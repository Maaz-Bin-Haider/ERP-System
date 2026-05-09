--
-- ============================================================
-- VIEW: vw_dash_stock_overview
-- ============================================================
--

CREATE VIEW public.vw_dash_stock_overview AS
 SELECT i.item_id,
    i.item_name,
    i.category,
    i.brand,
    i.sale_price,
    count(pu.unit_id) FILTER (WHERE (pu.in_stock = true)) AS units_in_stock,
    COALESCE(avg(pi2.unit_price) FILTER (WHERE (pu.in_stock = true)), (0)::numeric) AS avg_cost_price,
    max(pinv.invoice_date) FILTER (WHERE (pu.in_stock = true)) AS last_purchased,
    ( SELECT max(sinv.invoice_date) AS max
           FROM ((public.salesitems sitem
             JOIN public.soldunits su2 ON ((su2.sales_item_id = sitem.sales_item_id)))
             JOIN public.salesinvoices sinv ON ((sinv.sales_invoice_id = sitem.sales_invoice_id)))
          WHERE (sitem.item_id = i.item_id)) AS last_sold_date
   FROM (((public.items i
     LEFT JOIN public.purchaseitems pi2 ON ((pi2.item_id = i.item_id)))
     LEFT JOIN public.purchaseunits pu ON ((pu.purchase_item_id = pi2.purchase_item_id)))
     LEFT JOIN public.purchaseinvoices pinv ON ((pinv.purchase_invoice_id = pi2.purchase_invoice_id)))
  GROUP BY i.item_id, i.item_name, i.category, i.brand, i.sale_price;


ALTER VIEW public.vw_dash_stock_overview OWNER TO postgres;
