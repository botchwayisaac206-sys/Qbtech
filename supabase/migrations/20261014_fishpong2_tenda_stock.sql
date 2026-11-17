-- ─────────────────────────────────────────────────────────────
-- FISHPONG-2: Tenda stock sheet — 2026-10-14
--
-- The "FISHPOND 2 WH" sheet: 27 Tenda products, 1,036 units, booked into
-- FISHPONG-2.
--
-- HOW IT IS ENTERED
--   As a delivery (an RCV movement), exactly as Receive in the Transfers
--   tab would do it — not by overwriting counts. So:
--     • a product FISHPONG-2 already stocks gets these units ADDED to it;
--     • a new product gets its row, and STORE STOCK gets its empty row too
--       (20261007_store_stock_lists_everything.sql);
--     • the sheet appears in the movement history under one RCV number, so
--       "where did these 155 AC5 routers come from" has an answer.
--
-- HOW THE SHEET WAS READ
--   "CODE-Tenda description=Npcs" became "CODE Tenda description", so each
--   name starts with the model code staff search by.
--
--   N301 is booked as "N301" — the name STORE STOCK already uses for it —
--   rather than a new spelling.
--
--   Left OUT, because the sheet gives no quantity:
--     TEF1105P-4-63W Tenda 5-Port 10/100Mbps Desktop Switch with 4-Port PoE
--   Add it with Receive once it has been counted.
--
--   Kept as written, but worth a look on the shelf: "01-5G" — Tenda sells
--   this CPE as O1-5G (letter O, not zero). If the box says O1-5G, rename it
--   in Transfers → Product names so the name matches what is scanned.
--
-- Safe to run twice: if this sheet has already been entered, it stops.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_book_in(text, text, integer)') is null then
    raise exception 'Run 20261005_no_duplicate_names_on_moves.sql first — this file books stock in with it.'
      using errcode = '42P01';
  end if;
end $$;

do $sheet$
declare
  v_note  constant text := 'FISHPOND 2 WH stock sheet (Tenda), 2026-10-14';
  v_wh    constant text := 'FISHPONG-2';
  v_rec   public.stock_transfers;
  v_item  record;
  v_name  text;
  v_pos   integer := 0;
  v_units integer := 0;
  v_before bigint;
begin
  if not exists (select 1 from public.warehouses where name = v_wh) then
    raise exception 'There is no location called %', v_wh;
  end if;
  if exists (select 1 from public.stock_transfers where kind = 'receive' and note = v_note) then
    raise notice 'This sheet has already been entered — nothing done.';
    return;
  end if;

  select coalesce(sum(closing_stock), 0) into v_before from public.warehouse_stock where warehouse = v_wh;

  v_rec := public.stock_movement_open('receive', null, v_wh, 'Tenda', v_note, now());
  -- Entered from the SQL editor, so there is no login to stamp it with.
  update public.stock_transfers set signed_by = 'Stock sheet, entered by the office' where id = v_rec.id;

  for v_item in
    select * from (values
      ('TEF1109P-8-63W Tenda 9-Port 10/100Mbps Desktop Switch With 8-Port PoE', 10),
      ('TEF1118P-16-150W Tenda 16FE+2GE/1SFP Desktop Switch With 16-Port PoE', 15),
      ('TEF1126P-24-250W Tenda 24FE+2GE/1SFP Rackmount Switch With 24-Port PoE', 33),
      ('TEG1105P-4-63W Tenda 5-Port Gigabit Desktop Switch with 4-Port PoE', 53),
      ('TEG1110PF-8-120W Tenda 9GE+1SFP Ethernet Switch With 8-Port PoE', 53),
      ('TEG1120P-16-150W Tenda 18GE+2SFP Ethernet Unmanaged Switch With16-Port PoE', 53),
      ('TEG1120P-16-250W Tenda 18GE+2SFP Ethernet Unmanaged Switch With16-Port PoE', 50),
      ('TEG1128P-24-250W Tenda 26GE+2SFP Ethernet Unmanaged Switch With24-Port PoE', 8),
      ('TEG1128P-24-410W Tenda 26GE+2SFP Ethernet Unmanaged Switch With24-Port PoE', 9),
      ('N301', 1),
      ('AC5 Tenda AC1200 Dual-Band Wireless Router', 155),
      ('AC10 Tenda AC1200 Dual-Band Gigabit Wireless Router', 34),
      ('TX2L Pro Tenda AX1500 Dual-Band Gigabit Wi-Fi 6 Router', 15),
      ('TEL Tenda BE3600 Dual-Band Wi-Fi 7 Router', 5),
      ('4G03 Pro Tenda N300 Wi-Fi 4G LTE Router', 143),
      ('4G06 Tenda N300 Wi-Fi 4G VoLTE Router', 90),
      ('A18 Tenda AC1200 Dual-band Range Extender', 46),
      ('A21 Tenda AC2100 Gigabit Dual-Band Wireless Signal Extender', 30),
      ('A27 Tenda AX1800 Wi-Fi 6 Dual-Band Wireless Signal Extender', 10),
      ('A9 Tenda N300 Range Extender', 177),
      ('01-5G Tenda 5GHz 9dBi 11AC 867Mbps Outdoor CPE', 5),
      ('OS3 Tenda 5GHz 12dBi 11AC 867Mbps Outdoor CPE', 5),
      ('CP3 Tenda 3MP Security Pan/Tilt Camera', 5),
      ('CP3 Pro Tenda 3MP Security Pan/Tilt Camera', 5),
      ('CH3-WCA Tenda 1080P Outdoor Wi-Fi Pan/Tilt Camera', 5),
      ('CH7-WCA Tenda 4MP Outdoor Wi-Fi Pan/Tilt Camera', 5),
      ('CH9-WCA Tenda 6MP Dual-lens Linkage Outdoor Wi-Fi Pan/Tilt Camera', 16)
    ) as t(model, qty)
  loop
    -- Joins the row FISHPONG-2 already has for the product, under any
    -- spelling of the same code; otherwise creates it.
    v_name := public.stock_book_in(v_wh, v_item.model, v_item.qty);
    v_pos := v_pos + 1;
    v_units := v_units + v_item.qty;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_name, v_item.qty, null, v_pos);
  end loop;

  if (select coalesce(sum(closing_stock), 0) from public.warehouse_stock where warehouse = v_wh) <> v_before + v_units then
    raise exception 'FISHPONG-2 did not go up by exactly % units — nothing has been saved.', v_units;
  end if;

  raise notice '% — % products, % units booked into %.', v_rec.transfer_number, v_pos, v_units, v_wh;
end $sheet$;

-- ── Verification ──────────────────────────────────────────────
-- select model, closing_stock from public.warehouse_stock
--  where warehouse = 'FISHPONG-2' and (model ilike '%tenda%' or model = 'N301')
--  order by model;
