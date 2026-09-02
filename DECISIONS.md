# DECISIONS

Reasoning that isn't visible in the code. Only decisions actually made
in this project — where something was discussed but not settled, it says
so.

---

## 1. Hand-written vanilla JS, not Lovable

**Decided:** build the front end by hand as one HTML file with no
framework or build step.

**Alternatives:** Lovable (AI app builder) generating a React/Vite app
backed by Supabase; a conventional Node/Express backend.

**Why this won:** Lovable's MCP integration required an interactive
browser login that could not be completed from the working environment,
so it was never usable. Once the security model was understood, the
remaining UI was a form and two tables — not enough to justify a
framework, a bundler, or the dependency surface they bring.

**Cost:** no type checking, no component reuse, no test runner. One
1,800-line file. Refactoring is manual and there is nothing to catch a
typo before it reaches the browser.

**Status:** settled for this size of app. Revisit if a second page or a
second developer appears.

---

## 2. Supabase as the entire backend

**Decided:** Postgres + Auth + Storage, with all logic in database
functions. No application server.

**Alternatives:** Node/Express in front of Postgres; Supabase for auth
only with custom API.

**Why this won:** the rules that matter here are authorisation rules, and
they are enforceable in the database where they cannot be bypassed. An
application server would have added a layer that could be circumvented
by calling the database directly, and something to deploy and patch.

**Cost:** logic lives in SQL, which is harder to test and version than
application code. Postgres does not validate column names inside plpgsql
bodies at creation time, so a broken function installs cleanly and fails
at first call — this shipped two bugs.

**Status:** settled.

---

## 3. Magic links for vendors, passwords available for staff

**Decided:** `signInWithOtp` (e-mailed link) as the primary flow;
`signInWithPassword` offered behind a collapsed "IKIO staff" panel;
staff can set their own password from the header.

**Alternatives:** a shared unauthenticated link per vendor with a
signed token in the URL; passwords for everyone.

