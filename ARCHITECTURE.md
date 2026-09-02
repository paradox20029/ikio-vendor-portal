# ARCHITECTURE

Written 2026-09-02 by reading the files, not from memory. Line numbers
are as of that date and will drift; function and file names are stable.

## The shape of it in one paragraph

A static single-page app talks directly to Supabase over HTTPS. There is
no application server, no build step and no framework. Every rule that
matters — validation, authorisation, workflow transitions, audit — lives
in Postgres functions, and the browser calls them by name. A Cloudflare
Worker and an SAP Business One integration are designed and partly
wired, but **not built**; the code path for them exists and is disabled
by config.

## Directory layout

```
vendor-portal/
├── live/                    ← the ONLY folder that gets deployed
│   ├── index.html           the entire application (~1810 lines)
│   ├── config.js            runtime config, loaded before index.html's module
│   └── logo.png
├── schema.sql               consolidated current schema, safe to run whole
├── fix-01…fix-07*.sql       migrations, applied in numeric order
├── admin-queries.sql        operational SQL, not part of the schema
├── demo.html                standalone mockup, localStorage only, no backend
├── serve.py                 local dev server
├── CLAUDE.md STATUS.md HANDOFF.md ARCHITECTURE.md
├── SETUP.md DEMO.md TEST_PLAN.md ACTION_ITEMS.md CONCEPTS.md
├── README.md LOVABLE_PROMPT.md
└── .gitignore
```

Anything placed in `live/` becomes publicly downloadable when deployed.
Everything else in the repo is documentation and SQL that is never
served.

## Components

### `live/index.html` — the entire front end
One file. One `<script type="module">` starting at line 176, importing
`createClient` from `https://esm.sh/@supabase/supabase-js@2`.

**Owns:** all rendering, form state, client-side validation (`RX`
regexes, `validateStep()`), routing between vendor and staff views
(`boot()`), and every call to Supabase.

**Does NOT own:** authorisation (Postgres decides), data integrity
(Postgres constraints decide), audit (Postgres writes it), session
management (supabase-js owns it), or configuration (`config.js` owns it).

Module-scope state, all of it:

| Name | Line | Holds |
|---|---|---|
| `sb` | 196 | the Supabase client |
| `app` | 182 | the `<main>` element everything renders into |
| `SESSION`, `ME` | 383 | current session; `{email, isStaff, isApprover, isViewer, staffId}` |
| `VENDOR`, `BANK_MASK` | 384 | the loaded vendor row; masked account tail |
| `step` | 575 | which of the 3 vendor form steps is showing |
| `staffTab`, `openId`, `revealCache` | 1264 | staff view state |

There are no classes, no modules, no imports beyond supabase-js. All
functions are top-level in one scope.

### `live/config.js` — configuration
Plain script, loaded at line 7, **before** the module. Sets eight
`window.*` globals. No logic.

### Supabase — the actual backend
Postgres + Auth + Storage. Owns identity, RBAC, workflow state, audit,
document metadata, and (currently) banking data.

**Owns:** every authorisation decision, via RLS policies and 25
SECURITY DEFINER functions.

**Does NOT own:** rendering, e-mail delivery (Brevo does, configured in
the dashboard, invisible to this repo), or hosting.

### `serve.py` — local dev only
Binds `127.0.0.1` explicitly and sends no-cache headers. Never deployed.
Exists because `python -m http.server` binds all interfaces and permits
caching, both of which caused real problems.

### `demo.html` — mockup, not part of the system
Self-contained, `localStorage` only, no Supabase, no network. Used for
showing the flow without a backend. Shares no code with `live/`.

### Cloudflare Worker — DOES NOT EXIST
No `worker/`, `wrangler.toml` or `src/` in the repo; verified. The
client half is written (`sendBankToSap()`), the database half is written
(`fix-07`, unapplied), and both are disabled by config.

## How components talk

