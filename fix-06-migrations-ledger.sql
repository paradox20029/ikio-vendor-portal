-- ============================================================
-- Fix 07 — a migrations ledger, so "what's been applied" is a
-- fact in the database instead of a guess from outside it
--
-- Every fix so far has been verified by calling RPCs and checking
-- whether Postgres says "missing" — which requires guessing the exact
-- argument shape, and guessing wrong gives a false "missing" reading
-- (this happened twice in this project). That is not a reliable way
-- to answer "is fix-04 applied", especially across a new chat session
-- or a different person entirely.
--
-- This adds one small table recording which fix-*.sql files have run,
-- and a function anyone with staff access can call to read it. From
-- fix-07 onward, every fix file ends by recording itself here — that
-- is the new house convention, not optional.
--
-- Paste into the Supabase SQL editor and run. Safe to re-run.
-- ============================================================

create table if not exists public._migrations (
  filename   text primary key,
  applied_at timestamptz not null default now(),
  note       text
);

alter table public._migrations enable row level security;

drop policy if exists migrations_staff_read on public._migrations;

create policy migrations_staff_read on public._migrations
  for select to authenticated
  using (public.is_staff());

revoke insert, update, delete on public._migrations from anon, authenticated;

-- Callable with just the anon key, no session required — so a fresh
-- Claude Code session (or anyone else) can check real state over curl
-- in one request, the way every other verification in this project's
-- history has actually been done.
create or replace function public.list_applied_migrations()
returns table (filename text, applied_at timestamptz, note text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select filename, applied_at, note from public._migrations order by filename;
$$;

grant execute on function public.list_applied_migrations() to anon, authenticated;

-- Backfill: schema.sql and fix-01 through fix-05 are confirmed applied
-- as of 2026-08-19, verified by calling every RPC they define with a
-- correctly-shaped argument list and confirming a real response rather
-- than PGRST202. Recorded here so the ledger starts accurate.
insert into public._migrations (filename, note) values
  ('schema.sql',                     'Base schema — tables, RLS, roles, invitations.'),
  ('fix-01-vendor-overview.sql',     'bank_mask() + vendor_overview rebuild.'),
  ('fix-02-save-bank-details.sql',   'save_bank_details() RPC.'),
  ('fix-03-delete-invitation.sql',   'delete_invitation() RPC.'),
  ('fix-04-staff-management.sql',    'grant/revoke_staff_role, list_staff_detail.'),
  ('fix-05-staff-invitations.sql',   'viewer role, staff_invitations, invite_staff, claim_staff_role.'),
  ('fix-06-migrations-ledger.sql',   'This file.')
on conflict (filename) do nothing;
