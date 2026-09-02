# FRONTEND

Everything lives in `live/index.html` (~1,810 lines) plus
`live/config.js`. One `<script type="module">` from line 176. No
framework, no build step, no router, no bundler. Names and line numbers
read from the file on 2026-09-02; line numbers drift, names do not.

---

## "Routes"

There are none. One URL, one `<main id="app">`, and functions that
replace `app.innerHTML`. Navigation is a function call, not a URL
change — the address bar never changes, and **there is no deep linking,
no browser back, and a refresh always returns to the top of whichever
view your role implies.**

| View | Rendered by | Who reaches it |
|---|---|---|
| Sign in | `renderLogin()` (503) | anyone with no session |
| Vendor form, 3 steps | `renderVendor()` (684) | signed-in vendor whose registration is `draft` |
| Vendor read-only status | `renderVendorSubmitted()` (1122) | vendor once status ≠ `draft` |
| "No invitation found" | inline in `startVendor()` (590) | signed-in user with neither a role nor an invitation |
| Staff shell + tabs | `renderStaff()` (1266) | anyone with a row in `user_roles` |
| → Registrations | `renderQueue()` (1434) | all staff |
| → Registration detail | `renderDetail()` (1460) | all staff |
| → Invite (forms) | `renderInvite()` (1598) | all staff; colleague form is approver-only |
| → Invitations (lists) | `renderInvitationLists()` (1666) | all staff |
| → Access log | `renderAudit()` (1807) | all staff |
| → Staff | `renderStaffAdmin()` (1347) | approvers only |

Gating is `ME.isStaff` / `ME.isApprover` / `ME.isViewer`, set once in
`boot()`. **This is presentation only** — the database re-checks every
call, so hiding a tab is convenience, not a control.

---

## Components

No component system. Reuse happens through functions that return HTML
strings.

| Function | Line | Purpose | Used by |
|---|---|---|---|
| `field(v, key, label, opts)` | 645 | Renders one labelled input/select/textarea with `data-k="<column>"`, error slot, and a span class. `opts`: `req, full, span, options, blank, upper, type, ph, hint, bank` | every form field in `renderVendor()` |
| `summaryHTML(v, bankView)` | 1215 | Read-only `<dl>` of a whole registration | vendor step 3, `renderVendorSubmitted()`, `renderDetail()` |
| `showDialog(html, after)` | 319 | Modal via `<dialog>`; `after` wires buttons after injection | submit confirm, remarks prompts, delete confirms, approver-grant confirm, set-password |
| `askRemarks(title, cb, required)` | 1580 | Remarks modal wrapping `showDialog` | check / approve / reject / reopen in `renderDetail()` |
| `toast(msg, ms)` | 266 | Transient bottom message | everywhere |
| `busy(msg)` | 326 | Spinner placeholder | `boot()`, `startVendor()` |
| `bindInvitationActions(body)` | 1726 | Wires resend / copy / delete on both invitation tables | `renderInvitationLists()` |
| `slot(type, label, hint)` | inline in `renderVendor()` step 3 | One document upload slot | the 5 document slots |

`field()` is the only genuine abstraction; the rest are helpers.

---

## State

**Module-scope mutable globals.** No store, no reactivity — every change
is followed by a manual re-render call.

| Variable | Line | Kind | Contents |
|---|---|---|---|
| `sb` | 196 | client | Supabase client |
| `SESSION` | 383 | server | session from `getSession()` |
| `ME` | 383 | derived server | `{email, isStaff, isApprover, isViewer, staffId}` — roles fetched by RPC in `boot()` |
| `VENDOR` | 384 | server + local | the `vendors` row, **mutated in place** as the user types |
| `VENDOR.bank` | set in `startVendor()` | local only | never loaded from the server; write-only staging for banking |
| `BANK_MASK` | 384 | server | masked tail from `get_my_bank_last4()`, only in `supabase` bank mode |
| `VENDOR.docs` | `startVendor()` | server | from `vendor_documents` |
| `step` | 575 | local | 1–3 |
| `staffTab` | 1264 | local | `queue`/`invite`/`invitations`/`audit`/`staff` |
| `openId` | 1264 | local | which vendor's detail is open |
| `revealCache` | 1264 | server, per-view | revealed bank details, **memory only** — deliberately never persisted, and cleared on reload |

