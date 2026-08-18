-- ============================================================
-- Fix 03 — vendors could not save their bank details
--
--   permission denied for table vendor_bank_details
--
-- The portal was writing to that table directly from the browser. But
-- the whole point of the design is that nobody holds table privileges
-- on it — reads go through staff_reveal_bank_details(), which audits
-- first. Writes were left as a direct upsert, which contradicts that
-- and, once privileges were revoked, simply failed.
--
-- The fix makes writes work the same way reads do: through a function
-- that authorises the caller. The vendor's browser never touches the
-- table, so no grant is needed and none is given.
--
-- Paste this whole file into the Supabase SQL editor and run it.
-- Safe to re-run.
-- ============================================================

create or replace function public.save_bank_details(
  p_beneficiary_name text,
  p_bank_name_addr   text,
  p_account_number   text,
  p_ifsc_code        text default null,
  p_swift_code       text default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v public.vendors%rowtype;
begin
  -- You may only ever write your own bank details, and only while your
  -- registration is still a draft. Once submitted it is frozen; staff
  -- must send it back before anything can change.
  select * into v from public.vendors where user_id = auth.uid();
  if not found then
    raise exception 'No registration found for this account.';
  end if;
  if v.status <> 'draft' then
    raise exception 'This registration has already been submitted and cannot be edited.';
  end if;

  insert into public.vendor_bank_details
    (vendor_id, beneficiary_name, bank_name_addr,
     account_number, ifsc_code, swift_code, updated_at)
  values
    (v.id,
     nullif(trim(p_beneficiary_name), ''),
     nullif(trim(p_bank_name_addr), ''),
     nullif(trim(p_account_number), ''),
     nullif(trim(p_ifsc_code), ''),
     nullif(trim(p_swift_code), ''),
     now())
  on conflict (vendor_id) do update
     set beneficiary_name = excluded.beneficiary_name,
         bank_name_addr   = excluded.bank_name_addr,
         account_number   = excluded.account_number,
         ifsc_code        = excluded.ifsc_code,
         swift_code       = excluded.swift_code,
         updated_at       = now();
end;
$$;

grant execute on function public.save_bank_details(text, text, text, text, text)
  to authenticated;

-- Now that the only write path is the function above, take away the
-- direct write privileges too. The RLS policies on the table are left
-- in place deliberately: if a future migration re-grants privileges by
-- accident, they still stand between a vendor and someone else's row.
revoke insert, update, delete on public.vendor_bank_details from anon, authenticated;
