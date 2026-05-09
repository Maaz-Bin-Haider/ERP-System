--
-- ============================================================
-- FUNCTION: get_serial_ledger_sales(text)
-- ============================================================
--

CREATE FUNCTION public.get_serial_ledger_sales(p_serial text) RETURNS TABLE(serial_number text, serial_comment text, item_name text, txn_date date, particulars text, reference text, qty_in integer, qty_out integer, balance integer, party_name text, sale_price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY

    WITH item_info AS (
        SELECT 
            pu.serial_number::text,
            pu.serial_comment::text,
            i.item_name::text
        FROM purchaseunits pu
        JOIN purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN items i ON pit.item_id = i.item_id
        WHERE pu.serial_number = p_serial
        LIMIT 1
    ),

    sale AS (
        SELECT 
            si.invoice_date AS dt,
            'Sale'::text AS particulars,
            si.sales_invoice_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            c.party_name::text,
            su.sold_price AS sale_price
        FROM soldunits su
        JOIN salesitems sitm ON su.sales_item_id = sitm.sales_item_id
        JOIN salesinvoices si ON sitm.sales_invoice_id = si.sales_invoice_id
        JOIN parties c ON si.customer_id = c.party_id
        JOIN purchaseunits pu ON su.unit_id = pu.unit_id
        WHERE pu.serial_number = p_serial
    ),

    sales_return AS (
        SELECT
            sr.return_date AS dt,
            'Sales Return'::text AS particulars,
            sr.sales_return_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            c.party_name::text,
            sri.sold_price AS sale_price
        FROM salesreturnitems sri
        JOIN salesreturns sr ON sri.sales_return_id = sr.sales_return_id
        JOIN parties c ON sr.customer_id = c.party_id
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
        l.sale_price
    FROM (
        SELECT * FROM sale
        UNION ALL
        SELECT * FROM sales_return
    ) l
    CROSS JOIN item_info ii
    ORDER BY l.dt, l.reference;

END;
$$;


ALTER FUNCTION public.get_serial_ledger_sales(p_serial text) OWNER TO postgres;
