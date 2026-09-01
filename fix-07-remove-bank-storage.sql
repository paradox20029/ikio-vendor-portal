-- ============================================================
-- Fix 08 — remove all banking storage from Supabase
--
-- Implements section 4 of Hybrid_Cloudflare_SAP_Bypass_Architecture
-- Option 1: Supabase keeps identity, RBAC, workflow state, audit and
-- non-sensitive vendor metadata. Account numbers, IFSC and SWIFT are
-- never persisted here again — they transit to SAP via a Cloudflare
-- Worker and live only in SAP Business One.
--
-- WHAT THIS DOES NOT DO
-- It does not build the Worker. Until the Worker exists, the portal
-- collects no banking data at all, and submit_registration() no longer
-- requires it. That is deliberate: a vendor who cannot submit is worse
-- than a vendor whose bank details are gathered separately for a few
-- weeks. Front-end config flag PORTAL_WORKER_URL controls whether the
-- banking step is shown; leave it empty until the Worker is live.
--
-- IRREVERSIBLE. This deletes real rows and drops a table. There is no
-- undo, and this project is on Supabase's free tier with no
-- point-in-time recovery. Everything currently stored is mock test data
-- per TEST_PLAN.md, which is why this is safe to run now — verify that
-- is still true before running:
--
--     select count(*) from public.vendor_bank_details;
--     select vendor_id, right(account_number,4) from public.vendor_bank_details;
--
-- If any row is a real supplier's account, stop and export it to SAP
-- first. Once dropped it cannot be recovered.
-- ============================================================


-- ---------- 1. Purge, explicitly and before dropping ----------
-- Done as its own statement so the deletion is a deliberate, visible
-- act rather than a side effect of DROP TABLE.

delete from public.vendor_bank_details;


-- ---------- 2. Remove every read/write path -------------------
-- Order matters: the view depends on bank_mask(), so the view is
-- rebuilt further down before bank_mask is dropped here.

drop view if exists public.vendor_overview;

drop function if exists public.save_bank_details(text, text, text, text, text);
drop function if exists public.staff_reveal_bank_details(uuid);
drop function if exists public.get_my_bank_last4();
drop function if exists public.bank_mask(uuid);

drop table if exists public.vendor_bank_details;


-- ---------- 3. SAP reference fields on vendors ----------------
-- The only thing Supabase keeps about a vendor's banking is a pointer
-- to the SAP draft that holds it, plus enough state to reconcile a
-- failed hand-off. No financial values, by construction.

alter table public.vendors
  add column if not exists sap_draft_id     text,
  add column if not exists sap_link_state   text not null default 'none',
  add column if not exists sap_linked_at    timestamptz,
  add column if not exists idempotency_key  uuid;

alter table public.vendors drop constraint if exists sap_link_state_check;
alter table public.vendors add constraint sap_link_state_check
  check (sap_link_state in ('none','pending','linked','failed'));

-- 'pending' is the state that makes reconciliation possible: the Worker
-- sets it before calling SAP, so a draft created but never linked is
-- findable rather than silently orphaned (section 5.3 of the spec).
create index if not exists vendors_sap_pending_idx
  on public.vendors (sap_link_state) where sap_link_state = 'pending';


-- ---------- 4. Submission no longer requires bank data --------
-- Same completeness rules as before minus the banking block. An Indian
-- vendor still needs PAN, GSTIN and an MSMED answer; an overseas vendor
-- still needs neither. Banking is now SAP's concern entirely.

create or replace function public.submit_registration()
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.vendors%rowtype;
  is_india boolean;
begin
  select * into v from public.vendors where user_id = auth.uid();
  if not found then
    raise exception 'No registration found for this account.';
  end if;
  if v.status <> 'draft' then
    raise exception 'This registration has already been submitted.';
  end if;

  if v.company_name is null or v.country is null or v.address1 is null
     or v.city is null or v.pin_code is null or v.mobile_no is null
     or v.contact_sales is null or v.email_sales is null
     or v.contact_finance is null or v.email_finance is null
     or v.payment_terms is null or v.order_currency is null
     or v.nature_of_work is null then
    raise exception 'Company details are incomplete.';
  end if;

  is_india := lower(coalesce(v.country,'')) in ('india','in');

  if is_india then
    if v.pan_no is null or v.gstin_no is null then
      raise exception 'PAN and GSTIN are required for Indian vendors.';
    end if;
    if v.msmed_covered is null then
      raise exception 'Please state whether you are covered under the MSMED Act.';
    end if;
    if v.msmed_covered and not exists (
         select 1 from public.vendor_documents d
         where d.vendor_id = v.id and d.doc_type = 'msmed_certificate') then
      raise exception 'MSMED certificate must be attached when covered under the Act.';
    end if;
  end if;

  update public.vendors
     set status = 'submitted', submitted_at = now(), updated_at = now()
   where id = v.id;

  perform public.write_audit('vendor.submitted', v.id, null);
  return 'submitted';
