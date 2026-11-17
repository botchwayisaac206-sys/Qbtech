-- ─────────────────────────────────────────────────────────────
-- Dahua stock moves wait for the Big Boss's approval — 2026-10-17
--
-- Until now a Dahua move, delivery or return entered by staff changed the
-- stock the moment it was saved. From now on, one entered by staff is a
-- REQUEST: it is listed for the Big Boss, and only when he approves it does
-- the stock change. If he rejects it, nothing changes.
--
--   staff save a Dahua movement   →  a request, DH-REQ-2026-0001, "pending"
--   Big Boss approves it          →  the movement is made, as before, under
--                                    its usual DH-TRF / DH-RCV / DH-RNA (or
--                                    XTR) number, credited to the staff
--                                    member who asked, at the time they asked
--   Big Boss rejects it           →  marked rejected, with his reason; the
--                                    stock is untouched
--
-- What counts as a Dahua movement: a move between Dahua warehouses, a
-- delivery or return into a Dahua warehouse, and a move between the main
-- shop and Dahua (in either direction). Main-shop movements are unchanged.
--
-- The Big Boss's own movements are applied at once — he is the approver.
--
-- HOW IT IS ENFORCED
--   In the database, not just on screen. The four functions that change
--   Dahua stock are renamed to *_apply and replaced by thin versions that
--   let only the Big Boss through. Staff — from the Dahua portal, the main
--   Transfers tab or the phone app — go through request_dahua_movement(),
--   and record_stock_movement() (the phone app's path) turns their Dahua
--   movements into requests by itself.
--
--   NOTE FOR LATER MIGRATIONS: change the *_apply functions, not the thin
--   ones. Replacing dahua_transfer_stock() with a full body again would
--   switch the approval step off.
--
-- Requires 20261006_stock_staff_passwords.sql and
-- 20261005_no_duplicate_names_on_moves.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text, uuid)') is null then
    raise exception 'Run 20261006_stock_staff_passwords.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The functions that move Dahua stock become *_apply ─────
do $$
begin
  if to_regprocedure('public.dahua_transfer_stock_apply(text, text, jsonb, text, timestamptz)') is null then
    alter function public.dahua_transfer_stock(text, text, jsonb, text, timestamptz) rename to dahua_transfer_stock_apply;
  end if;
  if to_regprocedure('public.dahua_receive_stock_apply(text, jsonb, text, text, timestamptz)') is null then
    alter function public.dahua_receive_stock(text, jsonb, text, text, timestamptz) rename to dahua_receive_stock_apply;
  end if;
  if to_regprocedure('public.dahua_return_stock_apply(text, jsonb, text, text, timestamptz, text)') is null then
    alter function public.dahua_return_stock(text, jsonb, text, text, timestamptz, text) rename to dahua_return_stock_apply;
  end if;
  if to_regprocedure('public.cross_transfer_stock_apply(text, text, text, text, jsonb, text, timestamptz)') is null then
    alter function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz) rename to cross_transfer_stock_apply;
  end if;
end $$;

-- Reachable only through the thin versions below and the approval step.
revoke all on function public.dahua_transfer_stock_apply(text, text, jsonb, text, timestamptz)                from public, anon, authenticated;
revoke all on function public.dahua_receive_stock_apply(text, jsonb, text, text, timestamptz)                 from public, anon, authenticated;
revoke all on function public.dahua_return_stock_apply(text, jsonb, text, text, timestamptz, text)            from public, anon, authenticated;
revoke all on function public.cross_transfer_stock_apply(text, text, text, text, jsonb, text, timestamptz)    from public, anon, authenticated;

-- ── 2. The thin versions: the Big Boss straight through, staff refused ──
create or replace function public.dahua_needs_approval()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'A Dahua stock movement by staff needs the Big Boss''s approval — send it for approval instead.'
      using errcode = '42501';
  end if;
end $$;

