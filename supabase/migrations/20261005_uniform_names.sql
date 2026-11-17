-- ─────────────────────────────────────────────────────────────
-- One spelling per product, everywhere — 2026-10-05
--
-- Built from a read of the live stock list on 2026-10-05: 1,511 names in
-- the main shop, 302 in Dahua. It makes the names uniform. IT DOES NOT
-- CHANGE WHAT ANY WAREHOUSE HOLDS: the last step adds up every warehouse
-- before and after, and if a single unit has moved the whole file is
-- undone and nothing is saved.
--
-- WHAT IS RENAMED
--   Only names that are the same product beyond argument — identical once
--   capitals, spaces and punctuation are ignored (stock_model_key):
--
--     "ds-2ce16kot-lpfs"        →  "DS-2CE16KOT-LPFS"
--     "IOS84"                   →  "IO-S84"
--     "Video balun 8MP"         →  "VIDEO BALUN 8MP"
--     "DS-7208HGHI-M1#"         →  "DS-7208HGHI-M1"
--
--   The # and * on the end of names were marks from count sheets and mean
--   nothing about the product (confirmed by the shop), so they come off —
--   54 names. A * inside a name is a size ("520*350*180") and stays.
--   Stray and doubled spaces go too.
--
--   The spelling kept is the one most warehouses already use, then the one
--   holding most stock. Where the main shop and Dahua both stock a code,
--   Dahua takes the main shop's spelling.
--
-- WHERE TWO ROWS BECOME ONE
--   In most warehouses this is a rename and nothing else. But where ONE
--   warehouse held the same product under two spellings — BACK WAREHOUSE had
--   "DS-2CE10KF0T-LPFS" (288) and "DS-2CE10KF0T-LPFS*" (1,429) — the two rows
--   become one row holding both (1,717). That warehouse's total is exactly
--   what it was; it is now on one line instead of two.
--
-- WHAT IS NOT TOUCHED
--   Names that are only similar — "DS-2CD1027G3-LIU" and
--   "DS-2CD1027G3-LIU/SRB", "EAP225" and "EAP225 OUTDOOR", "AP3000" and
--   "CUDY AP3000". Those need a person to say they are the same product, and
--   are in the review list, not here.
--
--   Past invoices and movement records keep the wording they were written
--   with.
--
-- ALSO HERE
--   Invoices now find the STORE STOCK row the way movements do — by code,
--   not by exact spelling. Without this, renaming a row could stop a sale
--   being deducted because the product catalogue still spells it the old
--   way. With it, a spelling difference can no longer make a sale miss the
--   shelf at all.
--
-- Requires 20261005_model_key_keeps_decimals.sql. Safe to run again: a name
-- that has already been renamed is skipped.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_model_key(text)') is null
     or public.stock_model_key('1.5') <> '1~5' then
    raise exception 'Run 20261005_model_key_keeps_decimals.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The merge, without the "who is asking" check ───────────
