# GOTCHAS

Things that would cost you a day. Blunt. Speculation is labelled.

---

## Known bugs and their status

### Vendor sign-in / "6-digit code" — NOT A BUG, closed
A colleague on a corporate `@ikio.com` address appeared to be redirected
to the login page after clicking their sign-in link. A whole theory was
built around corporate mail scanners (Safe Links / Proofpoint)
pre-fetching URLs and consuming the single-use token, and a 6-digit OTP
was proposed as the fix.

**It was mail delivery latency.** He signed in successfully once the
message arrived. **No 6-digit code exists, none is needed, and none
should be built on the strength of that theory.** If you find a
reference to it anywhere, it is stale.

What is genuinely true and worth telling testers: links are single-use
and expire, Brevo's free tier can take minutes, and repeatedly
requesting new links burns the hourly rate limit and makes it look more
broken than it is.

### No checker currently granted — believed, blocks demos
Last known state was two approvers and one checker
(`sotriyusta@tozya.com`). A user holds **exactly one** role, so an
approver cannot check. With no checker, nothing moves past `submitted`
and the workflow demo dies mid-way. Verify in the Staff tab before
showing anyone.

### Temp-mail address holds live staff access
`sotriyusta@tozya.com` is a disposable inbox with `checker` rights on a
public URL. Anyone who guesses the address can request a sign-in link
and act as staff. Mock data only today, so low impact — but remove it.

### Real e-mail addresses are in public git history
Two personal Gmail addresses are readable in commit `2e94ef3` on GitHub.
The redaction commit `286b7a3` removed them from the files but git keeps
every version, and both are pushed. Not fixed; the decision was to leave
it.

---

## Fragile code

**HTML comments inside the module blank the entire page.** A single
`<!--` anywhere in `<script type="module">` throws "HTML comments are
not allowed in modules" and nothing renders. This has happened once,
introduced by hand-written explanatory comments. **A Node
`new Function()` syntax check will not catch it** — that parses as a
script, where they are legal. Only a browser catches it. Use `//` or
`/* */`.

**`CREATE OR REPLACE VIEW` cannot reorder or rename columns.** Only
append. Rebuilding `vendor_overview` with a different column order fails
with `42P16`. Must `drop view` first.

**A `security_invoker` view needs the caller to hold privileges on
everything it touches.** `vendor_overview` must never join
`vendor_bank_details` — SELECT is revoked from all roles, so the join
breaks the view for *staff too*, not just anonymous callers. This
happened; symptom was "permission denied for table vendor_bank_details"
on the whole staff queue.

**Postgres does not check column names inside plpgsql at creation
time.** A function referencing a non-existent column installs cleanly
and fails at first call. Two bugs shipped this way, including
`claim_invitation()` writing to a `vendors.email` column that does not
exist.

**`[hidden]` loses to a class selector that sets `display`.** The
fallback lettermark rendered alongside the real logo because
`header.app .logo{display:grid}` outranked the browser's `[hidden]`
rule. Needed an explicit `header.app .logo[hidden]{display:none}`.

### Looks safe to change but isn't

- **Any `data-k`, `data-tab`, `data-doc`, `data-del`, `data-revoke`
  attribute.** These are the wiring, not styling hooks. `data-k` maps a
  field to its database column. Rename or drop one and that field
  silently stops saving — no error, it just does nothing.
- **The storage path format in `uploadDoc()`.** Must begin
  `<vendor_id>/`. The `vdocs_insert_own` policy parses the first path
  segment. Change the format and every upload is rejected.
- **`STEP_COLS`.** Adding a column to the wrong step means it either
  never saves, or saves from a screen where it isn't visible and trips a
  constraint about an off-screen field.
- **The order of `revoke` vs `create policy` in a migration.** Policies
  on `vendor_bank_details` are already unreachable because privileges
  are revoked. Re-granting a privilege silently activates two dormant
  policies.
- **Reordering `sb.rpc("claim_staff_role")` in `boot()`.** It must run
  *before* the `is_staff`/`has_role` calls or a newly-invited colleague
  gets their role attached but reads their old (absent) role for that
  session.

---

## Unenforced assumptions

- **`vendor_documents.storage_path` points at a real file.** Nothing
  enforces it. `uploadDoc()` uploads then inserts as two independent
  operations with no transaction; a failure between them orphans one or
  the other. No cleanup job exists.
- **`vendors.company_name`, `country`, `status` are non-null.** All are
  nullable in the database. A row created by `claim_invitation()` has
  almost everything NULL until the vendor saves. Any code reading a
  `draft` row must handle that.
- **`updated_at` is current.** Maintained by hand inside functions. No
  trigger. Anything written via `admin-queries.sql` leaves it stale.
- **Roles are current for the session.** `ME` is populated once in
  `boot()` and never refreshed. A role changed mid-session is invisible
  until sign-out and back in.
