# CLAUDE.md — IKIO Vendor Registration Portal

## What this is

Vendor onboarding portal for IKIO Solutions Private Limited, serving
~500 suppliers. Vendors are invited by staff, fill a registration form
mirroring the company's existing paper "VRF ISPL" form, and submit for a
two-stage internal sign-off. Users are IKIO finance/procurement staff
(approvers, checkers, viewers) and external supplier contacts.

Live at https://ikio-vendor-portal.netlify.app · repo
https://github.com/paradox20029/ikio-vendor-portal (public).

## Architecture

```
Browser (static SPA)  ──►  Supabase (Postgres + Auth + Storage)
   Netlify-hosted           identity, RBAC, workflow, audit, documents
   live/index.html
        │
        └──► Cloudflare Worker ──► Cloudflare Tunnel ──► on-prem SAP B1
             (NOT BUILT YET — see PORTAL_BANK_MODE)
```

- **Front end**: one file, `live/index.html`. Vanilla JS in a single
  `<script type="module">`, no framework, no build step, no bundler.
  `live/config.js` holds runtime config and loads *before* the module.
- **Backend**: Supabase only. There is no application server. All logic
  that matters lives in Postgres functions; the browser calls them via
  PostgREST RPC.
- **The real boundary** is the set of ~25 SECURITY DEFINER functions.
  The front end collects input and renders results; every rule
  (validation, authorisation, audit, workflow transitions) is enforced
  in the database and holds even if the UI is bypassed entirely.
- **Planned boundary** (not built): banking data bypasses Supabase
  entirely and goes browser → Cloudflare Worker → Tunnel → SAP.

## Config flags — `live/config.js`

All are `window.*` globals read at runtime. Changing one changes
behaviour with no rebuild.

| Flag | Values | Effect |
|---|---|---|
| `SUPABASE_URL` | project URL | Which Supabase project. |
| `SUPABASE_ANON_KEY` | anon JWT | Public by design. See Keys below. |
| `PORTAL_ORG` | string | Header subtitle text. |
| `PORTAL_URL` | URL or `""` | Where magic links return users. Empty = use current origin (correct once deployed). Set only to force links from a local copy to point at production. |
| `PORTAL_TEST_MODE` | `true`/`false` | `true` shows the yellow "do not enter real bank details" banner. **Currently `true`.** |
| `PORTAL_BANK_MODE` | `"supabase"` / `"worker"` / `"off"` | See below. **Currently `"supabase"`.** |
| `PORTAL_WORKER_URL` | URL or `""` | Cloudflare Worker endpoint. Only used in `worker` mode. **Currently empty.** |
| `PORTAL_ALLOW_BANK_DOCUMENTS` | `true`/`false` | `false` hides the cancelled-cheque upload slot. **Currently `true`.** |

### PORTAL_BANK_MODE — the important one

- **`"supabase"`** — bank details stored in `vendor_bank_details` via
  `save_bank_details()`. Requires fix-07 **not** applied. Current state.
  Does *not* satisfy the "no banking data in third-party cloud
  databases" rule; acceptable only while on mock data.
- **`"worker"`** — bank payload POSTed to `PORTAL_WORKER_URL`, nothing
  stored in Supabase. Requires fix-07 applied **and** a deployed Worker.
- **`"off"`** — banking fields are never rendered at all (not hidden,
  not disabled — absent), so no code path can write an account number.
  `submit_registration()` in fix-07 no longer requires banking.

Worker mode **fails closed**: if `PORTAL_WORKER_URL` is empty,
`bankCaptureEnabled()` returns false rather than silently falling back
to Supabase. Verified by test.

## External integrations

- **Supabase** — project ref `wokaoqxsualvypgtfnjg`, free tier. Auth,
  Postgres, Storage. See the Supabase section below.
- **Brevo (SMTP)** — configured in Supabase Auth → Emails → SMTP
  Settings, not in this codebase. Quirks: the SMTP *username* is a
  synthetic `<id>@smtp-brevo.com` value from Brevo's SMTP page, not the
  account e-mail — getting this wrong presents as a gateway timeout, not
  an auth error. Sender address must be verified in Brevo first. Free
  tier ~300 mails/day. SMTP key was rotated once already.
- **Netlify** — static host. Deploy by dragging the **`live/` folder**
  onto the site's *Deploys* tab. Dragging the repo root publishes all
  the `.sql` and `.md` files at the site root (this happened once).
  Never use app.netlify.com/drop again — it creates a *new* site at a
  new URL.