`VENDOR` blurs server and local state: it starts as a server row and
accumulates unsaved edits, with no dirty tracking. Whether an edit has
been persisted is only knowable by whether `saveStep()` has run.

There is **no caching layer**. Every render re-queries.

---

## Backend calls

Every one, what it expects back.

### Auth (`sb.auth.*`)
| Call | Where | Expects |
|---|---|---|
| `getSession()` | `boot()` 392, `sendBankToSap()` 1164, reveal handler | `{data:{session}}`, session possibly null |
| `signInWithOtp({email, options:{emailRedirectTo}})` | `renderLogin()` `go()` | `{error}`; success = mail queued, **not** delivered |
| `signInWithPassword({email, password})` | `renderLogin()` `pwdGo()` | `{error}`; then `location.reload()` |
| `updateUser({password})` | set-password dialog in `boot()` | `{error}` |
| `signOut()` | `#out` handler | then `location.reload()` |
| `onAuthStateChange(cb)` | after `boot()` | fires `SIGNED_IN`; calls `boot()` only if `SESSION` was null |

### Tables (`sb.from(...)`)
| Call | Where | Expects |
|---|---|---|
| `.from("vendors").select("*").limit(1)` | `startVendor()` | 0 or 1 row — RLS guarantees at most own |
| `.from("vendors").update(patch).eq("id",...)` | `saveStep()` | `{error}`; RLS blocks non-draft |
| `.from("vendor_documents").select(...).eq("vendor_id",...)` | `startVendor()` | array |
| `.from("vendor_documents").insert({...})` | `uploadDoc()` | `{error}` |
| `.from("vendor_overview").select("*").neq("status","draft").order(...)` | `renderQueue()` | array, RLS-filtered by role |
| `.from("vendor_overview").select("*").eq("id",openId).single()` | `renderDetail()` | one row |
| `.from("vendor_invitations").select("*").order(...)` | `renderInvitationLists()` | array |
| `.from("audit_log").select("*").order("at",{ascending:false}).limit(200)` | `renderAudit()` | array |

### RPC (`sb.rpc(...)`)
`is_staff`, `has_role`, `claim_staff_role`, `claim_invitation`,
`get_my_bank_last4`, `save_bank_details`, `submit_registration`,
`staff_reveal_bank_details`, `advance_status`, `create_invitation`,
`delete_invitation`, `invite_staff`, `list_staff`, `list_staff_detail`,
`list_staff_invitations`, `delete_staff_invitation`, `grant_staff_role`,
`revoke_staff_role`.

All return `{data, error}`. **Business rules arrive as `error.message`
strings** — "Only a checker may check a registration", "The same person
cannot both check and approve a vendor" — and are shown verbatim. They
are written for the end user, not for a log.

### Storage
`sb.storage.from("vendor-docs").upload(path, file)` in `uploadDoc()`.
Path **must** start `<VENDOR.id>/` or the storage policy rejects it.

### Non-Supabase HTTP
Two raw `fetch()` calls, both to the **unbuilt** Cloudflare Worker and
both dead while `PORTAL_BANK_MODE ≠ "worker"`:
- `POST {PORTAL_WORKER_URL}/api/vendor/{id}/bank-draft` — `sendBankToSap()` (1164)
- `GET {PORTAL_WORKER_URL}/api/vendor/{id}/bank-details` — reveal handler in `renderDetail()`

Both send `Authorization: Bearer <session.access_token>`; the POST also
sends `Idempotency-Key: VENDOR.id`.

---

## Forms and validation

### Sign-in form (`renderLogin()`)
Fields: `#loginEmail`, and a collapsed staff panel (`#showPwd` toggles
`#pwdBox`) with `#loginPwd`.

Validation is one regex on the address, client-side only. Submitting via
`#sendLink` or Enter calls the `go()` closure → `signInWithOtp`. Success
replaces the view with a "Check your inbox" card. **No 6-digit code
exists** — no `verifyOtp`, no token field anywhere in the codebase.
Sign-in is a clickable magic link only.

### Vendor form (`renderVendor()`, 3 steps)
Validation is two-layered and the layers do different jobs.

