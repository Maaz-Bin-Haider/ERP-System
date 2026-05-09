--
-- ============================================================
-- FUNCTION: fn_dash_expense_kpi()
-- ============================================================
--

CREATE FUNCTION public.fn_dash_expense_kpi() RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'today',      COALESCE(SUM(amount) FILTER (
                          WHERE entry_date = CURRENT_DATE
                      ), 0),
        'this_month', COALESCE(SUM(amount) FILTER (
                          WHERE DATE_TRUNC('month', entry_date) = DATE_TRUNC('month', CURRENT_DATE)
                      ), 0),
        'this_year',  COALESCE(SUM(amount) FILTER (
                          WHERE DATE_PART('year', entry_date) = DATE_PART('year', CURRENT_DATE)
                      ), 0)
    )
    INTO v_result
    FROM vw_dash_expenses;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;


ALTER FUNCTION public.fn_dash_expense_kpi() OWNER TO postgres;
