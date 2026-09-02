# DATA MODEL

Derived from `schema.sql` and `fix-01`…`fix-07` on 2026-09-02, and
cross-checked against the live database. No key values appear here.

**`fix-07` is written but NOT applied.** Anything it introduces is
marked *(fix-07, not live)*.

---

## Tables

### `user_roles`
Who is internal staff, and what they may do. The most security-critical
table in the schema.

| Column | Notes |
|---|---|
| `user_id` | **PK**, FK → `auth.users(id)` ON DELETE CASCADE. Being the PK means **one role per person** — this is what makes separation of duties enforceable. |
| `role` | CHECK ∈ `viewer, initiator, checker, approver`. `viewer` added by fix-05. `initiator` is defined but **used nowhere**. |
| `granted_at` | timestamptz, default now() |

Deliberately has **no RLS policy at all** and `revoke all from anon,
authenticated`. Unreachable from the API in either direction; only
SECURITY DEFINER functions touch it. Roles are never read from
`auth.users.raw_user_meta_data`, which the user can edit themselves.

### `vendors`
One registration per account. ~35 columns; the ones that carry meaning:

| Column | Why it exists |
|---|---|
| `id` | PK, `gen_random_uuid()` |
| `user_id` | FK → `auth.users(id)`, **UNIQUE** — one registration per account |
| `company_name`, `country`, `region`, `address1..3`, `city`, `pin_code` | postal identity, ordered on the form as address → city → state → PIN → country |
| `payment_terms`, `order_currency`, `inco_terms` | commercial terms from the paper VRF |
| `contact_sales`/`email_sales`, `contact_finance`/`email_finance` | the paper form has **two separate contacts**; invitations are addressed to the finance one |
| `pan_no`, `tan_no`, `gstin_no` | Indian statutory IDs. Nullable — overseas vendors have none |
| `msmed_covered` | boolean, nullable. When true, an MSMED certificate is mandatory at submit |
| `status` | CHECK ∈ `draft, submitted, checked, approved, rejected` — the workflow state machine |
| `remarks` | staff note, shown back to the vendor |
| `allocated_staff_id` | FK → `auth.users(id)`. Added by an `ALTER` after the CREATE so it applies to existing installs. Drives the whole staff queue |
| `checked_by`/`checked_at`, `approved_by`/`approved_at` | the sign-off trail. `checked_by` is compared against `auth.uid()` to block one person doing both |
| `initiated_by`/`initiated_at` | **never written by any code** — left from mirroring the paper form |
| `sap_draft_id`, `sap_link_state`, `sap_linked_at`, `idempotency_key` | *(fix-07, not live)* pointer to SAP and enough state to reconcile a failed hand-off |

CHECK constraints `gstin_format`, `pan_format`, `tan_format`,
`pin_format` are all **NULL-tolerant** so a draft can be saved
half-finished; completeness is enforced at submit time by
`submit_registration()` instead.

### `vendor_bank_details`
Banking fields, one row per vendor. `vendor_id` is both PK and FK →
`vendors(id)` CASCADE.

Columns: `beneficiary_name`, `bank_name_addr`, `account_number`,
`ifsc_code`, `swift_code`, with format CHECKs on the last three.

**All privileges revoked from `anon` and `authenticated`** — no role can
SELECT, INSERT, UPDATE or DELETE. Access is exclusively through
functions. *(fix-07 drops this table entirely.)*

### `vendor_documents`
Metadata only; the files live in Storage.

| Column | Notes |
|---|---|
| `id` | PK |
| `vendor_id` | FK → `vendors(id)` CASCADE |
| `doc_type` | CHECK ∈ `msmed_certificate, gst_certificate, pan_card, cancelled_cheque, signed_vrf, other`. fix-07 removes `cancelled_cheque` |
| `storage_path` | must begin `<vendor_id>/` — the storage policies parse this |
| `file_name`, `uploaded_at` | |
| `verified_by`, `verified_at` | FK → `auth.users(id)`. **Never written by any code** |

