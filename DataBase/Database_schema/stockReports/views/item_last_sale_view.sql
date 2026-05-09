--
-- ============================================================
-- VIEW: item_last_sale_view
-- ============================================================
--

CREATE VIEW public.item_last_sale_view AS
 WITH last_sale AS (
         SELECT DISTINCT ON (si.item_id) si.item_id,
            si.unit_price AS last_sale_price,
            sinv.invoice_date AS last_sale_date
           FROM (public.salesitems si
             JOIN public.salesinvoices sinv ON ((si.sales_invoice_id = sinv.sales_invoice_id)))
          ORDER BY si.item_id, sinv.invoice_date DESC
        )
 SELECT i.item_name,
    i.category,
    i.brand,
    ls.last_sale_price,
    ls.last_sale_date
   FROM (public.items i
     LEFT JOIN last_sale ls ON ((i.item_id = ls.item_id)))
  ORDER BY i.item_name;


ALTER VIEW public.item_last_sale_view OWNER TO postgres;