| From → To | Mechanism | Where |
|---|---|---|
| `config.js` → module | `window.*` globals, read at call time not import time | `window.PORTAL_BANK_MODE` etc. |
| Browser → Postgres tables | HTTPS to PostgREST via `sb.from(...).select/insert/update()` | e.g. `saveStep()` |
| Browser → Postgres functions | HTTPS RPC via `sb.rpc("name", {p_args})` | e.g. `boot()` calling `is_staff` |
| Browser → Supabase Auth | supabase-js: `signInWithOtp`, `signInWithPassword`, `getSession`, `updateUser`, `signOut` | `renderLogin()`, `boot()` |
| Browser → Supabase Storage | `sb.storage.from("vendor-docs").upload(path, file)` | `uploadDoc()` |
| Auth → app | event callback: `sb.auth.onAuthStateChange` | near `boot()` |
| Browser → Worker | raw `fetch()` with `Authorization: Bearer <access_token>` | `sendBankToSap()`, and the reveal branch in `renderDetail()` |
| Within the front end | direct function calls only | no event bus, no pub/sub |
| Postgres → Postgres | `perform public.write_audit(...)` inside other functions | e.g. `submit_registration()` |

There are **no** WebSockets, no Supabase Realtime subscriptions
(verified: zero `.channel(` or `.subscribe(` in the codebase), and no
polling.

## External boundaries

| Boundary | Owned by | Mechanism | Notes |
|---|---|---|---|
| Supabase Postgres | `live/index.html` via `sb` | HTTPS / PostgREST | anon key only |
| Supabase Auth | `live/index.html` via `sb.auth` | HTTPS | sessions held by supabase-js in browser storage |
| Supabase Storage | `uploadDoc()` | HTTPS | one bucket, `vendor-docs`, private |
| Brevo SMTP | **Supabase**, not this repo | configured in dashboard | the app never talks to Brevo; it asks Supabase to send |
| Netlify | nothing in code | manual drag of `live/` | no CI, no deploy hook |
| Cloudflare Worker | `sendBankToSap()` and the reveal branch of `renderDetail()` | `fetch()` | **not built** |
| SAP B1 Service Layer | the Worker, when it exists | OData/REST, typically port 50000, via Cloudflare Tunnel | **nothing in this repo talks to SAP** |
| esm.sh CDN | the module import | `import` at line 177 | third-party runtime dependency; no vendored copy |

## Config flags — read at these points

All are `window.*`, read lazily so a value can change behaviour without
a reload in some cases.

| Flag | Read in | Effect |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | line ~190, then `createClient` at 196 | which project; guarded — if unset the app renders a "Not configured yet" card and throws |
| `PORTAL_ORG` | after client init | header subtitle text only |
| `PORTAL_TEST_MODE` | after client init | shows the yellow test banner |
| `PORTAL_URL` | `portalUrl()` (339) | `emailRedirectTo` for magic links; empty = current origin |
| `PORTAL_BANK_MODE` | `bankMode()` (1148), via `bankViaSupabase()` / `bankViaWorker()` / `bankCaptureEnabled()` | routes banking to Supabase, to the Worker, or nowhere |
| `PORTAL_WORKER_URL` | `bankViaWorker()` (1150), `sendBankToSap()` (1164) | Worker endpoint; empty makes worker mode fail closed |
| `PORTAL_ALLOW_BANK_DOCUMENTS` | `bankDocsAllowed()` (1158) | shows/hides the cancelled-cheque upload slot |

---

# Flow traces

## (a) Vendor sign-in

**The 6-digit code does not exist.** Verified: no `verifyOtp`, no
`{{ .Token }}`, no numeric-code entry anywhere in the codebase. Sign-in
is a clickable magic link. If it is ever added, the hooks are
`renderLogin()` for the entry field and `sb.auth.verifyOtp({email,
token, type:'email'})` for the exchange — neither is written.

Actual flow:

1. **`live/config.js`** loads (`<script src>` line 7), setting
   `window.SUPABASE_*`.
2. **`live/index.html` module** runs. Reads `URL_`/`KEY_`; if either is
   the placeholder, renders "Not configured yet" and throws (line ~193).
   Otherwise `createClient(URL_, KEY_)` → `sb` (196).
