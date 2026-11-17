-- Add section_labels to warehouses so each warehouse can define
-- named daily-quantity groups shown in the stock item edit form.
alter table warehouses
  add column if not exists section_labels text[] not null default '{}';
