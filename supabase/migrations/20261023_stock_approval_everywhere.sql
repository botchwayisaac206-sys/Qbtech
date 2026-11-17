-- ─────────────────────────────────────────────────────────────
-- Every staff stock movement waits for the Big Boss — 2026-10-23
--
-- 20261017_dahua_movement_approval.sql made Dahua movements by staff wait
-- for the Big Boss's approval. This does the same for the main shop, and
-- adds three things around it:
--
--   1. MAIN SHOP TOO
--      A move, delivery or return staff enter for the main shop is now a
--      request (REQ-2026-0001), like a Dahua one (DH-REQ-2026-0001). The
--      stock changes only when it is approved. The Big Boss's own
--      movements still apply at once.
--
--   2. AN APPROVED REQUEST CAN BE REVERSED
--      reverse_stock_request() undoes what the approval did, as a movement
--      of its own (REV-2026-0001, or DH-REV-… when only Dahua is involved):
--      units come back out of where they went and, on a move, back into
--      where they left. The original stays in the record; the request is
--      marked "reversed" with the reversal's number.
--
--   3. AUTO-ACCEPT AFTER 45 SECONDS
--      The Big Boss can switch on auto-accept. A request then approves
--      itself 45 seconds after it was filed, unless he has rejected it by
--      then. There is no timer in the database: settle_stock_requests()
--      approves whatever is due, and every screen that shows requests —
--      the staff member's who filed it included — calls it. Timed from
--      when the request reached the server (filed_at), not from the time
--      on the movement, so a phone that queued a move offline does not
--      skip the 45 seconds.
--
-- The request table keeps its name, dahua_movement_requests, and the old
-- request/approve/reject functions keep working (they call the new ones),
-- so a phone still running yesterday's app is not broken by this.
--
-- NOTE FOR LATER MIGRATIONS: as with Dahua, change transfer_stock_apply,
-- receive_stock_apply and return_stock_apply — not the thin versions.
--
-- Requires 20261017_dahua_movement_approval.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.dahua_movement_requests') is null then
    raise exception 'Run 20261017_dahua_movement_approval.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The main shop's movement functions become *_apply ──────
do $$
begin
  if to_regprocedure('public.transfer_stock_apply(text, text, jsonb, text, timestamptz)') is null then
    alter function public.transfer_stock(text, text, jsonb, text, timestamptz) rename to transfer_stock_apply;
  end if;
  if to_regprocedure('public.receive_stock_apply(text, jsonb, text, text, timestamptz)') is null then
    alter function public.receive_stock(text, jsonb, text, text, timestamptz) rename to receive_stock_apply;
  end if;
  if to_regprocedure('public.return_stock_apply(text, jsonb, text, text, timestamptz, text)') is null then
    alter function public.return_stock(text, jsonb, text, text, timestamptz, text) rename to return_stock_apply;
  end if;
end $$;

revoke all on function public.transfer_stock_apply(text, text, jsonb, text, timestamptz)       from public, anon, authenticated;
revoke all on function public.receive_stock_apply(text, jsonb, text, text, timestamptz)        from public, anon, authenticated;
revoke all on function public.return_stock_apply(text, jsonb, text, text, timestamptz, text)   from public, anon, authenticated;

-- The thin versions: the Big Boss straight through, staff told to ask.
create or replace function public.dahua_needs_approval()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'A stock movement by staff needs the Big Boss''s approval — send it for approval instead.'
      using errcode = '42501';
  end if;
end $$;

