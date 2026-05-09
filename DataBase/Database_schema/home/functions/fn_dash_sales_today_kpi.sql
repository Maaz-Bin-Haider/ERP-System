--
-- ============================================================
-- FUNCTION: fn_dash_sales_today_kpi()
-- ============================================================
--

CREATE FUNCTION public.fn_dash_sales_today_kpi() RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'sales_today',   COALESCE(SUM(si.total_amount), 0),
        'invoice_count', COUNT(DISTINCT si.sales_invoice_id),
        'profit_today',  COALESCE(SUM(su.sold_price - pi2.unit_price), 0)
    )
    INTO v_result
    FROM salesinvoices si
    LEFT JOIN salesitems    sitem  ON sitem.sales_invoice_id  = si.sales_invoice_id
    LEFT JOIN soldunits     su     ON su.sales_item_id        = sitem.sales_item_id
    LEFT JOIN purchaseunits punit  ON punit.unit_id           = su.unit_id
    LEFT JOIN purchaseitems pi2    ON pi2.purchase_item_id    = punit.purchase_item_id
    WHERE si.invoice_date = CURRENT_DATE;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_sales_today_kpi() OWNER TO postgres;
