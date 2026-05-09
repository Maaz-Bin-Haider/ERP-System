--
-- ============================================================
-- VIEW: stock_report
-- ============================================================
--

CREATE VIEW public.stock_report AS
 WITH stock AS (
         SELECT i.item_id,
            i.item_name,
            count(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
            pu.serial_number,
            pu.serial_comment,
            pi.invoice_date AS purchase_date,
            (CURRENT_DATE - pi.invoice_date) AS age_in_days,
            round((((CURRENT_DATE - pi.invoice_date))::numeric / 30.44), 1) AS age_in_months,
            row_number() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
           FROM (((public.purchaseunits pu
             JOIN public.purchaseitems pit ON ((pu.purchase_item_id = pit.purchase_item_id)))
             JOIN public.purchaseinvoices pi ON ((pit.purchase_invoice_id = pi.purchase_invoice_id)))
             JOIN public.items i ON ((pit.item_id = i.item_id)))
          WHERE ((pu.in_stock = true) AND (NOT (EXISTS ( SELECT 1
                   FROM public.soldunits su
                  WHERE ((su.unit_id = pu.unit_id) AND ((su.status)::text = 'Sold'::text))))) AND (NOT (EXISTS ( SELECT 1
                   FROM public.purchasereturnitems pri
                  WHERE ((pri.serial_number)::text = (pu.serial_number)::text)))))
        )
 SELECT
        CASE
            WHEN (rn = 1) THEN (item_id)::text
            ELSE ''::text
        END AS item_id,
        CASE
            WHEN (rn = 1) THEN item_name
            ELSE ''::character varying
        END AS item_name,
        CASE
            WHEN (rn = 1) THEN (quantity)::text
            ELSE ''::text
        END AS quantity,
    serial_number,
    serial_comment,
    age_in_days,
    age_in_months
   FROM stock
  ORDER BY ((item_id)::integer), rn;


ALTER VIEW public.stock_report OWNER TO postgres;