- **SAP Business One Service Layer** — planned, not built. OData/REST,
  typically port 50000. Stateful sessions vs stateless Workers is the
  known wrinkle.
- **Cloudflare Worker + Tunnel** — planned, not built.

## Conventions

- **File layout**: repo root holds SQL migrations and docs. `live/`
  holds *only* what is deployed — currently `index.html`, `config.js`,
  `logo.png`. Keep it that way; anything added there becomes public.
- **Migrations** are `fix-NN-short-name.sql`, applied in numeric order,
  each idempotent and safe to re-run. Each ends by registering itself in
  `public._migrations`. **A fix file that doesn't register itself hasn't
  fully landed** — this is a house rule from fix-06 onward.
- **`schema.sql`** is the consolidated current schema with every fix
  folded in. Safe to run whole against an empty project.
- **Naming**: functions are `verb_noun` (`grant_staff_role`,
  `claim_invitation`). Parameters are prefixed `p_`. Policies are
  `<subject>_<action>_<scope>` (`vendor_updates_draft`,
  `doc_staff_reads`).
- **Error handling**: Postgres functions `raise exception` with
  user-readable messages — those strings are shown verbatim in the UI,
  so write them for a vendor, not a log. `fail()` in the front end maps
  known constraint names (`pan_format`, `ifsc_format`) to friendlier
  text and appends a hint for `PGRST202` (function missing → an
  unapplied migration) vs `42501` (privilege denied).
- **Tests**: there is no automated test suite. Verification is
  `TEST_PLAN.md` (manual walkthrough + a leak test that hits the REST
  API directly with the anon key) and ad-hoc `curl`/browser-console
  checks. If you change RLS or a SECURITY DEFINER function, re-run the
  leak test.

## Gotchas / non-obvious decisions

- **HTML comments (`<!--`) inside `<script type="module">` blank the
  entire page.** Modules reject them outright. Use `//` or `/* */`. This
  has happened once; a Node `new Function()` syntax check will *not*
  catch it because that parses as a script, where they are legal.
- **`CREATE OR REPLACE VIEW` cannot reorder or rename columns.** It can
  only append. Rebuilding `vendor_overview` requires `drop view` first,
  or you get `42P16`.
- **A view with `security_invoker = true` needs the caller to hold table
  privileges on everything it touches.** `vendor_overview` must not join
  `vendor_bank_details` (SELECT is revoked from everyone), or the whole
  view fails for staff too. The masked tail comes from `bank_mask()`
  instead.
- **Postgres does not validate column names inside a plpgsql body at
  creation time.** A function referencing a non-existent column installs
  cleanly and fails at first call. Two bugs shipped this way.
- **Calling an RPC with the wrong argument shape returns `PGRST202`,
  identical to "function does not exist."** This has produced false
  "missing migration" readings twice. Use `list_applied_migrations()`
  as ground truth, not RPC probing.
- **`[hidden]` is overridden by a class selector that sets `display`.**
  The fallback lettermark rendered alongside the real logo until
  `header.app .logo[hidden]{display:none}` was added.
- **A `<select>` the user never touches shows its first option but holds
  no value in JS.** Country appeared to read "India" while saving empty,
  which silently classified Indian vendors as overseas. Fixed by
  `syncFromDom()` reading values from the DOM at save time rather than
  trusting change events.
- **Per-step saves**: `STEP_COLS` limits each save to the columns on the
  current screen. Saving all columns meant a half-typed PAN on step 2
  blocked saving step 1 with a constraint error about an off-screen
  field.
- **Dropping `vendor_bank_details` alone does NOT achieve the compliance
  boundary.** A cancelled cheque image in Supabase *Storage* contains
  the same account number. `PORTAL_ALLOW_BANK_DOCUMENTS` gates it, and
  fix-07 purges those rows — but the files themselves must also be
  deleted in the Storage UI.
- **Magic links are single-use and expire (~1 hour).** Re-clicking a
  spent link lands on the sign-in page rather than erroring clearly.
  Delivery via Brevo's free tier can also take minutes — slow mail has
  already been mistaken for a broken login once. Tell testers to wait
  before requesting another, since repeats burn the hourly rate limit.
- **Separation of duties is real, not cosmetic**: a user holds exactly
  one role (`user_roles.user_id` is the PK). An approver is therefore
  *not* a checker and cannot check. Two approvers and no checker means
  nothing can move past `submitted`.