3. **`boot()`** (392) — `sb.auth.getSession()`. No session, so it clears
   the header's `#who` block and calls `renderLogin()`.
4. **`renderLogin()`** (503) paints the form: an e-mail field
   (`#loginEmail`), a primary button (`#sendLink`), and a collapsed
   staff-only password panel (`#showPwd` → `#pwdBox`).
5. User submits → the local `go()` closure inside `renderLogin()`
   validates the address with a regex, then calls
   **`sb.auth.signInWithOtp({ email, options:{ emailRedirectTo:
   portalUrl() } })`**.
6. **`portalUrl()`** (339) returns `window.PORTAL_URL` if set, else
   `location.href` minus any `#fragment`.
7. Supabase sends the mail **through Brevo** using SMTP settings held in
   the Supabase dashboard. Nothing in this repo touches Brevo.
8. User clicks the link → browser returns to the portal with auth
   tokens in the URL. supabase-js consumes them and establishes a
   session. `sb.auth.onAuthStateChange` (registered just after `boot()`)
   fires `SIGNED_IN` and calls `boot()` again if `SESSION` was null.
9. **`boot()`** now has a session. Sets `ME.email`, `ME.staffId`, shows
   `busy("Signing you in…")`.
10. `await sb.rpc("claim_staff_role")` — attaches a pending colleague
    invitation if one matches this e-mail; a harmless no-op otherwise.
11. `Promise.all([sb.rpc("is_staff"), sb.rpc("has_role",
    {p_role:"approver"}), sb.rpc("has_role", {p_role:"viewer"})])` →
    sets `ME.isStaff`, `ME.isApprover`, `ME.isViewer`.
12. Renders the header (`#who`), wires `#out` (sign out) and, for staff,
    `#setpw` (`sb.auth.updateUser({password})`).
13. Branches: `isStaffRole(ROLE)`-equivalent check → **`renderStaff()`**
    (1266) for staff, otherwise **`startVendor()`** (590).
14. **`startVendor()`** calls `sb.rpc("claim_invitation")`, then
    `sb.from("vendors").select("*").limit(1)`. RLS returns at most the
    caller's own row. No row → "No invitation found" card. Row → seeds
    `VENDOR`, defaults the three dropdowns, loads `BANK_MASK` via
    `get_my_bank_last4` **only if `bankViaSupabase()`**, loads
    `vendor_documents`, sets `step = 1`, calls `renderVendor()`.

**Alternate path — staff password:** the `pwdGo()` closure in
`renderLogin()` calls `sb.auth.signInWithPassword({email, password})`
then `location.reload()`.

## (b) A write that lands in Supabase — vendor saves step 1

1. **`renderVendor()`** (684) painted the step-1 fields. Each input
   carries `data-k="<column>"`; `bindVendorInputs()` (857) attached
   `input` and `blur` handlers.
2. User clicks **Continue** → handler in `bindVendorInputs()` calls
   `saveStep()`.
3. **`saveStep()`** (1053) first calls **`syncFromDom()`** (1011), which
   reads every `[data-k]` element's `.value` straight from the DOM into
   `VENDOR`. This exists because an untouched `<select>` displays its
   first option while holding no JS value.
4. **`validateStep()`** (938) runs the step-1 rules — required fields,
   e-mail regexes. On failure it calls `markBad(key)` (932), which adds
   `.bad` to the wrapper and scrolls to it, and returns false.
5. `STEP_COLS[1]` (1025) selects the 19 columns step 1 owns. A `patch`
   object is built, `""` coerced to `null`. Other steps' columns are
   deliberately excluded — sending all columns meant a half-typed PAN on
   step 2 blocked saving step 1.
6. **`sb.from("vendors").update(patch).eq("id", v.id)`** — HTTPS PATCH
   to PostgREST.
7. Postgres applies RLS policy **`vendor_updates_draft`**:
   `user_id = auth.uid() AND status = 'draft'`. A submitted registration
   is frozen at this layer, not in the UI.
