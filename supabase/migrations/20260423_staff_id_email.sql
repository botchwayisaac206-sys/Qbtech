-- ============================================================================
-- Store the staff's login email (= their staff ID) on user_roles so the
-- boss can see/search it without querying auth.users.
-- Format going forward: <handle>@qbnettech.com (e.g. isha@qbnettech.com).
-- Safe to run multiple times.
-- ============================================================================

alter table public.user_roles
  add column if not exists staff_id text;

-- Backfill staff_id for any existing staff from auth.users.email (service role only).
do $$
begin
  update public.user_roles ur
     set staff_id = u.email
    from auth.users u
   where u.id = ur.user_id
     and ur.staff_id is null;
end $$;
