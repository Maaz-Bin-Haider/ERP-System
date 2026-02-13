# Account Report Functions - Complete Documentation

**Category:** Account Report Functions
**Total Functions:** 2

---


## 📊 ACCOUNT REPORT FUNCTIONS

**Total Functions:** 2

---

### Function 1: `detailed_ledger()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.detailed_ledger(p_party_name text, p_start_date date, p_end_date date) RETURNS TABLE(entry_date date, journal_id bigint, description text, party_name text, account_type text, debit numeric, credit numeric, running_balance numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH party_ledger AS (
        SELECT 
            je.entry_date AS entry_date,
            je.journal_id AS journal_id,
            je.description::TEXT AS description,
            p.party_name::TEXT AS party_name,                
            a.account_name::TEXT AS account_name,               
            jl.debit AS debit,
            jl.credit AS credit,
            (jl.debit - jl.credit) AS amount
        FROM JournalLines jl
        JOIN JournalEntries je ON jl.journal_id = je.journal_id
        JOIN ChartOfAccounts a ON jl.account_id = a.account_id
        LEFT JOIN Parties p ON jl.party_id = p.party_id   
        WHERE 
            p.party_name = p_party_name
            AND je.entry_date BETWEEN p_start_date AND p_end_date
    )
    SELECT 
        pl.entry_date,
        pl.journal_id,
        pl.description,
        pl.party_name,
        pl.account_name AS account_type,
        pl.debit,
        pl.credit,
        SUM(pl.amount) OVER (ORDER BY pl.entry_date, pl.journal_id ROWS UNBOUNDED PRECEDING) AS running_balance
    FROM party_ledger pl
    ORDER BY pl.entry_date, pl.journal_id;
END;
$$;
```

#### Parameters:
- `p_party_name text`
- `p_start_date date`
- `p_end_date date`

#### Returns:
`TABLE(entry_date date, journal_id bigint, description text, party_name text, account_type text, debit numeric, credit numeric, running_balance numeric)`

#### Purpose:
Detailed Ledger - Performs specialized database operation.

#### Example SQL Call:

```sql
SELECT detailed_ledger(..., ..., ...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 2: `get_cash_ledger_with_party()`

#### Complete SQL Code:

```sql
CREATE OR REPLACE FUNCTION public.get_cash_ledger_with_party(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
) RETURNS TABLE (
    entry_date DATE,
    journal_id BIGINT,
    party_name VARCHAR(150),
    description TEXT,
    debit NUMERIC(14,4),
    credit NUMERIC(14,4),
    balance NUMERIC(14,4)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cash_account_id BIGINT;
    v_opening_balance NUMERIC(14,4) := 0;
BEGIN
    -- Get Cash account ID
    SELECT account_id INTO v_cash_account_id
    FROM ChartOfAccounts
    WHERE account_name = 'Cash'
    LIMIT 1;

    IF v_cash_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found in Chart of Accounts';
    END IF;

    -- Set default dates if not provided
    p_start_date := COALESCE(p_start_date, '1900-01-01'::DATE);
    p_end_date := COALESCE(p_end_date, CURRENT_DATE);

    -- Calculate opening balance
    SELECT COALESCE(SUM(jl.debit) - SUM(jl.credit), 0)
    INTO v_opening_balance
    FROM JournalLines jl
    JOIN JournalEntries je ON jl.journal_id = je.journal_id
    WHERE jl.account_id = v_cash_account_id
      AND je.entry_date < p_start_date;

    -- Return opening balance if there are prior transactions
    IF v_opening_balance <> 0 THEN
        RETURN QUERY
        SELECT 
            p_start_date AS entry_date,
            NULL::BIGINT AS journal_id,
            NULL::VARCHAR(150) AS party_name,
            'Opening Balance'::TEXT AS description,
            CASE WHEN v_opening_balance > 0 THEN v_opening_balance ELSE 0 END AS debit,
            CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END AS credit,
            v_opening_balance AS balance;
    END IF;

    -- Return all cash transactions with party information
    RETURN QUERY
    WITH cash_transactions AS (
        SELECT 
            je.entry_date,
            je.journal_id,
            -- Get party name from the OTHER journal line in the same journal entry
            (SELECT p.party_name 
             FROM JournalLines jl2
             LEFT JOIN Parties p ON jl2.party_id = p.party_id
             WHERE jl2.journal_id = je.journal_id 
               AND jl2.account_id != v_cash_account_id
               AND jl2.party_id IS NOT NULL
             LIMIT 1) AS party_name,
            je.description,
            jl.debit,
            jl.credit,
            (jl.debit - jl.credit) AS net_amount
        FROM JournalLines jl
        JOIN JournalEntries je ON jl.journal_id = je.journal_id
        WHERE jl.account_id = v_cash_account_id
          AND je.entry_date >= p_start_date
          AND je.entry_date <= p_end_date
        ORDER BY je.entry_date, je.journal_id
    )
    SELECT 
        ct.entry_date,
        ct.journal_id,
        ct.party_name,
        ct.description,
        ct.debit,
        ct.credit,
        v_opening_balance + SUM(ct.net_amount) OVER (ORDER BY ct.entry_date, ct.journal_id) AS balance
    FROM cash_transactions ct;

END;
$$;
```

#### Parameters:
- `p_start_date DATE DEFAULT NULL`
- `p_end_date DATE DEFAULT NULL`

#### Returns:
`TABLE (
    entry_date DATE,
    journal_id BIGINT,
    party_name VARCHAR(150),
    description TEXT,
    debit NUMERIC(14,4),
    credit NUMERIC(14,4),
    balance NUMERIC(14,4)
)`

#### Purpose:
Get Cash Ledger With Party - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_cash_ledger_with_party(..., ...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

