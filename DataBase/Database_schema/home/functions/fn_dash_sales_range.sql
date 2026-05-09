--
-- ============================================================
-- FUNCTION: fn_dash_sales_range(date, date)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_sales_range(p_from date, p_to date) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'date',    TO_CHAR(agg.invoice_date, 'YYYY-MM-DD'),
            'label',   TO_CHAR(agg.invoice_date, 'Mon DD'),
            'revenue', agg.revenue,
            'profit',  agg.profit
        )
        ORDER BY agg.invoice_date
    )
    INTO v_result
    FROM (
        SELECT
            si.invoice_date,
            SUM(si.total_amount)                              AS revenue,
            COALESCE(SUM(su.sold_price - pi2.unit_price), 0) AS profit
        FROM salesinvoices si
        LEFT JOIN salesitems    sitem  ON sitem.sales_invoice_id  = si.sales_invoice_id
        LEFT JOIN soldunits     su     ON su.sales_item_id        = sitem.sales_item_id
        LEFT JOIN purchaseunits punit  ON punit.unit_id           = su.unit_id
        LEFT JOIN purchaseitems pi2    ON pi2.purchase_item_id    = punit.purchase_item_id
        WHERE si.invoice_date BETWEEN p_from AND p_to
        GROUP BY si.invoice_date
    ) agg;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_sales_range(p_from date, p_to date) OWNER TO postgres;
