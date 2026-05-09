--
-- ============================================================
-- FUNCTION: fn_dash_top_expense_descriptions(integer, date, date)
-- ============================================================
--

CREATE FUNCTION public.fn_dash_top_expense_descriptions(p_limit integer DEFAULT 5, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
    v_from   DATE := COALESCE(p_from, DATE_TRUNC('month', CURRENT_DATE)::DATE);
    v_to     DATE := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    SELECT json_agg(
        json_build_object(
            'description', description,
            'category',    expense_category,
            'total',       desc_total,
            'count',       desc_count
        )
        ORDER BY desc_total DESC
    )
    INTO v_result
    FROM (
        SELECT
            COALESCE(NULLIF(TRIM(expense_note), ''), 'No Description') AS description,
            expense_category,
            COALESCE(SUM(amount), 0) AS desc_total,
            COUNT(*)                  AS desc_count
        FROM vw_dash_expenses
        WHERE entry_date BETWEEN v_from AND v_to
          AND expense_note IS NOT NULL
          AND TRIM(expense_note) <> ''
        GROUP BY expense_note, expense_category
        ORDER BY SUM(amount) DESC
        LIMIT p_limit
    ) descs;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_top_expense_descriptions(p_limit integer, p_from date, p_to date) OWNER TO postgres;
