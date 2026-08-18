-- ============================================================
-- Fix 05 — manage staff roles from inside the portal
--
-- Adding a checker or approver meant running SQL by hand. That is fine
-- once and unsustainable as a workflow, so it moves into the app —
-- carefully, because user_roles is the table every other protection
-- keys off.
--
-- Guards, and why each exists:
--   * only an approver may call these at all
--   * you cannot change your own role  — stops someone quietly
--     escalating themselves, and makes every change attributable to a
--     second person
--   * the account must already exist   — roles attach to a user, and a
--     user only exists after they have signed in once
--   * the last approver cannot be removed — otherwise nobody can ever
--     grant a role again and the only way back is the SQL editor
--
-- Paste into the Supabase SQL editor and run. Safe to re-run.
-- ============================================================

create or replace function public.grant_staff_role(p_email text, p_role text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  uid uuid;
  addr text := lower(trim(p_email));
begin
  if not public.has_role('approver') then
    raise exception 'Only an approver may manage staff roles.';
  end if;
  if p_role not in ('checker','approver') then
    raise exception 'Role must be checker or approver.';
  end if;

  select id into uid from auth.users where lower(email) = addr;
  if uid is null then
    raise exception 'No account exists for %. Ask them to open the portal and sign in once, then try again.', addr;
  end if;
  if uid = auth.uid() then
    raise exception 'You cannot change your own role. Ask another approver.';
  end if;

  insert into public.user_roles (user_id, role)
  values (uid, p_role)
  on conflict (user_id) do update set role = excluded.role;

  perform public.write_audit('staff.role_granted', null,
    jsonb_build_object('email', addr, 'role', p_role));
  return p_role;
end;
$$;

grant execute on function public.grant_staff_role(text, text) to authenticated;


create or replace function public.revoke_staff_role(p_email text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  uid uuid;
  addr text := lower(trim(p_email));
  approvers_left int;
begin
  if not public.has_role('approver') then
    raise exception 'Only an approver may manage staff roles.';
  end if;

  select id into uid from auth.users where lower(email) = addr;
  if uid is null then
    raise exception 'No account exists for %.', addr;
  end if;
  if uid = auth.uid() then
    raise exception 'You cannot remove your own access.';
  end if;

  select count(*) into approvers_left
  from public.user_roles where role = 'approver' and user_id <> uid;
  if approvers_left = 0 then
    raise exception 'That is the last approver. Grant approver to someone else first.';
  end if;

  delete from public.user_roles where user_id = uid;

  perform public.write_audit('staff.role_revoked', null,
    jsonb_build_object('email', addr));
end;
$$;

grant execute on function public.revoke_staff_role(text) to authenticated;


-- Staff list with roles, for the portal's Staff tab. Staff only: it
-- exposes colleagues' addresses, which vendors have no business seeing.
create or replace function public.list_staff_detail()
returns table (email text, role text, granted_at timestamptz, is_you boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_staff() then
    raise exception 'Not authorised.';
  end if;
  return query
    select u.email::text, r.role, r.granted_at, (r.user_id = auth.uid())
    from public.user_roles r
    join auth.users u on u.id = r.user_id
    order by r.role, u.email;
end;
$$;

grant execute on function public.list_staff_detail() to authenticated;
