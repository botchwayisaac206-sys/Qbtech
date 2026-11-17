-- ─────────────────────────────────────────────────────────────
-- Stock staff set their own password — 2026-10-06
--
-- Tapping a name proved nothing: anyone holding a stock phone could tap a
-- colleague's and record under it. Each person on the stock staff list now
-- has a password of their own, set by them the first time they pick their
-- name, and asked for every time after.
--
-- HOW A MOVEMENT IS TIED TO A PERSON
--   Entering the password gives the phone a KEY for that person
--   (stock_handler_tokens). Every movement the phone records for them
--   carries the key, and record_stock_movement() refuses a movement signed
--   with a name whose key is missing or wrong. So a name on a record means
--   someone who knew that person's password recorded it.
--
--   A key, not the password itself, because movements can wait in a phone's
--   outbox for hours with no signal. The phone has to hold something to
--   send with them later, and it should not be the password.
--
--   Keys stop working when the password is changed or reset.
--
-- WHAT IS STORED
--   Never the password — a salted SHA-256 of it, in a table no app login
--   can read (RLS on, no policies). The staff list the phones read gives
--   names and "has a password: yes/no", nothing more.
--
--   Five wrong tries locks that name for five minutes.
--
-- FORGOTTEN PASSWORDS
--   The Big Boss resets it (stock_handler_reset_password). That removes the
--   password and every key; the person sets a new one the next time they
--   pick their name.
--
-- THE GAP TO KNOW ABOUT
--   Until someone has set a password, their name is open — whoever picks it
--   first sets the password. Have each person set theirs on day one; if the
--   wrong person got there first, reset it.
--
-- Movements signed with a name that has no password yet are still accepted,
-- so phones that have not updated keep working.
--
-- Requires 20261005_stock_handlers.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.stock_handlers') is null then
    raise exception 'Run 20261005_stock_handlers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. Where the secrets live ─────────────────────────────────
create table if not exists public.stock_handler_secrets (
  handler_id   uuid primary key references public.stock_handlers(id) on delete cascade,
  salt         text not null,
  hash         text not null,
  failed       integer not null default 0,
  locked_until timestamptz,
  set_at       timestamptz not null default now()
);
alter table public.stock_handler_secrets enable row level security;
-- No policies: only the functions below touch it.

