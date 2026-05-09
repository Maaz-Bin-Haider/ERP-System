--
-- ============================================================
-- FUNCTION: monthly_income_statement(date, date, numeric, numeric)
-- ============================================================
--

CREATE FUNCTION public.monthly_income_statement(p_from_date date, p_to_date date, p_sales_revenue numeric, p_cogs numeric) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_gross_profit      NUMERIC(14,2) := 0;
    v_expenses_json     JSON;
    v_total_expenses    NUMERIC(14,2) := 0;
    v_net_income        NUMERIC(14,2) := 0;
BEGIN

    v_gross_profit := p_sales_revenue - p_cogs;

    -- ── Operating Expenses from journal lines in date range ───────────────────
    -- Explicitly exclude 'Cost of Goods Sold' (it is an Expense-type account
    -- but is already accounted for via p_cogs above).
    WITH exp AS (
        SELECT
            coa.account_name                   AS category,
            COALESCE(SUM(jl.debit), 0)         AS amount
        FROM   journallines    jl
        JOIN   journalentries  je  ON je.journal_id  = jl.journal_id
        JOIN   chartofaccounts coa ON coa.account_id = jl.account_id
        WHERE  coa.account_type ILIKE '%expense%'
          AND  coa.account_name NOT ILIKE '%cost of goods%'   -- exclude COGS (supplied manually)
          AND  coa.account_name NOT ILIKE '%profit%'          -- exclude Profit A/C (not an operating expense)
          AND  jl.debit > 0
          AND  je.entry_date BETWEEN p_from_date AND p_to_date
        GROUP  BY coa.account_name
    )
    SELECT
        COALESCE(json_agg(
            json_build_object('category', category, 'amount', ROUND(amount, 2))
            ORDER BY category
        ), '[]'::json),
        COALESCE(SUM(amount), 0)
    INTO v_expenses_json, v_total_expenses
    FROM exp;

    v_net_income := v_gross_profit - v_total_expenses;

    RETURN json_build_object(
        'from_date',        p_from_date,
        'to_date',          p_to_date,
        'sales_revenue',    ROUND(p_sales_revenue, 2),
        'cogs',             ROUND(p_cogs, 2),
        'gross_profit',     ROUND(v_gross_profit, 2),
        'expenses',         v_expenses_json,
        'total_expenses',   ROUND(v_total_expenses, 2),
        'net_income',       ROUND(v_net_income, 2)
    );
END;
$$;


ALTER FUNCTION public.monthly_income_statement(p_from_date date, p_to_date date, p_sales_revenue numeric, p_cogs numeric) OWNER TO postgres;