create or replace function public.transfer_stock(
  p_from text, p_to text, p_items jsonb, p_note text default null, p_when timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.transfer_stock_apply(p_from, p_to, p_items, p_note, p_when);
end $$;

create or replace function public.receive_stock(
  p_to text, p_items jsonb, p_supplier text default null, p_note text default null, p_when timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.receive_stock_apply(p_to, p_items, p_supplier, p_note, p_when);
end $$;

create or replace function public.return_stock(
  p_to text, p_items jsonb, p_customer text default null, p_note text default null, p_when timestamptz default now(), p_spoilt text default 'SPOILT'
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.return_stock_apply(p_to, p_items, p_customer, p_note, p_when, p_spoilt);
end $$;

grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz)       to authenticated;
grant execute on function public.receive_stock(text, jsonb, text, text, timestamptz)        to authenticated;
grant execute on function public.return_stock(text, jsonb, text, text, timestamptz, text)   to authenticated;

-- ── 2. Requests: reversible, and timed from when they arrived ──
alter table public.dahua_movement_requests
  add column if not exists filed_at        timestamptz not null default now(),
  add column if not exists auto_approved   boolean not null default false,
  add column if not exists reversed_at     timestamptz,
  add column if not exists reversed_by     uuid references auth.users(id) on delete set null,
  add column if not exists reversal_number text,
  add column if not exists reverse_reason  text;

alter table public.dahua_movement_requests drop constraint if exists dahua_movement_requests_status_check;
alter table public.dahua_movement_requests
  add constraint dahua_movement_requests_status_check
  check (status in ('pending', 'approved', 'rejected', 'reversed'));

create index if not exists dahua_movement_requests_due_idx
  on public.dahua_movement_requests (filed_at) where status = 'pending';

-- ── 3. A reversal is a movement of its own kind ───────────────
alter table public.stock_transfers drop constraint if exists stock_transfers_kind_check;
alter table public.stock_transfers
  add constraint stock_transfers_kind_check check (kind in ('move', 'receive', 'return', 'reversal'));

alter table public.stock_transfers drop constraint if exists stock_transfers_source_check;
alter table public.stock_transfers
  add constraint stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null)
    or (kind in ('receive', 'return') and from_warehouse is null)
    or (kind = 'reversal' and from_warehouse is not null)
  );

alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_kind_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_kind_check check (kind in ('move', 'receive', 'return', 'reversal'));

alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_source_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null
       and (from_warehouse <> to_warehouse or from_line is not null))
    or (kind in ('receive', 'return') and from_warehouse is null)
    or (kind = 'reversal' and from_warehouse is not null)
  );

-- ── 4. Auto-accept: one switch, the Big Boss's ────────────────
create table if not exists public.stock_approval_settings (
  id            integer primary key default 1 check (id = 1),
  auto_accept   boolean not null default false,
  delay_seconds integer not null default 45 check (delay_seconds between 5 and 3600),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id) on delete set null
);
insert into public.stock_approval_settings (id) values (1) on conflict (id) do nothing;

alter table public.stock_approval_settings enable row level security;
-- Everyone signed in may read it: staff screens show the countdown.
drop policy if exists stock_approval_settings_read on public.stock_approval_settings;
create policy stock_approval_settings_read on public.stock_approval_settings
  for select to authenticated using (true);
-- Changed only through set_stock_auto_accept().

create or replace function public.set_stock_auto_accept(p_on boolean)
returns public.stock_approval_settings
language plpgsql security definer set search_path = public as $$
declare
  v_row public.stock_approval_settings;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can switch auto-accept';
  end if;
  update public.stock_approval_settings
     set auto_accept = coalesce(p_on, false), updated_at = now(), updated_by = auth.uid()
   where id = 1
  returning * into v_row;
  return v_row;
end $$;