create table if not exists public.stock_handler_tokens (
  token      uuid primary key default gen_random_uuid(),
  handler_id uuid not null references public.stock_handlers(id) on delete cascade,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists stock_handler_tokens_handler_idx on public.stock_handler_tokens (handler_id);
alter table public.stock_handler_tokens enable row level security;
-- No policies.

create or replace function public.stock_pass_hash(p_salt text, p_password text)
returns text
language sql immutable as $$
  select encode(sha256(convert_to(p_salt || ':' || p_password, 'UTF8')), 'hex')
$$;
revoke all on function public.stock_pass_hash(text, text) from public, anon, authenticated;

-- ── 2. The list the phones read ───────────────────────────────
create or replace function public.stock_handlers_list()
returns table (name text, has_password boolean)
language sql stable security definer set search_path = public as $$
  select h.name,
         exists (select 1 from public.stock_handler_secrets s where s.handler_id = h.id)
    from public.stock_handlers h
   order by h.name
$$;

-- ── 3. Entering a password ────────────────────────────────────
-- Returns {"ok": true, "name": …, "token": …} or {"ok": false, "error": …}.
-- A wrong password is RETURNED, not raised: raising would undo the count of
-- wrong tries along with everything else, and the lock would never engage.
create or replace function public.stock_handler_sign_in(p_name text, p_password text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_name   text;
  v_secret public.stock_handler_secrets;
  v_token  uuid;
  v_wait   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;

  select h.id, h.name into v_id, v_name
    from public.stock_handlers h
   where upper(btrim(h.name)) = upper(btrim(coalesce(p_name, '')));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'That name is not on the stock staff list');
  end if;

  select * into v_secret from public.stock_handler_secrets where handler_id = v_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No password has been set for this name yet', 'no_password', true);
  end if;

  if v_secret.locked_until is not null and v_secret.locked_until > now() then
    v_wait := greatest(1, ceil(extract(epoch from (v_secret.locked_until - now())) / 60)::integer);
    return jsonb_build_object('ok', false, 'error',
      'Too many wrong tries. Try again in ' || v_wait || ' minute' || case when v_wait = 1 then '' else 's' end || '.');
  end if;

  if public.stock_pass_hash(v_secret.salt, coalesce(p_password, '')) <> v_secret.hash then
    if v_secret.failed + 1 >= 5 then
      update public.stock_handler_secrets
         set failed = 0, locked_until = now() + interval '5 minutes'
       where handler_id = v_id;
      return jsonb_build_object('ok', false, 'error', 'Wrong password. Too many wrong tries — locked for 5 minutes.');
    end if;
    update public.stock_handler_secrets set failed = failed + 1 where handler_id = v_id;
    return jsonb_build_object('ok', false, 'error', 'Wrong password');
  end if;

  update public.stock_handler_secrets set failed = 0, locked_until = null where handler_id = v_id;

  insert into public.stock_handler_tokens (handler_id, created_by)
  values (v_id, auth.uid()) returning token into v_token;
  -- A handful of keys per person is plenty for two phones; older ones go.
  delete from public.stock_handler_tokens t
   where t.handler_id = v_id
     and t.token not in (select k.token from public.stock_handler_tokens k
                          where k.handler_id = v_id order by k.created_at desc limit 6);

  return jsonb_build_object('ok', true, 'name', v_name, 'token', v_token);
end $$;

-- ── 4. Setting or changing a password ─────────────────────────
-- First time: p_old is not needed. After that the current password must be
-- given. Changing it cancels every key, so other phones ask again.
create or replace function public.stock_handler_set_password(p_name text, p_new text, p_old text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_name   text;
  v_secret public.stock_handler_secrets;
  v_salt   text := gen_random_uuid()::text;
  v_token  uuid;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;

  select h.id, h.name into v_id, v_name
    from public.stock_handlers h
   where upper(btrim(h.name)) = upper(btrim(coalesce(p_name, '')));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'That name is not on the stock staff list');
  end if;
  if p_new is null or length(p_new) < 4 then
    return jsonb_build_object('ok', false, 'error', 'Use at least 4 characters');
  end if;
  if length(p_new) > 72 then
    return jsonb_build_object('ok', false, 'error', 'That password is too long');
  end if;

  select * into v_secret from public.stock_handler_secrets where handler_id = v_id for update;
  if found then
    if v_secret.locked_until is not null and v_secret.locked_until > now() then
      return jsonb_build_object('ok', false, 'error', 'Too many wrong tries. Try again in a few minutes.');
    end if;
    if public.stock_pass_hash(v_secret.salt, coalesce(p_old, '')) <> v_secret.hash then
      if v_secret.failed + 1 >= 5 then
        update public.stock_handler_secrets
           set failed = 0, locked_until = now() + interval '5 minutes'
         where handler_id = v_id;
      else
        update public.stock_handler_secrets set failed = failed + 1 where handler_id = v_id;
      end if;
      return jsonb_build_object('ok', false, 'error', 'The current password is wrong');
    end if;
    update public.stock_handler_secrets
       set salt = v_salt, hash = public.stock_pass_hash(v_salt, p_new),
           failed = 0, locked_until = null, set_at = now()
     where handler_id = v_id;
  else
    insert into public.stock_handler_secrets (handler_id, salt, hash)
    values (v_id, v_salt, public.stock_pass_hash(v_salt, p_new));
  end if;

  delete from public.stock_handler_tokens where handler_id = v_id;
  insert into public.stock_handler_tokens (handler_id, created_by)
  values (v_id, auth.uid()) returning token into v_token;

  return jsonb_build_object('ok', true, 'name', v_name, 'token', v_token);
end $$;

-- ── 5. Big Boss: reset a forgotten password ───────────────────
create or replace function public.stock_handler_reset_password(p_name text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may reset a password';
  end if;
  select h.id into v_id from public.stock_handlers h
   where upper(btrim(h.name)) = upper(btrim(coalesce(p_name, '')));
  if not found then
    raise exception 'That name is not on the stock staff list';
  end if;
  delete from public.stock_handler_tokens  where handler_id = v_id;
  delete from public.stock_handler_secrets where handler_id = v_id;
end $$;

-- ── 6. record_stock_movement checks the key ───────────────────
-- Dropped rather than overloaded: two versions differing only by a trailing
-- argument would make every call that leaves it out ambiguous.
drop function if exists public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text);

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

  -- Checked after the duplicate test above, so a movement that was already
  -- saved still answers "already saved" even if the key has since changed.
  if v_handler is not null
     and exists (select 1 from public.stock_handler_secrets s where s.handler_id = v_handler)
     and not exists (select 1 from public.stock_handler_tokens t
                      where t.handler_id = v_handler and t.token = p_done_token) then
    raise exception '% must enter their password on this phone again before this can be saved', v_name;
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

-- ── 7. Who may call what ──────────────────────────────────────
revoke all on function public.stock_handlers_list()                              from public, anon;
revoke all on function public.stock_handler_sign_in(text, text)                  from public, anon;
revoke all on function public.stock_handler_set_password(text, text, text)       from public, anon;
revoke all on function public.stock_handler_reset_password(text)                 from public, anon;
revoke all on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text, uuid)
  from public, anon;
grant execute on function public.stock_handlers_list()                           to authenticated;
grant execute on function public.stock_handler_sign_in(text, text)               to authenticated;
grant execute on function public.stock_handler_set_password(text, text, text)    to authenticated;
grant execute on function public.stock_handler_reset_password(text)              to authenticated;
grant execute on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text, uuid)
  to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- Who has set a password:
--
-- select h.name, s.set_at, s.locked_until
--   from public.stock_handlers h
--   left join public.stock_handler_secrets s on s.handler_id = h.id
--  order by h.name;
