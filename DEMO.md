# Demo runbook — two colleagues, one full cycle

Roles for the demo:

| Who | Role | Why |
|---|---|---|
| You | approver | Final sign-off. Sees every registration. |
| Colleague A | **checker** | Reviews the vendors allocated to them. |
| Colleague B | vendor | Fills in the registration form. |

**Colleague A must be a checker, not a second approver.** Approval requires a
completed check, and only a checker can check. Two approvers and no checker
means the submission reaches you and stops dead.

---

## Before the demo (do this first, not live)

**1. Run the outstanding SQL.** In the Supabase SQL editor, run
`fix-04-staff-management.sql` if you have not already. That adds the Staff
tab.

**2. Redeploy.** Drag the `live` folder onto your Netlify site's **Deploys**
tab. The deployed copy predates the Staff tab and the Set password button.

**3. Check `PORTAL_TEST_MODE` is still `true`** in `config.js`. The yellow
"do not enter real bank details" banner should be visible. Use the mock data
in `TEST_PLAN.md` throughout — this is a free-tier project, not a system to
put real supplier bank details into yet.

---

## Setting up Colleague A (staff — checker)

**1. Create their account.** Supabase → **Authentication → Users → Add user**:

- *Send invitation* — e-mails them a link that creates the account, or
- *Create new user* with a password and **Auto Confirm User** ticked, which
  is instant and avoids the mailer entirely.

**2. Grant the checker role.** SQL editor:

```sql
insert into public.user_roles (user_id, role)
select id, 'checker' from auth.users where email = 'COLLEAGUE_A@ikio.com'
on conflict (user_id) do update set role = excluded.role;
```

*0 rows means step 1 did not complete.*

Once `fix-04` is deployed you can do this from the **Staff** tab instead.

**3. They sign in** at the Netlify URL and land on the staff screens —
Registrations, Invitations, Access log. If they see "No invitation found",
the role did not attach; re-run step 2 and have them sign out and back in.

---

## Setting up Colleague B (vendor)

In the portal, **Invitations** tab → **Create & send invitation**:

- Vendor name: anything, e.g. `Meridian Polymers Pvt Ltd`
- Vendor e-mail: Colleague B's work address
- **Allocate to: Colleague A**

> Allocate to **Colleague A**, not yourself. Checkers only see vendors
> allocated to them. Allocate it to yourself and Colleague A's queue stays
> empty, and the demo stalls at the point you are trying to show off.

They receive a sign-in link by e-mail. Ask them to check spam — a new
sending domain often lands there the first time.

---

## The demo, in order

1. **Colleague B** clicks the link, lands straight on the registration form
   with the company name pre-filled from the invitation.
2. They fill it in using the mock data. Worth showing live: a bad GSTIN is
   refused, and the account number must be typed twice.
3. On the review step, **Print / save as PDF**, then upload it back as the
   signed copy. This is the piece finance teams care about.
4. They submit. The form freezes.
5. **Colleague A** opens Registrations — the submission is there, with the
   account number shown as `••••1234` and no bank column in the list.
6. They click **Reveal bank details**, then open **Access log** and show
   their own name against the reveal. This is the moment worth pausing on.
7. They **Mark as checked**.
8. **You** open the same record and **Approve**.
9. **Colleague B** reloads and sees the approved status.

## Two things to demonstrate deliberately

**Separation of duties.** Before step 8, have Colleague A try to approve —
the button is disabled, and the database refuses even if you re-enable it in
devtools. Then have yourself try to approve *before* Colleague A checks:
"This must be checked by its allocated owner first."

**Allocation.** If you have a second checker, show that Colleague A's queue
contains only their own vendors. This is what "the details go exclusively to
the allocated staff" means in practice.
