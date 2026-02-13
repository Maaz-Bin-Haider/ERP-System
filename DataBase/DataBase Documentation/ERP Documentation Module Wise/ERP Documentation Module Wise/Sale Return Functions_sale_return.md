# Sales Return Functions - Complete Documentation

**Category:** Sales Return Functions
**Total Functions:** 11

---


## 🔙 SALES RETURN FUNCTIONS

**Total Functions:** 11

---

### Function 1: `create_sale_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.create_sale_return(p_party_name text, p_serials jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id BIGINT;
    v_return_id BIGINT;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_cost NUMERIC(14,2) := 0;
BEGIN
    -- 1. Find Customer
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_party_name;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Customer % not found', p_party_name;
    END IF;

    -- 2. Create Return Header
    INSERT INTO SalesReturns(customer_id, return_date, total_amount)
    VALUES (v_party_id, CURRENT_DATE, 0)
    RETURNING sales_return_id INTO v_return_id;

    -- 3. Process each serial
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in SoldUnits', v_serial;
        END IF;

        -- check customer match
        IF v_unit.customer_id <> v_party_id THEN
            RAISE EXCEPTION 'Serial % was not sold to %', v_serial, p_party_name;
        END IF;

        -- mark sold unit as returned
        UPDATE SoldUnits SET status = 'Returned' WHERE sold_unit_id = v_unit.sold_unit_id;

        -- restore stock
        UPDATE PurchaseUnits SET in_stock = TRUE WHERE unit_id = v_unit.unit_id;

        -- log stock IN
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'IN', 'SalesReturn', v_return_id, 1);

        -- insert return line item
        INSERT INTO SalesReturnItems(sales_return_id, item_id, sold_price, cost_price, serial_number)
        VALUES (v_return_id, v_unit.item_id, v_unit.sold_price, v_unit.unit_price, v_serial);

        -- accumulate totals
        v_total := v_total + v_unit.sold_price;
        v_cost := v_cost + v_unit.unit_price;
    END LOOP;

    -- 4. Update return total
    UPDATE SalesReturns
    SET total_amount = v_total
    WHERE sales_return_id = v_return_id;

	-- Build Journal
	PERFORM rebuild_sales_return_journal(v_return_id);

    RETURN v_return_id;
END;
$$;
```

#### Parameters:
- `p_party_name text`
- `p_serials jsonb`

#### Returns:
`bigint`

#### Purpose:
Create Sale Return - Creates a new record in the database with all related entries and accounting journal.

#### Example SQL Call:

```sql
SELECT create_sale_return('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 2: `delete_sale_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.delete_sale_return(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
	v_journal_id BIGINT;
BEGIN
    -- 1. Revert each returned unit
    FOR rec IN
        SELECT sri.serial_number, sri.item_id
        FROM SalesReturnItems sri
        WHERE sri.sales_return_id = p_return_id
    LOOP
        -- mark sold unit back as Sold
        UPDATE SoldUnits
        SET status = 'Sold'
        WHERE unit_id = (
            SELECT unit_id
            FROM PurchaseUnits
            WHERE serial_number = rec.serial_number
            LIMIT 1
        );

        -- remove from stock again
        UPDATE PurchaseUnits
        SET in_stock = FALSE
        WHERE serial_number = rec.serial_number;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'SalesReturn-Delete', p_return_id, 1);
    END LOOP;

	-- 2. Remove journal (if exists)
    SELECT journal_id INTO v_journal_id
    FROM SalesReturns
    WHERE sales_return_id = p_return_id;

	IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 2. Delete return items
    DELETE FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- 4. Delete return header (triggers remove journal)
    DELETE FROM SalesReturns WHERE sales_return_id = p_return_id;