-- merge_stock_model() is the Big Boss's button in the app and insists on a
-- Big Boss login. A migration has no login at all, so the work itself moves
-- into this internal function, which nobody can call from the app.
--
-- Two differences from the button, both for running in bulk:
--   • a name nothing is stocked under is skipped, not an error — so the
--     file can be run twice;
--   • p_from = p_into is allowed, and folds two rows that already share one
--     name in one warehouse.
create or replace function public.stock_merge_names(p_line text, p_from text, p_into text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from     text := coalesce(p_from, '');
  v_into     text := btrim(coalesce(p_into, ''));
  v_wh       text;
  v_keep     uuid;
  v_gone     uuid[];
  v_opening  integer;
  v_invoice  integer;
  v_in       integer;
  v_out      integer;
  v_min      integer;
  v_daily    jsonb;
  v_price    numeric(12,2);
  v_places   integer := 0;
  v_absorbed integer := 0;
begin
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if btrim(v_from) = '' or v_into = '' then
    raise exception 'Both names are required';
  end if;
  if length(v_into) > 200 then
    raise exception 'That name is too long';
  end if;

  if p_line = 'main' then
    for v_wh in
      select distinct warehouse from public.warehouse_stock where model = v_from
    loop
      -- The surviving row: one already under the kept name if there is one,
      -- otherwise the one on the books longest.
      select s.id into v_keep
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level)
        into v_opening, v_invoice, v_in, v_out, v_min
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      -- daily_taken is a day → qty map. Days booked on both rows are added.
      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.warehouse_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      delete from public.warehouse_stock where id = any (v_gone);

      update public.warehouse_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    if v_from <> v_into then
      update public.product_codes
         set model = v_into, updated_at = now()
       where model = v_from;

      -- Two price entries for one name would make the price ambiguous, so
      -- the old entry only follows when the kept name has none of its own.
      update public.pricelist_items
         set model = v_into
       where model = v_from
         and not exists (
               select 1 from public.pricelist_items p
                where upper(btrim(p.model)) = upper(v_into) and p.model <> v_from
             );
    end if;

  else
    for v_wh in
      select distinct warehouse from public.dahua_stock where model = v_from
    loop
      select s.id into v_keep
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level),
             max(s.unit_price)
        into v_opening, v_invoice, v_in, v_out, v_min, v_price
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.dahua_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      -- Invoice lines keep pointing at a row that exists. The line triggers
      -- are lifted for this one statement: they would re-stamp each old
      -- line's list price and log a price override that never happened.
      if exists (select 1 from public.dahua_invoice_items where stock_id = any (v_gone)) then
        alter table public.dahua_invoice_items disable trigger user;
        update public.dahua_invoice_items set stock_id = v_keep where stock_id = any (v_gone);
        alter table public.dahua_invoice_items enable trigger user;
      end if;

      delete from public.dahua_stock where id = any (v_gone);

      update public.dahua_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily,
             -- Its own price stands; a row with none takes the group's.
             unit_price    = case when coalesce(unit_price, 0) > 0 then unit_price
                                  else coalesce(v_price, 0) end
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    if v_from <> v_into then
      update public.dahua_product_codes
         set model = v_into, updated_at = now()
       where model = v_from;
    end if;
  end if;

  return jsonb_build_object(
    'line', p_line, 'from', v_from, 'into', v_into,
    'warehouses', v_places, 'rows_absorbed', v_absorbed
  );
end $$;

revoke all on function public.stock_merge_names(text, text, text) from public, anon, authenticated;

