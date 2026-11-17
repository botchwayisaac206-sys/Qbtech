-- Close an audit gap: deliveries count toward Total Sales on the dashboard
-- (see SalesDashboard.tsx income = invoiceIncome + deliveryIncome) but never
-- had an audit trigger, so a deleted delivery silently changed the sales
-- total with no trace. Reuses the existing fn_audit() used by invoices/
-- expenses/warehouse_stock/product_codes — same audit_log table, same shape.

drop trigger if exists trg_audit_deliveries on public.deliveries;
create trigger trg_audit_deliveries
  after insert or update or delete on public.deliveries
  for each row execute function public.fn_audit();
