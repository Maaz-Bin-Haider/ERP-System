--===============================================================================================
--                                       STOCK Reports START
--===============================================================================================
-- ======================================================
-- 1. item_transaction_history - Updated
-- ======================================================
CREATE OR REPLACE FUNCTION public.item_transaction_history(
    p_item_name text, 
    p_from_date date DEFAULT NULL::date, 
    p_to_date date DEFAULT NULL::date
) 
RETURNS TABLE(
    item_name text, 
    serial_number text, 
    serial_comment text,
    transaction_date date, 
    transaction_type text, 
    counterparty text, 
    price numeric
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH purchase_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            pu.serial_comment::TEXT AS serial_comment,
            p.invoice_date AS transaction_date,
            'PURCHASE'::TEXT AS transaction_type,
            v.party_name::TEXT AS counterparty,
            pi.unit_price AS price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
        JOIN Parties v ON p.vendor_id = v.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
          AND (p_from_date IS NULL OR p.invoice_date >= p_from_date)
          AND (p_to_date IS NULL OR p.invoice_date <= p_to_date)
    ),
    sale_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            pu.serial_comment::TEXT AS serial_comment,
            s.invoice_date AS transaction_date,
            'SALE'::TEXT AS transaction_type,
            c.party_name::TEXT AS counterparty,
            su.sold_price AS price
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        JOIN Parties c ON s.customer_id = c.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
          AND (p_from_date IS NULL OR s.invoice_date >= p_from_date)
          AND (p_to_date IS NULL OR s.invoice_date <= p_to_date)
    )
    SELECT 
        ph.item_name,
        ph.serial_number,
        ph.serial_comment,
        ph.transaction_date,
        ph.transaction_type,
        ph.counterparty,
        ph.price
    FROM (
        SELECT * FROM purchase_history
        UNION ALL
        SELECT * FROM sale_history
    ) AS ph
    ORDER BY ph.transaction_date, 
             ph.transaction_type DESC,   -- ensures PURCHASE before SALE if same date
             ph.serial_number;
END;
$$;


-- ======================================================
-- 2. get_item_stock_by_name - Updated
-- ======================================================
CREATE OR REPLACE FUNCTION get_item_stock_by_name(p_item_name VARCHAR)
RETURNS TABLE (
    item_id_out TEXT,
    item_name_out VARCHAR(150),
    serial_number_out VARCHAR(100),
    serial_comment_out TEXT,
    quantity_out TEXT
) 
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH stock AS (
        SELECT 
            i.item_id,
            i.item_name,
            pu.serial_number,
            pu.serial_comment,
            COUNT(*) OVER () AS total_quantity,
            ROW_NUMBER() OVER (ORDER BY pu.serial_number) AS rn
        FROM purchaseunits pu
        JOIN purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN items i ON pit.item_id = i.item_id
        WHERE i.item_name = p_item_name
          AND pu.in_stock = true
    )
    SELECT 
        CASE WHEN rn = 1 THEN item_id::TEXT ELSE '' END,
        CASE WHEN rn = 1 THEN item_name ELSE ''::VARCHAR END,
        serial_number,
        serial_comment,
        CASE WHEN rn = 1 THEN total_quantity::TEXT ELSE '' END
    FROM stock
    ORDER BY rn;
END;
$$;


-- ======================================================
-- 3. stock_worth_report - Updated VIEW
-- ======================================================


