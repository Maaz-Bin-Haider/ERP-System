--
-- ============================================================
-- FUNCTION: fn_dash_recent_transactions(integer)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_recent_transactions(p_limit integer DEFAULT 10) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    -- The UNION ALL subquery is wrapped so ORDER BY + LIMIT apply to the whole set
    SELECT json_agg(
        json_build_object(
            'type',       row_data.txn_type,
            'icon',       row_data.txn_icon,
            'ref_id',     row_data.ref_id,
            'party_name', row_data.party_name,
            'amount',     row_data.amount,
            'txn_date',   row_data.txn_date
        )
        ORDER BY row_data.txn_date DESC, row_data.ref_id DESC
    )
    INTO v_result
    FROM (
        SELECT
            'Sale'                                    AS txn_type,
            'sale'                                    AS txn_icon,
            si.sales_invoice_id                       AS ref_id,
            p.party_name                              AS party_name,
            si.total_amount                           AS amount,
            TO_CHAR(si.invoice_date, 'YYYY-MM-DD')   AS txn_date
        FROM salesinvoices si
        JOIN parties p ON p.party_id = si.customer_id

        UNION ALL

        SELECT
            'Purchase',
            'purchase',
            pi.purchase_invoice_id,
            p.party_name,
            pi.total_amount,
            TO_CHAR(pi.invoice_date, 'YYYY-MM-DD')
        FROM purchaseinvoices pi
        JOIN parties p ON p.party_id = pi.vendor_id

        UNION ALL

        SELECT
            'Receipt',
            'receipt',
            r.receipt_id,
            p.party_name,
            r.amount,
            TO_CHAR(r.receipt_date, 'YYYY-MM-DD')
        FROM receipts r
        JOIN parties p ON p.party_id = r.party_id

        UNION ALL

        SELECT
            'Payment',
            'payment',
            pay.payment_id,
            p.party_name,
            pay.amount,
            TO_CHAR(pay.payment_date, 'YYYY-MM-DD')
        FROM payments pay
        JOIN parties p ON p.party_id = pay.party_id

        ORDER BY txn_date DESC, ref_id DESC
        LIMIT p_limit
    ) row_data;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_recent_transactions(p_limit integer) OWNER TO postgres;