## Commands

```bash
# Serve locally (from C:\IKIO\vendor-portal). Binds 127.0.0.1 only and
# sends no-cache headers — do NOT use `python -m http.server`, which
# binds 0.0.0.0 and lets the browser cache stale code.
python serve.py                # → http://localhost:8030/live/index.html
python serve.py 8040           # alternate port

# Ground truth: which migrations are actually applied
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/list_applied_migrations" \
     -H "apikey: $ANON_KEY" -H "Content-Type: application/json" -d '{}'

# Leak test (see TEST_PLAN.md for the full version) — every one of these
# must return empty or an error for an anonymous caller
curl -s "$SUPABASE_URL/rest/v1/vendors?select=*" -H "apikey: $ANON_KEY"
```

No build, no install, no test runner. Deploy = drag `live/` onto
Netlify's Deploys tab.

---

# Supabase

Derived from `schema.sql` + `fix-01`…`fix-07` and verified against the
live project on 2026-09-02. **`fix-07` is written but NOT applied** —
everything below describes live state unless marked otherwise.

## Tables

| Table | Purpose | Key relationships |
|---|---|---|
| `user_roles` | Internal staff and their single role. PK is `user_id`, so **one role per person**. | `user_id` → `auth.users(id)` ON DELETE CASCADE |
| `vendors` | One row per vendor registration. Non-sensitive company data, workflow state, sign-off timestamps. | `user_id` → `auth.users(id)` UNIQUE; `allocated_staff_id`, `checked_by`, `approved_by`, `initiated_by` → `auth.users(id)` |
| `vendor_bank_details` | Banking fields. **Removed by fix-07** (not yet applied). | `vendor_id` → `vendors(id)` PK, ON DELETE CASCADE |
| `vendor_documents` | Metadata for uploaded files; the files live in Storage. | `vendor_id` → `vendors(id)` CASCADE; `verified_by` → `auth.users(id)` |
| `vendor_invitations` | Vendors invited to register, with owner allocation and expiry. `vendor_email` UNIQUE. | `allocated_staff_id`, `invited_by`, `vendor_user_id` → `auth.users(id)`; `vendor_id` → `vendors(id)` |
| `staff_invitations` | Colleagues invited to the portal, with intended role. `email` UNIQUE. Added fix-05. | `invited_by` → `auth.users(id)` |
| `audit_log` | Append-only event record. `bigserial` PK. | `actor` → nullable uuid (not FK-constrained); `vendor_id` uuid |
| `_migrations` | Which `fix-*.sql` files have been applied. Added fix-06. | none |

`vendors.status` ∈ `draft, submitted, checked, approved, rejected`.
`vendor_invitations.status` ∈ `pending, opened, registered, expired, cancelled`.
`user_roles.role` ∈ `viewer, initiator, checker, approver` (fix-05 added
`viewer`; `initiator` is defined but unused in the UI).
Format constraints on `vendors`: `gstin_format`, `pan_format`,
`tan_format`, `pin_format` — all NULL-tolerant so drafts can be partial.

## RLS

**RLS is enabled on all 8 tables.** Verified live: an anonymous caller
holding the anon key gets empty results or `42501` on every one.

| Table | Policies | What they allow |
|---|---|---|
| `user_roles` | **none** | `revoke all from anon, authenticated`. No API access at all — reachable only via SECURITY DEFINER functions. This is deliberate: a vendor who could write here could self-promote. |
| `vendors` | `vendor_reads_own` (SELECT, `user_id = auth.uid()`); `vendor_inserts_own` (INSERT, same); `vendor_updates_draft` (UPDATE, own **and** `status = 'draft'`); `staff_reads_allocated` (SELECT) | Staff read rule is broader than the name suggests: `(is_staff() AND allocated_staff_id = auth.uid()) OR has_role('approver') OR has_role('viewer')`. **Approvers and viewers see every vendor row**, not just allocated ones. No DELETE policy exists anywhere. |
| `vendor_bank_details` | `bank_insert_own_draft`, `bank_update_own_draft` (own vendor, draft only) | Both are **dead letters** — `revoke select, insert, update, delete from anon, authenticated` means no privilege reaches them. Kept as a second layer if privileges are ever re-granted. All access is via `save_bank_details()` / `staff_reveal_bank_details()`. |
| `vendor_documents` | `doc_reads_own` (own vendor); `doc_insert_draft` (own vendor, draft only); `doc_staff_reads` (`is_staff()`) | **`doc_staff_reads` is broad: any staff member, including a `viewer`, can read every document row** — no allocation check. Files themselves are gated separately by the Storage policies below. |
| `vendor_invitations` | `inv_staff_reads` (SELECT, `allocated_staff_id = auth.uid() OR has_role('approver')`) | Writes revoked; go through `create_invitation()` / `delete_invitation()`. Note this does **not** include `viewer`. |
| `staff_invitations` | `staff_inv_reads` (SELECT, `is_staff()`) | **Any staff member including a viewer can read all colleague invitations and their intended roles.** Writes revoked. |
| `audit_log` | `staff_reads_audit` (SELECT, `is_staff()`) | INSERT/UPDATE/DELETE revoked — append-only, and only via `write_audit()`. Viewers can read the whole audit log. |
| `_migrations` | `migrations_staff_read` (SELECT, `is_staff()`) | Writes revoked. Note `list_applied_migrations()` is granted to **anon** and bypasses this. |

