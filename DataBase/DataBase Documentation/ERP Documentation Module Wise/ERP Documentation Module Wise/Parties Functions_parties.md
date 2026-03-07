# Party Functions - Complete Documentation

**Category:** Party Functions
**Total Functions:** 6

---


## 👥 PARTY FUNCTIONS

**Total Functions:** 6

---

### Function 1: `add_party_from_json()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.add_party_from_json(party_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_type TEXT := TRIM(BOTH '"' FROM party_data->>'party_type');
    v_party_name TEXT := TRIM(BOTH '"' FROM party_data->>'party_name');
    v_opening_balance NUMERIC := COALESCE((party_data->>'opening_balance')::NUMERIC, 0);
    v_balance_type TEXT := COALESCE(party_data->>'balance_type', 'Debit');
    v_expense_account_id BIGINT;
BEGIN
    -- Handle Expense-type Party (auto-create its expense COA account)
    IF v_party_type = 'Expense' THEN
        -- Check if Expense account already exists in COA
        SELECT account_id INTO v_expense_account_id
        FROM ChartOfAccounts
        WHERE account_name ILIKE v_party_name
          AND account_type = 'Expense'
        LIMIT 1;

        -- Create a new Expense account if not found
        IF v_expense_account_id IS NULL THEN
            INSERT INTO ChartOfAccounts (
                account_code, account_name, account_type, parent_account, date_created
            )
            VALUES (
                CONCAT('EXP-', LPAD((SELECT COUNT(*) + 1 FROM ChartOfAccounts WHERE account_type='Expense')::TEXT, 4, '0')),
                v_party_name,
                'Expense',
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Expenses' LIMIT 1),
                CURRENT_TIMESTAMP
            )
            RETURNING account_id INTO v_expense_account_id;
        END IF;
    END IF;

    -- Insert into Parties table
    INSERT INTO Parties (
        party_name, party_type, contact_info, address,
        opening_balance, balance_type,
        ar_account_id, ap_account_id
    )
    VALUES (
        v_party_name,
        v_party_type,
        party_data->>'contact_info',
        party_data->>'address',
        v_opening_balance,
        v_balance_type,
        CASE 
            WHEN v_party_type IN ('Customer','Both','Expense') THEN 
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Receivable' LIMIT 1)
            ELSE NULL 
        END,
        CASE 
            WHEN v_party_type IN ('Vendor','Both') THEN 
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Payable' LIMIT 1)
            WHEN v_party_type = 'Expense' THEN 
                v_expense_account_id
            ELSE NULL 
        END
    );