CREATE VIEW public.stock_worth_report AS
WITH stock AS (
    SELECT 
        i.item_id,
        i.item_name,
        COUNT(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
        pu.serial_number,
        pu.serial_comment,
        pit.unit_price AS purchase_price,
        i.sale_price AS market_price,
        ROW_NUMBER() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
    FROM public.purchaseunits pu
    JOIN public.purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN public.items i ON pit.item_id = i.item_id
    WHERE pu.in_stock = true
), 
running AS (
    SELECT 
        stock.item_id,
        stock.item_name,
        stock.quantity,
        stock.serial_number,
        stock.serial_comment,
        stock.purchase_price,
        stock.market_price,
        SUM(stock.purchase_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_purchase,
        SUM(stock.market_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_market,
        stock.rn
    FROM stock
)
SELECT
    CASE WHEN rn = 1 THEN item_id::TEXT ELSE ''::TEXT END AS item_id,
    CASE WHEN rn = 1 THEN item_name ELSE ''::VARCHAR END AS item_name,
    CASE WHEN rn = 1 THEN quantity::TEXT ELSE ''::TEXT END AS quantity,
    serial_number,
    serial_comment,
    purchase_price,
    market_price,
    running_total_purchase,
    running_total_market
FROM running
ORDER BY item_id::INTEGER, rn;


-- ======================================================
-- 4. stock_report - Updated VIEW
-- ======================================================
DROP VIEW IF EXISTS public.stock_report;

CREATE VIEW public.stock_report AS
WITH stock AS (
    SELECT 
        i.item_id,
        i.item_name,
        COUNT(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
        pu.serial_number,
        pu.serial_comment,
        ROW_NUMBER() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
    FROM public.purchaseunits pu
    JOIN public.purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN public.items i ON pit.item_id = i.item_id
    WHERE pu.in_stock = true
)
SELECT
    CASE WHEN rn = 1 THEN item_id::TEXT ELSE ''::TEXT END AS item_id,
    CASE WHEN rn = 1 THEN item_name ELSE ''::VARCHAR END AS item_name,
    CASE WHEN rn = 1 THEN quantity::TEXT ELSE ''::TEXT END AS quantity,
    serial_number,
    serial_comment
FROM stock
ORDER BY item_id::INTEGER, rn;


-- this new view contains age feature
DROP VIEW IF EXISTS public.stock_report;
CREATE OR REPLACE VIEW public.stock_report AS
WITH stock AS (
    SELECT 
        i.item_id,
        i.item_name,
        COUNT(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
        pu.serial_number,
        pu.serial_comment,
        pi.invoice_date AS purchase_date,
        CURRENT_DATE - pi.invoice_date AS age_in_days,
        ROUND((CURRENT_DATE - pi.invoice_date) / 30.44, 1) AS age_in_months,
        ROW_NUMBER() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
    FROM public.purchaseunits pu
    JOIN public.purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN public.purchaseinvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
    JOIN public.items i ON pit.item_id = i.item_id
    WHERE pu.in_stock = true
)
SELECT
    CASE WHEN rn = 1 THEN item_id::TEXT     ELSE ''::TEXT    END AS item_id,
    CASE WHEN rn = 1 THEN item_name         ELSE ''::VARCHAR END AS item_name,
    CASE WHEN rn = 1 THEN quantity::TEXT    ELSE ''::TEXT    END AS quantity,
    serial_number,
    serial_comment,
    age_in_days,
    age_in_months
FROM stock
ORDER BY item_id::INTEGER, rn;


-- ======================================================
-- 5. stock_summary - No changes needed (aggregate level)
-- ======================================================
-- This function works at item level aggregation, so serial_comment 
-- is not relevant here. No changes required.


-- ======================================================
-- 6. get_serial_ledger - Updated
-- ======================================================
CREATE OR REPLACE FUNCTION public.get_serial_ledger(p_serial text) 
RETURNS TABLE(
    serial_number text, 
    serial_comment text,
    item_name text, 
    txn_date date, 
    particulars text, 
    reference text, 
    qty_in integer, 
    qty_out integer, 
    balance integer, 
    party_name text, 
    purchase_price numeric, 
    sale_price numeric, 
    profit numeric
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY

    WITH item_info AS (
        SELECT 
            pu.serial_number::text AS serial_number,
            pu.serial_comment::text AS serial_comment,
            i.item_name::text AS item_name
        FROM PurchaseUnits pu
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN Items i ON pit.item_id = i.item_id
        WHERE pu.serial_number = p_serial
        LIMIT 1
    ),

    purchase AS (
        SELECT 
            pi.invoice_date AS dt,
            'Purchase'::text AS particulars,
            pi.purchase_invoice_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            p.party_name::text AS party_name,
            pit.unit_price AS purchase_price,
            NULL::numeric AS sale_price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN PurchaseInvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
        JOIN Parties p ON pi.vendor_id = p.party_id
        WHERE pu.serial_number = p_serial
    ),

    purchase_return AS (
        SELECT
            pr.return_date AS dt,
            'Purchase Return'::text AS particulars,
            pr.purchase_return_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            p.party_name::text AS party_name,
            pri.unit_price AS purchase_price,
            NULL::numeric AS sale_price
        FROM PurchaseReturnItems pri
        JOIN PurchaseReturns pr ON pri.purchase_return_id = pr.purchase_return_id
        JOIN Parties p ON pr.vendor_id = p.party_id
        WHERE pri.serial_number = p_serial
    ),

    sale AS (
        SELECT 
            si.invoice_date AS dt,
            'Sale'::text AS particulars,
            si.sales_invoice_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            c.party_name::text AS party_name,
            pit.unit_price AS purchase_price,
            su.sold_price AS sale_price
        FROM SoldUnits su
        JOIN SalesItems sitm ON su.sales_item_id = sitm.sales_item_id
        JOIN SalesInvoices si ON sitm.sales_invoice_id = si.sales_invoice_id
        JOIN Parties c ON si.customer_id = c.party_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        WHERE pu.serial_number = p_serial
    ),

    sales_return AS (
        SELECT
            sr.return_date AS dt,
            'Sales Return'::text AS particulars,
            sr.sales_return_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            c.party_name::text AS party_name,
            sri.cost_price AS purchase_price,
            sri.sold_price AS sale_price
        FROM SalesReturnItems sri
        JOIN SalesReturns sr ON sri.sales_return_id = sr.sales_return_id
        JOIN Parties c ON sr.customer_id = c.party_id
        WHERE sri.serial_number = p_serial
    )

    SELECT
        ii.serial_number,
        ii.serial_comment,
        ii.item_name,
        l.dt AS txn_date,
        l.particulars,
        l.reference,
        l.qty_in,
        l.qty_out,
        CAST(SUM(l.qty_in - l.qty_out) OVER (ORDER BY l.dt, l.reference) AS INT) AS balance,
        l.party_name,
        l.purchase_price,
        l.sale_price,
        CASE 
            WHEN l.sale_price IS NOT NULL AND l.purchase_price IS NOT NULL 
            THEN l.sale_price - l.purchase_price
        END AS profit
    FROM (
        SELECT * FROM purchase
        UNION ALL SELECT * FROM purchase_return
        UNION ALL SELECT * FROM sale
        UNION ALL SELECT * FROM sales_return
    ) l
    CROSS JOIN item_info ii
    ORDER BY l.dt, l.reference;

END;
$$;



CREATE OR REPLACE FUNCTION public.stock_summary()
RETURNS TABLE (
    item_id BIGINT,
    item_name VARCHAR,
    category VARCHAR,
    brand VARCHAR,
    quantity_in_stock BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        i.item_id,
        i.item_name,
        i.category,
        i.brand,
        COUNT(pu.unit_id) FILTER (WHERE pu.in_stock = TRUE) AS quantity_in_stock
    FROM Items i
    LEFT JOIN PurchaseItems pi ON i.item_id = pi.item_id
    LEFT JOIN PurchaseUnits pu ON pi.purchase_item_id = pu.purchase_item_id
    GROUP BY
        i.item_id,
        i.item_name,
        i.category,
        i.brand
    ORDER BY
        i.item_name ASC;
END;
$$;



CREATE OR REPLACE VIEW public.item_last_purchase_view AS
WITH last_purchase AS (
    SELECT DISTINCT ON (pi.item_id)
        pi.item_id,
        pi.unit_price        AS last_purchase_price,
        pinv.invoice_date    AS last_purchase_date
    FROM PurchaseItems pi
    JOIN PurchaseInvoices pinv ON pi.purchase_invoice_id = pinv.purchase_invoice_id
    ORDER BY pi.item_id, pinv.invoice_date DESC
)
SELECT
    i.item_name,
    i.category,
    i.brand,
    lp.last_purchase_price,
    lp.last_purchase_date
FROM Items i
LEFT JOIN last_purchase lp ON i.item_id = lp.item_id
ORDER BY i.item_name ASC;



SELECT * FROM item_last_purchase_view


--
-- Name: get_serial_number_details(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_serial_number_details(serial text) RETURNS TABLE(serial_number character varying, item_name character varying, brand character varying, category character varying, purchase_invoice_id bigint, vendor_name character varying, purchase_date date, purchase_price numeric, in_stock boolean, sales_invoice_id bigint, customer_name character varying, sale_date date, sold_price numeric, current_status character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        pu.serial_number,
        i.item_name,
        i.brand,
        i.category,
        pi.purchase_invoice_id,
        p.party_name AS vendor_name,
        pi.invoice_date AS purchase_date,
        pit.unit_price AS purchase_price,
        pu.in_stock,
        si.sales_invoice_id,
        c.party_name AS customer_name,
        si.invoice_date AS sale_date,
        su.sold_price,
        COALESCE(su.status, CASE WHEN pu.in_stock THEN 'In Stock' ELSE 'Sold/Unknown' END) AS current_status
    FROM PurchaseUnits pu
    JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN Items i ON pit.item_id = i.item_id
    JOIN PurchaseInvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
    JOIN Parties p ON pi.vendor_id = p.party_id
    LEFT JOIN SoldUnits su ON su.unit_id = pu.unit_id
    LEFT JOIN SalesItems si_itm ON su.sales_item_id = si_itm.sales_item_id
    LEFT JOIN SalesInvoices si ON si_itm.sales_invoice_id = si.sales_invoice_id
    LEFT JOIN Parties c ON si.customer_id = c.party_id
    WHERE pu.serial_number = serial;
END;
$$;
--===============================================================================================
--                                       STOCK Reports END
--===============================================================================================