**Why this won:** RLS needs `auth.uid()`, so a genuine identity is
required — a bare link would have meant hand-rolling a token system and
would have made the audit trail meaningless ("who submitted this bank
account" would answer "whoever held the link"). Passwords for ~500
external companies would have generated a reset-support burden with no
benefit. Staff are a handful of known colleagues, so a password is
reasonable and keeps the mailer off the critical path for the people who
administer the portal.

**Cost:** every vendor sign-in depends on e-mail delivery. Links are
single-use and expire, and Brevo's free tier can be slow — which was
mistaken for a broken login once.

**Status:** settled. A 6-digit code (`verifyOtp`) was proposed when a
corporate sign-in appeared to fail, then **dropped** once that turned
out to be mail delay rather than a fault. Not built, not needed.

---

## 4. Banking data: separate table, no grants, audited reveal

**Decided:** `vendor_bank_details` in its own table with SELECT, INSERT,
UPDATE and DELETE revoked from every role. All access via SECURITY
DEFINER functions; `staff_reveal_bank_details()` writes the audit row
*before* returning, so a failed audit rolls back the disclosure.

**Alternatives:** banking columns on `vendors` with RLS; Supabase
Transparent Column Encryption (pgsodium).

**Why this won:** RLS still requires *some* role to hold SELECT, so a
policy bug exposes the column. Revoking the privilege entirely means
there is no policy to get wrong. Column encryption was rejected because
Supabase advises against pgsodium TCE on their platform — disk
encryption is already on, anyone with dashboard access holds the keys
anyway, and it breaks filtering and constraints.

**Cost:** every read is a function call, and the masked tail needs a
separate helper (`bank_mask()`), which caused a real outage when the
view joined the table directly.

**Status:** superseded in principle by decision 5 — the table is due to
be dropped entirely.

---

## 5. PORTAL_BANK_MODE as a switch, not a one-way migration

**Decided:** three modes — `"supabase"`, `"worker"`, `"off"` — selected
by one line in `config.js`. **Currently `"supabase"`.**

> The brief for this file said the mode is `"off"`. It is not; it is
> `"supabase"`, verified in `live/config.js`. Banking data is still
> being stored in Supabase today.

**Alternatives:** apply `fix-07` immediately and force the portal into a
no-banking state; leave everything as it was and change nothing until
SAP is ready.

**Why this won:** management ruled that vendor banking must not sit in a
third-party cloud database, but SAP access and its API contract are
pending departmental discussion — months, not days. A one-way migration
would have broken the banking step on the deployed site with no
replacement. A switch keeps the portal working now and reduces the
eventual cutover to one line plus a migration.

The first attempt at this *was* a one-way migration; it was rebuilt as a
switch once the SAP timeline became clear.

**Cost:** three code paths where there could be one, and a live system
that is knowingly non-compliant with the stated rule until the gate in
`STATUS.md` is executed. That is acceptable only while the data is mock
and the TEST ENVIRONMENT banner is up.

**Status:** deliberately temporary. The gate is: set mode, set
`PORTAL_ALLOW_BANK_DOCUMENTS = false`, redeploy, purge Storage, then run
`fix-07` — in that order.

---

## 6. Worker mode fails closed

**Decided:** `bankViaWorker()` returns false when `PORTAL_WORKER_URL` is
empty, disabling capture rather than falling back to Supabase.

**Why:** a silent fallback would mean a misconfiguration quietly writes
account numbers to exactly the place the whole exercise is removing them
from. Failing closed makes the failure obvious instead of invisible.

**Cost:** a misconfigured deploy stops collecting banking with no loud
error — the fields simply aren't rendered.

**Status:** settled. Verified by test across all four mode/URL
combinations.

---

## 7. SAP's statelessness mismatch — decided in principle only

**The problem:** Cloudflare Workers are stateless and start fresh per
request. SAP B1's Service Layer is stateful — you log in, receive a
session, and reuse it.

**Options identified:** log in on every request (simple, slow, consumes
a licence slot per call); or cache the session in Cloudflare KV with
refresh-on-expiry (correct, more code).

**Status: NOT DECIDED.** This was analysed, not settled. No Worker code
exists. The choice depends on how SAP licensing counts concurrent
sessions in IKIO's configuration, which is an open question for the SAP
team. Do not treat either option as chosen.

Related and also undecided: whether vendors should be created in SAP as
drafts under an approval procedure or written directly. If direct, the
portal's approve step and SAP's approval process duplicate each other
and one must be made authoritative.

---

## 8. Data model shape: workflow in Supabase, financial truth in SAP

**Decided:** `vendors` holds identity, address, commercial terms,
contacts, statutory IDs and workflow state. Banking is a pointer
(`sap_draft_id`, `sap_link_state`) once fix-07 lands.

**Alternatives:** one wide table including banking; separate vendor
profile and submission tables with versioning.

**Why this won:** SAP is already the system of record for vendor master
data. A second copy of banking means two systems to secure and audit and
a reconciliation problem when they disagree. The strongest argument
against storing it in Supabase was never that Supabase is unsafe — it is
that the duplicate was unnecessary.

**Cost:** no history. `vendors` is updated in place, so there is no
record of what a field held before an edit; only `audit_log` shows that
*something* changed. If field-level history is ever needed it must be
added.

**Status:** settled in shape. `sap_link_state` exists specifically so a
SAP hand-off that fails halfway is findable rather than silently
orphaned.

---

## 9. Roles in their own table, one role per person

**Decided:** `user_roles` with `user_id` as primary key — so exactly one
role each — and `revoke all` from every API role.

**Alternatives:** roles in `auth.users.raw_user_meta_data`; multiple
roles per user.

**Why this won:** user metadata is editable by the user holding the anon
key, so a vendor could promote themselves. One role per person makes
separation of duties enforceable: an approver is definitionally not a
checker.

**Cost:** an approver **cannot check**. Two approvers and no checker
means nothing moves past `submitted` — this has already bitten during
setup and is easy to hit again.

**Status:** settled. The constraint is the point, not a limitation.

---

## 10. Invitation-only, no self-signup

**Decided:** vendors and staff both arrive by invitation.
`claim_invitation()` and `claim_staff_role()` match on the e-mail the
user has just proved they control.

**Why:** for a known list of ~500 suppliers, open signup is a liability
with no upside. It also removes the ordering problem — a role or
registration can be prepared before the person has an account.

**Cost:** an uninvited person sees "No invitation found", which reads as
an error the first time staff encounter it.

**Status:** settled.

---

## 11. Payment execution stays out of the portal

**Decided:** the portal verifies vendor master data. SAP Business One
and the bank execute payments.

**Alternatives raised and rejected:** Stripe integration; portal-driven
payouts.

**Why this won:** Stripe collects from customers; this is disbursement
to domestic suppliers, a different rail entirely. More importantly,
wiring payment into the portal would remove the maker-checker step that
currently sits between vendor-submitted data and money moving — which is
precisely the control that catches bank-detail fraud.

**Status:** settled and worth defending if raised again.

---

## 12. Deliberately simpler choices

- **Print-to-PDF, not PDF generation.** The signed VRF uses
  `window.print()` with a print stylesheet, not a PDF library. The
  printed page carries exactly what is in the database, so the signed
  document cannot disagree with the record.
- **`serve.py` instead of `python -m http.server`.** Written only
  because the built-in binds all interfaces (exposing the folder to the
  LAN) and permits caching (edits appearing not to take effect). Both
  problems occurred before this existed.
- **Migration ledger in the database.** `_migrations` +
  `list_applied_migrations()` exists because "which migrations are
  applied" was twice answered wrongly by probing RPCs — a wrong argument
  shape returns `PGRST202`, identical to "function missing". The ledger
  is queryable with only the anon key.
- **Name auto-capitalisation is narrow on purpose.** Applied to contact
  names and city only, and only when the text is entirely one case.
  Deliberately **not** applied to Beneficiary Name, which must match the
  bank's record character-for-character, nor to Company Name, where
  IKIO, LLP and 3M all lose meaning.
- **No test suite.** Verification is `TEST_PLAN.md` plus browser checks.
  For a single-file app with no build step, a runner was judged more
  overhead than value. This is a real trade, not an oversight.

---

# Deliberate vs debt

## Looks wrong, is intentional

- **One 1,800-line HTML file.** No framework, no modules. Intentional
  given the scope; see decision 1.
- **Two RLS policies on `vendor_bank_details` that can never fire.**
  Privileges are revoked, so the policies are unreachable. Kept as a
  second layer if privileges are ever re-granted by mistake.
- **`vendor_overview` doesn't join the bank table.** It must not — the
  view is `security_invoker = true`, and joining a table nobody can
  SELECT breaks the view for everyone. The masked tail comes from
  `bank_mask()` instead. This caused a real outage.
- **`syncFromDom()` re-reads the DOM instead of trusting change
  events.** Because an untouched `<select>` shows its first option while
  holding no JS value — Country displayed "India" and saved empty,
  silently classifying Indian vendors as overseas.
- **Per-step saves via `STEP_COLS`.** Saving all columns meant a
  half-typed PAN on step 2 blocked saving step 1 with a constraint error
  about an off-screen field.
- **Buttons disabled in the UI *and* rules enforced in SQL.** The UI
  state is convenience; the database is the control. Not duplication.
- **`schema.sql` overlaps the `fix-*.sql` files.** It is the
  consolidated current state for a fresh install; the fix files are the
  incremental history. Both are needed.

## Genuinely unfinished

- **The Cloudflare Worker does not exist.** `sendBankToSap()` and the
  worker branch of the reveal handler call an endpoint that has never
  been built. Disabled by config, so nothing is broken — but the code
  path is dead.
- **`fix-07` is written and unapplied.** Its four functions do not exist
  in the live database.
- **No index on `vendors.allocated_staff_id`** despite it being in the
  RLS policy on every staff queue read. Fine at 500 rows; see
  `DATA_MODEL.md` risks.
- **Document upload never exercised end to end** with a real file.
- **The leak test in `TEST_PLAN.md` has never been run against the
  deployed site**, only against the API directly.
- **`initiator` role is defined in the `user_roles` CHECK constraint and
  used nowhere.** Left over from mirroring the paper form's
  Initiated/Checked/Approved sign-offs.
- **`LOVABLE_PROMPT.md` describes an abandoned approach.** Kept as a
  record; it documents nothing that exists.
- **Storage cleanup is manual.** `fix-07` deletes `vendor_documents`
  rows but not the files in the bucket — deleting metadata leaves the
  images behind.
