--
-- ============================================================
-- FUNCTION: fn_dash_sales_last7days()
-- ============================================================
--

CREATE FUNCTION public.fn_dash_sales_last7days() RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'date',    TO_CHAR(d.day, 'YYYY-MM-DD'),
            'label',   TO_CHAR(d.day, 'Mon DD'),
            'revenue', COALESCE(s.revenue, 0),
            'profit',  COALESCE(s.profit,  0)
        )
        ORDER BY d.day
    )
    INTO v_result
    FROM (
        SELECT gs::date AS day
        FROM generate_series(
            CURRENT_DATE - INTERVAL '6 days',
            CURRENT_DATE,
            '1 day'::interval
        ) gs
    ) d
    LEFT JOIN (
        SELECT
            si.invoice_date                                   AS sale_date,
            SUM(si.total_amount)                              AS revenue,
            COALESCE(SUM(su.sold_price - pi2.unit_price), 0) AS profit
        FROM salesinvoices si
        LEFT JOIN salesitems    sitem  ON sitem.sales_invoice_id  = si.sales_invoice_id
        LEFT JOIN soldunits     su     ON su.sales_item_id        = sitem.sales_item_id
        LEFT JOIN purchaseunits punit  ON punit.unit_id           = su.unit_id
        LEFT JOIN purchaseitems pi2    ON pi2.purchase_item_id    = punit.purchase_item_id
        WHERE si.invoice_date >= CURRENT_DATE - INTERVAL '6 days'
        GROUP BY si.invoice_date
    ) s ON s.sale_date = d.day;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_sales_last7days() OWNER TO postgres;
