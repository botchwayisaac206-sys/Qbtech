-- ============================================================================
-- Deliveries: staff log a delivery (customer, amount, location, payment method);
-- the boss sees all of them, and the amounts roll into the sales dashboard.
--
-- RLS mirrors invoices/expenses: a cashier may insert and read only their own
-- rows; boss/admin read everything and may edit/delete.
--
-- Safe to run multiple times.
-- ============================================================================

-- Ensure the role helpers exist (they live in the base sales-system migration,
-- but this makes the deliveries migration self-contained / runnable standalone).
create or replace function public.current_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.user_roles where user_id = auth.uid()
$$;

create or replace function public.is_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() in ('boss','admin'), false)
$$;

create table if not exists public.deliveries (
  id             uuid primary key default gen_random_uuid(),
  customer_name  text,
  location       text,
  amount         numeric not null default 0,
  payment_method text   not null default 'Cash',   -- 'Cash' | 'Mobile Money'
  note           text,
  delivered_at   timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);

create index if not exists deliveries_delivered_at_idx on public.deliveries (delivered_at desc);
create index if not exists deliveries_created_by_idx    on public.deliveries (created_by);

alter table public.deliveries enable row level security;

drop policy if exists del_read on public.deliveries;
create policy del_read on public.deliveries for select
  using (public.is_boss() or created_by = auth.uid());

drop policy if exists del_insert on public.deliveries;
create policy del_insert on public.deliveries for insert
  with check (auth.uid() is not null and (public.is_boss() or created_by = auth.uid()));

drop policy if exists del_update on public.deliveries;
create policy del_update on public.deliveries for update
  using (public.is_boss()) with check (public.is_boss());

drop policy if exists del_delete on public.deliveries;
create policy del_delete on public.deliveries for delete
  using (public.is_boss());