END;
$$;
```

#### Parameters:
- `p_return_id bigint`

#### Returns:
`void`

#### Purpose:
Delete Sale Return - Deletes a record after validation, cleaning up all related entries.

#### Example SQL Call:

```sql
SELECT delete_sale_return(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 3: `update_sale_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.update_sale_return(p_return_id bigint, p_serials jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_cost NUMERIC(14,2) := 0;
    v_customer_id BIGINT;
BEGIN
    -- 1. Reverse old items
    FOR rec IN
        SELECT serial_number, item_id
        FROM SalesReturnItems
        WHERE sales_return_id = p_return_id
    LOOP
        -- revert SoldUnits status
        UPDATE SoldUnits
        SET status = 'Sold'
        WHERE unit_id = (
            SELECT unit_id FROM PurchaseUnits WHERE serial_number = rec.serial_number LIMIT 1
        );

        -- remove stock
        UPDATE PurchaseUnits
        SET in_stock = FALSE
        WHERE serial_number = rec.serial_number;

        -- log OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'SalesReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    -- 2. Remove old items
    DELETE FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- 3. Get customer id
    SELECT customer_id INTO v_customer_id
    FROM SalesReturns
    WHERE sales_return_id = p_return_id;

    -- 4. Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in SoldUnits', v_serial;
        END IF;

        IF v_unit.customer_id <> v_customer_id THEN
            RAISE EXCEPTION 'Serial % was not sold to this customer', v_serial;
        END IF;

        UPDATE SoldUnits SET status = 'Returned' WHERE sold_unit_id = v_unit.sold_unit_id;
        UPDATE PurchaseUnits SET in_stock = TRUE WHERE unit_id = v_unit.unit_id;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'IN', 'SalesReturn-Update', p_return_id, 1);

        INSERT INTO SalesReturnItems(sales_return_id, item_id, sold_price, cost_price, serial_number)
        VALUES (p_return_id, v_unit.item_id, v_unit.sold_price, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.sold_price;
        v_cost := v_cost + v_unit.unit_price;
    END LOOP;

    -- 5. Update header total
    UPDATE SalesReturns
    SET total_amount = v_total
    WHERE sales_return_id = p_return_id;

	-- 6. Rebuild journal
    PERFORM rebuild_sales_return_journal(p_return_id);
END;
$$;
```

#### Parameters:
- `p_return_id bigint`
- `p_serials jsonb`

#### Returns:
`void`

#### Purpose:
Update Sale Return - Updates an existing record with validation to maintain data integrity.

#### Example SQL Call:

```sql
SELECT update_sale_return('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 4: `get_current_sales_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_current_sales_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'sales_return_id', sr.sales_return_id,
        'Customer', pa.party_name,
        'return_date', sr.return_date,
        'total_amount', sr.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'sold_price', sri.sold_price,
                    'cost_price', sri.cost_price,
                    'serial_number', sri.serial_number
                )
            )
            FROM SalesReturnItems sri
            JOIN Items i ON i.item_id = sri.item_id
            WHERE sri.sales_return_id = sr.sales_return_id
        )
    )
    INTO result
    FROM SalesReturns sr
    JOIN Parties pa ON pa.party_id = sr.customer_id
    LEFT JOIN JournalEntries je ON je.journal_id = sr.journal_id
    WHERE sr.sales_return_id = p_return_id;

    RETURN result;
END;
$$;
```

#### Parameters:
- `p_return_id bigint`

#### Returns:
`json`

#### Purpose:
Get Current Sales Return - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_current_sales_return(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 5: `get_last_sales_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_last_sales_return() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_return_id INTO last_id
    FROM SalesReturns
    ORDER BY sales_return_id DESC
    LIMIT 1;

    RETURN get_current_sales_return(last_id);
END;
$$;
```

#### Parameters:
- None

#### Returns:
`json`

#### Purpose:
Get Last Sales Return - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_sales_return();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 6: `get_last_sales_return_id()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_last_sales_return_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_return_id
    INTO last_id
    FROM SalesReturns
    ORDER BY sales_return_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;
```

#### Parameters:
- None

#### Returns:
`bigint`

#### Purpose:
Get Last Sales Return Id - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_sales_return_id();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 7: `get_next_sales_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_next_sales_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT sales_return_id INTO next_id
    FROM SalesReturns
    WHERE sales_return_id > p_return_id
    ORDER BY sales_return_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sales_return(next_id);
