--
-- PostgreSQL database dump
--

\restrict IyjIK784Sp4a8hov8lV3SctochElSFAu1ebWYRM6TdLGgXrUItOKosnk4sh1tNx

-- Dumped from database version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.11 (Ubuntu 16.11-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: add_item_from_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_item_from_json(item_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO Items (
        item_name, 
        storage, 
        sale_price, 
        item_code, 
        category, 
        brand,
        created_at,
        updated_at
    )
    VALUES (
        item_data->>'item_name',
        COALESCE(item_data->>'storage', 'Main Warehouse'),          -- default storage
        COALESCE((item_data->>'sale_price')::NUMERIC, 0.00),        -- default 0.00
        NULLIF(item_data->>'item_code', ''),                        -- NULL if empty
        NULLIF(item_data->>'category', ''),                         -- optional
        NULLIF(item_data->>'brand', ''),                            -- optional
        COALESCE((item_data->>'created_at')::TIMESTAMP, NOW()),     -- default current time
        COALESCE((item_data->>'updated_at')::TIMESTAMP, NOW())      -- default current time
    );
END;
$$;


ALTER FUNCTION public.add_item_from_json(item_data jsonb) OWNER TO postgres;

--
-- Name: add_party_from_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.add_party_from_json(party_data jsonb) OWNER TO postgres;

--
-- Name: create_purchase(bigint, date, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_purchase(p_party_id bigint, p_invoice_date date, p_items jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_id BIGINT;
    v_purchase_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_item_id BIGINT;
    v_item JSONB;
    v_serial TEXT;
BEGIN
    -- 1. Create Purchase Invoice (header)
    INSERT INTO PurchaseInvoices(vendor_id, invoice_date, total_amount)
    VALUES (p_party_id, p_invoice_date, 0)
    RETURNING purchase_invoice_id INTO v_invoice_id;

    -- 2. Loop through items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve item_id from item_name
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            -- Optionally auto-create item if not found
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (
            v_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert purchase units (serials) into stock
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            -- Insert stock movement (IN) for audit trail
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- 3. Update invoice total
    UPDATE PurchaseInvoices
    SET total_amount = v_total
    WHERE purchase_invoice_id = v_invoice_id;

    -- 4. Build Journal Entry (explicit, no trigger needed)
    PERFORM rebuild_purchase_journal(v_invoice_id);

    RETURN v_invoice_id;
END;
$$;


ALTER FUNCTION public.create_purchase(p_party_id bigint, p_invoice_date date, p_items jsonb) OWNER TO postgres;

--
-- Name: create_purchase_return(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_purchase_return(p_party_name text, p_serials jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id BIGINT;
    v_return_id BIGINT;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
BEGIN
    -- 1. Find Vendor
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_party_name;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Vendor % not found', p_party_name;
    END IF;

    -- 2. Create Return Header
    INSERT INTO PurchaseReturns(vendor_id, return_date, total_amount)
    VALUES (v_party_id, CURRENT_DATE, 0)
    RETURNING purchase_return_id INTO v_return_id;

    -- 3. Process each serial
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.serial_number, pi.item_id, pi.unit_price, p.vendor_id, p.purchase_invoice_id
        INTO v_unit
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
        END IF;

        -- check if in stock
        IF NOT EXISTS (
            SELECT 1 FROM PurchaseUnits WHERE unit_id = v_unit.unit_id AND in_stock = TRUE
        ) THEN
            RAISE EXCEPTION 'Serial % is not currently in stock', v_serial;
        END IF;

        -- check vendor match
        IF v_unit.vendor_id <> v_party_id THEN
            RAISE EXCEPTION 'Serial % was purchased from a different vendor', v_serial;
        END IF;

        -- mark as returned (remove from stock)
        UPDATE PurchaseUnits 
        SET in_stock = FALSE 
        WHERE unit_id = v_unit.unit_id;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'OUT', 'PurchaseReturn', v_return_id, 1);

        -- insert return line (✅ unit_price instead of cost_price)
        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (v_return_id, v_unit.item_id, v_unit.unit_price, v_serial);

        -- accumulate total
        v_total := v_total + v_unit.unit_price;
    END LOOP;

    -- 4. Update header total
    UPDATE PurchaseReturns
    SET total_amount = v_total
    WHERE purchase_return_id = v_return_id;

    -- 5. Build Journal
    PERFORM rebuild_purchase_return_journal(v_return_id);

    RETURN v_return_id;
END;
$$;


ALTER FUNCTION public.create_purchase_return(p_party_name text, p_serials jsonb) OWNER TO postgres;

--
-- Name: create_sale(bigint, date, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.create_sale(p_party_id bigint, p_invoice_date date, p_items jsonb) OWNER TO postgres;

--
-- Name: create_sale_return(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.create_sale_return(p_party_name text, p_serials jsonb) OWNER TO postgres;

--
-- Name: delete_payment(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_payment(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM Payments WHERE payment_id = p_payment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment deleted successfully',
        'payment_id',p_payment_id
    );
END;
$$;


ALTER FUNCTION public.delete_payment(p_payment_id bigint) OWNER TO postgres;

--
-- Name: delete_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_purchase(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    j_id BIGINT;
BEGIN
    -- 1. Capture the related journal_id (if any)
    SELECT journal_id INTO j_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;

    -- 2. Log stock OUT movements before deleting
    FOR rec IN
        SELECT pu.serial_number, pi.item_id, pu.purchase_item_id
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pi.purchase_item_id = pu.purchase_item_id
        WHERE pi.purchase_invoice_id = p_invoice_id
    LOOP
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'PurchaseInvoice-Delete', p_invoice_id, 1);
    END LOOP;

    -- 3. Delete purchase units (serials)
    DELETE FROM PurchaseUnits
    WHERE purchase_item_id IN (
        SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id
    );

    -- 4. Delete purchase items
    DELETE FROM PurchaseItems
    WHERE purchase_invoice_id = p_invoice_id;

    -- 5. Delete journal lines + journal entry if exists
    IF j_id IS NOT NULL THEN
        DELETE FROM JournalLines WHERE journal_id = j_id;
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 6. Delete the purchase invoice itself
    DELETE FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;

END;
$$;


ALTER FUNCTION public.delete_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: delete_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_purchase_return(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_vendor_id BIGINT;
    v_unit_vendor_id BIGINT;
    v_journal_id BIGINT;
BEGIN
    -- 1. Get vendor id from return header
    SELECT vendor_id, journal_id
    INTO v_vendor_id, v_journal_id
    FROM PurchaseReturns
    WHERE purchase_return_id = p_return_id;

    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Purchase Return % not found', p_return_id;
    END IF;

    -- 2. Restore stock for returned items
    FOR rec IN
        SELECT serial_number, item_id
        FROM PurchaseReturnItems
        WHERE purchase_return_id = p_return_id
    LOOP
        -- fetch the vendor of the original purchase for safety
        SELECT p.vendor_id
        INTO v_unit_vendor_id
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = rec.serial_number;

        IF v_unit_vendor_id IS DISTINCT FROM v_vendor_id THEN
            RAISE EXCEPTION 'Serial % does not belong to vendor % (return %)', 
                rec.serial_number, v_vendor_id, p_return_id;
        END IF;

        -- restore in stock
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE serial_number = rec.serial_number;

        -- log stock IN
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'PurchaseReturn-Delete', p_return_id, 1);
    END LOOP;

    -- 3. Remove journal (if exists)
    IF v_journal_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = v_journal_id;
    END IF;

    -- 4. Delete return items
    DELETE FROM PurchaseReturnItems WHERE purchase_return_id = p_return_id;

    -- 5. Delete return header
    DELETE FROM PurchaseReturns WHERE purchase_return_id = p_return_id;
END;
$$;


ALTER FUNCTION public.delete_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: delete_receipt(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_receipt(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM Receipts WHERE receipt_id = p_receipt_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt ID % not found', p_receipt_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt deleted successfully',
        'receipt_id',p_receipt_id
    );
END;
$$;


ALTER FUNCTION public.delete_receipt(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: delete_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.delete_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: delete_sale_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.delete_sale_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: detailed_ledger(text, date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.detailed_ledger(p_party_name text, p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_current_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_current_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'purchase_invoice_id', pi.purchase_invoice_id,
        'Party', p.party_name,
        'invoice_date', pi.invoice_date,
        'total_amount', pi.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'qty', pi2.quantity,
                    'unit_price', pi2.unit_price,
                    'serials', (
                        SELECT json_agg(pu.serial_number)
                        FROM PurchaseUnits pu
                        WHERE pu.purchase_item_id = pi2.purchase_item_id
                    )
                )
            )
            FROM PurchaseItems pi2
            JOIN Items i ON i.item_id = pi2.item_id
            WHERE pi2.purchase_invoice_id = pi.purchase_invoice_id
        )
    )
    INTO result
    FROM PurchaseInvoices pi
    JOIN Parties p ON p.party_id = pi.vendor_id
    LEFT JOIN JournalEntries je ON je.journal_id = pi.journal_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_current_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_current_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_current_purchase_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'purchase_return_id', pr.purchase_return_id,
        'Vendor', pa.party_name,
        'return_date', pr.return_date,
        'total_amount', pr.total_amount,
        'description', je.description,
        'items', (
            SELECT json_agg(
                json_build_object(
                    'item_name', i.item_name,
                    'unit_price', pri.unit_price,
                    'serial_number', pri.serial_number
                )
            )
            FROM PurchaseReturnItems pri
            JOIN Items i ON i.item_id = pri.item_id
            WHERE pri.purchase_return_id = pr.purchase_return_id
        )
    )
    INTO result
    FROM PurchaseReturns pr
    JOIN Parties pa ON pa.party_id = pr.vendor_id
    LEFT JOIN JournalEntries je ON je.journal_id = pr.journal_id
    WHERE pr.purchase_return_id = p_return_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_current_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_current_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_current_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_current_sales_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_current_sales_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_expense_party_balances_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_expense_party_balances_json() OWNER TO postgres;

--
-- Name: get_item_by_name(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_item_by_name(p_item_name text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT COALESCE(
        jsonb_agg(to_jsonb(i) - 'updated_at' - 'created_at'),  -- convert rows to JSON array
        '[]'::jsonb
    )
    INTO result
    FROM Items i
    WHERE i.item_name ILIKE p_item_name;   -- case-insensitive match

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_item_by_name(p_item_name text) OWNER TO postgres;

--
-- Name: get_item_names_like(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_item_names_like(search_term text) RETURNS TABLE(item_name text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT item_name
    FROM items
    WHERE UPPER(item_name) LIKE search_term || '%';
END;
$$;


ALTER FUNCTION public.get_item_names_like(search_term text) OWNER TO postgres;

--
-- Name: get_items_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_items_json() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'item_name', item_name,
                   'brand', brand
               )
           )
    INTO result
    FROM Items;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_items_json() OWNER TO postgres;

--
-- Name: get_last_20_payments_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_20_payments_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party TEXT;
    result  JSONB;
BEGIN
    -- Extract optional party filter
    v_party := p_data->>'party_name';

    SELECT jsonb_agg(row_data)
    INTO result
    FROM (
        SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name) AS row_data
        FROM Payments p
        JOIN Parties pt ON pt.party_id = p.party_id
        WHERE (v_party IS NULL OR pt.party_name ILIKE v_party)
        ORDER BY p.payment_date DESC, p.payment_id DESC
        LIMIT 20
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_last_20_payments_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_last_20_receipts_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_20_receipts_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party TEXT;
    result  JSONB;
BEGIN
    v_party := p_data->>'party_name';

    SELECT jsonb_agg(row_data)
    INTO result
    FROM (
        SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name) AS row_data
        FROM Receipts r
        JOIN Parties pt ON pt.party_id = r.party_id
        WHERE (v_party IS NULL OR pt.party_name ILIKE v_party)
        ORDER BY r.receipt_date DESC, r.receipt_id DESC
        LIMIT 20
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_last_20_receipts_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_last_payment(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_payment() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    ORDER BY p.payment_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_last_payment() OWNER TO postgres;

--
-- Name: get_last_purchase(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO last_id
    FROM PurchaseInvoices
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    RETURN get_current_purchase(last_id);
END;
$$;


ALTER FUNCTION public.get_last_purchase() OWNER TO postgres;

--
-- Name: get_last_purchase_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_invoice_id
    INTO last_id
    FROM PurchaseInvoices
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_purchase_id() OWNER TO postgres;

--
-- Name: get_last_purchase_return(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase_return() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_return_id INTO last_id
    FROM PurchaseReturns
    ORDER BY purchase_return_id DESC
    LIMIT 1;

    RETURN get_current_purchase_return(last_id);
END;
$$;


ALTER FUNCTION public.get_last_purchase_return() OWNER TO postgres;

--
-- Name: get_last_purchase_return_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_purchase_return_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_return_id
    INTO last_id
    FROM PurchaseReturns
    ORDER BY purchase_return_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_purchase_return_id() OWNER TO postgres;

--
-- Name: get_last_receipt(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_last_receipt() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    ORDER BY r.receipt_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_last_receipt() OWNER TO postgres;

--
-- Name: get_last_sale(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_last_sale() OWNER TO postgres;

--
-- Name: get_last_sale_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_last_sale_id() OWNER TO postgres;

--
-- Name: get_last_sales_return(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_last_sales_return() OWNER TO postgres;

--
-- Name: get_last_sales_return_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_last_sales_return_id() OWNER TO postgres;

--
-- Name: get_next_payment(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_payment(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_id > p_payment_id
    ORDER BY p.payment_id ASC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_next_payment(p_payment_id bigint) OWNER TO postgres;

--
-- Name: get_next_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO next_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id > p_invoice_id
    ORDER BY purchase_invoice_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase(next_id);
END;
$$;


ALTER FUNCTION public.get_next_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_next_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_purchase_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT purchase_return_id INTO next_id
    FROM PurchaseReturns
    WHERE purchase_return_id > p_return_id
    ORDER BY purchase_return_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase_return(next_id);
END;
$$;


ALTER FUNCTION public.get_next_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_next_receipt(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_receipt(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_id > p_receipt_id
    ORDER BY r.receipt_id ASC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_next_receipt(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: get_next_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_next_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_next_sales_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_next_sales_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_parties_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_parties_json() OWNER TO postgres;

--
-- Name: get_party_balances_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_party_balances_json() OWNER TO postgres;

--
-- Name: get_party_by_name(text); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_party_by_name(p_name text) OWNER TO postgres;

--
-- Name: get_payment_details(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_payment_details(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_id = p_payment_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_payment_details(p_payment_id bigint) OWNER TO postgres;

--
-- Name: get_payments_by_date_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_payments_by_date_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_start DATE;
    v_end   DATE;
    v_party TEXT;
    result  JSONB;
BEGIN
    -- Extract from JSON
    v_start := (p_data->>'start_date')::DATE;
    v_end   := (p_data->>'end_date')::DATE;
    v_party := p_data->>'party_name';

    IF v_start IS NULL OR v_end IS NULL THEN
        RAISE EXCEPTION 'Both start_date and end_date must be provided in JSON';
    END IF;

    SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('party_name', pt.party_name) 
                     ORDER BY p.payment_date DESC, p.payment_id DESC)
    INTO result
    FROM Payments p
    JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_date BETWEEN v_start AND v_end
      AND (v_party IS NULL OR pt.party_name ILIKE v_party);

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_payments_by_date_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_previous_payment(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_payment(p_payment_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(p) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    WHERE p.payment_id < p_payment_id
    ORDER BY p.payment_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_previous_payment(p_payment_id bigint) OWNER TO postgres;

--
-- Name: get_previous_purchase(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO prev_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id < p_invoice_id
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase(prev_id);
END;
$$;


ALTER FUNCTION public.get_previous_purchase(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_previous_purchase_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_purchase_return(p_return_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT purchase_return_id INTO prev_id
    FROM PurchaseReturns
    WHERE purchase_return_id < p_return_id
    ORDER BY purchase_return_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase_return(prev_id);
END;
$$;


ALTER FUNCTION public.get_previous_purchase_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_previous_receipt(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_previous_receipt(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_id < p_receipt_id
    ORDER BY r.receipt_id DESC
    LIMIT 1;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_previous_receipt(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: get_previous_sale(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_previous_sale(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: get_previous_sales_return(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_previous_sales_return(p_return_id bigint) OWNER TO postgres;

--
-- Name: get_purchase_return_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_purchase_return_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 🧾 Case 1: Returns between given dates (latest first)
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                pr.purchase_return_id,
                pr.return_date,
                pa.party_name AS vendor,
                pr.total_amount
            FROM PurchaseReturns pr
            JOIN Parties pa ON pr.vendor_id = pa.party_id
            WHERE pr.return_date BETWEEN p_start_date AND p_end_date
            ORDER BY pr.return_date DESC
        ) AS p;

    ELSE
        -- 🧾 Case 2: Last 20 purchase returns (latest first)
        SELECT json_agg(p ORDER BY p.return_date DESC)
        INTO result
        FROM (
            SELECT
                pr.purchase_return_id,
                pr.return_date,
                pa.party_name AS vendor,
                pr.total_amount
            FROM PurchaseReturns pr
            JOIN Parties pa ON pr.vendor_id = pa.party_id
            ORDER BY pr.return_date DESC
            LIMIT 20
        ) AS p;
    END IF;

    RETURN COALESCE(result, '[]'::json);
END;
$$;


ALTER FUNCTION public.get_purchase_return_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_purchase_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_purchase_summary(p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSON;
BEGIN
    IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
        -- 🧾 Case 1: Purchases between given dates (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                pi.purchase_invoice_id,
                pi.invoice_date,
                pa.party_name AS vendor,
                pi.total_amount
            FROM PurchaseInvoices pi
            JOIN Parties pa ON pi.vendor_id = pa.party_id
            WHERE pi.invoice_date BETWEEN p_start_date AND p_end_date
            ORDER BY pi.invoice_date DESC
        ) AS p;

    ELSE
        -- 🧾 Case 2: Last 20 purchases (latest first)
        SELECT json_agg(p ORDER BY p.invoice_date DESC)
        INTO result
        FROM (
            SELECT
                pi.purchase_invoice_id,
                pi.invoice_date,
                pa.party_name AS vendor,
                pi.total_amount
            FROM PurchaseInvoices pi
            JOIN Parties pa ON pi.vendor_id = pa.party_id
            ORDER BY pi.invoice_date DESC
            LIMIT 20
        ) AS p;
    END IF;

    RETURN COALESCE(result, '[]'::json);
END;
$$;


ALTER FUNCTION public.get_purchase_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_receipt_details(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_receipt_details(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT to_jsonb(r) || jsonb_build_object('party_name', pt.party_name)
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_id = p_receipt_id;

    RETURN result;
END;
$$;


ALTER FUNCTION public.get_receipt_details(p_receipt_id bigint) OWNER TO postgres;

--
-- Name: get_receipts_by_date_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_receipts_by_date_json(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_start DATE;
    v_end   DATE;
    v_party TEXT;
    result  JSONB;
BEGIN
    v_start := (p_data->>'start_date')::DATE;
    v_end   := (p_data->>'end_date')::DATE;
    v_party := p_data->>'party_name';

    IF v_start IS NULL OR v_end IS NULL THEN
        RAISE EXCEPTION 'Both start_date and end_date must be provided in JSON';
    END IF;

    SELECT jsonb_agg(to_jsonb(r) || jsonb_build_object('party_name', pt.party_name) 
                     ORDER BY r.receipt_date DESC, r.receipt_id DESC)
    INTO result
    FROM Receipts r
    JOIN Parties pt ON pt.party_id = r.party_id
    WHERE r.receipt_date BETWEEN v_start AND v_end
      AND (v_party IS NULL OR pt.party_name ILIKE v_party);

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_receipts_by_date_json(p_data jsonb) OWNER TO postgres;

--
-- Name: get_sales_return_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_sales_return_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_sales_summary(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.get_sales_summary(p_start_date date, p_end_date date) OWNER TO postgres;

--
-- Name: get_serial_ledger(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_serial_ledger(p_serial text) RETURNS TABLE(serial_number text, item_name text, txn_date date, particulars text, reference text, qty_in integer, qty_out integer, balance integer, party_name text, purchase_price numeric, sale_price numeric, profit numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY

    WITH item_info AS (
        SELECT 
            pu.serial_number::text AS serial_number,
            i.item_name::text AS item_name
        FROM PurchaseUnits pu
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN Items i ON pit.item_id = i.item_id
        WHERE pu.serial_number = p_serial
        LIMIT 1
    ),

    purchase AS (
        SELECT 
            pi.invoice_date AS dt,
            'Purchase'::text AS particulars,
            pi.purchase_invoice_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            p.party_name::text AS party_name,
            pit.unit_price AS purchase_price,
            NULL::numeric AS sale_price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN PurchaseInvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
        JOIN Parties p ON pi.vendor_id = p.party_id
        WHERE pu.serial_number = p_serial
    ),

    purchase_return AS (
        SELECT
            pr.return_date AS dt,
            'Purchase Return'::text AS particulars,
            pr.purchase_return_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            p.party_name::text AS party_name,
            pri.unit_price AS purchase_price,
            NULL::numeric AS sale_price
        FROM PurchaseReturnItems pri
        JOIN PurchaseReturns pr ON pri.purchase_return_id = pr.purchase_return_id
        JOIN Parties p ON pr.vendor_id = p.party_id
        WHERE pri.serial_number = p_serial
    ),

    sale AS (
        SELECT 
            si.invoice_date AS dt,
            'Sale'::text AS particulars,
            si.sales_invoice_id::text AS reference,
            0 AS qty_in,
            1 AS qty_out,
            c.party_name::text AS party_name,
            pit.unit_price AS purchase_price,
            su.sold_price AS sale_price
        FROM SoldUnits su
        JOIN SalesItems sitm ON su.sales_item_id = sitm.sales_item_id
        JOIN SalesInvoices si ON sitm.sales_invoice_id = si.sales_invoice_id
        JOIN Parties c ON si.customer_id = c.party_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        WHERE pu.serial_number = p_serial
    ),

    sales_return AS (
        SELECT
            sr.return_date AS dt,
            'Sales Return'::text AS particulars,
            sr.sales_return_id::text AS reference,
            1 AS qty_in,
            0 AS qty_out,
            c.party_name::text AS party_name,
            sri.cost_price AS purchase_price,
            sri.sold_price AS sale_price
        FROM SalesReturnItems sri
        JOIN SalesReturns sr ON sri.sales_return_id = sr.sales_return_id
        JOIN Parties c ON sr.customer_id = c.party_id
        WHERE sri.serial_number = p_serial
    )

    SELECT
        ii.serial_number,
        ii.item_name,
        l.dt AS txn_date,
        l.particulars,
        l.reference,
        l.qty_in,
        l.qty_out,
        CAST(SUM(l.qty_in - l.qty_out) OVER (ORDER BY l.dt, l.reference) AS INT) AS balance,
        l.party_name,
        l.purchase_price,
        l.sale_price,
        CASE 
            WHEN l.sale_price IS NOT NULL AND l.purchase_price IS NOT NULL 
            THEN l.sale_price - l.purchase_price
        END AS profit
    FROM (
        SELECT * FROM purchase
        UNION ALL SELECT * FROM purchase_return
        UNION ALL SELECT * FROM sale
        UNION ALL SELECT * FROM sales_return
    ) l
    CROSS JOIN item_info ii
    ORDER BY l.dt, l.reference;

END;
$$;


ALTER FUNCTION public.get_serial_ledger(p_serial text) OWNER TO postgres;

--
-- Name: get_serial_number_details(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_serial_number_details(serial text) RETURNS TABLE(serial_number character varying, item_name character varying, brand character varying, category character varying, purchase_invoice_id bigint, vendor_name character varying, purchase_date date, purchase_price numeric, in_stock boolean, sales_invoice_id bigint, customer_name character varying, sale_date date, sold_price numeric, current_status character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        pu.serial_number,
        i.item_name,
        i.brand,
        i.category,
        pi.purchase_invoice_id,
        p.party_name AS vendor_name,
        pi.invoice_date AS purchase_date,
        pit.unit_price AS purchase_price,
        pu.in_stock,
        si.sales_invoice_id,
        c.party_name AS customer_name,
        si.invoice_date AS sale_date,
        su.sold_price,
        COALESCE(su.status, CASE WHEN pu.in_stock THEN 'In Stock' ELSE 'Sold/Unknown' END) AS current_status
    FROM PurchaseUnits pu
    JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN Items i ON pit.item_id = i.item_id
    JOIN PurchaseInvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
    JOIN Parties p ON pi.vendor_id = p.party_id
    LEFT JOIN SoldUnits su ON su.unit_id = pu.unit_id
    LEFT JOIN SalesItems si_itm ON su.sales_item_id = si_itm.sales_item_id
    LEFT JOIN SalesInvoices si ON si_itm.sales_invoice_id = si.sales_invoice_id
    LEFT JOIN Parties c ON si.customer_id = c.party_id
    WHERE pu.serial_number = serial;
END;
$$;


ALTER FUNCTION public.get_serial_number_details(serial text) OWNER TO postgres;

--
-- Name: get_trial_balance_json(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_trial_balance_json() RETURNS jsonb
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
    FROM vw_trial_balance;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_trial_balance_json() OWNER TO postgres;

--
-- Name: item_transaction_history(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.item_transaction_history(p_item_name text) RETURNS TABLE(item_name text, serial_number text, transaction_date date, transaction_type text, counterparty text, price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH purchase_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            p.invoice_date AS transaction_date,
            'PURCHASE'::TEXT AS transaction_type,
            v.party_name::TEXT AS counterparty,
            pi.unit_price AS price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
        JOIN Parties v ON p.vendor_id = v.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
    ),
    sale_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            s.invoice_date AS transaction_date,
            'SALE'::TEXT AS transaction_type,
            c.party_name::TEXT AS counterparty,
            su.sold_price AS price
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        JOIN Parties c ON s.customer_id = c.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
    )
    SELECT 
        ph.item_name,
        ph.serial_number,
        ph.transaction_date,
        ph.transaction_type,
        ph.counterparty,
        ph.price
    FROM (
        SELECT * FROM purchase_history
        UNION ALL
        SELECT * FROM sale_history
    ) AS ph
    ORDER BY ph.transaction_date, 
             ph.transaction_type DESC,   -- ensures PURCHASE before SALE if same date
             ph.serial_number;
END;
$$;


ALTER FUNCTION public.item_transaction_history(p_item_name text) OWNER TO postgres;

--
-- Name: item_transaction_history(text, date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.item_transaction_history(p_item_name text, p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date) RETURNS TABLE(item_name text, serial_number text, transaction_date date, transaction_type text, counterparty text, price numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH purchase_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            p.invoice_date AS transaction_date,
            'PURCHASE'::TEXT AS transaction_type,
            v.party_name::TEXT AS counterparty,
            pi.unit_price AS price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
        JOIN Parties v ON p.vendor_id = v.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
          AND (p_from_date IS NULL OR p.invoice_date >= p_from_date)
          AND (p_to_date IS NULL OR p.invoice_date <= p_to_date)
    ),
    sale_history AS (
        SELECT 
            i.item_id,
            i.item_name::TEXT AS item_name,
            pu.serial_number::TEXT AS serial_number,
            s.invoice_date AS transaction_date,
            'SALE'::TEXT AS transaction_type,
            c.party_name::TEXT AS counterparty,
            su.sold_price AS price
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        JOIN Parties c ON s.customer_id = c.party_id
        WHERE i.item_name ILIKE ('%' || p_item_name || '%')
          AND (p_from_date IS NULL OR s.invoice_date >= p_from_date)
          AND (p_to_date IS NULL OR s.invoice_date <= p_to_date)
    )
    SELECT 
        ph.item_name,
        ph.serial_number,
        ph.transaction_date,
        ph.transaction_type,
        ph.counterparty,
        ph.price
    FROM (
        SELECT * FROM purchase_history
        UNION ALL
        SELECT * FROM sale_history
    ) AS ph
    ORDER BY ph.transaction_date, 
             ph.transaction_type DESC,   -- ensures PURCHASE before SALE if same date
             ph.serial_number;
END;
$$;


ALTER FUNCTION public.item_transaction_history(p_item_name text, p_from_date date, p_to_date date) OWNER TO postgres;

--
-- Name: make_payment(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.make_payment(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id   BIGINT;
    v_account_id BIGINT;
    v_amount     NUMERIC(14,2);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_id         BIGINT;
BEGIN
    -- Extract
    v_amount    := (p_data->>'amount')::NUMERIC;
    v_method    := p_data->>'method';
    v_reference := p_data->>'reference_no';
    v_desc      := p_data->>'description';
    v_date      := NULLIF(p_data->>'payment_date','')::DATE;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    -- Get Vendor
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_data->>'party_name'
    LIMIT 1;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Vendor % not found', p_data->>'party_name';
    END IF;

    -- Always Cash for now
    SELECT account_id INTO v_account_id
    FROM ChartOfAccounts
    WHERE account_name = 'Cash';

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found';
    END IF;

    -- Auto ref
    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'PMT-' || nextval('payments_ref_seq');
    END IF;

    -- Insert (use given date or default CURRENT_DATE)
    INSERT INTO Payments(party_id, account_id, amount, method, reference_no, description, payment_date)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference, v_desc, COALESCE(v_date, CURRENT_DATE))
    RETURNING payment_id INTO v_id;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment created successfully',
        'payment_id',v_id
    );
END;
$$;


ALTER FUNCTION public.make_payment(p_data jsonb) OWNER TO postgres;

--
-- Name: make_receipt(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.make_receipt(p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_party_id   BIGINT;
    v_account_id BIGINT;
    v_amount     NUMERIC(14,2);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_id         BIGINT;
BEGIN
    -- Extract
    v_amount    := (p_data->>'amount')::NUMERIC;
    v_method    := p_data->>'method';
    v_reference := p_data->>'reference_no';
    v_desc      := p_data->>'description';
    v_date      := NULLIF(p_data->>'receipt_date','')::DATE;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    -- Get Customer
    SELECT party_id INTO v_party_id
    FROM Parties
    WHERE party_name = p_data->>'party_name'
    LIMIT 1;

    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Customer % not found', p_data->>'party_name';
    END IF;

    -- Always Cash for now
    SELECT account_id INTO v_account_id
    FROM ChartOfAccounts
    WHERE account_name = 'Cash';

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found';
    END IF;

    -- Auto ref
    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'RCT-' || nextval('receipts_ref_seq');
    END IF;

    -- Insert
    INSERT INTO Receipts(party_id, account_id, amount, method, reference_no, description, receipt_date)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference, v_desc, COALESCE(v_date, CURRENT_DATE))
    RETURNING receipt_id INTO v_id;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt created successfully',
        'receipt_id',v_id
    );
END;
$$;


ALTER FUNCTION public.make_receipt(p_data jsonb) OWNER TO postgres;

--
-- Name: rebuild_purchase_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rebuild_purchase_journal(p_invoice_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
BEGIN
    -- 1. Remove old journal if exists
    SELECT journal_id INTO j_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id;

    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 2. Get accounts
    SELECT account_id INTO inv_acc FROM ChartOfAccounts WHERE account_name='Inventory';
    SELECT ap_account_id INTO party_acc FROM Parties p
    JOIN PurchaseInvoices pi ON pi.vendor_id = p.party_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    -- 3. Get invoice total
    SELECT total_amount INTO v_total
    FROM PurchaseInvoices WHERE purchase_invoice_id = p_invoice_id;

    -- 4. Insert new journal entry
    INSERT INTO JournalEntries(entry_date, description)
    SELECT invoice_date, 'Purchase Invoice ' || purchase_invoice_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id = p_invoice_id
    RETURNING journal_id INTO j_id;

    -- 5. Update invoice with new journal_id
    UPDATE PurchaseInvoices
    SET journal_id = j_id
    WHERE purchase_invoice_id = p_invoice_id;

    -- 6. Debit Inventory
    INSERT INTO JournalLines(journal_id, account_id, debit)
    VALUES (j_id, inv_acc, v_total);

    -- 7. Credit Vendor (AP)
    INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
    VALUES (j_id, party_acc, (
        SELECT vendor_id FROM PurchaseInvoices WHERE purchase_invoice_id = p_invoice_id
    ), v_total);
END;
$$;


ALTER FUNCTION public.rebuild_purchase_journal(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: rebuild_purchase_return_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rebuild_purchase_return_journal(p_return_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    inv_acc BIGINT;
    party_acc BIGINT;
    v_total NUMERIC(14,2);
    v_vendor_id BIGINT;
    v_date DATE;
BEGIN
    -- 1. Remove old journal if exists
    SELECT journal_id INTO j_id 
    FROM PurchaseReturns 
    WHERE purchase_return_id = p_return_id;

    IF j_id IS NOT NULL THEN
        DELETE FROM JournalEntries WHERE journal_id = j_id;
    END IF;

    -- 2. Get totals
    SELECT vendor_id, total_amount, return_date
    INTO v_vendor_id, v_total, v_date
    FROM PurchaseReturns 
    WHERE purchase_return_id = p_return_id;

    -- 3. Accounts
    SELECT account_id INTO inv_acc 
    FROM ChartOfAccounts 
    WHERE account_name='Inventory';

    SELECT ap_account_id INTO party_acc 
    FROM Parties 
    WHERE party_id = v_vendor_id;

    -- 4. New journal
    INSERT INTO JournalEntries(entry_date, description)
    VALUES (v_date, 'Purchase Return ' || p_return_id)
    RETURNING journal_id INTO j_id;

    UPDATE PurchaseReturns 
    SET journal_id = j_id 
    WHERE purchase_return_id = p_return_id;

    -- 5. Journal lines (with conditions)
    -- (1) Debit Vendor (reduce AP balance)
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
        VALUES (j_id, party_acc, v_vendor_id, v_total);
    END IF;

    -- (2) Credit Inventory (stock reduced)
    IF v_total > 0 THEN
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, inv_acc, v_total);
    END IF;
END;
$$;


ALTER FUNCTION public.rebuild_purchase_return_journal(p_return_id bigint) OWNER TO postgres;

--
-- Name: rebuild_sales_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.rebuild_sales_journal(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: rebuild_sales_return_journal(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.rebuild_sales_return_journal(p_return_id bigint) OWNER TO postgres;

--
-- Name: sale_wise_profit(date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sale_wise_profit(p_from_date date, p_to_date date) RETURNS TABLE(sale_date date, serial_number text, item_name text, sale_price numeric, purchase_price numeric, profit_loss numeric, profit_loss_percent numeric, vendor_name text, purchase_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH sold_serials AS (
        SELECT 
            su.sold_unit_id,
            su.sold_price,
            pu.serial_number::TEXT AS serial_number,
            si.sales_item_id,
            s.sales_invoice_id,
            s.invoice_date AS sale_date,
            i.item_name::TEXT AS item_name,
            i.item_code,
            i.brand,
            i.category,
            si.item_id
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        WHERE s.invoice_date BETWEEN p_from_date AND p_to_date
    ),
    purchased_serials AS (
        SELECT 
            pu.unit_id,
            pu.serial_number::TEXT AS serial_number,
            pi.purchase_item_id,
            p.purchase_invoice_id,
            p.invoice_date AS purchase_date,
            p.vendor_id,
            i.item_id,
            i.item_name::TEXT AS item_name,
            pi.unit_price AS purchase_price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
    )
    SELECT 
        ss.sale_date,
        ss.serial_number,
        ss.item_name,
        ss.sold_price AS sale_price,
        ps.purchase_price,
        ROUND(ss.sold_price - ps.purchase_price, 2) AS profit_loss,
        CASE 
            WHEN ps.purchase_price > 0 THEN ROUND(((ss.sold_price - ps.purchase_price) / ps.purchase_price) * 100, 2)
            ELSE NULL
        END AS profit_loss_percent,
        v.party_name::TEXT AS vendor_name,
        ps.purchase_date
    FROM sold_serials ss
    LEFT JOIN purchased_serials ps 
        ON ss.serial_number = ps.serial_number
    LEFT JOIN Parties v 
        ON ps.vendor_id = v.party_id
    ORDER BY ss.sale_date, ss.item_name, ss.serial_number;
END;
$$;


ALTER FUNCTION public.sale_wise_profit(p_from_date date, p_to_date date) OWNER TO postgres;

--
-- Name: serial_exists_in_purchase_return(bigint, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.serial_exists_in_purchase_return(p_purchase_return_id bigint, p_serial_number text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT TRUE
    INTO v_exists
    FROM PurchaseReturnItems
    WHERE purchase_return_id = p_purchase_return_id
      AND serial_number = p_serial_number
    LIMIT 1;

    RETURN COALESCE(v_exists, FALSE);
END;
$$;


ALTER FUNCTION public.serial_exists_in_purchase_return(p_purchase_return_id bigint, p_serial_number text) OWNER TO postgres;

--
-- Name: serial_exists_in_sales_return(bigint, text); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.serial_exists_in_sales_return(p_sales_return_id bigint, p_serial_number text) OWNER TO postgres;

--
-- Name: trg_party_opening_balance(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_party_opening_balance() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    debit_acc BIGINT;
    credit_acc BIGINT;
    cap_acc BIGINT;
BEGIN
    IF NEW.opening_balance > 0 THEN
        -- Owner's Capital account
        SELECT account_id INTO cap_acc 
        FROM ChartOfAccounts 
        WHERE account_name = 'Owner''s Capital';

        IF cap_acc IS NULL THEN
            RAISE EXCEPTION 'Owner''s Capital account not found in COA';
        END IF;

        -- Create a new Journal Entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (CURRENT_DATE, 'Opening Balance for ' || NEW.party_name)
        RETURNING journal_id INTO j_id;

        -- ---------------------------
        -- CUSTOMER or BOTH
        -- ---------------------------
        IF NEW.party_type IN ('Customer','Both') AND NEW.balance_type = 'Debit' THEN
            debit_acc := NEW.ar_account_id;
            credit_acc := cap_acc;

            INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
            VALUES (j_id, debit_acc, NEW.party_id, NEW.opening_balance);

            INSERT INTO JournalLines(journal_id, account_id, credit)
            VALUES (j_id, credit_acc, NEW.opening_balance);
        END IF;

        -- ---------------------------
        -- VENDOR or BOTH
        -- ---------------------------
        IF NEW.party_type IN ('Vendor','Both') AND NEW.balance_type = 'Credit' THEN
            debit_acc := cap_acc;
            credit_acc := NEW.ap_account_id;

            INSERT INTO JournalLines(journal_id, account_id, debit)
            VALUES (j_id, debit_acc, NEW.opening_balance);

            INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
            VALUES (j_id, credit_acc, NEW.party_id, NEW.opening_balance);
        END IF;

        -- ---------------------------
        -- EXPENSE PARTY
        -- ---------------------------
        IF NEW.party_type = 'Expense' THEN
            debit_acc := NEW.ap_account_id;  -- Expense account
            credit_acc := cap_acc;           -- Funded by Owner's Capital

            INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
            VALUES (j_id, debit_acc, NEW.party_id, NEW.opening_balance);

            INSERT INTO JournalLines(journal_id, account_id, credit)
            VALUES (j_id, credit_acc, NEW.opening_balance);
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_party_opening_balance() OWNER TO postgres;

--
-- Name: trg_payment_journal(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_payment_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    party_acc BIGINT;
    v_party_name  TEXT;
    journal_desc TEXT;
BEGIN
    -- Handle DELETE: remove related journal
    IF TG_OP = 'DELETE' THEN
        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
        RETURN OLD;
    END IF;

    -- Handle UPDATE: only regenerate if relevant fields changed
    IF TG_OP = 'UPDATE' THEN
        IF OLD.amount = NEW.amount
           AND OLD.account_id = NEW.account_id
           AND OLD.party_id = NEW.party_id
           AND OLD.description IS NOT DISTINCT FROM NEW.description
           AND OLD.payment_date = NEW.payment_date THEN
            RETURN NEW;
        END IF;

        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
    END IF;

    -- Handle INSERT or UPDATE
    IF TG_OP IN ('INSERT','UPDATE') THEN
        -- Find AP account for vendor
        SELECT ap_account_id, p.party_name
        INTO party_acc, v_party_name
        FROM Parties AS p
        WHERE party_id = NEW.party_id;

        IF party_acc IS NULL THEN
            RAISE EXCEPTION 'No AP account found for vendor %', NEW.party_id;
        END IF;

        -- Description: custom if provided, else fallback with ref no
        journal_desc := COALESCE(
            NEW.description,
            'Payment to ' || v_party_name ||
            CASE WHEN NEW.reference_no IS NOT NULL AND NEW.reference_no <> '' 
                 THEN ' (Ref: ' || NEW.reference_no || ')'
                 ELSE '' END
        );

        -- Insert Journal Entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (NEW.payment_date, journal_desc)
        RETURNING journal_id INTO j_id;

        -- Prevent recursion when linking back
        PERFORM pg_catalog.set_config('session_replication_role', 'replica', true);
        UPDATE Payments
        SET journal_id = j_id
        WHERE payment_id = NEW.payment_id;
        PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);

        -- Debit Vendor (reduce liability)
        INSERT INTO JournalLines(journal_id, account_id, party_id, debit)
        VALUES (j_id, party_acc, NEW.party_id, NEW.amount);

        -- Credit Cash/Bank
        INSERT INTO JournalLines(journal_id, account_id, credit)
        VALUES (j_id, NEW.account_id, NEW.amount);
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_payment_journal() OWNER TO postgres;

--
-- Name: trg_receipt_journal(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_receipt_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    j_id BIGINT;
    party_acc BIGINT;
    v_party_name  TEXT;
    journal_desc TEXT;
BEGIN
    -- Handle DELETE: remove related journal
    IF TG_OP = 'DELETE' THEN
        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
        RETURN OLD;
    END IF;

    -- Handle UPDATE: only regenerate if relevant fields changed
    IF TG_OP = 'UPDATE' THEN
        IF OLD.amount = NEW.amount
           AND OLD.account_id = NEW.account_id
           AND OLD.party_id = NEW.party_id
           AND OLD.description IS NOT DISTINCT FROM NEW.description
           AND OLD.receipt_date = NEW.receipt_date THEN
            RETURN NEW;
        END IF;

        DELETE FROM JournalEntries WHERE journal_id = OLD.journal_id;
    END IF;

    -- Handle INSERT or UPDATE
    IF TG_OP IN ('INSERT','UPDATE') THEN
        -- Find AR account for customer
        SELECT ar_account_id, p.party_name
        INTO party_acc, v_party_name
        FROM Parties AS p
        WHERE party_id = NEW.party_id;

        IF party_acc IS NULL THEN
            RAISE EXCEPTION 'No AR account found for customer %', NEW.party_id;
        END IF;

        -- Description: custom if provided, else fallback with ref no
        journal_desc := COALESCE(
            NEW.description,
            'Receipt from ' || v_party_name ||
            CASE WHEN NEW.reference_no IS NOT NULL AND NEW.reference_no <> '' 
                 THEN ' (Ref: ' || NEW.reference_no || ')'
                 ELSE '' END
        );

        -- Insert Journal Entry
        INSERT INTO JournalEntries(entry_date, description)
        VALUES (NEW.receipt_date, journal_desc)
        RETURNING journal_id INTO j_id;

        -- Prevent recursion when linking back
        PERFORM pg_catalog.set_config('session_replication_role', 'replica', true);
        UPDATE Receipts
        SET journal_id = j_id
        WHERE receipt_id = NEW.receipt_id;
        PERFORM pg_catalog.set_config('session_replication_role', 'origin', true);

        -- Debit Cash/Bank (increase asset)
        INSERT INTO JournalLines(journal_id, account_id, debit)
        VALUES (j_id, NEW.account_id, NEW.amount);

        -- Credit Customer (reduce receivable)
        INSERT INTO JournalLines(journal_id, account_id, party_id, credit)
        VALUES (j_id, party_acc, NEW.party_id, NEW.amount);
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_receipt_journal() OWNER TO postgres;

--
-- Name: update_item_from_json(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_item_from_json(item_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE Items
    SET
        item_name   = COALESCE(item_data->>'item_name', item_name),
        storage     = COALESCE(item_data->>'storage', storage),
        sale_price  = COALESCE(NULLIF(item_data->>'sale_price','')::NUMERIC, sale_price),
        item_code   = COALESCE(NULLIF(item_data->>'item_code',''), item_code),
        category    = COALESCE(NULLIF(item_data->>'category',''), category),
        brand       = COALESCE(NULLIF(item_data->>'brand',''), brand),
        updated_at  = NOW()
    WHERE item_id = (item_data->>'item_id')::BIGINT;
END;
$$;


ALTER FUNCTION public.update_item_from_json(item_data jsonb) OWNER TO postgres;

--
-- Name: update_party_from_json(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.update_party_from_json(p_id bigint, party_data jsonb) OWNER TO postgres;

--
-- Name: update_payment(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_payment(p_payment_id bigint, p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_amount    NUMERIC(14,2);
    v_method    TEXT;
    v_reference TEXT;
    v_desc      TEXT;
    v_date      DATE;
    v_party_id  BIGINT;
    v_updated   RECORD;
BEGIN
    v_amount    := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method    := NULLIF(p_data->>'method','');
    v_reference := NULLIF(p_data->>'reference_no','');
    v_desc      := NULLIF(p_data->>'description','');
    v_date      := NULLIF(p_data->>'payment_date','')::DATE;

    IF p_data ? 'party_name' THEN
        SELECT party_id INTO v_party_id
        FROM Parties
        WHERE party_name = p_data->>'party_name'
        LIMIT 1;
        IF v_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor % not found', p_data->>'party_name';
        END IF;
    END IF;

    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount';
    END IF;

    UPDATE Payments
    SET amount       = COALESCE(v_amount, amount),
        method       = COALESCE(v_method, method),
        reference_no = COALESCE(v_reference, reference_no),
        party_id     = COALESCE(v_party_id, party_id),
        description  = COALESCE(v_desc, description),
        payment_date = COALESCE(v_date, payment_date)
    WHERE payment_id = p_payment_id
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Payment updated successfully',
        'payment', to_jsonb(v_updated)
    );
END;
$$;


ALTER FUNCTION public.update_payment(p_payment_id bigint, p_data jsonb) OWNER TO postgres;

--
-- Name: update_purchase_invoice(bigint, jsonb, text, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text DEFAULT NULL::text, p_invoice_date date DEFAULT NULL::date) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_purchase_item_id BIGINT;
    v_serial TEXT;
    v_new_party_id BIGINT;
BEGIN
    -- ========================================================
    -- 1️⃣ Update Party (Vendor) if given
    -- ========================================================
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties
        WHERE party_name = p_party_name
        LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor "%" not found in Parties table.', p_party_name;
        END IF;

        UPDATE PurchaseInvoices
        SET vendor_id = v_new_party_id
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 2️⃣ Update Invoice Date (if provided)
    -- ========================================================
    IF p_invoice_date IS NOT NULL THEN
        UPDATE PurchaseInvoices
        SET invoice_date = p_invoice_date
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- ========================================================
    -- 3️⃣ Delete old items + stock movements
    -- ========================================================
    DELETE FROM StockMovements 
    WHERE reference_type = 'PurchaseInvoice' AND reference_id = p_invoice_id;

    DELETE FROM PurchaseUnits 
    WHERE purchase_item_id IN (
        SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id
    );

    DELETE FROM PurchaseItems 
    WHERE purchase_invoice_id = p_invoice_id;

    -- ========================================================
    -- 4️⃣ Insert updated items and serials
    -- ========================================================
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Get or create item
        SELECT item_id INTO v_item_id FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (
            p_invoice_id,
            v_item_id,
            (v_item->>'qty')::INT,
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Insert serials and stock movements
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- ========================================================
    -- 5️⃣ Update total in Purchase Invoice
    -- ========================================================
    UPDATE PurchaseInvoices
    SET total_amount = v_total
    WHERE purchase_invoice_id = p_invoice_id;

    -- ========================================================
    -- 6️⃣ Rebuild journal entry (refreshes vendor + date)
    -- ========================================================
    PERFORM rebuild_purchase_journal(p_invoice_id);

END;
$$;


ALTER FUNCTION public.update_purchase_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text, p_invoice_date date) OWNER TO postgres;

--
-- Name: update_purchase_items(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_purchase_item_id BIGINT;
    v_serial TEXT;
BEGIN
    -- Remove old stock + items
    DELETE FROM StockMovements WHERE reference_type = 'PurchaseInvoice' AND reference_id = p_invoice_id;
    DELETE FROM PurchaseUnits WHERE purchase_item_id IN (SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id);
    DELETE FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id;

    -- Insert new items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve or create item
        SELECT item_id INTO v_item_id FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (p_invoice_id, v_item_id, (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Units + Stock IN
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- Update invoice total
    UPDATE PurchaseInvoices SET total_amount = v_total WHERE purchase_invoice_id = p_invoice_id;

    -- 🔑 Rebuild journal manually
    PERFORM rebuild_purchase_journal(p_invoice_id);
END;
$$;


ALTER FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb) OWNER TO postgres;

--
-- Name: update_purchase_items(bigint, jsonb, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb, p_party_name text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_item JSONB;
    v_item_id BIGINT;
    v_total NUMERIC(14,2) := 0;
    v_purchase_item_id BIGINT;
    v_serial TEXT;
    v_new_party_id BIGINT;
BEGIN
    -- ✅ If a new party name is provided, update vendor
    IF p_party_name IS NOT NULL THEN
        SELECT party_id INTO v_new_party_id
        FROM Parties
        WHERE party_name = p_party_name
        LIMIT 1;

        IF v_new_party_id IS NULL THEN
            RAISE EXCEPTION 'Vendor "%" not found in Parties table.', p_party_name;
        END IF;

        UPDATE PurchaseInvoices
        SET vendor_id = v_new_party_id
        WHERE purchase_invoice_id = p_invoice_id;
    END IF;

    -- Remove old stock + items
    DELETE FROM StockMovements WHERE reference_type = 'PurchaseInvoice' AND reference_id = p_invoice_id;
    DELETE FROM PurchaseUnits WHERE purchase_item_id IN (SELECT purchase_item_id FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id);
    DELETE FROM PurchaseItems WHERE purchase_invoice_id = p_invoice_id;

    -- Insert new items
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Resolve or create item
        SELECT item_id INTO v_item_id FROM Items WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (p_invoice_id, v_item_id, (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Total
        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        -- Units + Stock IN
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
            VALUES (v_purchase_item_id, v_serial, TRUE);

            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
        END LOOP;
    END LOOP;

    -- Update invoice total
    UPDATE PurchaseInvoices SET total_amount = v_total WHERE purchase_invoice_id = p_invoice_id;

    -- 🔑 Rebuild journal manually (to reflect new vendor)
    PERFORM rebuild_purchase_journal(p_invoice_id);
END;
$$;


ALTER FUNCTION public.update_purchase_items(p_invoice_id bigint, p_items jsonb, p_party_name text) OWNER TO postgres;

--
-- Name: update_purchase_return(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_purchase_return(p_return_id bigint, p_serials jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
    v_serial TEXT;
    v_unit RECORD;
    v_total NUMERIC(14,2) := 0;
    v_vendor_id BIGINT;
BEGIN
    -- 1. Get vendor id from return header
    SELECT vendor_id INTO v_vendor_id
    FROM PurchaseReturns
    WHERE purchase_return_id = p_return_id;

    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Purchase Return % not found', p_return_id;
    END IF;

    -- 2. Reverse old items (restore stock)
    FOR rec IN
        SELECT serial_number, item_id
        FROM PurchaseReturnItems
        WHERE purchase_return_id = p_return_id
    LOOP
        UPDATE PurchaseUnits
        SET in_stock = TRUE
        WHERE serial_number = rec.serial_number;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'PurchaseReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    -- 3. Remove old items
    DELETE FROM PurchaseReturnItems WHERE purchase_return_id = p_return_id;

    -- 4. Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.serial_number, pi.item_id, pi.unit_price, p.vendor_id
        INTO v_unit
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
        END IF;

        -- check if in stock
        IF NOT EXISTS (
            SELECT 1 FROM PurchaseUnits WHERE unit_id = v_unit.unit_id AND in_stock = TRUE
        ) THEN
            RAISE EXCEPTION 'Serial % is not currently in stock', v_serial;
        END IF;

        -- check vendor match
        IF v_unit.vendor_id <> v_vendor_id THEN
            RAISE EXCEPTION 'Serial % was purchased from a different vendor', v_serial;
        END IF;

        -- mark as returned (out of stock)
        UPDATE PurchaseUnits 
        SET in_stock = FALSE 
        WHERE unit_id = v_unit.unit_id;

        -- log stock OUT
        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'OUT', 'PurchaseReturn-Update', p_return_id, 1);

        -- insert return line (✅ unit_price instead of cost_price)
        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (p_return_id, v_unit.item_id, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.unit_price;
    END LOOP;

    -- 5. Update header total
    UPDATE PurchaseReturns
    SET total_amount = v_total
    WHERE purchase_return_id = p_return_id;

    -- 6. Rebuild journal
    PERFORM rebuild_purchase_return_journal(p_return_id);
END;
$$;


ALTER FUNCTION public.update_purchase_return(p_return_id bigint, p_serials jsonb) OWNER TO postgres;

--
-- Name: update_receipt(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_receipt(p_receipt_id bigint, p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_amount    NUMERIC(14,2);
    v_method    TEXT;
    v_reference TEXT;
    v_desc      TEXT;
    v_date      DATE;
    v_party_id  BIGINT;
    v_updated   RECORD;
BEGIN
    v_amount    := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method    := NULLIF(p_data->>'method','');
    v_reference := NULLIF(p_data->>'reference_no','');
    v_desc      := NULLIF(p_data->>'description','');
    v_date      := NULLIF(p_data->>'receipt_date','')::DATE;

    IF p_data ? 'party_name' THEN
        SELECT party_id INTO v_party_id
        FROM Parties
        WHERE party_name = p_data->>'party_name'
        LIMIT 1;
        IF v_party_id IS NULL THEN
            RAISE EXCEPTION 'Customer % not found', p_data->>'party_name';
        END IF;
    END IF;

    IF v_amount IS NOT NULL AND v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount';
    END IF;

    UPDATE Receipts
    SET amount       = COALESCE(v_amount, amount),
        method       = COALESCE(v_method, method),
        reference_no = COALESCE(v_reference, reference_no),
        party_id     = COALESCE(v_party_id, party_id),
        description  = COALESCE(v_desc, description),
        receipt_date = COALESCE(v_date, receipt_date)
    WHERE receipt_id = p_receipt_id
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt ID % not found', p_receipt_id;
    END IF;

    RETURN jsonb_build_object(
        'status','success',
        'message','Receipt updated successfully',
        'receipt', to_jsonb(v_updated)
    );
END;
$$;


ALTER FUNCTION public.update_receipt(p_receipt_id bigint, p_data jsonb) OWNER TO postgres;

--
-- Name: update_sale_invoice(bigint, jsonb, text, date); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.update_sale_invoice(p_invoice_id bigint, p_items jsonb, p_party_name text, p_invoice_date date) OWNER TO postgres;

--
-- Name: update_sale_return(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.update_sale_return(p_return_id bigint, p_serials jsonb) OWNER TO postgres;

--
-- Name: validate_purchase_delete(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_purchase_delete(p_invoice_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_serials TEXT[];
    v_sold_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serial numbers from this purchase invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_invoice_serials
    FROM PurchaseUnits pu
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

    IF v_invoice_serials IS NULL THEN
        v_invoice_serials := ARRAY[]::TEXT[];
    END IF;

    -- 2️⃣ Check if any of these serials are sold
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_sold_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    WHERE pu.serial_number = ANY(v_invoice_serials);

    IF v_sold_serials IS NULL THEN
        v_sold_serials := ARRAY[]::TEXT[];
    END IF;

    -- 3️⃣ Check if any of these serials are already returned to vendor
    SELECT ARRAY_AGG(pri.serial_number)
    INTO v_returned_serials
    FROM PurchaseReturnItems pri
    WHERE pri.serial_number = ANY(v_invoice_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 4️⃣ If any sold or returned serials exist, prevent deletion
    IF array_length(v_sold_serials, 1) IS NOT NULL
       OR array_length(v_returned_serials, 1) IS NOT NULL THEN

        v_message := '❌ Purchase Invoice ' || p_invoice_id || ' cannot be deleted.';

        IF array_length(v_sold_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_sold_serials, 1) || ' sold serial(s) found.';
        END IF;

        IF array_length(v_returned_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_returned_serials, 1) || ' returned serial(s) found.';
        END IF;

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'sold_serials', v_sold_serials,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 5️⃣ Otherwise, safe to delete
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to delete — no sold or returned serials found in this invoice.',
        'sold_serials', v_sold_serials,
        'returned_serials', v_returned_serials
    );
END;
$$;


ALTER FUNCTION public.validate_purchase_delete(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: validate_purchase_update(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_purchase_update(p_invoice_id bigint, p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existing_serials TEXT[];
    v_new_serials TEXT[];
    v_removed_serials TEXT[];
    v_sold_serials TEXT[];
    v_returned_serials TEXT[];
    v_message TEXT;
BEGIN
    -- 1️⃣ Get all serials currently in this purchase invoice
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_existing_serials
    FROM PurchaseUnits pu
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    WHERE pi.purchase_invoice_id = p_invoice_id;

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

    -- 4️⃣ Check if removed serials are sold
    SELECT ARRAY_AGG(pu.serial_number)
    INTO v_sold_serials
    FROM SoldUnits su
    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
    WHERE pu.serial_number = ANY(v_removed_serials);

    IF v_sold_serials IS NULL THEN
        v_sold_serials := ARRAY[]::TEXT[];
    END IF;

    -- 5️⃣ Check if removed serials are already returned to vendor
    SELECT ARRAY_AGG(pri.serial_number)
    INTO v_returned_serials
    FROM PurchaseReturnItems pri
    WHERE pri.serial_number = ANY(v_removed_serials);

    IF v_returned_serials IS NULL THEN
        v_returned_serials := ARRAY[]::TEXT[];
    END IF;

    -- 6️⃣ If any conflicts found, return descriptive message
    IF array_length(v_sold_serials, 1) IS NOT NULL
       OR array_length(v_returned_serials, 1) IS NOT NULL THEN

        v_message := '❌ Some serials cannot be removed.';

        IF array_length(v_sold_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_sold_serials, 1) || ' sold serial(s) found.';
        END IF;

        IF array_length(v_returned_serials, 1) IS NOT NULL THEN
            v_message := v_message || ' ' || array_length(v_returned_serials, 1) || ' returned serial(s) found.';
        END IF;

        RETURN jsonb_build_object(
            'is_valid', FALSE,
            'message', v_message,
            'sold_serials', v_sold_serials,
            'returned_serials', v_returned_serials
        );
    END IF;

    -- 7️⃣ Otherwise, all safe
    RETURN jsonb_build_object(
        'is_valid', TRUE,
        'message', '✅ Safe to update — no sold or returned serials will be removed.',
        'sold_serials', v_sold_serials,
        'returned_serials', v_returned_serials
    );
END;
$$;


ALTER FUNCTION public.validate_purchase_update(p_invoice_id bigint, p_items jsonb) OWNER TO postgres;

--
-- Name: validate_sales_delete(bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.validate_sales_delete(p_invoice_id bigint) OWNER TO postgres;

--
-- Name: validate_sales_update(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION public.validate_sales_update(p_invoice_id bigint, p_items jsonb) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: auth_group; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_group (
    id integer NOT NULL,
    name character varying(150) NOT NULL
);


ALTER TABLE public.auth_group OWNER TO postgres;

--
-- Name: auth_group_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_group ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_group_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_group_permissions (
    id bigint NOT NULL,
    group_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.auth_group_permissions OWNER TO postgres;

--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_group_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_group_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_permission; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_permission (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    content_type_id integer NOT NULL,
    codename character varying(100) NOT NULL
);


ALTER TABLE public.auth_permission OWNER TO postgres;

--
-- Name: auth_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_permission ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user (
    id integer NOT NULL,
    password character varying(128) NOT NULL,
    last_login timestamp with time zone,
    is_superuser boolean NOT NULL,
    username character varying(150) NOT NULL,
    first_name character varying(150) NOT NULL,
    last_name character varying(150) NOT NULL,
    email character varying(254) NOT NULL,
    is_staff boolean NOT NULL,
    is_active boolean NOT NULL,
    date_joined timestamp with time zone NOT NULL
);


ALTER TABLE public.auth_user OWNER TO postgres;

--
-- Name: auth_user_groups; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user_groups (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    group_id integer NOT NULL
);


ALTER TABLE public.auth_user_groups OWNER TO postgres;

--
-- Name: auth_user_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user_groups ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_user_user_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.auth_user_user_permissions (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.auth_user_user_permissions OWNER TO postgres;

--
-- Name: auth_user_user_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.auth_user_user_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.auth_user_user_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: chartofaccounts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.chartofaccounts (
    account_id bigint NOT NULL,
    account_code character varying(20) NOT NULL,
    account_name character varying(150) NOT NULL,
    account_type character varying(20) NOT NULL,
    parent_account bigint,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chartofaccounts_account_type_check CHECK (((account_type)::text = ANY (ARRAY[('Asset'::character varying)::text, ('Liability'::character varying)::text, ('Equity'::character varying)::text, ('Revenue'::character varying)::text, ('Expense'::character varying)::text])))
);


ALTER TABLE public.chartofaccounts OWNER TO postgres;

--
-- Name: chartofaccounts_account_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.chartofaccounts_account_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.chartofaccounts_account_id_seq OWNER TO postgres;

--
-- Name: chartofaccounts_account_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.chartofaccounts_account_id_seq OWNED BY public.chartofaccounts.account_id;


--
-- Name: django_admin_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_admin_log (
    id integer NOT NULL,
    action_time timestamp with time zone NOT NULL,
    object_id text,
    object_repr character varying(200) NOT NULL,
    action_flag smallint NOT NULL,
    change_message text NOT NULL,
    content_type_id integer,
    user_id integer NOT NULL,
    CONSTRAINT django_admin_log_action_flag_check CHECK ((action_flag >= 0))
);


ALTER TABLE public.django_admin_log OWNER TO postgres;

--
-- Name: django_admin_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_admin_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_admin_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_content_type; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_content_type (
    id integer NOT NULL,
    app_label character varying(100) NOT NULL,
    model character varying(100) NOT NULL
);


ALTER TABLE public.django_content_type OWNER TO postgres;

--
-- Name: django_content_type_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_content_type ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_content_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_migrations (
    id bigint NOT NULL,
    app character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    applied timestamp with time zone NOT NULL
);


ALTER TABLE public.django_migrations OWNER TO postgres;

--
-- Name: django_migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.django_migrations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.django_migrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: django_session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.django_session (
    session_key character varying(40) NOT NULL,
    session_data text NOT NULL,
    expire_date timestamp with time zone NOT NULL
);


ALTER TABLE public.django_session OWNER TO postgres;

--
-- Name: journalentries; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.journalentries (
    journal_id bigint NOT NULL,
    entry_date date DEFAULT CURRENT_DATE NOT NULL,
    description text,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.journalentries OWNER TO postgres;

--
-- Name: journallines; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.journallines (
    line_id bigint NOT NULL,
    journal_id bigint NOT NULL,
    account_id bigint NOT NULL,
    party_id bigint,
    debit numeric(14,2) DEFAULT 0,
    credit numeric(14,2) DEFAULT 0,
    CONSTRAINT journallines_check CHECK (((debit >= (0)::numeric) AND (credit >= (0)::numeric))),
    CONSTRAINT journallines_check1 CHECK ((NOT ((debit = (0)::numeric) AND (credit = (0)::numeric))))
);


ALTER TABLE public.journallines OWNER TO postgres;

--
-- Name: generalledger; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.generalledger AS
 SELECT jl.line_id AS gl_entry_id,
    je.journal_id,
    je.entry_date,
    jl.account_id,
    jl.party_id,
    jl.debit,
    jl.credit,
    je.description
   FROM (public.journallines jl
     JOIN public.journalentries je ON ((jl.journal_id = je.journal_id)));


ALTER VIEW public.generalledger OWNER TO postgres;

--
-- Name: items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.items (
    item_id bigint NOT NULL,
    item_name character varying(150) NOT NULL,
    storage character varying(100),
    sale_price numeric(12,2) DEFAULT 0.00 NOT NULL,
    item_code character varying(50),
    category character varying(100),
    brand character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.items OWNER TO postgres;

--
-- Name: parties; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.parties (
    party_id bigint NOT NULL,
    party_name character varying(150) NOT NULL,
    party_type character varying(20) NOT NULL,
    contact_info character varying(50),
    address text,
    ar_account_id bigint,
    ap_account_id bigint,
    opening_balance numeric(14,2) DEFAULT 0,
    balance_type character varying(10) DEFAULT 'Debit'::character varying,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT parties_balance_type_check CHECK (((balance_type)::text = ANY (ARRAY[('Debit'::character varying)::text, ('Credit'::character varying)::text]))),
    CONSTRAINT parties_party_type_check CHECK (((party_type)::text = ANY (ARRAY[('Customer'::character varying)::text, ('Vendor'::character varying)::text, ('Both'::character varying)::text, ('Expense'::character varying)::text])))
);


ALTER TABLE public.parties OWNER TO postgres;

--
-- Name: purchaseinvoices; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchaseinvoices (
    purchase_invoice_id bigint NOT NULL,
    vendor_id bigint NOT NULL,
    invoice_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) NOT NULL,
    journal_id bigint
);


ALTER TABLE public.purchaseinvoices OWNER TO postgres;

--
-- Name: purchaseitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchaseitems (
    purchase_item_id bigint NOT NULL,
    purchase_invoice_id bigint NOT NULL,
    item_id bigint NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    CONSTRAINT purchaseitems_quantity_check CHECK ((quantity > 0))
);


ALTER TABLE public.purchaseitems OWNER TO postgres;

--
-- Name: purchaseunits; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchaseunits (
    unit_id bigint NOT NULL,
    purchase_item_id bigint NOT NULL,
    serial_number character varying(100) NOT NULL,
    in_stock boolean DEFAULT true
);


ALTER TABLE public.purchaseunits OWNER TO postgres;

--
-- Name: salesinvoices; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesinvoices (
    sales_invoice_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    invoice_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) NOT NULL,
    journal_id bigint
);


ALTER TABLE public.salesinvoices OWNER TO postgres;

--
-- Name: salesitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesitems (
    sales_item_id bigint NOT NULL,
    sales_invoice_id bigint NOT NULL,
    item_id bigint NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    CONSTRAINT salesitems_quantity_check CHECK ((quantity > 0))
);


ALTER TABLE public.salesitems OWNER TO postgres;

--
-- Name: soldunits; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.soldunits (
    sold_unit_id bigint NOT NULL,
    sales_item_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    sold_price numeric(12,2) NOT NULL,
    status character varying(20) DEFAULT 'Sold'::character varying,
    CONSTRAINT soldunits_status_check CHECK (((status)::text = ANY (ARRAY[('Sold'::character varying)::text, ('Returned'::character varying)::text, ('Damaged'::character varying)::text])))
);


ALTER TABLE public.soldunits OWNER TO postgres;

--
-- Name: item_history_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.item_history_view AS
 WITH purchase_history AS (
         SELECT i.item_id,
            i.item_name,
            pu.serial_number,
            p.invoice_date AS transaction_date,
            'PURCHASE'::text AS transaction_type,
            v.party_name AS counterparty,
            pi.unit_price AS price
           FROM ((((public.purchaseunits pu
             JOIN public.purchaseitems pi ON ((pu.purchase_item_id = pi.purchase_item_id)))
             JOIN public.purchaseinvoices p ON ((pi.purchase_invoice_id = p.purchase_invoice_id)))
             JOIN public.items i ON ((pi.item_id = i.item_id)))
             JOIN public.parties v ON ((p.vendor_id = v.party_id)))
          WHERE ((i.item_name)::text ~~* '%iPhone 15 Pro%'::text)
        ), sale_history AS (
         SELECT i.item_id,
            i.item_name,
            pu.serial_number,
            s.invoice_date AS transaction_date,
            'SALE'::text AS transaction_type,
            c.party_name AS counterparty,
            su.sold_price AS price
           FROM (((((public.soldunits su
             JOIN public.purchaseunits pu ON ((su.unit_id = pu.unit_id)))
             JOIN public.salesitems si ON ((su.sales_item_id = si.sales_item_id)))
             JOIN public.salesinvoices s ON ((si.sales_invoice_id = s.sales_invoice_id)))
             JOIN public.items i ON ((si.item_id = i.item_id)))
             JOIN public.parties c ON ((s.customer_id = c.party_id)))
          WHERE ((i.item_name)::text ~~* '%iPhone 15 Pro%'::text)
        )
 SELECT item_name,
    serial_number,
    transaction_date,
    transaction_type,
    counterparty,
    price
   FROM ( SELECT purchase_history.item_id,
            purchase_history.item_name,
            purchase_history.serial_number,
            purchase_history.transaction_date,
            purchase_history.transaction_type,
            purchase_history.counterparty,
            purchase_history.price
           FROM purchase_history
        UNION ALL
         SELECT sale_history.item_id,
            sale_history.item_name,
            sale_history.serial_number,
            sale_history.transaction_date,
            sale_history.transaction_type,
            sale_history.counterparty,
            sale_history.price
           FROM sale_history) combined
  ORDER BY transaction_date, transaction_type DESC, serial_number;


ALTER VIEW public.item_history_view OWNER TO postgres;

--
-- Name: items_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.items_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.items_item_id_seq OWNER TO postgres;

--
-- Name: items_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.items_item_id_seq OWNED BY public.items.item_id;


--
-- Name: journalentries_journal_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.journalentries_journal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.journalentries_journal_id_seq OWNER TO postgres;

--
-- Name: journalentries_journal_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.journalentries_journal_id_seq OWNED BY public.journalentries.journal_id;


--
-- Name: journallines_line_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.journallines_line_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.journallines_line_id_seq OWNER TO postgres;

--
-- Name: journallines_line_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.journallines_line_id_seq OWNED BY public.journallines.line_id;


--
-- Name: parties_party_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.parties_party_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.parties_party_id_seq OWNER TO postgres;

--
-- Name: parties_party_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.parties_party_id_seq OWNED BY public.parties.party_id;


--
-- Name: payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payments (
    payment_id bigint NOT NULL,
    party_id bigint NOT NULL,
    account_id bigint NOT NULL,
    amount numeric(14,2) NOT NULL,
    payment_date date DEFAULT CURRENT_DATE NOT NULL,
    method character varying(20),
    reference_no character varying(100),
    journal_id bigint,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    notes text,
    description text,
    CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payments_method_check CHECK (((method)::text = ANY (ARRAY[('Cash'::character varying)::text, ('Bank'::character varying)::text, ('Cheque'::character varying)::text, ('Online'::character varying)::text])))
);


ALTER TABLE public.payments OWNER TO postgres;

--
-- Name: payments_payment_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.payments_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.payments_payment_id_seq OWNER TO postgres;

--
-- Name: payments_payment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.payments_payment_id_seq OWNED BY public.payments.payment_id;


--
-- Name: payments_ref_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.payments_ref_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.payments_ref_seq OWNER TO postgres;

--
-- Name: purchaseinvoices_purchase_invoice_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchaseinvoices_purchase_invoice_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchaseinvoices_purchase_invoice_id_seq OWNER TO postgres;

--
-- Name: purchaseinvoices_purchase_invoice_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchaseinvoices_purchase_invoice_id_seq OWNED BY public.purchaseinvoices.purchase_invoice_id;


--
-- Name: purchaseitems_purchase_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchaseitems_purchase_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchaseitems_purchase_item_id_seq OWNER TO postgres;

--
-- Name: purchaseitems_purchase_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchaseitems_purchase_item_id_seq OWNED BY public.purchaseitems.purchase_item_id;


--
-- Name: purchasereturnitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchasereturnitems (
    return_item_id bigint NOT NULL,
    purchase_return_id bigint NOT NULL,
    item_id bigint NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    serial_number character varying(100) NOT NULL
);


ALTER TABLE public.purchasereturnitems OWNER TO postgres;

--
-- Name: purchasereturnitems_return_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchasereturnitems_return_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchasereturnitems_return_item_id_seq OWNER TO postgres;

--
-- Name: purchasereturnitems_return_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchasereturnitems_return_item_id_seq OWNED BY public.purchasereturnitems.return_item_id;


--
-- Name: purchasereturns; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchasereturns (
    purchase_return_id bigint NOT NULL,
    vendor_id bigint NOT NULL,
    return_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) DEFAULT 0 NOT NULL,
    journal_id bigint
);


ALTER TABLE public.purchasereturns OWNER TO postgres;

--
-- Name: purchasereturns_purchase_return_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchasereturns_purchase_return_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchasereturns_purchase_return_id_seq OWNER TO postgres;

--
-- Name: purchasereturns_purchase_return_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchasereturns_purchase_return_id_seq OWNED BY public.purchasereturns.purchase_return_id;


--
-- Name: purchaseunits_unit_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchaseunits_unit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchaseunits_unit_id_seq OWNER TO postgres;

--
-- Name: purchaseunits_unit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchaseunits_unit_id_seq OWNED BY public.purchaseunits.unit_id;


--
-- Name: receipts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.receipts (
    receipt_id bigint NOT NULL,
    party_id bigint NOT NULL,
    account_id bigint NOT NULL,
    amount numeric(14,2) NOT NULL,
    receipt_date date DEFAULT CURRENT_DATE NOT NULL,
    method character varying(20),
    reference_no character varying(100),
    journal_id bigint,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    notes text,
    description text,
    CONSTRAINT receipts_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT receipts_method_check CHECK (((method)::text = ANY (ARRAY[('Cash'::character varying)::text, ('Bank'::character varying)::text, ('Cheque'::character varying)::text, ('Online'::character varying)::text])))
);


ALTER TABLE public.receipts OWNER TO postgres;

--
-- Name: receipts_receipt_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.receipts_receipt_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.receipts_receipt_id_seq OWNER TO postgres;

--
-- Name: receipts_receipt_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.receipts_receipt_id_seq OWNED BY public.receipts.receipt_id;


--
-- Name: receipts_ref_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.receipts_ref_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.receipts_ref_seq OWNER TO postgres;

--
-- Name: sale_wise_profit_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.sale_wise_profit_view AS
 WITH sold_serials AS (
         SELECT su.sold_unit_id,
            su.sold_price,
            pu.serial_number,
            si.sales_item_id,
            s.sales_invoice_id,
            s.invoice_date AS sale_date,
            i.item_name,
            i.item_code,
            i.brand,
            i.category,
            si.item_id
           FROM ((((public.soldunits su
             JOIN public.purchaseunits pu ON ((su.unit_id = pu.unit_id)))
             JOIN public.salesitems si ON ((su.sales_item_id = si.sales_item_id)))
             JOIN public.salesinvoices s ON ((si.sales_invoice_id = s.sales_invoice_id)))
             JOIN public.items i ON ((si.item_id = i.item_id)))
          WHERE ((s.invoice_date >= '2025-10-17'::date) AND (s.invoice_date <= '2025-10-31'::date))
        ), purchased_serials AS (
         SELECT pu.unit_id,
            pu.serial_number,
            pi.purchase_item_id,
            p.purchase_invoice_id,
            p.invoice_date AS purchase_date,
            p.vendor_id,
            i.item_id,
            i.item_name,
            pi.unit_price AS purchase_price
           FROM (((public.purchaseunits pu
             JOIN public.purchaseitems pi ON ((pu.purchase_item_id = pi.purchase_item_id)))
             JOIN public.purchaseinvoices p ON ((pi.purchase_invoice_id = p.purchase_invoice_id)))
             JOIN public.items i ON ((pi.item_id = i.item_id)))
        )
 SELECT ss.sale_date,
    ss.serial_number,
    ss.item_name,
    ss.sold_price AS sale_price,
    ps.purchase_price,
    round((ss.sold_price - ps.purchase_price), 2) AS profit_loss,
        CASE
            WHEN (ps.purchase_price > (0)::numeric) THEN round((((ss.sold_price - ps.purchase_price) / ps.purchase_price) * (100)::numeric), 2)
            ELSE NULL::numeric
        END AS profit_loss_percent,
    v.party_name AS vendor_name,
    ps.purchase_date
   FROM ((sold_serials ss
     LEFT JOIN purchased_serials ps ON (((ss.serial_number)::text = (ps.serial_number)::text)))
     LEFT JOIN public.parties v ON ((ps.vendor_id = v.party_id)))
  ORDER BY ss.sale_date, ss.item_name, ss.serial_number;


ALTER VIEW public.sale_wise_profit_view OWNER TO postgres;

--
-- Name: salesinvoices_sales_invoice_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesinvoices_sales_invoice_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesinvoices_sales_invoice_id_seq OWNER TO postgres;

--
-- Name: salesinvoices_sales_invoice_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesinvoices_sales_invoice_id_seq OWNED BY public.salesinvoices.sales_invoice_id;


--
-- Name: salesitems_sales_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesitems_sales_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesitems_sales_item_id_seq OWNER TO postgres;

--
-- Name: salesitems_sales_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesitems_sales_item_id_seq OWNED BY public.salesitems.sales_item_id;


--
-- Name: salesreturnitems; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesreturnitems (
    return_item_id bigint NOT NULL,
    sales_return_id bigint NOT NULL,
    item_id bigint NOT NULL,
    sold_price numeric(12,2) NOT NULL,
    cost_price numeric(12,2) NOT NULL,
    serial_number character varying(100) NOT NULL
);


ALTER TABLE public.salesreturnitems OWNER TO postgres;

--
-- Name: salesreturnitems_return_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesreturnitems_return_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesreturnitems_return_item_id_seq OWNER TO postgres;

--
-- Name: salesreturnitems_return_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesreturnitems_return_item_id_seq OWNED BY public.salesreturnitems.return_item_id;


--
-- Name: salesreturns; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salesreturns (
    sales_return_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    return_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) DEFAULT 0 NOT NULL,
    journal_id bigint
);


ALTER TABLE public.salesreturns OWNER TO postgres;

--
-- Name: salesreturns_sales_return_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salesreturns_sales_return_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salesreturns_sales_return_id_seq OWNER TO postgres;

--
-- Name: salesreturns_sales_return_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salesreturns_sales_return_id_seq OWNED BY public.salesreturns.sales_return_id;


--
-- Name: soldunits_sold_unit_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.soldunits_sold_unit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.soldunits_sold_unit_id_seq OWNER TO postgres;

--
-- Name: soldunits_sold_unit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.soldunits_sold_unit_id_seq OWNED BY public.soldunits.sold_unit_id;


--
-- Name: standing_company_worth_view; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.standing_company_worth_view AS
 WITH journal_summary AS (
         SELECT jl.account_id,
            jl.party_id,
            COALESCE(sum(jl.debit), (0)::numeric) AS debit,
            COALESCE(sum(jl.credit), (0)::numeric) AS credit
           FROM public.journallines jl
          GROUP BY jl.account_id, jl.party_id
        ), account_totals AS (
         SELECT coa.account_id,
            coa.account_code,
            coa.account_name,
            coa.account_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit
           FROM (public.chartofaccounts coa
             LEFT JOIN journal_summary js ON (((coa.account_id = js.account_id) AND (((coa.account_name)::text = ANY (ARRAY[('Accounts Receivable'::character varying)::text, ('Accounts Payable'::character varying)::text])) OR (js.party_id IS NULL)))))
          WHERE (NOT (coa.account_id IN ( SELECT DISTINCT p.ap_account_id
                   FROM public.parties p
                  WHERE (((p.party_type)::text = 'Expense'::text) AND (p.ap_account_id IS NOT NULL)))))
          GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
        ), party_totals AS (
         SELECT p.party_id,
            p.party_name,
            p.party_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit,
            (COALESCE(sum(js.debit), (0)::numeric) - COALESCE(sum(js.credit), (0)::numeric)) AS balance
           FROM (public.parties p
             LEFT JOIN journal_summary js ON ((js.party_id = p.party_id)))
          GROUP BY p.party_id, p.party_name, p.party_type
        ), classified_parties AS (
         SELECT pt.party_id,
            pt.party_name,
            pt.party_type,
            pt.total_debit,
            pt.total_credit,
            pt.balance,
                CASE
                    WHEN (((pt.party_type)::text = 'Customer'::text) AND (pt.balance < (0)::numeric)) THEN 'Accounts Payable'::text
                    WHEN (((pt.party_type)::text = 'Vendor'::text) AND (pt.balance > (0)::numeric)) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Both'::text) THEN
                    CASE
                        WHEN (pt.balance >= (0)::numeric) THEN 'Accounts Receivable'::text
                        ELSE 'Accounts Payable'::text
                    END
                    WHEN ((pt.party_type)::text = 'Customer'::text) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Vendor'::text) THEN 'Accounts Payable'::text
                    ELSE 'Expense Party'::text
                END AS effective_type
           FROM party_totals pt
        ), control_adjustment AS (
         SELECT classified_parties.effective_type AS account_name,
            sum(GREATEST(classified_parties.balance, (0)::numeric)) AS debit_side,
            sum(abs(LEAST(classified_parties.balance, (0)::numeric))) AS credit_side
           FROM classified_parties
          WHERE (classified_parties.effective_type = ANY (ARRAY['Accounts Receivable'::text, 'Accounts Payable'::text]))
          GROUP BY classified_parties.effective_type
        ), merged_totals AS (
         SELECT coa.account_type,
                CASE
                    WHEN ((coa.account_type)::text = ANY (ARRAY[('Asset'::character varying)::text, ('Expense'::character varying)::text])) THEN (COALESCE(ca.debit_side, at.total_debit, (0)::numeric) - COALESCE(ca.credit_side, at.total_credit, (0)::numeric))
                    WHEN ((coa.account_type)::text = ANY (ARRAY[('Liability'::character varying)::text, ('Equity'::character varying)::text, ('Revenue'::character varying)::text])) THEN (COALESCE(ca.credit_side, at.total_credit, (0)::numeric) - COALESCE(ca.debit_side, at.total_debit, (0)::numeric))
                    ELSE (0)::numeric
                END AS net_balance
           FROM ((account_totals at
             JOIN public.chartofaccounts coa ON ((at.account_id = coa.account_id)))
             LEFT JOIN control_adjustment ca ON ((ca.account_name = (coa.account_name)::text)))
        ), summary AS (
         SELECT merged_totals.account_type,
            sum(merged_totals.net_balance) AS total
           FROM merged_totals
          GROUP BY merged_totals.account_type
        ), party_expenses AS (
         SELECT sum(classified_parties.balance) AS total_party_expenses
           FROM classified_parties
          WHERE (classified_parties.effective_type = 'Expense Party'::text)
        ), totals AS (
         SELECT COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Asset'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS assets,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Liability'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS liabilities,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Equity'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS equity,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Revenue'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS revenue,
            (COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Expense'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) + COALESCE(( SELECT party_expenses.total_party_expenses
                   FROM party_expenses), (0)::numeric)) AS expenses
           FROM summary
        )
 SELECT json_build_object('financial_position', json_build_object('total_assets', round(assets, 2), 'total_liabilities', round(liabilities, 2), 'total_equity', round(equity, 2), 'net_worth', round((assets - liabilities), 2)), 'profit_and_loss', json_build_object('total_revenue', round(revenue, 2), 'total_expenses', round(expenses, 2), 'net_profit_loss', round((revenue - expenses), 2))) AS company_standing
   FROM totals;


ALTER VIEW public.standing_company_worth_view OWNER TO postgres;

--
-- Name: stock_report; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.stock_report AS
 WITH stock AS (
         SELECT i.item_id,
            i.item_name,
            count(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
            pu.serial_number,
            row_number() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
           FROM ((public.purchaseunits pu
             JOIN public.purchaseitems pit ON ((pu.purchase_item_id = pit.purchase_item_id)))
             JOIN public.items i ON ((pit.item_id = i.item_id)))
          WHERE (pu.in_stock = true)
        )
 SELECT
        CASE
            WHEN (rn = 1) THEN (item_id)::text
            ELSE ''::text
        END AS item_id,
        CASE
            WHEN (rn = 1) THEN item_name
            ELSE ''::character varying
        END AS item_name,
        CASE
            WHEN (rn = 1) THEN (quantity)::text
            ELSE ''::text
        END AS quantity,
    serial_number
   FROM stock
  ORDER BY ((item_id)::integer), rn;


ALTER VIEW public.stock_report OWNER TO postgres;

--
-- Name: stock_worth_report; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.stock_worth_report AS
 WITH stock AS (
         SELECT i.item_id,
            i.item_name,
            count(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
            pu.serial_number,
            pit.unit_price AS purchase_price,
            i.sale_price AS market_price,
            row_number() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
           FROM ((public.purchaseunits pu
             JOIN public.purchaseitems pit ON ((pu.purchase_item_id = pit.purchase_item_id)))
             JOIN public.items i ON ((pit.item_id = i.item_id)))
          WHERE (pu.in_stock = true)
        ), running AS (
         SELECT stock.item_id,
            stock.item_name,
            stock.quantity,
            stock.serial_number,
            stock.purchase_price,
            stock.market_price,
            sum(stock.purchase_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_purchase,
            sum(stock.market_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_market,
            stock.rn
           FROM stock
        )
 SELECT
        CASE
            WHEN (rn = 1) THEN (item_id)::text
            ELSE ''::text
        END AS item_id,
        CASE
            WHEN (rn = 1) THEN item_name
            ELSE ''::character varying
        END AS item_name,
        CASE
            WHEN (rn = 1) THEN (quantity)::text
            ELSE ''::text
        END AS quantity,
    serial_number,
    purchase_price,
    market_price,
    running_total_purchase,
    running_total_market
   FROM running
  ORDER BY ((item_id)::integer), rn;


ALTER VIEW public.stock_worth_report OWNER TO postgres;

--
-- Name: stockmovements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.stockmovements (
    movement_id bigint NOT NULL,
    item_id bigint NOT NULL,
    serial_number text,
    movement_type character varying(20) NOT NULL,
    reference_type character varying(50),
    reference_id bigint,
    movement_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    quantity integer NOT NULL,
    CONSTRAINT stockmovements_movement_type_check CHECK (((movement_type)::text = ANY (ARRAY[('IN'::character varying)::text, ('OUT'::character varying)::text])))
);


ALTER TABLE public.stockmovements OWNER TO postgres;

--
-- Name: stockmovements_movement_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.stockmovements_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.stockmovements_movement_id_seq OWNER TO postgres;

--
-- Name: stockmovements_movement_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.stockmovements_movement_id_seq OWNED BY public.stockmovements.movement_id;


--
-- Name: vw_trial_balance; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.vw_trial_balance AS
 WITH journal_summary AS (
         SELECT jl.account_id,
            jl.party_id,
            COALESCE(sum(jl.debit), (0)::numeric) AS debit,
            COALESCE(sum(jl.credit), (0)::numeric) AS credit
           FROM public.journallines jl
          GROUP BY jl.account_id, jl.party_id
        ), account_totals AS (
         SELECT coa.account_id,
            coa.account_code,
            coa.account_name,
            coa.account_type,
            sum(js.debit) AS total_debit,
            sum(js.credit) AS total_credit
           FROM (public.chartofaccounts coa
             LEFT JOIN journal_summary js ON (((coa.account_id = js.account_id) AND (((coa.account_name)::text = ANY (ARRAY[('Accounts Receivable'::character varying)::text, ('Accounts Payable'::character varying)::text])) OR (js.party_id IS NULL)))))
          WHERE (NOT (coa.account_id IN ( SELECT DISTINCT p.ap_account_id
                   FROM public.parties p
                  WHERE (((p.party_type)::text = 'Expense'::text) AND (p.ap_account_id IS NOT NULL)))))
          GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
        ), party_totals AS (
         SELECT p.party_id,
            p.party_name,
            p.party_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit,
            (COALESCE(sum(js.debit), (0)::numeric) - COALESCE(sum(js.credit), (0)::numeric)) AS balance
           FROM (public.parties p
             LEFT JOIN journal_summary js ON ((js.party_id = p.party_id)))
          GROUP BY p.party_id, p.party_name, p.party_type
        ), classified_parties AS (
         SELECT pt.party_id,
            pt.party_name,
            pt.party_type,
            pt.total_debit,
            pt.total_credit,
            pt.balance,
                CASE
                    WHEN (((pt.party_type)::text = 'Customer'::text) AND (pt.balance < (0)::numeric)) THEN 'Accounts Payable'::text
                    WHEN (((pt.party_type)::text = 'Vendor'::text) AND (pt.balance > (0)::numeric)) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Both'::text) THEN
                    CASE
                        WHEN (pt.balance >= (0)::numeric) THEN 'Accounts Receivable'::text
                        ELSE 'Accounts Payable'::text
                    END
                    WHEN ((pt.party_type)::text = 'Customer'::text) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Vendor'::text) THEN 'Accounts Payable'::text
                    ELSE 'Expense Party'::text
                END AS effective_type
           FROM party_totals pt
        ), control_adjustment AS (
         SELECT classified_parties.effective_type AS account_name,
            sum(GREATEST(classified_parties.balance, (0)::numeric)) AS debit_side,
            sum(abs(LEAST(classified_parties.balance, (0)::numeric))) AS credit_side
           FROM classified_parties
          WHERE (classified_parties.effective_type = ANY (ARRAY['Accounts Receivable'::text, 'Accounts Payable'::text]))
          GROUP BY classified_parties.effective_type
        )
 SELECT at.account_code AS code,
    at.account_name AS name,
    at.account_type AS type,
    COALESCE(ca.debit_side, at.total_debit, (0)::numeric) AS total_debit,
    COALESCE(ca.credit_side, at.total_credit, (0)::numeric) AS total_credit,
    (COALESCE(ca.debit_side, at.total_debit, (0)::numeric) - COALESCE(ca.credit_side, at.total_credit, (0)::numeric)) AS balance
   FROM (account_totals at
     LEFT JOIN control_adjustment ca ON ((ca.account_name = (at.account_name)::text)))
UNION ALL
 SELECT NULL::character varying AS code,
    pt.party_name AS name,
    pt.effective_type AS type,
    pt.total_debit,
    pt.total_credit,
    pt.balance
   FROM classified_parties pt
  WHERE ((pt.total_debit <> (0)::numeric) OR (pt.total_credit <> (0)::numeric))
  ORDER BY 1 NULLS FIRST, 2;


ALTER VIEW public.vw_trial_balance OWNER TO postgres;

--
-- Name: chartofaccounts account_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts ALTER COLUMN account_id SET DEFAULT nextval('public.chartofaccounts_account_id_seq'::regclass);


--
-- Name: items item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items ALTER COLUMN item_id SET DEFAULT nextval('public.items_item_id_seq'::regclass);


--
-- Name: journalentries journal_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journalentries ALTER COLUMN journal_id SET DEFAULT nextval('public.journalentries_journal_id_seq'::regclass);


--
-- Name: journallines line_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines ALTER COLUMN line_id SET DEFAULT nextval('public.journallines_line_id_seq'::regclass);


--
-- Name: parties party_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties ALTER COLUMN party_id SET DEFAULT nextval('public.parties_party_id_seq'::regclass);


--
-- Name: payments payment_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments ALTER COLUMN payment_id SET DEFAULT nextval('public.payments_payment_id_seq'::regclass);


--
-- Name: purchaseinvoices purchase_invoice_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices ALTER COLUMN purchase_invoice_id SET DEFAULT nextval('public.purchaseinvoices_purchase_invoice_id_seq'::regclass);


--
-- Name: purchaseitems purchase_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems ALTER COLUMN purchase_item_id SET DEFAULT nextval('public.purchaseitems_purchase_item_id_seq'::regclass);


--
-- Name: purchasereturnitems return_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems ALTER COLUMN return_item_id SET DEFAULT nextval('public.purchasereturnitems_return_item_id_seq'::regclass);


--
-- Name: purchasereturns purchase_return_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns ALTER COLUMN purchase_return_id SET DEFAULT nextval('public.purchasereturns_purchase_return_id_seq'::regclass);


--
-- Name: purchaseunits unit_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits ALTER COLUMN unit_id SET DEFAULT nextval('public.purchaseunits_unit_id_seq'::regclass);


--
-- Name: receipts receipt_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts ALTER COLUMN receipt_id SET DEFAULT nextval('public.receipts_receipt_id_seq'::regclass);


--
-- Name: salesinvoices sales_invoice_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices ALTER COLUMN sales_invoice_id SET DEFAULT nextval('public.salesinvoices_sales_invoice_id_seq'::regclass);


--
-- Name: salesitems sales_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems ALTER COLUMN sales_item_id SET DEFAULT nextval('public.salesitems_sales_item_id_seq'::regclass);


--
-- Name: salesreturnitems return_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems ALTER COLUMN return_item_id SET DEFAULT nextval('public.salesreturnitems_return_item_id_seq'::regclass);


--
-- Name: salesreturns sales_return_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns ALTER COLUMN sales_return_id SET DEFAULT nextval('public.salesreturns_sales_return_id_seq'::regclass);


--
-- Name: soldunits sold_unit_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits ALTER COLUMN sold_unit_id SET DEFAULT nextval('public.soldunits_sold_unit_id_seq'::regclass);


--
-- Name: stockmovements movement_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stockmovements ALTER COLUMN movement_id SET DEFAULT nextval('public.stockmovements_movement_id_seq'::regclass);


--
-- Data for Name: auth_group; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_group (id, name) FROM stdin;
1	view_only_users
\.


--
-- Data for Name: auth_group_permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_group_permissions (id, group_id, permission_id) FROM stdin;
\.


--
-- Data for Name: auth_permission; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_permission (id, name, content_type_id, codename) FROM stdin;
1	Can add log entry	1	add_logentry
2	Can change log entry	1	change_logentry
3	Can delete log entry	1	delete_logentry
4	Can view log entry	1	view_logentry
5	Can add permission	3	add_permission
6	Can change permission	3	change_permission
7	Can delete permission	3	delete_permission
8	Can view permission	3	view_permission
9	Can add group	2	add_group
10	Can change group	2	change_group
11	Can delete group	2	delete_group
12	Can view group	2	view_group
13	Can add user	4	add_user
14	Can change user	4	change_user
15	Can delete user	4	delete_user
16	Can view user	4	view_user
17	Can add content type	5	add_contenttype
18	Can change content type	5	change_contenttype
19	Can delete content type	5	delete_contenttype
20	Can view content type	5	view_contenttype
21	Can add session	6	add_session
22	Can change session	6	change_session
23	Can delete session	6	delete_session
24	Can view session	6	view_session
\.


--
-- Data for Name: auth_user; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_user (id, password, last_login, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined) FROM stdin;
1	pbkdf2_sha256$1200000$RXhGhMVbAN430kGibRWclp$0bFixmZrJQUORkd30ou1uNsx/1vRuA7fHI83CR9zly0=	2025-12-09 14:28:39.695832+00	t	financee_admin				t	t	2025-12-09 14:12:23.026824+00
2	pbkdf2_sha256$1200000$BUJHK6vNtJlrCuMQpstztc$hWijcN9qC3RkpbTTqWPI18AYSAtPiAy/+mpMc2M0TUs=	2026-01-04 14:41:11.404302+00	f	saqib				f	t	2025-12-09 14:31:16.44303+00
3	pbkdf2_sha256$1200000$mvVrQ0Eu8HeBIySSNm2PBw$yT7x2mFdxxqDhCVgHyqlnc/O/fLbJo5Imf5i2fHkhtA=	2026-01-07 12:49:23.75953+00	f	dubaiOffice				f	t	2025-12-09 14:35:42+00
\.


--
-- Data for Name: auth_user_groups; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_user_groups (id, user_id, group_id) FROM stdin;
1	3	1
\.


--
-- Data for Name: auth_user_user_permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.auth_user_user_permissions (id, user_id, permission_id) FROM stdin;
\.


--
-- Data for Name: chartofaccounts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.chartofaccounts (account_id, account_code, account_name, account_type, parent_account, date_created) FROM stdin;
1	2000	Accounts Payable	Liability	\N	2025-12-09 14:18:14.47586
2	3000	Owner's Capital	Equity	\N	2025-12-09 14:18:14.478347
3	4000	Sales Revenue	Revenue	\N	2025-12-09 14:18:14.479575
4	5000	Cost of Goods Sold	Expense	\N	2025-12-09 14:18:14.480735
5	1000	Cash	Asset	\N	2025-12-09 14:21:31.913409
6	1200	Accounts Receivable	Asset	\N	2025-12-09 14:21:31.913409
7	1400	Inventory	Asset	\N	2025-12-09 14:21:31.913409
17	3001	Opening Balance	Equity	\N	2026-01-05 16:32:54.927355
18	EXP-0002	AUSTRALIA OFFICE EXP	Expense	\N	2026-01-06 13:05:00.164473
19	EXP-0003	COMMISSION CHARGES	Expense	\N	2026-01-06 13:11:11.562331
20	EXP-0004	DISCOUNT	Expense	\N	2026-01-06 13:12:24.902304
21	EXP-0005	GST REFUND	Expense	\N	2026-01-06 13:19:16.39704
22	EXP-0006	KARACHI OFFICE EXPENSE	Expense	\N	2026-01-06 13:26:30.047226
23	EXP-0007	LABELS PROFIT	Expense	\N	2026-01-06 13:28:08.81782
24	EXP-0008	LOSS AC	Expense	\N	2026-01-06 13:29:55.462716
25	EXP-0009	DUBAI OFFICE EXPENSE	Expense	\N	2026-01-06 14:02:20.765197
26	EXP-0010	NEWZEALAND EXPENSE	Expense	\N	2026-01-06 14:05:38.324886
27	EXP-0011	SALARY EXP	Expense	\N	2026-01-06 14:14:11.064508
28	EXP-0012	USA EXP	Expense	\N	2026-01-06 14:30:45.115368
\.


--
-- Data for Name: django_admin_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_admin_log (id, action_time, object_id, object_repr, action_flag, change_message, content_type_id, user_id) FROM stdin;
1	2025-12-09 14:29:18.489428+00	1	view_only_users	1	[{"added": {}}]	2	1
2	2025-12-09 14:31:17.452744+00	2	saqib	1	[{"added": {}}]	4	1
3	2025-12-09 14:35:43.457174+00	3	dubaiOffice	1	[{"added": {}}]	4	1
4	2025-12-09 14:36:03.114181+00	3	dubaiOffice	2	[{"changed": {"fields": ["Groups"]}}]	4	1
\.


--
-- Data for Name: django_content_type; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_content_type (id, app_label, model) FROM stdin;
1	admin	logentry
2	auth	group
3	auth	permission
4	auth	user
5	contenttypes	contenttype
6	sessions	session
\.


--
-- Data for Name: django_migrations; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_migrations (id, app, name, applied) FROM stdin;
1	contenttypes	0001_initial	2025-12-09 14:11:05.291535+00
2	auth	0001_initial	2025-12-09 14:11:05.400142+00
3	admin	0001_initial	2025-12-09 14:11:05.450774+00
4	admin	0002_logentry_remove_auto_add	2025-12-09 14:11:05.458359+00
5	admin	0003_logentry_add_action_flag_choices	2025-12-09 14:11:05.466011+00
6	contenttypes	0002_remove_content_type_name	2025-12-09 14:11:05.48093+00
7	auth	0002_alter_permission_name_max_length	2025-12-09 14:11:05.489533+00
8	auth	0003_alter_user_email_max_length	2025-12-09 14:11:05.49789+00
9	auth	0004_alter_user_username_opts	2025-12-09 14:11:05.505418+00
10	auth	0005_alter_user_last_login_null	2025-12-09 14:11:05.515102+00
11	auth	0006_require_contenttypes_0002	2025-12-09 14:11:05.517146+00
12	auth	0007_alter_validators_add_error_messages	2025-12-09 14:11:05.524532+00
13	auth	0008_alter_user_username_max_length	2025-12-09 14:11:05.537983+00
14	auth	0009_alter_user_last_name_max_length	2025-12-09 14:11:05.546726+00
15	auth	0010_alter_group_name_max_length	2025-12-09 14:11:05.555501+00
16	auth	0011_update_proxy_permissions	2025-12-09 14:11:05.562354+00
17	auth	0012_alter_user_first_name_max_length	2025-12-09 14:11:05.570731+00
18	sessions	0001_initial	2025-12-09 14:11:05.5912+00
\.


--
-- Data for Name: django_session; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.django_session (session_key, session_data, expire_date) FROM stdin;
1up5w3niqp078xdx276k97dia5xw5g7x	.eJxVjEEOwiAQRe_C2pABCi0u3fcMZIYZbNXQpLQr491Nky50-997_60S7tuU9iZrmlldlVGX340wP6UegB9Y74vOS93WmfSh6JM2PS4sr9vp_h1M2KajJsjiBwc0uD7GUrrIPVsHGQQBQxkMBUfeW0RXuhA5ZgYjJQfbkXj1-QLwJzhf:1vSyhj:K33PVH_7EVJgi1Fg0JgQ_MheICS6PgaEY_eX-4pAz0I	2025-12-23 14:28:39.698208+00
cusvv0zy2ll2elmuncd4ppa3ky88ain0	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vSypk:7aHf8XMyMVD7ByNtZSKoAN7hvyLp554P9q4Y-9dxAds	2025-12-23 14:36:56.397601+00
59gb23ubf8bw9h4kdvtsktvc8www5g5a	.eJxVjMsOgjAUBf-la9NA6YO4dO83NPdVi5o2obAi_ruQsNDtmZmzqQjrkuPaZI4Tq6sy6vK7IdBLygH4CeVRNdWyzBPqQ9EnbfpeWd630_07yNDyXqdB7CA0ovQ4Wk8sBrwjFwKgQZdAKHQBxIPx5Mj03jLvZuJkOwdBfb4VyTkc:1vT3Sx:yKt5Ljl2IQjcS__pi6Uh2OQl1gZ2PdO9ZRw1NIXS8TQ	2025-12-23 19:33:43.624304+00
xkpkwdr9ap6hfwqnxora1nnilctzjlca	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vU49n:ExUAJNtWKHT-RyX72kP0-OFgoL1NBf7IEJulVIvn7y4	2025-12-26 14:30:07.021419+00
bb4jy77wbhedpuyi2xq9l6wh09usafh0	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vU5rx:asrCIEXwhyrngfjCUNvz18KpLqEPabhUshge2LInPoA	2025-12-26 16:19:49.078938+00
kz6dqf8w22uzqcov2h9oz8vhxnccvdn5	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vV6Ea:j8mNWRVYSL68Cze4PehDfXnVJkgKyE-quDkl7Sw5coM	2025-12-29 10:55:20.662494+00
1pq8zp5s9ox5r3cdxa02d6y8n1v6t5sz	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vVrVf:6F_NvU96nncCgskpc7nr6yF5NqSEGipeAt1gzauHQJA	2025-12-31 13:24:07.819811+00
iwtkj7fahx2t19jlw32tr7tty6w9ycra	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vWxhX:zgMINi8tIDHGZJRg0Ys68ybl2FqtDfwG6FK-22dFt00	2026-01-03 14:12:55.506729+00
dunoo8c7rug625v357dx2hwn2kumiizt	.eJxVjMsOgjAUBf-la9NA6YO4dO83NPdVi5o2obAi_ruQsNDtmZmzqQjrkuPaZI4Tq6sy6vK7IdBLygH4CeVRNdWyzBPqQ9EnbfpeWd630_07yNDyXqdB7CA0ovQ4Wk8sBrwjFwKgQZdAKHQBxIPx5Mj03jLvZuJkOwdBfb4VyTkc:1vcPI7:RfejKS5LGBgbRZ92NKp5iWTD0jnSkO26pwJgH0_Q7aQ	2026-01-18 14:41:11.406645+00
n8bqm9sgevlwjfwtgq8qrk7rqvwubs1q	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vd04N:7nYPsI6kvCNz5PUOZzyc0FyxOH4qkPDFQLs2ZLEQjqE	2026-01-20 05:57:27.903997+00
l2hjk9u8e6pvnp15ls82mw8au9u7a1r9	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vd5MQ:C-5jhYVbVb2TLx_BKUaA6542DsgcSKLrdxX2Ee6AdiU	2026-01-20 11:36:26.045304+00
6xumg4g41i513wgbjb5rtsgogcwvpuzq	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vdSyZ:183EfxftcId3RMpodd4RjQahctV5rOKc055Um9YRg8Y	2026-01-21 12:49:23.761949+00
\.


--
-- Data for Name: items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.items (item_id, item_name, storage, sale_price, item_code, category, brand, created_at, updated_at) FROM stdin;
1	STARLINK V4		1280.00	\N	Wifi Router	Starlink	2026-01-04 14:46:26.083183	2026-01-04 14:46:26.083183
2	PS5 SLIM DISC		1625.00	\N	Gaming Console	Sony	2026-01-04 14:47:25.238361	2026-01-04 14:47:25.238361
3	PS5 SLIM DIGITAL		1450.00	\N	Gaming Console	Sony	2026-01-04 14:47:49.047798	2026-01-04 14:47:49.047798
4	PS5 DUAL SENSE CONTROLLER		195.00	\N	Gaming Controller	Sony	2026-01-04 14:48:12.769261	2026-01-04 14:48:12.769261
5	PLAYSTATION VR2		1650.00	\N	VR	Sony	2026-01-04 14:48:43.955896	2026-01-04 14:48:43.955896
6	DJI MINI 5 PRO FLY MORE COMBO 52 MINS		3520.00	\N	Drone	DJI	2026-01-04 14:49:30.511458	2026-01-04 14:49:30.511458
7	DJI MAVIC 4 PRO CREATOR COMBO		11400.00	\N	Drone	DJI	2026-01-04 14:50:02.063501	2026-01-04 14:50:02.063501
8	DJI MAVIC 4 PRO FLY MORE COMBO		8200.00	\N	Drone	DJI	2026-01-04 14:50:27.642539	2026-01-04 14:50:27.642539
9	DJI MINI 4 PRO STANDARD		6250.00	\N	Drone	DJI	2026-01-04 14:50:47.356058	2026-01-04 14:50:47.356058
10	DJI MINI 4 PRO 45 MINS		3100.00	\N	Drone	DJI	2026-01-04 14:51:06.605046	2026-01-04 14:51:06.605046
11	DJI MINI 4 PRO 34 MINS		2750.00	\N	Drone	DJI	2026-01-04 14:51:24.111342	2026-01-04 14:51:24.111342
12	DJI MINI 4K FLY MORE COMBO		0.00	\N	Drone	DJI	2026-01-04 14:51:38.807765	2026-01-04 14:51:38.807765
13	DJI OSMO POCKET 3		1730.00	\N	Camera	DJI	2026-01-04 14:52:10.03496	2026-01-04 14:52:10.03496
14	DJI MIC 3		0.00	\N	Mic	DJI	2026-01-04 14:52:23.402468	2026-01-04 14:52:23.402468
15	DJI MIC MINI		0.00	\N	Mic	DJI	2026-01-04 14:52:38.628084	2026-01-04 14:52:38.628084
16	NINTENDO SWITCH 2 MARIOKART		0.00	\N	Gaming Console	Nintendo	2026-01-04 14:53:38.377117	2026-01-04 14:53:38.377117
17	CANON G7X MARK III		3480.00	\N	Camera	Canon	2026-01-04 14:55:06.966417	2026-01-04 14:55:06.966417
18	CANON SX 740 HS		0.00	\N	Camera	Canon	2026-01-04 14:55:22.205642	2026-01-04 14:55:22.205642
19	INSTAX MINI EVO		0.00	\N	Camera	Instax	2026-01-04 14:55:43.160407	2026-01-04 14:55:43.160407
20	INSTAX FILM 20 PACK		0.00	\N	Camera film	Instax	2026-01-04 14:55:59.458046	2026-01-04 14:55:59.458046
21	NINJA SLUSHI		0.00	\N	Electronics Machine	Ninja	2026-01-04 14:56:20.219221	2026-01-04 14:56:20.219221
22	NINJA CREAMI		0.00	\N	Electronics Machine	Ninja	2026-01-04 14:56:38.085576	2026-01-04 14:56:38.085576
23	NINJA PORTABLE BLENDER		0.00	\N	Electronics Blender	Ninja	2026-01-04 14:56:58.893894	2026-01-04 14:56:58.893894
24	STARLINK HP		0.00	\N	Wifi Router	Starlink	2026-01-04 14:57:17.607055	2026-01-04 14:57:17.607055
25	META QUEST 3S		0.00	\N	VR	Meta	2026-01-04 14:58:16.698913	2026-01-04 14:58:16.698913
26	RAYBAN GLASSES		0.00	\N	Smart Glasses	Meta	2026-01-04 14:58:38.228849	2026-01-04 14:58:38.228849
27	PS5 PRO		0.00	\N	Gaming Console	Sony	2026-01-04 14:58:58.16595	2026-01-04 14:58:58.16595
28	PLAYSTATION PORTAL		0.00	\N	Gaming Console	Sony	2026-01-04 14:59:11.150659	2026-01-04 14:59:11.150659
29	PS5 CD DISCS		0.00	\N	Game CD	Sony	2026-01-04 14:59:29.817839	2026-01-04 14:59:29.817839
30	NINTENDO SWITCH 2		0.00	\N	Gaming Console	Nintendo	2026-01-04 14:59:54.1372	2026-01-04 14:59:54.1372
31	NINTENDO SWITCH REGULAR		0.00	\N	Gaming Console	Nintendo	2026-01-04 15:00:12.369644	2026-01-04 15:00:12.369644
32	CYBERPOWER PC SERIES C		0.00	\N	PC	CyberPower	2026-01-04 15:00:45.439234	2026-01-04 15:00:45.439234
33	BEATS PILL SPEAKER		0.00	\N	Speaker	Beats	2026-01-04 15:01:14.664	2026-01-04 15:01:14.664
34	BEATS POWERBEATS PRO BUDS		0.00	\N	Buds	Beats	2026-01-04 15:01:32.824316	2026-01-04 15:01:32.824316
35	BOSE QUIETCOMFORT ULTRA HEADPHONES 2		0.00	\N	Headphones	Bose	2026-01-04 15:01:50.593596	2026-01-04 15:01:50.593596
36	BOSE SOUNDLINK MICRO SPEAKER		0.00	\N	Speaker	Bose	2026-01-04 15:02:07.042939	2026-01-04 15:02:07.042939
37	GO PRO 13		0.00	\N	Camera	GoPro	2026-01-04 15:03:00.726515	2026-01-04 15:03:00.726515
38	GARMIN VIVOACTIVE 5 WATCH		0.00	\N	Watch	Garmin	2026-01-04 15:03:19.823961	2026-01-04 15:03:19.823961
39	XBOX SERIES X		0.00	\N	Gaming Console	Microsoft	2026-01-04 15:03:54.122081	2026-01-04 15:03:54.122081
40	META QUEST 3 512 GB		0.00	\N	VR	Meta	2026-01-04 15:04:11.860031	2026-01-04 15:04:11.860031
41	AIRPODS 4		0.00	\N	Airpods	Apple	2026-01-04 15:04:44.053045	2026-01-04 15:04:44.053045
42	AIRPODS PRO 3		0.00	\N	Airpods	Apple	2026-01-04 15:05:10.263724	2026-01-04 15:05:10.263724
43	AIRPODS 4 (ANC)		0.00	\N	Airpods	Apple	2026-01-04 15:05:22.384198	2026-01-04 15:05:22.384198
44	APPLE IPAD PRO MAGIC KEYBOARD 11		0.00	\N	Keyboard	Apple	2026-01-04 15:05:47.63586	2026-01-04 15:05:47.63586
45	APPLE PENCIL USB-C		0.00	\N	Pencil	Apple	2026-01-04 15:06:14.428798	2026-01-04 15:06:14.428798
46	GOOGLE PIXEL BUDS 2A		0.00	\N	Buds	Google	2026-01-04 15:06:29.935299	2026-01-04 15:06:29.935299
47	MOTOROLLA G (5G)		0.00	\N	Mobile Phone	Motorola	2026-01-04 15:06:48.89338	2026-01-04 15:06:48.89338
48	MOTOROLLA G STYLUS 5G		0.00	\N	Mobile Phone	Motorola	2026-01-04 15:07:02.622868	2026-01-04 15:07:02.622868
49	MOTOROLLA EDGE 5G 2025		0.00	\N	Mobile Phone	Motorola	2026-01-04 15:07:19.432833	2026-01-04 15:07:19.432833
50	GOOGLE PIXEL FOLD 256 GB		0.00	\N	Mobile Phone	Google	2026-01-04 15:07:39.6255	2026-01-04 15:07:39.6255
51	GOOGLE PIXEL FOLD 512 GB		0.00	\N	Mobile Phone	Google	2026-01-04 15:08:20.077564	2026-01-04 15:08:20.077564
52	GOOGLE PIXEL WATCH 4		0.00	\N	Watch	Google	2026-01-04 15:08:33.038385	2026-01-04 15:08:33.038385
53	MACBOOK PRO M4 MAX 16 48 GB, 1 TB	16 GB , 1 TB	0.00	\N	MacBook	Apple	2026-01-04 15:09:23.871859	2026-01-04 15:09:23.871859
54	MACBOOK PRO M4 MAX 16 36 GB, 1 TB	36 gb , 1 tb	0.00	\N	MacBook	Apple	2026-01-04 15:09:50.833801	2026-01-04 15:09:50.833801
55	MACBOOK PRO M1 16 16 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-04 15:10:10.17158	2026-01-04 15:10:10.17158
56	MACBOOK AIR M4 13 16 GB, 256 GB		0.00	\N	MacBook	Apple	2026-01-04 15:10:27.141009	2026-01-04 15:10:27.141009
59	MACBOOK AIR M2 13 16 GB, 256 GB		0.00	\N	MacBook	Apple	2026-01-04 15:11:03.743865	2026-01-04 15:11:03.743865
60	MACBOOK AIR M1 13 8 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-04 15:11:28.440997	2026-01-04 15:11:28.440997
61	MACBOOK AIR M4 13 24 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-04 15:11:39.644314	2026-01-04 15:11:39.644314
62	MACBOOK AIR M2 13 8 GB, 256 GB		0.00	\N	MacBook	Apple	2026-01-04 15:11:57.114795	2026-01-04 15:11:57.114795
63	IPAD A16 (W+C)128 GB		0.00	\N	Ipad	Apple	2026-01-04 15:12:18.603975	2026-01-04 15:12:18.603975
64	IPAD PRO M4 13 (W+C) 2 TB		0.00	\N	Ipad	Apple	2026-01-04 15:14:12.56115	2026-01-04 15:14:12.56115
65	IPAD PRO M4 13 (W) 256 GB		0.00	\N	Ipad	Apple	2026-01-04 15:14:24.911516	2026-01-04 15:14:24.911516
66	IPAD PRO M5 11 (W+C) 256 GB		0.00	\N	Ipad	Apple	2026-01-04 15:14:35.887492	2026-01-04 15:14:35.887492
67	IPAD PRO M5 13 (W+C) 256 GB		0.00	\N	Ipad	Apple	2026-01-04 15:14:48.647882	2026-01-04 15:14:48.647882
68	IPHONE 17 PRO MAX 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:15:01.871049	2026-01-04 15:15:01.871049
69	IPHONE 17 PRO MAX 2 TB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:15:12.803418	2026-01-04 15:15:12.803418
70	IPHONE 17 PRO 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:15:23.474784	2026-01-04 15:15:23.474784
71	JBL CHARGE 6		0.00	\N	Speaker	JBL	2026-01-04 15:15:46.254203	2026-01-04 15:15:46.254203
72	JBL FLIP 7		0.00	\N	Speaker	JBL	2026-01-04 15:16:00.90167	2026-01-04 15:16:00.90167
73	ACER ASPIRE 7 A715-59G-58A8 16 GB, 512 GB		0.00	\N	Laptop	Acer	2026-01-04 15:16:18.685264	2026-01-04 15:16:18.685264
74	CANON IXUS 285 HA		0.00	\N	Camera	Canon	2026-01-04 15:16:29.80586	2026-01-04 15:16:29.80586
75	IPHONE 17 PRO MAX 512 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:16:39.822472	2026-01-04 15:16:39.822472
76	IPHONE 17 PRO 1 TB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:16:49.263315	2026-01-04 15:16:49.263315
77	IPHONE 17 AIR 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:17:00.232439	2026-01-04 15:17:00.232439
78	IPHONE 17 512 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:17:09.960551	2026-01-04 15:17:09.960551
79	IPHONE 16 PRO MAX 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:17:20.571428	2026-01-04 15:17:20.571428
80	IPHONE 16 PRO 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:17:32.555384	2026-01-04 15:17:32.555384
81	IPHONE 16 PRO 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:17:50.748672	2026-01-04 15:17:50.748672
82	IPHONE 15 PRO MAX 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:18:06.516764	2026-01-04 15:18:06.516764
83	IPHONE 15 PRO 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:18:29.92653	2026-01-04 15:18:29.92653
84	IPHONE 15 PRO 512 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:18:39.686419	2026-01-04 15:18:39.686419
85	IPHONE 15 PLUS 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:18:53.710788	2026-01-04 15:18:53.710788
86	IPHONE 14 PRO MAX 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:19:04.937419	2026-01-04 15:19:04.937419
87	IPHONE 13 PRO MAX 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:19:17.090087	2026-01-04 15:19:17.090087
88	IPAD PRO M4 13 (W+C) 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:19:33.546307	2026-01-04 15:19:33.546307
89	APPLE WATCH ULTRA 2 49MM		0.00	\N	Watch	Apple	2026-01-04 15:19:51.868727	2026-01-04 15:19:51.868727
90	APPLE WATCH SERIES 11 42MM		0.00	\N	Watch	Apple	2026-01-04 15:20:09.308976	2026-01-04 15:20:09.308976
91	APPLE WATCH SERIES 10 46MM		0.00	\N	Watch	Apple	2026-01-04 15:20:20.201353	2026-01-04 15:20:20.201353
92	APPLE WATCH SE 2 44MM		0.00	\N	Watch	Apple	2026-01-04 15:20:47.187316	2026-01-04 15:20:47.187316
93	APPLE WATCH SE 2 40MM		0.00	\N	Watch	Apple	2026-01-04 15:21:00.097661	2026-01-04 15:21:00.097661
94	SKYLINE V2 POUCH 3		0.00	\N	\N	Skyline	2026-01-04 15:21:20.745878	2026-01-04 15:21:20.745878
95	GALAXY TAB S10 FE		0.00	\N	Tab	Samsung	2026-01-04 15:21:46.26703	2026-01-04 15:21:46.26703
96	GALAXY WATCH ULTRA		0.00	\N	Watch	Samsung	2026-01-04 15:21:58.684719	2026-01-04 15:21:58.684719
97	MACBOOK PRO M5 14 16 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-04 15:22:13.605851	2026-01-04 15:22:13.605851
98	MACBOOK PRO M4 14 16 GB, 1 TB		0.00	\N	MacBook	Apple	2026-01-04 15:22:24.326727	2026-01-04 15:22:24.326727
99	MACBOOK AIR M4 13 16 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-04 15:22:36.734105	2026-01-04 15:22:36.734105
100	MACBOOK AIR M3 15 8 GB, 256 GB		0.00	\N	MacBook	Apple	2026-01-04 15:22:55.727479	2026-01-04 15:22:55.727479
101	IPAD PRO M5 13 (W) 1 TB		0.00	\N	Ipad	Apple	2026-01-04 15:24:17.014049	2026-01-04 15:24:17.014049
102	IPHONE 17 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:24:30.048406	2026-01-04 15:24:30.048406
103	IPHONE 16 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-04 15:25:29.70666	2026-01-04 15:25:29.70666
104	APPLE WATCH SERIES 11 46MM		0.00	\N	Watch	Apple	2026-01-04 15:25:47.947842	2026-01-04 15:25:47.947842
105	APPLE WATCH SE 3 44MM		0.00	\N	Watch	Apple	2026-01-04 15:25:59.956228	2026-01-04 15:25:59.956228
106	APPLE WATCH SE 3 40MM		0.00	\N	Watch	Apple	2026-01-04 15:26:17.967621	2026-01-04 15:26:17.967621
107	ONN SINGLE USE CAMERA WITH FLASH		0.00	\N	Camera	Onn	2026-01-04 15:26:31.319994	2026-01-04 15:26:31.319994
108	ONN RE-USABLE CAMERA WITH FLASH		0.00	\N	Camera	Onn	2026-01-04 15:26:50.25694	2026-01-04 15:26:50.25694
109	INSTAX MINI LIPLAY		0.00	\N	Camera	Instax	2026-01-04 15:27:09.922964	2026-01-04 15:27:09.922964
110	POKEMON CARD		0.00	\N	\N	\N	2026-01-04 15:27:23.692304	2026-01-04 15:27:23.692304
111	LENOVO THINK VISION E24-40 LCD MONITOR		0.00	\N	LCD Monitor	Lenovo	2026-01-04 15:27:46.803117	2026-01-04 15:27:46.803117
112	GO PRO FLOATY HERO		0.00	\N	Camera	GoPro	2026-01-04 15:28:01.150733	2026-01-04 15:28:01.150733
113	BLINK OUTDOOR 4		0.00	\N	\N	\N	2026-01-04 15:28:27.856943	2026-01-04 15:28:27.856943
114	PRESTO ELECTRIC KETTLE		0.00	\N	Electric Kettle	Presto	2026-01-04 15:28:55.649072	2026-01-04 15:28:55.649072
115	GALAXY S23 ULTRA 256 GB		0.00	\N	Mobile Phone	Samsung	2026-01-04 15:29:09.818756	2026-01-04 15:29:09.818756
116	ASTRO BOT GAME CD		0.00	\N	CD	BlueRayy	2026-01-05 12:23:52.406414	2026-01-05 12:23:52.406414
117	BRAUN SILK EPILATOR 9		0.00	\N	Eye Trimmer	Braun	2026-01-05 12:24:28.83388	2026-01-05 12:24:28.83388
118	BRAUN SILK EPILATOR 7		0.00	\N	Eye Trimmer	Braun	2026-01-05 12:24:48.513327	2026-01-05 12:24:48.513327
119	BRAUN SHAVER 6		0.00	\N	Trimmer	Braun	2026-01-05 12:25:02.120019	2026-01-05 12:25:02.120019
120	BRAUN ALL IN ONE TRIMMER 7		0.00	\N	Trimmer	Braun	2026-01-05 12:25:13.41133	2026-01-05 12:25:13.41133
121	BRAUN ALL IN ONE TRIMMER 5		0.00	\N	Trimmer	Braun	2026-01-05 12:25:24.428219	2026-01-05 12:25:24.428219
122	BRAUN IPL 5137		0.00	\N	Trimmer	Braun	2026-01-05 12:25:52.477957	2026-01-05 12:25:52.477957
123	BRAUN 9 IN 1		0.00	\N	Trimmer	Braun	2026-01-05 12:26:34.907272	2026-01-05 12:26:34.907272
124	SAMSUNG GALAXY S25 ULTRA 512		0.00	\N	Mobile Phone	Samsung	2026-01-05 12:27:31.133987	2026-01-05 12:27:31.133987
125	INSTAX WIDE 400		0.00	\N	Camera	Instax	2026-01-05 12:27:47.43792	2026-01-05 12:27:47.43792
126	MACBOOK AIR M3 15 24 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-05 13:53:22.843428	2026-01-05 13:53:22.843428
127	IPHONE 13 PRO MAX 512 GB		0.00	\N	Mobile Phone	Apple	2026-01-05 14:48:04.136292	2026-01-05 14:48:04.136292
128	IPAD A16 (W) 128 GB	\N	1.00	\N	\N	\N	2026-01-05 14:58:15.414811	2026-01-05 14:58:15.414811
129	Galaxy Tab S10 FE	\N	1400.00	\N	\N	\N	2026-01-05 14:58:15.419245	2026-01-05 14:58:15.419245
130	Galaxy Watch Ultra	\N	1200.00	\N	\N	\N	2026-01-05 14:58:15.419245	2026-01-05 14:58:15.419245
131	DJI MAVIC 4 PRO STANDARD		0.00	\N	Drone	DJI	2026-01-07 13:49:43.004912	2026-01-07 13:49:43.004912
132	IPHONE 16 PLUS 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 14:38:30.162257	2026-01-07 14:38:30.162257
133	GOOGLE PIXEL 7		0.00	\N	Mobile Phone	Google	2026-01-07 15:05:28.694661	2026-01-07 15:05:28.694661
134	IPHONE 13 PRO MAX 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 15:08:59.64704	2026-01-07 15:08:59.64704
135	IPHONE 11 PRO 256		0.00	\N	Mobile Phone	Apple	2026-01-07 15:10:37.91104	2026-01-07 15:10:37.91104
136	IPHONE 11 PRO MAX 256		0.00	\N	Mobile Phone	Apple	2026-01-07 15:10:58.648276	2026-01-07 15:10:58.648276
137	IPHONE 16 PRO 512 GB		0.00	\N	\N	\N	2026-01-07 15:13:25.517498	2026-01-07 15:13:25.517498
138	IPHONE 15 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 15:30:50.153247	2026-01-07 15:30:50.153247
139	IPHONE 17 PRO MAX 1 TB		0.00	\N	Mobile Phone	Apple	2026-01-07 16:09:49.297129	2026-01-07 16:09:49.297129
140	IPHONE 16 PRO MAX 1 TB		0.00	\N	Mobile Phone	Apple	2026-01-07 16:12:12.76971	2026-01-07 16:12:12.76971
141	IPHONE 16 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 16:13:59.213729	2026-01-07 16:13:59.213729
142	IPHONE 16E 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 16:16:35.085828	2026-01-07 16:16:35.085828
143	IPHONE 14 PRO MAX 256 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 16:23:37.482471	2026-01-07 16:23:37.482471
144	IPHONE 13 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 16:24:56.871763	2026-01-07 16:24:56.871763
145	IPHONE SE 128 GB		0.00	\N	Mobile Phone	Apple	2026-01-07 16:25:48.011873	2026-01-07 16:25:48.011873
146	IPAD AIR M3 13 (W) 128 GB		0.00	\N	Ipad	Apple	2026-01-07 16:29:16.151147	2026-01-07 16:29:16.151147
147	IPAD MINI A17 PRO (W+C) 128 GB		0.00	\N	Ipad	Apple	2026-01-07 16:30:37.820031	2026-01-07 16:30:37.820031
148	IPAD MINI A17 PRO (W) 256 GB		0.00	\N	Ipad	Apple	2026-01-07 16:31:02.695177	2026-01-07 16:31:02.695177
149	MACBOOK PRO M5 14 16 GB, 1 TB		0.00	\N	MacBook	Apple	2026-01-07 16:31:51.9766	2026-01-07 16:31:51.9766
150	MACBOOK PRO M5 14 24 GB, 1 TB		0.00	\N	MacBook	Apple	2026-01-07 16:33:11.14244	2026-01-07 16:33:11.14244
151	MACBOOK PRO M4 PRO 14 24 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-07 16:43:02.562757	2026-01-07 16:43:02.562757
152	APPLE WATCH ULTRA 3 49MM		0.00	\N	Watch	Apple	2026-01-07 16:45:17.095945	2026-01-07 16:45:17.095945
153	GALAXY Z FLIP 7 256 GB		0.00	\N	Mobile Phone	Samsung	2026-01-07 16:46:02.075444	2026-01-07 16:46:02.075444
154	META HEADLINER GEN 2		0.00	\N	Smart Glasses	Meta	2026-01-07 16:46:30.34375	2026-01-07 16:46:30.34375
155	META WAYFARER GEN 2		0.00	\N	Smart Glasses	Meta	2026-01-07 16:46:47.263372	2026-01-07 16:46:47.263372
156	META WAYFARER		0.00	\N	Smart Glasses	Meta	2026-01-07 16:47:07.464798	2026-01-07 16:47:07.464798
157	META SKYLER GEN 2		0.00	\N	Smart Glasses	Meta	2026-01-07 16:47:26.317845	2026-01-07 16:47:26.317845
158	META SKYLER		0.00	\N	Smart Glasses	Meta	2026-01-07 16:47:51.372246	2026-01-07 16:47:51.372246
159	IPHONE 17 PRO 512 GB		0.00	\N	Mobile Phone	\N	2026-01-08 08:59:38.746999	2026-01-08 08:59:38.746999
160	GALAXY S25 ULTRA 256 GB		0.00	\N	Mobile Phone	Samsung	2026-01-08 09:07:50.726993	2026-01-08 09:07:50.726993
\.


--
-- Data for Name: journalentries; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.journalentries (journal_id, entry_date, description, date_created) FROM stdin;
1	2026-01-04	Opening Balance for GIFT ACCOUNT	2026-01-04 15:38:18.8546
2	2026-01-04	Purchase Invoice 1	2026-01-04 15:42:21.678551
3	2026-01-04	Purchase Invoice 2	2026-01-04 15:42:21.692909
4	2026-01-04	Purchase Invoice 3	2026-01-04 15:44:33.93609
6	2026-01-05	Purchase Invoice 4	2026-01-05 13:53:56.498622
7	2026-01-05	Purchase Invoice 5	2026-01-05 13:53:56.5131
8	2026-01-05	Purchase Invoice 6	2026-01-05 13:53:56.524773
9	2026-01-05	Purchase Invoice 7	2026-01-05 13:53:56.52665
10	2026-01-05	Purchase Invoice 8	2026-01-05 13:53:56.528898
11	2026-01-05	Purchase Invoice 9	2026-01-05 13:53:56.532375
12	2026-01-05	Purchase Invoice 10	2026-01-05 13:53:56.534565
13	2026-01-05	Purchase Invoice 11	2026-01-05 13:53:56.536833
14	2026-01-05	Purchase Invoice 12	2026-01-05 13:53:56.539589
15	2026-01-05	Purchase Invoice 13	2026-01-05 13:53:56.541256
16	2026-01-05	Purchase Invoice 14	2026-01-05 13:53:56.54339
17	2026-01-05	Purchase Invoice 15	2026-01-05 13:53:56.546272
18	2026-01-05	Purchase Invoice 16	2026-01-05 13:53:56.548613
19	2026-01-05	Purchase Invoice 17	2026-01-05 13:53:56.551841
20	2026-01-05	Purchase Invoice 18	2026-01-05 13:53:56.553628
21	2026-01-05	Purchase Invoice 19	2026-01-05 13:53:56.555277
22	2026-01-05	Purchase Invoice 20	2026-01-05 13:53:56.559295
23	2026-01-05	Purchase Invoice 21	2026-01-05 13:53:56.561992
24	2026-01-05	Purchase Invoice 22	2026-01-05 13:53:56.574504
25	2026-01-05	Purchase Invoice 23	2026-01-05 13:53:56.597339
26	2026-01-05	Purchase Invoice 24	2026-01-05 13:53:56.598983
27	2026-01-05	Purchase Invoice 25	2026-01-05 13:53:56.601231
28	2026-01-05	Purchase Invoice 26	2026-01-05 13:53:56.603542
29	2026-01-05	Purchase Invoice 27	2026-01-05 13:53:56.605392
30	2026-01-05	Purchase Invoice 28	2026-01-05 13:53:56.626474
31	2026-01-05	Purchase Invoice 29	2026-01-05 13:53:56.627997
32	2026-01-05	Purchase Invoice 30	2026-01-05 13:53:56.630503
33	2026-01-05	Purchase Invoice 31	2026-01-05 13:53:56.632487
34	2026-01-05	Purchase Invoice 32	2026-01-05 13:53:56.634811
35	2026-01-05	Purchase Invoice 33	2026-01-05 13:53:56.637293
36	2026-01-05	Purchase Invoice 34	2026-01-05 13:53:56.639335
37	2026-01-05	Purchase Invoice 35	2026-01-05 13:53:56.643205
38	2026-01-05	Purchase Invoice 36	2026-01-05 13:53:56.645041
39	2026-01-05	Purchase Invoice 37	2026-01-05 14:10:05.684553
40	2026-01-05	Purchase Invoice 38	2026-01-05 14:10:05.692086
41	2026-01-05	Purchase Invoice 39	2026-01-05 14:52:11.197298
43	2026-01-05	Purchase Invoice 40	2026-01-05 14:58:15.414811
44	2026-01-05	Purchase Invoice 41	2026-01-05 14:58:15.419245
45	2026-01-05	Purchase Invoice 42	2026-01-05 14:58:15.421572
46	2026-01-05	Purchase Invoice 43	2026-01-05 14:58:15.424753
48	2026-01-05	Purchase Invoice 44	2026-01-05 15:07:33.317908
49	2026-01-05	Purchase Invoice 45	2026-01-05 15:07:33.321212
50	2026-01-05	Purchase Invoice 46	2026-01-05 15:07:33.324216
51	2026-01-05	Purchase Invoice 47	2026-01-05 15:07:33.326402
52	2026-01-05	Purchase Invoice 48	2026-01-05 15:07:33.328371
53	2026-01-05	Purchase Invoice 49	2026-01-05 15:07:33.332197
54	2026-01-05	Purchase Invoice 50	2026-01-05 15:07:33.333943
55	2026-01-05	Purchase Invoice 51	2026-01-05 15:07:33.336016
56	2026-01-05	Purchase Invoice 52	2026-01-05 15:07:33.338156
57	2026-01-05	Purchase Invoice 53	2026-01-05 15:07:33.340024
58	2026-01-05	Purchase Invoice 54	2026-01-05 15:07:33.341828
59	2026-01-05	Purchase Invoice 55	2026-01-05 15:07:33.344967
60	2026-01-05	Purchase Invoice 56	2026-01-05 15:07:33.346666
61	2026-01-05	Purchase Invoice 57	2026-01-05 15:07:33.34883
62	2026-01-05	Purchase Invoice 58	2026-01-05 15:07:33.351076
63	2026-01-05	Purchase Invoice 59	2026-01-05 15:07:33.353904
64	2026-01-05	Purchase Invoice 60	2026-01-05 15:07:33.356554
65	2026-01-05	Purchase Invoice 61	2026-01-05 15:07:33.358668
66	2026-01-05	Purchase Invoice 62	2026-01-05 15:07:33.361343
67	2026-01-05	Purchase Invoice 63	2026-01-05 15:07:33.364439
68	2026-01-05	Purchase Invoice 64	2026-01-05 15:07:33.366882
69	2026-01-05	Purchase Invoice 65	2026-01-05 15:07:33.372021
72	2026-01-05	Purchase Invoice 66	2026-01-05 15:38:57.79738
73	2026-01-05	Opening Balance for HAZARTO	2026-01-05 15:54:12.924413
74	2026-01-05	Purchase Invoice 67	2026-01-05 15:54:34.083047
76	2026-01-05	Opening Balance for TURBO	2026-01-05 16:11:07.581903
77	2026-01-05	Purchase Invoice 68	2026-01-05 16:11:37.917777
78	2026-01-05	Opening Balance for ABDUL MAJID BHAI	2026-01-05 16:14:17.543852
79	2026-01-05	Opening Balance for FAISAL BHAI	2026-01-05 16:15:09.340443
80	2026-01-05	Opening Balance for ABDUL REHMAN BHAI	2026-01-05 16:17:48.53278
81	2026-01-01	Opening balances	2026-01-05 16:39:30.298573
82	2026-01-06	Opening Balance for ABDUL REHMAN HOUSTON	2026-01-06 12:41:23.61114
83	2026-01-06	Opening Balance for ABUBAKER KARACHI	2026-01-06 12:46:32.006085
84	2026-01-06	Opening Balance for ADEEL CHINA	2026-01-06 12:47:16.781039
85	2026-01-06	Opening Balance for AHSAN CBA	2026-01-06 12:49:47.407021
86	2026-01-06	Opening Balance for AHSAN MOHSIN	2026-01-06 12:53:52.465446
87	2026-01-06	Opening Balance for AMRA SISTER	2026-01-06 12:55:22.921105
88	2026-01-06	Opening Balance for AR WISE BANK USA	2026-01-06 12:57:19.592492
89	2026-01-06	Opening Balance for ASHFAQ SAHAB CARD	2026-01-06 13:01:29.261219
90	2026-01-06	Opening Balance for AHMED PASHA	2026-01-06 13:06:51.369943
91	2026-01-06	Opening Balance for CAR	2026-01-06 13:08:22.473138
92	2026-01-06	Opening Balance for CELLULAR LINK	2026-01-06 13:09:56.57422
93	2026-01-06	Opening Balance for EAZYBUY ELECTRONICS	2026-01-06 13:13:54.368002
94	2026-01-06	Opening Balance for FAHEEM AHMED (CHACHA)	2026-01-06 13:15:46.860879
95	2026-01-06	Opening Balance for FAHEEM KARACHI	2026-01-06 13:16:26.426298
96	2026-01-06	Opening Balance for FIVE PERCENT	2026-01-06 13:17:25.940772
97	2026-01-06	Opening Balance for HAMZA CUSTOMER	2026-01-06 13:21:05.12173
98	2026-01-06	Opening Balance for HANZALAH	2026-01-06 13:21:46.430991
99	2026-01-06	Opening Balance for HUMAIR KARACHI	2026-01-06 13:25:05.112086
100	2026-01-06	Opening Balance for NOMAN AMGT USA	2026-01-06 14:06:28.648324
101	2026-01-06	Opening Balance for ONTELL	2026-01-06 14:07:41.180965
102	2026-01-06	Opening Balance for POWER PLAY	2026-01-06 14:08:52.235565
103	2026-01-06	Opening Balance for RAAD AL MADINA	2026-01-06 14:11:45.370735
104	2026-01-06	Opening Balance for SAAD & WAJAHAT	2026-01-06 14:12:33.26686
105	2026-01-06	Opening Balance for SHEHZAD MUGHAL	2026-01-06 14:17:19.009774
106	2026-01-06	Opening Balance for SHUJA SYDNEY	2026-01-06 14:24:08.198406
107	2026-01-06	Opening Balance for TRANSWORLD	2026-01-06 14:26:46.007847
108	2026-01-06	Opening Balance for UMAIR B SMART	2026-01-06 14:29:21.639172
109	2026-01-06	Opening Balance for WAHEED BHAI Z	2026-01-06 14:31:58.477807
110	2026-01-06	Opening Balance for WAJAHAT	2026-01-06 14:32:18.008356
111	2026-01-06	Opening Balance for WALEED BHAI AUS	2026-01-06 14:33:19.602425
112	2026-01-06	Opening Balance for WORLD MART	2026-01-06 14:34:05.815749
113	2026-01-06	Opening Balance for ZEESHAN	2026-01-06 14:35:10.429398
114	2026-01-06	Opening Balance for HASSAN ASHRAF	2026-01-06 15:05:48.887913
115	2026-01-06	Out to loss Account 	2026-01-06 16:06:41.776409
116	2026-01-06	loss for hassan Ashraf 	2026-01-06 16:07:26.313194
117	2026-01-07	Opening Balance for MUDASSIR	2026-01-07 15:01:42.534579
118	2026-01-07	Purchase Invoice 69	2026-01-07 15:02:07.966877
119	2026-01-07	Purchase Invoice 70	2026-01-07 15:02:07.973085
120	2026-01-07	Purchase Invoice 71	2026-01-07 15:02:07.975914
121	2026-01-07	Purchase Invoice 72	2026-01-07 15:02:07.978524
123	2026-01-07	Purchase Invoice 74	2026-01-07 15:18:36.12523
124	2026-01-07	Opening Balance for WAHEED BHAI	2026-01-07 15:26:22.98745
125	2026-01-07	Purchase Invoice 75	2026-01-07 15:28:08.550714
126	2026-01-07	Opening Balance for OWAIS HOUSTON	2026-01-07 15:55:44.881265
127	2026-01-07	Purchase Invoice 76	2026-01-07 15:56:22.764816
128	2026-01-08	Purchase Invoice 77	2026-01-08 08:41:25.164235
129	2026-01-08	Purchase Invoice 78	2026-01-08 09:01:02.485063
130	2026-01-08	Purchase Invoice 79	2026-01-08 09:08:57.876091
\.


--
-- Data for Name: journallines; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.journallines (line_id, journal_id, account_id, party_id, debit, credit) FROM stdin;
1	1	6	1	90.00	0.00
2	1	2	\N	0.00	90.00
3	2	7	\N	85.00	0.00
4	2	1	1	0.00	85.00
5	3	7	\N	5.00	0.00
6	3	1	1	0.00	5.00
7	4	7	\N	6924.80	0.00
8	4	1	2	0.00	6924.80
11	6	7	\N	218815.17	0.00
12	6	1	4	0.00	218815.17
13	7	7	\N	247151.90	0.00
14	7	1	4	0.00	247151.90
15	8	7	\N	162.00	0.00
16	8	1	4	0.00	162.00
17	9	7	\N	4568.00	0.00
18	9	1	4	0.00	4568.00
19	10	7	\N	90817.98	0.00
20	10	1	4	0.00	90817.98
21	11	7	\N	42344.00	0.00
22	11	1	4	0.00	42344.00
23	12	7	\N	86661.97	0.00
24	12	1	4	0.00	86661.97
25	13	7	\N	61821.00	0.00
26	13	1	4	0.00	61821.00
27	14	7	\N	9011.10	0.00
28	14	1	4	0.00	9011.10
29	15	7	\N	30156.06	0.00
30	15	1	4	0.00	30156.06
31	16	7	\N	35924.00	0.00
32	16	1	4	0.00	35924.00
33	17	7	\N	27525.40	0.00
34	17	1	4	0.00	27525.40
35	18	7	\N	35790.30	0.00
36	18	1	4	0.00	35790.30
37	19	7	\N	1518.00	0.00
38	19	1	4	0.00	1518.00
39	20	7	\N	3316.00	0.00
40	20	1	4	0.00	3316.00
41	21	7	\N	157525.37	0.00
42	21	1	4	0.00	157525.37
43	22	7	\N	39117.52	0.00
44	22	1	4	0.00	39117.52
45	23	7	\N	162637.00	0.00
46	23	1	4	0.00	162637.00
47	24	7	\N	29680.00	0.00
48	24	1	4	0.00	29680.00
49	25	7	\N	6624.80	0.00
50	25	1	4	0.00	6624.80
51	26	7	\N	8415.00	0.00
52	26	1	4	0.00	8415.00
53	27	7	\N	925.00	0.00
54	27	1	4	0.00	925.00
55	28	7	\N	7507.26	0.00
56	28	1	4	0.00	7507.26
57	29	7	\N	429416.37	0.00
58	29	1	4	0.00	429416.37
59	30	7	\N	1028.00	0.00
60	30	1	4	0.00	1028.00
61	31	7	\N	10040.82	0.00
62	31	1	4	0.00	10040.82
63	32	7	\N	757.89	0.00
64	32	1	4	0.00	757.89
65	33	7	\N	20824.10	0.00
66	33	1	4	0.00	20824.10
67	34	7	\N	23657.40	0.00
68	34	1	4	0.00	23657.40
69	35	7	\N	1732.32	0.00
70	35	1	4	0.00	1732.32
71	36	7	\N	20761.55	0.00
72	36	1	4	0.00	20761.55
73	37	7	\N	103.21	0.00
74	37	1	4	0.00	103.21
75	38	7	\N	12022.38	0.00
76	38	1	4	0.00	12022.38
77	39	7	\N	20017.40	0.00
78	39	1	4	0.00	20017.40
79	40	7	\N	1544.65	0.00
80	40	1	4	0.00	1544.65
81	41	7	\N	16.00	0.00
82	41	1	2	0.00	16.00
85	43	7	\N	14.00	0.00
86	43	1	5	0.00	14.00
87	44	7	\N	5300.00	0.00
88	44	1	5	0.00	5300.00
89	45	7	\N	13882.00	0.00
90	45	1	5	0.00	13882.00
91	46	7	\N	9700.00	0.00
92	46	1	5	0.00	9700.00
95	48	7	\N	22972.20	0.00
96	48	1	6	0.00	22972.20
97	49	7	\N	23654.88	0.00
98	49	1	6	0.00	23654.88
99	50	7	\N	6003.65	0.00
100	50	1	6	0.00	6003.65
101	51	7	\N	1007.00	0.00
102	51	1	6	0.00	1007.00
103	52	7	\N	7110.82	0.00
104	52	1	6	0.00	7110.82
105	53	7	\N	4.00	0.00
106	53	1	6	0.00	4.00
107	54	7	\N	453.00	0.00
108	54	1	6	0.00	453.00
109	55	7	\N	7760.28	0.00
110	55	1	6	0.00	7760.28
111	56	7	\N	2586.76	0.00
112	56	1	6	0.00	2586.76
113	57	7	\N	646.00	0.00
114	57	1	6	0.00	646.00
115	58	7	\N	8862.00	0.00
116	58	1	6	0.00	8862.00
117	59	7	\N	791.00	0.00
118	59	1	6	0.00	791.00
119	60	7	\N	6111.00	0.00
120	60	1	6	0.00	6111.00
121	61	7	\N	1452.98	0.00
122	61	1	6	0.00	1452.98
123	62	7	\N	4577.00	0.00
124	62	1	6	0.00	4577.00
125	63	7	\N	14595.68	0.00
126	63	1	6	0.00	14595.68
127	64	7	\N	3091.00	0.00
128	64	1	6	0.00	3091.00
129	65	7	\N	36408.00	0.00
130	65	1	6	0.00	36408.00
131	66	7	\N	42351.50	0.00
132	66	1	6	0.00	42351.50
133	67	7	\N	21627.52	0.00
134	67	1	6	0.00	21627.52
135	68	7	\N	41390.40	0.00
136	68	1	6	0.00	41390.40
137	69	7	\N	2584.80	0.00
138	69	1	6	0.00	2584.80
143	72	7	\N	69394.83	0.00
144	72	1	4	0.00	69394.83
145	73	2	\N	3252.00	0.00
146	73	1	7	0.00	3252.00
147	74	7	\N	60.00	0.00
148	74	1	7	0.00	60.00
151	76	2	\N	2404.00	0.00
152	76	1	8	0.00	2404.00
153	77	7	\N	77.00	0.00
154	77	1	8	0.00	77.00
155	78	2	\N	287832.00	0.00
156	78	1	9	0.00	287832.00
157	79	2	\N	156601.00	0.00
158	79	1	10	0.00	156601.00
159	80	2	\N	704552.00	0.00
160	80	1	11	0.00	704552.00
161	81	5	\N	113484.00	0.00
162	81	17	\N	0.00	113484.00
163	82	6	12	8341.00	0.00
164	82	2	\N	0.00	8341.00
165	83	2	\N	1143.00	0.00
166	83	1	13	0.00	1143.00
167	84	6	14	500.00	0.00
168	84	2	\N	0.00	500.00
169	85	2	\N	227184.00	0.00
170	85	1	15	0.00	227184.00
171	86	2	\N	22174.00	0.00
172	86	1	16	0.00	22174.00
173	87	6	17	630.00	0.00
174	87	2	\N	0.00	630.00
175	88	6	18	55054.00	0.00
176	88	2	\N	0.00	55054.00
177	89	2	\N	20880.00	0.00
178	89	1	19	0.00	20880.00
179	90	6	21	32869.00	0.00
180	90	2	\N	0.00	32869.00
181	91	6	22	21138.00	0.00
182	91	2	\N	0.00	21138.00
183	92	6	23	550.00	0.00
184	92	2	\N	0.00	550.00
185	93	2	\N	440.00	0.00
186	93	1	26	0.00	440.00
187	94	6	27	12658.00	0.00
188	94	2	\N	0.00	12658.00
189	95	6	28	470.00	0.00
190	95	2	\N	0.00	470.00
191	96	2	\N	29000.00	0.00
192	96	1	29	0.00	29000.00
193	97	6	32	2330.00	0.00
194	97	2	\N	0.00	2330.00
195	98	6	33	19836.00	0.00
196	98	2	\N	0.00	19836.00
197	99	6	36	580.00	0.00
198	99	2	\N	0.00	580.00
199	100	6	44	1835.00	0.00
200	100	2	\N	0.00	1835.00
201	101	2	\N	1317.00	0.00
202	101	1	45	0.00	1317.00
203	102	6	46	60317.00	0.00
204	102	2	\N	0.00	60317.00
205	103	2	\N	270.00	0.00
206	103	1	49	0.00	270.00
207	104	6	50	18982.00	0.00
208	104	2	\N	0.00	18982.00
209	105	6	54	2413.00	0.00
210	105	2	\N	0.00	2413.00
211	106	2	\N	95820.00	0.00
212	106	1	55	0.00	95820.00
213	107	2	\N	15.00	0.00
214	107	1	57	0.00	15.00
215	108	6	58	1601.00	0.00
216	108	2	\N	0.00	1601.00
217	109	6	61	1242.00	0.00
218	109	2	\N	0.00	1242.00
219	110	2	\N	200.00	0.00
220	110	1	62	0.00	200.00
221	111	6	63	6329.00	0.00
222	111	2	\N	0.00	6329.00
223	112	2	\N	3487.00	0.00
224	112	1	64	0.00	3487.00
225	113	6	66	5770.00	0.00
226	113	2	\N	0.00	5770.00
227	114	6	67	46220.00	0.00
228	114	2	\N	0.00	46220.00
229	115	5	\N	15000.00	0.00
230	115	6	67	0.00	15000.00
231	116	24	39	15000.00	0.00
232	116	5	\N	0.00	15000.00
233	117	6	5	15921.00	0.00
234	117	2	\N	0.00	15921.00
235	118	7	\N	2700.00	0.00
236	118	1	5	0.00	2700.00
237	119	7	\N	2800.00	0.00
238	119	1	5	0.00	2800.00
239	120	7	\N	1650.00	0.00
240	120	1	5	0.00	1650.00
241	121	7	\N	2430.00	0.00
242	121	1	5	0.00	2430.00
245	123	7	\N	32.00	0.00
246	123	1	2	0.00	32.00
247	124	6	4	641854.00	0.00
248	124	2	\N	0.00	641854.00
249	125	7	\N	11970.00	0.00
250	125	1	4	0.00	11970.00
251	126	6	6	529604.00	0.00
252	126	2	\N	0.00	529604.00
253	127	7	\N	21895.65	0.00
254	127	1	6	0.00	21895.65
255	128	7	\N	113904.00	0.00
256	128	1	6	0.00	113904.00
257	129	7	\N	81940.00	0.00
258	129	1	5	0.00	81940.00
259	130	7	\N	79860.00	0.00
260	130	1	5	0.00	79860.00
\.


--
-- Data for Name: parties; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.parties (party_id, party_name, party_type, contact_info, address, ar_account_id, ap_account_id, opening_balance, balance_type, date_created) FROM stdin;
1	GIFT ACCOUNT	Both	1111111111111	For purchasing gift items	6	1	90.00	Debit	2026-01-04 15:38:18.8546
2	HOLD	Both	1233333333313	For purchasing Hold Stock	6	1	0.00	Debit	2026-01-04 15:44:15.117524
61	WAHEED BHAI Z	Both		Loan Amount	6	1	1242.00	Debit	2026-01-06 14:31:58.477807
6	OWAIS HOUSTON	Both	+1 2332 232 223	Houston, Texas, USA	6	1	529604.00	Debit	2026-01-05 15:05:53.651157
7	HAZARTO	Both		Dubai, UAE	6	1	3252.00	Credit	2026-01-05 15:54:12.924413
8	TURBO	Both		Duabi, UAE	6	1	2404.00	Credit	2026-01-05 16:05:46.333139
9	ABDUL MAJID BHAI	Both		Canada	6	1	287832.00	Credit	2026-01-05 16:14:17.543852
10	FAISAL BHAI	Both		Dubai	6	1	156601.00	Credit	2026-01-05 16:15:09.340443
11	ABDUL REHMAN BHAI	Both		Karachi, Dubai	6	1	704552.00	Credit	2026-01-05 16:17:48.53278
12	ABDUL REHMAN HOUSTON	Both		Houston, Texas, USA	6	1	8341.00	Debit	2026-01-06 12:41:23.61114
13	ABUBAKER KARACHI	Both	+92 318 2077518	House AR 29, Gulshan-e-Iqbal block 10, Karachi	6	1	1143.00	Credit	2026-01-06 12:46:32.006085
14	ADEEL CHINA	Both		China	6	1	500.00	Debit	2026-01-06 12:47:16.781039
15	AHSAN CBA	Both		Shop # 224, Star City Mall, Karachi	6	1	227184.00	Credit	2026-01-06 12:49:47.407021
16	AHSAN MOHSIN	Both		Dubai, UAE	6	1	22174.00	Credit	2026-01-06 12:53:52.465446
17	AMRA SISTER	Both		Karachi	6	1	630.00	Debit	2026-01-06 12:55:22.921105
18	AR WISE BANK USA	Both		USA Bank Account	6	1	55054.00	Debit	2026-01-06 12:57:19.592492
19	ASHFAQ SAHAB CARD	Both		Ashfaq Sahab Card 	6	1	20880.00	Credit	2026-01-06 13:01:29.261219
20	AUSTRALIA OFFICE EXP	Expense		Australia Expense Account	6	18	0.00	Debit	2026-01-06 13:05:00.164473
21	AHMED PASHA	Both	+92 336 2033428	Karachi, Pakistan	6	1	32869.00	Debit	2026-01-06 13:06:51.369943
22	CAR	Both		Car Purchase	6	1	21138.00	Debit	2026-01-06 13:08:22.473138
23	CELLULAR LINK	Both		Dubai, UAE	6	1	550.00	Debit	2026-01-06 13:09:56.57422
24	COMMISSION CHARGES	Expense		For Commission amounts	6	19	0.00	Debit	2026-01-06 13:11:11.562331
25	DISCOUNT	Expense		For giving discounts to parties	6	20	0.00	Debit	2026-01-06 13:12:24.902304
26	EAZYBUY ELECTRONICS	Both		Dubai, UAE	6	1	440.00	Credit	2026-01-06 13:13:54.368002
27	FAHEEM AHMED (CHACHA)	Both		Karachi, Pakistan	6	1	12658.00	Debit	2026-01-06 13:15:46.860879
28	FAHEEM KARACHI	Both		Karachi, Pakistan	6	1	470.00	Debit	2026-01-06 13:16:26.426298
29	FIVE PERCENT	Both		5% amount of total monthly profit	6	1	29000.00	Credit	2026-01-06 13:17:25.940772
30	GAME HOME	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 13:18:02.777149
31	GST REFUND	Expense		For maintaining GST Amount	6	21	0.00	Debit	2026-01-06 13:19:16.39704
32	HAMZA CUSTOMER	Both		Dubai, UAE	6	1	2330.00	Debit	2026-01-06 13:21:05.12173
33	HANZALAH	Both		Dubai, UAE	6	1	19836.00	Debit	2026-01-06 13:21:46.430991
34	HARIS GUJRANWALA	Both		Dubai, UAE 	6	1	0.00	Debit	2026-01-06 13:22:44.73157
35	HMB	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 13:24:05.059029
36	HUMAIR KARACHI	Both		Karachi, Pakistan	6	1	580.00	Debit	2026-01-06 13:25:05.112086
37	KARACHI OFFICE EXPENSE	Expense		Karachi Expense Account	6	22	0.00	Debit	2026-01-06 13:26:30.047226
38	LABELS PROFIT	Expense		For maintaining USA Labels Profit	6	23	0.00	Debit	2026-01-06 13:28:08.81782
39	LOSS AC	Expense		for losses details	6	24	0.00	Debit	2026-01-06 13:29:55.462716
40	DUBAI OFFICE EXPENSE	Expense		Expense Account for Dubai Office	6	25	0.00	Debit	2026-01-06 14:02:20.765197
41	MOIN HUSSAIN TRADING	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 14:03:22.531446
42	MOIN SAHAB	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 14:04:24.591341
43	NEWZEALAND EXPENSE	Expense		Newzealand Expense	6	26	0.00	Debit	2026-01-06 14:05:38.324886
44	NOMAN AMGT USA	Both		USA	6	1	1835.00	Debit	2026-01-06 14:06:28.648324
45	ONTELL	Both		Dubai, UAE	6	1	1317.00	Credit	2026-01-06 14:07:41.180965
46	POWER PLAY	Both		Dubai, UAE	6	1	60317.00	Debit	2026-01-06 14:08:52.235565
47	QAISER STAFF	Both		Staff Person	6	1	0.00	Debit	2026-01-06 14:09:34.467813
48	RAAZ	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 14:10:02.431924
49	RAAD AL MADINA	Both		Dubai, UAE	6	1	270.00	Credit	2026-01-06 14:11:45.370735
50	SAAD & WAJAHAT	Both		Dubai, UAE	6	1	18982.00	Debit	2026-01-06 14:12:33.26686
51	SALARY EXP	Expense		Salary Expense	6	27	0.00	Debit	2026-01-06 14:14:11.064508
52	SHAHID KARACHI	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 14:15:31.82849
53	SHAPOOR	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 14:16:34.918478
54	SHEHZAD MUGHAL	Both		Dubai, UAE	6	1	2413.00	Debit	2026-01-06 14:17:19.009774
55	SHUJA SYDNEY	Both		Investment Amount	6	1	95820.00	Credit	2026-01-06 14:24:08.198406
56	SUMAIR PASTA KARACHI	Both		Shop # 464 Star City Mall, Karachi, Pakistan	6	1	0.00	Debit	2026-01-06 14:25:30.455025
57	TRANSWORLD	Both		Dubai, UAE	6	1	15.00	Credit	2026-01-06 14:26:46.007847
58	UMAIR B SMART	Both		Dubai, UAE	6	1	1601.00	Debit	2026-01-06 14:29:21.639172
59	UMAIR ROCKER	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 14:30:11.27838
60	USA EXP	Expense		USA Expense	6	28	0.00	Debit	2026-01-06 14:30:45.115368
62	WAJAHAT	Both			6	1	200.00	Credit	2026-01-06 14:32:18.008356
63	WALEED BHAI AUS	Both		Australia	6	1	6329.00	Debit	2026-01-06 14:33:19.602425
64	WORLD MART	Both		Dubai, UAE	6	1	3487.00	Credit	2026-01-06 14:34:05.815749
65	ZAIDI GUJRANWALA 	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-06 14:34:28.360022
66	ZEESHAN	Both		Dubai, UAE	6	1	5770.00	Debit	2026-01-06 14:35:10.429398
67	HASSAN ASHRAF	Both		Dubai, UAE	6	1	46220.00	Debit	2026-01-06 15:05:48.887913
68	DJI HUB	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-07 13:11:57.474502
69	METRO DELUXE	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-07 13:52:25.537671
5	MUDASSIR	Both	+92 332 2563123	Karachi, Pakistan	6	1	15921.00	Debit	2026-01-05 14:57:31.959174
4	WAHEED BHAI	Both	+61 421 022 212	Sydney Australia (Vendor)	6	1	641854.00	Debit	2026-01-05 13:51:50.504729
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payments (payment_id, party_id, account_id, amount, payment_date, method, reference_no, journal_id, date_created, notes, description) FROM stdin;
1	39	5	15000.00	2026-01-06	Cash	PMT-1	116	2026-01-06 16:07:26.313194	\N	loss for hassan Ashraf 
\.


--
-- Data for Name: purchaseinvoices; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchaseinvoices (purchase_invoice_id, vendor_id, invoice_date, total_amount, journal_id) FROM stdin;
1	1	2026-01-04	85.00	2
63	6	2026-01-05	21627.52	67
2	1	2026-01-04	5.00	3
37	4	2026-01-05	20017.40	39
3	2	2026-01-04	6924.80	4
4	4	2026-01-05	218815.17	6
5	4	2026-01-05	247151.90	7
38	4	2026-01-05	1544.65	40
6	4	2026-01-05	162.00	8
7	4	2026-01-05	4568.00	9
8	4	2026-01-05	90817.98	10
39	2	2026-01-05	16.00	41
9	4	2026-01-05	42344.00	11
10	4	2026-01-05	86661.97	12
64	6	2026-01-05	41390.40	68
11	4	2026-01-05	61821.00	13
40	5	2026-01-05	14.00	43
12	4	2026-01-05	9011.10	14
13	4	2026-01-05	30156.06	15
14	4	2026-01-05	35924.00	16
41	5	2026-01-05	5300.00	44
15	4	2026-01-05	27525.40	17
16	4	2026-01-05	35790.30	18
17	4	2026-01-05	1518.00	19
42	5	2026-01-05	13882.00	45
18	4	2026-01-05	3316.00	20
19	4	2026-01-05	157525.37	21
65	6	2026-01-05	2584.80	69
20	4	2026-01-05	39117.52	22
43	5	2026-01-05	9700.00	46
21	4	2026-01-05	162637.00	23
22	4	2026-01-05	29680.00	24
23	4	2026-01-05	6624.80	25
44	6	2026-01-05	22972.20	48
24	4	2026-01-05	8415.00	26
25	4	2026-01-05	925.00	27
79	5	2026-01-08	79860.00	130
26	4	2026-01-05	7507.26	28
45	6	2026-01-05	23654.88	49
27	4	2026-01-05	429416.37	29
28	4	2026-01-05	1028.00	30
66	4	2026-01-05	69394.83	72
29	4	2026-01-05	10040.82	31
46	6	2026-01-05	6003.65	50
30	4	2026-01-05	757.89	32
31	4	2026-01-05	20824.10	33
32	4	2026-01-05	23657.40	34
47	6	2026-01-05	1007.00	51
33	4	2026-01-05	1732.32	35
34	4	2026-01-05	20761.55	36
35	4	2026-01-05	103.21	37
48	6	2026-01-05	7110.82	52
36	4	2026-01-05	12022.38	38
67	7	2026-01-05	60.00	74
49	6	2026-01-05	4.00	53
50	6	2026-01-05	453.00	54
51	6	2026-01-05	7760.28	55
68	8	2026-01-05	77.00	77
52	6	2026-01-05	2586.76	56
53	6	2026-01-05	646.00	57
54	6	2026-01-05	8862.00	58
69	5	2026-01-07	2700.00	118
55	6	2026-01-05	791.00	59
56	6	2026-01-05	6111.00	60
57	6	2026-01-05	1452.98	61
70	5	2026-01-07	2800.00	119
58	6	2026-01-05	4577.00	62
59	6	2026-01-05	14595.68	63
60	6	2026-01-05	3091.00	64
71	5	2026-01-07	1650.00	120
61	6	2026-01-05	36408.00	65
62	6	2026-01-05	42351.50	66
72	5	2026-01-07	2430.00	121
74	2	2026-01-07	32.00	123
75	4	2026-01-07	11970.00	125
76	6	2026-01-07	21895.65	127
77	6	2026-01-08	113904.00	128
78	5	2026-01-08	81940.00	129
\.


--
-- Data for Name: purchaseitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchaseitems (purchase_item_id, purchase_invoice_id, item_id, quantity, unit_price) FROM stdin;
1	1	29	85	1.00
2	2	94	5	1.00
3	3	31	1	4.00
4	3	110	1	4.00
5	3	111	1	4.00
6	3	112	1	4.00
7	3	113	1	4.00
8	3	114	1	4.00
9	3	115	1	4.00
10	3	70	1	3590.00
11	3	79	1	3302.80
12	3	92	1	4.00
13	4	2	37	1513.37
14	4	2	11	1495.18
15	4	2	9	1513.33
16	4	2	9	1505.77
17	4	2	5	1505.80
18	4	2	9	1362.00
19	4	2	67	1483.80
20	5	3	50	1147.66
21	5	3	9	1152.44
22	5	3	10	1141.90
23	5	3	9	1207.22
24	5	3	8	1207.25
25	5	3	7	1207.28
26	5	3	124	1121.00
27	6	4	1	162.00
28	7	5	4	1142.00
29	8	6	3	3353.66
30	8	6	10	3351.60
31	8	6	4	3374.50
32	8	6	10	3374.30
33	9	7	4	10586.00
34	10	8	3	7820.00
35	10	8	3	7953.66
36	10	8	3	7900.33
37	10	8	2	7820.00
38	11	9	20	2492.75
39	11	9	5	2393.20
40	12	10	3	3003.70
41	13	11	11	2741.46
42	14	12	28	1283.00
43	15	13	20	1376.27
44	16	14	36	994.18
45	17	15	6	253.00
46	18	16	2	1658.00
47	19	17	12	2988.50
48	19	17	10	2988.00
49	19	17	10	2671.20
50	19	17	23	2829.19
51	20	18	26	1504.52
52	21	19	200	633.88
53	21	19	50	717.22
54	22	20	500	59.36
55	23	21	7	946.40
56	24	22	10	841.50
57	25	23	10	92.50
58	26	24	2	3753.63
59	27	1	50	957.58
60	27	1	159	952.81
61	27	1	60	957.60
62	27	1	106	952.80
63	27	1	15	957.50
64	27	1	23	955.21
65	27	1	37	952.85
66	28	25	1	1028.00
67	29	26	6	901.14
68	29	26	3	1544.66
69	30	72	3	252.63
70	31	73	10	2082.41
71	32	74	18	1314.30
72	33	117	4	433.08
73	34	118	3	409.26
74	34	119	3	322.64
75	34	119	1	324.81
76	34	120	1	344.29
77	34	121	3	236.02
78	34	122	2	1056.71
79	34	122	6	979.24
80	34	123	1	524.50
81	34	124	1	4304.33
82	34	125	10	437.10
83	35	116	1	103.21
84	36	126	3	4007.46
85	37	71	40	313.98
86	37	71	7	300.75
87	37	71	10	324.81
88	37	71	2	299.25
89	37	71	5	301.27
90	38	26	1	1544.65
91	39	79	1	4.00
92	39	127	1	4.00
93	39	88	1	4.00
94	39	89	1	4.00
95	40	97	1	1.00
96	40	98	1	1.00
97	40	99	1	1.00
98	40	100	6	1.00
99	40	128	1	1.00
100	40	66	1	1.00
101	40	101	1	1.00
102	40	102	2	1.00
103	41	129	1	1400.00
104	41	129	1	1500.00
105	41	130	2	1200.00
106	42	103	2	1400.00
107	42	89	1	2000.00
108	42	104	4	1350.00
109	42	90	1	1300.00
110	42	90	1	130.00
111	42	105	1	1100.00
112	42	106	2	1.00
113	42	105	1	1150.00
114	43	89	1	2050.00
115	43	88	1	3600.00
116	43	88	1	3450.00
117	43	93	1	600.00
118	44	27	9	2300.80
119	44	27	1	2265.00
120	45	2	2	1546.00
121	45	2	13	1581.76
122	46	3	2	1222.30
123	46	3	3	1186.35
124	47	28	2	503.50
125	48	4	18	197.72
126	48	4	19	186.94
127	49	5	1	4.00
128	50	29	3	151.00
129	51	30	6	1293.38
130	52	16	2	1293.38
131	53	31	1	646.00
132	54	32	2	1797.50
133	54	33	2	269.50
134	54	34	2	503.50
135	54	35	1	629.00
136	54	36	1	306.00
137	54	37	1	629.00
138	54	38	1	449.00
139	54	39	1	1708.00
140	55	25	1	791.00
141	56	40	4	1527.75
142	57	41	3	287.66
143	57	41	2	295.00
144	58	42	4	683.00
145	58	43	1	449.00
146	58	44	1	4.00
147	58	45	1	180.00
148	58	46	2	269.50
149	58	47	1	108.00
150	58	48	1	270.00
151	58	49	1	295.00
152	59	26	9	1258.25
153	59	26	3	629.12
154	59	26	1	665.07
155	59	26	1	719.00
156	60	50	1	1258.00
157	60	51	1	1258.00
158	60	52	1	575.00
159	61	53	1	8628.00
160	61	54	1	9886.00
161	61	55	1	2685.00
162	61	56	1	2517.00
163	61	56	1	2624.00
164	61	61	1	4008.00
165	61	62	1	2334.00
166	61	59	1	2000.00
167	61	60	1	1726.00
168	62	63	3	1033.50
169	62	64	1	5206.00
170	62	65	1	3595.00
171	62	66	1	3110.00
172	62	66	1	3595.00
173	62	66	1	3109.00
174	62	67	4	4170.25
175	62	67	1	3955.00
176	63	68	1	3523.10
177	63	69	1	5932.00
178	63	69	1	4389.00
179	63	69	1	4494.00
180	63	70	1	3289.42
181	64	75	1	3666.90
182	64	76	1	4853.25
183	64	77	1	1974.50
184	64	78	1	3091.70
185	64	79	1	4.00
186	64	79	1	4.00
187	64	79	1	3379.30
188	64	79	1	2228.90
189	64	79	1	3051.50
190	64	80	1	4.00
191	64	80	1	4.00
192	64	81	1	1941.30
193	64	82	1	2157.00
194	64	82	1	1833.45
195	64	83	1	2157.00
196	64	84	1	4.00
197	64	85	1	4.00
198	64	86	1	1581.80
199	64	87	1	1078.50
200	64	88	1	3590.00
201	64	89	1	1617.75
202	64	90	1	1078.50
203	64	91	1	790.90
204	64	92	1	575.20
205	64	93	1	539.20
206	64	93	1	179.75
207	65	79	1	2584.80
208	66	75	9	5627.87
209	66	75	3	6248.00
210	67	109	6	10.00
211	68	107	10	7.00
212	68	108	1	7.00
213	69	103	2	1350.00
214	70	103	2	1400.00
215	71	132	1	1650.00
216	72	79	1	2430.00
224	74	133	1	4.00
225	74	134	1	4.00
226	74	135	1	4.00
227	74	136	1	4.00
228	74	79	2	4.00
229	74	137	1	4.00
230	74	81	1	4.00
231	75	131	2	5985.00
232	76	80	1	1938.60
233	76	81	1	1938.60
234	76	79	1	4.00
235	76	137	1	4.00
236	76	138	1	1006.60
237	76	75	1	3666.90
238	76	76	1	3235.50
239	76	82	1	1797.50
240	76	86	1	1438.00
241	76	68	1	3127.65
242	76	104	1	1222.30
243	76	56	1	2516.00
244	77	43	3	450.00
245	77	42	4	702.00
246	77	106	1	648.00
247	77	105	1	720.00
248	77	152	1	2304.00
249	77	153	3	1512.00
250	77	151	1	5868.00
251	77	149	2	5580.00
252	77	150	1	6012.00
253	77	154	1	1080.00
254	77	158	1	1080.00
255	77	157	2	1080.00
256	77	156	1	1260.00
257	77	155	1	1260.00
258	77	63	2	1026.00
259	77	146	1	1980.00
260	77	146	1	2160.00
261	77	148	1	1710.00
262	77	147	1	1548.00
263	77	88	1	3402.00
264	77	66	1	3060.00
265	77	136	1	630.00
266	77	144	1	720.00
267	77	86	1	1476.00
268	77	143	1	1512.00
269	77	138	1	1008.00
270	77	141	1	1692.00
271	77	103	1	1260.00
272	77	141	1	1692.00
273	77	80	1	2232.00
274	77	79	1	2628.00
275	77	140	1	2232.00
276	77	142	4	738.00
277	77	68	7	3168.00
278	77	68	3	3240.00
279	77	75	1	3528.00
280	77	145	1	288.00
281	78	152	1	2200.00
282	78	152	2	2350.00
283	78	152	7	2380.00
284	78	67	1	3900.00
285	78	77	2	1900.00
286	78	70	1	2500.00
287	78	70	8	2600.00
288	78	159	2	2600.00
289	78	68	1	2500.00
290	78	68	6	3280.00
291	79	106	2	900.00
292	79	152	7	2380.00
293	79	160	3	1900.00
294	79	67	1	4100.00
295	79	77	4	1900.00
296	79	70	7	2600.00
297	79	68	2	3060.00
298	79	68	6	3280.00
\.


--
-- Data for Name: purchasereturnitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchasereturnitems (return_item_id, purchase_return_id, item_id, unit_price, serial_number) FROM stdin;
\.


--
-- Data for Name: purchasereturns; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchasereturns (purchase_return_id, vendor_id, return_date, total_amount, journal_id) FROM stdin;
\.


--
-- Data for Name: purchaseunits; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchaseunits (unit_id, purchase_item_id, serial_number, in_stock) FROM stdin;
1	1	cddragonage004	t
2	1	cddragonage005	t
3	1	cddragonage006	t
4	1	cddragonage007	t
5	1	cddragonage008	t
6	1	cddragonage009	t
7	1	cddragonage010	t
8	1	cddragonage011	t
9	1	cddragonage012	t
10	1	cddragonage013	t
11	1	cddragonage014	t
12	1	cddragonage015	t
13	1	cddragonage016	t
14	1	cddragonage017	t
15	1	cddragonage018	t
16	1	cddragonage019	t
17	1	cddragonage020	t
18	1	cddragonage021	t
19	1	cddragonage022	t
20	1	cddragonage023	t
21	1	cddragonage024	t
22	1	cddragonage025	t
23	1	cddragonage026	t
24	1	cddragonage027	t
25	1	cddragonage028	t
26	1	cddragonage029	t
27	1	cddragonage030	t
28	1	cddragonage031	t
29	1	cddragonage032	t
30	1	cddragonage033	t
31	1	cddragonage034	t
32	1	cddragonage035	t
33	1	cddragonage036	t
34	1	cddragonage037	t
35	1	cddragonage038	t
36	1	cddragonage039	t
37	1	cddragonage040	t
38	1	cddragonage041	t
39	1	cddragonage042	t
40	1	cddragonage043	t
41	1	cddragonage044	t
42	1	cddragonage045	t
43	1	cddragonage046	t
44	1	cddragonage047	t
45	1	cddragonage048	t
46	1	cddragonage049	t
47	1	cddragonage050	t
48	1	cddragonage051	t
49	1	cddragonage052	t
50	1	cddragonage053	t
51	1	cddragonage054	t
52	1	cddragonage055	t
53	1	cddragonage056	t
54	1	cddragonage057	t
55	1	cddragonage058	t
56	1	cddragonage059	t
57	1	cddragonage060	t
58	1	cddragonage061	t
59	1	cddragonage062	t
60	1	cddragonage063	t
61	1	cddragonage064	t
62	1	cddragonage065	t
63	1	cddragonage066	t
64	1	cddragonage067	t
65	1	cddragonage068	t
66	1	cddragonage069	t
67	1	cddragonage070	t
68	1	cddragonage071	t
69	1	cddragonage072	t
70	1	cddragonage073	t
71	1	cddragonage074	t
72	1	cddragonage075	t
73	1	cddragonage076	t
74	1	cddragonage077	t
75	1	cddragonage078	t
76	1	cddragonage079	t
77	1	cddragonage080	t
78	1	cddragonage081	t
79	1	cddragonage082	t
80	1	cddragonage083	t
81	1	cddragonage084	t
82	1	cddragonage085	t
83	1	cddragonage086	t
84	1	cddragonage087	t
85	1	cddragonage088	t
86	2	skylinev2pouch30001	t
87	2	skylinev2pouch30002	t
88	2	skylinev2pouch30003	t
89	2	skylinev2pouch30004	t
90	2	skylinev2pouch30005	t
91	3	XKW50103180253	t
92	4	196214119062	t
93	5	SV30F9ZMC	t
94	6	810116381937	t
95	7	PNT0E3015253PTAU	t
96	8	prestoelectrickettle001	t
97	9	353138601828735	t
98	10	355122367429969	t
99	11	355067541901427	t
100	12	SHP4MF2TF9Q	t
101	13	S01E45601CE810572356	t
102	13	S01E45601CE810570281	t
103	13	S01E45601CE810595951	t
104	13	S01E45601CE810570323	t
105	13	S01E45601CE810573044	t
106	13	S01E45601CE810565094	t
107	13	S01E45601CE810573039	t
108	13	S01E45501CE810557417	t
109	13	S01F44C01NXM10424000	t
110	13	S01E45601CE810599344	t
111	13	S01E45601CE810573040	t
112	13	S01E45601CE810573043	t
113	13	S01E45601CE810599343	t
114	13	S01E45601CE810565069	t
115	13	S01F55901DR210321979	t
116	13	S01E45601CE810585832	t
117	13	S01F55801DR210266420	t
118	13	S01E45601CE810576101	t
119	13	S01E45601CE810580025	t
120	13	S01E45601CE810578019	t
121	13	S01E45601CE810578011	t
122	13	S01E45601CE810576162	t
123	13	ps5slim00001	t
124	13	ps5slim00002	t
125	13	ps5slim00003	t
126	13	ps5slim00004	t
127	13	ps5slim00005	t
128	13	ps5slim00006	t
129	13	ps5slim00007	t
130	13	ps5slim00008	t
131	13	ps5slim00009	t
132	13	ps5slim00010	t
133	13	ps5slim00011	t
134	13	ps5slim00012	t
135	13	ps5slim00013	t
136	13	ps5slim00014	t
137	13	ps5slim00015	t
138	14	ps5slim00016	t
139	14	ps5slim00017	t
140	14	ps5slim00018	t
141	14	ps5slim00019	t
142	14	ps5slim00020	t
143	14	ps5slim00021	t
144	14	ps5slim00022	t
145	14	ps5slim00023	t
146	14	ps5slim00024	t
147	14	ps5slim00025	t
148	14	ps5slim00026	t
149	15	ps5slim00027	t
150	15	ps5slim00028	t
151	15	ps5slim00029	t
152	15	ps5slim00030	t
153	15	ps5slim00031	t
154	15	ps5slim00032	t
155	15	ps5slim00033	t
156	15	ps5slim00034	t
157	15	ps5slim00035	t
158	16	ps5slim00036	t
159	16	ps5slim00037	t
160	16	ps5slim00038	t
161	16	ps5slim00039	t
162	16	ps5slim00040	t
163	16	ps5slim00041	t
164	16	ps5slim00042	t
165	16	ps5slim00043	t
166	16	ps5slim00044	t
167	17	ps5slim00045	t
168	17	ps5slim00046	t
169	17	ps5slim00047	t
170	17	ps5slim00048	t
171	17	ps5slim00049	t
172	18	ps5slim00050	t
173	18	ps5slim00051	t
174	18	ps5slim00052	t
175	18	ps5slim00053	t
176	18	ps5slim00054	t
177	18	ps5slim00055	t
178	18	ps5slim00056	t
179	18	ps5slim00057	t
180	18	ps5slim00058	t
181	19	ps5slim00059	t
182	19	ps5slim00060	t
183	19	ps5slim00061	t
184	19	ps5slim00062	t
185	19	ps5slim00063	t
186	19	ps5slim00064	t
187	19	ps5slim00065	t
188	19	ps5slim00066	t
189	19	ps5slim00067	t
190	19	ps5slim00068	t
191	19	ps5slim00069	t
192	19	ps5slim00070	t
193	19	ps5slim00071	t
194	19	ps5slim00072	t
195	19	ps5slim00073	t
196	19	ps5slim00074	t
197	19	ps5slim00075	t
198	19	ps5slim00076	t
199	19	ps5slim00077	t
200	19	ps5slim00078	t
201	19	ps5slim00079	t
202	19	ps5slim00080	t
203	19	ps5slim00081	t
204	19	ps5slim00082	t
205	19	ps5slim00083	t
206	19	ps5slim00084	t
207	19	ps5slim00085	t
208	19	ps5slim00086	t
209	19	ps5slim00087	t
210	19	ps5slim00088	t
211	19	ps5slim00089	t
212	19	ps5slim00090	t
213	19	ps5slim00091	t
214	19	ps5slim00092	t
215	19	ps5slim00093	t
216	19	ps5slim00094	t
217	19	ps5slim00095	t
218	19	ps5slim00096	t
219	19	ps5slim00097	t
220	19	ps5slim00098	t
221	19	ps5slim00099	t
222	19	ps5slim00100	t
223	19	ps5slim00101	t
224	19	ps5slim00102	t
225	19	ps5slim00103	t
226	19	ps5slim00104	t
227	19	ps5slim00105	t
228	19	ps5slim00106	t
229	19	ps5slim00107	t
230	19	ps5slim00108	t
231	19	ps5slim00109	t
232	19	ps5slim00110	t
233	19	ps5slim00111	t
234	19	ps5slim00112	t
235	19	ps5slim00113	t
236	19	ps5slim00114	t
237	19	ps5slim00115	t
238	19	ps5slim00116	t
239	19	ps5slim00117	t
240	19	ps5slim00118	t
241	19	ps5slim00119	t
242	19	ps5slim00120	t
243	19	ps5slim00121	t
244	19	ps5slim00122	t
245	19	ps5slim00123	t
246	19	ps5slim00124	t
247	19	ps5slim00125	t
248	20	S01V558019CN10258177	t
249	20	S01F55701RRC10260424	t
250	20	S01V558019CN10255412	t
251	20	S01F55701RRC10252871	t
252	20	S01F55701RRC10253380	t
253	20	S01F55701RRC10260047	t
254	20	S01V558019CN10258939	t
255	20	S01F55801RRC10263365	t
256	20	S01F55701RRC10259204	t
257	20	S01F55701RRC10252786	t
258	20	S01F55701RRC10252873	t
259	20	S01F55701RRC10252785	t
260	20	S01F55701RRC10252801	t
261	20	S01F55701RRC10253418	t
262	20	S01F55801RRC10263353	t
263	20	S01V558019CN10256717	t
264	20	S01F55701RRC10252722	t
265	20	S01F55701RRC10252874	t
266	20	S01F55801RRC10263356	t
267	20	S01F55801RRC10263364	t
268	20	S01F55701RRC10253425	t
269	20	S01F55701RRC10252869	t
270	20	S01F55901RRC10282523	t
271	20	S01F55801RRC10263355	t
272	20	S01F55901RRC10287502	t
273	20	S01F55701RRC10252798	t
274	20	S01F55901RRC10290683	t
275	20	S01V558019CN10250136	t
276	20	S01F55901RRC10290623	t
277	20	S01F55801RRC10263357	t
278	20	S01F55701RRC10252721	t
279	20	S01F55701RRC10253396	t
280	20	S01F55801RRC10263351	t
281	20	S01F55901RRC10303746	t
282	20	S01V558019CN10256466	t
283	20	S01F55701RRC10252797	t
284	20	S01F55701RRC10253379	t
285	20	S01F55901RRC10304141	t
286	20	S01F55901RRC10289942	t
287	20	S01E456016ER10403419	t
288	20	ps5slimdigital00001	t
289	20	ps5slimdigital00002	t
290	20	ps5slimdigital00003	t
291	20	ps5slimdigital00004	t
292	20	ps5slimdigital00005	t
293	20	ps5slimdigital00006	t
294	20	ps5slimdigital00007	t
295	20	ps5slimdigital00008	t
296	20	ps5slimdigital00009	t
297	20	ps5slimdigital00010	t
298	21	ps5slimdigital00011	t
299	21	ps5slimdigital00012	t
300	21	ps5slimdigital00013	t
301	21	ps5slimdigital00014	t
302	21	ps5slimdigital00015	t
303	21	ps5slimdigital00016	t
304	21	ps5slimdigital00017	t
305	21	ps5slimdigital00018	t
306	21	ps5slimdigital00019	t
307	22	ps5slimdigital00020	t
308	22	ps5slimdigital00021	t
309	22	ps5slimdigital00022	t
310	22	ps5slimdigital00023	t
311	22	ps5slimdigital00024	t
312	22	ps5slimdigital00025	t
313	22	ps5slimdigital00026	t
314	22	ps5slimdigital00027	t
315	22	ps5slimdigital00028	t
316	22	ps5slimdigital00029	t
317	23	ps5slimdigital00030	t
318	23	ps5slimdigital00031	t
319	23	ps5slimdigital00032	t
320	23	ps5slimdigital00033	t
321	23	ps5slimdigital00034	t
322	23	ps5slimdigital00035	t
323	23	ps5slimdigital00036	t
324	23	ps5slimdigital00037	t
325	23	ps5slimdigital00038	t
326	24	ps5slimdigital00039	t
327	24	ps5slimdigital00040	t
328	24	ps5slimdigital00041	t
329	24	ps5slimdigital00042	t
330	24	ps5slimdigital00043	t
331	24	ps5slimdigital00044	t
332	24	ps5slimdigital00045	t
333	24	ps5slimdigital00046	t
334	25	ps5slimdigital00047	t
335	25	ps5slimdigital00048	t
336	25	ps5slimdigital00049	t
337	25	ps5slimdigital00050	t
338	25	ps5slimdigital00051	t
339	25	ps5slimdigital00052	t
340	25	ps5slimdigital00053	t
341	26	ps5slimdigital00054	t
342	26	ps5slimdigital00055	t
343	26	ps5slimdigital00056	t
344	26	ps5slimdigital00057	t
345	26	ps5slimdigital00058	t
346	26	ps5slimdigital00059	t
347	26	ps5slimdigital00060	t
348	26	ps5slimdigital00061	t
349	26	ps5slimdigital00062	t
350	26	ps5slimdigital00063	t
351	26	ps5slimdigital00064	t
352	26	ps5slimdigital00065	t
353	26	ps5slimdigital00066	t
354	26	ps5slimdigital00067	t
355	26	ps5slimdigital00068	t
356	26	ps5slimdigital00069	t
357	26	ps5slimdigital00070	t
358	26	ps5slimdigital00071	t
359	26	ps5slimdigital00072	t
360	26	ps5slimdigital00073	t
361	26	ps5slimdigital00074	t
362	26	ps5slimdigital00075	t
363	26	ps5slimdigital00076	t
364	26	ps5slimdigital00077	t
365	26	ps5slimdigital00078	t
366	26	ps5slimdigital00079	t
367	26	ps5slimdigital00080	t
368	26	ps5slimdigital00081	t
369	26	ps5slimdigital00082	t
370	26	ps5slimdigital00083	t
371	26	ps5slimdigital00084	t
372	26	ps5slimdigital00085	t
373	26	ps5slimdigital00086	t
374	26	ps5slimdigital00087	t
375	26	ps5slimdigital00088	t
376	26	ps5slimdigital00089	t
377	26	ps5slimdigital00090	t
378	26	ps5slimdigital00091	t
379	26	ps5slimdigital00092	t
380	26	ps5slimdigital00093	t
381	26	ps5slimdigital00094	t
382	26	ps5slimdigital00095	t
383	26	ps5slimdigital00096	t
384	26	ps5slimdigital00097	t
385	26	ps5slimdigital00098	t
386	26	ps5slimdigital00099	t
387	26	ps5slimdigital00100	t
388	26	ps5slimdigital00101	t
389	26	ps5slimdigital00102	t
390	26	ps5slimdigital00103	t
391	26	ps5slimdigital00104	t
392	26	ps5slimdigital00105	t
393	26	ps5slimdigital00106	t
394	26	ps5slimdigital00107	t
395	26	ps5slimdigital00108	t
396	26	ps5slimdigital00109	t
397	26	ps5slimdigital00110	t
398	26	ps5slimdigital00111	t
399	26	ps5slimdigital00112	t
400	26	ps5slimdigital00113	t
401	26	ps5slimdigital00114	t
402	26	ps5slimdigital00115	t
403	26	ps5slimdigital00116	t
404	26	ps5slimdigital00117	t
405	26	ps5slimdigital00118	t
406	26	ps5slimdigital00119	t
407	26	ps5slimdigital00120	t
408	26	ps5slimdigital00121	t
409	26	ps5slimdigital00122	t
410	26	ps5slimdigital00123	t
411	26	ps5slimdigital00124	t
412	26	ps5slimdigital00125	t
413	26	ps5slimdigital00126	t
414	26	ps5slimdigital00127	t
415	26	ps5slimdigital00128	t
416	26	ps5slimdigital00129	t
417	26	ps5slimdigital00130	t
418	26	ps5slimdigital00131	t
419	26	ps5slimdigital00132	t
420	26	ps5slimdigital00133	t
421	26	ps5slimdigital00134	t
422	26	ps5slimdigital00135	t
423	26	ps5slimdigital00136	t
424	26	ps5slimdigital00137	t
425	26	ps5slimdigital00138	t
426	26	ps5slimdigital00139	t
427	26	ps5slimdigital00140	t
428	26	ps5slimdigital00141	t
429	26	ps5slimdigital00142	t
430	26	ps5slimdigital00143	t
431	26	ps5slimdigital00144	t
432	26	ps5slimdigital00145	t
433	26	ps5slimdigital00146	t
434	26	ps5slimdigital00147	t
435	26	ps5slimdigital00148	t
436	26	ps5slimdigital00149	t
437	26	ps5slimdigital00150	t
438	26	ps5slimdigital00151	t
439	26	ps5slimdigital00152	t
440	26	ps5slimdigital00153	t
441	26	ps5slimdigital00154	t
442	26	ps5slimdigital00155	t
443	26	ps5slimdigital00156	t
444	26	ps5slimdigital00157	t
445	26	ps5slimdigital00158	t
446	26	ps5slimdigital00159	t
447	26	ps5slimdigital00160	t
448	26	ps5slimdigital00161	t
449	26	ps5slimdigital00162	t
450	26	ps5slimdigital00163	t
451	26	ps5slimdigital00164	t
452	26	ps5slimdigital00165	t
453	26	ps5slimdigital00166	t
454	26	ps5slimdigital00167	t
455	26	ps5slimdigital00168	t
456	26	ps5slimdigital00169	t
457	26	ps5slimdigital00170	t
458	26	ps5slimdigital00171	t
459	26	ps5slimdigital00172	t
460	26	ps5slimdigital00173	t
461	26	ps5slimdigital00174	t
462	26	ps5slimdigital00175	t
463	26	ps5slimdigital00176	t
464	26	ps5slimdigital00177	t
465	27	dualsensewirelesscontroller00038	t
466	28	psvr200001	t
467	28	psvr200002	t
468	28	psvr200003	t
469	28	psvr200004	t
470	29	1581F9DEC2592029S107	t
471	29	1581F9DEC258W02910YR	t
472	29	1581F9DEC258S029B1UX	t
473	30	1581F9DEC258W029589P	t
474	30	1581F9DEC258W0291QN2	t
475	30	1581F9DEC258H029J9SS	t
476	30	1581F9DEC25920299MLT	t
477	30	1581F9DEC259A029V3M1	t
478	30	1581F9DEC258U029X6E4	t
479	30	1581F9DEC2592029L653	t
480	30	1581F9DEC258S0294XWP	t
481	30	1581F9DEC258S0292B6T	t
482	30	1581F9DEC258W0293K3G	t
483	31	1581F9DEC258M0298CTZ	t
484	31	1581F9DEC258W029027D	t
485	31	1581F9DEC259202929ZB	t
486	31	1581F9DEC258U0294KUU	t
487	32	1581F9DEC25AL0291CTX	t
488	32	1581F9DEC25AQ0297HQU	t
489	32	1581F9DEC258W0291F67	t
490	32	1581F9DEC25AQ029SBVR	t
491	32	1581F9DEC25A90292N7Y	t
492	32	1581F9DEC25AK029B5VH	t
493	32	1581F9DEC25AL029R2T3	t
494	32	1581F9DEC25B3029PV6M	t
495	32	1581F9DEC25AL029CRJ2	t
496	32	1581F9DEC25AL0294V02	t
497	33	1581F986C258U0023MZ5	t
498	33	1581F986C257S0022VS4	t
499	33	djimavic4ceratorcombo0001	t
500	33	djimavic4ceratorcombo0002	t
501	34	1581F8LQC255A0021ZQA	t
502	34	1581F8LQC253G0020HJ4	t
503	34	1581F8LQC252U00200ND	t
504	35	djimavic4proflymorecombo00001	t
505	35	djimavic4proflymorecombo00002	t
506	35	djimavic4proflymorecombo00003	t
507	36	djimavic4proflymorecombo00004	t
508	36	djimavic4proflymorecombo00005	t
509	36	djimavic4proflymorecombo00006	t
510	37	djimavic4proflymorecombo00007	t
511	37	djimavic4proflymorecombo00008	t
512	38	1581F6Z9A248WML3S898	t
513	38	1581F6Z9A248WML3E8GD	t
514	38	1581F6Z9C2519003AY0G	t
515	38	1581F6Z9C2557003FNTS	t
516	38	1581F6Z9C2516003AMFM	t
517	38	1581F6Z9C2519003AYFZ	t
518	38	1581F6Z9C2557003FN58	t
519	38	1581F6Z9C2554003FALV	t
520	38	1581F6Z9A248WML30TXY	t
521	38	1581F6Z9C245N003TEC4	t
522	38	1581F6Z9A24CPML325EM	t
523	38	1581F6Z9C2517003AMZ4	t
524	38	1581F6Z9C2542003DDKL	t
525	38	1581F6Z9C2518003ASST	t
526	38	1581F6Z9A248WML3X76X	t
527	38	1581F6Z9C23AP003DC6C	t
528	38	1581F6Z9A24CRML3JZY0	t
529	38	1581F6Z9A24CRML3CZ3H	t
530	38	1581F6Z9A248WML359Z9	t
531	38	1581F6Z9A248WML3V5FG	t
532	39	1581F6Z9A248WML302VE	t
533	39	1581F6Z9A248WML33640	t
534	39	1581F6Z9A24CRML37S28	t
535	39	1581F6Z9A24CRML3TKW1	t
536	39	1581F6Z9A248WML3KK1E	t
537	40	1581F6Z9C2489003YS6P	t
538	40	1581F6Z9A24A1ML3ZC4G	t
539	40	1581F6Z9A249DML38T1H	t
540	41	1581F6Z9C254F003E8PX	t
541	41	1581F6Z9C251C003BCNG	t
542	41	1581F6Z9C2458003SP1X	t
543	41	1581F6Z9C251D003BKKT	t
544	41	1581F6Z9C253R003CSR1	t
545	41	1581F6Z9C251D003BN7E	t
546	41	1581F6Z9C251C003BAQ4	t
547	41	1581F6Z9C254D003E2UE	t
548	41	1581F6Z9C24AX0034Z36	t
549	41	1581F6Z9C254C003E003	t
550	41	1581F6Z9C2466003V1W2	t
551	42	1581F8PJC253V001GYLW	t
552	42	1581F8PJC24B5001BCXM	t
553	42	1581F8PJC24BL0020SV0	t
554	42	1581F8PJC24CR0022N4Y	t
555	42	1581F8PJC24BN00210EG	t
556	42	1581F8PJC24BN00210P6	t
557	42	1581F8PJC24CS0022S3P	t
558	42	1581F8PJC24CR0022JYA	t
559	42	1581F8PJC24CR0022MDB	t
560	42	1581F8PJC24B6001BKLQ	t
561	42	1581F8PJC253V001H1V2	t
562	42	1581F8PJC24B6001BKXK	t
563	42	1581F8PJC24BF0020EU1	t
564	42	1581F8PJC24CR0022M1Z	t
565	42	1581F8PJC24CQ0022HSV	t
566	42	1581F8PJC24CR0022MKF	t
567	42	1581F8PJC24CQ0022HMQ	t
568	42	1581F8PJC24BL0020T9Q	t
569	42	1581F8PJC24CR0022LFH	t
570	42	1581F8PJC24AK0009PEJ	t
571	42	1581F8PJC253V001H1V5	t
572	42	1581F8PJC24CR0022JYK	t
573	42	1581F8PJC24BC00202KW	t
574	42	1581F8PJC24BN0020ZS4	t
575	42	1581F8PJC24BP00212CD	t
576	42	1581F8PJC24CR0022K1X	t
577	42	1581F8PJC24BP002137K	t
578	42	1581F8PJC24BL0020R72	t
579	43	5WTCN7A002A1J8	t
580	43	5WTCN4S00223K2	t
581	43	5WTZN8R0024KFH	t
582	43	5WTZN7C002Y95X	t
583	43	5WTZN8F0021WDF	t
584	43	5WTCN7A002A365	t
585	43	5WTCN7A002A1A0	t
586	43	5WTCN7A002A66D	t
587	43	5WTCN7C002ABL0	t
588	43	5WTCN720028WVX	t
589	43	5WTCN780029AU8	t
590	43	5WTCN7A002A3B8	t
591	43	5WTCN7A002A756	t
592	43	5WTZN8K002D1RW	t
593	43	5WTCN7A002A2LJ	t
594	43	5WTCN780029GGB	t
595	43	5WTZN8J0026Y89	t
596	43	5WTZN8R0020E8T	t
597	43	5WTZN8P00292UP	t
598	43	5WTCN5K00214VP	t
599	44	9SDXN6U0122PYP	t
600	44	9SDXN5G01215JY	t
601	44	8PBWN8L006A05Z	t
602	44	9SDXN570120QYN	t
603	44	9SDXN6D012292X	t
604	44	9SDXN7G0221TMP	t
605	44	9SDXN980233VD9	t
606	44	9SDXN6Q0122K0Z	t
607	44	9SDXN9N012613Q	t
608	44	9SDXN5K0220150	t
609	44	9SDXN570120SUR	t
610	44	9SDXN9N01261ER	t
611	44	9SDXN9N0126152	t
612	44	9SDXN6S02219C8	t
613	44	9SDXN6U0122PYR	t
614	44	9SDXN9N0126472	t
615	44	8PBWN8K0069TGQ	t
616	44	9SDXN5E01214SH	t
617	44	8PBWN8M006A8XU	t
618	44	9SDXN4F012075H	t
619	44	9SDXN8L0124RC5	t
620	44	9SDXN9N01261FN	t
621	44	9SDXNA70126HJ6	t
622	44	9SDXN7B0122ZUB	t
623	44	9SDXN7B0122ZFE	t
624	44	9SDXN7H0123A7B	t
625	44	9SDXN950125ESB	t
626	44	9SDXN980233VAF	t
627	44	9SDXN660220J7G	t
628	44	9SDXN5K02202MW	t
629	44	9SDXN980233W52	t
630	44	9SDXN9N01264RS	t
631	44	djimic300001	t
632	44	djimic300002	t
633	44	djimic300003	t
634	44	djimic300004	t
635	45	8PBWN8M006A2T8	t
636	45	8PBWN8K0069XLY	t
637	45	8PBWN8M006A3WX	t
638	45	8PBXN86016E575	t
639	45	djimicmini00001	t
640	45	djimicmini00002	t
641	46	HAW10430234159	t
642	46	HAW10588033796	t
643	47	]C121105082000414	t
644	47	]C121105082000001	t
645	47	]C121105082000415	t
646	47	]C121105082000044	t
647	47	]C121105082000006	t
648	47	]C121105082000007	t
649	47	]C121105082000411	t
650	47	]C121105082000042	t
651	47	]C121105082000009	t
652	47	]C121105082000049	t
653	47	]C121105082000293	t
654	47	]C121105082000106	t
655	48	]C121105082000101	t
656	48	]C121105082000418	t
657	48	]C121105082000110	t
658	48	]C121105082000416	t
659	48	]C121105082000294	t
660	48	]C121105082000362	t
661	48	]C121105082000048	t
662	48	]C121105082000010	t
663	48	]C121105082000046	t
664	48	]C121095082000754	t
665	49	]C121105082001943	t
666	49	]C121105082001945	t
667	49	]C121095082002402	t
668	49	]C121085082000785	t
669	49	]C121095082001715	t
670	49	]C121095082002349	t
671	49	]C121095082001773	t
672	49	]C121095082001792	t
673	49	]C121085082000927	t
674	49	]C121085082000922	t
675	50	]C121105082001939	t
676	50	]C121105082001940	t
677	50	]C121105082001947	t
678	50	]C121105082001944	t
679	50	]C121105082001942	t
680	50	]C121115082000637	t
681	50	]C121115082000643	t
682	50	]C121115082000173	t
683	50	]C121115082000175	t
684	50	]C121115082000176	t
685	50	]C121115082000636	t
686	50	]C121105082001941	t
687	50	]C121105082001938	t
688	50	canong7xmarkiii00001	t
689	50	canong7xmarkiii00002	t
690	50	canong7xmarkiii00003	t
691	50	canong7xmarkiii00004	t
692	50	canong7xmarkiii00005	t
693	50	canong7xmarkiii00006	t
694	50	canong7xmarkiii00007	t
695	50	canong7xmarkiii00008	t
696	50	canong7xmarkiii00009	t
697	50	canong7xmarkiii00010	t
698	51	]C121115081000721	t
699	51	]C121115081000722	t
700	51	]C121115081000720	t
701	51	]C121115081000723	t
702	51	]C121095081000253	t
703	51	canonsx740hs00001	t
704	51	canonsx740hs00002	t
705	51	canonsx740hs00003	t
706	51	canonsx740hs00004	t
707	51	canonsx740hs00005	t
708	51	canonsx740hs00006	t
709	51	canonsx740hs00007	t
710	51	canonsx740hs00008	t
711	51	canonsx740hs00009	t
712	51	canonsx740hs00010	t
713	51	canonsx740hs00011	t
714	51	canonsx740hs00012	t
715	51	canonsx740hs00013	t
716	51	canonsx740hs00014	t
717	51	canonsx740hs00015	t
718	51	canonsx740hs00016	t
719	51	canonsx740hs00017	t
720	51	canonsx740hs00018	t
721	51	canonsx740hs00019	t
722	51	canonsx740hs00020	t
723	51	canonsx740hs00021	t
724	52	5TM38849	t
725	52	5TM38835	t
726	52	5TM38895	t
727	52	5TM38752	t
728	52	5TM38899	t
729	52	5TM38902	t
730	52	5TM38897	t
731	52	5TM38900	t
732	52	5TM38855	t
733	52	5TM38913	t
734	52	5TM38832	t
735	52	5TM38844	t
736	52	5SM00535	t
737	52	5TM38893	t
738	52	5TM38896	t
739	52	5TM38894	t
740	52	5SM27191	t
741	52	5SM27169	t
742	52	5TM38828	t
743	52	5TM38745	t
744	52	5SM27198	t
745	52	5SM27239	t
746	52	5TM38836	t
747	52	5TM38842	t
748	52	5SM27178	t
749	52	5TM38830	t
750	52	5TM38901	t
751	52	5TM38825	t
752	52	5TM38829	t
753	52	5TM38719	t
754	52	5SM27194	t
755	52	4WM54552	t
756	52	4WM13669	t
757	52	5TM38767	t
758	52	5TM38765	t
759	52	4WM54553	t
760	52	5TM38770	t
761	52	5SM27179	t
762	52	5TM38948	t
763	52	5SM00524	t
764	52	5TM38904	t
765	52	5TM38763	t
766	52	5SM00529	t
767	52	5TM38872	t
768	52	5TM38827	t
769	52	5TM38943	t
770	52	5TM38860	t
771	52	5TM38944	t
772	52	5TM38841	t
773	52	5TM38826	t
774	52	5UN60111	t
775	52	5UN60112	t
776	52	5UN60113	t
777	52	5UN60114	t
778	52	5UN60115	t
779	52	5UN60116	t
780	52	5UN60117	t
781	52	5UN60118	t
782	52	5UN60119	t
783	52	5UN60120	t
784	52	5UN60201	t
785	52	5UN60202	t
786	52	5UN60203	t
787	52	5UN60204	t
788	52	5UN60205	t
789	52	5UN60206	t
790	52	5UN60207	t
791	52	5UN60208	t
792	52	5UN60209	t
793	52	5UN60210	t
794	52	5UN60101	t
795	52	5UN60102	t
796	52	5UN60103	t
797	52	5UN60104	t
798	52	5UN60105	t
799	52	5UN60106	t
800	52	5UN60107	t
801	52	5UN60108	t
802	52	5UN60109	t
803	52	5UN60110	t
804	52	5UN60131	t
805	52	5UN60132	t
806	52	5UN60133	t
807	52	5UN60134	t
808	52	5UN60135	t
809	52	5UN60136	t
810	52	5UN60137	t
811	52	5UN60138	t
812	52	5UN60139	t
813	52	5UN60140	t
814	52	5UN60561	t
815	52	5UN60562	t
816	52	5UN60563	t
817	52	5UN60564	t
818	52	5UN60565	t
819	52	5UN60566	t
820	52	5UN60567	t
821	52	5UN60568	t
822	52	5UN60569	t
823	52	5UN60570	t
824	52	5UN60171	t
825	52	5UN60172	t
826	52	5UN60173	t
827	52	5UN60174	t
828	52	5UN60175	t
829	52	5UN60176	t
830	52	5UN60177	t
831	52	5UN60178	t
832	52	5UN60179	t
833	52	5UN60180	t
834	52	5UN37211	t
835	52	5UN37212	t
836	52	5UN37213	t
837	52	5UN37214	t
838	52	5UN37215	t
839	52	5UN37216	t
840	52	5UN37217	t
841	52	5UN37218	t
842	52	5UN37219	t
843	52	5UN37220	t
844	52	5UN60181	t
845	52	5UN60182	t
846	52	5UN60183	t
847	52	5UN60184	t
848	52	5UN60185	t
849	52	5UN60186	t
850	52	5UN60187	t
851	52	5UN60188	t
852	52	5UN60189	t
853	52	5UN60190	t
854	52	5UN60551	t
855	52	5UN60552	t
856	52	5UN60553	t
857	52	5UN60554	t
858	52	5UN60555	t
859	52	5UN60556	t
860	52	5UN60557	t
861	52	5UN60558	t
862	52	5UN60559	t
863	52	5UN60560	t
864	52	5UN60121	t
865	52	5UN60122	t
866	52	5UN60123	t
867	52	5UN60124	t
868	52	5UN60125	t
869	52	5UN60126	t
870	52	5UN60127	t
871	52	5UN60128	t
872	52	5UN60129	t
873	52	5UN60130	t
874	52	5UN37221	t
875	52	5UN37222	t
876	52	5UN37223	t
877	52	5UN37224	t
878	52	5UN37225	t
879	52	5UN37226	t
880	52	5UN37227	t
881	52	5UN37228	t
882	52	5UN37229	t
883	52	5UN37230	t
884	52	5UN42171	t
885	52	5UN42172	t
886	52	5UN42173	t
887	52	5UN42174	t
888	52	5UN42175	t
889	52	5UN42176	t
890	52	5UN42177	t
891	52	5UN42178	t
892	52	5UN42179	t
893	52	5UN42180	t
894	52	5UN60541	t
895	52	5UN60542	t
896	52	5UN60543	t
897	52	5UN60544	t
898	52	5UN60545	t
899	52	5UN60546	t
900	52	5UN60547	t
901	52	5UN60548	t
902	52	5UN60549	t
903	52	5UN60550	t
904	52	5UN60191	t
905	52	5UN60192	t
906	52	5UN60193	t
907	52	5UN60194	t
908	52	5UN60195	t
909	52	5UN60196	t
910	52	5UN60197	t
911	52	5UN60198	t
912	52	5UN60199	t
913	52	5UN60200	t
914	52	5UN60571	t
915	52	5UN60572	t
916	52	5UN60573	t
917	52	5UN60574	t
918	52	5UN60575	t
919	52	5UN60576	t
920	52	5UN60577	t
921	52	5UN60578	t
922	52	5UN60579	t
923	52	5UN60580	t
924	53	5UN37241	t
925	53	5UN37242	t
926	53	5UN37243	t
927	53	5UN37244	t
928	53	5UN37245	t
929	53	5UN37246	t
930	53	5UN37247	t
931	53	5UN37248	t
932	53	5UN37249	t
933	53	5UN37250	t
934	53	5UN42211	t
935	53	5UN42212	t
936	53	5UN42213	t
937	53	5UN42214	t
938	53	5UN42215	t
939	53	5UN42216	t
940	53	5UN42217	t
941	53	5UN42218	t
942	53	5UN42219	t
943	53	5UN42220	t
944	53	5UN42241	t
945	53	5UN42242	t
946	53	5UN42243	t
947	53	5UN42244	t
948	53	5UN42245	t
949	53	5UN42246	t
950	53	5UN42247	t
951	53	5UN42248	t
952	53	5UN42249	t
953	53	5UN42250	t
954	53	5UN60141	t
955	53	5UN60142	t
956	53	5UN60143	t
957	53	5UN60144	t
958	53	5UN60145	t
959	53	5UN60146	t
960	53	5UN60147	t
961	53	5UN60148	t
962	53	5UN60149	t
963	53	5UN60150	t
964	53	5UN42231	t
965	53	5UN42232	t
966	53	5UN42233	t
967	53	5UN42234	t
968	53	5UN42235	t
969	53	5UN42236	t
970	53	5UN42237	t
971	53	5UN42238	t
972	53	5UN42239	t
973	53	5UN42240	t
974	54	instaxfilm20pack00001	t
975	54	instaxfilm20pack00002	t
976	54	instaxfilm20pack00003	t
977	54	instaxfilm20pack00004	t
978	54	instaxfilm20pack00005	t
979	54	instaxfilm20pack00006	t
980	54	instaxfilm20pack00007	t
981	54	instaxfilm20pack00008	t
982	54	instaxfilm20pack00009	t
983	54	instaxfilm20pack00010	t
984	54	instaxfilm20pack00011	t
985	54	instaxfilm20pack00012	t
986	54	instaxfilm20pack00013	t
987	54	instaxfilm20pack00014	t
988	54	instaxfilm20pack00015	t
989	54	instaxfilm20pack00016	t
990	54	instaxfilm20pack00017	t
991	54	instaxfilm20pack00018	t
992	54	instaxfilm20pack00019	t
993	54	instaxfilm20pack00020	t
994	54	instaxfilm20pack00021	t
995	54	instaxfilm20pack00022	t
996	54	instaxfilm20pack00023	t
997	54	instaxfilm20pack00024	t
998	54	instaxfilm20pack00025	t
999	54	instaxfilm20pack00026	t
1000	54	instaxfilm20pack00027	t
1001	54	instaxfilm20pack00028	t
1002	54	instaxfilm20pack00029	t
1003	54	instaxfilm20pack00030	t
1004	54	instaxfilm20pack00031	t
1005	54	instaxfilm20pack00032	t
1006	54	instaxfilm20pack00033	t
1007	54	instaxfilm20pack00034	t
1008	54	instaxfilm20pack00035	t
1009	54	instaxfilm20pack00036	t
1010	54	instaxfilm20pack00037	t
1011	54	instaxfilm20pack00038	t
1012	54	instaxfilm20pack00039	t
1013	54	instaxfilm20pack00040	t
1014	54	instaxfilm20pack00041	t
1015	54	instaxfilm20pack00042	t
1016	54	instaxfilm20pack00043	t
1017	54	instaxfilm20pack00044	t
1018	54	instaxfilm20pack00045	t
1019	54	instaxfilm20pack00046	t
1020	54	instaxfilm20pack00047	t
1021	54	instaxfilm20pack00048	t
1022	54	instaxfilm20pack00049	t
1023	54	instaxfilm20pack00050	t
1024	54	instaxfilm20pack00051	t
1025	54	instaxfilm20pack00052	t
1026	54	instaxfilm20pack00053	t
1027	54	instaxfilm20pack00054	t
1028	54	instaxfilm20pack00055	t
1029	54	instaxfilm20pack00056	t
1030	54	instaxfilm20pack00057	t
1031	54	instaxfilm20pack00058	t
1032	54	instaxfilm20pack00059	t
1033	54	instaxfilm20pack00060	t
1034	54	instaxfilm20pack00061	t
1035	54	instaxfilm20pack00062	t
1036	54	instaxfilm20pack00063	t
1037	54	instaxfilm20pack00064	t
1038	54	instaxfilm20pack00065	t
1039	54	instaxfilm20pack00066	t
1040	54	instaxfilm20pack00067	t
1041	54	instaxfilm20pack00068	t
1042	54	instaxfilm20pack00069	t
1043	54	instaxfilm20pack00070	t
1044	54	instaxfilm20pack00071	t
1045	54	instaxfilm20pack00072	t
1046	54	instaxfilm20pack00073	t
1047	54	instaxfilm20pack00074	t
1048	54	instaxfilm20pack00075	t
1049	54	instaxfilm20pack00076	t
1050	54	instaxfilm20pack00077	t
1051	54	instaxfilm20pack00078	t
1052	54	instaxfilm20pack00079	t
1053	54	instaxfilm20pack00080	t
1054	54	instaxfilm20pack00081	t
1055	54	instaxfilm20pack00082	t
1056	54	instaxfilm20pack00083	t
1057	54	instaxfilm20pack00084	t
1058	54	instaxfilm20pack00085	t
1059	54	instaxfilm20pack00086	t
1060	54	instaxfilm20pack00087	t
1061	54	instaxfilm20pack00088	t
1062	54	instaxfilm20pack00089	t
1063	54	instaxfilm20pack00090	t
1064	54	instaxfilm20pack00091	t
1065	54	instaxfilm20pack00092	t
1066	54	instaxfilm20pack00093	t
1067	54	instaxfilm20pack00094	t
1068	54	instaxfilm20pack00095	t
1069	54	instaxfilm20pack00096	t
1070	54	instaxfilm20pack00097	t
1071	54	instaxfilm20pack00098	t
1072	54	instaxfilm20pack00099	t
1073	54	instaxfilm20pack00100	t
1074	54	instaxfilm20pack00101	t
1075	54	instaxfilm20pack00102	t
1076	54	instaxfilm20pack00103	t
1077	54	instaxfilm20pack00104	t
1078	54	instaxfilm20pack00105	t
1079	54	instaxfilm20pack00106	t
1080	54	instaxfilm20pack00107	t
1081	54	instaxfilm20pack00108	t
1082	54	instaxfilm20pack00109	t
1083	54	instaxfilm20pack00110	t
1084	54	instaxfilm20pack00111	t
1085	54	instaxfilm20pack00112	t
1086	54	instaxfilm20pack00113	t
1087	54	instaxfilm20pack00114	t
1088	54	instaxfilm20pack00115	t
1089	54	instaxfilm20pack00116	t
1090	54	instaxfilm20pack00117	t
1091	54	instaxfilm20pack00118	t
1092	54	instaxfilm20pack00119	t
1093	54	instaxfilm20pack00120	t
1094	54	instaxfilm20pack00121	t
1095	54	instaxfilm20pack00122	t
1096	54	instaxfilm20pack00123	t
1097	54	instaxfilm20pack001124	t
1098	54	instaxfilm20pack00125	t
1099	54	instaxfilm20pack00126	t
1100	54	instaxfilm20pack00127	t
1101	54	instaxfilm20pack00128	t
1102	54	instaxfilm20pack00129	t
1103	54	instaxfilm20pack00130	t
1104	54	instaxfilm20pack00131	t
1105	54	instaxfilm20pack00132	t
1106	54	instaxfilm20pack00133	t
1107	54	instaxfilm20pack00134	t
1108	54	instaxfilm20pack00135	t
1109	54	instaxfilm20pack00136	t
1110	54	instaxfilm20pack00137	t
1111	54	instaxfilm20pack00138	t
1112	54	instaxfilm20pack00139	t
1113	54	instaxfilm20pack00140	t
1114	54	instaxfilm20pack00141	t
1115	54	instaxfilm20pack00142	t
1116	54	instaxfilm20pack00143	t
1117	54	instaxfilm20pack00144	t
1118	54	instaxfilm20pack00145	t
1119	54	instaxfilm20pack00146	t
1120	54	instaxfilm20pack00147	t
1121	54	instaxfilm20pack00148	t
1122	54	instaxfilm20pack00149	t
1123	54	instaxfilm20pack00150	t
1124	54	instaxfilm20pack00151	t
1125	54	instaxfilm20pack00152	t
1126	54	instaxfilm20pack00153	t
1127	54	instaxfilm20pack00154	t
1128	54	instaxfilm20pack00155	t
1129	54	instaxfilm20pack00156	t
1130	54	instaxfilm20pack00157	t
1131	54	instaxfilm20pack00158	t
1132	54	instaxfilm20pack00159	t
1133	54	instaxfilm20pack00160	t
1134	54	instaxfilm20pack00161	t
1135	54	instaxfilm20pack00162	t
1136	54	instaxfilm20pack00163	t
1137	54	instaxfilm20pack00164	t
1138	54	instaxfilm20pack00165	t
1139	54	instaxfilm20pack00166	t
1140	54	instaxfilm20pack00167	t
1141	54	instaxfilm20pack00168	t
1142	54	instaxfilm20pack00169	t
1143	54	instaxfilm20pack00170	t
1144	54	instaxfilm20pack00171	t
1145	54	instaxfilm20pack00172	t
1146	54	instaxfilm20pack00173	t
1147	54	instaxfilm20pack00174	t
1148	54	instaxfilm20pack001175	t
1149	54	instaxfilm20pack00176	t
1150	54	instaxfilm20pack00177	t
1151	54	instaxfilm20pack00178	t
1152	54	instaxfilm20pack00179	t
1153	54	instaxfilm20pack00180	t
1154	54	instaxfilm20pack00181	t
1155	54	instaxfilm20pack00182	t
1156	54	instaxfilm20pack00183	t
1157	54	instaxfilm20pack00184	t
1158	54	instaxfilm20pack00185	t
1159	54	instaxfilm20pack001186	t
1160	54	instaxfilm20pack00187	t
1161	54	instaxfilm20pack00188	t
1162	54	instaxfilm20pack00189	t
1163	54	instaxfilm20pack00190	t
1164	54	instaxfilm20pack00191	t
1165	54	instaxfilm20pack00192	t
1166	54	instaxfilm20pack00193	t
1167	54	instaxfilm20pack00194	t
1168	54	instaxfilm20pack00195	t
1169	54	instaxfilm20pack00196	t
1170	54	instaxfilm20pack00197	t
1171	54	instaxfilm20pack00198	t
1172	54	instaxfilm20pack00199	t
1173	54	instaxfilm20pack00200	t
1174	54	instaxfilm20pack00201	t
1175	54	instaxfilm20pack00202	t
1176	54	instaxfilm20pack00203	t
1177	54	instaxfilm20pack00204	t
1178	54	instaxfilm20pack00205	t
1179	54	instaxfilm20pack00206	t
1180	54	instaxfilm20pack00207	t
1181	54	instaxfilm20pack00208	t
1182	54	instaxfilm20pack00209	t
1183	54	instaxfilm20pack00210	t
1184	54	instaxfilm20pack00211	t
1185	54	instaxfilm20pack00212	t
1186	54	instaxfilm20pack00213	t
1187	54	instaxfilm20pack00214	t
1188	54	instaxfilm20pack00215	t
1189	54	instaxfilm20pack00216	t
1190	54	instaxfilm20pack00217	t
1191	54	instaxfilm20pack00218	t
1192	54	instaxfilm20pack00219	t
1193	54	instaxfilm20pack00220	t
1194	54	instaxfilm20pack00221	t
1195	54	instaxfilm20pack00222	t
1196	54	instaxfilm20pack00223	t
1197	54	instaxfilm20pack00224	t
1198	54	instaxfilm20pack00225	t
1199	54	instaxfilm20pack00226	t
1200	54	instaxfilm20pack00227	t
1201	54	instaxfilm20pack00228	t
1202	54	instaxfilm20pack00229	t
1203	54	instaxfilm20pack00230	t
1204	54	instaxfilm20pack00231	t
1205	54	instaxfilm20pack00232	t
1206	54	instaxfilm20pack00233	t
1207	54	instaxfilm20pack00234	t
1208	54	instaxfilm20pack00235	t
1209	54	instaxfilm20pack00236	t
1210	54	instaxfilm20pack00237	t
1211	54	instaxfilm20pack00238	t
1212	54	instaxfilm20pack00239	t
1213	54	instaxfilm20pack00240	t
1214	54	instaxfilm20pack00241	t
1215	54	instaxfilm20pack00242	t
1216	54	instaxfilm20pack00243	t
1217	54	instaxfilm20pack00244	t
1218	54	instaxfilm20pack00245	t
1219	54	instaxfilm20pack00246	t
1220	54	instaxfilm20pack00247	t
1221	54	instaxfilm20pack00248	t
1222	54	instaxfilm20pack00249	t
1223	54	instaxfilm20pack00250	t
1224	54	instaxfilm20pack00251	t
1225	54	instaxfilm20pack00252	t
1226	54	instaxfilm20pack00253	t
1227	54	instaxfilm20pack00254	t
1228	54	instaxfilm20pack00255	t
1229	54	instaxfilm20pack00256	t
1230	54	instaxfilm20pack00257	t
1231	54	instaxfilm20pack00258	t
1232	54	instaxfilm20pack00259	t
1233	54	instaxfilm20pack00260	t
1234	54	instaxfilm20pack00261	t
1235	54	instaxfilm20pack00262	t
1236	54	instaxfilm20pack00263	t
1237	54	instaxfilm20pack00264	t
1238	54	instaxfilm20pack00265	t
1239	54	instaxfilm20pack00266	t
1240	54	instaxfilm20pack00267	t
1241	54	instaxfilm20pack00268	t
1242	54	instaxfilm20pack00269	t
1243	54	instaxfilm20pack00270	t
1244	54	instaxfilm20pack00271	t
1245	54	instaxfilm20pack00272	t
1246	54	instaxfilm20pack00273	t
1247	54	instaxfilm20pack00274	t
1248	54	instaxfilm20pack00275	t
1249	54	instaxfilm20pack00276	t
1250	54	instaxfilm20pack00277	t
1251	54	instaxfilm20pack00278	t
1252	54	instaxfilm20pack00279	t
1253	54	instaxfilm20pack00280	t
1254	54	instaxfilm20pack00281	t
1255	54	instaxfilm20pack00282	t
1256	54	instaxfilm20pack00283	t
1257	54	instaxfilm20pack00284	t
1258	54	instaxfilm20pack00285	t
1259	54	instaxfilm20pack00286	t
1260	54	instaxfilm20pack00287	t
1261	54	instaxfilm20pack00288	t
1262	54	instaxfilm20pack00289	t
1263	54	instaxfilm20pack00290	t
1264	54	instaxfilm20pack00291	t
1265	54	instaxfilm20pack00292	t
1266	54	instaxfilm20pack00293	t
1267	54	instaxfilm20pack00294	t
1268	54	instaxfilm20pack00295	t
1269	54	instaxfilm20pack00296	t
1270	54	instaxfilm20pack00297	t
1271	54	instaxfilm20pack00298	t
1272	54	instaxfilm20pack00299	t
1273	54	instaxfilm20pack00300	t
1274	54	instaxfilm20pack00301	t
1275	54	instaxfilm20pack00302	t
1276	54	instaxfilm20pack00303	t
1277	54	instaxfilm20pack00304	t
1278	54	instaxfilm20pack00305	t
1279	54	instaxfilm20pack00306	t
1280	54	instaxfilm20pack00307	t
1281	54	instaxfilm20pack00308	t
1282	54	instaxfilm20pack00309	t
1283	54	instaxfilm20pack00310	t
1284	54	instaxfilm20pack00311	t
1285	54	instaxfilm20pack00312	t
1286	54	instaxfilm20pack00313	t
1287	54	instaxfilm20pack00314	t
1288	54	instaxfilm20pack00315	t
1289	54	instaxfilm20pack00316	t
1290	54	instaxfilm20pack00317	t
1291	54	instaxfilm20pack00318	t
1292	54	instaxfilm20pack00319	t
1293	54	instaxfilm20pack00320	t
1294	54	instaxfilm20pack00321	t
1295	54	instaxfilm20pack00322	t
1296	54	instaxfilm20pack00323	t
1297	54	instaxfilm20pack00324	t
1298	54	instaxfilm20pack00325	t
1299	54	instaxfilm20pack00326	t
1300	54	instaxfilm20pack00327	t
1301	54	instaxfilm20pack00328	t
1302	54	instaxfilm20pack00329	t
1303	54	instaxfilm20pack00330	t
1304	54	instaxfilm20pack00331	t
1305	54	instaxfilm20pack00332	t
1306	54	instaxfilm20pack00333	t
1307	54	instaxfilm20pack00334	t
1308	54	instaxfilm20pack00335	t
1309	54	instaxfilm20pack00336	t
1310	54	instaxfilm20pack00337	t
1311	54	instaxfilm20pack00338	t
1312	54	instaxfilm20pack00339	t
1313	54	instaxfilm20pack00340	t
1314	54	instaxfilm20pack00341	t
1315	54	instaxfilm20pack00342	t
1316	54	instaxfilm20pack00343	t
1317	54	instaxfilm20pack00344	t
1318	54	instaxfilm20pack00345	t
1319	54	instaxfilm20pack00346	t
1320	54	instaxfilm20pack00347	t
1321	54	instaxfilm20pack00348	t
1322	54	instaxfilm20pack00349	t
1323	54	instaxfilm20pack00350	t
1324	54	instaxfilm20pack00351	t
1325	54	instaxfilm20pack00352	t
1326	54	instaxfilm20pack00353	t
1327	54	instaxfilm20pack00354	t
1328	54	instaxfilm20pack00355	t
1329	54	instaxfilm20pack00356	t
1330	54	instaxfilm20pack00357	t
1331	54	instaxfilm20pack00358	t
1332	54	instaxfilm20pack00359	t
1333	54	instaxfilm20pack00360	t
1334	54	instaxfilm20pack00361	t
1335	54	instaxfilm20pack00362	t
1336	54	instaxfilm20pack00363	t
1337	54	instaxfilm20pack00364	t
1338	54	instaxfilm20pack00365	t
1339	54	instaxfilm20pack00366	t
1340	54	instaxfilm20pack00367	t
1341	54	instaxfilm20pack00368	t
1342	54	instaxfilm20pack00369	t
1343	54	instaxfilm20pack00370	t
1344	54	instaxfilm20pack00371	t
1345	54	instaxfilm20pack00372	t
1346	54	instaxfilm20pack00373	t
1347	54	instaxfilm20pack00374	t
1348	54	instaxfilm20pack00375	t
1349	54	instaxfilm20pack00376	t
1350	54	instaxfilm20pack00377	t
1351	54	instaxfilm20pack00378	t
1352	54	instaxfilm20pack00379	t
1353	54	instaxfilm20pack00380	t
1354	54	instaxfilm20pack00381	t
1355	54	instaxfilm20pack00382	t
1356	54	instaxfilm20pack00383	t
1357	54	instaxfilm20pack00384	t
1358	54	instaxfilm20pack00385	t
1359	54	instaxfilm20pack00386	t
1360	54	instaxfilm20pack00387	t
1361	54	instaxfilm20pack00388	t
1362	54	instaxfilm20pack00389	t
1363	54	instaxfilm20pack00390	t
1364	54	instaxfilm20pack00391	t
1365	54	instaxfilm20pack00392	t
1366	54	instaxfilm20pack00393	t
1367	54	instaxfilm20pack00394	t
1368	54	instaxfilm20pack00395	t
1369	54	instaxfilm20pack00396	t
1370	54	instaxfilm20pack00397	t
1371	54	instaxfilm20pack00398	t
1372	54	instaxfilm20pack00399	t
1373	54	instaxfilm20pack00400	t
1374	54	instaxfilm20pack00401	t
1375	54	instaxfilm20pack00402	t
1376	54	instaxfilm20pack00403	t
1377	54	instaxfilm20pack00404	t
1378	54	instaxfilm20pack00405	t
1379	54	instaxfilm20pack00406	t
1380	54	instaxfilm20pack00407	t
1381	54	instaxfilm20pack00408	t
1382	54	instaxfilm20pack00409	t
1383	54	instaxfilm20pack00410	t
1384	54	instaxfilm20pack00411	t
1385	54	instaxfilm20pack00412	t
1386	54	instaxfilm20pack00413	t
1387	54	instaxfilm20pack00414	t
1388	54	instaxfilm20pack00415	t
1389	54	instaxfilm20pack00416	t
1390	54	instaxfilm20pack00417	t
1391	54	instaxfilm20pack00418	t
1392	54	instaxfilm20pack00419	t
1393	54	instaxfilm20pack00420	t
1394	54	instaxfilm20pack00421	t
1395	54	instaxfilm20pack00422	t
1396	54	instaxfilm20pack00423	t
1397	54	instaxfilm20pack00424	t
1398	54	instaxfilm20pack00425	t
1399	54	instaxfilm20pack00426	t
1400	54	instaxfilm20pack00427	t
1401	54	instaxfilm20pack00428	t
1402	54	instaxfilm20pack00429	t
1403	54	instaxfilm20pack00430	t
1404	54	instaxfilm20pack00431	t
1405	54	instaxfilm20pack00432	t
1406	54	instaxfilm20pack00433	t
1407	54	instaxfilm20pack00434	t
1408	54	instaxfilm20pack00435	t
1409	54	instaxfilm20pack00436	t
1410	54	instaxfilm20pack00437	t
1411	54	instaxfilm20pack00438	t
1412	54	instaxfilm20pack00439	t
1413	54	instaxfilm20pack00440	t
1414	54	instaxfilm20pack00441	t
1415	54	instaxfilm20pack00442	t
1416	54	instaxfilm20pack00443	t
1417	54	instaxfilm20pack00444	t
1418	54	instaxfilm20pack00445	t
1419	54	instaxfilm20pack00446	t
1420	54	instaxfilm20pack00447	t
1421	54	instaxfilm20pack00448	t
1422	54	instaxfilm20pack00449	t
1423	54	instaxfilm20pack00450	t
1424	54	instaxfilm20pack00451	t
1425	54	instaxfilm20pack00452	t
1426	54	instaxfilm20pack00453	t
1427	54	instaxfilm20pack00454	t
1428	54	instaxfilm20pack00455	t
1429	54	instaxfilm20pack00456	t
1430	54	instaxfilm20pack00457	t
1431	54	instaxfilm20pack00458	t
1432	54	instaxfilm20pack00459	t
1433	54	instaxfilm20pack00460	t
1434	54	instaxfilm20pack00461	t
1435	54	instaxfilm20pack00462	t
1436	54	instaxfilm20pack00463	t
1437	54	instaxfilm20pack00464	t
1438	54	instaxfilm20pack00465	t
1439	54	instaxfilm20pack00466	t
1440	54	instaxfilm20pack00467	t
1441	54	instaxfilm20pack00468	t
1442	54	instaxfilm20pack00469	t
1443	54	instaxfilm20pack00470	t
1444	54	instaxfilm20pack00471	t
1445	54	instaxfilm20pack00472	t
1446	54	instaxfilm20pack00473	t
1447	54	instaxfilm20pack00474	t
1448	54	instaxfilm20pack00475	t
1449	54	instaxfilm20pack00476	t
1450	54	instaxfilm20pack00477	t
1451	54	instaxfilm20pack00478	t
1452	54	instaxfilm20pack00479	t
1453	54	instaxfilm20pack00480	t
1454	54	instaxfilm20pack00481	t
1455	54	instaxfilm20pack00482	t
1456	54	instaxfilm20pack00483	t
1457	54	instaxfilm20pack00484	t
1458	54	instaxfilm20pack00485	t
1459	54	instaxfilm20pack00486	t
1460	54	instaxfilm20pack00487	t
1461	54	instaxfilm20pack00488	t
1462	54	instaxfilm20pack00489	t
1463	54	instaxfilm20pack00490	t
1464	54	instaxfilm20pack00491	t
1465	54	instaxfilm20pack00492	t
1466	54	instaxfilm20pack00493	t
1467	54	instaxfilm20pack00494	t
1468	54	instaxfilm20pack00495	t
1469	54	instaxfilm20pack00496	t
1470	54	instaxfilm20pack00497	t
1471	54	instaxfilm20pack00498	t
1472	54	instaxfilm20pack00499	t
1473	54	instaxfilm20pack00500	t
1474	55	ninjaslushi0001	t
1475	55	ninjaslushi0002	t
1476	55	ninjaslushi0003	t
1477	55	ninjaslushi0004	t
1478	55	ninjaslushi0005	t
1479	55	ninjaslushi0006	t
1480	55	ninjaslushi0007	t
1481	56	ninjacreami0001	t
1482	56	ninjacreami0002	t
1483	56	ninjacreami0003	t
1484	56	ninjacreami0004	t
1485	56	ninjacreami0005	t
1486	56	ninjacreami0006	t
1487	56	ninjacreami0007	t
1488	56	ninjacreami0008	t
1489	56	ninjacreami0009	t
1490	56	ninjacreami0010	t
1491	57	ninjaportableblender0001	t
1492	57	ninjaportableblender0002	t
1493	57	ninjaportableblender0003	t
1494	57	ninjaportableblender0004	t
1495	57	ninjaportableblender0005	t
1496	57	ninjaportableblender0006	t
1497	57	ninjaportableblender0007	t
1498	57	ninjaportableblender0008	t
1499	57	ninjaportableblender0009	t
1500	57	ninjaportableblender0010	t
1501	58	starlinkhp00001	t
1502	58	starlinkhp00002	t
1503	59	starlinkv40001	t
1504	59	starlinkv40002	t
1505	59	starlinkv40003	t
1506	59	starlinkv40004	t
1507	59	starlinkv40005	t
1508	59	starlinkv40006	t
1509	59	starlinkv40007	t
1510	59	starlinkv40008	t
1511	59	starlinkv40009	t
1512	59	starlinkv40010	t
1513	59	starlinkv40011	t
1514	59	starlinkv40012	t
1515	59	starlinkv40013	t
1516	59	starlinkv40014	t
1517	59	starlinkv40015	t
1518	59	starlinkv40016	t
1519	59	starlinkv40017	t
1520	59	starlinkv40018	t
1521	59	starlinkv40019	t
1522	59	starlinkv40020	t
1523	59	starlinkv40021	t
1524	59	starlinkv40022	t
1525	59	starlinkv40023	t
1526	59	starlinkv40024	t
1527	59	starlinkv40025	t
1528	59	starlinkv40026	t
1529	59	starlinkv40027	t
1530	59	starlinkv40028	t
1531	59	starlinkv40029	t
1532	59	starlinkv40030	t
1533	59	starlinkv40031	t
1534	59	starlinkv40032	t
1535	59	starlinkv40033	t
1536	59	starlinkv40034	t
1537	59	starlinkv40035	t
1538	59	starlinkv40036	t
1539	59	starlinkv40037	t
1540	59	starlinkv40038	t
1541	59	starlinkv40039	t
1542	59	starlinkv40040	t
1543	59	starlinkv40041	t
1544	59	starlinkv40042	t
1545	59	starlinkv40043	t
1546	59	starlinkv40044	t
1547	59	starlinkv40045	t
1548	59	starlinkv40046	t
1549	59	starlinkv40047	t
1550	59	starlinkv40048	t
1551	59	starlinkv40049	t
1552	59	starlinkv40050	t
1553	60	starlinkv40051	t
1554	60	starlinkv40052	t
1555	60	starlinkv40053	t
1556	60	starlinkv40054	t
1557	60	starlinkv40055	t
1558	60	starlinkv40056	t
1559	60	starlinkv40057	t
1560	60	starlinkv40058	t
1561	60	starlinkv40059	t
1562	60	starlinkv40060	t
1563	60	starlinkv40061	t
1564	60	starlinkv40062	t
1565	60	starlinkv40063	t
1566	60	starlinkv40064	t
1567	60	starlinkv40065	t
1568	60	starlinkv40066	t
1569	60	starlinkv40067	t
1570	60	starlinkv40068	t
1571	60	starlinkv40069	t
1572	60	starlinkv40070	t
1573	60	starlinkv40071	t
1574	60	starlinkv40072	t
1575	60	starlinkv40073	t
1576	60	starlinkv40074	t
1577	60	starlinkv40075	t
1578	60	starlinkv40076	t
1579	60	starlinkv40077	t
1580	60	starlinkv40078	t
1581	60	starlinkv40079	t
1582	60	starlinkv40080	t
1583	60	starlinkv40081	t
1584	60	starlinkv40082	t
1585	60	starlinkv40083	t
1586	60	starlinkv40084	t
1587	60	starlinkv40085	t
1588	60	starlinkv40086	t
1589	60	starlinkv40087	t
1590	60	starlinkv40088	t
1591	60	starlinkv40089	t
1592	60	starlinkv40090	t
1593	60	starlinkv40091	t
1594	60	starlinkv40092	t
1595	60	starlinkv40093	t
1596	60	starlinkv40094	t
1597	60	starlinkv40095	t
1598	60	starlinkv40096	t
1599	60	starlinkv40097	t
1600	60	starlinkv40098	t
1601	60	starlinkv40099	t
1602	60	starlinkv40100	t
1603	60	starlinkv40101	t
1604	60	starlinkv40102	t
1605	60	starlinkv40103	t
1606	60	starlinkv40104	t
1607	60	starlinkv40105	t
1608	60	starlinkv40106	t
1609	60	starlinkv40107	t
1610	60	starlinkv40108	t
1611	60	starlinkv40109	t
1612	60	starlinkv40110	t
1613	60	starlinkv40111	t
1614	60	starlinkv40112	t
1615	60	starlinkv40113	t
1616	60	starlinkv40114	t
1617	60	starlinkv40115	t
1618	60	starlinkv40116	t
1619	60	starlinkv40117	t
1620	60	starlinkv40118	t
1621	60	starlinkv40119	t
1622	60	starlinkv40120	t
1623	60	starlinkv40121	t
1624	60	starlinkv40122	t
1625	60	starlinkv40123	t
1626	60	starlinkv40124	t
1627	60	starlinkv40125	t
1628	60	starlinkv40126	t
1629	60	starlinkv40127	t
1630	60	starlinkv40128	t
1631	60	starlinkv40129	t
1632	60	starlinkv40130	t
1633	60	starlinkv40131	t
1634	60	starlinkv40132	t
1635	60	starlinkv40133	t
1636	60	starlinkv40134	t
1637	60	starlinkv40135	t
1638	60	starlinkv40136	t
1639	60	starlinkv40137	t
1640	60	starlinkv40138	t
1641	60	starlinkv40139	t
1642	60	starlinkv40140	t
1643	60	starlinkv40141	t
1644	60	starlinkv40142	t
1645	60	starlinkv40143	t
1646	60	starlinkv40144	t
1647	60	starlinkv40145	t
1648	60	starlinkv40146	t
1649	60	starlinkv40147	t
1650	60	starlinkv40148	t
1651	60	starlinkv40149	t
1652	60	starlinkv40150	t
1653	60	starlinkv40151	t
1654	60	starlinkv40152	t
1655	60	starlinkv40153	t
1656	60	starlinkv40154	t
1657	60	starlinkv40155	t
1658	60	starlinkv40156	t
1659	60	starlinkv40157	t
1660	60	starlinkv40158	t
1661	60	starlinkv40159	t
1662	60	starlinkv40160	t
1663	60	starlinkv40161	t
1664	60	starlinkv40162	t
1665	60	starlinkv40163	t
1666	60	starlinkv40164	t
1667	60	starlinkv40165	t
1668	60	starlinkv40166	t
1669	60	starlinkv40167	t
1670	60	starlinkv40168	t
1671	60	starlinkv40169	t
1672	60	starlinkv40170	t
1673	60	starlinkv40171	t
1674	60	starlinkv40172	t
1675	60	starlinkv40173	t
1676	60	starlinkv40174	t
1677	60	starlinkv40175	t
1678	60	starlinkv40176	t
1679	60	starlinkv40177	t
1680	60	starlinkv40178	t
1681	60	starlinkv40179	t
1682	60	starlinkv40180	t
1683	60	starlinkv40181	t
1684	60	starlinkv40182	t
1685	60	starlinkv40183	t
1686	60	starlinkv40184	t
1687	60	starlinkv40185	t
1688	60	starlinkv40186	t
1689	60	starlinkv40187	t
1690	60	starlinkv40188	t
1691	60	starlinkv40189	t
1692	60	starlinkv40190	t
1693	60	starlinkv40191	t
1694	60	starlinkv40192	t
1695	60	starlinkv40193	t
1696	60	starlinkv40194	t
1697	60	starlinkv40195	t
1698	60	starlinkv40196	t
1699	60	starlinkv40197	t
1700	60	starlinkv40198	t
1701	60	starlinkv40199	t
1702	60	starlinkv40200	t
1703	60	starlinkv40201	t
1704	60	starlinkv40202	t
1705	60	starlinkv40203	t
1706	60	starlinkv40204	t
1707	60	starlinkv40205	t
1708	60	starlinkv40206	t
1709	60	starlinkv40207	t
1710	60	starlinkv40208	t
1711	60	starlinkv40209	t
1712	61	starlinkv40210	t
1713	61	starlinkv40211	t
1714	61	starlinkv40212	t
1715	61	starlinkv40213	t
1716	61	starlinkv40214	t
1717	61	starlinkv40215	t
1718	61	starlinkv40216	t
1719	61	starlinkv40217	t
1720	61	starlinkv40218	t
1721	61	starlinkv40219	t
1722	61	starlinkv40220	t
1723	61	starlinkv40221	t
1724	61	starlinkv40222	t
1725	61	starlinkv40223	t
1726	61	starlinkv40224	t
1727	61	starlinkv40225	t
1728	61	starlinkv40226	t
1729	61	starlinkv40227	t
1730	61	starlinkv40228	t
1731	61	starlinkv40229	t
1732	61	starlinkv40230	t
1733	61	starlinkv40231	t
1734	61	starlinkv40232	t
1735	61	starlinkv40233	t
1736	61	starlinkv40234	t
1737	61	starlinkv40235	t
1738	61	starlinkv40236	t
1739	61	starlinkv40237	t
1740	61	starlinkv40238	t
1741	61	starlinkv40239	t
1742	61	starlinkv40240	t
1743	61	starlinkv40241	t
1744	61	starlinkv40242	t
1745	61	starlinkv40243	t
1746	61	starlinkv40244	t
1747	61	starlinkv40245	t
1748	61	starlinkv40246	t
1749	61	starlinkv40247	t
1750	61	starlinkv40248	t
1751	61	starlinkv40249	t
1752	61	starlinkv40250	t
1753	61	starlinkv40251	t
1754	61	starlinkv40252	t
1755	61	starlinkv40253	t
1756	61	starlinkv40254	t
1757	61	starlinkv40255	t
1758	61	starlinkv40256	t
1759	61	starlinkv40257	t
1760	61	starlinkv40258	t
1761	61	starlinkv40259	t
1762	61	starlinkv40260	t
1763	61	starlinkv40261	t
1764	61	starlinkv40262	t
1765	61	starlinkv40263	t
1766	61	starlinkv40264	t
1767	61	starlinkv40265	t
1768	61	starlinkv40266	t
1769	61	starlinkv40267	t
1770	61	starlinkv40268	t
1771	61	starlinkv40269	t
1772	62	starlinkv40270	t
1773	62	starlinkv40271	t
1774	62	starlinkv40272	t
1775	62	starlinkv40273	t
1776	62	starlinkv40274	t
1777	62	starlinkv40275	t
1778	62	starlinkv40276	t
1779	62	starlinkv40277	t
1780	62	starlinkv40278	t
1781	62	starlinkv40279	t
1782	62	starlinkv40280	t
1783	62	starlinkv40281	t
1784	62	starlinkv40282	t
1785	62	starlinkv40283	t
1786	62	starlinkv40284	t
1787	62	starlinkv40285	t
1788	62	starlinkv40286	t
1789	62	starlinkv40287	t
1790	62	starlinkv40288	t
1791	62	starlinkv40289	t
1792	62	starlinkv40290	t
1793	62	starlinkv40291	t
1794	62	starlinkv40292	t
1795	62	starlinkv40293	t
1796	62	starlinkv40294	t
1797	62	starlinkv40295	t
1798	62	starlinkv40296	t
1799	62	starlinkv40297	t
1800	62	starlinkv40298	t
1801	62	starlinkv40299	t
1802	62	starlinkv40300	t
1803	62	starlinkv40301	t
1804	62	starlinkv40302	t
1805	62	starlinkv40303	t
1806	62	starlinkv40304	t
1807	62	starlinkv40305	t
1808	62	starlinkv40306	t
1809	62	starlinkv40307	t
1810	62	starlinkv40308	t
1811	62	starlinkv40309	t
1812	62	starlinkv40310	t
1813	62	starlinkv40311	t
1814	62	starlinkv40312	t
1815	62	starlinkv40313	t
1816	62	starlinkv40314	t
1817	62	starlinkv40315	t
1818	62	starlinkv40316	t
1819	62	starlinkv40317	t
1820	62	starlinkv40318	t
1821	62	starlinkv40319	t
1822	62	starlinkv40320	t
1823	62	starlinkv40321	t
1824	62	starlinkv40322	t
1825	62	starlinkv40323	t
1826	62	starlinkv40324	t
1827	62	starlinkv40325	t
1828	62	starlinkv40326	t
1829	62	starlinkv40327	t
1830	62	starlinkv40328	t
1831	62	starlinkv40329	t
1832	62	starlinkv40330	t
1833	62	starlinkv40331	t
1834	62	starlinkv40332	t
1835	62	starlinkv40333	t
1836	62	starlinkv40334	t
1837	62	starlinkv40335	t
1838	62	starlinkv40336	t
1839	62	starlinkv40337	t
1840	62	starlinkv40338	t
1841	62	starlinkv40339	t
1842	62	starlinkv40340	t
1843	62	starlinkv40341	t
1844	62	starlinkv40342	t
1845	62	starlinkv40343	t
1846	62	starlinkv40344	t
1847	62	starlinkv40345	t
1848	62	starlinkv40346	t
1849	62	starlinkv40347	t
1850	62	starlinkv40348	t
1851	62	starlinkv40349	t
1852	62	starlinkv40350	t
1853	62	starlinkv40351	t
1854	62	starlinkv40352	t
1855	62	starlinkv40353	t
1856	62	starlinkv40354	t
1857	62	starlinkv40355	t
1858	62	starlinkv40356	t
1859	62	starlinkv40357	t
1860	62	starlinkv40358	t
1861	62	starlinkv40359	t
1862	62	starlinkv40360	t
1863	62	starlinkv40361	t
1864	62	starlinkv40362	t
1865	62	starlinkv40363	t
1866	62	starlinkv40364	t
1867	62	starlinkv40365	t
1868	62	starlinkv40366	t
1869	62	starlinkv40367	t
1870	62	starlinkv40368	t
1871	62	starlinkv40369	t
1872	62	starlinkv40370	t
1873	62	starlinkv40371	t
1874	62	starlinkv40372	t
1875	62	starlinkv40373	t
1876	62	starlinkv40374	t
1877	62	starlinkv40375	t
1878	63	starlinkv40376	t
1879	63	starlinkv40377	t
1880	63	starlinkv40378	t
1881	63	starlinkv40379	t
1882	63	starlinkv40380	t
1883	63	starlinkv40381	t
1884	63	starlinkv40382	t
1885	63	starlinkv40383	t
1886	63	starlinkv40384	t
1887	63	starlinkv40385	t
1888	63	starlinkv40386	t
1889	63	starlinkv40387	t
1890	63	starlinkv40388	t
1891	63	starlinkv40389	t
1892	63	starlinkv40390	t
1893	64	starlinkv40391	t
1894	64	starlinkv40392	t
1895	64	starlinkv40393	t
1896	64	starlinkv40394	t
1897	64	starlinkv40395	t
1898	64	starlinkv40396	t
1899	64	starlinkv40397	t
1900	64	starlinkv40398	t
1901	64	starlinkv40399	t
1902	64	starlinkv40400	t
1903	64	starlinkv40401	t
1904	64	starlinkv40402	t
1905	64	starlinkv40403	t
1906	64	starlinkv40404	t
1907	64	starlinkv40405	t
1908	64	starlinkv40406	t
1909	64	starlinkv40407	t
1910	64	starlinkv40408	t
1911	64	starlinkv40409	t
1912	64	starlinkv40410	t
1913	64	starlinkv40411	t
1914	64	starlinkv40412	t
1915	64	starlinkv40413	t
1916	65	starlinkv40414	t
1917	65	starlinkv40415	t
1918	65	starlinkv40416	t
1919	65	starlinkv40417	t
1920	65	starlinkv40418	t
1921	65	starlinkv40419	t
1922	65	starlinkv40420	t
1923	65	starlinkv40421	t
1924	65	starlinkv40422	t
1925	65	starlinkv40423	t
1926	65	starlinkv40424	t
1927	65	starlinkv40425	t
1928	65	starlinkv40426	t
1929	65	starlinkv40427	t
1930	65	starlinkv40428	t
1931	65	starlinkv40429	t
1932	65	starlinkv40430	t
1933	65	starlinkv40431	t
1934	65	starlinkv40432	t
1935	65	starlinkv40433	t
1936	65	starlinkv40434	t
1937	65	starlinkv40435	t
1938	65	starlinkv40436	t
1939	65	starlinkv40437	t
1940	65	starlinkv40438	t
1941	65	starlinkv40439	t
1942	65	starlinkv40440	t
1943	65	starlinkv40441	t
1944	65	starlinkv40442	t
1945	65	starlinkv40443	t
1946	65	starlinkv40444	t
1947	65	starlinkv40445	t
1948	65	starlinkv40446	t
1949	65	starlinkv40447	t
1950	65	starlinkv40448	t
1951	65	starlinkv40449	t
1952	65	starlinkv40450	t
1953	66	metaquest3s001	t
1954	67	4V0ZW23H7602XL	t
1955	67	4V0ZW23H6Z00DY	t
1956	67	2Q9GS02H7607MX	t
1957	67	2Q0ZY12H6F00DM	t
1958	67	2Q9GS00H9R0MPL	t
1959	67	2Q9GS00H9K091G	t
1960	68	raybanglass00001	t
1961	68	raybanglass00002	t
1962	68	raybanglass00003	t
1963	69	RS0290-GP0344450	t
1964	69	RS0290-GP0348792	t
1965	69	RS0290-GP0349113	t
1966	70	NHQX6SA001513010BD0X15	t
1967	70	NHQX6SA001513011270X15	t
1968	70	NHQX6SA001520011E20X15	t
1969	70	NHQX6SA001520011B70X15	t
1970	70	NHQX6SA001520011800X15	t
1971	70	NHQX6SA00151500FB40X15	t
1972	70	NHQX6SA001520013F90X15	t
1973	70	NHQX6SA0015200102D0X15	t
1974	70	NHQX6SA001520014060X15	t
1975	70	NHQX6SA001520013FC0X15	t
1976	71	]C121159503000032	t
1977	71	]C121159503000235	t
1978	71	]C121159503000491	t
1979	71	]C121159503000499	t
1980	71	]C121159503000063	t
1981	71	]C121159503000039	t
1982	71	]C121159503000060	t
1983	71	]C121159503000196	t
1984	71	]C121159503000377	t
1985	71	]C121159503000493	t
1986	71	]C121159503000233	t
1987	71	]C121159503000496	t
1988	71	]C121159503000385	t
1989	71	]C121159503000140	t
1990	71	]C121159503000055	t
1991	71	]C121159503000051	t
1992	71	]C121159503000308	t
1993	71	]C121159503000057	t
1994	72	silkepilator90001	t
1995	72	silkepilator90002	t
1996	72	silkepilator90003	t
1997	72	silkepilator90004	t
1998	73	silkepilator70001	t
1999	73	silkepilator70002	t
2000	73	silkepilator70003	t
2001	74	shaver60001	t
2002	74	shaver60002	t
2003	74	shaver60003	t
2004	75	shaver60004	t
2005	76	allinonetrimmer70001	t
2006	77	allinonetrimmer50001	t
2007	77	allinonetrimmer50002	t
2008	77	allinonetrimmer50003	t
2009	78	braunipl51370001	t
2010	78	braunipl51370002	t
2011	79	braunipl51370003	t
2012	79	braunipl51370004	t
2013	79	braunipl51370005	t
2014	79	braunipl51370006	t
2015	79	braunipl51370007	t
2016	79	braunipl51370008	t
2017	80	braun9in10001	t
2018	81	S25ultra0001	t
2019	82	INSTAXWIDE4000001	t
2020	82	INSTAXWIDE4000002	t
2021	82	INSTAXWIDE4000003	t
2022	82	INSTAXWIDE4000004	t
2023	82	INSTAXWIDE4000005	t
2024	82	INSTAXWIDE4000006	t
2025	82	INSTAXWIDE4000007	t
2026	82	INSTAXWIDE4000008	t
2027	82	INSTAXWIDE4000009	t
2028	82	INSTAXWIDE4000010	t
2029	83	astrobotgame00001	t
2030	84	SJWMFJKY3N4	t
2031	84	SL7XYP0G23D	t
2032	84	SG720G7T46C	t
2033	85	JBLC6-0001	t
2034	85	JBLC6-0002	t
2035	85	JBLC6-0003	t
2036	85	JBLC6-0004	t
2037	85	JBLC6-0005	t
2038	85	JBLC6-0006	t
2039	85	JBLC6-0007	t
2040	85	JBLC6-0008	t
2041	85	JBLC6-0009	t
2042	85	JBLC6-0010	t
2043	85	JBLC6-0011	t
2044	85	JBLC6-0012	t
2045	85	JBLC6-0013	t
2046	85	JBLC6-0014	t
2047	85	JBLC6-0015	t
2048	85	JBLC6-0016	t
2049	85	JBLC6-0017	t
2050	85	JBLC6-0018	t
2051	85	JBLC6-0019	t
2052	85	JBLC6-0020	t
2053	85	JBLC6-0021	t
2054	85	JBLC6-0022	t
2055	85	JBLC6-0023	t
2056	85	JBLC6-0024	t
2057	85	JBLC6-0025	t
2058	85	JBLC6-0026	t
2059	85	JBLC6-0027	t
2060	85	JBLC6-0028	t
2061	85	JBLC6-0029	t
2062	85	JBLC6-0030	t
2063	85	JBLC6-0031	t
2064	85	JBLC6-0032	t
2065	85	JBLC6-0033	t
2066	85	JBLC6-0034	t
2067	85	JBLC6-0035	t
2068	85	JBLC6-0036	t
2069	85	JBLC6-0037	t
2070	85	JBLC6-0038	t
2071	85	JBLC6-0039	t
2072	85	JBLC6-0040	t
2073	86	JBLC6-0041	t
2074	86	JBLC6-0042	t
2075	86	JBLC6-0043	t
2076	86	JBLC6-0044	t
2077	86	JBLC6-0045	t
2078	86	JBLC6-0046	t
2079	86	JBLC6-0047	t
2080	87	JBLC6-0048	t
2081	87	JBLC6-0049	t
2082	87	JBLC6-0050	t
2083	87	JBLC6-0051	t
2084	87	JBLC6-0052	t
2085	87	JBLC6-0053	t
2086	87	JBLC6-0054	t
2087	87	JBLC6-0055	t
2088	87	JBLC6-0056	t
2089	87	JBLC6-0057	t
2090	88	JBLC6-0058	t
2091	88	JBLC6-0059	t
2092	89	JBLC6-0060	t
2093	89	JBLC6-0061	t
2094	89	JBLC6-0062	t
2095	89	JBLC6-0063	t
2096	89	JBLC6-0064	t
2097	90	2Q9GS11H7Q0BX3	t
2098	91	357205987236407	t
2099	92	359811269284607	t
2100	93	356334540191734	t
2101	94	356706681483527	t
2102	95	SLT21H7HQ07	t
2103	96	SK4J0CJP9GD	t
2104	97	SMH6XKV42GN	t
2105	98	SCLJDXQM0M5	t
2106	98	SLW5X9YYFV4	t
2107	98	SDHWJP7GCTQ	t
2108	98	SJQ1034P73F	t
2109	98	SK9HQP762LY	t
2110	98	SG03VC4XHGQ	t
2111	99	SDXFHWMK411	t
2112	100	358112934982993	t
2113	101	SKFHLW39006	t
2114	102	354780907319619	t
2115	102	359045769498108	t
2116	103	353729490556559	t
2117	104	353729490518146	t
2118	105	355362421357943	t
2119	105	355362421357711	t
2120	106	359493732980820	t
2121	106	356422163856533	t
2122	107	356706681272813	t
2123	108	354123754950428	t
2124	108	354123755217074	t
2125	108	354123752557134	t
2126	108	354123758609392	t
2127	109	358911633611088	t
2128	110	358911632167553	t
2129	111	357550247169306	t
2130	112	359132196544314	t
2131	112	359132192725040	t
2132	113	357550246973039	t
2133	114	352905161312222	t
2134	115	356334540659417	t
2135	116	352066342028508	t
2136	117	358345392856594	t
2137	118	S01K15301M8110364247	t
2138	118	S01K15401M8110414717	t
2139	118	S01K15501M8110427662	t
2140	118	S01F14B01GH910943285	t
2141	118	S01K15501M8110427617	t
2142	118	S01K15101M8110310006	t
2143	118	S01K25701VJ910336156	t
2144	118	S01K15501M8110454774	t
2145	118	S01K15101M8110303945	t
2146	119	S01K15401M8110401394	t
2147	120	S01M45601K1W11165182	t
2148	120	S01M45601K1W11165181	t
2149	121	S01V55601Z1L10345699	t
2150	121	S01V55601Z1L10458423	t
2151	121	S01V55601Z1L10304899	t
2152	121	S01V55601Z1L10345582	t
2153	121	S01V55601Z1L10504969	t
2154	121	S01V55601Z1L10377962	t
2155	121	S01K5560179810281816	t
2156	121	S01V55801Z1L11001841	t
2157	121	S01V55701Z1L10846630	t
2158	121	S01V55801Z1L11086063	t
2159	121	S01V55801Z1L11081301	t
2160	121	S01V55801Z1L11057425	t
2161	121	S01V55801Z1L11086045	t
2162	122	S01V55801UNL11264243	t
2163	122	S01V55901UNL11364709	t
2164	123	S01E44A01X4912823801	t
2165	123	S011558343F	t
2166	123	S0115405247	t
2167	124	playstationportal00001	t
2168	124	playstationportal00002	t
2169	125	dualsensewirelesscontroller00001	t
2170	125	dualsensewirelesscontroller00002	t
2171	125	dualsensewirelesscontroller00003	t
2172	125	dualsensewirelesscontroller00004	t
2173	125	dualsensewirelesscontroller00005	t
2174	125	dualsensewirelesscontroller00006	t
2175	125	dualsensewirelesscontroller00007	t
2176	125	dualsensewirelesscontroller00008	t
2177	125	dualsensewirelesscontroller00009	t
2178	125	dualsensewirelesscontroller00010	t
2179	125	dualsensewirelesscontroller00011	t
2180	125	dualsensewirelesscontroller00012	t
2181	125	dualsensewirelesscontroller00013	t
2182	125	dualsensewirelesscontroller00014	t
2183	125	dualsensewirelesscontroller00015	t
2184	125	dualsensewirelesscontroller00016	t
2185	125	dualsensewirelesscontroller00017	t
2186	125	dualsensewirelesscontroller00018	t
2187	126	dualsensewirelesscontroller00019	t
2188	126	dualsensewirelesscontroller00020	t
2189	126	dualsensewirelesscontroller00021	t
2190	126	dualsensewirelesscontroller00022	t
2191	126	dualsensewirelesscontroller00023	t
2192	126	dualsensewirelesscontroller00024	t
2193	126	dualsensewirelesscontroller00025	t
2194	126	dualsensewirelesscontroller00026	t
2195	126	dualsensewirelesscontroller00027	t
2196	126	dualsensewirelesscontroller00028	t
2197	126	dualsensewirelesscontroller00029	t
2198	126	dualsensewirelesscontroller00030	t
2199	126	dualsensewirelesscontroller00031	t
2200	126	dualsensewirelesscontroller00032	t
2201	126	dualsensewirelesscontroller00033	t
2202	126	dualsensewirelesscontroller00034	t
2203	126	dualsensewirelesscontroller00035	t
2204	126	dualsensewirelesscontroller00036	t
2205	126	dualsensewirelesscontroller00037	t
2206	127	S01G13200K1J11901709	t
2207	128	cddragonage001	t
2208	128	cddragonage002	t
2209	128	cddragonage003	t
2210	129	HAW50133386373	t
2211	129	HAW50823681801	t
2212	129	HAW50999742764	t
2213	129	HAW50552318047	t
2214	129	HAW50879431337	t
2215	129	HAW50594654479	t
2216	130	HAW50872099053	t
2217	130	XKW70042063868	t
2218	131	XKW40016891919	t
2219	132	2388071	t
2220	132	2431142	t
2221	133	SCRGHQQVPXF	t
2222	133	SFN4KXRQCTK	t
2223	134	SH2DN10B1LN3P	t
2224	134	SH2JMX109LN3P	t
2225	135	085954T53164697AE	t
2226	136	076842950653250AE	t
2227	137	C3535424564583	t
2228	138	87F852433	t
2229	139	610528253621	t
2230	140	3497BMMH9303DP	t
2231	141	2G97BMMH9S00J0	t
2232	141	2G97BMMH9X03ZS	t
2233	141	2G97BMMH9Q057K	t
2234	141	2G0YBMTH0700FL	t
2235	142	SCYDJ4CQP61	t
2236	142	SGW14WNWRLY	t
2237	142	SHVJJJQWFQ1	t
2238	143	SKTH7XD95H4	t
2239	143	SHYD12GT7FV	t
2240	144	SC0Y0F9X7QC	t
2241	144	SGCF92TLQXH	t
2242	144	SG2D1H6GKVC	t
2243	144	SHLQQTX9JGW	t
2244	145	SGHJYWKVQXD	t
2245	146	SV49N6TXD96	t
2246	147	SDKJYYPYHW5	t
2247	148	59101WRBJB3416	t
2248	148	58111WRBJB0499	t
2249	149	359636864068653	t
2250	150	353490912585953	t
2251	151	358352972640471	t
2252	152	4W0ZWF5H760BH3	t
2253	152	4V37W29H7X00MG	t
2254	152	4V37W31H9900B3	t
2255	152	4V0ZW04H9F04PK	t
2256	152	4V0ZW27H9L0132	t
2257	152	2Q9GS11H9J04VT	t
2258	152	2Q9GS11H9H0C2P	t
2259	152	2Q9GS11H9J0438	t
2260	152	2Q9GS11H9H04GR	t
2261	153	2Q9GS11HBG08WZ	t
2262	153	2Q9GS11H9J03Q1	t
2263	153	2Q9GS11H9H0204	t
2264	154	2Q9GS11H9H04ZK	t
2265	155	2Q9GS11H9G01M4	t
2266	156	352457390429203	t
2267	157	352457390576607	t
2268	158	359117430967728	t
2269	159	SK6GQGF74F4	t
2270	160	SGVQ2RQRCMW	t
2271	161	ST76N06VX9D	t
2272	162	SF7J9C4WVDW	t
2273	163	SK327X51Q91	t
2274	164	SL93Y0GWVRC	t
2275	165	SC91KHM70VM	t
2276	166	SGPGK00MPQ7	t
2277	167	SFVFHN160Q6L5	t
2278	168	356196182587945	t
2279	168	356196183103940	t
2280	168	355205568606640	t
2281	169	352066342215865	t
2282	170	SJXKF950C3P	t
2283	171	358112930502035	t
2284	172	358112931678883	t
2285	173	358112932166375	t
2286	174	352355706850411	t
2287	174	352355704532573	t
2288	174	352355700973722	t
2289	174	352355701807754	t
2290	175	352355709742698	t
2291	176	350247150243361	t
2292	177	356764175496547	t
2293	178	355478870898102	t
2294	179	353837412105817	t
2295	180	355122363950588	t
2296	181	358419940353196	t
2297	182	359724852602210	t
2298	183	358271520320685	t
2299	184	351523426490179	t
2300	185	359222381700076	t
2301	186	356541620272248	t
2302	187	356864569740201	t
2303	188	359222389749273	t
2304	189	357031376241620	t
2305	190	353357355939908	t
2306	191	354136652550926	t
2307	192	356043381249259	t
2308	193	351661825602182	t
2309	194	357275795101812	t
2310	195	350832430489197	t
2311	196	352772254261397	t
2312	197	353352950838027	t
2313	198	353427814932297	t
2314	199	359836518197367	t
2315	200	352066342213241	t
2316	201	357494474437690	t
2317	202	358911632646218	t
2318	203	353173803445491	t
2319	204	356799836296837	t
2320	205	SJ460W9GH4F	t
2321	206	SDCLXG1749Y	t
2322	207	355783829033440	t
2323	208	352368545956687	t
2324	208	352758404050616	t
2325	208	354512320603638	t
2326	208	354512324560990	t
2327	208	358936958142898	t
2328	208	352758404284538	t
2329	208	352758404073113	t
2330	208	352368545993615	t
2331	208	352368546192654	t
2332	209	354512323488342	t
2333	209	352602317458153	t
2334	209	354512320823475	t
2335	210	fujiinstaxminiliply00001	t
2336	210	fujiinstaxminiliply00002	t
2337	210	fujiinstaxminiliply00003	t
2338	210	fujiinstaxminiliply00004	t
2339	210	fujiinstaxminiliply00005	t
2340	210	fujiinstaxminiliply00006	t
2341	211	onnsingleusecamera00001	t
2342	211	onnsingleusecamera00002	t
2343	211	onnsingleusecamera00003	t
2344	211	onnsingleusecamera00004	t
2345	211	onnsingleusecamera00005	t
2346	211	onnsingleusecamera00006	t
2347	211	onnsingleusecamera00007	t
2348	211	onnsingleusecamera00008	t
2349	211	onnsingleusecamera00009	t
2350	211	onnsingleusecamera00010	t
2351	212	onnreusablecamera00001	t
2352	213	351525510727416	t
2353	213	351525510878441	t
2354	214	359493733064400	t
2355	214	356422165489838	t
2356	215	359103740084792	t
2357	216	350773430942266	t
2366	224	pixel0001	t
2367	225	352653442265609	t
2368	226	353247105566665	t
2369	227	353890109487576	t
2370	228	352315403679901	t
2371	228	357205981249315	t
2372	229	355964948552797	t
2373	230	356295606462741	t
2374	231	1581F8LQC259V0025QND	t
2375	231	1581F8LQC255Q0022GVN	t
2376	232	354136652903232	t
2377	233	357463448249218	t
2378	234	352315400015596	t
2379	235	354359265927857	t
2380	236	351399081079239	t
2381	237	356764170580642	t
2382	238	359724859410781	t
2383	239	352676524778959	t
2384	240	358001685550705	t
2385	241	351687742123226	t
2386	242	SKVNHV9WJ4J	t
2387	243	L0FVM00VD9	t
2388	244	SMT43DHJRGH	t
2389	244	SK946HW04X3	t
2390	244	SGD4TR707KJ	t
2391	245	SD2WYWYFPLV	t
2392	245	SDX9XWFKW42	t
2393	245	SL9W0J24GDM	t
2394	245	SM7RR6FRW7N	t
2395	246	359132197678855	t
2396	247	SH6W4PFQWCW	t
2397	248	356187982445939	t
2398	249	359800206266629	t
2399	249	358344510337678	t
2400	249	359800204422869	t
2401	250	SDF9R6G97J0	t
2402	251	SMT79VX36C5	t
2403	251	SMJF72R0W6K	t
2404	252	SF3W6VGQT49	t
2405	253	4V0ZH17H7X01K1	t
2406	254	2Q0ZY01H6R0088	t
2407	255	4V0ZS17H8H02KD	t
2408	255	4V0ZS12H8M0121	t
2409	256	2Q0ZT00H9108MM	t
2410	257	4V37W23H8Y03BB	t
2411	258	350094261697964	t
2412	258	350094261355704	t
2413	259	SJ56LKQX91F	t
2414	260	SLJ2DW1GJPG	t
2415	261	SM04W37XK2M	t
2416	262	357153132623899	t
2417	263	356334540274274	t
2418	264	358112930542452	t
2419	265	353894107001488	t
2420	266	358691739992588	t
2421	267	357773240293275	t
2422	268	357773241392274	t
2423	269	356832826585198	t
2424	270	357985605788059	t
2425	271	353685834007800	t
2426	272	357762265949689	t
2427	273	357719281961635	t
2428	274	355008282401839	t
2429	275	355445520481381	t
2430	276	355852812209224	t
2431	276	350138782777415	t
2432	276	352515983937724	t
2433	276	350304975570948	t
2434	277	358051322533887	t
2435	277	353837419391642	t
2436	277	358051321265978	t
2437	277	356605225057831	t
2438	277	350889862536879	t
2439	277	353263425144000	t
2440	277	359614544687390	t
2441	278	359912587219711	t
2442	278	359614541610171	t
2443	278	359614540060931	t
2444	279	353263423932034	t
2445	280	358229303109360	t
2446	281	356768323979858	t
2447	282	355827874735076	t
2448	282	355827873912551	t
2449	283	356768327697845	t
2450	283	355827874548040	t
2451	283	356768323955908	t
2452	283	355827874619494	t
2453	283	355827874116541	t
2454	283	358135794483430	t
2455	283	358135794723439	t
2456	284	352355700400171	t
2457	285	350795041545725	t
2458	285	357223745121191	t
2459	286	351317522499402	t
2460	287	356250549251677	t
2461	287	350208033090551	t
2462	287	350208033173753	t
2463	287	350208033299269	t
2464	287	356250549428937	t
2465	287	356250549139179	t
2466	287	350208033166849	t
2467	287	352190324660847	t
2468	288	350208037361842	t
2469	288	350208037531998	t
2470	289	355224250029748	t
2471	290	358051322163339	t
2472	290	350889865420378	t
2473	290	357586344694234	t
2474	290	356188163778437	t
2475	290	358051322098196	t
2476	290	357586344596264	t
2477	291	352673830520696	t
2478	291	355201220205269	t
2479	292	355827874060491	t
2480	292	356768325047464	t
2481	292	355827873857608	t
2482	292	355827874760009	t
2483	292	356768328441524	t
2484	292	356187983372108	t
2485	292	358135794112948	t
2486	293	351878871049411	t
2487	293	351878871034231	t
2488	293	356930604129856	t
2489	294	352355707404705	t
2490	295	350795040883309	t
2491	295	357247591394057	t
2492	295	350795041218463	t
2493	295	350795041085185	t
2494	296	352190327421734	t
2495	296	354956974267937	t
2496	296	356661405453746	t
2497	296	356250543171277	t
2498	296	356250549338896	t
2499	296	352190327764315	t
2500	296	353708846189133	t
2501	297	355450218650917	t
2502	297	356605226033781	t
2503	298	357586344726028	t
2504	298	350889864968799	t
2505	298	358051322474710	t
2506	298	356188163860573	t
2507	298	358051322301210	t
2508	298	358051321091101	t
\.


--
-- Data for Name: receipts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.receipts (receipt_id, party_id, account_id, amount, receipt_date, method, reference_no, journal_id, date_created, notes, description) FROM stdin;
1	67	5	15000.00	2026-01-06	Cash	RCT-1	115	2026-01-06 16:06:41.776409	\N	Out to loss Account 
\.


--
-- Data for Name: salesinvoices; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesinvoices (sales_invoice_id, customer_id, invoice_date, total_amount, journal_id) FROM stdin;
\.


--
-- Data for Name: salesitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesitems (sales_item_id, sales_invoice_id, item_id, quantity, unit_price) FROM stdin;
\.


--
-- Data for Name: salesreturnitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesreturnitems (return_item_id, sales_return_id, item_id, sold_price, cost_price, serial_number) FROM stdin;
\.


--
-- Data for Name: salesreturns; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesreturns (sales_return_id, customer_id, return_date, total_amount, journal_id) FROM stdin;
\.


--
-- Data for Name: soldunits; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.soldunits (sold_unit_id, sales_item_id, unit_id, sold_price, status) FROM stdin;
\.


--
-- Data for Name: stockmovements; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.stockmovements (movement_id, item_id, serial_number, movement_type, reference_type, reference_id, movement_date, quantity) FROM stdin;
1	29	cddragonage004	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
2	29	cddragonage005	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
3	29	cddragonage006	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
4	29	cddragonage007	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
5	29	cddragonage008	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
6	29	cddragonage009	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
7	29	cddragonage010	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
8	29	cddragonage011	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
9	29	cddragonage012	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
10	29	cddragonage013	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
11	29	cddragonage014	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
12	29	cddragonage015	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
13	29	cddragonage016	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
14	29	cddragonage017	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
15	29	cddragonage018	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
16	29	cddragonage019	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
17	29	cddragonage020	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
18	29	cddragonage021	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
19	29	cddragonage022	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
20	29	cddragonage023	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
21	29	cddragonage024	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
22	29	cddragonage025	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
23	29	cddragonage026	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
24	29	cddragonage027	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
25	29	cddragonage028	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
26	29	cddragonage029	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
27	29	cddragonage030	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
28	29	cddragonage031	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
29	29	cddragonage032	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
30	29	cddragonage033	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
31	29	cddragonage034	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
32	29	cddragonage035	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
33	29	cddragonage036	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
34	29	cddragonage037	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
35	29	cddragonage038	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
36	29	cddragonage039	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
37	29	cddragonage040	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
38	29	cddragonage041	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
39	29	cddragonage042	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
40	29	cddragonage043	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
41	29	cddragonage044	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
42	29	cddragonage045	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
43	29	cddragonage046	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
44	29	cddragonage047	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
45	29	cddragonage048	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
46	29	cddragonage049	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
47	29	cddragonage050	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
48	29	cddragonage051	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
49	29	cddragonage052	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
50	29	cddragonage053	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
51	29	cddragonage054	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
52	29	cddragonage055	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
53	29	cddragonage056	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
54	29	cddragonage057	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
55	29	cddragonage058	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
56	29	cddragonage059	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
57	29	cddragonage060	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
58	29	cddragonage061	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
59	29	cddragonage062	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
60	29	cddragonage063	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
61	29	cddragonage064	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
62	29	cddragonage065	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
63	29	cddragonage066	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
64	29	cddragonage067	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
65	29	cddragonage068	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
66	29	cddragonage069	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
67	29	cddragonage070	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
68	29	cddragonage071	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
69	29	cddragonage072	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
70	29	cddragonage073	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
71	29	cddragonage074	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
72	29	cddragonage075	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
73	29	cddragonage076	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
74	29	cddragonage077	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
75	29	cddragonage078	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
76	29	cddragonage079	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
77	29	cddragonage080	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
78	29	cddragonage081	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
79	29	cddragonage082	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
80	29	cddragonage083	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
81	29	cddragonage084	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
82	29	cddragonage085	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
83	29	cddragonage086	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
84	29	cddragonage087	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
85	29	cddragonage088	IN	PurchaseInvoice	1	2026-01-04 15:42:21.678551	1
86	94	skylinev2pouch30001	IN	PurchaseInvoice	2	2026-01-04 15:42:21.692909	1
87	94	skylinev2pouch30002	IN	PurchaseInvoice	2	2026-01-04 15:42:21.692909	1
88	94	skylinev2pouch30003	IN	PurchaseInvoice	2	2026-01-04 15:42:21.692909	1
89	94	skylinev2pouch30004	IN	PurchaseInvoice	2	2026-01-04 15:42:21.692909	1
90	94	skylinev2pouch30005	IN	PurchaseInvoice	2	2026-01-04 15:42:21.692909	1
91	31	XKW50103180253	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
92	110	196214119062	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
93	111	SV30F9ZMC	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
94	112	810116381937	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
95	113	PNT0E3015253PTAU	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
96	114	prestoelectrickettle001	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
97	115	353138601828735	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
98	70	355122367429969	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
99	79	355067541901427	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
100	92	SHP4MF2TF9Q	IN	PurchaseInvoice	3	2026-01-04 15:44:33.93609	1
101	2	S01E45601CE810572356	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
102	2	S01E45601CE810570281	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
103	2	S01E45601CE810595951	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
104	2	S01E45601CE810570323	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
105	2	S01E45601CE810573044	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
106	2	S01E45601CE810565094	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
107	2	S01E45601CE810573039	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
108	2	S01E45501CE810557417	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
109	2	S01F44C01NXM10424000	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
110	2	S01E45601CE810599344	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
111	2	S01E45601CE810573040	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
112	2	S01E45601CE810573043	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
113	2	S01E45601CE810599343	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
114	2	S01E45601CE810565069	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
115	2	S01F55901DR210321979	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
116	2	S01E45601CE810585832	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
117	2	S01F55801DR210266420	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
118	2	S01E45601CE810576101	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
119	2	S01E45601CE810580025	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
120	2	S01E45601CE810578019	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
121	2	S01E45601CE810578011	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
122	2	S01E45601CE810576162	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
123	2	ps5slim00001	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
124	2	ps5slim00002	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
125	2	ps5slim00003	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
126	2	ps5slim00004	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
127	2	ps5slim00005	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
128	2	ps5slim00006	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
129	2	ps5slim00007	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
130	2	ps5slim00008	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
131	2	ps5slim00009	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
132	2	ps5slim00010	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
133	2	ps5slim00011	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
134	2	ps5slim00012	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
135	2	ps5slim00013	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
136	2	ps5slim00014	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
137	2	ps5slim00015	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
138	2	ps5slim00016	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
139	2	ps5slim00017	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
140	2	ps5slim00018	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
141	2	ps5slim00019	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
142	2	ps5slim00020	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
143	2	ps5slim00021	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
144	2	ps5slim00022	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
145	2	ps5slim00023	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
146	2	ps5slim00024	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
147	2	ps5slim00025	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
148	2	ps5slim00026	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
149	2	ps5slim00027	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
150	2	ps5slim00028	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
151	2	ps5slim00029	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
152	2	ps5slim00030	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
153	2	ps5slim00031	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
154	2	ps5slim00032	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
155	2	ps5slim00033	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
156	2	ps5slim00034	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
157	2	ps5slim00035	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
158	2	ps5slim00036	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
159	2	ps5slim00037	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
160	2	ps5slim00038	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
161	2	ps5slim00039	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
162	2	ps5slim00040	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
163	2	ps5slim00041	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
164	2	ps5slim00042	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
165	2	ps5slim00043	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
166	2	ps5slim00044	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
167	2	ps5slim00045	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
168	2	ps5slim00046	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
169	2	ps5slim00047	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
170	2	ps5slim00048	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
171	2	ps5slim00049	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
172	2	ps5slim00050	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
173	2	ps5slim00051	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
174	2	ps5slim00052	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
175	2	ps5slim00053	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
176	2	ps5slim00054	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
177	2	ps5slim00055	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
178	2	ps5slim00056	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
179	2	ps5slim00057	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
180	2	ps5slim00058	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
181	2	ps5slim00059	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
182	2	ps5slim00060	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
183	2	ps5slim00061	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
184	2	ps5slim00062	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
185	2	ps5slim00063	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
186	2	ps5slim00064	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
187	2	ps5slim00065	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
188	2	ps5slim00066	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
189	2	ps5slim00067	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
190	2	ps5slim00068	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
191	2	ps5slim00069	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
192	2	ps5slim00070	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
193	2	ps5slim00071	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
194	2	ps5slim00072	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
195	2	ps5slim00073	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
196	2	ps5slim00074	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
197	2	ps5slim00075	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
198	2	ps5slim00076	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
199	2	ps5slim00077	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
200	2	ps5slim00078	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
201	2	ps5slim00079	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
202	2	ps5slim00080	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
203	2	ps5slim00081	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
204	2	ps5slim00082	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
205	2	ps5slim00083	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
206	2	ps5slim00084	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
207	2	ps5slim00085	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
208	2	ps5slim00086	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
209	2	ps5slim00087	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
210	2	ps5slim00088	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
211	2	ps5slim00089	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
212	2	ps5slim00090	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
213	2	ps5slim00091	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
214	2	ps5slim00092	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
215	2	ps5slim00093	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
216	2	ps5slim00094	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
217	2	ps5slim00095	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
218	2	ps5slim00096	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
219	2	ps5slim00097	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
220	2	ps5slim00098	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
221	2	ps5slim00099	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
222	2	ps5slim00100	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
223	2	ps5slim00101	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
224	2	ps5slim00102	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
225	2	ps5slim00103	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
226	2	ps5slim00104	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
227	2	ps5slim00105	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
228	2	ps5slim00106	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
229	2	ps5slim00107	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
230	2	ps5slim00108	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
231	2	ps5slim00109	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
232	2	ps5slim00110	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
233	2	ps5slim00111	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
234	2	ps5slim00112	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
235	2	ps5slim00113	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
236	2	ps5slim00114	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
237	2	ps5slim00115	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
238	2	ps5slim00116	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
239	2	ps5slim00117	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
240	2	ps5slim00118	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
241	2	ps5slim00119	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
242	2	ps5slim00120	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
243	2	ps5slim00121	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
244	2	ps5slim00122	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
245	2	ps5slim00123	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
246	2	ps5slim00124	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
247	2	ps5slim00125	IN	PurchaseInvoice	4	2026-01-05 13:53:56.498622	1
248	3	S01V558019CN10258177	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
249	3	S01F55701RRC10260424	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
250	3	S01V558019CN10255412	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
251	3	S01F55701RRC10252871	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
252	3	S01F55701RRC10253380	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
253	3	S01F55701RRC10260047	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
254	3	S01V558019CN10258939	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
255	3	S01F55801RRC10263365	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
256	3	S01F55701RRC10259204	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
257	3	S01F55701RRC10252786	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
258	3	S01F55701RRC10252873	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
259	3	S01F55701RRC10252785	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
260	3	S01F55701RRC10252801	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
261	3	S01F55701RRC10253418	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
262	3	S01F55801RRC10263353	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
263	3	S01V558019CN10256717	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
264	3	S01F55701RRC10252722	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
265	3	S01F55701RRC10252874	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
266	3	S01F55801RRC10263356	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
267	3	S01F55801RRC10263364	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
268	3	S01F55701RRC10253425	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
269	3	S01F55701RRC10252869	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
270	3	S01F55901RRC10282523	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
271	3	S01F55801RRC10263355	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
272	3	S01F55901RRC10287502	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
273	3	S01F55701RRC10252798	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
274	3	S01F55901RRC10290683	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
275	3	S01V558019CN10250136	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
276	3	S01F55901RRC10290623	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
277	3	S01F55801RRC10263357	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
278	3	S01F55701RRC10252721	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
279	3	S01F55701RRC10253396	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
280	3	S01F55801RRC10263351	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
281	3	S01F55901RRC10303746	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
282	3	S01V558019CN10256466	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
283	3	S01F55701RRC10252797	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
284	3	S01F55701RRC10253379	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
285	3	S01F55901RRC10304141	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
286	3	S01F55901RRC10289942	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
287	3	S01E456016ER10403419	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
288	3	ps5slimdigital00001	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
289	3	ps5slimdigital00002	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
290	3	ps5slimdigital00003	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
291	3	ps5slimdigital00004	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
292	3	ps5slimdigital00005	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
293	3	ps5slimdigital00006	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
294	3	ps5slimdigital00007	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
295	3	ps5slimdigital00008	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
296	3	ps5slimdigital00009	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
297	3	ps5slimdigital00010	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
298	3	ps5slimdigital00011	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
299	3	ps5slimdigital00012	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
300	3	ps5slimdigital00013	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
301	3	ps5slimdigital00014	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
302	3	ps5slimdigital00015	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
303	3	ps5slimdigital00016	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
304	3	ps5slimdigital00017	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
305	3	ps5slimdigital00018	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
306	3	ps5slimdigital00019	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
307	3	ps5slimdigital00020	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
308	3	ps5slimdigital00021	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
309	3	ps5slimdigital00022	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
310	3	ps5slimdigital00023	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
311	3	ps5slimdigital00024	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
312	3	ps5slimdigital00025	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
313	3	ps5slimdigital00026	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
314	3	ps5slimdigital00027	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
315	3	ps5slimdigital00028	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
316	3	ps5slimdigital00029	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
317	3	ps5slimdigital00030	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
318	3	ps5slimdigital00031	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
319	3	ps5slimdigital00032	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
320	3	ps5slimdigital00033	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
321	3	ps5slimdigital00034	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
322	3	ps5slimdigital00035	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
323	3	ps5slimdigital00036	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
324	3	ps5slimdigital00037	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
325	3	ps5slimdigital00038	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
326	3	ps5slimdigital00039	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
327	3	ps5slimdigital00040	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
328	3	ps5slimdigital00041	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
329	3	ps5slimdigital00042	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
330	3	ps5slimdigital00043	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
331	3	ps5slimdigital00044	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
332	3	ps5slimdigital00045	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
333	3	ps5slimdigital00046	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
334	3	ps5slimdigital00047	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
335	3	ps5slimdigital00048	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
336	3	ps5slimdigital00049	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
337	3	ps5slimdigital00050	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
338	3	ps5slimdigital00051	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
339	3	ps5slimdigital00052	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
340	3	ps5slimdigital00053	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
341	3	ps5slimdigital00054	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
342	3	ps5slimdigital00055	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
343	3	ps5slimdigital00056	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
344	3	ps5slimdigital00057	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
345	3	ps5slimdigital00058	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
346	3	ps5slimdigital00059	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
347	3	ps5slimdigital00060	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
348	3	ps5slimdigital00061	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
349	3	ps5slimdigital00062	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
350	3	ps5slimdigital00063	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
351	3	ps5slimdigital00064	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
352	3	ps5slimdigital00065	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
353	3	ps5slimdigital00066	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
354	3	ps5slimdigital00067	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
355	3	ps5slimdigital00068	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
356	3	ps5slimdigital00069	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
357	3	ps5slimdigital00070	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
358	3	ps5slimdigital00071	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
359	3	ps5slimdigital00072	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
360	3	ps5slimdigital00073	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
361	3	ps5slimdigital00074	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
362	3	ps5slimdigital00075	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
363	3	ps5slimdigital00076	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
364	3	ps5slimdigital00077	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
365	3	ps5slimdigital00078	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
366	3	ps5slimdigital00079	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
367	3	ps5slimdigital00080	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
368	3	ps5slimdigital00081	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
369	3	ps5slimdigital00082	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
370	3	ps5slimdigital00083	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
371	3	ps5slimdigital00084	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
372	3	ps5slimdigital00085	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
373	3	ps5slimdigital00086	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
374	3	ps5slimdigital00087	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
375	3	ps5slimdigital00088	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
376	3	ps5slimdigital00089	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
377	3	ps5slimdigital00090	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
378	3	ps5slimdigital00091	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
379	3	ps5slimdigital00092	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
380	3	ps5slimdigital00093	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
381	3	ps5slimdigital00094	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
382	3	ps5slimdigital00095	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
383	3	ps5slimdigital00096	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
384	3	ps5slimdigital00097	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
385	3	ps5slimdigital00098	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
386	3	ps5slimdigital00099	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
387	3	ps5slimdigital00100	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
388	3	ps5slimdigital00101	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
389	3	ps5slimdigital00102	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
390	3	ps5slimdigital00103	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
391	3	ps5slimdigital00104	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
392	3	ps5slimdigital00105	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
393	3	ps5slimdigital00106	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
394	3	ps5slimdigital00107	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
395	3	ps5slimdigital00108	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
396	3	ps5slimdigital00109	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
397	3	ps5slimdigital00110	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
398	3	ps5slimdigital00111	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
399	3	ps5slimdigital00112	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
400	3	ps5slimdigital00113	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
401	3	ps5slimdigital00114	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
402	3	ps5slimdigital00115	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
403	3	ps5slimdigital00116	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
404	3	ps5slimdigital00117	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
405	3	ps5slimdigital00118	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
406	3	ps5slimdigital00119	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
407	3	ps5slimdigital00120	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
408	3	ps5slimdigital00121	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
409	3	ps5slimdigital00122	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
410	3	ps5slimdigital00123	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
411	3	ps5slimdigital00124	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
412	3	ps5slimdigital00125	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
413	3	ps5slimdigital00126	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
414	3	ps5slimdigital00127	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
415	3	ps5slimdigital00128	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
416	3	ps5slimdigital00129	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
417	3	ps5slimdigital00130	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
418	3	ps5slimdigital00131	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
419	3	ps5slimdigital00132	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
420	3	ps5slimdigital00133	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
421	3	ps5slimdigital00134	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
422	3	ps5slimdigital00135	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
423	3	ps5slimdigital00136	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
424	3	ps5slimdigital00137	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
425	3	ps5slimdigital00138	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
426	3	ps5slimdigital00139	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
427	3	ps5slimdigital00140	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
428	3	ps5slimdigital00141	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
429	3	ps5slimdigital00142	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
430	3	ps5slimdigital00143	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
431	3	ps5slimdigital00144	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
432	3	ps5slimdigital00145	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
433	3	ps5slimdigital00146	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
434	3	ps5slimdigital00147	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
435	3	ps5slimdigital00148	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
436	3	ps5slimdigital00149	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
437	3	ps5slimdigital00150	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
438	3	ps5slimdigital00151	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
439	3	ps5slimdigital00152	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
440	3	ps5slimdigital00153	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
441	3	ps5slimdigital00154	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
442	3	ps5slimdigital00155	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
443	3	ps5slimdigital00156	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
444	3	ps5slimdigital00157	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
445	3	ps5slimdigital00158	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
446	3	ps5slimdigital00159	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
447	3	ps5slimdigital00160	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
448	3	ps5slimdigital00161	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
449	3	ps5slimdigital00162	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
450	3	ps5slimdigital00163	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
451	3	ps5slimdigital00164	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
452	3	ps5slimdigital00165	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
453	3	ps5slimdigital00166	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
454	3	ps5slimdigital00167	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
455	3	ps5slimdigital00168	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
456	3	ps5slimdigital00169	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
457	3	ps5slimdigital00170	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
458	3	ps5slimdigital00171	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
459	3	ps5slimdigital00172	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
460	3	ps5slimdigital00173	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
461	3	ps5slimdigital00174	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
462	3	ps5slimdigital00175	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
463	3	ps5slimdigital00176	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
464	3	ps5slimdigital00177	IN	PurchaseInvoice	5	2026-01-05 13:53:56.5131	1
465	4	dualsensewirelesscontroller00038	IN	PurchaseInvoice	6	2026-01-05 13:53:56.524773	1
466	5	psvr200001	IN	PurchaseInvoice	7	2026-01-05 13:53:56.52665	1
467	5	psvr200002	IN	PurchaseInvoice	7	2026-01-05 13:53:56.52665	1
468	5	psvr200003	IN	PurchaseInvoice	7	2026-01-05 13:53:56.52665	1
469	5	psvr200004	IN	PurchaseInvoice	7	2026-01-05 13:53:56.52665	1
470	6	1581F9DEC2592029S107	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
471	6	1581F9DEC258W02910YR	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
472	6	1581F9DEC258S029B1UX	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
473	6	1581F9DEC258W029589P	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
474	6	1581F9DEC258W0291QN2	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
475	6	1581F9DEC258H029J9SS	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
476	6	1581F9DEC25920299MLT	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
477	6	1581F9DEC259A029V3M1	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
478	6	1581F9DEC258U029X6E4	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
479	6	1581F9DEC2592029L653	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
480	6	1581F9DEC258S0294XWP	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
481	6	1581F9DEC258S0292B6T	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
482	6	1581F9DEC258W0293K3G	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
483	6	1581F9DEC258M0298CTZ	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
484	6	1581F9DEC258W029027D	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
485	6	1581F9DEC259202929ZB	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
486	6	1581F9DEC258U0294KUU	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
487	6	1581F9DEC25AL0291CTX	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
488	6	1581F9DEC25AQ0297HQU	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
489	6	1581F9DEC258W0291F67	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
490	6	1581F9DEC25AQ029SBVR	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
491	6	1581F9DEC25A90292N7Y	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
492	6	1581F9DEC25AK029B5VH	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
493	6	1581F9DEC25AL029R2T3	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
494	6	1581F9DEC25B3029PV6M	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
495	6	1581F9DEC25AL029CRJ2	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
496	6	1581F9DEC25AL0294V02	IN	PurchaseInvoice	8	2026-01-05 13:53:56.528898	1
497	7	1581F986C258U0023MZ5	IN	PurchaseInvoice	9	2026-01-05 13:53:56.532375	1
498	7	1581F986C257S0022VS4	IN	PurchaseInvoice	9	2026-01-05 13:53:56.532375	1
499	7	djimavic4ceratorcombo0001	IN	PurchaseInvoice	9	2026-01-05 13:53:56.532375	1
500	7	djimavic4ceratorcombo0002	IN	PurchaseInvoice	9	2026-01-05 13:53:56.532375	1
501	8	1581F8LQC255A0021ZQA	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
502	8	1581F8LQC253G0020HJ4	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
503	8	1581F8LQC252U00200ND	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
504	8	djimavic4proflymorecombo00001	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
505	8	djimavic4proflymorecombo00002	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
506	8	djimavic4proflymorecombo00003	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
507	8	djimavic4proflymorecombo00004	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
508	8	djimavic4proflymorecombo00005	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
509	8	djimavic4proflymorecombo00006	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
510	8	djimavic4proflymorecombo00007	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
511	8	djimavic4proflymorecombo00008	IN	PurchaseInvoice	10	2026-01-05 13:53:56.534565	1
512	9	1581F6Z9A248WML3S898	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
513	9	1581F6Z9A248WML3E8GD	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
514	9	1581F6Z9C2519003AY0G	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
515	9	1581F6Z9C2557003FNTS	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
516	9	1581F6Z9C2516003AMFM	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
517	9	1581F6Z9C2519003AYFZ	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
518	9	1581F6Z9C2557003FN58	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
519	9	1581F6Z9C2554003FALV	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
520	9	1581F6Z9A248WML30TXY	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
521	9	1581F6Z9C245N003TEC4	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
522	9	1581F6Z9A24CPML325EM	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
523	9	1581F6Z9C2517003AMZ4	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
524	9	1581F6Z9C2542003DDKL	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
525	9	1581F6Z9C2518003ASST	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
526	9	1581F6Z9A248WML3X76X	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
527	9	1581F6Z9C23AP003DC6C	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
528	9	1581F6Z9A24CRML3JZY0	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
529	9	1581F6Z9A24CRML3CZ3H	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
530	9	1581F6Z9A248WML359Z9	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
531	9	1581F6Z9A248WML3V5FG	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
532	9	1581F6Z9A248WML302VE	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
533	9	1581F6Z9A248WML33640	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
534	9	1581F6Z9A24CRML37S28	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
535	9	1581F6Z9A24CRML3TKW1	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
536	9	1581F6Z9A248WML3KK1E	IN	PurchaseInvoice	11	2026-01-05 13:53:56.536833	1
537	10	1581F6Z9C2489003YS6P	IN	PurchaseInvoice	12	2026-01-05 13:53:56.539589	1
538	10	1581F6Z9A24A1ML3ZC4G	IN	PurchaseInvoice	12	2026-01-05 13:53:56.539589	1
539	10	1581F6Z9A249DML38T1H	IN	PurchaseInvoice	12	2026-01-05 13:53:56.539589	1
540	11	1581F6Z9C254F003E8PX	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
541	11	1581F6Z9C251C003BCNG	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
542	11	1581F6Z9C2458003SP1X	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
543	11	1581F6Z9C251D003BKKT	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
544	11	1581F6Z9C253R003CSR1	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
545	11	1581F6Z9C251D003BN7E	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
546	11	1581F6Z9C251C003BAQ4	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
547	11	1581F6Z9C254D003E2UE	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
548	11	1581F6Z9C24AX0034Z36	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
549	11	1581F6Z9C254C003E003	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
550	11	1581F6Z9C2466003V1W2	IN	PurchaseInvoice	13	2026-01-05 13:53:56.541256	1
551	12	1581F8PJC253V001GYLW	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
552	12	1581F8PJC24B5001BCXM	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
553	12	1581F8PJC24BL0020SV0	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
554	12	1581F8PJC24CR0022N4Y	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
555	12	1581F8PJC24BN00210EG	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
556	12	1581F8PJC24BN00210P6	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
557	12	1581F8PJC24CS0022S3P	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
558	12	1581F8PJC24CR0022JYA	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
559	12	1581F8PJC24CR0022MDB	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
560	12	1581F8PJC24B6001BKLQ	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
561	12	1581F8PJC253V001H1V2	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
562	12	1581F8PJC24B6001BKXK	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
563	12	1581F8PJC24BF0020EU1	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
564	12	1581F8PJC24CR0022M1Z	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
565	12	1581F8PJC24CQ0022HSV	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
566	12	1581F8PJC24CR0022MKF	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
567	12	1581F8PJC24CQ0022HMQ	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
568	12	1581F8PJC24BL0020T9Q	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
569	12	1581F8PJC24CR0022LFH	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
570	12	1581F8PJC24AK0009PEJ	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
571	12	1581F8PJC253V001H1V5	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
572	12	1581F8PJC24CR0022JYK	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
573	12	1581F8PJC24BC00202KW	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
574	12	1581F8PJC24BN0020ZS4	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
575	12	1581F8PJC24BP00212CD	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
576	12	1581F8PJC24CR0022K1X	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
577	12	1581F8PJC24BP002137K	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
578	12	1581F8PJC24BL0020R72	IN	PurchaseInvoice	14	2026-01-05 13:53:56.54339	1
579	13	5WTCN7A002A1J8	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
580	13	5WTCN4S00223K2	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
581	13	5WTZN8R0024KFH	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
582	13	5WTZN7C002Y95X	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
583	13	5WTZN8F0021WDF	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
584	13	5WTCN7A002A365	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
585	13	5WTCN7A002A1A0	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
586	13	5WTCN7A002A66D	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
587	13	5WTCN7C002ABL0	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
588	13	5WTCN720028WVX	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
589	13	5WTCN780029AU8	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
590	13	5WTCN7A002A3B8	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
591	13	5WTCN7A002A756	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
592	13	5WTZN8K002D1RW	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
593	13	5WTCN7A002A2LJ	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
594	13	5WTCN780029GGB	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
595	13	5WTZN8J0026Y89	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
596	13	5WTZN8R0020E8T	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
597	13	5WTZN8P00292UP	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
598	13	5WTCN5K00214VP	IN	PurchaseInvoice	15	2026-01-05 13:53:56.546272	1
599	14	9SDXN6U0122PYP	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
600	14	9SDXN5G01215JY	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
601	14	8PBWN8L006A05Z	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
602	14	9SDXN570120QYN	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
603	14	9SDXN6D012292X	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
604	14	9SDXN7G0221TMP	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
605	14	9SDXN980233VD9	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
606	14	9SDXN6Q0122K0Z	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
607	14	9SDXN9N012613Q	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
608	14	9SDXN5K0220150	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
609	14	9SDXN570120SUR	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
610	14	9SDXN9N01261ER	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
611	14	9SDXN9N0126152	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
612	14	9SDXN6S02219C8	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
613	14	9SDXN6U0122PYR	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
614	14	9SDXN9N0126472	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
615	14	8PBWN8K0069TGQ	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
616	14	9SDXN5E01214SH	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
617	14	8PBWN8M006A8XU	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
618	14	9SDXN4F012075H	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
619	14	9SDXN8L0124RC5	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
620	14	9SDXN9N01261FN	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
621	14	9SDXNA70126HJ6	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
622	14	9SDXN7B0122ZUB	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
623	14	9SDXN7B0122ZFE	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
624	14	9SDXN7H0123A7B	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
625	14	9SDXN950125ESB	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
626	14	9SDXN980233VAF	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
627	14	9SDXN660220J7G	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
628	14	9SDXN5K02202MW	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
629	14	9SDXN980233W52	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
630	14	9SDXN9N01264RS	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
631	14	djimic300001	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
632	14	djimic300002	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
633	14	djimic300003	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
634	14	djimic300004	IN	PurchaseInvoice	16	2026-01-05 13:53:56.548613	1
635	15	8PBWN8M006A2T8	IN	PurchaseInvoice	17	2026-01-05 13:53:56.551841	1
636	15	8PBWN8K0069XLY	IN	PurchaseInvoice	17	2026-01-05 13:53:56.551841	1
637	15	8PBWN8M006A3WX	IN	PurchaseInvoice	17	2026-01-05 13:53:56.551841	1
638	15	8PBXN86016E575	IN	PurchaseInvoice	17	2026-01-05 13:53:56.551841	1
639	15	djimicmini00001	IN	PurchaseInvoice	17	2026-01-05 13:53:56.551841	1
640	15	djimicmini00002	IN	PurchaseInvoice	17	2026-01-05 13:53:56.551841	1
641	16	HAW10430234159	IN	PurchaseInvoice	18	2026-01-05 13:53:56.553628	1
642	16	HAW10588033796	IN	PurchaseInvoice	18	2026-01-05 13:53:56.553628	1
643	17	]C121105082000414	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
644	17	]C121105082000001	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
645	17	]C121105082000415	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
646	17	]C121105082000044	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
647	17	]C121105082000006	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
648	17	]C121105082000007	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
649	17	]C121105082000411	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
650	17	]C121105082000042	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
651	17	]C121105082000009	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
652	17	]C121105082000049	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
653	17	]C121105082000293	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
654	17	]C121105082000106	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
655	17	]C121105082000101	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
656	17	]C121105082000418	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
657	17	]C121105082000110	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
658	17	]C121105082000416	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
659	17	]C121105082000294	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
660	17	]C121105082000362	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
661	17	]C121105082000048	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
662	17	]C121105082000010	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
663	17	]C121105082000046	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
664	17	]C121095082000754	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
665	17	]C121105082001943	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
666	17	]C121105082001945	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
667	17	]C121095082002402	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
668	17	]C121085082000785	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
669	17	]C121095082001715	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
670	17	]C121095082002349	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
671	17	]C121095082001773	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
672	17	]C121095082001792	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
673	17	]C121085082000927	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
674	17	]C121085082000922	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
675	17	]C121105082001939	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
676	17	]C121105082001940	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
677	17	]C121105082001947	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
678	17	]C121105082001944	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
679	17	]C121105082001942	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
680	17	]C121115082000637	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
681	17	]C121115082000643	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
682	17	]C121115082000173	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
683	17	]C121115082000175	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
684	17	]C121115082000176	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
763	19	5SM00524	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
685	17	]C121115082000636	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
686	17	]C121105082001941	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
687	17	]C121105082001938	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
688	17	canong7xmarkiii00001	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
689	17	canong7xmarkiii00002	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
690	17	canong7xmarkiii00003	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
691	17	canong7xmarkiii00004	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
692	17	canong7xmarkiii00005	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
693	17	canong7xmarkiii00006	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
694	17	canong7xmarkiii00007	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
695	17	canong7xmarkiii00008	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
696	17	canong7xmarkiii00009	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
697	17	canong7xmarkiii00010	IN	PurchaseInvoice	19	2026-01-05 13:53:56.555277	1
698	18	]C121115081000721	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
699	18	]C121115081000722	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
700	18	]C121115081000720	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
701	18	]C121115081000723	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
702	18	]C121095081000253	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
703	18	canonsx740hs00001	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
704	18	canonsx740hs00002	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
705	18	canonsx740hs00003	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
706	18	canonsx740hs00004	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
707	18	canonsx740hs00005	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
708	18	canonsx740hs00006	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
709	18	canonsx740hs00007	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
710	18	canonsx740hs00008	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
711	18	canonsx740hs00009	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
712	18	canonsx740hs00010	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
713	18	canonsx740hs00011	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
714	18	canonsx740hs00012	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
715	18	canonsx740hs00013	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
716	18	canonsx740hs00014	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
717	18	canonsx740hs00015	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
718	18	canonsx740hs00016	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
719	18	canonsx740hs00017	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
720	18	canonsx740hs00018	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
721	18	canonsx740hs00019	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
722	18	canonsx740hs00020	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
723	18	canonsx740hs00021	IN	PurchaseInvoice	20	2026-01-05 13:53:56.559295	1
724	19	5TM38849	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
725	19	5TM38835	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
726	19	5TM38895	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
727	19	5TM38752	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
728	19	5TM38899	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
729	19	5TM38902	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
730	19	5TM38897	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
731	19	5TM38900	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
732	19	5TM38855	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
733	19	5TM38913	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
734	19	5TM38832	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
735	19	5TM38844	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
736	19	5SM00535	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
737	19	5TM38893	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
738	19	5TM38896	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
739	19	5TM38894	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
740	19	5SM27191	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
741	19	5SM27169	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
742	19	5TM38828	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
743	19	5TM38745	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
744	19	5SM27198	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
745	19	5SM27239	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
746	19	5TM38836	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
747	19	5TM38842	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
748	19	5SM27178	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
749	19	5TM38830	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
750	19	5TM38901	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
751	19	5TM38825	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
752	19	5TM38829	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
753	19	5TM38719	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
754	19	5SM27194	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
755	19	4WM54552	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
756	19	4WM13669	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
757	19	5TM38767	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
758	19	5TM38765	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
759	19	4WM54553	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
760	19	5TM38770	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
761	19	5SM27179	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
762	19	5TM38948	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
764	19	5TM38904	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
765	19	5TM38763	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
766	19	5SM00529	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
767	19	5TM38872	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
768	19	5TM38827	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
769	19	5TM38943	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
770	19	5TM38860	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
771	19	5TM38944	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
772	19	5TM38841	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
773	19	5TM38826	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
774	19	5UN60111	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
775	19	5UN60112	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
776	19	5UN60113	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
777	19	5UN60114	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
778	19	5UN60115	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
779	19	5UN60116	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
780	19	5UN60117	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
781	19	5UN60118	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
782	19	5UN60119	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
783	19	5UN60120	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
784	19	5UN60201	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
785	19	5UN60202	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
786	19	5UN60203	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
787	19	5UN60204	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
788	19	5UN60205	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
789	19	5UN60206	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
790	19	5UN60207	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
791	19	5UN60208	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
792	19	5UN60209	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
793	19	5UN60210	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
794	19	5UN60101	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
795	19	5UN60102	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
796	19	5UN60103	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
797	19	5UN60104	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
798	19	5UN60105	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
799	19	5UN60106	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
800	19	5UN60107	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
801	19	5UN60108	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
802	19	5UN60109	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
803	19	5UN60110	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
804	19	5UN60131	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
805	19	5UN60132	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
806	19	5UN60133	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
807	19	5UN60134	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
808	19	5UN60135	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
809	19	5UN60136	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
810	19	5UN60137	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
811	19	5UN60138	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
812	19	5UN60139	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
813	19	5UN60140	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
814	19	5UN60561	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
815	19	5UN60562	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
816	19	5UN60563	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
817	19	5UN60564	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
818	19	5UN60565	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
819	19	5UN60566	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
820	19	5UN60567	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
821	19	5UN60568	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
822	19	5UN60569	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
823	19	5UN60570	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
824	19	5UN60171	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
825	19	5UN60172	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
826	19	5UN60173	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
827	19	5UN60174	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
828	19	5UN60175	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
829	19	5UN60176	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
830	19	5UN60177	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
831	19	5UN60178	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
832	19	5UN60179	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
833	19	5UN60180	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
834	19	5UN37211	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
835	19	5UN37212	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
836	19	5UN37213	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
837	19	5UN37214	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
838	19	5UN37215	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
839	19	5UN37216	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
840	19	5UN37217	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
841	19	5UN37218	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
842	19	5UN37219	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
843	19	5UN37220	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
844	19	5UN60181	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
845	19	5UN60182	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
846	19	5UN60183	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
847	19	5UN60184	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
848	19	5UN60185	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
849	19	5UN60186	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
850	19	5UN60187	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
851	19	5UN60188	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
852	19	5UN60189	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
853	19	5UN60190	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
854	19	5UN60551	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
855	19	5UN60552	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
856	19	5UN60553	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
857	19	5UN60554	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
858	19	5UN60555	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
859	19	5UN60556	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
860	19	5UN60557	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
861	19	5UN60558	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
862	19	5UN60559	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
863	19	5UN60560	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
864	19	5UN60121	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
865	19	5UN60122	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
866	19	5UN60123	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
867	19	5UN60124	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
868	19	5UN60125	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
869	19	5UN60126	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
870	19	5UN60127	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
871	19	5UN60128	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
872	19	5UN60129	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
873	19	5UN60130	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
874	19	5UN37221	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
875	19	5UN37222	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
876	19	5UN37223	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
877	19	5UN37224	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
878	19	5UN37225	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
879	19	5UN37226	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
880	19	5UN37227	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
881	19	5UN37228	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
882	19	5UN37229	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
883	19	5UN37230	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
884	19	5UN42171	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
885	19	5UN42172	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
886	19	5UN42173	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
887	19	5UN42174	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
888	19	5UN42175	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
889	19	5UN42176	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
890	19	5UN42177	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
891	19	5UN42178	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
892	19	5UN42179	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
893	19	5UN42180	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
894	19	5UN60541	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
895	19	5UN60542	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
896	19	5UN60543	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
897	19	5UN60544	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
898	19	5UN60545	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
899	19	5UN60546	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
900	19	5UN60547	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
901	19	5UN60548	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
902	19	5UN60549	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
903	19	5UN60550	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
904	19	5UN60191	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
905	19	5UN60192	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
906	19	5UN60193	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
907	19	5UN60194	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
908	19	5UN60195	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
909	19	5UN60196	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
910	19	5UN60197	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
911	19	5UN60198	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
912	19	5UN60199	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
913	19	5UN60200	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
914	19	5UN60571	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
915	19	5UN60572	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
916	19	5UN60573	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
917	19	5UN60574	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
918	19	5UN60575	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
919	19	5UN60576	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
920	19	5UN60577	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
921	19	5UN60578	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
922	19	5UN60579	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
923	19	5UN60580	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
924	19	5UN37241	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
925	19	5UN37242	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
926	19	5UN37243	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
927	19	5UN37244	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
928	19	5UN37245	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
929	19	5UN37246	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
930	19	5UN37247	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
931	19	5UN37248	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
932	19	5UN37249	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
933	19	5UN37250	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
934	19	5UN42211	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
935	19	5UN42212	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
936	19	5UN42213	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
937	19	5UN42214	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
938	19	5UN42215	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
939	19	5UN42216	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
940	19	5UN42217	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
941	19	5UN42218	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
942	19	5UN42219	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
943	19	5UN42220	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
944	19	5UN42241	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
945	19	5UN42242	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
946	19	5UN42243	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
947	19	5UN42244	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
948	19	5UN42245	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
949	19	5UN42246	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
950	19	5UN42247	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
951	19	5UN42248	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
952	19	5UN42249	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
953	19	5UN42250	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
954	19	5UN60141	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
955	19	5UN60142	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
956	19	5UN60143	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
957	19	5UN60144	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
958	19	5UN60145	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
959	19	5UN60146	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
960	19	5UN60147	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
961	19	5UN60148	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
962	19	5UN60149	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
963	19	5UN60150	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
964	19	5UN42231	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
965	19	5UN42232	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
966	19	5UN42233	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
967	19	5UN42234	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
968	19	5UN42235	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
969	19	5UN42236	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
970	19	5UN42237	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
971	19	5UN42238	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
972	19	5UN42239	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
973	19	5UN42240	IN	PurchaseInvoice	21	2026-01-05 13:53:56.561992	1
974	20	instaxfilm20pack00001	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
975	20	instaxfilm20pack00002	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
976	20	instaxfilm20pack00003	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
977	20	instaxfilm20pack00004	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
978	20	instaxfilm20pack00005	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
979	20	instaxfilm20pack00006	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
980	20	instaxfilm20pack00007	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
981	20	instaxfilm20pack00008	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
982	20	instaxfilm20pack00009	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
983	20	instaxfilm20pack00010	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
984	20	instaxfilm20pack00011	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
985	20	instaxfilm20pack00012	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
986	20	instaxfilm20pack00013	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
987	20	instaxfilm20pack00014	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
988	20	instaxfilm20pack00015	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
989	20	instaxfilm20pack00016	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
990	20	instaxfilm20pack00017	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
991	20	instaxfilm20pack00018	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
992	20	instaxfilm20pack00019	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
993	20	instaxfilm20pack00020	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
994	20	instaxfilm20pack00021	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
995	20	instaxfilm20pack00022	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
996	20	instaxfilm20pack00023	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
997	20	instaxfilm20pack00024	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
998	20	instaxfilm20pack00025	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
999	20	instaxfilm20pack00026	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1000	20	instaxfilm20pack00027	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1001	20	instaxfilm20pack00028	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1002	20	instaxfilm20pack00029	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1003	20	instaxfilm20pack00030	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1004	20	instaxfilm20pack00031	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1005	20	instaxfilm20pack00032	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1006	20	instaxfilm20pack00033	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1007	20	instaxfilm20pack00034	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1008	20	instaxfilm20pack00035	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1009	20	instaxfilm20pack00036	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1010	20	instaxfilm20pack00037	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1011	20	instaxfilm20pack00038	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1012	20	instaxfilm20pack00039	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1013	20	instaxfilm20pack00040	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1014	20	instaxfilm20pack00041	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1015	20	instaxfilm20pack00042	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1016	20	instaxfilm20pack00043	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1017	20	instaxfilm20pack00044	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1018	20	instaxfilm20pack00045	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1019	20	instaxfilm20pack00046	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1020	20	instaxfilm20pack00047	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1021	20	instaxfilm20pack00048	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1022	20	instaxfilm20pack00049	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1023	20	instaxfilm20pack00050	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1024	20	instaxfilm20pack00051	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1025	20	instaxfilm20pack00052	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1026	20	instaxfilm20pack00053	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1027	20	instaxfilm20pack00054	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1028	20	instaxfilm20pack00055	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1029	20	instaxfilm20pack00056	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1030	20	instaxfilm20pack00057	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1031	20	instaxfilm20pack00058	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1032	20	instaxfilm20pack00059	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1033	20	instaxfilm20pack00060	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1034	20	instaxfilm20pack00061	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1035	20	instaxfilm20pack00062	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1036	20	instaxfilm20pack00063	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1037	20	instaxfilm20pack00064	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1038	20	instaxfilm20pack00065	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1039	20	instaxfilm20pack00066	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1040	20	instaxfilm20pack00067	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1041	20	instaxfilm20pack00068	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1042	20	instaxfilm20pack00069	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1043	20	instaxfilm20pack00070	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1044	20	instaxfilm20pack00071	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1045	20	instaxfilm20pack00072	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1046	20	instaxfilm20pack00073	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1047	20	instaxfilm20pack00074	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1048	20	instaxfilm20pack00075	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1049	20	instaxfilm20pack00076	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1050	20	instaxfilm20pack00077	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1051	20	instaxfilm20pack00078	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1052	20	instaxfilm20pack00079	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1053	20	instaxfilm20pack00080	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1054	20	instaxfilm20pack00081	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1055	20	instaxfilm20pack00082	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1056	20	instaxfilm20pack00083	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1057	20	instaxfilm20pack00084	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1058	20	instaxfilm20pack00085	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1059	20	instaxfilm20pack00086	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1060	20	instaxfilm20pack00087	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1061	20	instaxfilm20pack00088	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1062	20	instaxfilm20pack00089	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1063	20	instaxfilm20pack00090	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1064	20	instaxfilm20pack00091	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1065	20	instaxfilm20pack00092	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1066	20	instaxfilm20pack00093	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1067	20	instaxfilm20pack00094	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1068	20	instaxfilm20pack00095	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1069	20	instaxfilm20pack00096	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1070	20	instaxfilm20pack00097	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1071	20	instaxfilm20pack00098	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1072	20	instaxfilm20pack00099	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1073	20	instaxfilm20pack00100	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1074	20	instaxfilm20pack00101	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1075	20	instaxfilm20pack00102	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1076	20	instaxfilm20pack00103	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1077	20	instaxfilm20pack00104	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1078	20	instaxfilm20pack00105	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1079	20	instaxfilm20pack00106	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1080	20	instaxfilm20pack00107	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1081	20	instaxfilm20pack00108	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1082	20	instaxfilm20pack00109	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1083	20	instaxfilm20pack00110	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1084	20	instaxfilm20pack00111	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1085	20	instaxfilm20pack00112	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1086	20	instaxfilm20pack00113	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1087	20	instaxfilm20pack00114	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1088	20	instaxfilm20pack00115	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1089	20	instaxfilm20pack00116	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1090	20	instaxfilm20pack00117	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1091	20	instaxfilm20pack00118	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1092	20	instaxfilm20pack00119	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1093	20	instaxfilm20pack00120	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1094	20	instaxfilm20pack00121	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1095	20	instaxfilm20pack00122	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1096	20	instaxfilm20pack00123	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1097	20	instaxfilm20pack001124	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1098	20	instaxfilm20pack00125	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1099	20	instaxfilm20pack00126	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1100	20	instaxfilm20pack00127	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1101	20	instaxfilm20pack00128	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1102	20	instaxfilm20pack00129	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1103	20	instaxfilm20pack00130	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1104	20	instaxfilm20pack00131	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1105	20	instaxfilm20pack00132	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1106	20	instaxfilm20pack00133	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1107	20	instaxfilm20pack00134	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1108	20	instaxfilm20pack00135	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1109	20	instaxfilm20pack00136	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1110	20	instaxfilm20pack00137	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1111	20	instaxfilm20pack00138	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1112	20	instaxfilm20pack00139	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1113	20	instaxfilm20pack00140	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1114	20	instaxfilm20pack00141	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1115	20	instaxfilm20pack00142	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1116	20	instaxfilm20pack00143	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1117	20	instaxfilm20pack00144	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1118	20	instaxfilm20pack00145	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1119	20	instaxfilm20pack00146	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1120	20	instaxfilm20pack00147	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1121	20	instaxfilm20pack00148	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1122	20	instaxfilm20pack00149	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1123	20	instaxfilm20pack00150	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1124	20	instaxfilm20pack00151	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1125	20	instaxfilm20pack00152	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1126	20	instaxfilm20pack00153	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1127	20	instaxfilm20pack00154	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1128	20	instaxfilm20pack00155	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1129	20	instaxfilm20pack00156	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1130	20	instaxfilm20pack00157	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1131	20	instaxfilm20pack00158	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1132	20	instaxfilm20pack00159	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1133	20	instaxfilm20pack00160	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1134	20	instaxfilm20pack00161	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1135	20	instaxfilm20pack00162	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1136	20	instaxfilm20pack00163	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1137	20	instaxfilm20pack00164	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1138	20	instaxfilm20pack00165	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1139	20	instaxfilm20pack00166	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1140	20	instaxfilm20pack00167	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1141	20	instaxfilm20pack00168	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1142	20	instaxfilm20pack00169	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1143	20	instaxfilm20pack00170	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1144	20	instaxfilm20pack00171	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1145	20	instaxfilm20pack00172	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1146	20	instaxfilm20pack00173	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1147	20	instaxfilm20pack00174	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1148	20	instaxfilm20pack001175	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1149	20	instaxfilm20pack00176	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1150	20	instaxfilm20pack00177	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1151	20	instaxfilm20pack00178	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1152	20	instaxfilm20pack00179	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1153	20	instaxfilm20pack00180	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1154	20	instaxfilm20pack00181	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1155	20	instaxfilm20pack00182	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1156	20	instaxfilm20pack00183	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1157	20	instaxfilm20pack00184	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1158	20	instaxfilm20pack00185	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1159	20	instaxfilm20pack001186	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1160	20	instaxfilm20pack00187	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1161	20	instaxfilm20pack00188	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1162	20	instaxfilm20pack00189	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1163	20	instaxfilm20pack00190	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1164	20	instaxfilm20pack00191	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1165	20	instaxfilm20pack00192	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1166	20	instaxfilm20pack00193	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1167	20	instaxfilm20pack00194	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1168	20	instaxfilm20pack00195	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1169	20	instaxfilm20pack00196	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1170	20	instaxfilm20pack00197	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1171	20	instaxfilm20pack00198	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1172	20	instaxfilm20pack00199	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1173	20	instaxfilm20pack00200	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1174	20	instaxfilm20pack00201	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1175	20	instaxfilm20pack00202	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1176	20	instaxfilm20pack00203	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1177	20	instaxfilm20pack00204	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1178	20	instaxfilm20pack00205	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1179	20	instaxfilm20pack00206	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1180	20	instaxfilm20pack00207	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1181	20	instaxfilm20pack00208	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1182	20	instaxfilm20pack00209	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1183	20	instaxfilm20pack00210	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1184	20	instaxfilm20pack00211	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1185	20	instaxfilm20pack00212	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1186	20	instaxfilm20pack00213	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1187	20	instaxfilm20pack00214	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1188	20	instaxfilm20pack00215	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1189	20	instaxfilm20pack00216	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1190	20	instaxfilm20pack00217	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1191	20	instaxfilm20pack00218	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1192	20	instaxfilm20pack00219	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1193	20	instaxfilm20pack00220	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1194	20	instaxfilm20pack00221	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1195	20	instaxfilm20pack00222	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1196	20	instaxfilm20pack00223	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1197	20	instaxfilm20pack00224	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1198	20	instaxfilm20pack00225	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1199	20	instaxfilm20pack00226	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1200	20	instaxfilm20pack00227	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1201	20	instaxfilm20pack00228	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1202	20	instaxfilm20pack00229	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1203	20	instaxfilm20pack00230	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1204	20	instaxfilm20pack00231	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1205	20	instaxfilm20pack00232	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1206	20	instaxfilm20pack00233	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1207	20	instaxfilm20pack00234	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1208	20	instaxfilm20pack00235	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1209	20	instaxfilm20pack00236	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1210	20	instaxfilm20pack00237	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1211	20	instaxfilm20pack00238	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1212	20	instaxfilm20pack00239	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1213	20	instaxfilm20pack00240	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1214	20	instaxfilm20pack00241	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1215	20	instaxfilm20pack00242	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1216	20	instaxfilm20pack00243	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1217	20	instaxfilm20pack00244	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1218	20	instaxfilm20pack00245	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1219	20	instaxfilm20pack00246	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1220	20	instaxfilm20pack00247	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1221	20	instaxfilm20pack00248	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1222	20	instaxfilm20pack00249	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1223	20	instaxfilm20pack00250	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1224	20	instaxfilm20pack00251	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1225	20	instaxfilm20pack00252	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1226	20	instaxfilm20pack00253	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1227	20	instaxfilm20pack00254	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1228	20	instaxfilm20pack00255	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1229	20	instaxfilm20pack00256	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1230	20	instaxfilm20pack00257	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1231	20	instaxfilm20pack00258	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1232	20	instaxfilm20pack00259	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1233	20	instaxfilm20pack00260	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1234	20	instaxfilm20pack00261	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1235	20	instaxfilm20pack00262	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1236	20	instaxfilm20pack00263	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1237	20	instaxfilm20pack00264	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1238	20	instaxfilm20pack00265	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1239	20	instaxfilm20pack00266	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1240	20	instaxfilm20pack00267	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1241	20	instaxfilm20pack00268	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1242	20	instaxfilm20pack00269	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1243	20	instaxfilm20pack00270	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1244	20	instaxfilm20pack00271	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1245	20	instaxfilm20pack00272	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1246	20	instaxfilm20pack00273	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1247	20	instaxfilm20pack00274	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1248	20	instaxfilm20pack00275	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1249	20	instaxfilm20pack00276	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1250	20	instaxfilm20pack00277	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1251	20	instaxfilm20pack00278	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1252	20	instaxfilm20pack00279	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1253	20	instaxfilm20pack00280	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1254	20	instaxfilm20pack00281	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1255	20	instaxfilm20pack00282	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1256	20	instaxfilm20pack00283	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1257	20	instaxfilm20pack00284	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1258	20	instaxfilm20pack00285	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1259	20	instaxfilm20pack00286	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1260	20	instaxfilm20pack00287	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1261	20	instaxfilm20pack00288	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1262	20	instaxfilm20pack00289	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1263	20	instaxfilm20pack00290	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1264	20	instaxfilm20pack00291	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1265	20	instaxfilm20pack00292	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1266	20	instaxfilm20pack00293	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1267	20	instaxfilm20pack00294	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1268	20	instaxfilm20pack00295	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1269	20	instaxfilm20pack00296	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1270	20	instaxfilm20pack00297	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1271	20	instaxfilm20pack00298	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1272	20	instaxfilm20pack00299	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1273	20	instaxfilm20pack00300	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1274	20	instaxfilm20pack00301	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1275	20	instaxfilm20pack00302	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1276	20	instaxfilm20pack00303	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1277	20	instaxfilm20pack00304	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1278	20	instaxfilm20pack00305	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1279	20	instaxfilm20pack00306	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1280	20	instaxfilm20pack00307	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1281	20	instaxfilm20pack00308	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1282	20	instaxfilm20pack00309	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1283	20	instaxfilm20pack00310	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1284	20	instaxfilm20pack00311	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1285	20	instaxfilm20pack00312	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1286	20	instaxfilm20pack00313	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1287	20	instaxfilm20pack00314	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1288	20	instaxfilm20pack00315	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1289	20	instaxfilm20pack00316	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1290	20	instaxfilm20pack00317	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1291	20	instaxfilm20pack00318	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1292	20	instaxfilm20pack00319	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1293	20	instaxfilm20pack00320	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1294	20	instaxfilm20pack00321	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1295	20	instaxfilm20pack00322	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1296	20	instaxfilm20pack00323	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1297	20	instaxfilm20pack00324	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1298	20	instaxfilm20pack00325	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1299	20	instaxfilm20pack00326	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1300	20	instaxfilm20pack00327	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1301	20	instaxfilm20pack00328	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1302	20	instaxfilm20pack00329	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1303	20	instaxfilm20pack00330	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1304	20	instaxfilm20pack00331	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1305	20	instaxfilm20pack00332	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1306	20	instaxfilm20pack00333	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1307	20	instaxfilm20pack00334	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1308	20	instaxfilm20pack00335	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1309	20	instaxfilm20pack00336	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1310	20	instaxfilm20pack00337	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1311	20	instaxfilm20pack00338	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1312	20	instaxfilm20pack00339	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1313	20	instaxfilm20pack00340	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1314	20	instaxfilm20pack00341	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1315	20	instaxfilm20pack00342	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1316	20	instaxfilm20pack00343	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1317	20	instaxfilm20pack00344	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1318	20	instaxfilm20pack00345	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1319	20	instaxfilm20pack00346	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1320	20	instaxfilm20pack00347	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1321	20	instaxfilm20pack00348	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1322	20	instaxfilm20pack00349	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1323	20	instaxfilm20pack00350	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1324	20	instaxfilm20pack00351	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1325	20	instaxfilm20pack00352	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1326	20	instaxfilm20pack00353	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1327	20	instaxfilm20pack00354	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1328	20	instaxfilm20pack00355	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1329	20	instaxfilm20pack00356	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1330	20	instaxfilm20pack00357	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1331	20	instaxfilm20pack00358	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1332	20	instaxfilm20pack00359	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1333	20	instaxfilm20pack00360	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1334	20	instaxfilm20pack00361	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1335	20	instaxfilm20pack00362	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1336	20	instaxfilm20pack00363	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1337	20	instaxfilm20pack00364	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1338	20	instaxfilm20pack00365	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1339	20	instaxfilm20pack00366	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1340	20	instaxfilm20pack00367	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1341	20	instaxfilm20pack00368	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1342	20	instaxfilm20pack00369	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1343	20	instaxfilm20pack00370	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1344	20	instaxfilm20pack00371	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1345	20	instaxfilm20pack00372	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1346	20	instaxfilm20pack00373	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1347	20	instaxfilm20pack00374	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1348	20	instaxfilm20pack00375	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1349	20	instaxfilm20pack00376	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1350	20	instaxfilm20pack00377	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1351	20	instaxfilm20pack00378	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1352	20	instaxfilm20pack00379	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1353	20	instaxfilm20pack00380	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1354	20	instaxfilm20pack00381	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1355	20	instaxfilm20pack00382	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1356	20	instaxfilm20pack00383	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1357	20	instaxfilm20pack00384	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1358	20	instaxfilm20pack00385	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1359	20	instaxfilm20pack00386	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1360	20	instaxfilm20pack00387	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1361	20	instaxfilm20pack00388	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1362	20	instaxfilm20pack00389	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1363	20	instaxfilm20pack00390	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1364	20	instaxfilm20pack00391	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1365	20	instaxfilm20pack00392	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1366	20	instaxfilm20pack00393	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1367	20	instaxfilm20pack00394	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1368	20	instaxfilm20pack00395	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1369	20	instaxfilm20pack00396	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1370	20	instaxfilm20pack00397	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1371	20	instaxfilm20pack00398	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1372	20	instaxfilm20pack00399	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1373	20	instaxfilm20pack00400	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1374	20	instaxfilm20pack00401	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1375	20	instaxfilm20pack00402	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1376	20	instaxfilm20pack00403	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1377	20	instaxfilm20pack00404	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1378	20	instaxfilm20pack00405	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1379	20	instaxfilm20pack00406	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1380	20	instaxfilm20pack00407	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1381	20	instaxfilm20pack00408	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1382	20	instaxfilm20pack00409	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1383	20	instaxfilm20pack00410	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1384	20	instaxfilm20pack00411	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1385	20	instaxfilm20pack00412	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1386	20	instaxfilm20pack00413	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1387	20	instaxfilm20pack00414	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1388	20	instaxfilm20pack00415	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1389	20	instaxfilm20pack00416	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1390	20	instaxfilm20pack00417	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1391	20	instaxfilm20pack00418	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1392	20	instaxfilm20pack00419	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1393	20	instaxfilm20pack00420	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1394	20	instaxfilm20pack00421	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1395	20	instaxfilm20pack00422	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1396	20	instaxfilm20pack00423	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1397	20	instaxfilm20pack00424	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1398	20	instaxfilm20pack00425	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1399	20	instaxfilm20pack00426	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1400	20	instaxfilm20pack00427	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1401	20	instaxfilm20pack00428	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1402	20	instaxfilm20pack00429	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1403	20	instaxfilm20pack00430	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1404	20	instaxfilm20pack00431	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1405	20	instaxfilm20pack00432	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1406	20	instaxfilm20pack00433	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1407	20	instaxfilm20pack00434	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1408	20	instaxfilm20pack00435	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1409	20	instaxfilm20pack00436	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1410	20	instaxfilm20pack00437	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1411	20	instaxfilm20pack00438	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1412	20	instaxfilm20pack00439	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1413	20	instaxfilm20pack00440	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1414	20	instaxfilm20pack00441	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1415	20	instaxfilm20pack00442	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1416	20	instaxfilm20pack00443	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1417	20	instaxfilm20pack00444	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1418	20	instaxfilm20pack00445	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1419	20	instaxfilm20pack00446	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1420	20	instaxfilm20pack00447	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1421	20	instaxfilm20pack00448	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1422	20	instaxfilm20pack00449	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1423	20	instaxfilm20pack00450	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1424	20	instaxfilm20pack00451	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1425	20	instaxfilm20pack00452	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1426	20	instaxfilm20pack00453	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1427	20	instaxfilm20pack00454	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1428	20	instaxfilm20pack00455	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1429	20	instaxfilm20pack00456	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1430	20	instaxfilm20pack00457	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1431	20	instaxfilm20pack00458	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1432	20	instaxfilm20pack00459	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1433	20	instaxfilm20pack00460	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1434	20	instaxfilm20pack00461	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1435	20	instaxfilm20pack00462	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1436	20	instaxfilm20pack00463	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1437	20	instaxfilm20pack00464	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1438	20	instaxfilm20pack00465	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1439	20	instaxfilm20pack00466	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1440	20	instaxfilm20pack00467	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1441	20	instaxfilm20pack00468	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1442	20	instaxfilm20pack00469	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1443	20	instaxfilm20pack00470	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1444	20	instaxfilm20pack00471	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1445	20	instaxfilm20pack00472	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1446	20	instaxfilm20pack00473	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1447	20	instaxfilm20pack00474	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1448	20	instaxfilm20pack00475	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1449	20	instaxfilm20pack00476	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1450	20	instaxfilm20pack00477	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1451	20	instaxfilm20pack00478	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1452	20	instaxfilm20pack00479	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1453	20	instaxfilm20pack00480	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1454	20	instaxfilm20pack00481	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1455	20	instaxfilm20pack00482	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1456	20	instaxfilm20pack00483	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1457	20	instaxfilm20pack00484	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1458	20	instaxfilm20pack00485	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1459	20	instaxfilm20pack00486	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1460	20	instaxfilm20pack00487	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1461	20	instaxfilm20pack00488	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1462	20	instaxfilm20pack00489	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1463	20	instaxfilm20pack00490	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1464	20	instaxfilm20pack00491	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1465	20	instaxfilm20pack00492	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1466	20	instaxfilm20pack00493	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1467	20	instaxfilm20pack00494	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1468	20	instaxfilm20pack00495	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1469	20	instaxfilm20pack00496	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1470	20	instaxfilm20pack00497	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1471	20	instaxfilm20pack00498	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1472	20	instaxfilm20pack00499	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1473	20	instaxfilm20pack00500	IN	PurchaseInvoice	22	2026-01-05 13:53:56.574504	1
1474	21	ninjaslushi0001	IN	PurchaseInvoice	23	2026-01-05 13:53:56.597339	1
1475	21	ninjaslushi0002	IN	PurchaseInvoice	23	2026-01-05 13:53:56.597339	1
1476	21	ninjaslushi0003	IN	PurchaseInvoice	23	2026-01-05 13:53:56.597339	1
1477	21	ninjaslushi0004	IN	PurchaseInvoice	23	2026-01-05 13:53:56.597339	1
1478	21	ninjaslushi0005	IN	PurchaseInvoice	23	2026-01-05 13:53:56.597339	1
1479	21	ninjaslushi0006	IN	PurchaseInvoice	23	2026-01-05 13:53:56.597339	1
1480	21	ninjaslushi0007	IN	PurchaseInvoice	23	2026-01-05 13:53:56.597339	1
1481	22	ninjacreami0001	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1482	22	ninjacreami0002	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1483	22	ninjacreami0003	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1484	22	ninjacreami0004	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1485	22	ninjacreami0005	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1486	22	ninjacreami0006	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1487	22	ninjacreami0007	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1488	22	ninjacreami0008	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1489	22	ninjacreami0009	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1490	22	ninjacreami0010	IN	PurchaseInvoice	24	2026-01-05 13:53:56.598983	1
1491	23	ninjaportableblender0001	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1492	23	ninjaportableblender0002	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1493	23	ninjaportableblender0003	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1494	23	ninjaportableblender0004	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1495	23	ninjaportableblender0005	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1496	23	ninjaportableblender0006	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1497	23	ninjaportableblender0007	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1498	23	ninjaportableblender0008	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1499	23	ninjaportableblender0009	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1500	23	ninjaportableblender0010	IN	PurchaseInvoice	25	2026-01-05 13:53:56.601231	1
1501	24	starlinkhp00001	IN	PurchaseInvoice	26	2026-01-05 13:53:56.603542	1
1502	24	starlinkhp00002	IN	PurchaseInvoice	26	2026-01-05 13:53:56.603542	1
1503	1	starlinkv40001	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1504	1	starlinkv40002	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1505	1	starlinkv40003	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1506	1	starlinkv40004	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1507	1	starlinkv40005	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1508	1	starlinkv40006	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1509	1	starlinkv40007	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1510	1	starlinkv40008	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1511	1	starlinkv40009	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1512	1	starlinkv40010	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1513	1	starlinkv40011	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1514	1	starlinkv40012	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1515	1	starlinkv40013	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1516	1	starlinkv40014	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1517	1	starlinkv40015	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1518	1	starlinkv40016	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1519	1	starlinkv40017	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1520	1	starlinkv40018	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1521	1	starlinkv40019	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1522	1	starlinkv40020	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1523	1	starlinkv40021	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1524	1	starlinkv40022	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1525	1	starlinkv40023	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1526	1	starlinkv40024	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1527	1	starlinkv40025	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1528	1	starlinkv40026	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1529	1	starlinkv40027	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1530	1	starlinkv40028	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1531	1	starlinkv40029	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1532	1	starlinkv40030	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1533	1	starlinkv40031	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1534	1	starlinkv40032	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1535	1	starlinkv40033	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1536	1	starlinkv40034	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1537	1	starlinkv40035	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1538	1	starlinkv40036	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1539	1	starlinkv40037	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1540	1	starlinkv40038	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1541	1	starlinkv40039	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1542	1	starlinkv40040	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1543	1	starlinkv40041	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1544	1	starlinkv40042	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1545	1	starlinkv40043	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1546	1	starlinkv40044	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1547	1	starlinkv40045	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1548	1	starlinkv40046	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1549	1	starlinkv40047	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1550	1	starlinkv40048	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1551	1	starlinkv40049	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1552	1	starlinkv40050	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1553	1	starlinkv40051	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1554	1	starlinkv40052	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1555	1	starlinkv40053	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1556	1	starlinkv40054	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1557	1	starlinkv40055	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1558	1	starlinkv40056	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1559	1	starlinkv40057	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1560	1	starlinkv40058	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1561	1	starlinkv40059	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1562	1	starlinkv40060	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1563	1	starlinkv40061	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1564	1	starlinkv40062	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1565	1	starlinkv40063	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1566	1	starlinkv40064	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1567	1	starlinkv40065	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1568	1	starlinkv40066	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1569	1	starlinkv40067	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1570	1	starlinkv40068	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1571	1	starlinkv40069	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1572	1	starlinkv40070	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1573	1	starlinkv40071	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1574	1	starlinkv40072	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1575	1	starlinkv40073	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1576	1	starlinkv40074	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1577	1	starlinkv40075	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1578	1	starlinkv40076	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1579	1	starlinkv40077	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1580	1	starlinkv40078	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1581	1	starlinkv40079	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1582	1	starlinkv40080	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1583	1	starlinkv40081	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1584	1	starlinkv40082	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1585	1	starlinkv40083	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1586	1	starlinkv40084	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1587	1	starlinkv40085	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1588	1	starlinkv40086	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1589	1	starlinkv40087	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1590	1	starlinkv40088	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1591	1	starlinkv40089	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1592	1	starlinkv40090	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1593	1	starlinkv40091	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1594	1	starlinkv40092	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1595	1	starlinkv40093	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1596	1	starlinkv40094	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1597	1	starlinkv40095	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1598	1	starlinkv40096	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1599	1	starlinkv40097	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1600	1	starlinkv40098	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1601	1	starlinkv40099	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1602	1	starlinkv40100	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1603	1	starlinkv40101	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1604	1	starlinkv40102	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1605	1	starlinkv40103	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1606	1	starlinkv40104	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1607	1	starlinkv40105	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1608	1	starlinkv40106	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1609	1	starlinkv40107	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1610	1	starlinkv40108	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1611	1	starlinkv40109	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1612	1	starlinkv40110	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1613	1	starlinkv40111	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1614	1	starlinkv40112	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1615	1	starlinkv40113	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1616	1	starlinkv40114	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1617	1	starlinkv40115	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1618	1	starlinkv40116	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1619	1	starlinkv40117	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1620	1	starlinkv40118	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1621	1	starlinkv40119	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1622	1	starlinkv40120	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1623	1	starlinkv40121	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1624	1	starlinkv40122	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1625	1	starlinkv40123	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1626	1	starlinkv40124	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1627	1	starlinkv40125	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1628	1	starlinkv40126	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1629	1	starlinkv40127	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1630	1	starlinkv40128	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1631	1	starlinkv40129	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1632	1	starlinkv40130	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1633	1	starlinkv40131	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1634	1	starlinkv40132	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1635	1	starlinkv40133	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1636	1	starlinkv40134	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1637	1	starlinkv40135	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1638	1	starlinkv40136	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1639	1	starlinkv40137	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1640	1	starlinkv40138	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1641	1	starlinkv40139	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1642	1	starlinkv40140	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1643	1	starlinkv40141	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1644	1	starlinkv40142	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1645	1	starlinkv40143	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1646	1	starlinkv40144	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1647	1	starlinkv40145	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1648	1	starlinkv40146	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1649	1	starlinkv40147	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1650	1	starlinkv40148	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1651	1	starlinkv40149	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1652	1	starlinkv40150	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1653	1	starlinkv40151	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1654	1	starlinkv40152	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1655	1	starlinkv40153	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1656	1	starlinkv40154	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1657	1	starlinkv40155	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1658	1	starlinkv40156	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1659	1	starlinkv40157	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1660	1	starlinkv40158	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1661	1	starlinkv40159	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1662	1	starlinkv40160	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1663	1	starlinkv40161	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1664	1	starlinkv40162	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1665	1	starlinkv40163	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1666	1	starlinkv40164	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1667	1	starlinkv40165	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1668	1	starlinkv40166	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1669	1	starlinkv40167	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1670	1	starlinkv40168	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1671	1	starlinkv40169	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1672	1	starlinkv40170	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1673	1	starlinkv40171	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1674	1	starlinkv40172	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1675	1	starlinkv40173	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1676	1	starlinkv40174	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1677	1	starlinkv40175	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1678	1	starlinkv40176	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1679	1	starlinkv40177	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1680	1	starlinkv40178	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1681	1	starlinkv40179	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1682	1	starlinkv40180	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1683	1	starlinkv40181	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1684	1	starlinkv40182	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1685	1	starlinkv40183	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1686	1	starlinkv40184	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1687	1	starlinkv40185	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1688	1	starlinkv40186	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1689	1	starlinkv40187	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1690	1	starlinkv40188	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1691	1	starlinkv40189	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1692	1	starlinkv40190	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1693	1	starlinkv40191	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1694	1	starlinkv40192	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1695	1	starlinkv40193	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1696	1	starlinkv40194	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1697	1	starlinkv40195	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1698	1	starlinkv40196	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1699	1	starlinkv40197	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1700	1	starlinkv40198	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1701	1	starlinkv40199	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1702	1	starlinkv40200	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1703	1	starlinkv40201	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1704	1	starlinkv40202	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1705	1	starlinkv40203	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1706	1	starlinkv40204	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1707	1	starlinkv40205	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1708	1	starlinkv40206	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1709	1	starlinkv40207	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1710	1	starlinkv40208	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1711	1	starlinkv40209	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1712	1	starlinkv40210	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1713	1	starlinkv40211	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1714	1	starlinkv40212	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1715	1	starlinkv40213	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1716	1	starlinkv40214	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1717	1	starlinkv40215	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1718	1	starlinkv40216	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1719	1	starlinkv40217	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1720	1	starlinkv40218	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1721	1	starlinkv40219	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1722	1	starlinkv40220	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1723	1	starlinkv40221	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1724	1	starlinkv40222	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1725	1	starlinkv40223	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1726	1	starlinkv40224	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1727	1	starlinkv40225	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1728	1	starlinkv40226	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1729	1	starlinkv40227	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1730	1	starlinkv40228	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1731	1	starlinkv40229	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1732	1	starlinkv40230	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1733	1	starlinkv40231	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1734	1	starlinkv40232	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1735	1	starlinkv40233	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1736	1	starlinkv40234	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1737	1	starlinkv40235	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1738	1	starlinkv40236	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1739	1	starlinkv40237	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1740	1	starlinkv40238	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1741	1	starlinkv40239	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1742	1	starlinkv40240	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1743	1	starlinkv40241	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1744	1	starlinkv40242	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1745	1	starlinkv40243	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1746	1	starlinkv40244	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1747	1	starlinkv40245	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1748	1	starlinkv40246	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1749	1	starlinkv40247	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1750	1	starlinkv40248	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1751	1	starlinkv40249	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1752	1	starlinkv40250	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1753	1	starlinkv40251	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1754	1	starlinkv40252	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1755	1	starlinkv40253	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1756	1	starlinkv40254	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1757	1	starlinkv40255	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1758	1	starlinkv40256	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1759	1	starlinkv40257	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1760	1	starlinkv40258	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1761	1	starlinkv40259	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1762	1	starlinkv40260	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1763	1	starlinkv40261	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1764	1	starlinkv40262	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1765	1	starlinkv40263	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1766	1	starlinkv40264	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1767	1	starlinkv40265	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1768	1	starlinkv40266	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1769	1	starlinkv40267	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1770	1	starlinkv40268	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1771	1	starlinkv40269	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1772	1	starlinkv40270	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1773	1	starlinkv40271	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1774	1	starlinkv40272	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1775	1	starlinkv40273	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1776	1	starlinkv40274	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1777	1	starlinkv40275	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1778	1	starlinkv40276	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1779	1	starlinkv40277	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1780	1	starlinkv40278	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1781	1	starlinkv40279	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1782	1	starlinkv40280	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1783	1	starlinkv40281	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1784	1	starlinkv40282	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1785	1	starlinkv40283	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1786	1	starlinkv40284	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1787	1	starlinkv40285	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1788	1	starlinkv40286	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1789	1	starlinkv40287	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1790	1	starlinkv40288	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1791	1	starlinkv40289	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1792	1	starlinkv40290	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1793	1	starlinkv40291	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1794	1	starlinkv40292	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1795	1	starlinkv40293	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1796	1	starlinkv40294	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1797	1	starlinkv40295	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1798	1	starlinkv40296	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1799	1	starlinkv40297	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1800	1	starlinkv40298	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1801	1	starlinkv40299	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1802	1	starlinkv40300	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1803	1	starlinkv40301	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1804	1	starlinkv40302	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1805	1	starlinkv40303	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1806	1	starlinkv40304	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1807	1	starlinkv40305	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1808	1	starlinkv40306	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1809	1	starlinkv40307	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1810	1	starlinkv40308	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1811	1	starlinkv40309	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1812	1	starlinkv40310	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1813	1	starlinkv40311	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1814	1	starlinkv40312	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1815	1	starlinkv40313	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1816	1	starlinkv40314	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1817	1	starlinkv40315	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1818	1	starlinkv40316	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1819	1	starlinkv40317	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1820	1	starlinkv40318	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1821	1	starlinkv40319	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1822	1	starlinkv40320	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1823	1	starlinkv40321	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1824	1	starlinkv40322	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1825	1	starlinkv40323	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1826	1	starlinkv40324	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1827	1	starlinkv40325	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1828	1	starlinkv40326	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1829	1	starlinkv40327	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1830	1	starlinkv40328	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1831	1	starlinkv40329	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1832	1	starlinkv40330	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1833	1	starlinkv40331	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1834	1	starlinkv40332	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1835	1	starlinkv40333	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1836	1	starlinkv40334	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1837	1	starlinkv40335	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1838	1	starlinkv40336	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1839	1	starlinkv40337	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1840	1	starlinkv40338	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1841	1	starlinkv40339	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1842	1	starlinkv40340	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1843	1	starlinkv40341	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1844	1	starlinkv40342	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1845	1	starlinkv40343	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1846	1	starlinkv40344	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1847	1	starlinkv40345	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1848	1	starlinkv40346	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1849	1	starlinkv40347	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1850	1	starlinkv40348	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1851	1	starlinkv40349	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1852	1	starlinkv40350	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1853	1	starlinkv40351	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1854	1	starlinkv40352	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1855	1	starlinkv40353	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1856	1	starlinkv40354	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1857	1	starlinkv40355	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1858	1	starlinkv40356	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1859	1	starlinkv40357	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1860	1	starlinkv40358	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1861	1	starlinkv40359	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1862	1	starlinkv40360	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1863	1	starlinkv40361	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1864	1	starlinkv40362	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1865	1	starlinkv40363	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1866	1	starlinkv40364	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1867	1	starlinkv40365	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1868	1	starlinkv40366	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1869	1	starlinkv40367	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1870	1	starlinkv40368	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1871	1	starlinkv40369	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1872	1	starlinkv40370	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1873	1	starlinkv40371	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1874	1	starlinkv40372	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1875	1	starlinkv40373	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1876	1	starlinkv40374	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1877	1	starlinkv40375	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1878	1	starlinkv40376	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1879	1	starlinkv40377	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1880	1	starlinkv40378	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1881	1	starlinkv40379	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1882	1	starlinkv40380	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1883	1	starlinkv40381	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1884	1	starlinkv40382	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1885	1	starlinkv40383	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1886	1	starlinkv40384	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1887	1	starlinkv40385	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1888	1	starlinkv40386	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1889	1	starlinkv40387	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1890	1	starlinkv40388	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1891	1	starlinkv40389	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1892	1	starlinkv40390	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1893	1	starlinkv40391	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1894	1	starlinkv40392	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1895	1	starlinkv40393	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1896	1	starlinkv40394	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1897	1	starlinkv40395	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1898	1	starlinkv40396	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1899	1	starlinkv40397	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1900	1	starlinkv40398	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1901	1	starlinkv40399	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1902	1	starlinkv40400	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1903	1	starlinkv40401	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1904	1	starlinkv40402	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1905	1	starlinkv40403	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1906	1	starlinkv40404	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1907	1	starlinkv40405	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1908	1	starlinkv40406	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1909	1	starlinkv40407	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1910	1	starlinkv40408	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1911	1	starlinkv40409	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1912	1	starlinkv40410	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1913	1	starlinkv40411	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1914	1	starlinkv40412	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1915	1	starlinkv40413	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1916	1	starlinkv40414	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1917	1	starlinkv40415	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1918	1	starlinkv40416	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1919	1	starlinkv40417	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1920	1	starlinkv40418	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1921	1	starlinkv40419	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1922	1	starlinkv40420	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1923	1	starlinkv40421	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1924	1	starlinkv40422	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1925	1	starlinkv40423	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1926	1	starlinkv40424	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1927	1	starlinkv40425	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1928	1	starlinkv40426	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1929	1	starlinkv40427	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1930	1	starlinkv40428	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1931	1	starlinkv40429	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1932	1	starlinkv40430	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1933	1	starlinkv40431	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1934	1	starlinkv40432	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1935	1	starlinkv40433	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1936	1	starlinkv40434	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1937	1	starlinkv40435	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1938	1	starlinkv40436	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1939	1	starlinkv40437	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1940	1	starlinkv40438	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1941	1	starlinkv40439	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1942	1	starlinkv40440	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1943	1	starlinkv40441	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1944	1	starlinkv40442	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1945	1	starlinkv40443	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1946	1	starlinkv40444	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1947	1	starlinkv40445	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1948	1	starlinkv40446	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1949	1	starlinkv40447	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1950	1	starlinkv40448	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1951	1	starlinkv40449	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1952	1	starlinkv40450	IN	PurchaseInvoice	27	2026-01-05 13:53:56.605392	1
1953	25	metaquest3s001	IN	PurchaseInvoice	28	2026-01-05 13:53:56.626474	1
1954	26	4V0ZW23H7602XL	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1955	26	4V0ZW23H6Z00DY	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1956	26	2Q9GS02H7607MX	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1957	26	2Q0ZY12H6F00DM	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1958	26	2Q9GS00H9R0MPL	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1959	26	2Q9GS00H9K091G	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1960	26	raybanglass00001	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1961	26	raybanglass00002	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1962	26	raybanglass00003	IN	PurchaseInvoice	29	2026-01-05 13:53:56.627997	1
1963	72	RS0290-GP0344450	IN	PurchaseInvoice	30	2026-01-05 13:53:56.630503	1
1964	72	RS0290-GP0348792	IN	PurchaseInvoice	30	2026-01-05 13:53:56.630503	1
1965	72	RS0290-GP0349113	IN	PurchaseInvoice	30	2026-01-05 13:53:56.630503	1
1966	73	NHQX6SA001513010BD0X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1967	73	NHQX6SA001513011270X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1968	73	NHQX6SA001520011E20X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1969	73	NHQX6SA001520011B70X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1970	73	NHQX6SA001520011800X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1971	73	NHQX6SA00151500FB40X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1972	73	NHQX6SA001520013F90X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1973	73	NHQX6SA0015200102D0X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1974	73	NHQX6SA001520014060X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1975	73	NHQX6SA001520013FC0X15	IN	PurchaseInvoice	31	2026-01-05 13:53:56.632487	1
1976	74	]C121159503000032	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1977	74	]C121159503000235	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1978	74	]C121159503000491	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1979	74	]C121159503000499	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1980	74	]C121159503000063	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1981	74	]C121159503000039	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1982	74	]C121159503000060	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1983	74	]C121159503000196	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1984	74	]C121159503000377	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1985	74	]C121159503000493	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1986	74	]C121159503000233	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1987	74	]C121159503000496	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1988	74	]C121159503000385	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1989	74	]C121159503000140	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1990	74	]C121159503000055	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1991	74	]C121159503000051	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1992	74	]C121159503000308	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1993	74	]C121159503000057	IN	PurchaseInvoice	32	2026-01-05 13:53:56.634811	1
1994	117	silkepilator90001	IN	PurchaseInvoice	33	2026-01-05 13:53:56.637293	1
1995	117	silkepilator90002	IN	PurchaseInvoice	33	2026-01-05 13:53:56.637293	1
1996	117	silkepilator90003	IN	PurchaseInvoice	33	2026-01-05 13:53:56.637293	1
1997	117	silkepilator90004	IN	PurchaseInvoice	33	2026-01-05 13:53:56.637293	1
1998	118	silkepilator70001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
1999	118	silkepilator70002	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2000	118	silkepilator70003	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2001	119	shaver60001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2002	119	shaver60002	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2003	119	shaver60003	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2004	119	shaver60004	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2005	120	allinonetrimmer70001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2006	121	allinonetrimmer50001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2007	121	allinonetrimmer50002	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2008	121	allinonetrimmer50003	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2009	122	braunipl51370001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2010	122	braunipl51370002	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2011	122	braunipl51370003	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2012	122	braunipl51370004	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2013	122	braunipl51370005	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2014	122	braunipl51370006	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2015	122	braunipl51370007	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2016	122	braunipl51370008	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2017	123	braun9in10001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2018	124	S25ultra0001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2019	125	INSTAXWIDE4000001	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2020	125	INSTAXWIDE4000002	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2021	125	INSTAXWIDE4000003	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2022	125	INSTAXWIDE4000004	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2023	125	INSTAXWIDE4000005	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2024	125	INSTAXWIDE4000006	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2025	125	INSTAXWIDE4000007	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2026	125	INSTAXWIDE4000008	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2027	125	INSTAXWIDE4000009	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2028	125	INSTAXWIDE4000010	IN	PurchaseInvoice	34	2026-01-05 13:53:56.639335	1
2029	116	astrobotgame00001	IN	PurchaseInvoice	35	2026-01-05 13:53:56.643205	1
2030	126	SJWMFJKY3N4	IN	PurchaseInvoice	36	2026-01-05 13:53:56.645041	1
2031	126	SL7XYP0G23D	IN	PurchaseInvoice	36	2026-01-05 13:53:56.645041	1
2032	126	SG720G7T46C	IN	PurchaseInvoice	36	2026-01-05 13:53:56.645041	1
2033	71	JBLC6-0001	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2034	71	JBLC6-0002	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2035	71	JBLC6-0003	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2036	71	JBLC6-0004	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2037	71	JBLC6-0005	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2038	71	JBLC6-0006	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2039	71	JBLC6-0007	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2040	71	JBLC6-0008	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2041	71	JBLC6-0009	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2042	71	JBLC6-0010	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2043	71	JBLC6-0011	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2044	71	JBLC6-0012	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2045	71	JBLC6-0013	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2046	71	JBLC6-0014	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2047	71	JBLC6-0015	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2048	71	JBLC6-0016	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2049	71	JBLC6-0017	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2050	71	JBLC6-0018	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2051	71	JBLC6-0019	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2052	71	JBLC6-0020	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2053	71	JBLC6-0021	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2054	71	JBLC6-0022	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2055	71	JBLC6-0023	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2056	71	JBLC6-0024	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2057	71	JBLC6-0025	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2058	71	JBLC6-0026	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2059	71	JBLC6-0027	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2060	71	JBLC6-0028	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2061	71	JBLC6-0029	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2062	71	JBLC6-0030	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2063	71	JBLC6-0031	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2064	71	JBLC6-0032	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2065	71	JBLC6-0033	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2066	71	JBLC6-0034	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2067	71	JBLC6-0035	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2068	71	JBLC6-0036	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2069	71	JBLC6-0037	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2070	71	JBLC6-0038	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2071	71	JBLC6-0039	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2072	71	JBLC6-0040	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2073	71	JBLC6-0041	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2074	71	JBLC6-0042	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2075	71	JBLC6-0043	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2076	71	JBLC6-0044	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2077	71	JBLC6-0045	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2078	71	JBLC6-0046	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2079	71	JBLC6-0047	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2080	71	JBLC6-0048	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2081	71	JBLC6-0049	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2082	71	JBLC6-0050	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2083	71	JBLC6-0051	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2084	71	JBLC6-0052	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2085	71	JBLC6-0053	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2086	71	JBLC6-0054	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2087	71	JBLC6-0055	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2088	71	JBLC6-0056	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2089	71	JBLC6-0057	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2090	71	JBLC6-0058	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2091	71	JBLC6-0059	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2092	71	JBLC6-0060	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2093	71	JBLC6-0061	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2094	71	JBLC6-0062	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2095	71	JBLC6-0063	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2096	71	JBLC6-0064	IN	PurchaseInvoice	37	2026-01-05 14:10:05.684553	1
2097	26	2Q9GS11H7Q0BX3	IN	PurchaseInvoice	38	2026-01-05 14:10:05.692086	1
2098	79	357205987236407	IN	PurchaseInvoice	39	2026-01-05 14:52:11.197298	1
2099	127	359811269284607	IN	PurchaseInvoice	39	2026-01-05 14:52:11.197298	1
2100	88	356334540191734	IN	PurchaseInvoice	39	2026-01-05 14:52:11.197298	1
2101	89	356706681483527	IN	PurchaseInvoice	39	2026-01-05 14:52:11.197298	1
2102	97	SLT21H7HQ07	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2103	98	SK4J0CJP9GD	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2104	99	SMH6XKV42GN	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2105	100	SCLJDXQM0M5	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2106	100	SLW5X9YYFV4	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2107	100	SDHWJP7GCTQ	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2108	100	SJQ1034P73F	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2109	100	SK9HQP762LY	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2110	100	SG03VC4XHGQ	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2111	128	SDXFHWMK411	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2112	66	358112934982993	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2113	101	SKFHLW39006	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2114	102	354780907319619	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2115	102	359045769498108	IN	PurchaseInvoice	40	2026-01-05 14:58:15.414811	1
2116	129	353729490556559	IN	PurchaseInvoice	41	2026-01-05 14:58:15.419245	1
2117	129	353729490518146	IN	PurchaseInvoice	41	2026-01-05 14:58:15.419245	1
2118	130	355362421357943	IN	PurchaseInvoice	41	2026-01-05 14:58:15.419245	1
2119	130	355362421357711	IN	PurchaseInvoice	41	2026-01-05 14:58:15.419245	1
2120	103	359493732980820	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2121	103	356422163856533	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2122	89	356706681272813	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2123	104	354123754950428	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2124	104	354123755217074	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2125	104	354123752557134	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2126	104	354123758609392	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2127	90	358911633611088	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2128	90	358911632167553	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2129	105	357550247169306	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2130	106	359132196544314	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2131	106	359132192725040	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2132	105	357550246973039	IN	PurchaseInvoice	42	2026-01-05 14:58:15.421572	1
2133	89	352905161312222	IN	PurchaseInvoice	43	2026-01-05 14:58:15.424753	1
2134	88	356334540659417	IN	PurchaseInvoice	43	2026-01-05 14:58:15.424753	1
2135	88	352066342028508	IN	PurchaseInvoice	43	2026-01-05 14:58:15.424753	1
2136	93	358345392856594	IN	PurchaseInvoice	43	2026-01-05 14:58:15.424753	1
2137	27	S01K15301M8110364247	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2138	27	S01K15401M8110414717	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2139	27	S01K15501M8110427662	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2140	27	S01F14B01GH910943285	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2141	27	S01K15501M8110427617	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2142	27	S01K15101M8110310006	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2143	27	S01K25701VJ910336156	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2144	27	S01K15501M8110454774	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2145	27	S01K15101M8110303945	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2146	27	S01K15401M8110401394	IN	PurchaseInvoice	44	2026-01-05 15:07:33.317908	1
2147	2	S01M45601K1W11165182	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2148	2	S01M45601K1W11165181	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2149	2	S01V55601Z1L10345699	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2150	2	S01V55601Z1L10458423	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2151	2	S01V55601Z1L10304899	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2152	2	S01V55601Z1L10345582	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2153	2	S01V55601Z1L10504969	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2154	2	S01V55601Z1L10377962	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2155	2	S01K5560179810281816	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2156	2	S01V55801Z1L11001841	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2157	2	S01V55701Z1L10846630	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2158	2	S01V55801Z1L11086063	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2159	2	S01V55801Z1L11081301	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2160	2	S01V55801Z1L11057425	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2161	2	S01V55801Z1L11086045	IN	PurchaseInvoice	45	2026-01-05 15:07:33.321212	1
2162	3	S01V55801UNL11264243	IN	PurchaseInvoice	46	2026-01-05 15:07:33.324216	1
2163	3	S01V55901UNL11364709	IN	PurchaseInvoice	46	2026-01-05 15:07:33.324216	1
2164	3	S01E44A01X4912823801	IN	PurchaseInvoice	46	2026-01-05 15:07:33.324216	1
2165	3	S011558343F	IN	PurchaseInvoice	46	2026-01-05 15:07:33.324216	1
2166	3	S0115405247	IN	PurchaseInvoice	46	2026-01-05 15:07:33.324216	1
2167	28	playstationportal00001	IN	PurchaseInvoice	47	2026-01-05 15:07:33.326402	1
2168	28	playstationportal00002	IN	PurchaseInvoice	47	2026-01-05 15:07:33.326402	1
2169	4	dualsensewirelesscontroller00001	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2170	4	dualsensewirelesscontroller00002	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2171	4	dualsensewirelesscontroller00003	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2172	4	dualsensewirelesscontroller00004	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2173	4	dualsensewirelesscontroller00005	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2174	4	dualsensewirelesscontroller00006	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2175	4	dualsensewirelesscontroller00007	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2176	4	dualsensewirelesscontroller00008	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2177	4	dualsensewirelesscontroller00009	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2178	4	dualsensewirelesscontroller00010	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2179	4	dualsensewirelesscontroller00011	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2180	4	dualsensewirelesscontroller00012	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2181	4	dualsensewirelesscontroller00013	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2182	4	dualsensewirelesscontroller00014	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2183	4	dualsensewirelesscontroller00015	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2184	4	dualsensewirelesscontroller00016	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2185	4	dualsensewirelesscontroller00017	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2186	4	dualsensewirelesscontroller00018	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2187	4	dualsensewirelesscontroller00019	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2188	4	dualsensewirelesscontroller00020	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2189	4	dualsensewirelesscontroller00021	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2190	4	dualsensewirelesscontroller00022	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2191	4	dualsensewirelesscontroller00023	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2192	4	dualsensewirelesscontroller00024	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2193	4	dualsensewirelesscontroller00025	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2194	4	dualsensewirelesscontroller00026	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2195	4	dualsensewirelesscontroller00027	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2196	4	dualsensewirelesscontroller00028	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2197	4	dualsensewirelesscontroller00029	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2198	4	dualsensewirelesscontroller00030	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2199	4	dualsensewirelesscontroller00031	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2200	4	dualsensewirelesscontroller00032	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2201	4	dualsensewirelesscontroller00033	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2202	4	dualsensewirelesscontroller00034	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2203	4	dualsensewirelesscontroller00035	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2204	4	dualsensewirelesscontroller00036	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2205	4	dualsensewirelesscontroller00037	IN	PurchaseInvoice	48	2026-01-05 15:07:33.328371	1
2206	5	S01G13200K1J11901709	IN	PurchaseInvoice	49	2026-01-05 15:07:33.332197	1
2207	29	cddragonage001	IN	PurchaseInvoice	50	2026-01-05 15:07:33.333943	1
2208	29	cddragonage002	IN	PurchaseInvoice	50	2026-01-05 15:07:33.333943	1
2209	29	cddragonage003	IN	PurchaseInvoice	50	2026-01-05 15:07:33.333943	1
2210	30	HAW50133386373	IN	PurchaseInvoice	51	2026-01-05 15:07:33.336016	1
2211	30	HAW50823681801	IN	PurchaseInvoice	51	2026-01-05 15:07:33.336016	1
2212	30	HAW50999742764	IN	PurchaseInvoice	51	2026-01-05 15:07:33.336016	1
2213	30	HAW50552318047	IN	PurchaseInvoice	51	2026-01-05 15:07:33.336016	1
2214	30	HAW50879431337	IN	PurchaseInvoice	51	2026-01-05 15:07:33.336016	1
2215	30	HAW50594654479	IN	PurchaseInvoice	51	2026-01-05 15:07:33.336016	1
2216	16	HAW50872099053	IN	PurchaseInvoice	52	2026-01-05 15:07:33.338156	1
2217	16	XKW70042063868	IN	PurchaseInvoice	52	2026-01-05 15:07:33.338156	1
2218	31	XKW40016891919	IN	PurchaseInvoice	53	2026-01-05 15:07:33.340024	1
2219	32	2388071	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2220	32	2431142	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2221	33	SCRGHQQVPXF	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2222	33	SFN4KXRQCTK	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2223	34	SH2DN10B1LN3P	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2224	34	SH2JMX109LN3P	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2225	35	085954T53164697AE	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2226	36	076842950653250AE	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2227	37	C3535424564583	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2228	38	87F852433	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2229	39	610528253621	IN	PurchaseInvoice	54	2026-01-05 15:07:33.341828	1
2230	25	3497BMMH9303DP	IN	PurchaseInvoice	55	2026-01-05 15:07:33.344967	1
2231	40	2G97BMMH9S00J0	IN	PurchaseInvoice	56	2026-01-05 15:07:33.346666	1
2232	40	2G97BMMH9X03ZS	IN	PurchaseInvoice	56	2026-01-05 15:07:33.346666	1
2233	40	2G97BMMH9Q057K	IN	PurchaseInvoice	56	2026-01-05 15:07:33.346666	1
2234	40	2G0YBMTH0700FL	IN	PurchaseInvoice	56	2026-01-05 15:07:33.346666	1
2235	41	SCYDJ4CQP61	IN	PurchaseInvoice	57	2026-01-05 15:07:33.34883	1
2236	41	SGW14WNWRLY	IN	PurchaseInvoice	57	2026-01-05 15:07:33.34883	1
2237	41	SHVJJJQWFQ1	IN	PurchaseInvoice	57	2026-01-05 15:07:33.34883	1
2238	41	SKTH7XD95H4	IN	PurchaseInvoice	57	2026-01-05 15:07:33.34883	1
2239	41	SHYD12GT7FV	IN	PurchaseInvoice	57	2026-01-05 15:07:33.34883	1
2240	42	SC0Y0F9X7QC	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2241	42	SGCF92TLQXH	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2242	42	SG2D1H6GKVC	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2243	42	SHLQQTX9JGW	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2244	43	SGHJYWKVQXD	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2245	44	SV49N6TXD96	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2246	45	SDKJYYPYHW5	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2247	46	59101WRBJB3416	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2248	46	58111WRBJB0499	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2249	47	359636864068653	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2250	48	353490912585953	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2251	49	358352972640471	IN	PurchaseInvoice	58	2026-01-05 15:07:33.351076	1
2252	26	4W0ZWF5H760BH3	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2253	26	4V37W29H7X00MG	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2254	26	4V37W31H9900B3	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2255	26	4V0ZW04H9F04PK	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2256	26	4V0ZW27H9L0132	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2257	26	2Q9GS11H9J04VT	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2258	26	2Q9GS11H9H0C2P	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2259	26	2Q9GS11H9J0438	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2260	26	2Q9GS11H9H04GR	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2261	26	2Q9GS11HBG08WZ	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2262	26	2Q9GS11H9J03Q1	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2263	26	2Q9GS11H9H0204	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2264	26	2Q9GS11H9H04ZK	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2265	26	2Q9GS11H9G01M4	IN	PurchaseInvoice	59	2026-01-05 15:07:33.353904	1
2266	50	352457390429203	IN	PurchaseInvoice	60	2026-01-05 15:07:33.356554	1
2267	51	352457390576607	IN	PurchaseInvoice	60	2026-01-05 15:07:33.356554	1
2268	52	359117430967728	IN	PurchaseInvoice	60	2026-01-05 15:07:33.356554	1
2269	53	SK6GQGF74F4	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2270	54	SGVQ2RQRCMW	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2271	55	ST76N06VX9D	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2272	56	SF7J9C4WVDW	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2273	56	SK327X51Q91	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2274	61	SL93Y0GWVRC	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2275	62	SC91KHM70VM	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2276	59	SGPGK00MPQ7	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2277	60	SFVFHN160Q6L5	IN	PurchaseInvoice	61	2026-01-05 15:07:33.358668	1
2278	63	356196182587945	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2279	63	356196183103940	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2280	63	355205568606640	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2281	64	352066342215865	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2282	65	SJXKF950C3P	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2283	66	358112930502035	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2284	66	358112931678883	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2285	66	358112932166375	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2286	67	352355706850411	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2287	67	352355704532573	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2288	67	352355700973722	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2289	67	352355701807754	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2290	67	352355709742698	IN	PurchaseInvoice	62	2026-01-05 15:07:33.361343	1
2291	68	350247150243361	IN	PurchaseInvoice	63	2026-01-05 15:07:33.364439	1
2292	69	356764175496547	IN	PurchaseInvoice	63	2026-01-05 15:07:33.364439	1
2293	69	355478870898102	IN	PurchaseInvoice	63	2026-01-05 15:07:33.364439	1
2294	69	353837412105817	IN	PurchaseInvoice	63	2026-01-05 15:07:33.364439	1
2295	70	355122363950588	IN	PurchaseInvoice	63	2026-01-05 15:07:33.364439	1
2296	75	358419940353196	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2297	76	359724852602210	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2298	77	358271520320685	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2299	78	351523426490179	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2300	79	359222381700076	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2301	79	356541620272248	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2302	79	356864569740201	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2303	79	359222389749273	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2304	79	357031376241620	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2305	80	353357355939908	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2306	80	354136652550926	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2307	81	356043381249259	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2308	82	351661825602182	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2309	82	357275795101812	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2310	83	350832430489197	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2311	84	352772254261397	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2312	85	353352950838027	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2313	86	353427814932297	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2314	87	359836518197367	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2315	88	352066342213241	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2316	89	357494474437690	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2317	90	358911632646218	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2318	91	353173803445491	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2319	92	356799836296837	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2320	93	SJ460W9GH4F	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2321	93	SDCLXG1749Y	IN	PurchaseInvoice	64	2026-01-05 15:07:33.366882	1
2322	79	355783829033440	IN	PurchaseInvoice	65	2026-01-05 15:07:33.372021	1
2323	75	352368545956687	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2324	75	352758404050616	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2325	75	354512320603638	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2326	75	354512324560990	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2327	75	358936958142898	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2328	75	352758404284538	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2329	75	352758404073113	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2330	75	352368545993615	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2331	75	352368546192654	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2332	75	354512323488342	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2333	75	352602317458153	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2334	75	354512320823475	IN	PurchaseInvoice	66	2026-01-05 15:38:57.79738	1
2335	109	fujiinstaxminiliply00001	IN	PurchaseInvoice	67	2026-01-05 15:54:34.083047	1
2336	109	fujiinstaxminiliply00002	IN	PurchaseInvoice	67	2026-01-05 15:54:34.083047	1
2337	109	fujiinstaxminiliply00003	IN	PurchaseInvoice	67	2026-01-05 15:54:34.083047	1
2338	109	fujiinstaxminiliply00004	IN	PurchaseInvoice	67	2026-01-05 15:54:34.083047	1
2339	109	fujiinstaxminiliply00005	IN	PurchaseInvoice	67	2026-01-05 15:54:34.083047	1
2340	109	fujiinstaxminiliply00006	IN	PurchaseInvoice	67	2026-01-05 15:54:34.083047	1
2341	107	onnsingleusecamera00001	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2342	107	onnsingleusecamera00002	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2343	107	onnsingleusecamera00003	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2344	107	onnsingleusecamera00004	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2345	107	onnsingleusecamera00005	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2346	107	onnsingleusecamera00006	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2347	107	onnsingleusecamera00007	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2348	107	onnsingleusecamera00008	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2349	107	onnsingleusecamera00009	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2350	107	onnsingleusecamera00010	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2351	108	onnreusablecamera00001	IN	PurchaseInvoice	68	2026-01-05 16:11:37.917777	1
2352	103	351525510727416	IN	PurchaseInvoice	69	2026-01-07 15:02:07.966877	1
2353	103	351525510878441	IN	PurchaseInvoice	69	2026-01-07 15:02:07.966877	1
2354	103	359493733064400	IN	PurchaseInvoice	70	2026-01-07 15:02:07.973085	1
2355	103	356422165489838	IN	PurchaseInvoice	70	2026-01-07 15:02:07.973085	1
2356	132	359103740084792	IN	PurchaseInvoice	71	2026-01-07 15:02:07.975914	1
2357	79	350773430942266	IN	PurchaseInvoice	72	2026-01-07 15:02:07.978524	1
2358	133	pixel0001	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2359	134	352653442265609	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2360	135	353247105566665	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2361	136	353890109487576	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2362	79	352315403679901	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2363	79	357205981249315	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2364	137	355964948552797	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2365	81	356295606462741	IN	PurchaseInvoice	73	2026-01-07 15:16:34.091438	1
2366	133	pixel0001	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2367	134	352653442265609	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2368	135	353247105566665	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2369	136	353890109487576	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2370	79	352315403679901	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2371	79	357205981249315	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2372	137	355964948552797	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2373	81	356295606462741	OUT	PurchaseInvoice-Delete	73	2026-01-07 15:18:23.686268	1
2374	133	pixel0001	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2375	134	352653442265609	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2376	135	353247105566665	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2377	136	353890109487576	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2378	79	352315403679901	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2379	79	357205981249315	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2380	137	355964948552797	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2381	81	356295606462741	IN	PurchaseInvoice	74	2026-01-07 15:18:36.12523	1
2382	131	1581F8LQC259V0025QND	IN	PurchaseInvoice	75	2026-01-07 15:28:08.550714	1
2383	131	1581F8LQC255Q0022GVN	IN	PurchaseInvoice	75	2026-01-07 15:28:08.550714	1
2384	80	354136652903232	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2385	81	357463448249218	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2386	79	352315400015596	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2387	137	354359265927857	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2388	138	351399081079239	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2389	75	356764170580642	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2390	76	359724859410781	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2391	82	352676524778959	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2392	86	358001685550705	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2393	68	351687742123226	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2394	104	SKVNHV9WJ4J	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2395	56	L0FVM00VD9	IN	PurchaseInvoice	76	2026-01-07 15:56:22.764816	1
2396	43	SMT43DHJRGH	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2397	43	SK946HW04X3	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2398	43	SGD4TR707KJ	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2399	42	SD2WYWYFPLV	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2400	42	SDX9XWFKW42	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2401	42	SL9W0J24GDM	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2402	42	SM7RR6FRW7N	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2403	106	359132197678855	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2404	105	SH6W4PFQWCW	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2405	152	356187982445939	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2406	153	359800206266629	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2407	153	358344510337678	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2408	153	359800204422869	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2409	151	SDF9R6G97J0	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2410	149	SMT79VX36C5	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2411	149	SMJF72R0W6K	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2412	150	SF3W6VGQT49	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2413	154	4V0ZH17H7X01K1	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2414	158	2Q0ZY01H6R0088	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2415	157	4V0ZS17H8H02KD	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2416	157	4V0ZS12H8M0121	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2417	156	2Q0ZT00H9108MM	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2418	155	4V37W23H8Y03BB	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2419	63	350094261697964	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2420	63	350094261355704	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2421	146	SJ56LKQX91F	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2422	146	SLJ2DW1GJPG	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2423	148	SM04W37XK2M	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2424	147	357153132623899	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2425	88	356334540274274	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2426	66	358112930542452	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2427	136	353894107001488	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2428	144	358691739992588	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2429	86	357773240293275	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2430	143	357773241392274	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2431	138	356832826585198	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2432	141	357985605788059	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2433	103	353685834007800	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2434	141	357762265949689	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2435	80	357719281961635	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2436	79	355008282401839	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2437	140	355445520481381	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2438	142	355852812209224	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2439	142	350138782777415	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2440	142	352515983937724	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2441	142	350304975570948	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2442	68	358051322533887	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2443	68	353837419391642	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2444	68	358051321265978	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2445	68	356605225057831	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2446	68	350889862536879	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2447	68	353263425144000	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2448	68	359614544687390	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2449	68	359912587219711	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2450	68	359614541610171	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2451	68	359614540060931	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2452	75	353263423932034	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2453	145	358229303109360	IN	PurchaseInvoice	77	2026-01-08 08:41:25.164235	1
2454	152	356768323979858	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2455	152	355827874735076	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2456	152	355827873912551	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2457	152	356768327697845	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2458	152	355827874548040	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2459	152	356768323955908	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2460	152	355827874619494	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2461	152	355827874116541	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2462	152	358135794483430	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2463	152	358135794723439	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2464	67	352355700400171	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2465	77	350795041545725	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2466	77	357223745121191	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2467	70	351317522499402	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2468	70	356250549251677	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2469	70	350208033090551	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2470	70	350208033173753	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2471	70	350208033299269	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2472	70	356250549428937	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2473	70	356250549139179	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2474	70	350208033166849	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2475	70	352190324660847	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2476	159	350208037361842	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2477	159	350208037531998	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2478	68	355224250029748	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2479	68	358051322163339	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2480	68	350889865420378	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2481	68	357586344694234	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2482	68	356188163778437	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2483	68	358051322098196	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2484	68	357586344596264	IN	PurchaseInvoice	78	2026-01-08 09:01:02.485063	1
2485	106	352673830520696	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2486	106	355201220205269	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2487	152	355827874060491	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2488	152	356768325047464	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2489	152	355827873857608	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2490	152	355827874760009	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2491	152	356768328441524	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2492	152	356187983372108	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2493	152	358135794112948	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2494	160	351878871049411	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2495	160	351878871034231	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2496	160	356930604129856	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2497	67	352355707404705	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2498	77	350795040883309	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2499	77	357247591394057	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2500	77	350795041218463	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2501	77	350795041085185	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2502	70	352190327421734	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2503	70	354956974267937	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2504	70	356661405453746	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2505	70	356250543171277	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2506	70	356250549338896	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2507	70	352190327764315	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2508	70	353708846189133	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2509	68	355450218650917	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2510	68	356605226033781	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2511	68	357586344726028	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2512	68	350889864968799	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2513	68	358051322474710	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2514	68	356188163860573	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2515	68	358051322301210	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
2516	68	358051321091101	IN	PurchaseInvoice	79	2026-01-08 09:08:57.876091	1
\.


--
-- Name: auth_group_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_group_id_seq', 1, true);


--
-- Name: auth_group_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_group_permissions_id_seq', 1, false);


--
-- Name: auth_permission_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_permission_id_seq', 24, true);


--
-- Name: auth_user_groups_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_user_groups_id_seq', 1, true);


--
-- Name: auth_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_user_id_seq', 3, true);


--
-- Name: auth_user_user_permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.auth_user_user_permissions_id_seq', 1, false);


--
-- Name: chartofaccounts_account_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.chartofaccounts_account_id_seq', 28, true);


--
-- Name: django_admin_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.django_admin_log_id_seq', 4, true);


--
-- Name: django_content_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.django_content_type_id_seq', 6, true);


--
-- Name: django_migrations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.django_migrations_id_seq', 18, true);


--
-- Name: items_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.items_item_id_seq', 160, true);


--
-- Name: journalentries_journal_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.journalentries_journal_id_seq', 130, true);


--
-- Name: journallines_line_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.journallines_line_id_seq', 260, true);


--
-- Name: parties_party_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.parties_party_id_seq', 69, true);


--
-- Name: payments_payment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payments_payment_id_seq', 1, true);


--
-- Name: payments_ref_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payments_ref_seq', 1, true);


--
-- Name: purchaseinvoices_purchase_invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseinvoices_purchase_invoice_id_seq', 79, true);


--
-- Name: purchaseitems_purchase_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseitems_purchase_item_id_seq', 298, true);


--
-- Name: purchasereturnitems_return_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchasereturnitems_return_item_id_seq', 1, false);


--
-- Name: purchasereturns_purchase_return_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchasereturns_purchase_return_id_seq', 1, false);


--
-- Name: purchaseunits_unit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseunits_unit_id_seq', 2508, true);


--
-- Name: receipts_receipt_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.receipts_receipt_id_seq', 1, true);


--
-- Name: receipts_ref_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.receipts_ref_seq', 1, true);


--
-- Name: salesinvoices_sales_invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesinvoices_sales_invoice_id_seq', 1, false);


--
-- Name: salesitems_sales_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesitems_sales_item_id_seq', 1, false);


--
-- Name: salesreturnitems_return_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesreturnitems_return_item_id_seq', 1, false);


--
-- Name: salesreturns_sales_return_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesreturns_sales_return_id_seq', 1, false);


--
-- Name: soldunits_sold_unit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.soldunits_sold_unit_id_seq', 1, false);


--
-- Name: stockmovements_movement_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.stockmovements_movement_id_seq', 2516, true);


--
-- Name: auth_group auth_group_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_name_key UNIQUE (name);


--
-- Name: auth_group_permissions auth_group_permissions_group_id_permission_id_0cd325b0_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_permission_id_0cd325b0_uniq UNIQUE (group_id, permission_id);


--
-- Name: auth_group_permissions auth_group_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_group auth_group_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group
    ADD CONSTRAINT auth_group_pkey PRIMARY KEY (id);


--
-- Name: auth_permission auth_permission_content_type_id_codename_01ab375a_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_codename_01ab375a_uniq UNIQUE (content_type_id, codename);


--
-- Name: auth_permission auth_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_pkey PRIMARY KEY (id);


--
-- Name: auth_user_groups auth_user_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_pkey PRIMARY KEY (id);


--
-- Name: auth_user_groups auth_user_groups_user_id_group_id_94350c0c_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_user_id_group_id_94350c0c_uniq UNIQUE (user_id, group_id);


--
-- Name: auth_user auth_user_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user
    ADD CONSTRAINT auth_user_pkey PRIMARY KEY (id);


--
-- Name: auth_user_user_permissions auth_user_user_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_user_user_permissions auth_user_user_permissions_user_id_permission_id_14a6b632_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_user_id_permission_id_14a6b632_uniq UNIQUE (user_id, permission_id);


--
-- Name: auth_user auth_user_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user
    ADD CONSTRAINT auth_user_username_key UNIQUE (username);


--
-- Name: chartofaccounts chartofaccounts_account_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts
    ADD CONSTRAINT chartofaccounts_account_code_key UNIQUE (account_code);


--
-- Name: chartofaccounts chartofaccounts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts
    ADD CONSTRAINT chartofaccounts_pkey PRIMARY KEY (account_id);


--
-- Name: django_admin_log django_admin_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_pkey PRIMARY KEY (id);


--
-- Name: django_content_type django_content_type_app_label_model_76bd3d3b_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_app_label_model_76bd3d3b_uniq UNIQUE (app_label, model);


--
-- Name: django_content_type django_content_type_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_content_type
    ADD CONSTRAINT django_content_type_pkey PRIMARY KEY (id);


--
-- Name: django_migrations django_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_migrations
    ADD CONSTRAINT django_migrations_pkey PRIMARY KEY (id);


--
-- Name: django_session django_session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_session
    ADD CONSTRAINT django_session_pkey PRIMARY KEY (session_key);


--
-- Name: items items_item_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_item_code_key UNIQUE (item_code);


--
-- Name: items items_item_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_item_name_key UNIQUE (item_name);


--
-- Name: items items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (item_id);


--
-- Name: journalentries journalentries_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journalentries
    ADD CONSTRAINT journalentries_pkey PRIMARY KEY (journal_id);


--
-- Name: journallines journallines_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_pkey PRIMARY KEY (line_id);


--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (party_id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (payment_id);


--
-- Name: purchaseinvoices purchaseinvoices_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_pkey PRIMARY KEY (purchase_invoice_id);


--
-- Name: purchaseitems purchaseitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_pkey PRIMARY KEY (purchase_item_id);


--
-- Name: purchasereturnitems purchasereturnitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_pkey PRIMARY KEY (return_item_id);


--
-- Name: purchasereturns purchasereturns_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_pkey PRIMARY KEY (purchase_return_id);


--
-- Name: purchaseunits purchaseunits_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_pkey PRIMARY KEY (unit_id);


--
-- Name: purchaseunits purchaseunits_serial_number_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_serial_number_key UNIQUE (serial_number);


--
-- Name: receipts receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_pkey PRIMARY KEY (receipt_id);


--
-- Name: salesinvoices salesinvoices_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_pkey PRIMARY KEY (sales_invoice_id);


--
-- Name: salesitems salesitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems
    ADD CONSTRAINT salesitems_pkey PRIMARY KEY (sales_item_id);


--
-- Name: salesreturnitems salesreturnitems_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_pkey PRIMARY KEY (return_item_id);


--
-- Name: salesreturns salesreturns_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_pkey PRIMARY KEY (sales_return_id);


--
-- Name: soldunits soldunits_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_pkey PRIMARY KEY (sold_unit_id);


--
-- Name: stockmovements stockmovements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stockmovements
    ADD CONSTRAINT stockmovements_pkey PRIMARY KEY (movement_id);


--
-- Name: parties unique_party_name; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT unique_party_name UNIQUE (party_name);


--
-- Name: auth_group_name_a6ea08ec_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_name_a6ea08ec_like ON public.auth_group USING btree (name varchar_pattern_ops);


--
-- Name: auth_group_permissions_group_id_b120cbf9; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_permissions_group_id_b120cbf9 ON public.auth_group_permissions USING btree (group_id);


--
-- Name: auth_group_permissions_permission_id_84c5c92e; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_group_permissions_permission_id_84c5c92e ON public.auth_group_permissions USING btree (permission_id);


--
-- Name: auth_permission_content_type_id_2f476e4b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_permission_content_type_id_2f476e4b ON public.auth_permission USING btree (content_type_id);


--
-- Name: auth_user_groups_group_id_97559544; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_groups_group_id_97559544 ON public.auth_user_groups USING btree (group_id);


--
-- Name: auth_user_groups_user_id_6a12ed8b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_groups_user_id_6a12ed8b ON public.auth_user_groups USING btree (user_id);


--
-- Name: auth_user_user_permissions_permission_id_1fbb5f2c; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_user_permissions_permission_id_1fbb5f2c ON public.auth_user_user_permissions USING btree (permission_id);


--
-- Name: auth_user_user_permissions_user_id_a95ead1b; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_user_permissions_user_id_a95ead1b ON public.auth_user_user_permissions USING btree (user_id);


--
-- Name: auth_user_username_6821ab7c_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX auth_user_username_6821ab7c_like ON public.auth_user USING btree (username varchar_pattern_ops);


--
-- Name: django_admin_log_content_type_id_c4bce8eb; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_admin_log_content_type_id_c4bce8eb ON public.django_admin_log USING btree (content_type_id);


--
-- Name: django_admin_log_user_id_c564eba6; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_admin_log_user_id_c564eba6 ON public.django_admin_log USING btree (user_id);


--
-- Name: django_session_expire_date_a5c62663; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_session_expire_date_a5c62663 ON public.django_session USING btree (expire_date);


--
-- Name: django_session_session_key_c0390e0f_like; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX django_session_session_key_c0390e0f_like ON public.django_session USING btree (session_key varchar_pattern_ops);


--
-- Name: parties trg_party_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_party_insert AFTER INSERT ON public.parties FOR EACH ROW EXECUTE FUNCTION public.trg_party_opening_balance();


--
-- Name: payments trg_payment_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_delete AFTER DELETE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();


--
-- Name: payments trg_payment_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_insert AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();


--
-- Name: payments trg_payment_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_update AFTER UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();


--
-- Name: receipts trg_receipt_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_receipt_delete AFTER DELETE ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();


--
-- Name: receipts trg_receipt_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_receipt_insert AFTER INSERT ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();


--
-- Name: receipts trg_receipt_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_receipt_update AFTER UPDATE ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();


--
-- Name: auth_group_permissions auth_group_permissio_permission_id_84c5c92e_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissio_permission_id_84c5c92e_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_group_permissions auth_group_permissions_group_id_b120cbf9_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_group_permissions
    ADD CONSTRAINT auth_group_permissions_group_id_b120cbf9_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_permission auth_permission_content_type_id_2f476e4b_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_2f476e4b_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_groups auth_user_groups_group_id_97559544_fk_auth_group_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_group_id_97559544_fk_auth_group_id FOREIGN KEY (group_id) REFERENCES public.auth_group(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_groups auth_user_groups_user_id_6a12ed8b_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_groups
    ADD CONSTRAINT auth_user_groups_user_id_6a12ed8b_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_user_permissions auth_user_user_permi_permission_id_1fbb5f2c_fk_auth_perm; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permi_permission_id_1fbb5f2c_fk_auth_perm FOREIGN KEY (permission_id) REFERENCES public.auth_permission(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: auth_user_user_permissions auth_user_user_permissions_user_id_a95ead1b_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.auth_user_user_permissions
    ADD CONSTRAINT auth_user_user_permissions_user_id_a95ead1b_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: chartofaccounts chartofaccounts_parent_account_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chartofaccounts
    ADD CONSTRAINT chartofaccounts_parent_account_fkey FOREIGN KEY (parent_account) REFERENCES public.chartofaccounts(account_id) ON DELETE SET NULL;


--
-- Name: django_admin_log django_admin_log_content_type_id_c4bce8eb_fk_django_co; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_content_type_id_c4bce8eb_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: django_admin_log django_admin_log_user_id_c564eba6_fk_auth_user_id; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.django_admin_log
    ADD CONSTRAINT django_admin_log_user_id_c564eba6_fk_auth_user_id FOREIGN KEY (user_id) REFERENCES public.auth_user(id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: journallines journallines_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chartofaccounts(account_id);


--
-- Name: journallines journallines_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE CASCADE;


--
-- Name: journallines journallines_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(party_id) ON DELETE SET NULL;


--
-- Name: parties parties_ap_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_ap_account_id_fkey FOREIGN KEY (ap_account_id) REFERENCES public.chartofaccounts(account_id) ON DELETE SET NULL;


--
-- Name: parties parties_ar_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_ar_account_id_fkey FOREIGN KEY (ar_account_id) REFERENCES public.chartofaccounts(account_id) ON DELETE SET NULL;


--
-- Name: payments payments_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chartofaccounts(account_id);


--
-- Name: payments payments_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: payments payments_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: purchaseinvoices purchaseinvoices_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: purchaseinvoices purchaseinvoices_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: purchaseitems purchaseitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: purchaseitems purchaseitems_purchase_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_purchase_invoice_id_fkey FOREIGN KEY (purchase_invoice_id) REFERENCES public.purchaseinvoices(purchase_invoice_id) ON DELETE CASCADE;


--
-- Name: purchasereturnitems purchasereturnitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: purchasereturnitems purchasereturnitems_purchase_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_purchase_return_id_fkey FOREIGN KEY (purchase_return_id) REFERENCES public.purchasereturns(purchase_return_id) ON DELETE CASCADE;


--
-- Name: purchasereturns purchasereturns_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: purchasereturns purchasereturns_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: purchaseunits purchaseunits_purchase_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_purchase_item_id_fkey FOREIGN KEY (purchase_item_id) REFERENCES public.purchaseitems(purchase_item_id) ON DELETE CASCADE;


--
-- Name: receipts receipts_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chartofaccounts(account_id);


--
-- Name: receipts receipts_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: receipts receipts_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: salesinvoices salesinvoices_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: salesinvoices salesinvoices_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: salesitems salesitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems
    ADD CONSTRAINT salesitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: salesitems salesitems_sales_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesitems
    ADD CONSTRAINT salesitems_sales_invoice_id_fkey FOREIGN KEY (sales_invoice_id) REFERENCES public.salesinvoices(sales_invoice_id) ON DELETE CASCADE;


--
-- Name: salesreturnitems salesreturnitems_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- Name: salesreturnitems salesreturnitems_sales_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_sales_return_id_fkey FOREIGN KEY (sales_return_id) REFERENCES public.salesreturns(sales_return_id) ON DELETE CASCADE;


--
-- Name: salesreturns salesreturns_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


--
-- Name: salesreturns salesreturns_journal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


--
-- Name: soldunits soldunits_sales_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_sales_item_id_fkey FOREIGN KEY (sales_item_id) REFERENCES public.salesitems(sales_item_id) ON DELETE CASCADE;


--
-- Name: soldunits soldunits_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.purchaseunits(unit_id) ON DELETE CASCADE;


--
-- Name: stockmovements stockmovements_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stockmovements
    ADD CONSTRAINT stockmovements_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- PostgreSQL database dump complete
--

\unrestrict IyjIK784Sp4a8hov8lV3SctochElSFAu1ebWYRM6TdLGgXrUItOKosnk4sh1tNx

