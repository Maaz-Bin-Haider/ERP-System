--
-- ============================================================
-- FUNCTION: monthly_company_position(date)
-- ============================================================
--

CREATE FUNCTION public.monthly_company_position(p_as_of_date date DEFAULT CURRENT_DATE) RETURNS json
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_stock_worth       NUMERIC(14,2) := 0;
    v_cash_balance      NUMERIC(14,2) := 0;
    v_receivables       JSON;
    v_payables          JSON;
    v_total_receivable  NUMERIC(14,2) := 0;
    v_total_payable     NUMERIC(14,2) := 0;
    v_cash_account_id   BIGINT;
BEGIN

    -- ── 1. Stock Worth (purchase price of all in-stock units) ─────────────────
    SELECT COALESCE(SUM(pi2.unit_price), 0)
    INTO   v_stock_worth
    FROM   purchaseunits pu
    JOIN   purchaseitems pi2 ON pi2.purchase_item_id = pu.purchase_item_id
    WHERE  pu.in_stock = TRUE
      AND  NOT EXISTS (
               SELECT 1 FROM soldunits su
               WHERE su.unit_id = pu.unit_id AND su.status = 'Sold'
           )
      AND  NOT EXISTS (
               SELECT 1 FROM purchasereturnitems pri
               WHERE pri.serial_number = pu.serial_number
           );

    -- ── 2. Cash balance (all journal entries up to p_as_of_date) ─────────────
    SELECT account_id INTO v_cash_account_id
    FROM   chartofaccounts
    WHERE  account_name = 'Cash'
    LIMIT  1;

    IF v_cash_account_id IS NOT NULL THEN
        SELECT COALESCE(SUM(jl.debit) - SUM(jl.credit), 0)
        INTO   v_cash_balance
        FROM   journallines jl
        JOIN   journalentries je ON je.journal_id = jl.journal_id
        WHERE  jl.account_id = v_cash_account_id
          AND  je.entry_date <= p_as_of_date;
    END IF;

    -- ── 3. Party Receivables (customers who owe us, up to p_as_of_date) ───────
    WITH party_bal AS (
        SELECT
            p.party_name,
            p.party_type,
            COALESCE(SUM(jl.debit),0) - COALESCE(SUM(jl.credit),0) AS balance
        FROM   parties p
        JOIN   journallines jl    ON jl.party_id   = p.party_id
        JOIN   journalentries je  ON je.journal_id = jl.journal_id
        WHERE  je.entry_date <= p_as_of_date
          AND  p.party_type NOT ILIKE '%expense%'
        GROUP  BY p.party_id, p.party_name, p.party_type
    )
    SELECT
        COALESCE(json_agg(
            json_build_object('name', party_name, 'balance', ROUND(balance,2))
            ORDER BY party_name
        ), '[]'::json),
        COALESCE(SUM(balance), 0)
    INTO v_receivables, v_total_receivable
    FROM party_bal
    WHERE balance > 0;

    -- ── 4. Party Payables (we owe them, up to p_as_of_date) ──────────────────
    WITH party_bal2 AS (
        SELECT
            p.party_name,
            p.party_type,
            COALESCE(SUM(jl.debit),0) - COALESCE(SUM(jl.credit),0) AS balance
        FROM   parties p
        JOIN   journallines jl    ON jl.party_id   = p.party_id
        JOIN   journalentries je  ON je.journal_id = jl.journal_id
        WHERE  je.entry_date <= p_as_of_date
          AND  p.party_type NOT ILIKE '%expense%'
        GROUP  BY p.party_id, p.party_name, p.party_type
    )
    SELECT
        COALESCE(json_agg(
            json_build_object('name', party_name, 'balance', ROUND(ABS(balance),2))
            ORDER BY party_name
        ), '[]'::json),
        COALESCE(SUM(ABS(balance)), 0)
    INTO v_payables, v_total_payable
    FROM party_bal2
    WHERE balance < 0;

    -- ── 5. Build result JSON ──────────────────────────────────────────────────
    RETURN json_build_object(
        'as_of_date',       p_as_of_date,
        'stock_worth',      ROUND(v_stock_worth, 2),
        'cash_balance',     ROUND(v_cash_balance, 2),
        'receivables',      v_receivables,
        'total_party_receivable', ROUND(v_total_receivable, 2),
        'payables',         v_payables,
        'total_payable',    ROUND(v_total_payable, 2)
    );
END;
$$;


ALTER FUNCTION public.monthly_company_position(p_as_of_date date) OWNER TO postgres;
