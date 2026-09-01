# Concepts worth understanding for this project

Roughly ordered by when you will need them. Each one is tied to
something that has already happened in this build, because you have met
most of these already without the vocabulary attached.

---

## Part 1 — Networking (for the IT conversation)

### Inbound vs outbound connections
The single most important idea in the Cloudflare design.

A firewall's job is mostly to block **inbound** connections — things on
the internet reaching into your network. **Outbound** connections, your
network reaching out, are normally allowed, because otherwise nobody
could browse the web.

`cloudflared` exploits this: it sits inside IKIO's network and dials
*out* to Cloudflare, then holds that connection open. Traffic flows back
down the pipe that was opened from the inside. No inbound port is ever
opened.

*When IT says "we're not opening a port for this", the honest answer is
"you don't have to — nothing inbound is required."*

### NAT and why inbound is hard
Most internal machines have private addresses (192.168.x.x, 10.x.x.x)
that don't exist on the public internet. NAT translates them on the way
out. This is why an outside service fundamentally cannot dial *in* to
your SAP server without deliberate configuration — and why the tunnel
approach exists at all.

### Ports
A port is a numbered door on a machine. HTTPS is 443. SAP Business One
Service Layer is typically **50000**. When IT asks "what are you
connecting to", the answer is one host and one port — and being able to
say that precisely is what makes a tunnel request acceptable rather than
alarming.

### Egress control / data exfiltration
IT's real objection to tunnels. A tunnel is a route out of the network
that their inspection tools cannot see inside. In the wrong hands, it is
how data leaves. Their concern is legitimate. The mitigation is
restricting the tunnel to a single destination.

*Expect this objection. Don't be defensive about it.*

### TLS / HTTPS, and "in transit" vs "at rest"
TLS encrypts data while it moves. Encryption at rest protects it while
stored on disk. They are different protections, and compliance rules
usually care about **at rest** (where it lives) and **processing** (who
touches it), not just transit.

*This is why "but it's encrypted" is not an answer to "don't store bank
details in Supabase". Supabase already encrypts at rest. The objection
was about custody, not encryption.*

### DNS
Maps names to addresses. Relevant twice here: your Netlify site's
address, and the Brevo domain verification records (SPF/DKIM) that let
your mail be trusted rather than binned as spam.

---

## Part 2 — Identity and authorisation

### Authentication vs authorisation
**Authentication** = who are you. **Authorisation** = what may you do.
Supabase Auth does the first; `user_roles` and RLS do the second.

*You hit this exactly: creating a user in the Supabase dashboard
authenticates them but grants nothing, which is why a new colleague
still saw "No invitation found" until a role was granted.*

### JWT (JSON Web Token)
The signed token Supabase issues after sign-in. Three parts: header,
payload (who you are, when it expires), and a **signature**.

The signature is the point. Anyone can read a JWT — it isn't encrypted —
but only Supabase can produce a valid signature, so a server can verify
it wasn't forged or altered. This is how the Cloudflare Worker will
trust a request it receives from a browser it has never met.

*You've already decoded one: I read the project reference straight out
of your anon key, because JWT payloads are readable by design.*

### Public vs secret keys
Your **anon key** is public by design — it identifies the project, grants
nothing, and is meant to sit in browser code. The **service_role** key
bypasses every rule in the database and must never leave a server.

*This distinction is why publishing `config.js` to a public GitHub repo
is fine, and why the same file with a service_role key would have been a
serious incident.*

### Row Level Security (RLS)
Rules stored in the database saying which rows each user may see. The
protection lives in Postgres, not in your JavaScript — so it holds even
if someone bypasses your app entirely and calls the API directly.

*This is what the "leak test" in TEST_PLAN.md checks: a signed-in vendor
holding the public key cannot read another vendor's row.*

### Security definer functions
A Postgres function that runs with its *creator's* privileges rather
than the caller's. This is how a vendor with zero access to
`vendor_bank_details` could still write to it — through a function that
checks who they are first.

*Powerful and sharp-edged: a careless one is a privilege escalation
hole. That's why every one in this schema pins `search_path` and checks
the caller before doing anything.*

### Least privilege
Grant the minimum needed, nothing more. The SAP integration user should
be able to create and read vendor master data and nothing else.

*Already applied here: nobody holds SELECT on `vendor_bank_details`, not
even approvers — reads go through an audited function instead.*

### Defence in depth
Multiple independent layers, so one failure isn't fatal. Your buttons
are disabled in the UI *and* the rules are enforced in the database. The
UI layer is convenience; the database layer is the control.

---

