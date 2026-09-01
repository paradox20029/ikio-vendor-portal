# Action items and meeting prep

For the departmental discussions on SAP + Cloudflare integration.
Ordered so the cheapest question that could cancel the project gets
asked first.

---

## Part 1 — Ask this before booking any other meeting

**"Is the rule no third-party *storage*, or no third-party *processing*?"**

Put this to whoever set the policy — your manager, or compliance.

It matters because bank details will sit in Cloudflare Worker memory for
a few milliseconds while being forwarded to SAP. That is processing, not
storage.

- If the answer is **no storage** → the Cloudflare design is valid,
  proceed.
- If the answer is **no processing** → the design fails for exactly the
  same reason Supabase did, and the integration must run on-premise
  instead. Everything below about Cloudflare becomes irrelevant.

Do not spend three meetings on tunnel logistics before settling this.
It is one question and it decides whether the rest is worth doing.

**Also confirm:** does the rule cover *images* of bank details, not just
typed fields? A cancelled cheque uploaded as a photo contains the same
account number. Assume yes unless told otherwise.

---

## Part 2 — IT / Network team

The realistic blocker. Ask early.

**Questions**

1. Will you permit `cloudflared` (Cloudflare Tunnel) to run on a machine
   inside our network? It makes an outbound-only connection — no inbound
   firewall port is opened.
2. If not, what outbound integration paths *are* permitted?
3. Which machine could host it, and who owns its patching and uptime?
4. Do we already have a Cloudflare account, or would this be new?
5. Is there an existing approved pattern for cloud-to-on-premise
   integration we should use instead?

**What a bad answer sounds like:** "We don't allow tunnelling software."
Some organisations ban it outright as an uncontrolled egress path. If
that is the answer, this architecture is dead and the fallback in Part 6
applies — find out now, not after two weeks of work.

**Know before you go in:** the objection they will raise is that a
tunnel creates a path out of the network that their perimeter controls
do not inspect. That is a fair concern. The counter is that the tunnel
can be restricted to a single destination — the SAP Service Layer host
and port, nothing else.

---

## Part 3 — SAP team or B1 consultant

Where the actual effort lives.

**Questions**

1. Is the **SAP B1 Service Layer** installed, licensed and enabled?
   (Typically HTTPS on port 50000.)
2. Can we have a **dedicated integration user** with only the permissions
   needed to create and read vendor master data? What licence does that
   consume?
3. Should a new vendor be created as a **draft under an approval
   procedure**, or written directly? What does our configuration do today?
4. Which fields are **mandatory** on a Business Partner in our setup, and
   what are the numbering rules for new vendor codes?
5. How are **bank details** stored on a Business Partner here — the
   standard bank accounts collection, or customised?
6. If a draft is created and then needs cancelling, is that **safe** in
   our approval workflow, or does it leave a broken record?
7. Is there a **test/sandbox company database** we can develop against?

**Know before you go in:** question 7 is the one that quietly determines
your timeline. Developing an integration directly against production is
not acceptable, and if no sandbox exists, creating one becomes a project
of its own.

Question 3 also matters more than it looks — if vendors go straight in
rather than as drafts, the portal's approve step and SAP's approval
process are doing the same job twice, and you need to decide which one
is authoritative.

---

## Part 4 — Finance / whoever owns vendor onboarding

Ask this even though it feels obvious. The answer may remove the need
for the whole integration.

**Questions**

1. How do you capture a new vendor's bank details **today** — signed
   form, email, phone?
2. Who keys them into SAP, and how long does that take per vendor?
3. Do you verify them by **calling the vendor back** on a number you
   already hold? *(If not, that is the single most valuable control to
   add, integration or no integration.)*
4. Roughly how many new vendors per month, and how often do existing
   vendors change bank details?
5. Would you accept the portal handling everything **except** banking,
   with bank details continuing as they do now?

**Know before you go in:** if the answer to 4 is "a handful a month",
the business case for a Cloudflare + SAP integration is weak. Automating
a task that happens five times a month, at the cost of a tunnel, a
Worker, session handling and a reconciliation process, is hard to
justify. Question 5 is the one that could save you a month of work.

---

## Part 5 — Your own items, independent of any meeting

These do not depend on anyone else and are worth doing regardless.

- [ ] **Fix vendor sign-in.** `manoj.singh@ikio.com` was redirected to
      the login page. Likely cause: corporate mail scanning (Safe Links
      or similar) opening the one-time link before the human clicks,
      consuming it. Fix is a 6-digit code instead of a link. Until then,
      corporate recipients may not be able to sign in at all.
- [ ] **Grant someone the `checker` role.** Currently there are two
      approvers and no checker, so nothing can move past "submitted" —
      approval requires a completed check first.
- [ ] **Remove `sotriyusta@tozya.com`** (temp-mail address holding real
      checker access) once testing with it is finished.
- [ ] **Run the leak test** in `TEST_PLAN.md` against the deployed site.
      Not yet done.
- [ ] **Move to Supabase Pro ($25/mo)** before real vendor data. The free
      tier has no point-in-time recovery and pauses on inactivity —
      unsuitable for production regardless of the banking question.
- [ ] **Check your Supabase region** (Settings → General). If it is not
      Mumbai, Indian vendor data is stored outside India, which is a
      separate compliance question from the banking one and cannot be
      changed after creation.
- [ ] **Test document upload end to end.** Never exercised with a real
      file.

---

## Part 6 — If Cloudflare is refused

Have this ready, so a "no" does not end the project.

1. **Portal without banking.** Everything except bank details runs
   through the portal; finance collects banking as they do today. Zero
   integration work, available immediately, already compliant. This is
   the current state of the code — `PORTAL_BANK_MODE = "off"`.
2. **On-premise integration runtime.** Same split-payload design, but the
   forwarding service runs inside IKIO's network instead of at
   Cloudflare's edge. Satisfies a "no third-party processing" rule.
   More infrastructure to own.
3. **Scheduled batch.** Portal collects nothing sensitive; finance
   exports approved vendors and keys banking into SAP. Least automated,
   least risk, least work.

---

## What to say when asked "why not just store it in Supabase?"

Not "because it is insecure" — it is not, and that answer invites an
argument you do not need to have.

Say: **SAP is already the system of record for vendor master data.
Storing bank details in a second system means two places to secure, two
to audit, two that can leak, and a reconciliation problem when they
disagree — for no benefit.** The strongest argument is not that Supabase
is risky, it is that the second copy was never necessary.
