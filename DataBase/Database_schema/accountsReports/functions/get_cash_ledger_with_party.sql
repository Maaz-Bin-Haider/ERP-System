--
-- ============================================================
-- FUNCTION: get_cash_ledger_with_party(date, date)
-- ============================================================
--

CREATE FUNCTION public.get_cash_ledger_with_party(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS TABLE(entry_date date, journal_id bigint, party_name character varying, description text, debit numeric, credit numeric, balance numeric, created_by text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_cash_account_id BIGINT;
    v_opening_balance NUMERIC(14,4) := 0;
BEGIN
    SELECT account_id INTO v_cash_account_id
    FROM ChartOfAccounts WHERE account_name = 'Cash' LIMIT 1;

    IF v_cash_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found in Chart of Accounts';
    END IF;

    p_start_date := COALESCE(p_start_date, '1900-01-01'::DATE);
    p_end_date   := COALESCE(p_end_date, CURRENT_DATE);

    -- Opening balance
    SELECT COALESCE(SUM(jl.debit) - SUM(jl.credit), 0)
    INTO v_opening_balance
    FROM JournalLines jl
    JOIN JournalEntries je ON jl.journal_id = je.journal_id
    WHERE jl.account_id = v_cash_account_id
      AND je.entry_date < p_start_date;

    -- Opening balance row (no author)
    IF v_opening_balance <> 0 THEN
        RETURN QUERY
        SELECT
            p_start_date                                                AS entry_date,
            NULL::BIGINT                                                AS journal_id,
            NULL::VARCHAR(150)                                          AS party_name,
            'Opening Balance'::TEXT                                     AS description,
            CASE WHEN v_opening_balance > 0 THEN v_opening_balance ELSE 0 END AS debit,
            CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END AS credit,
            v_opening_balance                                           AS balance,
            NULL::TEXT                                                  AS created_by;
    END IF;

    -- Main cash transactions with running balance and author
    RETURN QUERY
    WITH cash_transactions AS (
        SELECT
            je.entry_date,
            je.journal_id,
            (SELECT p.party_name
             FROM JournalLines jl2
             LEFT JOIN Parties p ON jl2.party_id = p.party_id
             WHERE jl2.journal_id = je.journal_id
               AND jl2.account_id != v_cash_account_id
               AND jl2.party_id IS NOT NULL
             LIMIT 1)                                                   AS party_name,
            je.description,
            jl.debit,
            jl.credit,
            (jl.debit - jl.credit)                                      AS net_amount
        FROM JournalLines jl
        JOIN JournalEntries je ON jl.journal_id = je.journal_id
        WHERE jl.account_id = v_cash_account_id
          AND je.entry_date >= p_start_date
          AND je.entry_date <= p_end_date
        ORDER BY je.entry_date, je.journal_id
    ),
    -- Resolve author username from whichever document owns this journal
    journal_author AS (
        SELECT py.journal_id, u.username::TEXT
        FROM payments py LEFT JOIN auth_user u ON u.id = py.created_by
        WHERE py.journal_id IS NOT NULL
        UNION ALL
        SELECT r.journal_id, u.username::TEXT
        FROM receipts r LEFT JOIN auth_user u ON u.id = r.created_by
        WHERE r.journal_id IS NOT NULL
        UNION ALL
        SELECT si.journal_id, u.username::TEXT
        FROM salesinvoices si LEFT JOIN auth_user u ON u.id = si.created_by
        WHERE si.journal_id IS NOT NULL
        UNION ALL
        SELECT pi.journal_id, u.username::TEXT
        FROM purchaseinvoices pi LEFT JOIN auth_user u ON u.id = pi.created_by
        WHERE pi.journal_id IS NOT NULL
        UNION ALL
        SELECT sr.journal_id, u.username::TEXT
        FROM salesreturns sr LEFT JOIN auth_user u ON u.id = sr.created_by
        WHERE sr.journal_id IS NOT NULL
        UNION ALL
        SELECT pr.journal_id, u.username::TEXT
        FROM purchasereturns pr LEFT JOIN auth_user u ON u.id = pr.created_by
        WHERE pr.journal_id IS NOT NULL
    )
    SELECT
        ct.entry_date,
        ct.journal_id,
        ct.party_name,
        ct.description,
        ct.debit,
        ct.credit,
        v_opening_balance + SUM(ct.net_amount) OVER (
            ORDER BY ct.entry_date, ct.journal_id
        )                                                               AS balance,
        COALESCE(ja.username::TEXT, 'N/A')                              AS created_by
    FROM cash_transactions ct
    LEFT JOIN journal_author ja ON ja.journal_id = ct.journal_id;

END;
$$;


ALTER FUNCTION public.get_cash_ledger_with_party(p_start_date date, p_end_date date) OWNER TO postgres;