**Client (`validateStep()` 938)** — per-step only. Step 1: required
fields plus e-mail regexes. Step 2: `RX.pan_no`, `RX.gstin_no`,
`RX.tan_no`, `RX.ifsc_code`/`RX.swift_code` by country,
`RX.account_number`, and the re-typed account must match. Failure calls
`markBad(key)` (932), which adds `.bad` and scrolls the field into view.
Skipped entirely when `bankCaptureEnabled()` is false.

**Server** — CHECK constraints, plus `submit_registration()` re-checking
completeness. `fail()` (305) maps constraint names to readable messages
via `CONSTRAINT_MSG` and appends `errDetail()` (298), which separates
`PGRST202` (missing function → unapplied migration) from `42501`
(privilege denied).

Three non-obvious pieces:

- **`syncFromDom()` (1011)** reads every `[data-k]` element's `.value`
  from the DOM at save time rather than trusting `input` events. An
  untouched `<select>` displays its first option while holding no JS
  value — Country showed "India" and saved empty.
- **`STEP_COLS` (1025)** limits each save to that step's columns.
  Sending all of them meant a half-typed PAN on step 2 blocked saving
  step 1.
- **`tidyName()` / `titleCase()` (994, 1002)** title-case on blur, but
  only for `NAME_FIELDS` (`contact_sales`, `contact_finance`, `city`)
  and only when the text is entirely one case. Deliberately excludes
  Beneficiary Name, which must match the bank's record exactly.

Save path: `saveStep()` → `syncFromDom()` → `validateStep()` → build
patch → `update` → banking branch. Steps advance only on success. Step
chips are clickable: backwards saves a draft first, forwards validates
each intervening step.

---

## Client-side auth

- **Storage**: entirely supabase-js. The app never reads or writes a
  token itself; it calls `getSession()` when it needs one.
- **Refresh**: automatic inside supabase-js. There is **no explicit
  refresh handling, and no reaction to expiry** beyond `sendBankToSap()`
  and the reveal handler checking for a null session and returning a
  "session has expired" error.
- **Checking**: roles are fetched **once**, in `boot()`, into `ME`. They
  are not re-checked afterwards. A role changed mid-session is not seen
  until sign-out and back in — this has caused real confusion.
- **Establishment**: the magic link returns with tokens in the URL;
  supabase-js consumes them; `onAuthStateChange` fires `SIGNED_IN` and
  re-runs `boot()` if `SESSION` was null.
- **Redirect target**: `portalUrl()` (339) — `PORTAL_URL` if set, else
  current origin minus fragment. The address must also be on Supabase's
  Redirect URLs allow-list or Supabase silently substitutes the Site URL.

---

## Shared utilities

| Function | Line | Does |
|---|---|---|
| `esc(s)` | ~250 | HTML-escapes `& < > "`. **The only XSS defence** — everything is built with template strings and `innerHTML` |
| `fmtDate(s)` | ~252 | `en-IN` medium date + short time |
| `isIndia(v)` | ~254 | lowercase compare on `country`; drives every conditional field |
| `toast`, `fail`, `errDetail`, `showDialog`, `busy` | 266–326 | user feedback |
| `portalUrl()`, `onLocalhost()` | 339, 343 | redirect target; localhost warning banner |
| `emailSignInLink(email)` | 359 | wraps `signInWithOtp`; maps 502/503/504 to an SMTP-settings hint and 429 to a rate-limit message |
| `bankMode()`, `bankViaSupabase()`, `bankViaWorker()`, `bankCaptureEnabled()`, `bankDocsAllowed()` | 1148–1158 | the only readers of the banking config flags |
| `titleCase`, `tidyName`, `syncFromDom` | 994–1011 | input normalisation |
| `markBad(key)` | 932 | validation error styling + scroll |
| `vendorBankView()` | 1200 | assembles what the vendor is allowed to see of their own banking — masked only |

### Styling
One `<style>` block. Six-column grid with `.c2` / `.c3` / `.full` spans,
collapsing at 820px and 560px. A `@media print` block strips chrome for
the signed VRF and reveals `.sign`. CSS custom properties for colour.
No CSS framework.
