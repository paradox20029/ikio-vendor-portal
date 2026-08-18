-- ============================================================
-- Admin queries — run these in the Supabase SQL editor as needed.
-- Nothing here is part of the schema; it is day-to-day operations.
-- ============================================================


-- ---------- Who is who -------------------------------------
-- The one to run first when anything looks wrong. Shows every account,
-- whether it is staff, and whether it also has a vendor registration.

select
  u.email,
  coalesce(r.role, '— vendor / no role —')      as staff_role,
  (v.id is not null)                            as has_vendor_record,
  v.status                                      as registration_status,
  u.last_sign_in_at
from auth.users u
left join public.user_roles r on r.user_id = u.id
left join public.vendors    v on v.user_id = u.id
order by u.created_at;


-- ---------- Make someone staff ------------------------------
-- 'approver' can approve and sees every registration.
-- 'checker'  can check, and sees only vendors allocated to them.
-- Remember: the same person cannot both check and approve a vendor.

insert into public.user_roles (user_id, role)
select id, 'approver' from auth.users where email = 'YOUR_EMAIL@example.com'
on conflict (user_id) do update set role = excluded.role;


-- ---------- Set a password for a staff account ---------------
-- Needed when an account was created by magic link: it has no password,
-- so the portal's staff sign-in has nothing to check. The dashboard's
-- "send password recovery" option goes through e-mail, which is exactly
-- what you are trying to avoid while the built-in mailer is throttled.
--
-- Change BOTH the address and the password before running.
-- Do not leave a real password sitting in a saved query.

update auth.users
   set encrypted_password = extensions.crypt('ChangeThisPassword123!',
                                             extensions.gen_salt('bf')),
       updated_at = now()
 where email = 'YOUR_EMAIL@example.com';

-- If that errors with "schema extensions does not exist", drop the
-- prefixes and run:
--   update auth.users
--      set encrypted_password = crypt('ChangeThisPassword123!', gen_salt('bf')),
--          updated_at = now()
--    where email = 'YOUR_EMAIL@example.com';

-- Confirm it took effect — should return one row with a password set:
-- select email, (encrypted_password is not null) as has_password,
--        (email_confirmed_at is not null) as confirmed
--   from auth.users where email = 'YOUR_EMAIL@example.com';


-- ---------- Remove someone's staff access -------------------
-- They keep their account; they simply stop being internal staff.

-- delete from public.user_roles
--  where user_id = (select id from auth.users where email = 'someone@example.com');


-- ---------- Re-allocate a vendor to a different owner --------

-- update public.vendors
--    set allocated_staff_id = (select id from auth.users where email = 'newowner@ikio.com')
--  where company_name = 'Vendor Name Here';


-- ---------- Cancel or re-issue an invitation ----------------

-- update public.vendor_invitations set status = 'cancelled'
--  where vendor_email = 'someone@example.com';

-- Extend one that expired:
-- update public.vendor_invitations
--    set expires_at = now() + interval '30 days', status = 'pending'
--  where vendor_email = 'someone@example.com';


-- ---------- Clean up a test vendor completely ---------------
-- Deletes the registration, its bank details and documents (cascade),
-- and the invitation. The auth user is removed from
-- Authentication -> Users in the dashboard, not from here.
-- The audit_log rows are deliberately left behind.

-- delete from public.vendor_invitations
--  where vendor_email = 'bamof95879@ittiv.com';
-- delete from public.vendors
--  where user_id = (select id from auth.users where email = 'bamof95879@ittiv.com');


-- ---------- What has been happening -------------------------

select at, actor_email, action, detail
from public.audit_log
order by at desc
limit 50;
