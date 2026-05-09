--
-- ============================================================
-- FUNCTION: update_party_from_json(bigint, jsonb)
-- ============================================================
--

CREATE FUNCTION public.update_party_from_json(p_id bigint, party_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    old_opening       NUMERIC(14,2);
    old_balance_type  VARCHAR(10);
    old_party_type    VARCHAR(20);
    old_party_name    VARCHAR(150);
    new_opening       NUMERIC(14,2);
    new_balance_type  VARCHAR(10);
    new_party_type    VARCHAR(20);
    new_party_name    VARCHAR(150);
    cap_acc           BIGINT;
    j_id              BIGINT;
    debit_acc         BIGINT;
    credit_acc        BIGINT;
    v_expense_account_id BIGINT;
BEGIN
    -- Fetch existing data
    SELECT opening_balance, balance_type, party_type, party_name
    INTO old_opening, old_balance_type, old_party_type, old_party_name
    FROM Parties WHERE party_id = p_id;

    -- Parse new values
    new_opening      := COALESCE((party_data->>'opening_balance')::NUMERIC, old_opening);
    new_balance_type := COALESCE(party_data->>'balance_type', old_balance_type);
    new_party_type   := COALESCE(party_data->>'party_type', old_party_type);
    new_party_name   := COALESCE(party_data->>'party_name', old_party_name);

    -- Expense party logic (unchanged)
    IF new_party_type = 'Expense' THEN
        SELECT ap_account_id INTO v_expense_account_id FROM Parties WHERE party_id = p_id;
        IF v_expense_account_id IS NOT NULL THEN
            UPDATE ChartOfAccounts SET account_name = new_party_name
            WHERE account_id = v_expense_account_id;
        ELSE
            INSERT INTO ChartOfAccounts(account_code, account_name, account_type, parent_account, date_created)
            VALUES (
                CONCAT('EXP-', LPAD((SELECT COUNT(*)+1 FROM ChartOfAccounts WHERE account_type='Expense')::TEXT, 4, '0')),
                new_party_name, 'Expense',
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Expenses' LIMIT 1),
                CURRENT_TIMESTAMP
            ) RETURNING account_id INTO v_expense_account_id;
        END IF;
    END IF;

    -- Update party — now includes created_by (last modifier)
    UPDATE Parties
    SET
        party_name      = new_party_name,
        party_type      = new_party_type,
        contact_info    = COALESCE(party_data->>'contact_info', contact_info),
        address         = COALESCE(party_data->>'address', address),
        opening_balance = new_opening,
        balance_type    = new_balance_type,
        ar_account_id   = CASE
                            WHEN new_party_type IN ('Customer','Both')
                            THEN (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Receivable' LIMIT 1)
                            ELSE NULL END,
        ap_account_id   = CASE
                            WHEN new_party_type IN ('Vendor','Both')
                                THEN (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Payable' LIMIT 1)
                            WHEN new_party_type = 'Expense'
                                THEN v_expense_account_id
                            ELSE NULL END,
        -- Update last modifier if provided
        created_by      = CASE
                            WHEN NULLIF(party_data->>'created_by_id', '') IS NOT NULL
                            THEN (party_data->>'created_by_id')::INTEGER
                            ELSE created_by
                          END
    WHERE party_id = p_id;

    -- Sync journal description if party name changed (unchanged)
    IF new_party_name IS DISTINCT FROM old_party_name THEN
        UPDATE JournalEntries
        SET description = 'Opening Balance for ' || new_party_name
        WHERE journal_id IN (
            SELECT DISTINCT jl.journal_id FROM JournalLines jl WHERE jl.party_id = p_id
        )
        AND description ILIKE 'Opening Balance for%';
    END IF;

    -- Handle opening balance changes (unchanged logic)
    IF new_opening IS DISTINCT FROM old_opening
       OR new_balance_type IS DISTINCT FROM old_balance_type
       OR new_party_type IS DISTINCT FROM old_party_type THEN

        DELETE FROM JournalEntries je
        WHERE je.description ILIKE 'Opening Balance for%'
          AND je.journal_id IN (
              SELECT jl.journal_id FROM JournalLines jl WHERE jl.party_id = p_id
          );

        IF new_opening <> 0 THEN
            SELECT account_id INTO cap_acc FROM ChartOfAccounts WHERE account_name = 'Capital';

            INSERT INTO JournalEntries(entry_date, description)
            VALUES (CURRENT_DATE, 'Opening Balance for ' || new_party_name)
            RETURNING journal_id INTO j_id;

            IF new_balance_type = 'Debit' THEN
                SELECT ar_account_id INTO debit_acc FROM Parties WHERE party_id = p_id;
                credit_acc := cap_acc;
            ELSE
                SELECT ap_account_id INTO credit_acc FROM Parties WHERE party_id = p_id;
                debit_acc := cap_acc;
            END IF;

            INSERT INTO JournalLines(journal_id, account_id, party_id, debit, credit)
            VALUES (j_id, debit_acc, p_id, new_opening, 0);
            INSERT INTO JournalLines(journal_id, account_id, party_id, debit, credit)
            VALUES (j_id, credit_acc, p_id, 0, new_opening);
        END IF;
    END IF;
END;
$$;


ALTER FUNCTION public.update_party_from_json(p_id bigint, party_data jsonb) OWNER TO postgres;