END;
$$;
```

#### Parameters:
- `party_data jsonb`

#### Returns:
`void`

#### Purpose:
Add Party From Json - Performs specialized database operation.

#### Example SQL Call:

```sql
SELECT add_party_from_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 2: `update_party_from_json()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.update_party_from_json(p_id bigint, party_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    -- Old party data
    old_opening NUMERIC(14,2);
    old_balance_type VARCHAR(10);
    old_party_type VARCHAR(20);
    old_party_name VARCHAR(150);

    -- New values
    new_opening NUMERIC(14,2);
    new_balance_type VARCHAR(10);
    new_party_type VARCHAR(20);
    new_party_name VARCHAR(150);

    -- Accounting
    cap_acc BIGINT;
    j_id BIGINT;
    debit_acc BIGINT;
    credit_acc BIGINT;
    v_expense_account_id BIGINT;
BEGIN
    -- ============= FETCH EXISTING DATA =============
    SELECT opening_balance, balance_type, party_type, party_name
    INTO old_opening, old_balance_type, old_party_type, old_party_name
    FROM Parties
    WHERE party_id = p_id;

    -- ============= PARSE NEW VALUES =============
    new_opening := COALESCE((party_data->>'opening_balance')::NUMERIC, old_opening);
    new_balance_type := COALESCE(party_data->>'balance_type', old_balance_type);
    new_party_type := COALESCE(party_data->>'party_type', old_party_type);
    new_party_name := COALESCE(party_data->>'party_name', old_party_name);

    -- ============= EXPENSE PARTY LOGIC =============
    IF new_party_type = 'Expense' THEN
        -- Try to fetch the linked expense account (stored in ap_account_id)
        SELECT ap_account_id INTO v_expense_account_id
        FROM Parties WHERE party_id = p_id;

        -- If found, rename COA to match new name
        IF v_expense_account_id IS NOT NULL THEN
            UPDATE ChartOfAccounts
            SET account_name = new_party_name
            WHERE account_id = v_expense_account_id;
        ELSE
            -- Otherwise create a new Expense COA account
            INSERT INTO ChartOfAccounts (
                account_code, account_name, account_type, parent_account, date_created
            )
            VALUES (
                CONCAT('EXP-', LPAD((SELECT COUNT(*) + 1 FROM ChartOfAccounts WHERE account_type='Expense')::TEXT, 4, '0')),
                new_party_name,
                'Expense',
                (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Expenses' LIMIT 1),
                CURRENT_TIMESTAMP
            )
            RETURNING account_id INTO v_expense_account_id;
        END IF;
    END IF;

    -- ============= UPDATE PARTY DETAILS =============
    UPDATE Parties
    SET 
        party_name     = new_party_name,
        party_type     = new_party_type,
        contact_info   = COALESCE(party_data->>'contact_info', contact_info),
        address        = COALESCE(party_data->>'address', address),
        opening_balance = new_opening,
        balance_type   = new_balance_type,
        ar_account_id  = CASE 
                            WHEN new_party_type IN ('Customer','Both')
                            THEN (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Receivable' LIMIT 1)
                            ELSE NULL END,
        ap_account_id  = CASE 
                            WHEN new_party_type IN ('Vendor','Both')
                                THEN (SELECT account_id FROM ChartOfAccounts WHERE account_name ILIKE 'Accounts Payable' LIMIT 1)
                            WHEN new_party_type = 'Expense'
                                THEN v_expense_account_id
                            ELSE NULL 
                         END
    WHERE party_id = p_id;

    -- ============= SYNC JOURNAL DESCRIPTION IF PARTY NAME CHANGED =============
    IF new_party_name IS DISTINCT FROM old_party_name THEN
        UPDATE JournalEntries
        SET description = 'Opening Balance for ' || new_party_name
        WHERE journal_id IN (
            SELECT DISTINCT jl.journal_id
            FROM JournalLines jl
            WHERE jl.party_id = p_id
        )
        AND description ILIKE 'Opening Balance for%';
    END IF;

    -- ============= HANDLE OPENING BALANCE CHANGES =============
    IF new_opening IS DISTINCT FROM old_opening 
       OR new_balance_type IS DISTINCT FROM old_balance_type
       OR new_party_type IS DISTINCT FROM old_party_type THEN

        -- Delete old Opening Balance journals
        DELETE FROM JournalEntries je
        WHERE je.journal_id IN (
            SELECT jl.journal_id
            FROM JournalLines jl
            WHERE jl.party_id = p_id
        )
        AND je.description ILIKE 'Opening Balance for%';

        -- Get Owner's Capital account
        SELECT account_id INTO cap_acc 
        FROM ChartOfAccounts WHERE account_name = 'Owner''s Capital';

        IF cap_acc IS NULL THEN
            RAISE EXCEPTION 'Owner''s Capital account not found in COA';
        END IF;

        -- Recreate new Opening Balance entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (CURRENT_DATE, 'Opening Balance for ' || new_party_name)
        RETURNING journal_id INTO j_id;

        -- Customer / Both (Debit balance)
        IF new_party_type IN ('Customer','Both') AND new_balance_type = 'Debit' AND new_opening > 0 THEN
            debit_acc := (SELECT ar_account_id FROM Parties WHERE party_id = p_id);
            credit_acc := cap_acc;

            INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
            VALUES (j_id, debit_acc, p_id, new_opening);

            INSERT INTO JournalLines(journal_id, account_id, credit)
            VALUES (j_id, credit_acc, new_opening);
        END IF;

        -- Vendor / Both (Credit balance)
        IF new_party_type IN ('Vendor','Both') AND new_balance_type = 'Credit' AND new_opening > 0 THEN
            debit_acc := cap_acc;
            credit_acc := (SELECT ap_account_id FROM Parties WHERE party_id = p_id);

            INSERT INTO JournalLines(journal_id, account_id, debit)
            VALUES (j_id, debit_acc, new_opening);

            INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
            VALUES (j_id, credit_acc, p_id, new_opening);
        END IF;
    END IF;
END;
$$;
```

