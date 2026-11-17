-- ─────────────────────────────────────────────────────────────
-- Debtors — sales on credit, and what has been paid against them
-- 2026-10-13
--
-- Some customers take goods now and pay bit by bit. Until now such a sale
-- was an ordinary invoice: it counted as money in on the day it was written,
-- and nothing recorded what was still owed or what had come in since.
--
-- HOW IT WORKS NOW
--   The invoice forms have an "On credit" switch. A sale saved with it on
--   gets a row here in `debts` — who owes, on which invoice, how much — and
--   each payment the customer makes afterwards is a row in `debt_payments`.
--   What is still owed is the debt's total less its payments.
--
-- WHAT THE SALES PAGE COUNTS
--   A credit sale is NOT counted as sales when it is written. Each payment
--   IS counted, on the day it is received, in the method it was paid by. So
--   Sales shows money that has actually come in, and the Debtors tab shows
--   the money that has not. The invoice is still the invoice — printed,
--   numbered, and its stock deducted at once: the goods have left.
--
-- ONE TABLE FOR BOTH LINES
--   `line` says whether the invoice is a main-shop one or a Dahua one. The
--   invoice is referred to by id and number rather than a foreign key,
--   because the two lines keep their invoices in two tables.
--
-- WHO CAN DO WHAT
--   Any staff login can see debts and record a payment — a customer pays
--   whoever is at the counter. A payment cannot take a debt below zero.
--   Only the Big Boss can remove a payment or a debt.
--
-- Idempotent.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.debts (
  id             uuid primary key default gen_random_uuid(),
  line           text not null default 'main' check (line in ('main', 'dahua')),
  invoice_id     uuid not null,
  invoice_number text not null,
  customer_name  text not null,
  customer_num   text,
  customer_loc   text,
  total          numeric(12,2) not null check (total > 0),
  -- Kept in step by the trigger below, so lists need not add up payments.
  paid           numeric(12,2) not null default 0,
  settled_at     timestamptz,
  issued_at      timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  unique (line, invoice_id)
);
create index if not exists debts_open_idx on public.debts (line, issued_at desc) where settled_at is null;
create index if not exists debts_invoice_number_idx on public.debts (invoice_number);

create table if not exists public.debt_payments (
  id             uuid primary key default gen_random_uuid(),
  debt_id        uuid not null references public.debts(id) on delete cascade,
  amount         numeric(12,2) not null check (amount > 0),
  payment_method text not null default 'Cash',
  paid_at        timestamptz not null default now(),
  note           text,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists debt_payments_debt_idx on public.debt_payments (debt_id);
create index if not exists debt_payments_paid_at_idx on public.debt_payments (paid_at desc);

-- ── A payment cannot overpay, and the debt keeps its own running total ──
create or replace function public.fn_debt_payment_check()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_total numeric(12,2);
  v_paid  numeric(12,2);
begin
  -- Locked, so two tills taking a payment on one debt at the same moment
  -- cannot both be told there is room for theirs.
  select total into v_total from public.debts where id = new.debt_id for update;
  if not found then
    raise exception 'That debt no longer exists';
  end if;
  select coalesce(sum(amount), 0) into v_paid
    from public.debt_payments
   where debt_id = new.debt_id and id is distinct from new.id;
  if v_paid + new.amount > v_total + 0.005 then
    raise exception 'That is more than is owed — % is left to pay', to_char(v_total - v_paid, 'FM999,999,990.00');
  end if;
  return new;
end $$;

drop trigger if exists trg_debt_payment_check on public.debt_payments;
create trigger trg_debt_payment_check
  before insert or update of amount, debt_id on public.debt_payments
  for each row execute function public.fn_debt_payment_check();

create or replace function public.fn_debt_resync()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_debt uuid := coalesce(new.debt_id, old.debt_id);
  v_paid numeric(12,2);
begin
  select coalesce(sum(amount), 0) into v_paid from public.debt_payments where debt_id = v_debt;
  update public.debts d
     set paid       = v_paid,
         settled_at = case when v_paid >= d.total - 0.005 then coalesce(d.settled_at, now()) else null end
   where d.id = v_debt;
  return null;
end $$;

drop trigger if exists trg_debt_resync on public.debt_payments;
create trigger trg_debt_resync
  after insert or update or delete on public.debt_payments
  for each row execute function public.fn_debt_resync();

-- ── RLS ───────────────────────────────────────────────────────
alter table public.debts         enable row level security;
alter table public.debt_payments enable row level security;

drop policy if exists debts_read on public.debts;
create policy debts_read on public.debts
  for select to authenticated
  using ((select public.is_boss()) or (select public.is_cashier()));

drop policy if exists debts_insert on public.debts;
create policy debts_insert on public.debts
  for insert to authenticated
  with check (((select public.is_superboss()) or (select public.is_cashier())) and created_by = (select auth.uid()));

drop policy if exists debts_superboss_write on public.debts;
create policy debts_superboss_write on public.debts
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists debt_payments_read on public.debt_payments;
create policy debt_payments_read on public.debt_payments
  for select to authenticated
  using ((select public.is_boss()) or (select public.is_cashier()));

drop policy if exists debt_payments_insert on public.debt_payments;
create policy debt_payments_insert on public.debt_payments
  for insert to authenticated
  with check (((select public.is_superboss()) or (select public.is_cashier())) and created_by = (select auth.uid()));

drop policy if exists debt_payments_superboss_write on public.debt_payments;
create policy debt_payments_superboss_write on public.debt_payments
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ── Audit ─────────────────────────────────────────────────────
drop trigger if exists trg_audit_debts on public.debts;
create trigger trg_audit_debts
  after insert or delete on public.debts
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_debt_payments on public.debt_payments;
create trigger trg_audit_debt_payments
  after insert or update or delete on public.debt_payments
  for each row execute function public.fn_audit();

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- Who owes what, largest first:
--
-- select line, customer_name, customer_num, invoice_number, total, paid, total - paid as owed, issued_at
--   from public.debts
--  where settled_at is null
--  order by total - paid desc;