create or replace function public.dahua_transfer_stock(
  p_from text, p_to text, p_items jsonb, p_note text default null, p_when timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.dahua_transfer_stock_apply(p_from, p_to, p_items, p_note, p_when);
end $$;

create or replace function public.dahua_receive_stock(
  p_to text, p_items jsonb, p_supplier text default null, p_note text default null, p_when timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.dahua_receive_stock_apply(p_to, p_items, p_supplier, p_note, p_when);
end $$;

create or replace function public.dahua_return_stock(
  p_to text, p_items jsonb, p_customer text default null, p_note text default null, p_when timestamptz default now(), p_spoilt text default 'SPOILT'
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.dahua_return_stock_apply(p_to, p_items, p_customer, p_note, p_when, p_spoilt);
end $$;

-- Every move between the main shop and Dahua changes Dahua stock on one side.
create or replace function public.cross_transfer_stock(
  p_from_line text, p_from text, p_to_line text, p_to text, p_items jsonb, p_note text default null, p_when timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.cross_transfer_stock_apply(p_from_line, p_from, p_to_line, p_to, p_items, p_note, p_when);
end $$;

grant execute on function public.dahua_transfer_stock(text, text, jsonb, text, timestamptz)              to authenticated;
grant execute on function public.dahua_receive_stock(text, jsonb, text, text, timestamptz)               to authenticated;
grant execute on function public.dahua_return_stock(text, jsonb, text, text, timestamptz, text)          to authenticated;
grant execute on function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)  to authenticated;

-- ── 3. Requests ───────────────────────────────────────────────
create table if not exists public.dahua_movement_requests (
  id                 uuid primary key default gen_random_uuid(),
  request_number     text not null unique,
  kind               text not null check (kind in ('move', 'receive', 'return')),
  from_line          text check (from_line in ('main', 'dahua')),
  from_warehouse     text,
  to_line            text not null check (to_line in ('main', 'dahua')),
  to_warehouse       text not null,
  items              jsonb not null,
  party              text,       -- the supplier on a delivery, the buyer on a return
  note               text,
  requested_at       timestamptz not null default now(),
  requested_by       uuid references auth.users(id) on delete set null,
  requested_staff_id text,       -- the login it was asked from
  requested_name     text,       -- the person: the name tapped on the phone, or the login's name
  status             text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_at         timestamptz,
  decided_by         uuid references auth.users(id) on delete set null,
  reject_reason      text,
  transfer_number    text        -- the movement it became, once approved
);
create index if not exists dahua_movement_requests_pending_idx on public.dahua_movement_requests (requested_at) where status = 'pending';
create index if not exists dahua_movement_requests_when_idx on public.dahua_movement_requests (requested_at desc);

alter table public.dahua_movement_requests enable row level security;
-- Bosses see every request; staff see their own, to know what became of them.
drop policy if exists dahua_movement_requests_read on public.dahua_movement_requests;
create policy dahua_movement_requests_read on public.dahua_movement_requests
  for select to authenticated
  using ((select public.is_boss()) or requested_by = (select auth.uid()));
-- Written only by the functions below.

drop trigger if exists trg_audit_dahua_movement_requests on public.dahua_movement_requests;
create trigger trg_audit_dahua_movement_requests
  after insert or update or delete on public.dahua_movement_requests
  for each row execute function public.fn_audit();

-- ── 4. Asking ─────────────────────────────────────────────────
create or replace function public.request_dahua_movement(
  p_kind      text,
  p_from_line text,
  p_from      text,
  p_to_line   text,
  p_to        text,
  p_items     jsonb,
  p_party     text default null,
  p_note      text default null,
  p_when      timestamptz default now(),
  p_done_by   text default null
) returns public.dahua_movement_requests
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.dahua_movement_requests;
  v_to    text := coalesce(p_to_line, 'dahua');
  v_from  text := case when p_kind = 'move' then coalesce(p_from_line, v_to) else null end;
  v_yr    text := to_char(now(), 'YYYY');
  v_n     text;
  v_try   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_kind not in ('move', 'receive', 'return') then
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;
  if v_to not in ('main', 'dahua') or (v_from is not null and v_from not in ('main', 'dahua')) then
    raise exception 'Unknown stock line';
  end if;
  if v_to <> 'dahua' and coalesce(v_from, '') <> 'dahua' then
    raise exception 'Only Dahua stock movements go for approval';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is the stock going?';
  end if;
  if p_kind = 'move' and (p_from is null or btrim(p_from) = '' or (p_from = p_to and v_from = v_to)) then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item';
  end if;

  for v_try in 1..8 loop
    begin
      select 'DH-REQ-' || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_n
        from public.dahua_movement_requests where request_number like 'DH-REQ-' || v_yr || '-%';
      insert into public.dahua_movement_requests
        (request_number, kind, from_line, from_warehouse, to_line, to_warehouse, items, party, note,
         requested_at, requested_by, requested_staff_id, requested_name)
      values
        (v_n, p_kind, v_from, case when p_kind = 'move' then p_from end, v_to, p_to, p_items,
         nullif(btrim(coalesce(p_party, '')), ''), nullif(btrim(coalesce(p_note, '')), ''),
         coalesce(p_when, now()), auth.uid(), public.current_staff_id(),
         coalesce(nullif(btrim(coalesce(p_done_by, '')), ''), public.current_staff_name()))
      returning * into v_rec;
      return v_rec;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;
end $$;

-- ── 5. Approving and rejecting ────────────────────────────────
create or replace function public.approve_dahua_movement(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req    public.dahua_movement_requests;
  v_number text;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can approve stock movements';
  end if;
  select * into v_req from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'That request was already %', v_req.status;
  end if;

  -- Made exactly as it would have been if it had been applied at once, and
  -- dated when it was asked for, not when it was approved.
  if v_req.kind = 'move' and v_req.from_line <> v_req.to_line then
    select t.transfer_number into v_number
      from public.cross_transfer_stock_apply(v_req.from_line, v_req.from_warehouse, v_req.to_line, v_req.to_warehouse,
                                             v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'move' then
    select t.transfer_number into v_number
      from public.dahua_transfer_stock_apply(v_req.from_warehouse, v_req.to_warehouse, v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'receive' then
    select t.transfer_number into v_number
      from public.dahua_receive_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at) t;
  else
    select t.transfer_number into v_number
      from public.dahua_return_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at, 'SPOILT') t;
  end if;

  -- The movement is the staff member's, not the approver's.
  update public.dahua_stock_transfers
     set signed_by = v_req.requested_name, staff_id = v_req.requested_staff_id,
         created_by = coalesce(v_req.requested_by, created_by)
   where transfer_number = v_number;
  update public.stock_transfers
     set signed_by = v_req.requested_name, staff_id = v_req.requested_staff_id,
         created_by = coalesce(v_req.requested_by, created_by)
   where transfer_number = v_number;

  update public.dahua_movement_requests
     set status = 'approved', decided_at = now(), decided_by = auth.uid(), transfer_number = v_number
   where id = p_id;

  return jsonb_build_object('request_number', v_req.request_number, 'transfer_number', v_number);
end $$;

create or replace function public.reject_dahua_movement(p_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_status text;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can reject stock movements';
  end if;
  select status into v_status from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_status <> 'pending' then
    raise exception 'That request was already %', v_status;
  end if;
  update public.dahua_movement_requests
     set status = 'rejected', decided_at = now(), decided_by = auth.uid(),
         reject_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_id;
end $$;

revoke all on function public.request_dahua_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) from public, anon;
revoke all on function public.approve_dahua_movement(uuid)       from public, anon;
revoke all on function public.reject_dahua_movement(uuid, text)  from public, anon;
revoke all on function public.dahua_needs_approval()             from public, anon;
grant execute on function public.request_dahua_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) to authenticated;
grant execute on function public.approve_dahua_movement(uuid)      to authenticated;
grant execute on function public.reject_dahua_movement(uuid, text) to authenticated;
grant execute on function public.dahua_needs_approval()            to authenticated;

-- ── 6. The phone app's path turns staff Dahua movements into requests ──
-- Same as in 20261006_stock_staff_passwords.sql, with one step added before
-- the movement is made: a Dahua movement by staff is filed as a request and
-- answered with {"pending": true, ...} instead.
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
  p_done_by    text default null,
  p_done_token uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner   uuid;
  v_result  jsonb;
  v_to      text := coalesce(p_to_line, 'main');
  v_from    text := coalesce(p_from_line, v_to);
  v_typed   text := btrim(coalesce(p_done_by, ''));
  v_name    text;
  v_handler uuid;
  v_req     public.dahua_movement_requests;
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

  if v_typed <> '' then
    select h.id, h.name into v_handler, v_name
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

  if v_handler is not null
     and exists (select 1 from public.stock_handler_secrets s where s.handler_id = v_handler)
     and not exists (select 1 from public.stock_handler_tokens t
                      where t.handler_id = v_handler and t.token = p_done_token) then
    raise exception '% must enter their password on this phone again before this can be saved', v_name;
  end if;

  -- A Dahua movement by staff goes to the Big Boss for approval.
  if not (select public.is_superboss())
     and (v_to = 'dahua' or (p_kind = 'move' and v_from = 'dahua')) then
    select * into v_req
      from public.request_dahua_movement(p_kind, case when p_kind = 'move' then v_from end, p_from, v_to, p_to,
                                         p_items, p_party, p_note, p_when, v_name);
    v_result := jsonb_build_object(
      'pending', true, 'request_number', v_req.request_number,
      'transfer_number', v_req.request_number, 'kind', p_kind,
      'to_warehouse', p_to, 'signed_by', v_req.requested_name);
    update public.stock_movement_requests set result = v_result where request_id = p_request_id;
    return v_result;
  end if;

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

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- What is waiting for approval:
--
-- select request_number, kind, from_warehouse, to_warehouse, requested_name, requested_at, items
--   from public.dahua_movement_requests where status = 'pending' order by requested_at;
