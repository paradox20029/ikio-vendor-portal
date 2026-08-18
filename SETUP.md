# Going live — step by step

Follow these in order. The order matters: roles can only be granted to a user
who already exists, and a user only exists after they have signed in once.

Budget 45–90 minutes. Steps 1 and 11 are the only ones that need you to sign
up for something.

---

## 1. Create the Supabase project

1. Go to <https://supabase.com> and sign in (GitHub account or e-mail).
2. **New project**.
   - Name: `ikio-vendor-portal`
   - Database password: generate one and save it somewhere. You will not need
     it for this portal, but you cannot retrieve it later.
   - **Region: Mumbai / `ap-south-1`** if offered. You will hold Indian
     suppliers' PAN, GST and bank details. This cannot be changed afterwards.
   - Plan: Free is fine for the staff pilot.
3. Wait for provisioning to finish (1–2 minutes).

## 2. Run the schema

Dashboard → **SQL Editor** → **New query**.

Paste the entire contents of `../schema.sql` and click **Run**.

Expect "Success. No rows returned." If you get an error, stop and send me the
message — do not continue past a failed schema.

## 3. Copy your two keys into `config.js`

Dashboard → **Project Settings** → **Data API** (labelled **API** on some
plans).

Open `live/config.js` and replace the two placeholders:

| In `config.js` | Copy from the dashboard |
|---|---|
| `SUPABASE_URL` | **Project URL** |
| `SUPABASE_ANON_KEY` | the **anon** / **publishable** key |

The anon key is meant to live in client-side code and is public by design.
**Do not use the `service_role` key** — it bypasses every access rule in the
schema.

## 4. Allow localhost to receive sign-in links

Dashboard → **Authentication** → **URL Configuration**:

- **Site URL**: `http://localhost:8030`
- **Redirect URLs**: add `http://localhost:8030/live/index.html`

Magic links fail silently if the address is not on this list. This is the
single most common reason "the link doesn't work".

## 5. Start the portal locally

From `C:\IKIO\vendor-portal`:

```
python serve.py
```

Open <http://localhost:8030/live/index.html>.

Use `serve.py`, not `python -m http.server`. The built-in server listens on
every network interface and allows caching, so your folder ends up on the
LAN and edits appear not to take effect. `serve.py` binds localhost only and
sends no-cache headers.

If an edit still seems to be ignored, hard-reload once with Ctrl+Shift+R —
the browser may be holding a copy from before the switch.

## 6. Sign in once as yourself

> **The built-in mailer sends about 2 e-mails per hour, across the entire
> project.** Not per user — 2 in total. Request a link once and wait;
> repeated clicks just push the reset further out. Check spam before
> retrying.
>
> It does deliver to outside addresses, including disposable ones — tested
> and confirmed on this project. The constraint is volume, not who the
> recipient is. That makes it usable for a small hands-on demo and useless
> for inviting 512 suppliers, which is why step 6c still matters before the
> real rollout.
>
> If you are already locked out, **step 6b** gets you in without e-mail at
> all.

Enter your own work e-mail, click the link that arrives, and come back.

**You will see "No invitation found". That is correct**, not a bug — you have
not been made staff yet, and the portal treats every unknown address as an
uninvited vendor. It has, however, now created your user account, which is
what step 7 needs.

## 6b. If you hit "email rate limit exceeded"

Nothing is broken and nothing is lost. The counter resets on its own —
check **Authentication → Rate Limits** for the current window.

### Fastest way through: create a staff account with a password

This skips e-mail completely. It takes about a minute and does not consume
any quota.

1. Supabase → **Authentication → Users → Add user → Create new user**.
2. Enter your e-mail and a password you choose.
3. **Tick "Auto Confirm User"** — without it the account is created but
   cannot sign in, and confirming it would need an e-mail.
4. **Create user.**
5. In the portal, enter that e-mail, click **"IKIO staff — sign in with a
   password"**, type the password, **Sign in**.

You are now signed in with no mail involved, and your account exists, so
step 7 will work.

This route is for internal staff only, and deliberately so. Passwords are
reasonable for a handful of colleagues you can reach directly; for 512
external suppliers the reset burden is exactly why vendors get magic links
instead. Vendors never see this option unless they go looking, and it gives
them nothing — they have no password set.

**Do this while you wait**, because it may not be wasted time. Go to
**Authentication → Users**. If your address is already listed, one of your
earlier link requests worked and your account exists — so you can run step 7
right now, and by the time you can sign in again you will already be an
approver.

## 6c. Custom SMTP — the only way to raise the limit

There is no setting that raises the built-in mailer; the ~2/hour cap is a
fixed property of it, and Supabase documents it as best-effort with no
delivery SLA. Configuring your own SMTP raises the default to 30/hour and
makes the **Rate Limits** page editable so you can go higher.

You can run a small demo on the built-in mailer by pacing your requests.
You cannot invite 512 suppliers on it. Deliverability is the other reason:
mail sent from Supabase's shared sender is far more likely to be filtered
than mail from a verified IKIO domain — and a supplier who never sees the
invitation simply never registers.

