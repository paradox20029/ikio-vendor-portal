-- ============================================================
-- Vendor Registration Portal — IKIO Solutions Private Limited
-- Fields mirror the existing "VRF ISPL" paper form.
-- Paste into Supabase SQL editor and run once, top to bottom.
-- Safe to re-run: everything is idempotent.
-- ============================================================

-- ---------- 1. Roles -----------------------------------------
-- The paper form has three internal sign-offs: Initiated By,
-- Checked By, Approved By. Those become roles here, so the
-- portal keeps the same separation of duties rather than
-- collapsing it into one "admin".

create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null check (role in ('initiator','checker','approver')),
  granted_at timestamptz not null default now()
);

alter table public.user_roles enable row level security;

-- No policy = no access through the API for anon/authenticated.
-- Roles are never read from auth.users.raw_user_meta_data, because a
-- vendor holding the public anon key can edit their own metadata.
revoke all on public.user_roles from anon, authenticated;

create or replace function public.has_role(p_role text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.user_roles
    where user_id = auth.uid() and role = p_role
  );
$$;

-- Any internal staff member, of any of the three roles.
create or replace function public.is_staff()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid());
$$;

grant execute on function public.has_role(text) to authenticated;
grant execute on function public.is_staff() to authenticated;


-- ---------- 2. Vendors (non-sensitive) ------------------------

