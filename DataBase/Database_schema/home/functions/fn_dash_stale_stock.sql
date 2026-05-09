--
-- ============================================================
-- FUNCTION: fn_dash_stale_stock(integer)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_stale_stock(p_days integer DEFAULT 30) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'item_id',        item_id,
            'item_name',      item_name,
            'category',       COALESCE(category, 'N/A'),
            'units_in_stock', units_in_stock,
            'last_sold_date', TO_CHAR(last_sold_date, 'YYYY-MM-DD'),
            'days_stale',     CASE
                                  WHEN last_sold_date IS NULL THEN NULL
                                  ELSE (CURRENT_DATE - last_sold_date)
                              END
        )
        ORDER BY last_sold_date ASC NULLS FIRST
    )
    INTO v_result
    FROM vw_dash_stock_overview
    WHERE
        units_in_stock > 0
        AND (
            last_sold_date IS NULL
            OR last_sold_date < CURRENT_DATE - (p_days || ' days')::INTERVAL
        );

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_stale_stock(p_days integer) OWNER TO postgres;
