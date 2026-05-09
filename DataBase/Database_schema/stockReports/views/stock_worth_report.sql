--
-- ============================================================
-- VIEW: stock_worth_report
-- ============================================================
--

CREATE VIEW public.stock_worth_report AS
 WITH stock AS (
         SELECT i.item_id,
            i.item_name,
            count(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
            pu.serial_number,
            pu.serial_comment,
            pit.unit_price AS purchase_price,
            i.sale_price AS market_price,
            row_number() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
           FROM ((public.purchaseunits pu
             JOIN public.purchaseitems pit ON ((pu.purchase_item_id = pit.purchase_item_id)))
             JOIN public.items i ON ((pit.item_id = i.item_id)))
          WHERE ((pu.in_stock = true) AND (NOT (EXISTS ( SELECT 1
                   FROM public.soldunits su
                  WHERE ((su.unit_id = pu.unit_id) AND ((su.status)::text = 'Sold'::text))))) AND (NOT (EXISTS ( SELECT 1
                   FROM public.purchasereturnitems pri
                  WHERE ((pri.serial_number)::text = (pu.serial_number)::text)))))
        ), running AS (
         SELECT stock.item_id,
            stock.item_name,
            stock.quantity,
            stock.serial_number,
            stock.serial_comment,
            stock.purchase_price,
            stock.market_price,
            sum(stock.purchase_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_purchase,
            sum(stock.market_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_market,
            stock.rn
           FROM stock
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
    purchase_price,
    market_price,
    running_total_purchase,
    running_total_market
   FROM running
  ORDER BY ((item_id)::integer), rn;


ALTER VIEW public.stock_worth_report OWNER TO postgres;