- **One vendor = one account.** Enforced by `vendors.user_id UNIQUE`.
  There is no mechanism for a supplier whose contact person leaves —
  staff must cancel and reissue the invitation to a new address.
- **`vendor_invitations.vendor_email` is the finance contact.** Only
  convention; the UI hints it, nothing enforces it.

---

## Local vs deployed

| | Local | Deployed |
|---|---|---|
| Server | `serve.py`, binds `127.0.0.1`, no-cache headers | Netlify CDN, caches |
| Redirect target | `location.href` → `localhost:8030` | the Netlify URL |
| **Sign-in links** | **point at localhost — useless to anyone else** | work for everyone |
| Config | edit `config.js`, reload | requires a redeploy |
| Schema | same live Supabase project | same live Supabase project |

**The one that catches people:** database changes take effect on the
deployed site *immediately*, because both talk to the same Supabase
project — but front-end changes need a redeploy. Run a migration that
drops a function the deployed page still calls and you break production
while your local copy looks fine. Always redeploy first, then migrate.

The Invitations tab shows a warning banner when running on localhost
with no `PORTAL_URL` set, precisely because invitations sent from a
local copy contain unusable links.

Deploy is a manual drag of the **`live/` folder** onto Netlify's Deploys
tab. Dragging the repo root publishes every `.sql` and `.md` file at the
site root — this happened once and led to rotating the Brevo SMTP key.

---

## What fails silently

- **Delivery of any e-mail.** `signInWithOtp` resolving without error
  means Supabase *accepted* the request, not that anything arrived.
  Delivery failures surface only in Brevo's logs.
- **`uploadDoc()` partial failure.** The Storage upload succeeding and
  the metadata insert failing shows "Upload failed" but leaves the file
  in the bucket permanently.
- **An untouched `<select>`.** Fixed by `syncFromDom()`, but the class
  of bug remains: any new input added without `data-k` will render,
  accept typing, and never save. No warning.
- **`try{ await sb.rpc("claim_staff_role") }catch(e){}` in `boot()`.**
  Swallows every error, including a genuine failure to attach a role.
  The user simply appears to have no access.
- **`catch(e){ /* treated as vendor */ }`** around the role lookups in
  `boot()`. A network blip during sign-in silently demotes a staff
  member to the vendor view.
- **`bankViaWorker()` returning false on a misconfiguration.** Failing
  closed is correct, but the failure is invisible — the banking fields
  simply aren't rendered, with no error anywhere.
- **Netlify deploys.** No CI, no check. Whatever is dragged is live.

---

## Half-migrated / half-refactored

- **`fix-07` is written and unapplied.** The front end has all three
  banking modes; the database still has the old shape. Consistent only
  because `PORTAL_BANK_MODE = "supabase"` selects the old path. Change
  that flag without running fix-07, or run fix-07 without changing the
  flag, and the portal breaks in opposite directions.
- **The Cloudflare Worker does not exist.** `sendBankToSap()` and the
  worker branch of the reveal handler call endpoints that were never
  built. Dead code guarded by config.
- **`initiator` role.** In the `user_roles` CHECK constraint, referenced
  nowhere. Same for `vendors.initiated_by` / `initiated_at` — columns
  that no code writes.
- **`vendor_invitations.status` value `opened`.** Permitted by the CHECK
  constraint, never set.
- **`LOVABLE_PROMPT.md`** documents an abandoned build approach. Kept as
  history; describes nothing that exists.
- **`demo.html`** is a standalone localStorage mockup sharing no code
  with `live/`. It has diverged and does not reflect current behaviour —
  notably it still shows a single shared staff queue.
- **`admin-queries.sql` is applied out of band.** Role grants and
  password resets have been run from it directly. Nothing records when.
  `user_roles` contents cannot be reconstructed from migration history.

---

## Speculation, labelled as such

- *(Speculation)* The `viewer` role probably grants more than intended.
  A viewer can read every vendor, every document, every file, every
  colleague invitation and the entire audit log — only bank details are
  withheld. Whether "view only" was meant to mean "limited scope" was
  never settled. Worth asking before anyone is given it.
- *(Speculation)* `audit_log` is append-only and never pruned. At a few
  hundred vendors this is fine. If a script ever loops over reveals it
  could grow fast, and `audit_log.at` is unindexed while `renderAudit()`
  orders by it.
- *(Speculation)* Nothing tests whether `PORTAL_TEST_MODE = false`
  actually hides the banner in the deployed build; it has only ever run
  as `true`.
- *(Unverified)* The contents of `vendor_bank_details` are *believed* to
  be mock data only. RLS correctly prevents reading it from outside, so
  this has never been confirmed. `fix-07` deletes it irreversibly, on a
  free-tier project with no point-in-time recovery. **Check before
  running it.**