### Storage policies (`storage.objects`, bucket `vendor-docs`)

Path convention is `<vendor_id>/<filename>` — the first path segment is
the ownership key, via `storage.foldername(name))[1]`.

- `vdocs_insert_own` — INSERT if the caller owns that vendor **and** it
  is still `draft`.
- `vdocs_read_own` — SELECT own vendor's files (any status).
- `vdocs_read_staff` — SELECT if `is_staff()`. **Broad: includes
  viewers, and no allocation check.**

Bucket is created with `public = false`.

### Flagged as broader than they look

1. `staff_reads_allocated` on `vendors` — approvers *and viewers* see
   all rows, not just allocated.
2. `doc_staff_reads` + `vdocs_read_staff` — any staff role, including
   `viewer`, reads every document and every file. A viewer is meant to
   be read-only, but "read-only over everything" may be wider than
   intended. **Worth reviewing.**
3. `staff_inv_reads` — viewers can see who has been invited as an
   approver.
4. `list_applied_migrations()` is granted to `anon` — deliberate (lets a
   fresh session check state with only the public key) but it does
   expose which migrations exist.

## Auth

- **Flow**: passwordless e-mail OTP via `sb.auth.signInWithOtp()` for
  everyone, plus `sb.auth.signInWithPassword()` offered as an explicit
  "IKIO staff" option on the sign-in screen. Staff can set a password
  from the header (`sb.auth.updateUser({ password })`); vendors are not
  offered this.
- **Sessions/JWTs**: handled entirely by supabase-js v2 (loaded from
  `esm.sh`). Session read via `getSession()`, changes watched with
  `onAuthStateChange`. The access token is passed to the Cloudflare
  Worker as `Authorization: Bearer` in `worker` mode.
- **Identity mapping**: `auth.users(id)` → `vendors.user_id` (UNIQUE, so
  one registration per account) and → `user_roles.user_id` (PK, so one
  role per account). A user with a row in `user_roles` is staff; a user
  with a `vendors` row is a vendor; a user with neither sees "No
  invitation found".
- **Invitation claiming**: `claim_invitation()` and `claim_staff_role()`
  both match on the e-mail of the currently signed-in user — the address
  they just proved they control by receiving the link. Both run at
  sign-in; both are idempotent no-ops for users with no invitation.
- **6-digit code**: **not implemented and not needed.** Sign-in is a
  clickable magic link and works for corporate addresses — confirmed
  with `@ikio.com`. If it is ever wanted, the route is `{{ .Token }}` in
  the Supabase e-mail template plus `verifyOtp({ email, token,
  type:'email' })`, but there is no current reason to.

## Keys

- **anon key** — in `live/config.js`, shipped to every browser, present
  in the public GitHub repo. Public by design; all protection comes from
  RLS. Used for every front-end call.
- **service_role key** — **not used anywhere in this codebase and must
  never enter `live/`.** It is intended only for the future Cloudflare
  Worker, where it would call `sap_begin_link`, `sap_complete_link` and
  `write_audit_as` — the three fix-07 functions explicitly revoked from
  `anon` and `authenticated`.
- Boundary: anything under `live/` is public. Anything needing
  `service_role` runs server-side in the Worker with the key in
  Cloudflare secrets.
- No key values are recorded in this file or any repo file.

## Functions