### What goes in each field

The SMTP Settings page asks for seven things. Get the provider account set
up **first** — saving credentials for an unverified sender succeeds, then
every send fails.

| Field | Brevo | Resend |
|---|---|---|
| Host | `smtp-relay.brevo.com` | `smtp.resend.com` |
| Port number | `587` | `465` |
| Username | your Brevo login e-mail | `resend` |
| Password | Brevo **SMTP key** (not your account password) | Resend API key, starts `re_` |
| Sender email address | an address verified in Brevo | any address at your verified domain |
| Sender name | `IKIO Vendor Portal` | `IKIO Vendor Portal` |
| Minimum interval per user | `60` | `60` |

**Sender email address** must be one the provider has verified, or mail is
rejected at send time. This is also the address vendors will see, so it
should look like IKIO, not like a personal account.

**Minimum interval per user** is a cooldown between e-mails to the *same*
person — unrelated to the hourly cap. 60 seconds stops someone generating
a dozen links by clicking repeatedly, without being annoying to a vendor
who genuinely needs a second one.

After saving, go to **Authentication → Rate Limits** and raise the hourly
figure. Enabling SMTP lifts it to 30/hour automatically; for a batch of
invitations you will want more.

### With an IKIO domain (do this if you can)

1. Sign up at <https://resend.com>.
2. **Domains → Add domain**, enter an IKIO domain, and add the DNS records
   it gives you (SPF and DKIM). Wait for it to verify.
3. **API Keys → Create API Key.** Copy it.
4. Supabase → **Authentication → Emails → SMTP Settings** → enable:
   - Host `smtp.resend.com`
   - Port `465`
   - Username `resend`
   - Password — the Resend API key
   - Sender e-mail — `vendors@yourikiodomain`
   - Sender name — `IKIO Vendor Portal`
5. Supabase → **Authentication → Rate Limits** → raise the e-mails-per-hour
   figure to something sensible for your batch size.

The domain step is not bureaucracy. Vendors are being asked for bank details;
mail from an address they recognise is the difference between a registration
request and something their finance team reports as phishing.

### Without DNS access — Brevo, step by step

Free tier is 300 e-mails a day, no card required. Enough for a pilot.

**1. Verify a sender address.**
Brevo → **Senders, Domains & Dedicated IPs → Senders → Add a sender**.
Enter a name and an address you can open. Brevo e-mails that address a
confirmation link; click it. Until this is done, every send is rejected.

Use an IKIO address if you have one. A personal address works for testing
but will look wrong to suppliers.

**2. Generate an SMTP key.**
Brevo → **SMTP & API → SMTP** tab. That page shows the server, port and a
**Login** value, and has a button to create an SMTP key.

That page shows a **Login** that looks like an e-mail but is not one — it has
the shape `<something>@smtp-brevo.com`. That string is your SMTP username.
It is not your Brevo account e-mail and not your name. Copy it exactly from
the dashboard; do not write it into any file that might be published.

Getting this wrong is the most common failure here, and it does not present
as "wrong username" — it shows up as `Error sending confirmation email`, or
as a gateway timeout, because the connection is refused during
authentication.

Copy the SMTP key too; Brevo shows it once.

If the SMTP tab is locked or asks you to activate your account first, that
is Brevo's anti-abuse review for new accounts. Complete whatever it asks;
it is usually quick, but it can hold you up for a few hours.

**3. Enter it in Supabase.**
Authentication → Emails → SMTP Settings, enable custom SMTP:

| Field | Value |
|---|---|
| Host | `smtp-relay.brevo.com` |
| Port number | `587` |
| Username | the Login from Brevo's SMTP page |
| Password | the SMTP key |
| Sender email address | the address you verified in step 1 |
| Sender name | `IKIO Vendor Portal` |
| Minimum interval per user | `60` |

**4. Raise the limit.** Authentication → Rate Limits. Enabling SMTP moves
you to 30/hour automatically; raise it further for a batch of invitations.

**5. Test before trusting it.** Request a sign-in link to an address that
is *not* your Brevo account and *not* your Supabase login — a disposable
address is fine. Confirm it arrives, and check whether it landed in spam.

Treat Brevo-with-a-personal-sender as a stopgap. Move to a verified IKIO
domain before real vendors: an unrecognised sender asking suppliers for
bank details is what finance teams report as phishing.

## 7. Make yourself an approver

Back in the **SQL Editor**, with your own address:

```sql
insert into public.user_roles (user_id, role)
select id, 'approver' from auth.users where email = 'YOUR@EMAIL.COM'
on conflict (user_id) do update set role = excluded.role;
```

If it reports 0 rows, the address does not match the one you signed in with.

Now **sign out and back in** in the portal. You should land on the staff
screens: Registrations, Invitations, Access log.

## 8. Add a second staff member as checker

The database enforces that **the same person cannot both check and approve**,
so the full chain needs two people.

Ask a colleague to open the portal and sign in with their work address (they
will also see "No invitation found" — expected). Then run:

