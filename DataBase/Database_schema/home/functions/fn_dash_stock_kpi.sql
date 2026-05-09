--
-- ============================================================
-- FUNCTION: fn_dash_stock_kpi()
-- ============================================================
--

CREATE FUNCTION public.fn_dash_stock_kpi() RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'total_units',     COALESCE(SUM(units_in_stock), 0),
        'low_stock_count', COUNT(*) FILTER (WHERE units_in_stock > 0 AND units_in_stock < 5),
        'out_of_stock',    COUNT(*) FILTER (WHERE units_in_stock = 0),
        'total_items',     COUNT(*)
    )
    INTO v_result
    FROM vw_dash_stock_overview;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_stock_kpi() OWNER TO postgres;
