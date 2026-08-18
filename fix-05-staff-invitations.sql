-- ============================================================
-- Fix 06 — invite colleagues, and a view-only role
--
-- Adds:
--   * a 'viewer' role — can see registrations, can do nothing to them,
--     and cannot reveal a bank account
--   * staff_invitations, so a colleague can be invited before they have
--     an account, exactly like a vendor is
--   * claim_staff_role(), which attaches the role on their first sign-in
--
-- Also closes a hole created by adding the role: 'reject' and 'reopen'
-- previously required only is_staff(), so a viewer would have been able
-- to reject registrations. They now require checker or approver.
--
-- Paste into the Supabase SQL editor and run. Safe to re-run.
-- ============================================================

-- ---------- 1. Allow the new role -----------------------------

alter table public.user_roles drop constraint if exists user_roles_role_check;
alter table public.user_roles add constraint user_roles_role_check
  check (role in ('viewer','initiator','checker','approver'));


-- ---------- 2. Viewers can see registrations ------------------
-- Read-only and unallocated: a viewer sees the whole queue, because an
-- observer with an empty screen is useless. They still cannot see a bank
-- account — that goes through staff_reveal_bank_details(), which is
-- restricted below.

drop policy if exists staff_reads_allocated on public.vendors;

create policy staff_reads_allocated on public.vendors
  for select to authenticated
  using (
    (public.is_staff() and allocated_staff_id = auth.uid())
    or public.has_role('approver')
    or public.has_role('viewer')
  );


-- ---------- 3. Viewers cannot act -----------------------------

create or replace function public.staff_reveal_bank_details(p_vendor_id uuid)
returns table (beneficiary_name text, bank_name_addr text,
               account_number text, ifsc_code text, swift_code text)
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  -- Viewers are deliberately excluded. Seeing the queue is one thing;
  -- reading a supplier's account number is another, and it is the single
  -- most sensitive action in this system.
  if not exists (
    select 1 from public.vendors v
    where v.id = p_vendor_id
      and (((public.has_role('checker')) and v.allocated_staff_id = auth.uid())
           or public.has_role('approver'))
  ) then
    raise exception 'Not authorised to view bank details for this vendor.';
  end if;

  perform public.write_audit('bank_details.revealed', p_vendor_id, null);

  return query
    select b.beneficiary_name, b.bank_name_addr,
           b.account_number, b.ifsc_code, b.swift_code
    from public.vendor_bank_details b
    where b.vendor_id = p_vendor_id;
end;
$$;

grant execute on function public.staff_reveal_bank_details(uuid) to authenticated;

-- reject / reopen used to accept any staff member, which would now
-- include viewers. Narrow them to checker or approver.
create or replace function public.advance_status(
  p_vendor_id uuid, p_action text, p_remarks text default null)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.vendors%rowtype;
  can_act boolean := public.has_role('checker') or public.has_role('approver');
begin
  select * into v from public.vendors where id = p_vendor_id;
  if not found then raise exception 'Vendor not found.'; end if;

  if p_action = 'check' then
    if not public.has_role('checker') then
      raise exception 'Only a checker may check a registration.';
    end if;
    if v.status <> 'submitted' then
      raise exception 'Only submitted registrations can be checked.';
    end if;
    update public.vendors
       set status = 'checked', checked_by = auth.uid(),
           checked_at = now(), remarks = p_remarks, updated_at = now()
     where id = p_vendor_id;

  elsif p_action = 'approve' then
    if not public.has_role('approver') then
      raise exception 'Only an approver may approve a registration.';
    end if;
    if v.status <> 'checked' then
      raise exception 'A registration must be checked before it is approved.';
    end if;
    if v.checked_by = auth.uid() then
      raise exception 'The same person cannot both check and approve a vendor.';
    end if;
    update public.vendors
       set status = 'approved', approved_by = auth.uid(),
           approved_at = now(), remarks = p_remarks, updated_at = now()
     where id = p_vendor_id;

  elsif p_action = 'reject' then
    if not can_act then raise exception 'View-only access cannot reject a registration.'; end if;
    update public.vendors
       set status = 'rejected', remarks = p_remarks, updated_at = now()
     where id = p_vendor_id;

  elsif p_action = 'reopen' then
    if not can_act then raise exception 'View-only access cannot send a registration back.'; end if;
    update public.vendors
       set status = 'draft', remarks = p_remarks,
           checked_by = null, checked_at = null, updated_at = now()
     where id = p_vendor_id;

  else
    raise exception 'Unknown action.';
  end if;

  perform public.write_audit('status.' || p_action, p_vendor_id,
    jsonb_build_object('remarks', p_remarks));
  return p_action;