```sql
insert into public.user_roles (user_id, role)
select id, 'checker' from auth.users where email = 'COLLEAGUE@EMAIL.COM'
on conflict (user_id) do update set role = excluded.role;
```

## 8b. Walking the vendor side with no e-mail at all

Creating an invitation does **not** send anything. It records who was invited
and who owns them; the vendor then signs in from the portal themselves. So an
empty inbox after "Create invitation" is expected, not a failure.

While the built-in mailer is still in place it cannot reach an outside
address anyway. To test the whole vendor journey today, give the test vendor
a password the same way you gave yourself one:

1. **Authentication → Users → Add user → Create new user.**
2. Use **exactly the address you invited**. `claim_invitation()` matches on
   e-mail, so a different address will land on "No invitation found".
3. Set a password, tick **Auto Confirm User**, create.
4. Open the portal in a **private/incognito window** — otherwise you will
   replace your own staff session — and sign in with the password button.

You land straight on the registration form, pre-filled with the company name
from the invitation. Fill it in, submit, then switch back to your normal
window to check, reveal and approve it.

This proves every part of the flow except delivery of the e-mail itself.

## 9. Invite your first test vendor

In the portal: **Invitations** tab → enter a vendor name, the e-mail address
of whoever will play the vendor, and allocate it to yourself → **Create
invitation**.

## 10. Walk the whole flow locally

Have them open the portal, sign in with that same address, fill the form using
the mock data in `../TEST_PLAN.md` — **not real bank details** — and submit.

Then confirm, on your side:

- it appears in **Registrations**
- the account number shows as `••••5566`, not in full
- **Reveal bank details** shows it, and writes a row in **Access log**
- your colleague can **Mark as checked**; you can then **Approve** or
  **Reject** with remarks
- you cannot approve something that has not been checked

## 11. Deploy, to get a link you can send

1. Go to <https://app.netlify.com/drop> and sign in.
2. Drag the **`live` folder** onto the page — the folder itself, not its
   contents. It should contain only `index.html` and `config.js`.
   Anything else in there becomes publicly readable.
3. You get a URL like `https://random-words-123.netlify.app` in about a
   minute. There is no build step.
4. Optional but worth it: **Site configuration → Change site name** to
   something like `ikio-vendor-portal`, so the address is not gibberish.
5. **Authentication → URL Configuration** in Supabase: set **Site URL** to
   the new address and add it to **Redirect URLs** as well.

   > **The symptom if you skip this:** the sign-in e-mail arrives, but
   > clicking it lands on `http://localhost:3000/#access_token=...` and
   > "This site can't be reached". Port 3000 is Supabase's factory default
   > Site URL. When the address your app asks to return to is not on the
   > Redirect URLs list, Supabase ignores it and uses the Site URL instead
   > — so the giveaway is a port your project has never used.
   >
   > Add both, so links work from either place:
   > - `https://your-site.netlify.app`
   > - `http://localhost:8030/live/index.html`
   >
   > Wildcards are allowed in Redirect URLs, e.g.
   > `https://your-site.netlify.app/**`.
   >
   > Each sign-in link is single-use. After fixing the setting, request a
   > fresh one — the old link is spent, and retrying it will fail even
   > once the configuration is right.
6. Sign in on the public URL yourself and walk the whole flow again before
   sending the link to anyone.

`PORTAL_URL` in `config.js` can stay empty. It only overrides where sign-in
links point; left blank, the portal uses whatever address it is being served
from, which is correct once deployed. Set it only if you want links sent from
a local copy to still point at the deployed site.

## 11b. Updating after deployment

You can change anything, any time. There is no build and no release process.

**Front end** — edit `index.html` or `config.js`, then open your site in
Netlify, go to the **Deploys** tab, and drag the `live` folder onto *that*
page. The site updates and keeps the same URL.

> Do not drag onto app.netlify.com/drop again. That creates a **new site at
> a different address**, and everyone holding the old link is stranded.

**Database** — run SQL in the Supabase editor exactly as you have been. The
deployed site talks to the same project, so schema changes take effect
immediately with no redeploy.

The two halves are independent, which is why adding features later is cheap.
Just keep them in step: if a change needs both a new function and new UI, run
the SQL first, then deploy the front end. That order means the UI never calls
something that does not exist yet.

## 12. Before real vendors — not before the staff demo

- **E-mail limits.** Supabase's built-in mailer is heavily rate limited and
  meant for testing. Fine for a few staff; it will silently drop most of 512
  invitations. Configure your own SMTP under **Authentication → SMTP
  Settings** (Resend, SES, Postmark) before any bulk invite.
- **Run the leak test** in `../TEST_PLAN.md`. It checks the one thing that
  matters: that a signed-in vendor holding the public anon key cannot read
  another vendor's row, cannot read any bank details, and cannot promote
  themselves to staff.
- **Use an IKIO domain.** An unexpected e-mail asking for bank details from a
  `netlify.app` address is indistinguishable from phishing.
- **Move to Supabase Pro.** Free projects pause after inactivity and have no
  point-in-time recovery.
- **Set `PORTAL_TEST_MODE = false`** in `config.js` to drop the test banner.
