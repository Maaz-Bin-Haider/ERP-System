-- ============================================================
-- MIGRATION: Make created_by track the LAST modifier
--
-- What changes:
--   1. update_sale_invoice     — new p_created_by parameter,
--                                writes it to salesinvoices.created_by
--   2. update_purchase_invoice — same
--   3. update_item_from_json   — reads created_by_id from JSON,
--                                writes it to items.created_by
--   4. update_party_from_json  — reads created_by_id from JSON,
--                                writes it to parties.created_by
--   5. make_payment / make_receipt — already read created_by_id
--      from the JSON payload (added in the earlier migration).
--      No change needed there.
--
-- create_sale, create_purchase, create_sale_return,
-- create_purchase_return already have p_created_by — no change.
--
-- Run this AFTER the earlier migrations.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. update_sale_invoice — add p_created_by parameter
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_sale_invoice(
    p_invoice_id    BIGINT,
    p_items         JSONB,
    p_party_name    TEXT    DEFAULT NULL,
    p_invoice_date  DATE    DEFAULT NULL,
    p_created_by    INTEGER DEFAULT NULL    -- NEW: last modifier
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_item          JSONB;
    v_item_id       BIGINT;
    v_total         NUMERIC(14,2) := 0;
    v_sales_item_id BIGINT;
    v_serial        TEXT;
    v_unit_id       BIGINT;
    v_new_party_id  BIGINT;
BEGIN
    -- 1. Update Party (Customer) if given
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties WHERE party_name = p_party_name LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Customer "%" not found in Parties table.', p_party_name;
        END IF;

        UPDATE SalesInvoices
        SET customer_id = v_new_party_id
        WHERE sales_invoice_id = p_invoice_id;
    END IF;

    -- 2. Update Invoice Date (if provided)
    IF p_invoice_date IS NOT NULL THEN
        UPDATE SalesInvoices
        SET invoice_date = p_invoice_date
        WHERE sales_invoice_id = p_invoice_id;
    END IF;

    -- 3. Update last modifier (always, if provided)
    IF p_created_by IS NOT NULL THEN
        UPDATE SalesInvoices
        SET created_by = p_created_by
        WHERE sales_invoice_id = p_invoice_id;
    END IF;

    -- 4. Delete old items + sold units + stock movements
    DELETE FROM StockMovements
    WHERE reference_type = 'SalesInvoice' AND reference_id = p_invoice_id;

    DELETE FROM SoldUnits
    WHERE sales_item_id IN (
        SELECT sales_item_id FROM SalesItems WHERE sales_invoice_id = p_invoice_id
    );

    DELETE FROM SalesItems WHERE sales_invoice_id = p_invoice_id;

    -- 5. Insert new/updated items and serials
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        SELECT item_id INTO v_item_id
        FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;

        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table for update_sale_invoice',
                            (v_item->>'item_name');
        END IF;

        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (p_invoice_id, v_item_id,
                (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING sales_item_id INTO v_sales_item_id;

        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            SELECT unit_id INTO v_unit_id
            FROM PurchaseUnits WHERE serial_number = v_serial LIMIT 1;

            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
            END IF;

            UPDATE PurchaseUnits SET in_stock = FALSE WHERE unit_id = v_unit_id;

            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');

            INSERT INTO StockMovements(item_id, serial_number, movement_type,
                                       reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 6. Update total amount
    UPDATE SalesInvoices SET total_amount = v_total
    WHERE sales_invoice_id = p_invoice_id;

    -- 7. Rebuild journal
    PERFORM rebuild_sales_journal(p_invoice_id);
END;
$$;


-- ============================================================
-- 2. update_purchase_invoice — add p_created_by parameter
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_purchase_invoice(
    p_invoice_id    BIGINT,
    p_items         JSONB,
    p_party_name    TEXT    DEFAULT NULL,
    p_invoice_date  DATE    DEFAULT NULL,
    p_created_by    INTEGER DEFAULT NULL    -- NEW: last modifier
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_item              JSONB;
    v_item_id           BIGINT;
    v_total             NUMERIC(14,2) := 0;
    v_purchase_item_id  BIGINT;
    v_serial            JSONB;
    v_new_party_id      BIGINT;
    v_existing_serials  TEXT[];
    v_new_serials       TEXT[];
    v_serials_to_remove TEXT[];
    v_serials_to_keep   TEXT[];
    v_validation        JSONB;
    v_temp_item_id      BIGINT := -999999;
BEGIN
    -- Validate
    v_validation := validate_purchase_update2(p_invoice_id, p_items);
    IF (v_validation->>'is_valid')::BOOLEAN = FALSE THEN
        RAISE EXCEPTION '%', v_validation->>'message';
    END IF;

    -- Update Party
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties WHERE party_name = p_party_name LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor "%" not found.', p_party_name;
        END IF;

        UPDATE PurchaseInvoices
        SET vendor_id = v_new_party_id
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- Update Date
    IF p_invoice_date IS NOT NULL THEN
        UPDATE PurchaseInvoices
        SET invoice_date = p_invoice_date
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- Update last modifier
    IF p_created_by IS NOT NULL THEN
        UPDATE PurchaseInvoices
        SET created_by = p_created_by
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- Existing serials
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_existing_serials
    FROM PurchaseUnits pu
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    IF v_existing_serials IS NULL THEN v_existing_serials := ARRAY[]::TEXT[]; END IF;

    -- New serials from JSON
    SELECT ARRAY_AGG(serial_obj->>'serial')
    INTO v_new_serials
    FROM jsonb_array_elements(p_items) AS item,
         jsonb_array_elements(item->'serials') AS serial_obj;

    IF v_new_serials IS NULL THEN v_new_serials := ARRAY[]::TEXT[]; END IF;

    -- Serials to remove
    SELECT ARRAY_AGG(s) INTO v_serials_to_remove
    FROM unnest(v_existing_serials) AS s WHERE s <> ALL(v_new_serials);
    IF v_serials_to_remove IS NULL THEN v_serials_to_remove := ARRAY[]::TEXT[]; END IF;

    -- Serials to keep
    SELECT ARRAY_AGG(s) INTO v_serials_to_keep
    FROM unnest(v_existing_serials) AS s WHERE s = ANY(v_new_serials);
    IF v_serials_to_keep IS NULL THEN v_serials_to_keep := ARRAY[]::TEXT[]; END IF;

    -- Temp item placeholder
    INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
    VALUES (p_invoice_id, 1, 1, 0)
    RETURNING purchase_item_id INTO v_temp_item_id;

    UPDATE PurchaseUnits SET purchase_item_id = v_temp_item_id
    WHERE serial_number = ANY(v_serials_to_keep);

    -- Remove old stock movements for removed serials
    DELETE FROM StockMovements
    WHERE reference_type = 'PurchaseInvoice'
      AND reference_id = p_invoice_id
      AND serial_number = ANY(v_serials_to_remove);

    -- Delete old items
    DELETE FROM PurchaseItems
    WHERE purchase_invoice_id = p_invoice_id
      AND purchase_item_id != v_temp_item_id;

    -- Recreate items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        SELECT item_id INTO v_item_id
        FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;

        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (p_invoice_id, v_item_id,
                (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING purchase_item_id INTO v_purchase_item_id;

        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        FOR v_serial IN SELECT * FROM jsonb_array_elements(v_item->'serials')
        LOOP
            IF (v_serial->>'serial') = ANY(v_serials_to_keep) THEN
                UPDATE PurchaseUnits
                SET purchase_item_id = v_purchase_item_id,
                    serial_comment = NULLIF(TRIM(COALESCE(v_serial->>'comment','')), '')
                WHERE serial_number = v_serial->>'serial'
                  AND purchase_item_id = v_temp_item_id;
            ELSE
                INSERT INTO PurchaseUnits(purchase_item_id, serial_number, serial_comment, in_stock)
                VALUES (v_purchase_item_id, v_serial->>'serial',
                        NULLIF(TRIM(COALESCE(v_serial->>'comment','')), ''), TRUE);

                INSERT INTO StockMovements(item_id, serial_number, movement_type,
                                           reference_type, reference_id, quantity)
                VALUES (v_item_id, v_serial->>'serial', 'IN', 'PurchaseInvoice', p_invoice_id, 1);
            END IF;
        END LOOP;
    END LOOP;

    DELETE FROM PurchaseItems WHERE purchase_item_id = v_temp_item_id;

    UPDATE PurchaseInvoices SET total_amount = v_total
    WHERE purchase_invoice_id = p_invoice_id;

    PERFORM rebuild_purchase_journal(p_invoice_id);
END;
$$;


-- ============================================================
-- 3. update_item_from_json — read created_by_id from JSON
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_item_from_json(item_data jsonb) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE Items
    SET
        item_name   = COALESCE(item_data->>'item_name', item_name),
        storage     = COALESCE(item_data->>'storage', storage),
        sale_price  = COALESCE(NULLIF(item_data->>'sale_price','')::NUMERIC, sale_price),
        item_code   = COALESCE(NULLIF(item_data->>'item_code',''), item_code),
        category    = COALESCE(NULLIF(item_data->>'category',''), category),
        brand       = COALESCE(NULLIF(item_data->>'brand',''), brand),
        updated_at  = NOW(),
        -- Update last modifier if provided
        created_by  = CASE
                        WHEN NULLIF(item_data->>'created_by_id', '') IS NOT NULL
                        THEN (item_data->>'created_by_id')::INTEGER
                        ELSE created_by
                      END
    WHERE item_id = (item_data->>'item_id')::BIGINT;
END;
$$;


-- ============================================================
-- 4. update_party_from_json — read created_by_id from JSON
--    (minimal addition — only the SET clause gains created_by)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_party_from_json(p_id bigint, party_data jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
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

COMMIT;
