--
-- ============================================================
-- FUNCTION: fn_dash_low_stock_items(integer)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_low_stock_items(p_threshold integer DEFAULT 5) RETURNS json
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
            'sale_price',     sale_price
        )
        ORDER BY units_in_stock ASC
    )
    INTO v_result
    FROM vw_dash_stock_overview
    WHERE units_in_stock < p_threshold;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_low_stock_items(p_threshold integer) OWNER TO postgres;