8. Column `CHECK` constraints (`gstin_format`, `pan_format`,
   `tan_format`, `pin_format`) run.
9. On error, **`fail(e)`** (305) maps known constraint names via
   `CONSTRAINT_MSG` to readable text and appends `errDetail(e)` (298),
   which distinguishes `PGRST202` (missing function → unapplied
   migration) from `42501` (privilege denied). `saveStep()` returns
   false and the step does not advance.

Banking, when `bankCaptureEnabled()`, is handled separately at the end
of `saveStep()` — either `sb.rpc("save_bank_details", {...})` or
`sendBankToSap()`, never a direct table write, because no role holds
privileges on `vendor_bank_details`.

**Document upload** is the other write shape: `uploadDoc()` (914)
uploads to Storage at path `<VENDOR.id>/<timestamp>-<filename>` — the
leading path segment is what the `vdocs_insert_own` storage policy keys
on — then inserts a row into `vendor_documents`. Two separate
operations; a Storage success followed by a metadata failure leaves an
orphaned file.

## (c) An SAP Service Layer call

**No SAP call exists.** Nothing in this repo talks to SAP. The client
half is written and disabled; the server half was never built. Traced to
the point where it stops:

1. `PORTAL_BANK_MODE` would need to be `"worker"` and
   `PORTAL_WORKER_URL` non-empty. Currently `"supabase"` and `""`, so
   `bankViaWorker()` (1150) returns false and none of the below runs.
2. **`saveStep()`** at step 2, banking present, `bankViaWorker()` true →
   calls **`sendBankToSap()`** (1164).
3. **`sendBankToSap()`** gets the session via `sb.auth.getSession()`,
   then `fetch()`s
   `POST {PORTAL_WORKER_URL}/api/vendor/{VENDOR.id}/bank-draft` with
   `Authorization: Bearer <access_token>`, `Idempotency-Key: VENDOR.id`,
   and a JSON body of the five banking fields. On success it blanks
   `VENDOR.bank` in memory immediately. On any failure it returns an
   `Error` and `saveStep()` refuses to advance.
4. **— BOUNDARY. Everything past here is unbuilt. —** The Worker would
   verify the Supabase JWT, check the caller's role server-side, call
   `sap_begin_link(vendor_id, idempotency_key)`, POST to the SAP B1
   Service Layer through Cloudflare Tunnel, then call
   `sap_complete_link(vendor_id, sap_draft_id)` and `write_audit_as(...)`
   using the **service_role** key. Those three functions are defined in
   `fix-07-remove-bank-storage.sql` and explicitly revoked from `anon`
   and `authenticated` — but **fix-07 has not been applied**, so they do
   not exist in the live database either.
5. The staff-side counterpart is the `on("reveal", ...)` handler inside
   **`renderDetail()`** (1460). In worker mode it `fetch()`es
   `GET {PORTAL_WORKER_URL}/api/vendor/{id}/bank-details`; otherwise it
   calls `sb.rpc("staff_reveal_bank_details", {p_vendor_id})`. Only the
   second branch works today.

The intended endpoints are listed in
`C:\IKIO\Hybrid_Cloudflare_SAP_Bypass_Architecture_Option_1.docx`
section 7. That document is outside this repo.

## Things that are not obvious from reading the code

- **The security boundary is not the front end.** Deleting
  `live/index.html` and calling PostgREST directly with the anon key
  changes nothing about what a user can reach. RLS and the SECURITY
  DEFINER functions are the control.
- **`schema.sql` is not applied incrementally.** It is the consolidated
  current state; `fix-NN` files are what actually get run in order. The
  live database's applied set is queryable via
  `list_applied_migrations()`, which is granted to `anon`.
- **`vendor_overview` must never join `vendor_bank_details`.** It is
  `security_invoker = true`, so a join to a table nobody holds SELECT on
  makes the whole view fail for everyone.
- **HTML comments inside the module blank the page.** Modules reject
  `<!--`. Use `//` or `/* */`.
