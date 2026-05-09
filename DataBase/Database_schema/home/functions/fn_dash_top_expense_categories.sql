--
-- ============================================================
-- FUNCTION: fn_dash_top_expense_categories(integer, date, date)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_top_expense_categories(p_limit integer DEFAULT 5, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
    v_from   DATE := COALESCE(p_from, DATE_TRUNC('month', CURRENT_DATE)::DATE);
    v_to     DATE := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    SELECT json_agg(
        json_build_object(
            'category', expense_category,
            'total',    cat_total,
            'count',    cat_count
        )
        ORDER BY cat_total DESC
    )
    INTO v_result
    FROM (
        SELECT
            expense_category,
            COALESCE(SUM(amount), 0) AS cat_total,
            COUNT(*)                  AS cat_count
        FROM vw_dash_expenses
        WHERE entry_date BETWEEN v_from AND v_to
        GROUP BY expense_category
        ORDER BY SUM(amount) DESC
        LIMIT p_limit
    ) cats;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_top_expense_categories(p_limit integer, p_from date, p_to date) OWNER TO postgres;
