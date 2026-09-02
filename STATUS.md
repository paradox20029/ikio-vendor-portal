# Project status

Last updated: 2026-08-19.

## Start here — how to restore context in a new chat, in one message

Paste this to a fresh Claude Code session started in `C:\IKIO\vendor-portal`:

> Read STATUS.md, then run this to get the database's own record of what's
> applied (replace ANON_KEY from live/config.js):
>
> `curl -s -X POST "https://wokaoqxsualvypgtfnjg.supabase.co/rest/v1/rpc/list_applied_migrations" -H "apikey: ANON_KEY"`
>
> Compare that list against the fix-*.sql files present in this folder. Any
> file not in the returned list has not been applied — run it before
> assuming its functions exist. Then read DEMO.md, SETUP.md and TEST_PLAN.md
> before making changes.

That one query is ground truth. Everything else in this file is
convenience — helpful context, not something to trust blindly. **This
project has twice given a false "missing" reading** from calling an RPC
with the wrong argument shape (Postgres reports that identically to "does
not exist"). Prefer the ledger query above over re-deriving state by
guessing RPC signatures.

## What exists

- **Supabase project**: `ikio_vendor_portal`, ref `wokaoqxsualvypgtfnjg`,
  org `paradox20029's Org`, free tier.
- **GitHub**: https://github.com/paradox20029/ikio-vendor-portal — public.
  Front end, schema, and every fix-*.sql are version controlled here. This
  repo is the durable copy of code and intended migrations; it is NOT a
  record of what has actually run against the live database — that's what
  the ledger (above) is for.
- **Deployed site**: https://ikio-vendor-portal.netlify.app — the `live/`
  folder only (index.html, config.js, logo.png). Redeploy by dragging that
  folder onto the site's Deploys tab in Netlify, never onto
  app.netlify.com/drop again (that mints a new site at a new URL).
- **Local dev**: `python serve.py` from `C:\IKIO\vendor-portal`, serves on
  `:8030`. No-cache headers, localhost-only bind.
- **SMTP**: Brevo, custom SMTP configured in Supabase Auth. Sender verified.
  Key was rotated once already (see bottom of this file) — if mail stops
  working, check the key hasn't expired or been revoked in Brevo.

## Database — the migrations ledger (fix-06 onward)

`fix-06-migrations-ledger.sql` adds a `_migrations` table and a
`list_applied_migrations()` RPC — callable with only the anon key, no
sign-in required. **Run the query in the "Start here" section above before
trusting anything below.**

| File | What it adds |
|---|---|
| `schema.sql` | Base schema — tables, RLS, roles, invitations. Safe to re-run whole. |
| `fix-01-vendor-overview.sql` | `bank_mask()` + `vendor_overview` rebuild. |
| `fix-02-save-bank-details.sql` | `save_bank_details()` — vendor bank writes go through a function, never a direct table write. |
| `fix-03-delete-invitation.sql` | `delete_invitation()` — frees a vendor e-mail to reinvite. |
| `fix-04-staff-management.sql` | `grant_staff_role`, `revoke_staff_role`, `list_staff_detail` — the Staff tab. |
| `fix-05-staff-invitations.sql` | `viewer` role, `staff_invitations`, `invite_staff`, `claim_staff_role` — Invite a colleague. |
| `fix-06-migrations-ledger.sql` | This ledger itself. **Not yet applied — run it.** |

**House rule from fix-06 onward:** every future fix file ends with an
`insert into public._migrations (filename, note) values (...)`. A fix file
that doesn't register itself hasn't fully landed, even if its functions
work — update the file, don't skip the step.

## People currently in the system

Real state as of last check — verify again if it's been a while, e.g.
`select email, role from public.user_roles join auth.users using (id)`
run as an approver, or via the Staff tab.

| E-mail | Role | Notes |
|---|---|---|
| YOUR_EMAIL@example.com | approver | The owner account. |
| COLLEAGUE_EMAIL@example.com | approver | Real inbox. |
| sotriyusta@tozya.com | checker | **Temp-mail address with real access.** Remove once testing is done — disposable inboxes are readable by anyone who knows the address. |

Three vendor invitations exist (`solder_compnay`, `led_company`, `xyz`), all
status `registered`, all using temp-mail addresses and mock data from
`TEST_PLAN.md`. Safe to delete and recreate at any time.

## Open thread — mail delivery, last left unresolved

Colleague invitations to `sotriyusta@tozya.com` and the real Gmail address
were created successfully, but neither confirmed receiving the sign-in
e-mail. Not yet established whether the Supabase send call itself failed,
or Brevo received it and blocked/filtered it (check Brevo → Transactional →
Logs — this is the fastest way to settle it). Leading theory was Brevo
refusing the disposable `tozya.com` domain; unconfirmed either way. If this
is resolved, delete this section rather than leaving a stale "open thread."

## Banking data — current position and the gate before real vendors

**Right now bank details ARE stored in Supabase**, in
`public.vendor_bank_details`. This is deliberate and temporary: SAP
access and its API contract are pending departmental discussion, and the
portal has to stay functional in the meantime. Everything in that table
is mock data per `TEST_PLAN.md`.

`PORTAL_BANK_MODE` in `live/config.js` selects the behaviour:

| Mode | Behaviour | Requires |
|---|---|---|
| `supabase` | Stored in Supabase, as originally built. **Current setting.** | fix-07 NOT applied |
| `worker` | Posted to the Cloudflare Worker → SAP. Nothing stored here. | fix-07 applied + Worker deployed |
| `off` | Not collected at all. Registrations submit without banking. | fix-07 applied |

Worker mode fails closed: if `PORTAL_WORKER_URL` is empty it disables
capture rather than falling back to Supabase.

### Hard gate — do this before the first REAL vendor is invited

The manager's rule is that vendor banking data must not sit in a
third-party cloud database. While the portal is on mock data with the
TEST ENVIRONMENT banner up, that rule is not yet in play. It comes into
force the moment a real supplier is invited. In that order:

1. `PORTAL_BANK_MODE` → `"worker"` (if SAP is ready) or `"off"`
2. `PORTAL_ALLOW_BANK_DOCUMENTS` → `false`
3. Redeploy `live/` to Netlify
4. Delete cancelled-cheque files from Storage → `vendor-docs`
5. Run `fix-07-remove-bank-storage.sql`

**Do not run fix-07 before step 3.** The deployed site would call
`save_bank_details`, which fix-07 drops, and the banking step would
break for anyone mid-registration.

**The non-obvious part:** dropping the table is not sufficient on its
own. A cancelled cheque image shows the account number and IFSC, and
those upload to Supabase *Storage*, which is the same third-party cloud.
`PORTAL_ALLOW_BANK_DOCUMENTS = false` closes that, and fix-07 purges the
existing rows — but the files themselves must be deleted in the Storage
UI as well, since removing metadata rows leaves the images in the bucket.

## Real vendor data — findings that constrain rollout

Analysed 2026-09-02 from `BP Master data..1.xlsx` (IKIO Business Partner
export, dated 11-03-2026, 1,658 rows). Aggregates only — that file is
not in this repo and should not be committed to it; it contains real
supplier names, GSTINs and contact details.

**The blocker: only 8.9% of vendors have an e-mail address on file.**
147 of 1,658. The portal is invitation-by-e-mail end to end —
`create_invitation()` requires an address, `claim_invitation()` matches
on it, and magic links are the only way in. **1,511 vendors cannot be
invited as things stand.** This is a data-collection problem, not a code
problem, and it is the largest single constraint on rollout.

**Scale is 1,658, not ~500.** Every earlier estimate — the architecture
document's costs, SMTP volume, Supabase tier — assumed roughly 500.

**But the live working set may be ~114.** Only 114 rows are marked
`Active = Y`, and those are the *only* rows with a contact person filled
in (100% of them, versus 0% of the remainder). That is a strong signal
the active flag is genuinely maintained and the other 1,544 are dormant
history. **Unconfirmed — see ACTION_ITEMS.md.**

**The two lists barely overlap.** Of the 114 active vendors only 16 have
an e-mail; 131 vendors have an e-mail but are not marked active. `Active`
and `E-Mail` appear to be maintained by different people or at different
times.

Other figures worth knowing:

| Field | Coverage | Note |
|---|---|---|
| GSTIN | 100% | the only reliable identifier across the whole file |
| Payment terms | 100% | highly standardised: 1,376 are `Net-30*`, then `100% Advance` (183), Net-45, Net-60, Net-15 |
| Address | 100% | |
| Contact person | 6.9% | all within the active 114 |
| Mobile | 3.3% | |
| Vendor Reg. Form OK | **0%** | every row reads "Not OK" — either nobody has a completed form, or the column is unmaintained. Either way it is the problem this portal exists to solve |
| MSME status | 22% are MSME | 184 Small, 151 Micro, 24 Medium; 1,084 "NO"; 215 ambiguous `0` |
| Cancelled cheque on file | 0% | no bank documents held at all in this export |

Two consequences for the portal, **not yet acted on** (no code changed):

- `vendors.payment_terms` is free text. SAP already holds a small
  standard set; a dropdown of those values would match the ERP and
  improve data quality.
- MSMED handling in the portal is genuinely load-bearing — roughly a
  fifth of suppliers are MSME and need the certificate.

## Known gaps / not yet done

- **Leak test** (`TEST_PLAN.md`) has not been run against the live project.
  Do this before any real vendor data goes in.
- **Document upload** (MSMED certificate etc.) has UI and storage policies
  but has not been exercised end to end with a real file.
- **PORTAL_TEST_MODE** is `true` in `config.js` — keep it until genuinely
  collecting real vendor data.
- No real vendor or bank data exists anywhere in the system. Everything is
  mock data per `TEST_PLAN.md`.
- A **checker** role must exist alongside the approver(s) or nothing can
  move past "submitted" — verify one is currently granted before demoing.

## Rotated credentials

Brevo SMTP key was rotated once after an accidental deploy briefly exposed
`SETUP.md` (containing the old SMTP username) at the site root — that
deploy mistake is fixed (only `live/` is now dragged to Netlify) but if mail
ever stops working unexpectedly, check whether the key needs rotating again
rather than assuming it's a code problem.
