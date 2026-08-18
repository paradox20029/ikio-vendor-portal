# Project status

Last updated: 2026-08-18. This file is the single place to check "where did
we leave off" — update it whenever something material changes, and read it
first in any new session before touching code or SQL.

## What exists

- **Supabase project**: `ikio_vendor_portal`, ref `wokaoqxsualvypgtfnjg`,
  org `paradox20029's Org`, free tier.
- **Deployed site**: https://ikio-vendor-portal.netlify.app — live, correct
  folder (`live/` only, 3 files: index.html, config.js, logo.png).
- **Local dev**: `python serve.py` from `C:\IKIO\vendor-portal`, serves on
  `:8030`. No-cache headers, localhost-only bind.
- **SMTP**: Brevo, custom SMTP configured in Supabase Auth. Sender verified.

## Database — fix files applied, in order

Run against the live Supabase project, confirmed installed by direct query
(not assumed):

| File | What it does |
|---|---|
| `schema.sql` | Base schema. Safe to re-run whole; every fix below is folded into it. |
| `fix-01-vendor-overview.sql` | `vendor_overview` view + `bank_mask()` — fixed permission-denied bug. |
| `fix-02-save-bank-details.sql` | `save_bank_details()` RPC — vendor bank writes now go through a function, not a direct table write. |
| `fix-03-delete-invitation.sql` | `delete_invitation()` — lets staff free up a vendor e-mail to reinvite. |
| `fix-04-staff-management.sql` | `grant_staff_role`, `revoke_staff_role`, `list_staff_detail` — the Staff tab. **Confirmed installed.** |
| `fix-05-staff-invitations.sql` | `viewer` role, `staff_invitations` table, `invite_staff`, `claim_staff_role` — Invite a colleague. **Confirmed installed.** |

If starting a new session: don't assume any of these ran. Query directly —
`select proname from pg_proc where proname = '<function>'`, or try calling
the RPC and check for `PGRST202` (missing) vs. any other response (exists).

## People currently in the system

Real state as of last check — verify again if it's been a while:

| E-mail | Role | Notes |
|---|---|---|
| YOUR_EMAIL@example.com | approver | The owner account. |
| COLLEAGUE_EMAIL@example.com | approver | Real inbox. |
| sotriyusta@tozya.com | checker | **Temp-mail address with real access.** Remove once testing is done — disposable inboxes are readable by anyone who knows the address, and this one can check registrations. |

Three vendor invitations exist (`solder_compnay`, `led_company`, `xyz`), all
status `registered`, all using temp-mail addresses and mock data from
`TEST_PLAN.md`. Safe to delete and recreate at any time.

## Open thread — mail delivery, unresolved

Colleague invitations to `sotriyusta@tozya.com` and `COLLEAGUE_EMAIL@example.com` were
created successfully (both rows exist in `staff_invitations`), but neither
reported receiving the sign-in e-mail.

**Not yet established:** whether Supabase's send call itself failed (check
Resend link → the toast message it returns), or whether it succeeded and
Brevo failed to deliver (check Brevo → Transactional → Logs) or rate-limited
(check Supabase → Authentication → Rate Limits — SMTP defaults to 30/hour and
today's session has sent many). Leading theory is Brevo blocking the
disposable `tozya.com` domain, unconfirmed — `COLLEAGUE_EMAIL@example.com` (real inbox)
not receiving anything either would rule that out.

**Next action:** check Brevo's transactional log for both addresses and
report what it shows.

## Known gaps / not yet done

- **Leak test** (`TEST_PLAN.md`) has not been run against the live project.
  Do this before any real vendor data goes in.
- **Document upload** (MSMED certificate etc.) has UI and storage policies
  but has not been exercised end to end with a real file.
- **PORTAL_TEST_MODE** is `true` in `config.js` — keep it that way until
  genuinely collecting real vendor data.
- No real vendor or bank data exists anywhere in the system. Everything is
  mock data per `TEST_PLAN.md`.

## Rotated credentials

Brevo SMTP key was rotated after an accidental deploy briefly exposed
`SETUP.md` (containing the old SMTP username) at the site root. Old key is
invalid; current key is in Supabase's SMTP settings only, not written to any
file in this repo.