### `vendor_invitations`
| Column | Notes |
|---|---|
| `id` | PK |
| `vendor_email` | **UNIQUE** — one invitation per address ever, which is why `delete_invitation()` exists |
| `allocated_staff_id` | NOT NULL FK → `auth.users(id)` — a submission can never arrive unowned |
| `vendor_user_id`, `vendor_id` | filled on claim |
| `status` | CHECK ∈ `pending, opened, registered, expired, cancelled`. `opened` is **never set by any code** |
| `expires_at` | default `now() + 30 days` |

### `staff_invitations` *(fix-05)*
Colleague invitations. `email` UNIQUE, `role` CHECK ∈ `viewer, checker,
approver`, `claimed_at` nullable. Lets a role be prepared before the
person has an account.

### `audit_log`
Append-only. `id bigserial` PK, `at`, `actor` (uuid, **not FK
constrained**), `actor_email`, `action`, `vendor_id` (uuid, **not FK
constrained**), `detail jsonb`.

INSERT/UPDATE/DELETE revoked. Writes only via `write_audit()`. The
missing FKs are deliberate — audit rows must survive the deletion of
whatever they describe.

### `_migrations` *(fix-06)*
`filename` PK, `applied_at`, `note`. The ground truth for what has been
applied.

---

## Relationships

Enforced by foreign keys:

```
auth.users ──1:1── vendors            (user_id UNIQUE, CASCADE)
auth.users ──1:1── user_roles         (user_id PK, CASCADE)
auth.users ──1:N── vendors.allocated_staff_id
auth.users ──1:N── vendor_invitations.allocated_staff_id (NOT NULL)
vendors    ──1:1── vendor_bank_details (vendor_id PK, CASCADE)
vendors    ──1:N── vendor_documents    (CASCADE)
vendors    ──0:1── vendor_invitations.vendor_id
```

**Enforced only in application code or by convention:**

- `audit_log.vendor_id` → `vendors.id` — no FK. Intentional; audit
  outlives its subject.
- `audit_log.actor` → `auth.users.id` — no FK, same reason.
- `vendor_documents.storage_path` → the actual file in the `vendor-docs`
  bucket. **Nothing enforces this.** `uploadDoc()` uploads first and
  inserts the row second; a failure between the two leaves an orphaned
  file with no metadata, or metadata pointing at nothing.
- `staff_invitations.email` → `auth.users.email` — matched by string in
  `claim_staff_role()`, no constraint.
- `vendor_invitations.vendor_email` → `auth.users.email` — same, in
  `claim_invitation()`.

---

## RLS

**Enabled on all 8 tables.** Verified live: an anonymous caller holding
the anon key gets `[]` or `42501` on every one.

| Table | Policy | Applies to | Permits |
|---|---|---|---|
| `user_roles` | *(none)* | — | Nothing. `revoke all`. |
| `vendors` | `vendor_reads_own` | authenticated | SELECT where `user_id = auth.uid()` |
| | `vendor_inserts_own` | authenticated | INSERT where `user_id = auth.uid()` |
| | `vendor_updates_draft` | authenticated | UPDATE where own **and** `status='draft'` — this is what freezes a submitted record |
| | `staff_reads_allocated` | authenticated | SELECT where `(is_staff() AND allocated_staff_id = auth.uid()) OR has_role('approver') OR has_role('viewer')` |
| `vendor_bank_details` | `bank_insert_own_draft`, `bank_update_own_draft` | authenticated | **Unreachable** — privileges revoked |
| `vendor_documents` | `doc_reads_own` | authenticated | SELECT own vendor's rows |
| | `doc_insert_draft` | authenticated | INSERT for own vendor while draft |
| | `doc_staff_reads` | authenticated | SELECT where `is_staff()` |
| `vendor_invitations` | `inv_staff_reads` | authenticated | SELECT where `allocated_staff_id = auth.uid() OR has_role('approver')` |
| `staff_invitations` | `staff_inv_reads` | authenticated | SELECT where `is_staff()` |
| `audit_log` | `staff_reads_audit` | authenticated | SELECT where `is_staff()` |
| `_migrations` | `migrations_staff_read` | authenticated | SELECT where `is_staff()` |

### Storage — `storage.objects`, bucket `vendor-docs` (private)