END;
$$;
```

#### Parameters:
- `p_return_id bigint`

#### Returns:
`json`

#### Purpose:
Get Next Sales Return - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_next_sales_return(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 8: `get_previous_sales_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_previous_sales_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT sales_return_id INTO prev_id
    FROM SalesReturns
    WHERE sales_return_id < p_return_id
    ORDER BY sales_return_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sales_return(prev_id);
END;
$$;
```

#### Parameters:
- `p_return_id bigint`

#### Returns:
`json`

#### Purpose:
Get Previous Sales Return - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_previous_sales_return(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 9: `get_sales_return_summary()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_sales_return_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 📅 Filter by date range
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                sr.sales_return_id,
                sr.return_date,
                pa.party_name AS customer,
                sr.total_amount
            FROM SalesReturns sr
            JOIN Parties pa ON sr.customer_id = pa.party_id
            WHERE sr.return_date BETWEEN p_start_date AND p_end_date
            ORDER BY sr.return_date DESC
        ) AS p;
    ELSE
        -- 📅 Last 20 returns
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                sr.sales_return_id,
                sr.return_date,
                pa.party_name AS customer,
                sr.total_amount
            FROM SalesReturns sr
            JOIN Parties pa ON sr.customer_id = pa.party_id
            ORDER BY sr.return_date DESC
            LIMIT 20
        ) AS p;
    END IF;

    RETURN COALESCE(result, '[]'::json);
END;
$$;
```

#### Parameters:
- `p_start_date date DEFAULT NULL::date`
- `p_end_date date DEFAULT NULL::date`

#### Returns:
`json`

#### Purpose:
Get Sales Return Summary - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_sales_return_summary(..., ...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 10: `serial_exists_in_sales_return()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.serial_exists_in_sales_return(p_sales_return_id bigint, p_serial_number text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT TRUE
    INTO v_exists
    FROM SalesReturnItems
    WHERE sales_return_id = p_sales_return_id
      AND serial_number = p_serial_number
    LIMIT 1;

    RETURN COALESCE(v_exists, FALSE);
END;
$$;
```

#### Parameters:
- `p_sales_return_id bigint`
- `p_serial_number text`

#### Returns:
`boolean`

#### Purpose:
Serial Exists In Sales Return - Performs specialized database operation.

#### Example SQL Call:

```sql
SELECT serial_exists_in_sales_return(..., ...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 11: `rebuild_sales_return_journal()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.rebuild_sales_return_journal(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    rev_acc BIGINT;
    cogs_acc BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
    v_cost NUMERIC(14,2);
    v_customer_id BIGINT;
    v_date DATE;
BEGIN
    -- remove old journal
    SELECT journal_id INTO j_id FROM SalesReturns WHERE sales_return_id = p_return_id;
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- totals
    SELECT customer_id, total_amount, return_date
    INTO v_customer_id, v_total, v_date
    FROM SalesReturns WHERE sales_return_id = p_return_id;

    SELECT COALESCE(SUM(cost_price),0) INTO v_cost
    FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    -- accounts
    SELECT account_id INTO rev_acc FROM ChartOfAccounts WHERE account_name='Sales Revenue';
    SELECT account_id INTO cogs_acc FROM ChartOfAccounts WHERE account_name='Cost of Goods Sold';
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ar_account_id INTO party_acc FROM Parties WHERE party_id = v_customer_id;

    -- new journal
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_date, 'Sales Return ' || p_return_id)
    RETURNING journal_id INTO j_id;

    UPDATE SalesReturns SET journal_id = j_id WHERE sales_return_id = p_return_id;

    -- (1) Debit Sales Revenue
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, rev_acc, v_total);
    END IF;

    -- (2) Credit Customer AR
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
        VALUES (j_id, party_acc, v_customer_id, v_total);
    END IF;

    -- (3) Debit Inventory
    IF v_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, inv_acc, v_cost);
    END IF;

    -- (4) Credit COGS
    IF v_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, cogs_acc, v_cost);
    END IF;
END;
$$;
```

#### Parameters:
- `p_return_id bigint`

#### Returns:
`void`

#### Purpose:
Rebuild Sales Return Journal - Rebuilds accounting journal entries for a transaction.

#### Example SQL Call:

```sql
SELECT rebuild_sales_return_journal(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