end;
$$;

grant execute on function public.submit_registration() to authenticated;


-- ---------- 5. Rebuilt view, no banking columns ---------------
-- account_masked and has_bank_details are gone. Staff see whether a SAP
-- draft is linked; the values themselves come from SAP via the Worker,
-- never from here.

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
  v.sap_draft_id,
  v.sap_link_state,
  (v.sap_draft_id is not null) as has_sap_draft,
  (select count(*) from public.vendor_documents d where d.vendor_id = v.id) as doc_count
from public.vendors v;

grant select on public.vendor_overview to authenticated;


-- ---------- 6. Worker-facing functions ------------------------
-- Called by the Cloudflare Worker using the service_role key, which
-- runs server-side and never reaches a browser. auth.uid() is null in
-- that context, so the acting user is passed explicitly and validated
-- by the Worker from a verified Supabase JWT before it calls these.

-- Marks intent to create a SAP draft. Call BEFORE contacting SAP so a
-- crash mid-call leaves a 'pending' row to reconcile against.
create or replace function public.sap_begin_link(
  p_vendor_id uuid, p_idempotency_key uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  update public.vendors
     set sap_link_state = 'pending',
         idempotency_key = p_idempotency_key,
         updated_at = now()
   where id = p_vendor_id;
end;
$$;

-- Records the SAP draft reference once SAP has confirmed creation.
create or replace function public.sap_complete_link(
  p_vendor_id uuid, p_sap_draft_id text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if p_sap_draft_id is null or trim(p_sap_draft_id) = '' then
    raise exception 'A SAP draft id is required to complete the link.';
  end if;
  update public.vendors
     set sap_draft_id = p_sap_draft_id,
         sap_link_state = 'linked',
         sap_linked_at = now(),
         updated_at = now()
   where id = p_vendor_id;
end;
$$;

-- Audit written on behalf of a user the Worker has authenticated.
-- Never records financial values — the Worker passes only metadata.
create or replace function public.write_audit_as(
  p_actor uuid, p_actor_email text, p_action text,
  p_vendor_id uuid, p_detail jsonb default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.audit_log (actor, actor_email, action, vendor_id, detail)
  values (p_actor, p_actor_email, p_action, p_vendor_id, p_detail);
end;
$$;

-- Deliberately NOT granted to anon or authenticated. These are
-- service_role only — reachable by the Worker, unreachable from any
-- browser holding the public anon key.
revoke execute on function public.sap_begin_link(uuid, uuid)      from anon, authenticated;
revoke execute on function public.sap_complete_link(uuid, text)   from anon, authenticated;
revoke execute on function public.write_audit_as(uuid, text, text, uuid, jsonb)
  from anon, authenticated;


-- ---------- 7. Reconciliation helper --------------------------
-- Section 5.3: find submissions where a SAP draft may exist but was
-- never linked back. Approver-only, read-only, no financial data.

create or replace function public.list_unlinked_sap_drafts()
returns table (vendor_id uuid, company_name text, idempotency_key uuid,
               submitted_at timestamptz, sap_link_state text)
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_role('approver') then
    raise exception 'Not authorised.';
  end if;
  return query
    select v.id, v.company_name, v.idempotency_key, v.submitted_at, v.sap_link_state
    from public.vendors v
    where v.sap_link_state in ('pending','failed')
    order by v.submitted_at nulls last;
end;
$$;

grant execute on function public.list_unlinked_sap_drafts() to authenticated;


-- ---------- 8. Verification -----------------------------------
-- Run these after applying. Both should confirm the boundary holds.

-- Should return zero rows — no column anywhere can hold an account number:
--   select table_name, column_name from information_schema.columns
--    where table_schema = 'public'
--      and (column_name ilike '%account_number%'
--           or column_name ilike '%ifsc%'
--           or column_name ilike '%swift%');

-- Should return zero rows — no function body references the dropped table:
--   select proname from pg_proc
--    where pronamespace = 'public'::regnamespace
--      and prosrc ilike '%vendor_bank_details%';


insert into public._migrations (filename, note) values
  ('fix-07-remove-bank-storage.sql',
   'Dropped vendor_bank_details + all bank RPCs. Added sap_draft_id/sap_link_state. Banking now transits to SAP via Cloudflare Worker, never stored.')
on conflict (filename) do nothing;
