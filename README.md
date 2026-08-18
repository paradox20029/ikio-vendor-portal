# Vendor Registration Portal — build kit

Everything lives in `C:\IKIO\vendor-portal`. Nothing here depends on any
other folder.

Two things sit side by side here, and it matters which you are looking at:

| | What it is |
|---|---|
| `demo.html` | **Mockup.** Runs anywhere with no setup, invented data, everything in one browser. For showing people the flow. |
| `live/` | **The real portal.** Real accounts, real database, real access control. Needs a Supabase project — see `SETUP.md`. This folder is what gets deployed, so keep only `index.html` and `config.js` in it. |

The mockup cannot be made shareable by hosting it: its data never leaves the
browser it was typed into, so two people opening the same page never see each
other's work. `live/` is the version that produces a link you can send.

## Start here: `demo.html`

Double-click it. No install, no server, no accounts. It runs entirely in the
browser and stores data in that browser only, so it is safe to hand round.

**Or serve it**, which is better for anything longer than a quick look —
some browsers block storage on `file://` pages, so served over HTTP your
clicks survive a refresh. From this folder:

```
python serve.py
```

It prints both URLs and stops with Ctrl+C:

- mockup — <http://localhost:8030/demo.html>
- live portal — <http://localhost:8030/live/index.html>

Use `serve.py` rather than `python -m http.server`. The built-in one listens
on every network interface, which puts this folder on your LAN, and it lets
browsers cache pages so edits appear not to take effect. `serve.py` binds
localhost only and sends no-cache headers.

Use the **View as** dropdown in the dark bar at the top to switch between the
vendor's view and three staff views — that bar is a demo device and would not
exist in the real system. **Reset demo data** puts everything back.

The three staff personas exist to make allocation visible. S. Rao owns two
vendors, A. Iyer owns one, and You (approver) sees all four. Switching between
them is the fastest way to show that a submission reaches its allocated owner
and nobody else.

What it demonstrates end to end: the three-step vendor form with live
validation, drafts, the India-versus-overseas field split, submission
freezing the record, the staff queue with bank details masked, reveal-and-log,
and the Checked → Approved sign-off chain including the rule that one person
cannot do both.

### Changing fields as details arrive

Everything is in `demo.html`, and the pieces you will want are near the top:

| To change | Edit |
|---|---|
| Dropdown options | `CURRENCIES`, `INCO`, `COUNTRIES` constants |
| The example vendors | the `seed()` function |
| Format rules | the `RX` object, and `RX_MSG` for the message shown |
| Add or remove a form field | the `field(...)` calls inside `renderVendor()` |
| Which fields are mandatory | the arrays inside `validate()` |
| What staff see in the list | `queueHTML()` |

Keep `schema.sql` in step with the demo as fields settle — the demo is the
conversation piece, the schema is what actually gets built.

---

## When the requirements settle: the real build

Three files, run in this order.

1. **`LOVABLE_PROMPT.md`** — the prompts to paste into Lovable. Prompt 1
   scaffolds the app.
2. **`schema.sql`** — paste into the Supabase SQL editor and run. This
   replaces whatever tables Lovable generated. Ours carry the security model.
3. **`LOVABLE_PROMPT.md`, prompts 2–3** — wires the UI to the real schema.
4. **`TEST_PLAN.md`** — mock vendor data for staff, plus the leak test.

## Connecting Lovable to Claude Code

The MCP server is already registered in this project. It needs a browser
login, which has to happen in an interactive terminal:

```bash
claude mcp login lovable
```

Then in a normal `claude` session, Lovable's tools are available directly.

## What the schema does that Lovable won't

- Roles live in `user_roles`, not user metadata. A vendor holding the public
  anon key can edit their own metadata; they cannot touch this table.
- Bank details sit in their own table with **no select policy at all**. Not
  for vendors, not for admins. Reads happen only through
  `admin_reveal_bank_details()`, which checks the caller's role and writes an
  audit row before returning — and rolls back the whole call if the audit
  write fails.
- Submitted registrations freeze. Vendors can edit drafts only.
- `audit_log` is append-only; no update or delete path exists through the API.
- Every security-definer function pins `search_path`, so a caller can't
  shadow `public` with their own schema and hijack the function body.

## Matched to your existing form

Fields, order and wording follow the `VRF ISPL` paper form — including the
things that would have been missed by guessing: two separate contacts (Sales
and Finance & Accounts), TAN alongside PAN, Payment/Order-Currency/INCO terms,
and the MSMED declaration with its mandatory certificate attachment.

The form's `Initiated By / Checked By / Approved By` sign-off block is
implemented as real separation of duties, not decoration: a checker must check
before an approver can approve, and the same person cannot do both. That rule
lives in the database, so the UI cannot bypass it.

Country drives the statutory fields. Indian vendors need PAN, GSTIN and IFSC;
overseas vendors need SWIFT and are not asked for any of them. The paper form
has Country and Order Currency but no overseas path — worth confirming with
whoever owns onboarding whether foreign vendors are in scope.

## What this deliberately does not do

No column encryption. Supabase advises against pgsodium-based Transparent
Column Encryption on their platform — disk encryption is already on, and
anyone with dashboard access holds the keys anyway, so it buys little while
breaking filtering and constraints. The protection here is access control
plus a truthful audit trail.

No payment execution. The portal verifies vendor master data; Business One
and the bank execute payments, where the mandate, approval limits and
maker-checker already live.

## Still open

- The upload-vs-form question is answered: it is both. The VRF makes the
  MSMED certificate a required attachment, so `vendor_documents` and the
  private `vendor-docs` bucket are built in from the start rather than
  retrofitted. Optional slots exist for GST certificate, PAN card, cancelled
  cheque and the signed VRF.
- Whether a signed-and-stamped VRF is still needed on top of a portal
  submission is a policy call, not a technical one.
- Custom SMTP. Required before inviting anyone at volume.
- DPDP Act obligations apply to you as the collecting entity. Worth a
  conversation with whoever owns compliance before go-live, not after.