25 distinct functions, **all SECURITY DEFINER**, all with
`set search_path = public, pg_temp`.

**Authorisation helpers** — `has_role(p_role)`, `is_staff()`.

**Vendor-facing** (granted to `authenticated`) — `claim_invitation()`,
`submit_registration()` (validates completeness, freezes the record,
audits), `save_bank_details(...)`, `get_my_bank_last4()`.

**Staff-facing** (granted to `authenticated`, each checks role
internally) — `staff_reveal_bank_details(p_vendor_id)` (audits *before*
returning, so the whole call rolls back if the audit write fails),
`advance_status(p_vendor_id, p_action, p_remarks)` (check/approve/reject/
reopen; enforces checker≠approver and the submitted→checked→approved
order), `create_invitation`, `delete_invitation`, `list_staff`,
`list_staff_detail`, `grant_staff_role`, `revoke_staff_role` (refuses to
remove the last approver, and nobody may change their own role),
`invite_staff`, `claim_staff_role`, `list_staff_invitations`,
`delete_staff_invitation`, `bank_mask(p_vendor_id)`,
`list_applied_migrations()` (also granted to `anon`).

**Internal** — `write_audit(p_action, p_vendor_id, p_detail)`, called by
other functions.

**fix-07 only, not yet live** — `sap_begin_link`, `sap_complete_link`,
`write_audit_as`, `list_unlinked_sap_drafts`. The first three are
revoked from `anon` and `authenticated`: service_role/Worker only.

**Triggers**: none. No `CREATE TRIGGER` exists anywhere in the schema or
migrations.

## Views

`public.vendor_overview` — the staff queue. `security_invoker = true`,
so each caller's own RLS applies and a vendor querying it directly sees
only their own row. Contains **no banking columns by construction**;
the masked tail comes from `bank_mask()` via a lateral join. Rebuilt
three times (schema, fix-01, fix-07); fix-07's version drops
`account_masked`/`has_bank_details` in favour of `sap_draft_id`,
`sap_link_state`, `has_sap_draft`.

## Edge Functions

**None.** There is no `supabase/` or `functions/` directory in the repo
and no Edge Function is deployed. All server-side logic is Postgres
functions. The planned Cloudflare Worker is *not* a Supabase Edge
Function.

## Storage

One bucket: **`vendor-docs`**, private (`public = false`), created by an
`insert into storage.buckets ... on conflict do nothing` in `schema.sql`
— verified present in the live project. Path convention
`<vendor_id>/<timestamp>-<filename>`. Access rules under RLS above.
`doc_type` ∈ `msmed_certificate, gst_certificate, pan_card,
cancelled_cheque, signed_vrf, other` (fix-07 removes `cancelled_cheque`).

## Realtime

**None.** No `.channel()`, `.subscribe()` or realtime usage anywhere in
the front end. All data is fetched on demand.

## Migrations

Plain `.sql` files in the repo root, applied by hand: paste into the
Supabase SQL editor and Run. There is no CLI, no `supabase/migrations`
directory, no automated runner.

The editor wraps a pasted batch in a single implicit transaction, so a
script that errors partway **rolls back entirely** — a failed run leaves
nothing applied.

Applied live as of 2026-09-02: `schema.sql`, `fix-01` … `fix-06`.
Written but **not applied**: `fix-07-remove-bank-storage.sql`.

## Unverified — confirm before relying on

- **Supabase region.** Not checked. Settings → General. Matters for
  Indian data-residency (DPDP / RBI); cannot be changed after creation.
- **Plan tier.** Believed free tier (no PITR, project pauses on
  inactivity) but not verified this session.
- **Contents of `vendor_bank_details`.** Believed to be mock data only
  per `TEST_PLAN.md`, but RLS correctly prevents reading it from
  outside, so this is unconfirmed. Check before running fix-07, which
  deletes it irreversibly.
- **Current `user_roles` membership.** Last known: two approvers and one
  checker (`sotriyusta@tozya.com`, a temp-mail address). Not re-verified.
- **Brevo SMTP settings** live in the Supabase dashboard, not in code —
  none of it is verifiable from this repo.
- **Auth rate limits and whether "allow new users to sign up" is
  enabled.** Not inspected. Rate limits matter if many people are
  invited at once — SMTP raises the default to 30/hour, adjustable.
- **Whether any `signed_vrf` uploads contain handwritten bank details.**
  Affects whether fix-07's optional `signed_vrf` purge is needed.
