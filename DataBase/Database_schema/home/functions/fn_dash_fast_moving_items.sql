--
-- ============================================================
-- FUNCTION: fn_dash_fast_moving_items(integer, integer)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_fast_moving_items(p_days integer DEFAULT 30, p_limit integer DEFAULT 10) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'item_id',    item_id,
            'item_name',  item_name,
            'category',   category,
            'units_sold', units_sold,
            'revenue',    revenue
        )
        ORDER BY units_sold DESC
    )
    INTO v_result
    FROM (
        SELECT
            i.item_id,
            i.item_name,
            COALESCE(i.category, 'N/A')        AS category,
            COUNT(su.sold_unit_id)              AS units_sold,
            COALESCE(SUM(su.sold_price), 0)    AS revenue
        FROM items i
        JOIN salesitems    sitem  ON sitem.item_id       = i.item_id
        JOIN soldunits     su     ON su.sales_item_id    = sitem.sales_item_id
        JOIN salesinvoices si     ON si.sales_invoice_id = sitem.sales_invoice_id
        WHERE si.invoice_date >= CURRENT_DATE - (p_days || ' days')::INTERVAL
        GROUP BY i.item_id, i.item_name, i.category
        ORDER BY COUNT(su.sold_unit_id) DESC
        LIMIT p_limit
    ) ranked;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_fast_moving_items(p_days integer, p_limit integer) OWNER TO postgres;
