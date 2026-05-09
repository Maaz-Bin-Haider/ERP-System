--
-- ============================================================
-- FUNCTION: fn_dash_top_vendors(integer, date, date)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_top_vendors(p_limit integer DEFAULT 5, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
    v_from   DATE := COALESCE(p_from, '2000-01-01'::date);
    v_to     DATE := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    SELECT json_agg(
        json_build_object(
            'party_id',       party_id,
            'party_name',     party_name,
            'contact',        contact,
            'invoice_count',  invoice_count,
            'total_purchased',total_purchased,
            'last_purchase',  last_purchase
        )
        ORDER BY total_purchased DESC
    )
    INTO v_result
    FROM (
        SELECT
            p.party_id,
            p.party_name,
            COALESCE(p.contact_info, 'N/A')              AS contact,
            COUNT(DISTINCT pi.purchase_invoice_id)        AS invoice_count,
            COALESCE(SUM(pi.total_amount), 0)             AS total_purchased,
            TO_CHAR(MAX(pi.invoice_date), 'YYYY-MM-DD')  AS last_purchase
        FROM parties p
        JOIN purchaseinvoices pi ON pi.vendor_id = p.party_id
        WHERE pi.invoice_date BETWEEN v_from AND v_to
        GROUP BY p.party_id, p.party_name, p.contact_info
        ORDER BY SUM(pi.total_amount) DESC
        LIMIT p_limit
    ) subq;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_top_vendors(p_limit integer, p_from date, p_to date) OWNER TO postgres;
