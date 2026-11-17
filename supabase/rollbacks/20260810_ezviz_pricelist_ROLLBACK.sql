-- ─────────────────────────────────────────────────────────────
-- ROLLBACK for 20260810_ezviz_pricelist.sql
--
-- Removes the 22 EZVIZ products and the 'EZVIZ' category.
--
-- The category is only dropped once it is empty, so if you have added your own
-- items to it since, they are kept and the category survives.
--
-- Note: pricelist_items has no invoice foreign key — the price list is a
-- catalogue, not stock — so deleting these rows cannot orphan an invoice.
-- ─────────────────────────────────────────────────────────────

begin;

delete from pricelist_items pi
 using pricelist_categories pc
 where pc.id = pi.category_id
   and pc.name = 'EZVIZ'
   and pi.model in (
         'CS-C7-44WF',
         'CS-CB1',
         'CS-CB2-B',
         'CS-CB2-W',
         'CS-CB3/SP-2K',
         'CS-E4P-6MP',
         'CS-EB3/SP-2K',
         'CS-EB8/SP-4KW4GA',
         'CS-EP3x/SD7-KIT',
         'CS-H1C',
         'CS-H3C-3MP/Colored',
         'CS-H5-4G',
         'CS-H6-5WF-3K',
         'CS-H7C-44WFW2',
         'CS-H80X-8MP+2MP4M',
         'CS-H90-4MP+4MP',
         'CS-H9C-3MP',
         'CS-HB8/SP-4k',
         'CS-HB8C/SP-4MPW4G',
         'CS-HB90/SP-4MP+4MP',
         'CS-HB90X/SP-4MP+4M-4G',
         'CS-SD7'
       );

delete from pricelist_categories pc
 where pc.name = 'EZVIZ'
   and not exists (select 1 from pricelist_items pi where pi.category_id = pc.id);

commit;
