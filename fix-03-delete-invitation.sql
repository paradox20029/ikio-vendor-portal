-- ============================================================
-- Fix 04 — staff can delete an invitation
--
-- vendor_email is unique, so a mistyped or abandoned invitation blocks
-- that address from ever being invited again. There was no way to
-- remove one except by hand in the SQL editor.
--
-- Deletion goes through a function for the same reason everything else
-- does: the table has no write privileges granted to anyone, and the
-- removal has to be authorised and recorded. The audit row is written
-- BEFORE the delete, so what was removed and by whom survives the
-- record it describes.
--
-- Paste into the Supabase SQL editor and run. Safe to re-run.
-- ============================================================

create or replace function public.delete_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  inv public.vendor_invitations%rowtype;
begin
  select * into inv from public.vendor_invitations where id = p_invitation_id;
  if not found then
    raise exception 'Invitation not found.';
  end if;

  -- Same rule as reading them: your own, or anything if you are an approver.
  if not (public.is_staff()
          and (inv.allocated_staff_id = auth.uid() or public.has_role('approver'))) then
    raise exception 'Not authorised to delete this invitation.';
  end if;

  perform public.write_audit('invitation.deleted', inv.vendor_id,
    jsonb_build_object('email',       inv.vendor_email,
                       'vendor_name', inv.vendor_name,
                       'status',      inv.status));

  delete from public.vendor_invitations where id = p_invitation_id;
end;
$$;

grant execute on function public.delete_invitation(uuid) to authenticated;

-- Note: this removes the invitation only. If the vendor already signed in,
-- their account and any registration they started remain. To clear a test
-- vendor completely, see admin-queries.sql, and delete their user under
-- Authentication -> Users in the dashboard.
