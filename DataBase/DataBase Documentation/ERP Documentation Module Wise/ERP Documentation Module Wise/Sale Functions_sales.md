# Sales Functions - Complete Documentation

**Category:** Sales Functions
**Total Functions:** 12

---


## 💰 SALES FUNCTIONS

**Total Functions:** 12

---

### Function 1: `create_sale()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.create_sale(p_party_id bigint, p_invoice_date date, p_items jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_id BIGINT;
    v_sales_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_unit_id BIGINT;
    v_serial TEXT;
    v_item_id BIGINT;
    v_item JSONB;
BEGIN
    -- 1. Create Invoice (header)
    INSERT INTO SalesInvoices(customer_id, invoice_date, total_amount)
    VALUES (p_party_id, p_invoice_date, 0)
    RETURNING sales_invoice_id INTO v_invoice_id;

    -- 2. Loop through items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve item_id from item_name
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table', (v_item->>'item_name');
        END IF;

        -- Insert sales item
        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (
            v_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING sales_item_id INTO v_sales_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert sold units from serials
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            -- find unit_id for this serial
            SELECT unit_id INTO v_unit_id
            FROM PurchaseUnits
            WHERE serial_number = v_serial
              AND in_stock = TRUE
            LIMIT 1;

            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found or already sold', v_serial;
            END IF;

            -- insert sold unit
            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');

            -- mark purchase unit as not in stock
            UPDATE PurchaseUnits
            SET in_stock = FALSE
            WHERE unit_id = v_unit_id;

            -- log stock movement (OUT)
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 3. Update invoice total
    UPDATE SalesInvoices
    SET total_amount = v_total
    WHERE sales_invoice_id = v_invoice_id;

    -- 4. Build Journal Entry (explicit, no trigger needed)
    PERFORM rebuild_sales_journal(v_invoice_id);

    RETURN v_invoice_id;
END;
$$;
```

#### Parameters:
- `p_party_id bigint`
- `p_invoice_date date`
- `p_items jsonb`

#### Returns:
`bigint`

#### Purpose:
Create Sale - Creates a new record in the database with all related entries and accounting journal.

#### Example SQL Call:

```sql
SELECT create_sale('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 2: `delete_sale()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.delete_sale(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_journal_id BIGINT;
BEGIN
    -- 1. Restore stock for all sold units of this sale
    FOR rec IN
        SELECT su.unit_id, pu.serial_number, si.item_id
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        WHERE si.sales_invoice_id = p_invoice_id
    LOOP
        -- restore stock
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE unit_id = rec.unit_id;

        -- log stock movement (IN)
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'SalesInvoice-Delete', p_invoice_id, 1);
    END LOOP;

    -- 2. Delete associated journal entries (accounting)
    SELECT journal_id INTO v_journal_id
    FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;

    IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalLines WHERE journal_id = v_journal_id;
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 3. Delete the invoice (cascade removes SalesItems + SoldUnits)
    DELETE FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;

END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`

#### Returns:
`void`

#### Purpose:
Delete Sale - Deletes a record after validation, cleaning up all related entries.

#### Example SQL Call:

```sql
SELECT delete_sale(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 3: `validate_sales_delete()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.validate_sales_delete(p_invoice_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serials belonging to this Sales Invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_invoice_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
    WHERE si.sales_invoice_id = p_invoice_id;

    IF v_invoice_serials IS NULL THEN
        v_invoice_serials := ARRAY[]::TEXT[];
    END IF;

    -- 2️⃣ Check which of these serials are already returned
    SELECT ARRAY_AGG(sri.serial_number)
    INTO v_returned_serials
    FROM SalesReturnItems sri
    WHERE sri.serial_number = ANY(v_invoice_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 3️⃣ If any serials are returned, block deletion
    IF array_length(v_returned_serials, 1) IS NOT NULL THEN
        v_message := '❌ Cannot delete Sales Invoice ' || p_invoice_id ||
                     ' — ' || array_length(v_returned_serials, 1) ||
                     ' serial(s) already returned.';

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 4️⃣ Otherwise, safe to delete
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to delete — no returned serials found.',
        'returned_serials', v_returned_serials
    );
END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Validate Sales Delete - Deletes a record after validation, cleaning up all related entries.

#### Example SQL Call:

```sql
SELECT validate_sales_delete(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 4: `update_sale_invoice()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.update_sale_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text DEFAULT NULL::text, p_invoice_date date DEFAULT NULL::date) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_sales_item_id BIGINT;
    v_serial TEXT;
    v_unit_id BIGINT;
    v_new_party_id BIGINT;
BEGIN
    -- ========================================================
    -- 1️⃣ Update Party (Customer) if given
    -- ========================================================
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties
        WHERE party_name = p_party_name
        LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Customer "%" not found in Parties table.', p_party_name;
        END IF;

        UPDATE SalesInvoices
        SET customer_id = v_new_party_id
        WHERE sales_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 2️⃣ Update Invoice Date (if provided)
    -- ========================================================
    IF p_invoice_date IS NOT NULL THEN
        UPDATE SalesInvoices
        SET invoice_date = p_invoice_date
        WHERE sales_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 3️⃣ Delete old items + sold units + stock movements
    -- ========================================================
    DELETE FROM StockMovements 
    WHERE reference_type = 'SalesInvoice' AND reference_id = p_invoice_id;

    DELETE FROM SoldUnits
    WHERE sales_item_id IN (
        SELECT sales_item_id FROM SalesItems WHERE sales_invoice_id = p_invoice_id
    );

    DELETE FROM SalesItems 
    WHERE sales_invoice_id = p_invoice_id;

    -- ========================================================
    -- 4️⃣ Insert new/updated items and serials
    -- ========================================================
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Find item_id
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table for update_sale_invoice', (v_item->>'item_name');
        END IF;

        -- Insert sales item
        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (
            p_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING sales_item_id INTO v_sales_item_id;

        -- Add to total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert sold units + stock movements
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            -- get matching purchase unit
            SELECT unit_id INTO v_unit_id
            FROM PurchaseUnits
            WHERE serial_number = v_serial
            LIMIT 1;

            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
            END IF;

            -- mark unit as sold (in_stock = FALSE)
            UPDATE PurchaseUnits
            SET in_stock = FALSE
            WHERE unit_id = v_unit_id;

            -- insert into SoldUnits
            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');

            -- log stock OUT
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- ========================================================
    -- 5️⃣ Update total amount
    -- ========================================================
    UPDATE SalesInvoices
    SET total_amount = v_total
    WHERE sales_invoice_id = p_invoice_id;

    -- ========================================================
    -- 6️⃣ Rebuild journal (refreshes AR, Revenue, COGS, Inventory)
    -- ========================================================
    PERFORM rebuild_sales_journal(p_invoice_id);

END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`
- `p_items jsonb`
- `p_party_name text DEFAULT NULL::text`
- `p_invoice_date date DEFAULT NULL::date`

#### Returns:
`void`

#### Purpose:
Update Sale Invoice - Updates an existing record with validation to maintain data integrity.

#### Example SQL Call:

```sql
SELECT update_sale_invoice('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 5: `validate_sales_update()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.validate_sales_update(p_invoice_id bigint, p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existing_serials TEXT[];
    v_new_serials TEXT[];
    v_removed_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serials currently in this sales invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_existing_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
    WHERE si.sales_invoice_id = p_invoice_id;

    IF v_existing_serials IS NULL THEN
        v_existing_serials := ARRAY[]::TEXT[];
    END IF;

    -- 2️⃣ Extract all serials from the new JSON data (flatten correctly)
    SELECT ARRAY_AGG(serial::TEXT)
    INTO v_new_serials
    FROM jsonb_array_elements(p_items) AS item,
         jsonb_array_elements_text(item->'serials') AS serial;

    IF v_new_serials IS NULL THEN
        v_new_serials := ARRAY[]::TEXT[];
    END IF;

    -- 3️⃣ Find removed serials (those that existed before but not now)
    SELECT ARRAY_AGG(s)
    INTO v_removed_serials
    FROM unnest(v_existing_serials) AS s
    WHERE s <> ALL(v_new_serials);

    IF v_removed_serials IS NULL THEN
        v_removed_serials := ARRAY[]::TEXT[];
    END IF;

    -- 4️⃣ Check if removed serials are already in Sales Return
    SELECT ARRAY_AGG(sri.serial_number)
    INTO v_returned_serials
    FROM SalesReturnItems sri
    WHERE sri.serial_number = ANY(v_removed_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 5️⃣ If any conflicts found, return descriptive message
    IF array_length(v_returned_serials, 1) IS NOT NULL THEN
        v_message := '❌ Some serials cannot be removed. ' ||
                     array_length(v_returned_serials, 1) || ' serial(s) already returned.';

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 6️⃣ Otherwise, all safe
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to update — no returned serials will be removed.',
        'returned_serials', v_returned_serials
    );
END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`
- `p_items jsonb`

#### Returns:
`jsonb`

#### Purpose:
Validate Sales Update - Updates an existing record with validation to maintain data integrity.

#### Example SQL Call:

```sql
SELECT validate_sales_update('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 6: `rebuild_sales_journal()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.rebuild_sales_journal(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    rev_acc BIGINT;
    party_acc BIGINT;
    cogs_acc BIGINT;
    inv_acc BIGINT;
    total_cost NUMERIC(14,2);
    total_revenue NUMERIC(14,2);
    v_customer_id BIGINT;
    v_invoice_date DATE;
BEGIN
    -- 1. Get existing journal_id (if any)
    SELECT journal_id INTO j_id
    FROM SalesInvoices
    WHERE sales_invoice_id = p_invoice_id;

    -- 2. If exists, clear old lines + entry
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalLines WHERE journal_id = j_id;
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 3. Get invoice details
    SELECT s.customer_id, s.total_amount, s.invoice_date
    INTO v_customer_id, total_revenue, v_invoice_date
    FROM SalesInvoices s
    WHERE s.sales_invoice_id = p_invoice_id;

    -- 4. Get accounts
    SELECT account_id INTO rev_acc FROM ChartOfAccounts WHERE account_name='Sales Revenue';
    SELECT account_id INTO cogs_acc FROM ChartOfAccounts WHERE account_name='Cost of Goods Sold';
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ar_account_id INTO party_acc FROM Parties WHERE party_id = v_customer_id;

    -- 5. Insert new journal entry
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_invoice_date, 'Sale Invoice ' || p_invoice_id)
    RETURNING journal_id INTO j_id;

    -- 6. Update invoice with new journal_id
    UPDATE SalesInvoices
    SET journal_id = j_id
    WHERE sales_invoice_id = p_invoice_id;

    -- (1) Debit Customer (AR)
    INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
    VALUES (j_id, party_acc, v_customer_id, total_revenue);

    -- (2) Credit Revenue
    INSERT INTO JournalLines(journal_id, account_id, credit)
    VALUES (j_id, rev_acc, total_revenue);

    -- (3) Debit COGS / Credit Inventory
    SELECT COALESCE(SUM(pi.unit_price),0) INTO total_cost
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
    WHERE si.sales_invoice_id = p_invoice_id;

    IF total_cost > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, cogs_acc, total_cost);

        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, inv_acc, total_cost);
    END IF;
END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`

#### Returns:
`void`

#### Purpose:
Rebuild Sales Journal - Rebuilds accounting journal entries for a transaction.

#### Example SQL Call:

```sql
SELECT rebuild_sales_journal(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 7: `get_current_sale()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_current_sale(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'sales_invoice_id', si.sales_invoice_id,
        'Party', p.party_name,
        'invoice_date', si.invoice_date,
        'total_amount', si.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'qty', s_items.quantity,
                    'unit_price', s_items.unit_price,
                    'serials', (
                        SELECT json_agg(pu.serial_number)
                        FROM SoldUnits su
                        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
                        WHERE su.sales_item_id = s_items.sales_item_id
                    )
                )
            )
            FROM SalesItems s_items
            JOIN Items i ON i.item_id = s_items.item_id
            WHERE s_items.sales_invoice_id = si.sales_invoice_id
        )
    )
    INTO result
    FROM SalesInvoices si
    JOIN Parties p ON p.party_id = si.customer_id
    LEFT JOIN JournalEntries je ON je.journal_id = si.journal_id
    WHERE si.sales_invoice_id = p_invoice_id;

    RETURN result;
END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`

#### Returns:
`json`

#### Purpose:
Get Current Sale - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_current_sale(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 8: `get_last_sale()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_last_sale() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_invoice_id INTO last_id
    FROM SalesInvoices
    ORDER BY sales_invoice_id DESC
    LIMIT 1;

    RETURN get_current_sale(last_id);
END;
$$;
```

#### Parameters:
- None

#### Returns:
`json`

#### Purpose:
Get Last Sale - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_sale();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 9: `get_last_sale_id()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_last_sale_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_invoice_id
    INTO last_id
    FROM SalesInvoices
    ORDER BY sales_invoice_id DESC
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
Get Last Sale Id - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_sale_id();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 10: `get_next_sale()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_next_sale(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT sales_invoice_id INTO next_id
    FROM SalesInvoices
    WHERE sales_invoice_id > p_invoice_id
    ORDER BY sales_invoice_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sale(next_id);
END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`

#### Returns:
`json`

#### Purpose:
Get Next Sale - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_next_sale(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 11: `get_previous_sale()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_previous_sale(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT sales_invoice_id INTO prev_id
    FROM SalesInvoices
    WHERE sales_invoice_id < p_invoice_id
    ORDER BY sales_invoice_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_sale(prev_id);
END;
$$;
```

#### Parameters:
- `p_invoice_id bigint`

#### Returns:
`json`

#### Purpose:
Get Previous Sale - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_previous_sale(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 12: `get_sales_summary()`

#### Complete SQL Code:

```sql
CREATE FUNCTION public.get_sales_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 🧾 Case 1: Sales between given dates (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                si.sales_invoice_id,
                si.invoice_date,
                pa.party_name AS customer,
                si.total_amount
            FROM SalesInvoices si
            JOIN Parties pa ON si.customer_id = pa.party_id
            WHERE si.invoice_date BETWEEN p_start_date AND p_end_date
            ORDER BY si.invoice_date DESC
        ) AS p;

    ELSE
        -- 🧾 Case 2: Last 20 sales (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                si.sales_invoice_id,
                si.invoice_date,
                pa.party_name AS customer,
                si.total_amount
            FROM SalesInvoices si
            JOIN Parties pa ON si.customer_id = pa.party_id
            ORDER BY si.invoice_date DESC
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
Get Sales Summary - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_sales_summary(..., ...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

