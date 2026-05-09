--
-- ============================================================
-- FUNCTION: get_serial_ledger_purchase(text)
-- ============================================================
--

CREATE FUNCTION public.get_serial_ledger_purchase(p_serial text) RETURNS TABLE(serial_number text, serial_comment text, item_name text, txn_date date, particulars text, reference text, qty_in integer, qty_out integer, balance integer, party_name text, purchase_price numeric)
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

    purchase AS (
        SELECT 
            pi.invoice_date AS dt,
            'Purchase'::text AS particulars,
            pi.purchase_invoice_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            p.party_name::text,
            pit.unit_price AS purchase_price
        FROM purchaseunits pu
        JOIN purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN purchaseinvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
        JOIN parties p ON pi.vendor_id = p.party_id
        WHERE pu.serial_number = p_serial
    ),

    purchase_return AS (
        SELECT
            pr.return_date AS dt,
            'Purchase Return'::text AS particulars,
            pr.purchase_return_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            p.party_name::text,
            pri.unit_price AS purchase_price
        FROM purchasereturnitems pri
        JOIN purchasereturns pr ON pri.purchase_return_id = pr.purchase_return_id
        JOIN parties p ON pr.vendor_id = p.party_id
        WHERE pri.serial_number = p_serial
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
        l.purchase_price
    FROM (
        SELECT * FROM purchase
        UNION ALL
        SELECT * FROM purchase_return
    ) l
    CROSS JOIN item_info ii
    ORDER BY l.dt, l.reference;

END;
$$;


ALTER FUNCTION public.get_serial_ledger_purchase(p_serial text) OWNER TO postgres;