#### Parameters:
- `p_id bigint`
- `party_data jsonb`

#### Returns:
`void`

#### Purpose:
Update Party From Json - Updates an existing record with validation to maintain data integrity.

#### Example SQL Call:

```sql
SELECT update_party_from_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 3: `get_parties_json()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_parties_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'party_name', party_name,
                   'party_type', party_type
               )
           )
    INTO result
    FROM Parties;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;
```

#### Parameters:
- None

#### Returns:
`jsonb`

#### Purpose:
Get Parties Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_parties_json();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 4: `get_party_balances_json()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_party_balances_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'name', name,
                   'balance', balance
               )
           )
    INTO result
    FROM vw_trial_balance
    WHERE code IS NULL  -- only parties (not chart of accounts)
      AND type NOT ILIKE '%Expense%'  -- exclude expense parties if any
      AND balance <> 0;  -- optional: skip zero balances

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;
```

#### Parameters:
- None

#### Returns:
`jsonb`

#### Purpose:
Get Party Balances Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_party_balances_json();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

# `get_party_balances_json_excluding(p_exclude_names)`

## Purpose

Returns a JSON array of party balances — identical to `get_party_balances_json()` — but allows you to **exclude one or more parties by name**. Useful when certain parties (e.g. internal accounts, special vendors, write-off entries) should be hidden from a particular report or UI view.

---

## Signature

```sql
public.get_party_balances_json_excluding(
    p_exclude_names TEXT[] DEFAULT ARRAY[]::TEXT[]
)
RETURNS JSONB
```

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_exclude_names` | `TEXT[]` | `ARRAY[]::TEXT[]` | Array of party names to exclude. Pass an empty array or omit to return all parties (same as the original function). |

---

## Return Format

```json
[
  { "name": "Ali Traders", "balance": 15000.00 },
  { "name": "XYZ Suppliers", "balance": -8500.00 }
]
```

Returns `[]` (empty JSON array) if no matching rows are found.

---

## Filtering Logic

The function applies all the same filters as the base `get_party_balances_json()`:

- `code IS NULL` — only parties, not chart-of-accounts entries
- `type NOT ILIKE '%Expense%'` — excludes Expense Party types
- `balance <> 0` — skips zero-balance parties

Additionally:
- `NOT (name = ANY(p_exclude_names))` — skips any party whose name exactly matches an entry in the exclusion array

> **Note:** The name match is **case-sensitive** and must be an exact string match. Ensure the names passed match exactly as stored in the `parties` table.

---

## Usage Examples

**Exclude nothing (equivalent to original function):**
```sql
SELECT public.get_party_balances_json_excluding();
```

**Exclude a single party:**
```sql
SELECT public.get_party_balances_json_excluding(ARRAY['John Doe']);
```

**Exclude multiple parties:**
```sql
SELECT public.get_party_balances_json_excluding(ARRAY['John Doe', 'ABC Supplier', 'Internal Account']);
```

---

## Notes

- The exclusion array is optional. If not provided, the function behaves exactly like `get_party_balances_json()`.
- Balances can be positive (receivable) or negative (payable) — both are included unless filtered by name.
- To filter by balance direction, use `get_accounts_receivable_json()` or `get_accounts_payable_json()` instead.

--


# `get_accounts_payable_json()`

## Purpose

Returns a JSON array of parties **you owe money to** — i.e., parties with a **negative balance** in the trial balance view. These represent your **Accounts Payable (AP)**: amounts you are expected to pay to vendors, suppliers, or other creditors.

---

## Signature

```sql
public.get_accounts_payable_json()
RETURNS JSONB
```

---

## Parameters

None.

---

## Return Format