-- The Big Boss's button: the checks a person needs, then the same work.
create or replace function public.merge_stock_model(p_line text, p_from text, p_into text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from text := coalesce(p_from, '');
  v_into text := btrim(coalesce(p_into, ''));
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may merge product names';
  end if;
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if v_from = v_into then
    raise exception 'Those are the same name';
  end if;
  if p_line = 'main' and not exists (select 1 from public.warehouse_stock where model = v_from) then
    raise exception 'Nothing is stocked as "%"', v_from;
  end if;
  if p_line = 'dahua' and not exists (select 1 from public.dahua_stock where model = v_from) then
    raise exception 'Dahua stocks nothing as "%"', v_from;
  end if;
  return public.stock_merge_names(p_line, v_from, v_into);
end $$;

-- ── 2. Invoices find the shelf by code, not by exact spelling ──
-- Supersedes the version in 20260921_deduct_store_stock_match.sql, which
-- matched on capitals and outer spaces only. "IOS84" on an invoice now comes
-- off "IO-S84" on the shelf. Still internal: reachable only through
-- deduct_invoice_store_stock().
create or replace function public.deduct_store_stock(
  p_items jsonb,
  p_store text default 'STORE STOCK'
) returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_item  jsonb;
  v_typed text;
  v_qty   integer;
  v_id    uuid;
  v_model text;
  v_have  integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_typed := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_typed = '' or v_qty <= 0 then
      continue;
    end if;

    v_id := public.stock_find_row(p_store, v_typed);
    if v_id is null then
      -- Reported, not invented: an item the shop does not stock should not
      -- create a negative row out of nothing.
      model := v_typed; requested := v_qty; available := 0; tracked := false;
      return next;
      continue;
    end if;

    -- Locked so two tills invoicing the same model cannot both read the
    -- same "before" figure.
    select s.model, s.closing_stock into v_model, v_have
      from public.warehouse_stock s where s.id = v_id for update;

    update public.warehouse_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_qty
     where id = v_id;

    -- The sale is never blocked by the count; a shortfall is reported and
    -- the closing figure simply goes negative.
    if v_have < v_qty then
      model := v_model; requested := v_qty; available := v_have; tracked := true;
      return next;
    end if;
  end loop;
end $$;

-- ── 3. The renames ────────────────────────────────────────────
-- One block, so it is all or nothing. Before anything is renamed every
-- warehouse is added up; afterwards it is added up again; any difference at
-- all raises an error, and an error here undoes every rename above it.
do $names$
declare
  v_main_before  jsonb;
  v_dahua_before jsonb;
  v_main_after   jsonb;
  v_dahua_after  jsonb;
  v_rows_before  integer;
  v_rows_after   integer;
begin
  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_main_before
    from (select warehouse, sum(closing_stock) as units from public.warehouse_stock group by warehouse) t;
  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_dahua_before
    from (select warehouse, sum(closing_stock) as units from public.dahua_stock group by warehouse) t;
  select (select count(*) from public.warehouse_stock) + (select count(*) from public.dahua_stock) into v_rows_before;

  -- Renaming a thousand rows is one event, not a thousand entries in the
  -- activity log. The summary is raised as a notice at the end instead.
  alter table public.warehouse_stock disable trigger trg_audit_warehouse_stock;
  alter table public.dahua_stock     disable trigger trg_audit_dahua_stock;

  -- Main shop: 109 names
  perform public.stock_merge_names('main', '12V5A ADAPTER', '12V 5A ADAPTER');
  perform public.stock_merge_names('main', ' 2U Westa 520*350*180 ', '2U Westa 520*350*180');
  perform public.stock_merge_names('main', '4U CABINET  600X600', '4U CABINET 600X600');
  perform public.stock_merge_names('main', '6U CABINET  600X600', '6U CABINET 600X600');
  perform public.stock_merge_names('main', '9U-CABINET', '9U-CABINET');
  perform public.stock_merge_names('main', 'Axiom cat6  Cable UTP gray 100m', 'Axiom cat6 Cable UTP gray 100m');
  perform public.stock_merge_names('main', 'Axiom cat6 SFTP outdoor PVC+PE 100m', 'Axiom cat6 SFTP OUTDOOR PVC+PE 100m');
  perform public.stock_merge_names('main', 'BNC connector copper', 'BNC CONNECTOR COPPER');
  perform public.stock_merge_names('main', 'Cable manager', 'CABLE MANAGER');
  perform public.stock_merge_names('main', 'CS-HB8c/SP', 'CS-HB8C/SP');
  perform public.stock_merge_names('main', 'CS-HB90x/SP', 'CS-HB90X/SP');
  perform public.stock_merge_names('main', 'Cs-HB90X/SP', 'CS-HB90X/SP');
  perform public.stock_merge_names('main', 'DECOx20(3pack)', 'Deco X20 3-pack');
  perform public.stock_merge_names('main', 'DH-CS4218-16ET-240', 'DH-CS4218-16ET-240');
  perform public.stock_merge_names('main', 'DH-CS4226-24ET-375', 'DH-CS4226-24ET-375');
  perform public.stock_merge_names('main', 'DH-XVRIBO4-I/T', 'DH-XVRIBO4-I/T');
  perform public.stock_merge_names('main', 'DS-1H18-A#', 'DS-1H18-A');
  perform public.stock_merge_names('main', 'DS-1LN6AUSPE-FTP#', 'DS-1LN6AUSPE-FTP');
  perform public.stock_merge_names('main', 'DS-2CD1023G2-LIU#', 'DS-2CD1023G2-LIU');
  perform public.stock_merge_names('main', 'ds-2cd1063g2-liu', 'DS-2CD1063G2-LIU');
  perform public.stock_merge_names('main', 'ds-2cd1163g2-liu', 'DS-2CD1163G2-LIU');
  perform public.stock_merge_names('main', 'DS-2CD1347G2H-LIUF/SRB  4 MP ColorVu Smart Hybrid', 'DS-2CD1347G2H-LIUF/SRB 4 MP ColorVu Smart Hybrid');
  perform public.stock_merge_names('main', 'DS-2CD2087G3-LI2UY/SRB**', 'DS-2CD2087G3-LI2UY/SRB');
  perform public.stock_merge_names('main', 'DS-2CD2187G2-LSU', 'DS-2CD2187G2+LSU');
  perform public.stock_merge_names('main', 'DS-2CE10KF0T-LPFS*', 'DS-2CE10KF0T-LPFS');
  perform public.stock_merge_names('main', 'ds-2ce16kot-lpfs', 'DS-2CE16KOT-LPFS');
  perform public.stock_merge_names('main', 'ds-2ce76kot-lpfs', 'DS-2CE76KOT-LPFS');
  perform public.stock_merge_names('main', 'DS-2CE78D0T-LPXTS*', 'DS-2CE78D0T-LPXTS');
  perform public.stock_merge_names('main', 'DS-2CFSO4/4G#', 'DS-2CFSO4/4G');
  perform public.stock_merge_names('main', 'DS-2CFSP4/4G*', 'DS-2CFSP4/4G');
  perform public.stock_merge_names('main', 'DS-2FA1225-C4(UK) 4CH POWER SUPPLY#', 'DS-2FA1225-C4(UK) 4CH POWER SUPPLY');
  perform public.stock_merge_names('main', 'DS-3E0116R-O#', 'DS-3E0116R-O');
  perform public.stock_merge_names('main', 'DS-3E1318P-E1/M*', 'DS-3E1318P-E1/M');
  perform public.stock_merge_names('main', 'DS-7204HGHI-M1/T#', 'DS-7204HGHI-M1/T');
  perform public.stock_merge_names('main', 'DS-7208HGHI-M1#', 'DS-7208HGHI-M1');
  perform public.stock_merge_names('main', 'DS-7216HGHI-M1/T*', 'DS-7216HGHI-M1/T');
  perform public.stock_merge_names('main', 'DS-7232HGH1-M2#', 'DS-7232HGH1-M2');
  perform public.stock_merge_names('main', 'DS-7604NXI-K1/4P(E)**', 'DS-7604NXI-K1/4P(E)');
  perform public.stock_merge_names('main', 'DS-7608NI-Q2-8P-E', 'DS-7608NI-Q2/8P(E)');
  perform public.stock_merge_names('main', 'DS-7608NXI-K1/8P(E)**', 'DS-7608NXI-K1/8P(E)');
  perform public.stock_merge_names('main', 'DS-7608NXI-K1(E)**', 'DS-7608NXI-K1(E)');
  perform public.stock_merge_names('main', 'DS-7616NXI-K1(E)#', 'DS-7616NXI-K1 (E)');
  perform public.stock_merge_names('main', 'DS-7616NXI-K1 NVR NONE POE 16CH*', 'DS-7616NXI-K1 NVR NONE POE 16CH');
  perform public.stock_merge_names('main', 'DS-7616NXI-K2/16P (E) NVR POE 16CH*', 'DS-7616NXI-K2/16P (E) NVR POE 16CH');
  perform public.stock_merge_names('main', 'DS-7632NXI-K2/16P(E)**', 'DS-7632NXI-K2/16P(E)');
  perform public.stock_merge_names('main', 'DS-7632NXI-K2(E)*', 'DS-7632NXI-K2(E)');
  perform public.stock_merge_names('main', 'DS-D5022F2-IV2#', 'DS-D5022F2-IV2');
  perform public.stock_merge_names('main', 'DS-D5024F2-AV2#', 'DS-D5024F2-AV2');
  perform public.stock_merge_names('main', 'DS-J142I/7208HGHI-M1+4+4 CAM/ COLOUR VU#', 'DS-J142I/7208HGHI-M1+4+4 CAM/ COLOUR VU');
  perform public.stock_merge_names('main', 'DS-K3GL606WX*', 'DS-K3GL606WX');
  perform public.stock_merge_names('main', 'DS-K7M-AW24#', 'DS-K7M-AW24');
  perform public.stock_merge_names('main', 'DS-KIA8503MF-B#', 'DS-KIA8503MF-B');
  perform public.stock_merge_names('main', 'DS-KIS303-P#', 'DS-KIS303-P');
  perform public.stock_merge_names('main', 'DS-KIS603-P(C)#', 'DS-KIS603-P (C)');
  perform public.stock_merge_names('main', 'DS-KIS608-P#', 'DS-KIS608-P');
  perform public.stock_merge_names('main', 'DS-KIS610-P#', 'DS-KIS610-P');
  perform public.stock_merge_names('main', 'DS-KIS611-S#', 'DS-KIS611-S');
  perform public.stock_merge_names('main', 'DS-KIS902-S#', 'DS-KIS902-S');
  perform public.stock_merge_names('main', 'DS-KIT343MFX#', 'DS-KIT343MFX');
  perform public.stock_merge_names('main', 'DS-KIT344MBFWX-E1*', 'DS-KIT344MBFWX-E1');
  perform public.stock_merge_names('main', 'DS-KIT808 MFWX', 'DS-KIT808MFWX');
  perform public.stock_merge_names('main', 'DS-KV6124WBE1', 'DS-KV6124-WBE1');
  perform public.stock_merge_names('main', 'DS-KV6133-WME1#', 'DS-KV6133-WME1');
  perform public.stock_merge_names('main', 'DS-KV8113-WME1(C)#', 'DS-KV8113-WME1(C)');
  perform public.stock_merge_names('main', 'DS-PDP15P-EG2-WE(B)#', 'DS-PDP15P-EG2-WE(B)');
  perform public.stock_merge_names('main', 'DS-QA20206GI-S#', 'DS-QA20206GI-S');
  perform public.stock_merge_names('main', 'DS-QAE0120GIR#', 'DS-QAE0120GIR');
  perform public.stock_merge_names('main', 'DS-QAE0A60G1-VB*', 'DS-QAE0A60G1-VB');
  perform public.stock_merge_names('main', 'DS-QAEOA60G1-VB#', 'DS-QAEOA60G1-VB');
  perform public.stock_merge_names('main', 'DS-UPS-1200-R*', 'DS-UPS-1200-R');
  perform public.stock_merge_names('main', 'DS-UPS2000va', 'DS-UPS2000VA');
  perform public.stock_merge_names('main', 'DS-ups2000va', 'DS-UPS2000VA');
  perform public.stock_merge_names('main', 'EAP215-BRIDGE KIT', 'EAP215 BRIDGE KIT');
  perform public.stock_merge_names('main', 'EAP235 Wall', 'EAP 235 WALL');
  perform public.stock_merge_names('main', 'EAP 235 WALL', 'EAP 235 WALL');
  perform public.stock_merge_names('main', 'EAP610GP Desktop (EU)', 'EAP610GP DESKTOP (EU)');
  perform public.stock_merge_names('main', 'EAP610 Outdoor', 'EAP610 OUTDOOR');
  perform public.stock_merge_names('main', 'EAP725 Outdoor', 'EAP725 OUTDOOR');
  perform public.stock_merge_names('main', 'HDMI FIBRE OPTIC 15M#', 'HDMI FIBRE OPTIC 15M');
  perform public.stock_merge_names('main', 'Hilook NVR104H-D/4P', 'HiLook NVR-104H-D/4P');
  perform public.stock_merge_names('main', 'Hilook NVR-108H-D/8P', 'HI-LOOK NVR-108H-D/8P');
  perform public.stock_merge_names('main', 'IDS-7204HQHI-M1/T#', 'IDS-7204HQHI-M1/T');
  perform public.stock_merge_names('main', 'IDS-7204HQHI-M1/XT#', 'IDS-7204HQHI-M1/XT');
  perform public.stock_merge_names('main', 'IDS-7208HQHI-M1/T#', 'IDS-7208HQHI-M1/T');
  perform public.stock_merge_names('main', 'IDS-7208HQHI-M1/XT#', 'IDS-7208HQHI-M1/XT');
  perform public.stock_merge_names('main', 'IDS-7216HQHI-M1/T#', 'IDS-7216HQHI-M1/T');
  perform public.stock_merge_names('main', 'IDS-7232HQHI-M2/XT#', 'IDS-7232HQHI-M2/XT');
  perform public.stock_merge_names('main', 'IOS84', 'IO-S84');
  perform public.stock_merge_names('main', 'IOWF145', 'IO-WF145');
  perform public.stock_merge_names('main', ' JUNCTION BOX BIG', 'JUNCTION BOX BIG');
  perform public.stock_merge_names('main', 'Junction box big size', 'JUNCTION BOX BIG SIZE');
  perform public.stock_merge_names('main', 'JUNCTION BOX BIG SIZE ROUND ', 'JUNCTION BOX BIG SIZE ROUND');
  perform public.stock_merge_names('main', 'Junction Box Small', 'JUNCTION BOX SMALL');
  perform public.stock_merge_names('main', 'Mini smart switch*', 'Mini smart switch');
  perform public.stock_merge_names('main', 'MODULAR CRIMPING TOOL PASS THROUGH', 'MODULAR CRIMPING TOOL PASS-THROUGH');
  perform public.stock_merge_names('main', 'Network Tool Kit', 'NETWORK TOOL KIT');
  perform public.stock_merge_names('main', 'NK844WDH', 'NK844WDH');
  perform public.stock_merge_names('main', 'PATRESS-BOX#', 'PATRESS-BOX');
  perform public.stock_merge_names('main', 'PDU extension board', 'PDU EXTENSION BOARD');
  perform public.stock_merge_names('main', 'PS4 GAME PAD', 'PS4 GAMEPAD');
  perform public.stock_merge_names('main', 'PS4 gamepad', 'PS4 GAMEPAD');
  perform public.stock_merge_names('main', ' PS5 GAMEPAD', 'PS5 GAMEPAD');
  perform public.stock_merge_names('main', 'PS5 GAME PAD', 'PS5 GAMEPAD');
  perform public.stock_merge_names('main', 'SD-UPS2000VA', 'SD-UPS-2000VA');
  perform public.stock_merge_names('main', ' SD-UPS-3000VA', 'SD-UPS-3000VA');
  perform public.stock_merge_names('main', 'Tapo C200', 'TAPO C200');
  perform public.stock_merge_names('main', 'U7 Lite', 'U7 LITE');
  perform public.stock_merge_names('main', 'Video Balun 8mp', 'VIDEO BALUN 8MP');
  perform public.stock_merge_names('main', 'Video balun 8MP', 'VIDEO BALUN 8MP');

  -- Dahua: 22 names
  perform public.stock_merge_names('dahua', '12V5A ADAPTER ', '12V 5A ADAPTER');
  perform public.stock_merge_names('dahua', '4U WESTA CABINET ', '4U WESTA CABINET');
  perform public.stock_merge_names('dahua', 'DH-CS4006-4ET2GT-60  SWITCH', 'DH-CS4006-4ET2GT-60 SWITCH');
  perform public.stock_merge_names('dahua', 'DH-HAC-B1A21P-U 2MP ', 'DH-HAC-B1A21P-U 2MP');
  perform public.stock_merge_names('dahua', 'DH-HAC-HDW1509CLQP-A-LED 5MP ', 'DH-HAC-HDW1509CLQP-A-LED 5MP');
  perform public.stock_merge_names('dahua', 'DH-HAC-HFW1500CLP-IL-A   5MP', 'DH-HAC-HFW1500CLP-IL-A 5MP');
  perform public.stock_merge_names('dahua', 'DHI-KTP01L(S) IP INTERCOM WITH IP SWITCH ', 'DHI-KTP01L(S) IP INTERCOM WITH IP SWITCH');
  perform public.stock_merge_names('dahua', 'DHI-KTP02 IP INTERCOM BLACK WITH SWITCH ', 'DHI-KTP02 IP INTERCOM BLACK WITH SWITCH');
  perform public.stock_merge_names('dahua', 'DHI-KTP10 VIDEO INTERCOM KIT IP INTERCOM WITH POE SWITCH ', 'DHI-KTP10 VIDEO INTERCOM KIT IP INTERCOM WITH POE SWITCH');
  perform public.stock_merge_names('dahua', 'DH-IPC-C3AP-0280B CUBE 3MP indoor Wi-Fi cube IP camera ', 'DH-IPC-C3AP-0280B CUBE 3MP indoor Wi-Fi cube IP camera');
  perform public.stock_merge_names('dahua', 'DH-IPC-HFW2439SP-SA-LED-S2 4MP ', 'DH-IPC-HFW2439SP-SA-LED-S2 4MP');
  perform public.stock_merge_names('dahua', 'DH-IPC-HFW2441DG-4G-SP-B    64Wh', 'DH-IPC-HFW2441DG-4G-SP-B 64Wh');
  perform public.stock_merge_names('dahua', 'DH-MR403 DAHUA ROUTER ', 'DH-MR403 DAHUA ROUTER');
  perform public.stock_merge_names('dahua', 'HDMI 60M KVM EXTENDER', 'HDMI 60m KVM extender');
  perform public.stock_merge_names('dahua', 'QS-V5 VIDEO CALLING CAMERA ', 'QS-V5 VIDEO CALLING CAMERA');
  perform public.stock_merge_names('dahua', 'SD-UPS1000VA', 'SD-UPS-1000VA');
  perform public.stock_merge_names('dahua', 'SOLID UPS 2000VA', 'SOLID-UPS2000Va');
  perform public.stock_merge_names('dahua', 'ST-LC55-6M-4G SOLAR STREET ', 'ST-LC55-6M-4G SOLAR STREET');
  perform public.stock_merge_names('dahua', 'WESTA CAT6 SFTP AG003  OUTDOOR', 'WESTA CAT6 SFTP AG003 OUTDOOR');
  perform public.stock_merge_names('dahua', 'WIRELESS HDMI 100M', 'Wireless HDMI 100 m');
  perform public.stock_merge_names('dahua', 'WIRELESS HDMI 150M', 'Wireless HDMI 150 m');
  perform public.stock_merge_names('dahua', 'WIRELESS HDMI 50M', 'Wireless HDMI 50 m');

  alter table public.warehouse_stock enable trigger trg_audit_warehouse_stock;
  alter table public.dahua_stock     enable trigger trg_audit_dahua_stock;

  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_main_after
    from (select warehouse, sum(closing_stock) as units from public.warehouse_stock group by warehouse) t;
  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_dahua_after
    from (select warehouse, sum(closing_stock) as units from public.dahua_stock group by warehouse) t;
  select (select count(*) from public.warehouse_stock) + (select count(*) from public.dahua_stock) into v_rows_after;

  if v_main_after <> v_main_before then
    raise exception 'A main-shop warehouse total changed — nothing has been saved. Before: %  After: %',
      v_main_before, v_main_after;
  end if;
  if v_dahua_after <> v_dahua_before then
    raise exception 'A Dahua warehouse total changed — nothing has been saved. Before: %  After: %',
      v_dahua_before, v_dahua_after;
  end if;

  raise notice 'Names made uniform. Every warehouse holds exactly what it held before. Stock rows: % before, % after (% doubled rows folded into one).',
    v_rows_before, v_rows_after, v_rows_before - v_rows_after;
end $names$;

-- ── Verification (run after the block above) ──────────────────
-- No warehouse should list one product code twice any more (expect 0 rows):
--
-- select warehouse, public.stock_model_key(model) as code, array_agg(model) as spellings
--   from public.warehouse_stock
--  group by 1, 2 having count(*) > 1;
--
-- No name should end in a # or * (expect 0):
--
-- select count(*) from public.warehouse_stock where model ~ '[#*]\s*$';
--
-- One spelling per code across all warehouses (expect 0 rows):
--
-- select public.stock_model_key(model) as code, array_agg(distinct model) as spellings
--   from public.warehouse_stock
--  group by 1 having count(distinct model) > 1;
