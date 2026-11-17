-- ─────────────────────────────────────────────────────────────
-- Who moved the stock, by name — 2026-10-05
--
-- The phone stock app is signed in once and stays signed in, so the login
-- says which PHONE recorded a movement, not which person was holding it.
-- Stock staff now tap their own name before they record anything, and that
-- name is written onto the movement.
--
--   staff_id   the login the phone is signed in with — as before
--   signed_by  the person who tapped their name — new for phone movements
--
-- The Transfers history already shows both, one under the other.
--
-- THE NAMES COME FROM A LIST
--   stock_handlers is kept by the Big Boss. A name that is not on it is
--   refused by the database, so the record cannot carry an invented name,
--   and "Kofi", "kofi" and "Kofi A." cannot become three people.
--
--   A tapped name is not proof: anyone holding the phone can tap a
--   colleague's. It is a record of who SAID they did it, which is what was
--   asked for. If that ever needs to be stronger, a PIN column here and one
--   check in record_stock_movement() is the whole change.
--
-- Requires 20261005_cross_line_transfers.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.stock_movement_requests') is null then
    raise exception 'Run 20261005_cross_line_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The list ───────────────────────────────────────────────
create table if not exists public.stock_handlers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 2 and 60),
  created_at timestamptz not null default now()
);
-- One entry per person, however it is capitalised.
create unique index if not exists stock_handlers_name_key
  on public.stock_handlers (upper(btrim(name)));

alter table public.stock_handlers enable row level security;

drop policy if exists stock_handlers_read on public.stock_handlers;
create policy stock_handlers_read on public.stock_handlers
  for select to authenticated using (true);

drop policy if exists stock_handlers_superboss_write on public.stock_handlers;
create policy stock_handlers_superboss_write on public.stock_handlers
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ── 2. record_stock_movement takes the name ───────────────────
-- Dropped rather than overloaded: two versions differing only by a trailing
-- argument would make every call that leaves it out ambiguous.
drop function if exists public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz);

create or replace function public.record_stock_movement(
  p_request_id uuid,
  p_kind       text,
  p_from_line  text,
  p_from       text,
  p_to_line    text,
  p_to         text,
  p_items      jsonb,
  p_party      text default null,
  p_note       text default null,
  p_when       timestamptz default now(),
  p_done_by    text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_result jsonb;
  v_to     text := coalesce(p_to_line, 'main');
  v_from   text := coalesce(p_from_line, v_to);
  v_typed  text := btrim(coalesce(p_done_by, ''));
  v_name   text;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_request_id is null then
    raise exception 'A request ID is required';
  end if;
  if v_to not in ('main', 'dahua') or v_from not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  -- Stored as the list spells it, not as the phone sent it.
  if v_typed <> '' then
    select h.name into v_name
      from public.stock_handlers h
     where upper(btrim(h.name)) = upper(v_typed);
    if not found then
      raise exception '% is not on the stock staff list', v_typed;
    end if;
  end if;

  begin
    insert into public.stock_movement_requests (request_id, created_by)
    values (p_request_id, auth.uid());
  exception when unique_violation then
    select created_by, result into v_owner, v_result
      from public.stock_movement_requests where request_id = p_request_id;
    if v_owner is distinct from auth.uid() then
      raise exception 'That request belongs to someone else';
    end if;
    return v_result || jsonb_build_object('duplicate', true);
  end;

  if p_kind = 'move' then
    if v_from <> v_to then
      select to_jsonb(t) into v_result
        from public.cross_transfer_stock(v_from, p_from, v_to, p_to, p_items, p_note, p_when) t;
    elsif v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    end if;
  elsif p_kind = 'receive' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  elsif p_kind = 'return' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_return_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.return_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  else
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;

  -- The movement functions stamp the login's own name. Where a person has
  -- said who they are, theirs replaces it. Matched on the reference: TRF and
  -- DH-TRF numbers each live in one table, an XTR number lives in both, and
  -- both copies should name the same person.
  if v_name is not null then
    update public.stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    update public.dahua_stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    v_result := v_result || jsonb_build_object('signed_by', v_name);
  end if;

  update public.stock_movement_requests
     set result = v_result
   where request_id = p_request_id;

  return v_result;
end $$;

revoke all on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text)
  from public, anon;
grant execute on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text)
  to authenticated;

-- ── Verification (run after the statements above) ─────────────
-- Who has been recording movements from the phones, most recent first:
--
-- select t.transfer_number, t.transferred_at, t.signed_by as person, t.staff_id as phone_login,
--        t.from_warehouse, t.to_warehouse
--   from public.stock_transfers t
--  order by t.transferred_at desc
--  limit 50;