| Policy | Permits |
|---|---|
| `vdocs_insert_own` | INSERT where caller owns the vendor named by `(storage.foldername(name))[1]` **and** that vendor is `draft` |
| `vdocs_read_own` | SELECT own vendor's files, any status |
| `vdocs_read_staff` | SELECT where `is_staff()` |

### Broader than the name suggests

1. **`staff_reads_allocated`** — despite "allocated", approvers *and
   viewers* read **every** vendor row.
2. **`doc_staff_reads` and `vdocs_read_staff`** — any staff role,
   including `viewer`, reads **every** document row and **every** file,
   with no allocation check. A viewer is meant to be read-only; this
   makes it read-only over everything. **Worth reviewing.**
3. **`staff_inv_reads`** — viewers can see who has been invited as an
   approver.
4. **`list_applied_migrations()`** is granted to `anon` and is SECURITY
   DEFINER, so it bypasses `migrations_staff_read` entirely. Deliberate,
   but it means the migration list is public.

No table has RLS off.

---

## Functions

25 distinct, **all SECURITY DEFINER**, all pinning `search_path =
public, pg_temp`.

**Authorisation** — `has_role(p_role)`, `is_staff()`. Every other
function's guard is built on these.

**Vendor** — `claim_invitation()`, `submit_registration()` (completeness
checks, freezes the row, audits), `save_bank_details(...)`,
`get_my_bank_last4()`.

**Staff** — `staff_reveal_bank_details(p_vendor_id)` (**audits before
returning**, so a failed audit write rolls back the disclosure),
`advance_status(p_vendor_id, p_action, p_remarks)` (check/approve/
reject/reopen; enforces `submitted→checked→approved` order and
`checked_by ≠ auth.uid()`), `create_invitation`, `delete_invitation`,
`list_staff`, `list_staff_detail`, `grant_staff_role`,
`revoke_staff_role` (refuses to remove the last approver; nobody may
change their own role), `invite_staff`, `claim_staff_role`,
`list_staff_invitations`, `delete_staff_invitation`, `bank_mask`.

**Open** — `list_applied_migrations()`, granted to `anon`.

**Internal** — `write_audit(p_action, p_vendor_id, p_detail)`.

**fix-07, not live** — `sap_begin_link`, `sap_complete_link`,
`write_audit_as` (all three revoked from `anon`/`authenticated`;
service_role only) and `list_unlinked_sap_drafts` (approver-only
reconciliation).

## Triggers

**None.** No `CREATE TRIGGER` anywhere. `updated_at` is set explicitly
inside functions, not by a trigger — so any write that bypasses those
functions leaves it stale.

## Views

`vendor_overview` — the staff queue. `security_invoker = true`, so the
caller's own RLS applies and a vendor querying it directly sees only
their own row. **Contains no banking columns by construction.** Rebuilt
three times (schema → fix-01 → fix-07). The fix-01 rebuild exists
because the original joined `vendor_bank_details`, which nobody can
SELECT, breaking the view for everyone with `42501`.

## Indexes

**Exactly one is declared in the entire schema**, and it is in the
unapplied fix-07:

```sql
create index vendors_sap_pending_idx on public.vendors (sap_link_state)
  where sap_link_state = 'pending';
```
Supports the reconciliation query in `list_unlinked_sap_drafts()`.

Everything else relies on implicit indexes from PK and UNIQUE
constraints: `vendors(id)`, `vendors(user_id)`, `user_roles(user_id)`,
`vendor_bank_details(vendor_id)`, `vendor_documents(id)`,
`vendor_invitations(id)`, `vendor_invitations(vendor_email)`,
`staff_invitations(id)`, `staff_invitations(email)`, `audit_log(id)`,
`_migrations(filename)`.

**Not indexed, but queried on every page load** — see Risks.

---

## Which code paths touch which table

