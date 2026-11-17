-- ─────────────────────────────────────────────────────────────
-- Dahua — staff may override a fixed price, but every override is logged
-- 2026-09-06
--
-- Replaces the hard lock added in 20260906_dahua_pricing.sql. A cashier at
-- the counter can now sell at a negotiated price; what changes is that the
-- invoice line remembers what the price SHOULD have been, and the override
-- is written to public.audit_log where the boss already reads it.
--
-- Requires 20260906_dahua_pricing.sql. Run in the Supabase SQL editor.
--
-- WHAT IS AND IS NOT UNLOCKED
--   Overriding one line of one invoice is not the same as repricing a
--   product. dahua_stock.unit_price stays Big-Boss-only
--   (trg_dahua_stock_lock_price is untouched), so a cashier can discount a
--   sale but cannot quietly move the shop's price and hide the discount.
--
-- WHY list_price IS A STORED COLUMN
--   An override is only detectable against the price that applied at the
--   time of sale. Reading dahua_stock.unit_price later gives today's price,
--   so a repricing would silently turn old sales into overrides, or hide
--   real ones. The line therefore carries its own copy.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Remember the price that applied when the line was written ──
alter table public.dahua_invoice_items
  add column if not exists list_price numeric(12,2) not null default 0;

comment on column public.dahua_invoice_items.list_price is
  'The product''s fixed price at the moment this line was saved. 0 = the '
  'product had no fixed price (or the line is free text). An override is '
  'list_price > 0 and unit_price <> list_price.';

-- Back-fill: every line written before this migration was forced to the
-- product price, so its list_price is its unit_price. Marking them 0 would
-- read as "never had a fixed price", which is the opposite of what happened.
update public.dahua_invoice_items
   set list_price = unit_price
 where list_price = 0
   and stock_id is not null;

-- ── 2. Record the fixed price; allow the sale price to differ ─────
-- Supersedes the version in 20260906_dahua_pricing.sql, which forced
-- new.unit_price to the product price for anyone but the Big Boss.
create or replace function public.dahua_item_apply_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fixed numeric(12,2);
begin
  if new.stock_id is not null then
    select unit_price into fixed
      from public.dahua_stock
     where id = new.stock_id;

    new.list_price := coalesce(fixed, 0);

    -- A line saved with no price at all takes the fixed price. This is what
    -- makes the price "automatic" in the ordinary case: the cashier picks a
    -- product and does nothing else. Typing a different figure is an
    -- override, and step 3 logs it.
    if coalesce(new.unit_price, 0) = 0 and coalesce(fixed, 0) > 0 then
      new.unit_price := fixed;
    end if;
  else
    new.list_price := 0;
  end if;

  -- Never trusted from the client.
  new.line_total := round(new.quantity * new.unit_price, 2);
  return new;
end;
$$;

-- ── 3. Log every override to audit_log ────────────────────────────
-- Definer because a cashier has no INSERT on audit_log — the same pattern
-- fn_audit() uses for invoices and expenses.
create or replace function public.dahua_log_price_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv  record;
  mdl  text;
begin
  -- Nothing to compare against when the product has no fixed price.
  if coalesce(new.list_price, 0) <= 0 then return null; end if;
  if new.unit_price = new.list_price   then return null; end if;

  select invoice_number, customer_name, issued_at
    into inv
    from public.dahua_invoices
   where id = new.invoice_id;

  select model into mdl from public.dahua_stock where id = new.stock_id;

  insert into public.audit_log (actor_id, actor_role, action, table_name, row_id, diff)
  values (
    auth.uid(),
    public.current_role(),
    'override',
    'dahua_price_override',
    new.id::text,
    jsonb_build_object(
      'model',          coalesce(mdl, new.description),
      'description',    new.description,
      'invoice_id',     new.invoice_id,
      'invoice_number', inv.invoice_number,
      'customer_name',  inv.customer_name,
      'quantity',       new.quantity,
      'list_price',     new.list_price,
      'unit_price',     new.unit_price,
      'difference',     round(new.unit_price - new.list_price, 2),
      'total_effect',   round((new.unit_price - new.list_price) * new.quantity, 2)
    )
  );
  return null;
end;
$$;

drop trigger if exists trg_dahua_log_price_override on public.dahua_invoice_items;
create trigger trg_dahua_log_price_override
  after insert or update on public.dahua_invoice_items
  for each row execute function public.dahua_log_price_override();

commit;

-- ── Verification ──────────────────────────────────────────────
-- Overrides so far, newest first:
--
-- select created_at,
--        diff->>'invoice_number' as invoice,
--        diff->>'model'          as model,
--        diff->>'list_price'     as should_be,
--        diff->>'unit_price'     as sold_at,
--        diff->>'total_effect'   as effect
--   from public.audit_log
--  where table_name = 'dahua_price_override'
--  order by created_at desc;
--
-- Total given away (or gained) this month:
--
-- select sum((diff->>'total_effect')::numeric)
--   from public.audit_log
--  where table_name = 'dahua_price_override'
--    and created_at >= date_trunc('month', now());