-- ── 5. Asking ─────────────────────────────────────────────────
-- Any staff movement, either line. DH-REQ when Dahua is involved, REQ when
-- it is the main shop alone.
create or replace function public.request_stock_movement(
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
  v_rec    public.dahua_movement_requests;
  v_to     text := coalesce(p_to_line, 'main');
  v_from   text := case when p_kind = 'move' then coalesce(p_from_line, v_to) else null end;
  v_yr     text := to_char(now(), 'YYYY');
  v_prefix text;
  v_n      text;
  v_try    integer;
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
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is the stock going?';
  end if;
  if p_kind = 'move' and (p_from is null or btrim(p_from) = '' or (p_from = p_to and v_from = v_to)) then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item';
  end if;

  v_prefix := case when v_to = 'dahua' or coalesce(v_from, '') = 'dahua' then 'DH-REQ-' else 'REQ-' end;

  for v_try in 1..8 loop
    begin
      select v_prefix || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_n
        from public.dahua_movement_requests where request_number like v_prefix || v_yr || '-%';
      insert into public.dahua_movement_requests
        (request_number, kind, from_line, from_warehouse, to_line, to_warehouse, items, party, note,
         requested_at, filed_at, requested_by, requested_staff_id, requested_name)
      values
        (v_n, p_kind, v_from, case when p_kind = 'move' then p_from end, v_to, p_to, p_items,
         nullif(btrim(coalesce(p_party, '')), ''), nullif(btrim(coalesce(p_note, '')), ''),
         coalesce(p_when, now()), now(), auth.uid(), public.current_staff_id(),
         coalesce(nullif(btrim(coalesce(p_done_by, '')), ''), public.current_staff_name()))
      returning * into v_rec;
      return v_rec;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;
end $$;

-- The old name, for apps loaded before this change.
create or replace function public.request_dahua_movement(
  p_kind text, p_from_line text, p_from text, p_to_line text, p_to text, p_items jsonb,
  p_party text default null, p_note text default null, p_when timestamptz default now(), p_done_by text default null
) returns public.dahua_movement_requests
language sql security definer set search_path = public as $$
  select * from public.request_stock_movement(p_kind, p_from_line, p_from, p_to_line, p_to, p_items, p_party, p_note, p_when, p_done_by)
$$;

-- ── 6. Approving ──────────────────────────────────────────────
-- Internal: makes the movement a pending request describes. The callers
-- check who may do it.
create or replace function public.stock_request_apply(p_id uuid, p_auto boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req    public.dahua_movement_requests;
  v_number text;
begin
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
  elsif v_req.kind = 'move' and v_req.to_line = 'dahua' then
    select t.transfer_number into v_number
      from public.dahua_transfer_stock_apply(v_req.from_warehouse, v_req.to_warehouse, v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'move' then
    select t.transfer_number into v_number
      from public.transfer_stock_apply(v_req.from_warehouse, v_req.to_warehouse, v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'receive' and v_req.to_line = 'dahua' then
    select t.transfer_number into v_number
      from public.dahua_receive_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'receive' then
    select t.transfer_number into v_number
      from public.receive_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at) t;
  elsif v_req.to_line = 'dahua' then
    select t.transfer_number into v_number
      from public.dahua_return_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at, 'SPOILT') t;
  else
    select t.transfer_number into v_number
      from public.return_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at, 'SPOILT') t;
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
     set status = 'approved', decided_at = now(),
         decided_by = case when p_auto then null else auth.uid() end,
         auto_approved = coalesce(p_auto, false), transfer_number = v_number
   where id = p_id;

  return jsonb_build_object('request_number', v_req.request_number, 'transfer_number', v_number, 'auto', coalesce(p_auto, false));
end $$;
revoke all on function public.stock_request_apply(uuid, boolean) from public, anon, authenticated;

create or replace function public.approve_stock_request(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can approve stock movements';
  end if;
  return public.stock_request_apply(p_id, false);
end $$;

create or replace function public.reject_stock_request(p_id uuid, p_reason text default null)
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

-- The old names, for apps loaded before this change.
create or replace function public.approve_dahua_movement(p_id uuid)
returns jsonb
language sql security definer set search_path = public as $$
  select public.approve_stock_request(p_id)
$$;
create or replace function public.reject_dahua_movement(p_id uuid, p_reason text default null)
returns void
language sql security definer set search_path = public as $$
  select public.reject_stock_request(p_id, p_reason)
$$;

-- ── 7. Auto-accept: approve whatever is due ───────────────────
-- Called by every screen that shows requests. Does nothing unless the Big
-- Boss has switched auto-accept on. Returns how many it approved.
create or replace function public.settle_stock_requests()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_set  public.stock_approval_settings;
  v_id   uuid;
  v_done integer := 0;
begin
  select * into v_set from public.stock_approval_settings where id = 1;
  if not found or not v_set.auto_accept then
    return 0;
  end if;
  -- The movement functions underneath accept staff and the Big Boss only.
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    return 0;
  end if;

  for v_id in
    select r.id from public.dahua_movement_requests r
     where r.status = 'pending'
       and r.filed_at <= now() - make_interval(secs => v_set.delay_seconds)
     order by r.filed_at
     limit 50
       for update skip locked
  loop
    begin
      perform public.stock_request_apply(v_id, true);
      v_done := v_done + 1;
    exception when others then
      -- One that cannot be made (a location renamed since, say) stays
      -- pending for the Big Boss to look at; the rest still go through.
      null;
    end;
  end loop;
  return v_done;
end $$;

-- ── 8. Reversing an approved request ──────────────────────────
-- Internal: takes units off a location's row for a product.
create or replace function public.stock_take_out(p_line text, p_warehouse text, p_model text, p_qty integer)
returns table (model text, before integer)
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if p_line = 'dahua' then
    v_id := public.dahua_stock_find_row(p_warehouse, p_model);
    if v_id is null then
      raise exception '% (Dahua) no longer lists % — it cannot be taken back out', p_warehouse, p_model;
    end if;
    return query
      update public.dahua_stock s set transfer_out = coalesce(s.transfer_out, 0) + p_qty
       where s.id = v_id
      returning s.model, (s.closing_stock + p_qty)::integer;
  else
    v_id := public.stock_find_row(p_warehouse, p_model);
    if v_id is null then
      raise exception '% no longer lists % — it cannot be taken back out', p_warehouse, p_model;
    end if;
    return query
      update public.warehouse_stock s set transfer_out = coalesce(s.transfer_out, 0) + p_qty
       where s.id = v_id
      returning s.model, (s.closing_stock + p_qty)::integer;
  end if;
end $$;
revoke all on function public.stock_take_out(text, text, text, integer) from public, anon, authenticated;

create or replace function public.reverse_stock_request(p_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req     public.dahua_movement_requests;
  v_main    boolean;
  v_cross   boolean;
  v_src     text;              -- the line the units go back to (moves)
  v_dst     text;              -- the line they come out of
  v_yr      text := to_char(now(), 'YYYY');
  v_prefix  text;
  v_number  text;
  v_note    text;
  v_main_id uuid;
  v_dh_id   uuid;
  v_try     integer;
  v_item    record;
  v_out     record;
  v_back    text;
  v_pos     integer := 0;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can reverse stock movements';
  end if;
  select * into v_req from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_req.status <> 'approved' or v_req.transfer_number is null then
    raise exception 'Only an approved request can be reversed — this one is %', v_req.status;
  end if;

  v_dst   := v_req.to_line;
  v_src   := coalesce(v_req.from_line, v_req.to_line);
  v_cross := v_req.kind = 'move' and v_src <> v_dst;
  v_main  := v_src = 'main' or v_dst = 'main';
  v_prefix := case when v_main then 'REV-' else 'DH-REV-' end;
  v_note  := 'Reversal of ' || v_req.transfer_number || ' (' || v_req.request_number || ')'
             || coalesce(' — ' || nullif(btrim(coalesce(p_reason, '')), ''), '');

  -- The header: in the table of each line it touches, under one number.
  for v_try in 1..8 loop
    begin
      if v_main then
        select v_prefix || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_number
          from public.stock_transfers where transfer_number like v_prefix || v_yr || '-%';
      else
        select v_prefix || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_number
          from public.dahua_stock_transfers where transfer_number like v_prefix || v_yr || '-%';
      end if;
      if v_main then
        insert into public.stock_transfers
          (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
           note, signed_by, staff_id, transferred_at, created_by)
        values
          (v_number, 'reversal', v_req.to_warehouse,
           case when v_req.kind = 'move' then v_req.from_warehouse else 'REVERSED' end,
           case when v_cross then v_dst end, case when v_cross then v_src end,
           v_note, public.current_staff_name(), public.current_staff_id(), now(), auth.uid())
        returning id into v_main_id;
      end if;
      if not v_main or v_cross then
        insert into public.dahua_stock_transfers
          (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
           note, signed_by, staff_id, transferred_at, created_by)
        values
          (v_number, 'reversal', v_req.to_warehouse,
           case when v_req.kind = 'move' then v_req.from_warehouse else 'REVERSED' end,
           case when v_cross then v_dst end, case when v_cross then v_src end,
           v_note, public.current_staff_name(), public.current_staff_id(), now(), auth.uid())
        returning id into v_dh_id;
      end if;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  -- What the approval actually booked, item by item. On a cross move each
  -- side's table holds that side's name; within one line `model` is the
  -- name it left under and `other_model` the one it joined.
  for v_item in
    select coalesce(m.position, d.position) as position,
           coalesce(m.quantity, d.quantity) as quantity,
           coalesce(case when v_req.to_line = 'dahua' then d.condition end, m.condition, d.condition, 'good') as condition,
           -- the name it sits under where it went
           case when v_cross then (case when v_dst = 'main' then m.model else d.model end)
                else coalesce((case when v_dst = 'main' then m.other_model else d.other_model end),
                              (case when v_dst = 'main' then m.model else d.model end)) end as dest_model,
           -- the name it had where it came from
           case when v_cross then (case when v_src = 'main' then m.model else d.model end)
                else (case when v_src = 'main' then m.model else d.model end) end as src_model
      from (select i.* from public.stock_transfer_items i
              join public.stock_transfers t on t.id = i.transfer_id
             where t.transfer_number = v_req.transfer_number) m
      full join (select i.* from public.dahua_stock_transfer_items i
                   join public.dahua_stock_transfers t on t.id = i.transfer_id
                  where t.transfer_number = v_req.transfer_number) d
        on d.position = m.position
     order by 1
  loop
    if v_item.dest_model is null or coalesce(v_item.quantity, 0) <= 0 then
      continue;
    end if;

    select * into v_out from public.stock_take_out(
      v_dst,
      case when v_req.kind = 'return' and v_item.condition = 'spoilt' then 'SPOILT' else v_req.to_warehouse end,
      v_item.dest_model, v_item.quantity);

    v_back := null;
    if v_req.kind = 'move' then
      if v_src = 'dahua' then
        v_back := public.dahua_stock_book_in_as(v_req.from_warehouse, v_item.src_model, v_item.quantity);
      else
        v_back := public.stock_book_in(v_req.from_warehouse, v_item.src_model, v_item.quantity);
      end if;
    end if;

    v_pos := v_pos + 1;
    if v_main_id is not null then
      insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position, condition, other_model)
      values (v_main_id,
              case when v_dst = 'main' then v_out.model else v_back end,
              v_item.quantity, case when v_dst = 'main' then v_out.before end, v_pos,
              coalesce(v_item.condition, 'good'),
              case when v_cross then (case when v_dst = 'main' then v_back else v_out.model end)
                   else nullif(v_back, v_out.model) end);
    end if;
    if v_dh_id is not null then
      insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position, condition, other_model)
      values (v_dh_id,
              case when v_dst = 'dahua' then v_out.model else v_back end,
              v_item.quantity, case when v_dst = 'dahua' then v_out.before end, v_pos,
              coalesce(v_item.condition, 'good'),
              case when v_cross then (case when v_dst = 'dahua' then v_back else v_out.model end)
                   else nullif(v_back, v_out.model) end);
    end if;
  end loop;

  if v_pos = 0 then
    raise exception 'Nothing was found to reverse on %', v_req.transfer_number;
  end if;

  update public.dahua_movement_requests
     set status = 'reversed', reversed_at = now(), reversed_by = auth.uid(),
         reversal_number = v_number, reverse_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_id;

  return jsonb_build_object('request_number', v_req.request_number, 'transfer_number', v_req.transfer_number,
                            'reversal_number', v_number, 'lines', v_pos);
end $$;

revoke all on function public.request_stock_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) from public, anon;
revoke all on function public.approve_stock_request(uuid)        from public, anon;
revoke all on function public.reject_stock_request(uuid, text)   from public, anon;
revoke all on function public.reverse_stock_request(uuid, text)  from public, anon;
revoke all on function public.settle_stock_requests()            from public, anon;
revoke all on function public.set_stock_auto_accept(boolean)     from public, anon;
grant execute on function public.request_stock_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) to authenticated;
grant execute on function public.approve_stock_request(uuid)       to authenticated;
grant execute on function public.reject_stock_request(uuid, text)  to authenticated;
grant execute on function public.reverse_stock_request(uuid, text) to authenticated;
grant execute on function public.settle_stock_requests()           to authenticated;
grant execute on function public.set_stock_auto_accept(boolean)    to authenticated;

-- ── 9. The phone app's path files every staff movement as a request ──
-- Same as in 20261017_dahua_movement_approval.sql, except that the step
-- before the movement now catches every line, not only Dahua.
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

  -- Every movement by staff goes to the Big Boss for approval.
  if not (select public.is_superboss()) then
    select * into v_req
      from public.request_stock_movement(p_kind, case when p_kind = 'move' then v_from end, p_from, v_to, p_to,
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
-- What is waiting, and what auto-accept is set to:
--
-- select request_number, kind, from_warehouse, to_warehouse, requested_name, filed_at
--   from public.dahua_movement_requests where status = 'pending' order by filed_at;
-- select * from public.stock_approval_settings;