## Part 3 — Backend and integration

### REST and OData
REST is the convention of addressing things by URL with verbs
(GET/POST). **OData** is a stricter query flavour of REST that SAP's
Service Layer uses — it adds standard filtering and navigation syntax.
If you can read the Supabase API calls in `index.html`, you can read
OData.

### Stateless vs stateful
A Cloudflare Worker is **stateless** — each request starts fresh with no
memory of the last. SAP's Service Layer is **stateful** — you log in,
get a session, and reuse it.

*This mismatch is the real engineering wrinkle in the integration. Either
log in on every request (slow, consumes licence slots) or cache the
session in Cloudflare KV (more code, but correct).*

### Idempotency
An operation you can safely repeat with the same result. Critical when
a network call times out and you don't know whether it succeeded.

*Without it: vendor submits, the request times out, they click again,
and SAP now has two vendor drafts. With an idempotency key, the second
call is recognised as a repeat of the first.*

*You have already met the opposite of this: magic links are deliberately
single-use, which is why a corporate mail scanner opening one first
burns it before the human clicks.*

### Distributed transactions and why they don't exist here
A database transaction is all-or-nothing. Across **two** systems —
Supabase and SAP — there is no such guarantee. SAP can succeed while the
Supabase update fails, leaving them disagreeing.

You cannot eliminate this, only handle it:
- **Compensating action** — undo the first step (cancel the SAP draft).
  Only safe if SAP permits cancellation.
- **Reconciliation** — record the inconsistency and fix it later with a
  scheduled job. Usually the safer choice.

*This is the entire content of section 5.3 and 5.5 of your architecture
document, and the reason `sap_link_state` exists in the schema.*

### Fail closed vs fail open
When something breaks, does access get denied or granted? Security
systems should **fail closed**.

*Concretely: `PORTAL_BANK_MODE = "worker"` with no Worker URL disables
banking capture entirely rather than quietly falling back to storing in
Supabase. That's failing closed, and I tested it specifically.*

### Audit trail and non-repudiation
A record of who did what, that the actor cannot later deny or erase.
Yours writes the audit row **before** disclosing bank details, and rolls
the whole thing back if the audit write fails — so there is no way to
read the data without leaving a trace.

*A log that can be edited by the person it incriminates is decoration.
That's why `audit_log` has no update or delete path.*

---

## Part 4 — Data and compliance

### Data residency
*Where* data physically sits. Indian financial data is expected to stay
in India under RBI guidance and DPDP.

*Your Supabase region was fixed when the project was created and cannot
be changed. Worth checking under Settings → General.*

### At rest / in transit / in processing
Three distinct states, and compliance rules treat them differently:
- **At rest** — stored on disk. Supabase and SAP.
- **In transit** — moving over the network. Protected by TLS.
- **In processing** — briefly in a machine's memory while being handled.
  Cloudflare Workers.

*This is precisely why the storage-versus-processing question is the
first thing to settle. A rule about storage permits the Cloudflare
design; a rule about processing forbids it.*

### Controller vs processor
Under DPDP and GDPR, the **controller** decides why data is collected
(IKIO). A **processor** handles it on the controller's instructions
(Supabase, Cloudflare, Brevo). The controller stays accountable — you
cannot outsource responsibility for a leak to your vendor.

### Data minimisation
Don't collect or keep what you don't need. The strongest version of the
current argument: SAP already holds vendor bank details, so a second
copy in Supabase was never necessary.

---

## Part 5 — Things you already did that have names

Useful to know, because you'll be asked how the portal is secured.

| What you built | What it's called |
|---|---|
| Bank details in a table nobody can SELECT | Least privilege / data isolation |
| Reveal function that audits before returning | Mediated access with non-repudiation |
| Checker cannot also approve the same vendor | Separation of duties / four-eyes principle |
| Roles in their own table, not user metadata | Trusted vs untrusted claims |
| Buttons disabled *and* rules in the database | Defence in depth |
| Vendor sees only their own row | Row-level access control / tenant isolation |
| Invitation required, no open signup | Closed enrolment |
| `anon` key public, `service_role` never shipped | Key separation by privilege |

---

## What to read if you want depth

- **Supabase docs on RLS and Auth** — closest to what you've built.
- **Cloudflare Tunnel docs** — read before the IT meeting; being able to
  describe it accurately is most of that conversation.
- **SAP B1 Service Layer documentation** — dry, but it defines what is
  actually possible on the SAP side.
- **OWASP Top 10** — the standard list of how web applications get
  broken. Short, and you'll recognise several you already defended
  against here.