| Table | Read by | Written by |
|---|---|---|
| `vendors` | `startVendor()` (`sb.from("vendors").select`), `renderQueue()`/`renderDetail()` via the view | `saveStep()` (`.update`), `claim_invitation()`, `submit_registration()`, `advance_status()` |
| `vendor_overview` | `renderQueue()`, `renderDetail()` | — (view) |
| `vendor_bank_details` | `get_my_bank_last4()`, `staff_reveal_bank_details()`, `bank_mask()` | `save_bank_details()` only |
| `vendor_documents` | `startVendor()`, `vendor_overview` doc_count subquery | `uploadDoc()` (`.insert`) |
| `vendor_invitations` | `renderInvitationLists()` | `create_invitation()`, `delete_invitation()`, `claim_invitation()` |
| `staff_invitations` | `list_staff_invitations()` | `invite_staff()`, `claim_staff_role()`, `delete_staff_invitation()` |
| `user_roles` | `is_staff()`, `has_role()`, `list_staff_detail()` | `grant_staff_role()`, `revoke_staff_role()`, `claim_staff_role()`, `invite_staff()` |
| `audit_log` | `renderAudit()` | `write_audit()` only |
| `_migrations` | `list_applied_migrations()` | the `insert` at the foot of each fix file |

The front end reads only five things directly: `vendors`,
`vendor_overview`, `vendor_documents`, `vendor_invitations`,
`audit_log`. Everything else goes through RPC.

## Migrations

Plain `.sql` in the repo root, applied by hand in the Supabase SQL
editor. No CLI, no `supabase/migrations/`, no runner.

The editor wraps a pasted batch in one implicit transaction, so a script
that errors partway **rolls back entirely** — a failed run leaves
nothing applied. This is why the fix-01 failure also silently reverted
the `claim_invitation` fix later in the same file.

Applied live: `schema.sql`, `fix-01` … `fix-06`.
Written, not applied: `fix-07-remove-bank-storage.sql`.

**Applied out of band:** `admin-queries.sql` is *not* a migration — it
is operational SQL run ad hoc (granting roles, resetting a password,
reallocating a vendor). Nothing records when any of it was run. Role
grants in particular have been made directly this way, so `user_roles`
contents cannot be reconstructed from the migration history.

---

## Risks

**Unindexed columns on hot paths.** `vendors.allocated_staff_id` is
evaluated by `staff_reads_allocated` on *every* staff queue read and has
no index. Same for `vendors.status` (filtered on every `renderQueue()`),
`vendor_documents.vendor_id` (joined for `doc_count` on every row of the
queue), and `audit_log.at` (ordered on every audit view). At ~500
vendors Postgres will seq-scan happily and nobody will notice. This
becomes real if the audit log grows large — it is append-only and never
pruned.

**`vendor_overview` calls `bank_mask()` per row** via a lateral join,
and `bank_mask()` itself runs three `has_role`/`is_staff` lookups
against `user_roles`. That is a function call per row per page load.
Fine at this size; quadratic-ish in feel if the queue grows.

**Nullable columns the code assumes are set.** `vendors.company_name`,
`country`, `status` are all nullable at the database level. The UI and
`submit_registration()` treat them as present. A row created by
`claim_invitation()` has only `company_name`, `email_finance` and
`allocated_staff_id` set — everything else is NULL until the vendor
saves. Any code reading a `draft` row must handle NULL everywhere.

**`updated_at` is maintained by hand.** No trigger. Any write that does
not go through the functions leaves it stale, including
`admin-queries.sql` edits.

**Orphaned storage files.** `uploadDoc()` performs two independent
operations. There is no transaction across Storage and Postgres, and no
cleanup job. `fix-07` deletes `vendor_documents` rows but explicitly
does not delete the files.

**`audit_log.actor` has no FK**, so deleting a user leaves audit rows
pointing at a non-existent id. Deliberate, but it means the audit trail
cannot be joined back to `auth.users` reliably.

**No history on `vendors`.** Updates are in place. `audit_log` records
that a status changed but not what a field held before. There is no way
to answer "what account number did they originally give" — which,
once banking moves to SAP, becomes SAP's problem rather than a gap here.

**`initiator` role and `initiated_by`/`initiated_at` are dead.**
Defined, constrained, never written. Harmless, but misleading to anyone
reading the schema expecting a three-stage flow.

**One `viewer` can read everything.** Covered above under RLS — the
combination of `staff_reads_allocated`, `doc_staff_reads`,
`vdocs_read_staff`, `staff_inv_reads` and `staff_reads_audit` means a
view-only account sees every vendor, every document, every file, every
colleague invitation and the full audit log. Only bank details are
withheld. If "view only" was meant to imply "limited scope", it does
not.
