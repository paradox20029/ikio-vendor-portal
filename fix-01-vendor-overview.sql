-- ============================================================
-- Fix 01 — vendor_overview could not be read by anyone
--
-- Found by running the leak test against the live project.
--
-- The view was declared with security_invoker = true so that each
-- caller's own row-level security applies. But it also joined
-- vendor_bank_details, and SELECT on that table is revoked from
-- everyone by design. Postgres therefore refused the whole view for
-- every caller, staff included:
--
--   42501: permission denied for table vendor_bank_details
--
-- The masked account has to come from something that can read the
-- table without the caller being able to. That is a security-definer
-- function, with its own authorisation check — the view's RLS cannot
-- protect a function that is also callable directly over the API.
--
-- Paste this whole file into the Supabase SQL editor and run it.
-- Safe to re-run.
-- ============================================================

create or replace function public.bank_mask(p_vendor_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  acct text;
  allowed boolean;
begin
  -- This runs as the owner, so row-level security does NOT filter the
  -- lookups below. Authorisation is therefore explicit: you may see the
  -- masked tail only for your own registration, for a vendor allocated
  -- to you, or as an approver.
  select exists (
    select 1 from public.vendors v
    where v.id = p_vendor_id
      and ( v.user_id = auth.uid()
            or (public.is_staff() and v.allocated_staff_id = auth.uid())
            or public.has_role('approver') )
  ) into allowed;

  if not allowed then
    return null;
  end if;

  select account_number into acct
    from public.vendor_bank_details where vendor_id = p_vendor_id;

  if acct is null then
    return null;
  end if;

  -- Last four only. The full number is available solely through
  -- staff_reveal_bank_details(), which writes an audit row first.
  return '••••' || right(acct, 4);
end;
$$;

grant execute on function public.bank_mask(uuid) to authenticated;


-- Rebuilt without touching vendor_bank_details directly.
--
-- Dropped first, not "create or replace". CREATE OR REPLACE VIEW may only
-- append columns — it cannot reorder or rename them, and this rebuild
-- changes the order. Replacing in place fails with:
--   42P16: cannot change name of view column "has_bank_details" to "account_masked"
-- Dropping a view destroys no data; it is only a stored query.
drop view if exists public.vendor_overview;

create view public.vendor_overview
with (security_invoker = true) as
select
  v.id, v.company_name, v.country, v.region, v.city, v.pin_code,
  v.payment_terms, v.order_currency, v.inco_terms,
  v.contact_sales, v.email_sales, v.contact_finance, v.email_finance,
  v.mobile_no, v.telephone_no,
  v.pan_no, v.tan_no, v.gstin_no, v.msmed_covered, v.nature_of_work,
  v.status, v.remarks, v.submitted_at, v.checked_at, v.approved_at,
  v.allocated_staff_id,
  m.masked as account_masked,
  (m.masked is not null) as has_bank_details,
  (select count(*) from public.vendor_documents d where d.vendor_id = v.id) as doc_count
from public.vendors v
left join lateral (select public.bank_mask(v.id) as masked) m on true;

grant select on public.vendor_overview to authenticated;


-- ============================================================
-- Fix 02 — claim_invitation() wrote to a column that does not exist
--
-- It inserted into vendors(..., email, ...), but that table has
-- email_sales and email_finance, no plain "email". PostgreSQL does not
-- check column names inside a plpgsql body when the function is
-- created — only the syntax — which is why the schema reported success
-- and this would have failed at runtime instead, on the very first
-- vendor sign-in:
--
--   column "email" of relation "vendors" does not exist
--
-- The invitation is addressed to the Finance & Accounts contact, so
-- that is the correct column.
-- ============================================================

create or replace function public.claim_invitation()
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  inv public.vendor_invitations%rowtype;
  my_email text;
  new_vendor uuid;
begin
  select email into my_email from auth.users where id = auth.uid();
  if my_email is null then raise exception 'Not signed in.'; end if;

  select * into inv from public.vendor_invitations
   where vendor_email = lower(my_email);
  if not found then
    raise exception 'No invitation exists for this email address.';
  end if;
  if inv.status = 'cancelled' then
    raise exception 'This invitation has been cancelled.';
  end if;
  if inv.expires_at < now() then
    update public.vendor_invitations set status = 'expired' where id = inv.id;
    raise exception 'This invitation has expired. Please ask your contact at IKIO to reissue it.';
  end if;

  if inv.vendor_id is not null then
    return inv.vendor_id;                      -- already claimed; idempotent
  end if;

  insert into public.vendors (user_id, company_name, email_finance, allocated_staff_id)
  values (auth.uid(), inv.vendor_name, my_email, inv.allocated_staff_id)
  on conflict (user_id) do update set allocated_staff_id = excluded.allocated_staff_id
  returning id into new_vendor;

  update public.vendor_invitations
     set vendor_user_id = auth.uid(), vendor_id = new_vendor, status = 'registered'
   where id = inv.id;

  perform public.write_audit('invitation.claimed', new_vendor, null);
  return new_vendor;
end;
$$;

grant execute on function public.claim_invitation() to authenticated;