create table if not exists public.vendors (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null unique references auth.users(id) on delete cascade,

  -- 1–4: identity and address
  company_name   text,
  country        text,
  region         text,          -- state, for Indian vendors
  address1       text,
  address2       text,
  address3       text,
  city           text,
  pin_code       text,

  -- 5–7: commercial terms
  payment_terms  text,
  order_currency text,          -- INR, USD, EUR, …
  inco_terms     text,          -- EXW, FOB, CIF, DDP, …

  -- 8–10: telephony
  telephone_no   text,
  mobile_no      text,
  fax_no         text,

  -- 11–14: two separate contacts, as on the paper form
  contact_sales        text,
  email_sales          text,
  contact_finance      text,
  email_finance        text,

  -- 15–17: statutory. Nullable: overseas vendors have none of these.
  pan_no         text,
  tan_no         text,
  gstin_no       text,

  -- 19–20: MSMED
  msmed_covered  boolean,
  -- certificate itself lives in vendor_documents

  -- 21
  nature_of_work text,

  -- workflow: mirrors Initiated / Checked / Approved
  status         text not null default 'draft'
                 check (status in ('draft','submitted','checked','approved','rejected')),
  remarks        text,

  initiated_by   uuid references auth.users(id),
  initiated_at   timestamptz,
  checked_by     uuid references auth.users(id),
  checked_at     timestamptz,
  approved_by    uuid references auth.users(id),
  approved_at    timestamptz,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  submitted_at   timestamptz,

  -- Format checks, all NULL-tolerant so drafts can be saved half-finished
  -- and so overseas vendors are not blocked. Completeness is enforced at
  -- submit time by submit_registration(), which applies the Indian rules
  -- only when country = 'India'.
  constraint gstin_format check (gstin_no is null or gstin_no ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  constraint pan_format   check (pan_no   is null or pan_no   ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint tan_format   check (tan_no   is null or tan_no   ~ '^[A-Z]{4}[0-9]{5}[A-Z]$'),
  constraint pin_format   check (pin_code is null or pin_code ~ '^[0-9A-Za-z \-]{4,10}$')
);

-- Each vendor is owned by one staff member. Added separately so this is
-- safe to run over an existing install.
alter table public.vendors
  add column if not exists allocated_staff_id uuid references auth.users(id);

alter table public.vendors enable row level security;

drop policy if exists vendor_reads_own     on public.vendors;
drop policy if exists vendor_inserts_own   on public.vendors;
drop policy if exists vendor_updates_draft on public.vendors;
drop policy if exists staff_reads_all      on public.vendors;
drop policy if exists staff_reads_allocated on public.vendors;

create policy vendor_reads_own on public.vendors
  for select to authenticated
  using (user_id = auth.uid());

create policy vendor_inserts_own on public.vendors
  for insert to authenticated
  with check (user_id = auth.uid());

-- A vendor may edit only while the form is still a draft. Once
-- submitted it freezes; only staff move it on, via RPC.
create policy vendor_updates_draft on public.vendors
  for update to authenticated
  using      (user_id = auth.uid() and status = 'draft')
  with check (user_id = auth.uid() and status = 'draft');

-- Staff see the vendors allocated to them. An approver sees everything,
-- because final sign-off cannot be blind to the queue it is signing off.
create policy staff_reads_allocated on public.vendors
  for select to authenticated
  using (
    (public.is_staff() and allocated_staff_id = auth.uid())
    or public.has_role('approver')
  );

-- No delete policy anywhere: vendor records are not deletable via the API.


-- ---------- 3. Bank details (sensitive) -----------------------
-- Separate table. The `authenticated` role has NO select policy on it —
-- not for vendors, not for staff. Every read goes through a
-- security-definer function that authorises the caller and writes an
-- audit row first. That is what makes the audit log truthful rather
-- than decorative.

create table if not exists public.vendor_bank_details (
  vendor_id        uuid primary key references public.vendors(id) on delete cascade,
  beneficiary_name text,                 -- 15
  bank_name_addr   text,                 -- 16, "Bank Name & Address" as one field
  account_number   text,                 -- 17
  ifsc_code        text,                 -- 18
  swift_code       text,                 -- overseas equivalent of IFSC
  updated_at       timestamptz not null default now(),

  constraint ifsc_format  check (ifsc_code      is null or ifsc_code      ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  constraint swift_format check (swift_code     is null or swift_code     ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  constraint acct_format  check (account_number is null or account_number ~ '^[0-9A-Z]{9,34}$')
);

alter table public.vendor_bank_details enable row level security;

drop policy if exists bank_insert_own_draft on public.vendor_bank_details;
drop policy if exists bank_update_own_draft on public.vendor_bank_details;

create policy bank_insert_own_draft on public.vendor_bank_details
  for insert to authenticated
  with check (exists (
    select 1 from public.vendors v
    where v.id = vendor_id and v.user_id = auth.uid() and v.status = 'draft'));

create policy bank_update_own_draft on public.vendor_bank_details
  for update to authenticated
  using (exists (
    select 1 from public.vendors v
    where v.id = vendor_id and v.user_id = auth.uid() and v.status = 'draft'))
  with check (exists (
    select 1 from public.vendors v
    where v.id = vendor_id and v.user_id = auth.uid() and v.status = 'draft'));

-- No direct access of any kind, in either direction. Reads go through
-- staff_reveal_bank_details() (which audits first), writes through
-- save_bank_details(). The policies above are kept as a second layer in
-- case privileges are ever re-granted by mistake.
revoke select, insert, update, delete on public.vendor_bank_details
  from anon, authenticated;


-- ---------- 4. Documents --------------------------------------
-- The paper form requires the MSMED certificate to be attached, so
-- uploads are not optional. Files go to a private Storage bucket;
-- this table holds the metadata.

create table if not exists public.vendor_documents (
  id           uuid primary key default gen_random_uuid(),
  vendor_id    uuid not null references public.vendors(id) on delete cascade,
  doc_type     text not null check (doc_type in
                 ('msmed_certificate','gst_certificate','pan_card',
                  'cancelled_cheque','signed_vrf','other')),
  storage_path text not null,
  file_name    text,
  uploaded_at  timestamptz not null default now(),
  verified_by  uuid references auth.users(id),
  verified_at  timestamptz
);

alter table public.vendor_documents enable row level security;

drop policy if exists doc_reads_own    on public.vendor_documents;
drop policy if exists doc_insert_draft on public.vendor_documents;
drop policy if exists doc_staff_reads  on public.vendor_documents;

create policy doc_reads_own on public.vendor_documents
  for select to authenticated
  using (exists (select 1 from public.vendors v
                 where v.id = vendor_id and v.user_id = auth.uid()));

create policy doc_insert_draft on public.vendor_documents
  for insert to authenticated
  with check (exists (
    select 1 from public.vendors v
    where v.id = vendor_id and v.user_id = auth.uid() and v.status = 'draft'));

create policy doc_staff_reads on public.vendor_documents
  for select to authenticated
  using (public.is_staff());

-- Storage bucket + its own policies. Path convention: <vendor_id>/<filename>,
-- so the first path segment is the ownership key.
insert into storage.buckets (id, name, public)
values ('vendor-docs', 'vendor-docs', false)
on conflict (id) do nothing;

drop policy if exists vdocs_insert_own on storage.objects;
drop policy if exists vdocs_read_own   on storage.objects;
drop policy if exists vdocs_read_staff on storage.objects;

create policy vdocs_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'vendor-docs'
    and exists (select 1 from public.vendors v
                where v.user_id = auth.uid()
                  and v.status = 'draft'
                  and v.id::text = (storage.foldername(name))[1]));

create policy vdocs_read_own on storage.objects
  for select to authenticated
  using (
    bucket_id = 'vendor-docs'
    and exists (select 1 from public.vendors v
                where v.user_id = auth.uid()
                  and v.id::text = (storage.foldername(name))[1]));

create policy vdocs_read_staff on storage.objects
  for select to authenticated
  using (bucket_id = 'vendor-docs' and public.is_staff());


-- ---------- 5. Audit log --------------------------------------
-- Append-only. No update or delete policy exists, and none should be
-- added: the value of this table is that rows cannot be walked back.

create table if not exists public.audit_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  actor       uuid,
  actor_email text,
  action      text not null,
  vendor_id   uuid,
  detail      jsonb
);

alter table public.audit_log enable row level security;

drop policy if exists staff_reads_audit on public.audit_log;

create policy staff_reads_audit on public.audit_log
  for select to authenticated
  using (public.is_staff());

revoke insert, update, delete on public.audit_log from anon, authenticated;

create or replace function public.write_audit(
  p_action text, p_vendor_id uuid, p_detail jsonb default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.audit_log (actor, actor_email, action, vendor_id, detail)
  values (auth.uid(),
          (select email from auth.users where id = auth.uid()),
          p_action, p_vendor_id, p_detail);
end;
$$;


-- ---------- 6. Vendor-facing RPC ------------------------------

create or replace function public.get_my_bank_last4()
returns table (masked text, ifsc_code text, bank_name_addr text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select '••••' || right(b.account_number, 4), b.ifsc_code, b.bank_name_addr
  from public.vendor_bank_details b
  join public.vendors v on v.id = b.vendor_id
  where v.user_id = auth.uid();
$$;

grant execute on function public.get_my_bank_last4() to authenticated;

-- The only write path into vendor_bank_details. The vendor's browser has
-- no privileges on that table at all, so this function is how the data
-- gets in — authorised, and only while the registration is a draft.
create or replace function public.save_bank_details(
  p_beneficiary_name text,
  p_bank_name_addr   text,
  p_account_number   text,
  p_ifsc_code        text default null,
  p_swift_code       text default null
) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.vendors%rowtype;
begin
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

-- Submit: validates completeness, freezes the record, audits.
-- Indian statutory fields are required only for Indian vendors;
-- overseas vendors need SWIFT instead of IFSC.
create or replace function public.submit_registration()
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.vendors%rowtype;
  b public.vendor_bank_details%rowtype;
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
    -- The paper form makes the certificate mandatory when MSMED = Yes.
    if v.msmed_covered and not exists (
         select 1 from public.vendor_documents d
         where d.vendor_id = v.id and d.doc_type = 'msmed_certificate') then
      raise exception 'MSMED certificate must be attached when covered under the Act.';
    end if;
  end if;

  select * into b from public.vendor_bank_details where vendor_id = v.id;
  if not found or b.account_number is null or b.beneficiary_name is null
     or b.bank_name_addr is null then
    raise exception 'Bank details are incomplete.';
  end if;
  if is_india and b.ifsc_code is null then
    raise exception 'IFSC code is required for Indian bank accounts.';
  end if;
  if not is_india and b.swift_code is null then
    raise exception 'SWIFT code is required for overseas bank accounts.';
  end if;

  update public.vendors
     set status = 'submitted', submitted_at = now(), updated_at = now()
   where id = v.id;

  perform public.write_audit('vendor.submitted', v.id, null);
  return 'submitted';
end;
$$;

grant execute on function public.submit_registration() to authenticated;


-- ---------- 7. Staff RPC --------------------------------------

-- The reveal. Authorises, audits, THEN returns. If the audit insert
-- fails the whole call rolls back and no data is returned.
create or replace function public.staff_reveal_bank_details(p_vendor_id uuid)
returns table (beneficiary_name text, bank_name_addr text,
               account_number text, ifsc_code text, swift_code text)
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  -- Allocation is enforced here too, not only in the list policy. Staff may
  -- reveal an account only for a vendor they own, or if they are an approver.
  if not exists (
    select 1 from public.vendors v
    where v.id = p_vendor_id
      and ((public.is_staff() and v.allocated_staff_id = auth.uid())
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

-- Workflow advance, enforcing the paper form's separation of duties:
-- submitted -> checked (checker) -> approved (approver).
-- The same person may not both check and approve a vendor.
create or replace function public.advance_status(
  p_vendor_id uuid, p_action text, p_remarks text default null)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.vendors%rowtype;
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
    if not public.is_staff() then raise exception 'Not authorised.'; end if;
    update public.vendors
       set status = 'rejected', remarks = p_remarks, updated_at = now()
     where id = p_vendor_id;

  elsif p_action = 'reopen' then
    -- Send back to the vendor for correction.
    if not public.is_staff() then raise exception 'Not authorised.'; end if;
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


-- ---------- 8. Staff list view --------------------------------
-- security_invoker means the caller's own RLS applies, so a vendor
-- querying this directly sees only their own row. It contains no
-- bank columns by construction.
--
-- The view must NOT join vendor_bank_details. SELECT on that table is
-- revoked from everyone, and under security_invoker Postgres checks
-- table privileges as the caller — so joining it makes the whole view
-- unreadable for staff too, with "permission denied for table
-- vendor_bank_details". The masked tail comes from bank_mask() instead,
-- which is security definer and carries its own authorisation check.

create or replace function public.bank_mask(p_vendor_id uuid)
returns text
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  acct text;
  allowed boolean;
begin
  -- Runs as owner, so RLS does not filter these lookups. Authorisation
  -- is explicit, because this function is callable directly over the API.
  select exists (
    select 1 from public.vendors v
    where v.id = p_vendor_id
      and ( v.user_id = auth.uid()
            or (public.is_staff() and v.allocated_staff_id = auth.uid())
            or public.has_role('approver') )
  ) into allowed;

  if not allowed then return null; end if;

  select account_number into acct
    from public.vendor_bank_details where vendor_id = p_vendor_id;
  if acct is null then return null; end if;

  return '••••' || right(acct, 4);
end;
$$;

grant execute on function public.bank_mask(uuid) to authenticated;

-- Dropped rather than replaced: CREATE OR REPLACE VIEW cannot reorder or
-- rename columns, so re-running an updated definition over an older one
-- fails with 42P16. A view holds no data, so dropping it costs nothing.
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


-- ---------- 9. Seed staff roles -------------------------------
-- Run AFTER each person has logged in once, so their auth user exists.
-- Give yourself 'approver'. Note that check and approve must be
-- different people — that is the point of the sign-off chain.

-- insert into public.user_roles (user_id, role)
-- select id, 'approver' from auth.users where email = 'armaan20029@gmail.com'
-- on conflict (user_id) do update set role = excluded.role;

-- insert into public.user_roles (user_id, role)
-- select id, 'checker'  from auth.users where email = 'staff-checker@ikio.example'
-- on conflict (user_id) do update set role = excluded.role;


-- ---------- 10. Invitations -----------------------------------
-- Staff invite a known supplier and allocate it to an owner up front.
-- Vendors never self-register: for a fixed list of ~512 suppliers,
-- invitation is both simpler and safer than open signup.
--
-- IMPORTANT — what the invitation id is NOT. It is a record of who was
-- invited, not a credential. Do not put it in a URL and treat possession
-- of it as proof of identity. A link that IS the login can be forwarded,
-- logged by a mail scanner or corporate proxy, and left in browser
-- history, and it binds the submission to whoever held the link rather
-- than to a person. For a form that carries bank details, that destroys
-- the one question the audit trail exists to answer.
--
-- The invitation email should instead trigger a Supabase magic link to
-- vendor_email. The vendor experience is identical — click a link, land
-- on the form — but auth.uid() then exists, RLS applies, and the record
-- names a person.

create table if not exists public.vendor_invitations (
  id                 uuid primary key default gen_random_uuid(),
  vendor_name        text not null,
  vendor_email       text not null,
  allocated_staff_id uuid not null references auth.users(id),
  vendor_user_id     uuid references auth.users(id),   -- set on first login
  vendor_id          uuid references public.vendors(id),
  status             text not null default 'pending'
                     check (status in ('pending','opened','registered','expired','cancelled')),
  invited_by         uuid references auth.users(id),
  invited_at         timestamptz not null default now(),
  expires_at         timestamptz not null default (now() + interval '30 days'),
  unique (vendor_email)
);

alter table public.vendor_invitations enable row level security;

drop policy if exists inv_staff_reads on public.vendor_invitations;

create policy inv_staff_reads on public.vendor_invitations
  for select to authenticated
  using (allocated_staff_id = auth.uid() or public.has_role('approver'));

revoke insert, update, delete on public.vendor_invitations from anon, authenticated;

-- Staff create invitations through this, so allocation and audit are not
-- optional and cannot be skipped by writing to the table directly.
create or replace function public.create_invitation(
  p_vendor_name text, p_vendor_email text, p_allocated_staff_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare new_id uuid;
begin
  if not public.is_staff() then
    raise exception 'Not authorised to invite vendors.';
  end if;
  if not exists (select 1 from public.user_roles where user_id = p_allocated_staff_id) then
    raise exception 'Vendors can only be allocated to a staff member.';
  end if;

  insert into public.vendor_invitations
    (vendor_name, vendor_email, allocated_staff_id, invited_by)
  values (p_vendor_name, lower(trim(p_vendor_email)), p_allocated_staff_id, auth.uid())
  returning id into new_id;

  perform public.write_audit('vendor.invited', null,
    jsonb_build_object('email', lower(trim(p_vendor_email)),
                       'allocated_to', p_allocated_staff_id));
  return new_id;
end;
$$;

grant execute on function public.create_invitation(text, text, uuid) to authenticated;

-- Populates the "allocate to" dropdown. Staff only — it exposes colleagues'
-- e-mail addresses, which vendors have no business seeing.
create or replace function public.list_staff()
returns table (id uuid, label text)
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_staff() then
    raise exception 'Not authorised.';
  end if;
  return query
    select u.id, (u.email || ' (' || r.role || ')')::text
    from public.user_roles r
    join auth.users u on u.id = r.user_id
    order by u.email;
end;
$$;

grant execute on function public.list_staff() to authenticated;

-- Called once, by the vendor, immediately after their first magic-link
-- login. It matches on the email the invitation was addressed to — which
-- the vendor has just proven they control by receiving the link — and
-- creates their vendor row already allocated to the right staff member.
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

  -- email_finance, not "email": the vendors table has no plain email column,
  -- and the invitation goes to the Finance & Accounts address by design.
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