```json
[
  { "name": "XYZ Suppliers", "balance": 8500.00 },
  { "name": "Tech Imports Ltd", "balance": 12000.00 }
]
```

> Balances are returned as **positive absolute values** for clarity, even though they are stored as negative in the trial balance view.

Returns `[]` (empty JSON array) if no payable parties are found.

---

## Filtering Logic

| Filter | Meaning |
|---|---|
| `code IS NULL` | Only party rows, not chart-of-accounts rows |
| `type NOT ILIKE '%Expense%'` | Excludes Expense Party types |
| `balance < 0` | **Only negative balances** — you owe this party money |
| `ABS(balance)` | Converts negative to positive in the output |

> A **negative balance** in `vw_trial_balance` means the party has a net **credit** position — you owe them. This is the standard AP interpretation in double-entry bookkeeping where AP is a credit-normal account.

---

## Usage Example

```sql
SELECT public.get_accounts_payable_json();
```

**Sample output:**
```json
[
  { "name": "XYZ Suppliers", "balance": 8500.00 },
  { "name": "Tech Imports Ltd", "balance": 12000.00 }
]
```

---

## Notes

- The `balance` field in the output is always a **positive number** (using `ABS()`), representing the amount you owe — making it easier to display or sum in reports without sign confusion.
- Zero-balance parties are automatically excluded (since `balance < 0` requires strictly negative).
- To get parties who owe money to you, use `get_accounts_receivable_json()`.
- To get all non-zero party balances, use `get_party_balances_json()` or `get_party_balances_json_excluding()`.
--


# `get_accounts_receivable_json()`

## Purpose

Returns a JSON array of parties who **owe money to you** — i.e., parties with a **positive balance** in the trial balance view. These represent your **Accounts Receivable (AR)**: amounts customers or other parties are expected to pay you.

---

## Signature

```sql
public.get_accounts_receivable_json()
RETURNS JSONB
```

---

## Parameters

None.

---

## Return Format

```json
[
  { "name": "Ali Traders", "balance": 15000.00 },
  { "name": "Kareem Electronics", "balance": 4250.50 }
]
```

Returns `[]` (empty JSON array) if no receivable parties are found.

---

## Filtering Logic

| Filter | Meaning |
|---|---|
| `code IS NULL` | Only party rows, not chart-of-accounts rows |
| `type NOT ILIKE '%Expense%'` | Excludes Expense Party types |
| `balance > 0` | **Only positive balances** — party owes you money |

> A **positive balance** in `vw_trial_balance` means the party has a net **debit** position — they owe you. This is the standard AR interpretation in double-entry bookkeeping where AR is a debit-normal account.

---

## Usage Example

```sql
SELECT public.get_accounts_receivable_json();
```

**Sample output:**
```json
[
  { "name": "Ali Traders", "balance": 15000.00 },
  { "name": "Rafiq & Sons", "balance": 3200.00 }
]
```

---

## Notes

- Balances are returned **as-is** (positive numbers).
- Zero-balance parties are automatically excluded (since `balance > 0` requires strictly positive).
- To get parties you owe money to, use `get_accounts_payable_json()`.
- To get all non-zero party balances, use `get_party_balances_json()` or `get_party_balances_json_excluding()`.
--

### Function 5: `get_party_by_name()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_party_by_name(p_name text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p)
    INTO result
    FROM Parties p
    WHERE LOWER(p.party_name) = LOWER(p_name)
    LIMIT 1;

    IF result IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    RETURN result;
END;
$$;
```

#### Parameters:
- `p_name text`

#### Returns:
`jsonb`

#### Purpose:
Get Party By Name - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_party_by_name(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 6: `get_expense_party_balances_json()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_expense_party_balances_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'name', name,
                   'balance', balance
               )
           )
    INTO result
    FROM vw_trial_balance
    WHERE code IS NULL  -- only parties (not chart of accounts)
      AND type = 'Expense Party'  -- specifically Expense Party
      AND balance <> 0;  -- optional: skip zero balances

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;
```

#### Parameters:
- None

#### Returns:
`jsonb`

#### Purpose:
Get Expense Party Balances Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_expense_party_balances_json();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

