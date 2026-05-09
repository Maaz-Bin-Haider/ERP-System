--
-- ============================================================
-- VIEW: item_last_purchase_view
-- ============================================================
--

CREATE VIEW public.item_last_purchase_view AS
 WITH last_purchase AS (
         SELECT DISTINCT ON (pi.item_id) pi.item_id,
            pi.unit_price AS last_purchase_price,
            pinv.invoice_date AS last_purchase_date
           FROM (public.purchaseitems pi
             JOIN public.purchaseinvoices pinv ON ((pi.purchase_invoice_id = pinv.purchase_invoice_id)))
          ORDER BY pi.item_id, pinv.invoice_date DESC
        )
 SELECT i.item_name,
    i.category,
    i.brand,
    lp.last_purchase_price,
    lp.last_purchase_date
   FROM (public.items i
     LEFT JOIN last_purchase lp ON ((i.item_id = lp.item_id)))
  ORDER BY i.item_name;


ALTER VIEW public.item_last_purchase_view OWNER TO postgres;