end;
$$;

grant execute on function public.advance_status(uuid, text, text) to authenticated;


-- ---------- 4. Staff invitations ------------------------------

create table if not exists public.staff_invitations (
  id          uuid primary key default gen_random_uuid(),
  email       text not null unique,
  role        text not null check (role in ('viewer','checker','approver')),
  invited_by  uuid references auth.users(id),
  invited_at  timestamptz not null default now(),
  claimed_at  timestamptz
);

alter table public.staff_invitations enable row level security;

drop policy if exists staff_inv_reads on public.staff_invitations;

create policy staff_inv_reads on public.staff_invitations
  for select to authenticated using (public.is_staff());

revoke insert, update, delete on public.staff_invitations from anon, authenticated;


create or replace function public.invite_staff(p_email text, p_role text)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  new_id uuid;
  addr text := lower(trim(p_email));
begin
  if not public.has_role('approver') then
    raise exception 'Only an approver may invite colleagues.';
  end if;
  if p_role not in ('viewer','checker','approver') then
    raise exception 'Role must be viewer, checker or approver.';
  end if;
  if exists (select 1 from public.vendor_invitations where vendor_email = addr) then
    raise exception 'That address is already invited as a vendor. One address cannot be both.';
  end if;

  insert into public.staff_invitations (email, role, invited_by)
  values (addr, p_role, auth.uid())
  on conflict (email) do update
     set role = excluded.role, invited_by = excluded.invited_by,
         invited_at = now(), claimed_at = null
  returning id into new_id;

  -- If they already have an account, apply it immediately rather than
  -- making them sign out and back in to pick it up.
  update public.user_roles r set role = p_role
    from auth.users u where u.id = r.user_id and lower(u.email) = addr;
  insert into public.user_roles (user_id, role)
  select u.id, p_role from auth.users u
   where lower(u.email) = addr
     and not exists (select 1 from public.user_roles x where x.user_id = u.id);

  perform public.write_audit('staff.invited', null,
    jsonb_build_object('email', addr, 'role', p_role));
  return new_id;
end;
$$;

grant execute on function public.invite_staff(text, text) to authenticated;


-- Called on every sign-in. Harmless for people with no invitation.
create or replace function public.claim_staff_role()
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  inv public.staff_invitations%rowtype;
  my_email text;
begin
  select email into my_email from auth.users where id = auth.uid();
  if my_email is null then return null; end if;

  select * into inv from public.staff_invitations
   where email = lower(my_email) and claimed_at is null;
  if not found then return null; end if;

  insert into public.user_roles (user_id, role)
  values (auth.uid(), inv.role)
  on conflict (user_id) do update set role = excluded.role;

  update public.staff_invitations set claimed_at = now() where id = inv.id;

  perform public.write_audit('staff.role_claimed', null,
    jsonb_build_object('email', lower(my_email), 'role', inv.role));
  return inv.role;
end;
$$;

grant execute on function public.claim_staff_role() to authenticated;


create or replace function public.list_staff_invitations()
returns table (id uuid, email text, role text, invited_at timestamptz, claimed_at timestamptz)
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_staff() then raise exception 'Not authorised.'; end if;
  return query
    select i.id, i.email, i.role, i.invited_at, i.claimed_at
    from public.staff_invitations i order by i.invited_at desc;
end;
$$;

grant execute on function public.list_staff_invitations() to authenticated;


create or replace function public.delete_staff_invitation(p_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare inv public.staff_invitations%rowtype;
begin
  if not public.has_role('approver') then
    raise exception 'Only an approver may remove a colleague invitation.';
  end if;
  select * into inv from public.staff_invitations where id = p_id;
  if not found then raise exception 'Invitation not found.'; end if;

  perform public.write_audit('staff.invitation_deleted', null,
    jsonb_build_object('email', inv.email, 'role', inv.role));
  delete from public.staff_invitations where id = p_id;
end;
$$;

grant execute on function public.delete_staff_invitation(uuid) to authenticated;
