--
-- PostgreSQL database dump
--

\restrict Ibiku0xaY5yAkBqstFDzbH5EHFnKXOuLHJhXa0z8eKIWxEQbz3oeq2EaLoam2dp

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

CREATE FUNCTION public.get_serial_ledger(p_serial text) RETURNS TABLE(serial_number text, item_name text, txn_date date, particulars text, reference text, qty_in integer, qty_out integer, balance integer, party_name text, purchase_price numeric, sale_price numeric, profit numeric, age_days integer, age_months numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY

    WITH item_info AS (
        SELECT 
            pu.serial_number::text AS serial_number,
            i.item_name::text AS item_name,
            pi.invoice_date::date AS purchase_date
        FROM PurchaseUnits pu
        JOIN PurchaseItems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN PurchaseInvoices pi ON pit.purchase_invoice_id = pi.purchase_invoice_id
        JOIN Items i ON pit.item_id = i.item_id
        WHERE pu.serial_number = p_serial
        ORDER BY pi.invoice_date
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
        CAST(SUM(l.qty_in - l.qty_out)
            OVER (ORDER BY l.dt, l.reference) AS INT) AS balance,
        l.party_name,
        l.purchase_price,
        l.sale_price,
        CASE 
            WHEN l.sale_price IS NOT NULL AND l.purchase_price IS NOT NULL 
            THEN l.sale_price - l.purchase_price
        END AS profit,

        -- 🔹 AGE CALCULATION
        (CURRENT_DATE - ii.purchase_date) AS age_days,
        ROUND((CURRENT_DATE - ii.purchase_date) / 30.0, 2) AS age_months

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
    v_amount     NUMERIC(14,4);
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
    v_amount     NUMERIC(14,4);
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
-- Name: stock_summary(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.stock_summary() RETURNS TABLE(item_id bigint, item_name character varying, category character varying, brand character varying, quantity_in_stock bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        i.item_id,
        i.item_name,
        i.category,
        i.brand,
        COUNT(pu.unit_id) FILTER (WHERE pu.in_stock = TRUE) AS quantity_in_stock
    FROM Items i
    LEFT JOIN PurchaseItems pi ON i.item_id = pi.item_id
    LEFT JOIN PurchaseUnits pu ON pi.purchase_item_id = pu.purchase_item_id
    GROUP BY
        i.item_id,
        i.item_name,
        i.category,
        i.brand
    ORDER BY
        i.item_name ASC;
END;
$$;


ALTER FUNCTION public.stock_summary() OWNER TO postgres;

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
    v_amount    NUMERIC(14,4);
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
    v_purchase_item_id BIGINT;
    v_serial TEXT;
    v_new_party_id BIGINT;
    v_total NUMERIC(14,2) := 0;
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
    -- 3️⃣ Preserve sold serials in temp table
    -- ========================================================
    CREATE TEMP TABLE tmp_sold_units AS
    SELECT pu.purchase_item_id,
           pu.serial_number,
           pu.in_stock
    FROM PurchaseUnits pu
    JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
    WHERE pi.purchase_invoice_id = p_invoice_id
      AND pu.in_stock = FALSE;

    -- ========================================================
    -- 4️⃣ Delete old units, stock movements, and purchase items
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
    -- 5️⃣ Insert updated items and units
    -- ========================================================
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        -- Get or create item
        SELECT item_id INTO v_item_id
        FROM Items
        WHERE item_name = (v_item->>'item_name')
        LIMIT 1;

        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        -- Insert purchase item
        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (
            p_invoice_id,
            v_item_id,
            jsonb_array_length(v_item->'serials'),
            (v_item->>'unit_price')::NUMERIC
        )
        RETURNING purchase_item_id INTO v_purchase_item_id;

        -- Reinsert sold serials for this item (if any)
        INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
        SELECT v_purchase_item_id, serial_number, in_stock
        FROM tmp_sold_units
        WHERE purchase_item_id = v_purchase_item_id;

        -- Insert new serials from JSON (skip sold ones)
        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM PurchaseUnits WHERE purchase_item_id = v_purchase_item_id AND serial_number = v_serial
            ) THEN
                INSERT INTO PurchaseUnits(purchase_item_id, serial_number, in_stock)
                VALUES (v_purchase_item_id, v_serial, TRUE);

                INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
                VALUES (v_item_id, v_serial, 'IN', 'PurchaseInvoice', p_invoice_id, 1);
            END IF;
        END LOOP;

        -- Accumulate total
        v_total := v_total + ((v_item->>'qty')::NUMERIC * (v_item->>'unit_price')::NUMERIC);
    END LOOP;

    -- ========================================================
    -- 6️⃣ Update total in Purchase Invoice
    -- ========================================================
    UPDATE PurchaseInvoices
    SET total_amount = v_total
    WHERE purchase_invoice_id = p_invoice_id;

    -- ========================================================
    -- 7️⃣ Rebuild journal entry
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
    v_amount    NUMERIC(14,4);
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
    amount numeric(14,4) NOT NULL,
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
    amount numeric(14,4) NOT NULL,
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
3	pbkdf2_sha256$1200000$mvVrQ0Eu8HeBIySSNm2PBw$yT7x2mFdxxqDhCVgHyqlnc/O/fLbJo5Imf5i2fHkhtA=	2026-01-17 18:02:29.725037+00	f	dubaiOffice				f	t	2025-12-09 14:35:42+00
2	pbkdf2_sha256$1200000$BUJHK6vNtJlrCuMQpstztc$hWijcN9qC3RkpbTTqWPI18AYSAtPiAy/+mpMc2M0TUs=	2026-01-19 12:20:30.699955+00	f	saqib				f	t	2025-12-09 14:31:16.44303+00
1	pbkdf2_sha256$1200000$RXhGhMVbAN430kGibRWclp$0bFixmZrJQUORkd30ou1uNsx/1vRuA7fHI83CR9zly0=	2026-01-21 15:44:13.55321+00	t	financee_admin				t	t	2025-12-09 14:12:23.026824+00
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
29	EXP-0013	SHIPPING AND CLEARANCE	Expense	\N	2026-01-10 13:16:12.886828
30	EXP-0014	MEGATOP AUSTRALIA SHIPPING	Expense	\N	2026-01-19 17:10:49.4531
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
6xumg4g41i513wgbjb5rtsgogcwvpuzq	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vdSyZ:183EfxftcId3RMpodd4RjQahctV5rOKc055Um9YRg8Y	2026-01-21 12:49:23.761949+00
slvs18bpyc5acipk6r68gekuqhoial7n	.eJxVjMsOgjAUBf-la9NA6YO4dO83NPdVi5o2obAi_ruQsNDtmZmzqQjrkuPaZI4Tq6sy6vK7IdBLygH4CeVRNdWyzBPqQ9EnbfpeWd630_07yNDyXqdB7CA0ovQ4Wk8sBrwjFwKgQZdAKHQBxIPx5Mj03jLvZuJkOwdBfb4VyTkc:1vfglc:MCkDkrPu50jBXqSxquPK64zEFel9o2uyTx2QipRfFKs	2026-01-27 15:57:12.087623+00
3vgutp79yrruq3hqvinn61f17iplmeig	.eJxVjMsOgjAUBf-la9NA6YO4dO83NPdVi5o2obAi_ruQsNDtmZmzqQjrkuPaZI4Tq6sy6vK7IdBLygH4CeVRNdWyzBPqQ9EnbfpeWd630_07yNDyXqdB7CA0ovQ4Wk8sBrwjFwKgQZdAKHQBxIPx5Mj03jLvZuJkOwdBfb4VyTkc:1vgkDv:3crBRkPFdNO4idF0rs5QJNbWBwWTa04ybj0xKT5nfT4	2026-01-30 13:50:47.245577+00
cfkwpbmkjgtkrwikerz3p5w6x0yli2qk	.eJxVjMsOwiAUBf-FtSEg5eXSvd9A7gOkamhS2pXx322TLnQ7M-e8RYJ1qWnteU4ji4sw4vTLEOiZ2y74Ae0-SZraMo8o90QetsvbxPl1Pdq_gwq9buuQs_KunIsFKpCjDRpBBYQwRFRxAK09KTZEGwnkDYPzaAAjR20di88XAyA4lg:1vhAd3:3XJgYg668U93RfhZasRoMkQVJqjq1-W3oum82OFocVE	2026-01-31 18:02:29.727437+00
25qjdgp7jzkzgwo1trlw44dfemmrviww	.eJxVjEEOwiAQRe_C2pABCi0u3fcMZIYZbNXQpLQr491Nky50-997_60S7tuU9iZrmlldlVGX340wP6UegB9Y74vOS93WmfSh6JM2PS4sr9vp_h1M2KajJsjiBwc0uD7GUrrIPVsHGQQBQxkMBUfeW0RXuhA5ZgYjJQfbkXj1-QLwJzhf:1viaNR:EgzdZTf_kfxD98kIz9BgGgmpYLSVNRJtPb5drKWF47Q	2026-02-04 15:44:13.556142+00
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
161	DJI OSMO POCKET 3 CREATOR COMBO		0.00	\N	Camera	DJI	2026-01-09 16:15:20.284885	2026-01-09 16:15:20.284885
162	DUAL SENSE EDGE WIRELESS CONTROLLER		0.00	\N	Gaming Controller	Sony	2026-01-12 13:37:28.880265	2026-01-12 13:37:28.880265
163	MACBOOK AIR M4 15 16 GB, 512 GB		0.00	\N	MacBook	Apple	2026-01-17 13:04:14.529854	2026-01-17 13:04:14.529854
164	STEAM DECK 256 GB		0.00	\N	Gaming Console	Valve	2026-01-17 13:06:32.884573	2026-01-17 13:06:32.884573
165	STEAM DECK OLED 1 TB		0.00	\N	Gaming Console	Valve	2026-01-17 13:07:19.919849	2026-01-17 13:07:19.919849
166	STEAM DECK OLED 512 GB		0.00	\N	Gaming Console	Valve	2026-01-17 13:07:49.993488	2026-01-17 13:07:49.993488
167	IPAD AIR M3 11 (W) 128 GB		0.00	\N	Ipad	Apple	2026-01-17 13:17:54.337022	2026-01-17 13:17:54.337022
168	IPAD PRO M5 13 (W) 512 GB		0.00	\N	Ipad	Apple	2026-01-17 13:19:24.05314	2026-01-17 13:19:24.05314
169	IPHONE 16 PRO MAX 512 GB		0.00	\N	Mobile Phone	Apple	2026-01-17 13:21:02.455012	2026-01-17 13:21:02.455012
170	META VANGUARD		0.00	\N	Smart Glasses	Meta	2026-01-17 13:38:57.308768	2026-01-17 13:38:57.308768
171	AIRPODS PRO 2		0.00	\N	Airpods	Apple	2026-01-17 13:39:41.716066	2026-01-17 13:39:41.716066
172	STARLINK MINI		1050.00	\N	Electronics	Starlink 	2026-01-19 12:03:57.914352	2026-01-19 12:03:57.914352
173	IPAD PRO M5 13 (W) 256 GB	Dubai	1200.00	\N	Electronics	Apple	2026-01-20 13:02:50.496252	2026-01-20 13:02:50.496252
174	GALAXY TAB S10+ (5G)		0.00	\N	Tab	Samsung	2026-01-21 10:31:40.755277	2026-01-21 10:31:40.755277
\.


--
-- Data for Name: journalentries; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.journalentries (journal_id, entry_date, description, date_created) FROM stdin;
1	2026-01-04	Opening Balance for GIFT ACCOUNT	2026-01-04 15:38:18.8546
2	2026-01-04	Purchase Invoice 1	2026-01-04 15:42:21.678551
3	2026-01-04	Purchase Invoice 2	2026-01-04 15:42:21.692909
4	2026-01-04	Purchase Invoice 3	2026-01-04 15:44:33.93609
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
124	2026-01-07	Opening Balance for WAHEED BHAI	2026-01-07 15:26:22.98745
125	2026-01-07	Purchase Invoice 75	2026-01-07 15:28:08.550714
126	2026-01-07	Opening Balance for OWAIS HOUSTON	2026-01-07 15:55:44.881265
127	2026-01-07	Purchase Invoice 76	2026-01-07 15:56:22.764816
129	2026-01-08	Purchase Invoice 78	2026-01-08 09:01:02.485063
130	2026-01-08	Purchase Invoice 79	2026-01-08 09:08:57.876091
131	2026-01-05	Purchase Invoice 80	2026-01-08 14:11:03.685037
132	2026-01-05	Purchase Invoice 81	2026-01-08 14:15:14.649235
133	2026-01-08	Sale Invoice 1	2026-01-08 15:48:18.704672
134	2026-01-08	Sale Invoice 2	2026-01-08 15:48:18.715356
135	2026-01-08	Sale Invoice 3	2026-01-08 15:48:18.718899
136	2026-01-08	Sale Invoice 4	2026-01-08 15:48:18.721873
137	2026-01-08	Sale Invoice 5	2026-01-08 15:52:58.528036
138	2026-01-08	Sale Invoice 6	2026-01-08 16:09:26.178065
139	2026-01-08	Sale Invoice 7	2026-01-08 16:18:27.095922
140	2026-01-08	Sale Invoice 8	2026-01-09 13:30:53.533113
141	2026-01-08	Sale Invoice 9	2026-01-09 13:34:12.373214
143	2026-01-08	Sale Invoice 10	2026-01-09 13:43:09.35116
144	2026-01-09	Sale Invoice 12	2026-01-09 14:12:30.007796
146	2026-01-08	Sale Invoice 13	2026-01-09 14:20:27.866434
147	2026-01-08	Sale Invoice 14	2026-01-09 14:21:17.940202
148	2026-01-09	Sale Invoice 15	2026-01-09 14:27:52.181083
150	2026-01-08	Sale Invoice 17	2026-01-09 14:40:29.194573
151	2026-01-08	Sale Invoice 18	2026-01-09 14:43:45.384582
152	2026-01-08	Sale Invoice 19	2026-01-09 14:46:41.773201
153	2026-01-09	Sale Invoice 20	2026-01-09 14:50:58.199463
154	2026-01-08	Sale Invoice 21	2026-01-09 14:54:11.863896
155	2026-01-08	Sale Invoice 22	2026-01-09 14:56:48.674896
158	2026-01-08	Sale Invoice 24	2026-01-09 15:16:47.431197
160	2026-01-09	Sale Invoice 27	2026-01-09 15:28:02.763274
161	2026-01-08	Sale Invoice 28	2026-01-09 15:31:16.077963
162	2026-01-08	Sale Invoice 29	2026-01-09 15:34:38.570262
163	2026-01-08	Sale Invoice 30	2026-01-09 15:36:10.394453
165	2026-01-08	Sale Invoice 32	2026-01-09 15:44:03.749986
167	2026-01-08	Sale Invoice 34	2026-01-09 15:54:12.141482
169	2026-01-08	Sale Invoice 36	2026-01-09 16:00:18.559281
170	2026-01-08	Sale Invoice 37	2026-01-09 16:05:11.019644
171	2026-01-05	Purchase Invoice 6	2026-01-09 16:11:42.26849
173	2026-01-05	Purchase Invoice 82	2026-01-09 16:20:44.556728
174	2026-01-09	Sale Invoice 38	2026-01-09 16:25:09.146762
175	2026-01-08	Sale Invoice 39	2026-01-09 16:33:35.995383
176	2026-01-08	Sale Invoice 40	2026-01-09 16:34:47.338244
177	2026-01-08	Sale Invoice 41	2026-01-09 16:36:17.126877
178	2026-01-08	Sale Invoice 42	2026-01-09 16:37:35.871792
180	2026-01-09	Sale Invoice 26	2026-01-09 17:05:55.065656
181	2026-01-08	37615 cash paid to ahsan Mohsin jimmy	2026-01-10 11:53:33.158313
183	2026-01-08	6970 cash received power play	2026-01-10 11:55:05.643216
184	2026-01-08	Hammali	2026-01-10 11:55:28.924895
185	2026-01-08	Sale Invoice 43	2026-01-10 11:59:42.216685
186	2026-01-08	1740 cash received Fiji electronics	2026-01-10 12:00:03.495489
187	2026-01-08	Paid to ahsan Mohsin	2026-01-10 12:00:48.638446
188	2026-01-08	Caryy 52,000 PKR @79 For karachi Office Pieces to Waqas Aslam	2026-01-10 12:03:57.288467
189	2026-01-08	Caryy 52,000 PKR @79 For karachi Office Pieces to Waqas Aslam from Abdul Rehman	2026-01-10 12:04:31.716656
190	2026-01-08	37680 cash received from easy buy	2026-01-10 12:05:45.705735
191	2026-01-08	50,000 paid to ahsan Mohsin jimmy	2026-01-10 12:06:15.462593
192	2026-01-08	Cash received Khaira jaani bur Dubai 71,400	2026-01-10 12:06:57.072922
193	2026-01-08	7,260 cash received from BBC	2026-01-10 12:07:32.319435
194	2026-01-08	25040 cash received from power play	2026-01-10 12:08:07.425558
195	2026-01-08	11350 cash received century store	2026-01-10 12:08:38.563087
196	2026-01-08	17,700 cash received metro delux	2026-01-10 12:09:09.870876
197	2026-01-08	Hammali	2026-01-10 12:09:36.632213
198	2026-01-08	50,000 paid to ahsan Mohsin jimmy	2026-01-10 12:10:51.054475
199	2026-01-08	1450 cash received century store	2026-01-10 12:11:23.469767
200	2026-01-08	29150 cash received phone 4 u	2026-01-10 12:11:51.617068
201	2026-01-08	20400 cash received from metro by abdul wasay	2026-01-10 12:12:17.402666
202	2026-01-08	15 packing material osmo pocket 3	2026-01-10 12:12:45.164903
203	2026-01-08	100,000 cash received from ahsan cba	2026-01-10 12:13:14.77815
204	2026-01-08	19800 cash received from Hanzala laptop	2026-01-10 12:14:10.594311
205	2026-01-08	62000 cash received ahsan cba	2026-01-10 12:14:37.091616
206	2026-01-08	Hammali	2026-01-10 12:15:02.457879
207	2026-01-08	155000 paid to ahsan cba bank deposit	2026-01-10 12:15:38.161202
208	2026-01-08	16830 paid ahsan cba bank deposit	2026-01-10 12:16:03.914423
209	2026-01-08	50,000 paid to Mudassir Wajahat	2026-01-10 12:16:31.739877
210	2026-01-08	To Anwer for Karachi Office Software 12 months payment from AR Meezan	2026-01-10 12:17:59.354552
211	2026-01-08	To Anwer for Karachi Office Software 12 months payment from AR Meezan	2026-01-10 12:18:16.511423
212	2026-01-08	Packing Material	2026-01-10 12:18:51.31607
213	2026-01-08	Hammali	2026-01-10 12:19:10.09946
214	2026-01-08	128550 paid bank  deposit ahsan cba	2026-01-10 12:19:43.813636
215	2026-01-08	30 packing material	2026-01-10 12:20:03.937552
216	2026-01-08	5500 paid bank deposit ahsan cba	2026-01-10 12:20:24.928278
217	2026-01-08	20k PKR from AR Meezan to TAYYAB ANDLEEB (Faisal Bhai)	2026-01-10 12:21:40.280949
218	2026-01-08	20k PKR from AR Meezan to TAYYAB ANDLEEB (Faisal Bhai)	2026-01-10 12:21:57.27772
219	2026-01-08	11k PKR from AR Meezan to KHADIJA FAISAL (Faisal Bhai)	2026-01-10 12:22:47.981239
220	2026-01-08	11k PKR from AR Meezan to KHADIJA FAISAL (Faisal Bhai)	2026-01-10 12:23:04.567851
221	2026-01-08	Hammali	2026-01-10 12:23:23.061029
222	2026-01-08	sealing machine	2026-01-10 12:23:47.598885
223	2026-01-08	100,000 cash received phone 4 u	2026-01-10 12:25:12.525469
224	2026-01-08	9676 cash received all digital	2026-01-10 12:25:43.85413
225	2026-01-08	275 paid Abdul rehman(Waseem )	2026-01-10 12:29:52.727733
226	2026-01-08	50000 paid to ahsan mohsin jimmy	2026-01-10 12:30:14.14033
228	2026-01-08	22500 cash received from phone for u	2026-01-10 12:31:06.344256
229	2026-01-08	97900 paid to ahsan  cba cash deposit bank	2026-01-10 12:31:39.486467
230	2026-01-08	10350 cash received al oha	2026-01-10 12:32:13.578334
231	2026-01-08	27750 cash received hamza one touch	2026-01-10 12:32:43.699754
232	2026-01-08	7200 cash received from all digital	2026-01-10 12:33:12.048472
233	2026-01-08	7040 cash received from all digital	2026-01-10 12:34:54.924713
234	2026-01-08	7500 cash received from metro deluxe	2026-01-10 12:35:24.589915
235	2026-01-08	Hammali	2026-01-10 12:35:55.829026
236	2026-01-08	122,000 cash received central system	2026-01-10 12:37:01.604676
237	2026-01-08	36,700 received from NY 	2026-01-10 13:02:10.598109
238	2026-01-08	Discount to NY	2026-01-10 13:02:31.673349
239	2026-01-08	Discount to NY	2026-01-10 13:02:51.482592
241	2026-01-08	Cash received all digital 5000	2026-01-10 13:11:59.94835
242	2026-01-08	17,268 cash paid to mutee ur rehman for FedEx charges world mart For Owais 2 Shipments  #886948403809 1930.02 $ * 3.674,  #887197830975 2,769.99 * 3,674	2026-01-10 13:12:13.076652
243	2026-01-08	5000 received from faisal self for daily visa deposit	2026-01-10 13:14:20.659484
244	2026-01-08	34800 cash received phone 4 u	2026-01-10 13:15:03.589534
245	2026-01-08	20,000 cash paid to turbo freight	2026-01-10 13:16:37.379337
246	2026-01-08	12200 cash paid to Mudassir Wajahat	2026-01-10 13:17:11.531288
247	2026-01-08	8550 cash received from asad Bsamart	2026-01-10 13:21:08.756249
248	2026-01-08	13680 cash received from farhan alhamd	2026-01-10 13:22:02.373029
249	2026-01-08	12480 cash received from Asad Bsmart	2026-01-10 13:23:18.308004
250	2026-01-08	39500 cash received from humair karachi	2026-01-10 13:23:44.357321
251	2026-01-08	7950 cash received from sabeer sama almal	2026-01-10 13:24:11.622641
252	2026-01-08	Hammali	2026-01-10 13:25:31.614508
255	2026-01-08	Abdul Rafay Salary for the month of December	2026-01-10 13:30:28.31084
256	2026-01-08	5000 out to faisal self	2026-01-10 13:30:55.985601
257	2026-01-08	2630 cash received from phone 4U	2026-01-10 13:32:14.077503
258	2026-01-08	22500 cash received from metro delux	2026-01-10 13:32:35.934412
259	2026-01-08	Hammali	2026-01-10 13:33:08.069064
260	2026-01-08	100,000 paid to Mudassir	2026-01-10 13:33:52.932958
261	2026-01-08	2800 cash received from shapoor	2026-01-10 13:34:23.328195
262	2026-01-08	Hammali	2026-01-10 13:35:14.282897
263	2026-01-08	50430 cash received from Zeeshan dysomac	2026-01-10 13:35:53.44112
264	2026-01-08	50430 cash paid to ahsan Mohsin jimmy	2026-01-10 13:36:32.857635
265	2026-01-08	6860 cash received from shaid karachi	2026-01-10 13:38:04.104266
266	2026-01-08	4200 cash received from metro delux	2026-01-10 13:38:23.559611
267	2026-01-08	4200 cash received from digi hub	2026-01-10 13:38:41.956333
269	2026-01-08	1600 cash received from bsmart	2026-01-10 13:41:39.166927
270	2026-01-08	43,000 cash received from Asad Bsmart	2026-01-10 13:42:29.410012
272	2026-01-08	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)	2026-01-10 13:46:41.149091
273	2026-01-08	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)	2026-01-10 13:46:53.518445
274	2026-01-10	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)	2026-01-10 13:47:59.794721
275	2026-01-10	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)	2026-01-10 13:48:13.968511
276	2026-01-08	Paid to ahsan Mohsin	2026-01-10 13:50:11.281889
277	2026-01-08	122000 paid to ahsan Mohsin jimmy	2026-01-10 13:53:29.786485
278	2026-01-08	65000 paid to ahsan Mohsin jimmy	2026-01-10 13:53:52.666561
279	2026-01-10	Opening Balance for ANUS MOTA	2026-01-10 13:58:26.708963
280	2026-01-08	Sale Invoice 44	2026-01-10 13:59:59.266664
281	2026-01-08	Sale Invoice 45	2026-01-10 14:01:55.188918
282	2026-01-08	205K PKR, from Cell Arena to ON POint IT Services(MUDASSIR)	2026-01-10 14:03:18.633106
283	2026-01-08	205K PKR, from Cell Arena to ON POint IT Services(MUDASSIR)	2026-01-10 14:03:40.954805
284	2026-01-08	From HASEEB AHMED to ON Point IT Services (MUDASSIR)	2026-01-10 14:04:46.375486
285	2026-01-08	From HASEEB AHMED to ON Point IT Services (MUDASSIR)	2026-01-10 14:05:03.859211
286	2026-01-08	Sale Invoice 46	2026-01-10 14:19:52.988639
287	2026-01-08	Sale Invoice 47	2026-01-10 14:22:43.957872
289	2026-01-08	Sale Invoice 49	2026-01-10 14:32:21.611488
290	2026-01-08	Sale Invoice 48	2026-01-10 14:37:37.021822
291	2026-01-08	from Ahmed Hassan 224 to ON Point IT Services(Mudassir)	2026-01-10 14:38:55.650588
292	2026-01-08	from Ahmed Hassan 224 to ON Point IT Services(Mudassir)	2026-01-10 14:39:20.89246
294	2026-01-08	150K PKR from Faizan Ground (muhammad Ahsan) to ON Point It services( MUdassir)	2026-01-10 14:42:41.03914
295	2026-01-08	150K PKR from Faizan Ground (muhammad Ahsan) to ON Point It services( MUdassir)	2026-01-10 14:43:00.114849
296	2026-01-08	200,000 PKR from haseeb 137 to AR Meezan 	2026-01-10 14:44:14.560684
297	2026-01-08	200,000 PKR from haseeb 137 to AR Meezan 	2026-01-10 14:44:32.271205
298	2026-01-08	Sale Invoice 50	2026-01-10 14:46:51.67825
299	2026-01-08	Sale Invoice 51	2026-01-10 14:48:58.281093
300	2026-01-08	from Faizan Ground (Muhammad Ahsan) to On point IT Services (Mudassir)	2026-01-10 14:50:28.47004
301	2026-01-08	from Faizan Ground (Muhammad Ahsan) to On point IT Services (Mudassir)	2026-01-10 14:50:47.639042
302	2026-01-08	Sale Invoice 52	2026-01-10 14:57:28.165552
303	2026-01-08	Received from Anus paid to Ahmed 224	2026-01-10 15:03:23.627941
304	2026-01-08	Received from Anus paid to Ahmed 224	2026-01-10 15:04:57.310439
305	2026-01-08	from Ahmed Hassan CBA to AR Meezan 	2026-01-10 15:06:36.594315
306	2026-01-08	from Ahmed Hassan CBA to AR Meezan 	2026-01-10 15:07:16.266927
307	2026-01-08	136,000 PKR From sumair pasta to AR Meezan	2026-01-10 15:09:09.551794
308	2026-01-08	136,000 PKR From sumair pasta to AR Meezan	2026-01-10 15:09:31.358428
309	2026-01-08	189,000 PKR from Haseeb 137 to AR Meezan	2026-01-10 15:12:15.024877
310	2026-01-08	189,000 PKR from Haseeb 137 to AR Meezan	2026-01-10 15:12:36.29542
312	2026-01-08	115000 PKR from Faizan Ground to On point IT services ( Mudassir)	2026-01-10 15:14:07.642991
313	2026-01-08	115000 PKR from Faizan Ground to On point IT services ( Mudassir)	2026-01-10 15:14:40.480212
314	2026-01-06	 50,000 AUD@2.4180 paid through Ahsan Mohsin to Waheed Bhai	2026-01-10 15:21:18.395534
315	2026-01-06	 50,000 AUD@2.4180 paid through Ahsan Mohsin to Waheed Bhai	2026-01-10 15:21:37.468463
316	2026-01-09	 99,000 AUD @2.4378 from Ahsan Mohsin to Waheed bhai	2026-01-10 15:27:45.586781
317	2026-01-09	 99,000 AUD @2.4378 from Ahsan Mohsin to Waheed bhai	2026-01-10 15:28:04.551835
318	2026-01-05	20 cash out to glass buff	2026-01-10 15:34:14.761306
320	2026-01-05	7100 cash received from metro delux 01-01-2026	2026-01-10 15:41:29.556263
321	2026-01-05	500 cash received from adeel dubai	2026-01-10 15:42:00.550368
322	2026-01-05	2800 cash received from shapoor	2026-01-10 15:43:31.148565
323	2026-01-05	12500 cash received from digi hub	2026-01-10 15:44:39.817006
324	2026-01-05	150 paid to Abubaker	2026-01-10 15:45:12.517352
325	2026-01-05	500 paid to Abubaker	2026-01-10 15:59:34.468503
326	2026-01-08	Sale Invoice 53	2026-01-10 16:05:17.404368
327	2026-01-08	17330 cash received from hamza makhdum	2026-01-10 16:12:40.53053
331	2026-01-10	Purchase Invoice 83	2026-01-12 13:54:11.503843
332	2026-01-09	Sale Invoice 54	2026-01-12 14:04:43.660247
334	2026-01-09	Sale Invoice 56	2026-01-12 14:10:21.991543
335	2026-01-09	Sale Invoice 57	2026-01-12 14:12:33.574286
336	2026-01-09	Sale Invoice 58	2026-01-12 14:15:01.727995
337	2026-01-09	Sale Invoice 59	2026-01-12 14:18:07.199599
338	2026-01-09	Sale Invoice 60	2026-01-12 14:22:51.759548
340	2026-01-12	Sales Return 1	2026-01-12 14:26:09.848258
341	2026-01-09	Sale Invoice 62	2026-01-12 14:29:26.845081
342	2026-01-09	Sale Invoice 63	2026-01-12 14:32:20.152304
343	2026-01-09	Sale Invoice 64	2026-01-12 14:36:20.992596
344	2026-01-10	Sale Invoice 65	2026-01-12 14:39:51.864026
345	2026-01-09	3730 cash received from fahad Lahore \r\n20 discount box damage	2026-01-12 14:43:27.120844
346	2026-01-09	20 discount box damage Fahad Lahore	2026-01-12 14:44:00.287736
347	2026-01-09	20 discount box damage Fahad Lahore	2026-01-12 14:44:14.465798
348	2026-01-09	2800 cash received from shapoor	2026-01-12 14:45:07.02094
349	2026-01-09	7500 cash received from all digital	2026-01-12 14:45:30.497061
350	2026-01-09	20190 cash received from CTN	2026-01-12 14:45:53.208924
351	2026-01-09	100,000 to Jimmy	2026-01-12 14:46:39.435308
352	2026-01-09	9500 cash received from shaid karachi \r\n	2026-01-12 14:47:59.030551
353	2026-01-09	Commision	2026-01-12 14:49:05.387728
354	2026-01-09	2680 cash received from ahsan ali	2026-01-12 14:49:33.679346
355	2026-01-09	60000 cash out to wajahat 	2026-01-12 14:50:03.21557
356	2026-01-10	5590 cash received from asad Bsmart	2026-01-12 14:50:27.609022
357	2026-01-10	3000 cash received from metro delux	2026-01-12 14:50:59.771473
358	2026-01-10	27920 cas received from digi hub	2026-01-12 14:51:21.546555
359	2026-01-10	31385 cash recived from sajjad atari fariya	2026-01-12 14:52:01.118603
360	2026-01-10	50,000 paid to ahsan Mohsin jimmy	2026-01-12 14:52:43.938342
361	2026-01-10	5 out to jimmy	2026-01-12 14:53:09.522919
363	2026-01-10	Received from century storr	2026-01-12 14:54:07.360287
368	2026-01-08	10,080 received from Zaidi gujranwala	2026-01-12 15:36:40.4233
369	2026-01-08	Cash received by Abubaker NO message in any Fianace Group	2026-01-12 15:48:23.562857
370	2026-01-11	Sale Invoice 67	2026-01-12 15:55:26.074668
371	2026-01-12	Sale Invoice 68	2026-01-12 15:59:03.04829
372	2026-01-12	5000 cash received from Ariya mobail	2026-01-12 16:00:38.615534
373	2026-01-12	5715 cash received from shaid karachi	2026-01-12 16:01:03.556119
375	2026-01-08	27350 cash received from bilal karachi	2026-01-12 16:29:52.136722
376	2026-01-08	7000 cash received from metro delux	2026-01-12 16:30:07.42419
377	2026-01-08	47,630 cash received Raad Al Madina	2026-01-12 16:30:20.697678
378	2026-01-12	Sale Invoice 70	2026-01-13 12:19:26.408038
379	2026-01-12	Sale Invoice 71	2026-01-13 12:28:28.908955
380	2026-01-13	Sale Invoice 55	2026-01-13 12:32:02.968113
381	2026-01-12	700 Aed out viza expanse by AR hand	2026-01-13 12:33:25.507816
382	2026-01-12	27750 cash recived from digi hub by Abubaker	2026-01-13 12:34:06.75983
383	2026-01-13	70,000 USD @3.595 to Owais HT through Ahsan Mohsin (Dec-28-2025)	2026-01-13 12:47:23.672287
384	2026-01-13	70,000 USD @3.595 to Owais HT through Ahsan Mohsin (Dec-28-2025)	2026-01-13 12:48:01.645561
385	2026-01-13	 10,000 USD to Owais HOUSTON@3.595 through Ahsan Mohsin (jan-08-2026)	2026-01-13 12:52:44.501271
386	2026-01-13	 10,000 USD to Owais HOUSTON@3.595 through Ahsan Mohsin (jan-08-2026)	2026-01-13 12:53:38.303678
387	2026-01-13	20,000 USD to Owais HOUSTON @3.595 through Ahsan Mohsin (jan-09-2026)	2026-01-13 12:55:11.309011
388	2026-01-13	20,000 USD to Owais HOUSTON @3.595 through Ahsan Mohsin (jan-09-2026)	2026-01-13 12:55:45.412217
389	2026-01-08	Purchase Invoice 77	2026-01-13 13:05:52.839235
390	2026-01-09	Purchase Invoice 84	2026-01-13 13:06:48.685721
391	2026-01-08	2,000 PKR cash received from Haseeb 137 out to Ahmed 224	2026-01-13 13:12:09.525421
392	2026-01-08	2,000 PKR cash received from Haseeb 137 out to Ahmed 224	2026-01-13 13:12:26.900099
393	2026-01-08	120,000 PKR from Waqas Abdul Wahab to AR Meezan A/C	2026-01-13 13:13:45.098649
394	2026-01-08	120,000 PKR from Waqas Abdul Wahab to AR Meezan A/C	2026-01-13 13:14:04.187089
395	2026-01-08	Sale Invoice 73	2026-01-13 13:16:56.435549
396	2026-01-08	100,000 PKR Waqas MT(KULSUM ABDUL WAHAB) to AR Meezan A/C	2026-01-13 13:19:19.880603
398	2026-01-08	100,000 PKR Waqas MT(KULSUM ABDUL WAHAB) to AR Meezan A/C	2026-01-13 13:19:51.98332
400	2026-01-09	131,000 PKR from Faizan GR (MUHAMMAD AHSAN) to Mudassir(ON POINT IT SERVICES) Reference #516046	2026-01-13 13:22:53.620484
401	2026-01-09	131,000 PKR from Faizan GR (MUHAMMAD AHSAN) to Mudassir(ON POINT IT SERVICES) Reference #516046	2026-01-13 13:23:16.542347
402	2026-01-12	Sale Invoice 74	2026-01-13 13:26:51.269534
403	2026-01-12	73,000 PKR from Waqas MT( KULSUM ABDUL WAHAB) to AR Meezan A/C	2026-01-13 13:28:10.379594
404	2026-01-12	73,000 PKR from Waqas MT( KULSUM ABDUL WAHAB) to AR Meezan A/C	2026-01-13 13:28:27.624052
405	2026-01-13	Sale Invoice 75	2026-01-13 13:31:00.925398
406	2026-01-13	Cash received from Kumail Customer out to Ahsan 224	2026-01-13 13:31:38.39315
407	2026-01-13	Cash received from Kumail Customer out to Ahsan 224	2026-01-13 13:31:54.391237
408	2026-01-05	Purchase Invoice 61	2026-01-14 12:12:19.841542
409	2026-01-13	Sale Invoice 76	2026-01-14 12:14:45.226055
411	2026-01-13	Sale Invoice 77	2026-01-14 12:27:37.08907
412	2026-01-13	45,350 total cash received from Shahzad Mughal	2026-01-14 13:01:43.089364
413	2026-01-13	45,350 paid to ahsan mohsin jimmy	2026-01-14 13:03:18.33692
414	2026-01-13	Cash out to Faisal Bhai Message by Abdul Rafay	2026-01-14 13:04:03.724375
415	2026-01-13	Cash received Rakesh 4900	2026-01-14 13:05:11.82834
416	2026-01-14	35000 cash out to wajahat Message by Abubaker	2026-01-14 13:05:55.226964
417	2026-01-14	Sale Invoice 78	2026-01-14 13:18:15.398603
418	2026-01-14	900 cash received from ahsan ali sheikh	2026-01-14 13:18:50.71692
419	2026-01-14	60 hammali	2026-01-14 13:24:16.227301
420	2026-01-16	from AR Meezan to ARSH IMRAN (Karachi Office Internet) EXP (jan-06-2026)	2026-01-16 12:56:58.758066
421	2026-01-16	from AR Meezan to ARSH IMRAN (Karachi Office Internet) EXP (jan-06-2026)	2026-01-16 12:57:26.063968
422	2026-01-16	from AR Meezan to MEHREEN (Faisal Bhai) (jan-10-2026)	2026-01-16 12:59:39.58355
423	2026-01-16	from AR Meezan to MEHREEN (Faisal Bhai) (jan-10-2026)	2026-01-16 13:00:19.847326
424	2026-01-16	from AR Meezan to JAS TRAVELS (office exp saudi travelling exp ammi baba) jan-07-2026	2026-01-16 13:02:28.122879
425	2026-01-16	from AR Meezan to JAS TRAVELS (office exp saudi travelling exp ammi baba) jan-07-2026	2026-01-16 13:02:44.646528
426	2026-01-16	from AR Meezan to CONNECT (Karachi Office Rent ) (jan-10-2026)	2026-01-16 13:06:41.000814
427	2026-01-16	from AR Meezan to CONNECT (Karachi Office Rent ) (jan-10-2026)	2026-01-16 13:06:58.051599
428	2026-01-16	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)	2026-01-16 13:09:00.319449
429	2026-01-16	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)	2026-01-16 13:09:24.825557
430	2026-01-16	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)	2026-01-16 13:09:54.334361
431	2026-01-16	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)	2026-01-16 13:10:07.828386
432	2026-01-16	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)	2026-01-16 13:11:32.223677
433	2026-01-16	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)	2026-01-16 13:11:45.867331
434	2026-01-16	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)	2026-01-16 13:12:04.125451
435	2026-01-16	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)	2026-01-16 13:12:15.853559
436	2026-01-16	124,516 PKR from AR Meezan to Saqib Meezan for (Maaz,Saqib,Hassan) Salary (jan-05-2026)	2026-01-16 13:16:57.676429
437	2026-01-16	124,516 PKR from AR Meezan to Saqib Meezan for (Maaz,Saqib,Hassan) Salary (jan-05-2026)	2026-01-16 13:17:17.595746
438	2026-01-16	20,484 from AR Meezan to Saqib Meezan Karachi Office Expense Amount (jan-05-2026)	2026-01-16 13:18:52.781792
439	2026-01-16	20,484 from AR Meezan to Saqib Meezan Karachi Office Expense Amount (jan-05-2026)	2026-01-16 13:19:07.154337
441	2026-01-14	Purchase Invoice 85	2026-01-16 13:42:04.522401
442	2026-01-14	Sale Invoice 79	2026-01-16 13:54:57.271046
443	2026-01-14	Sale Invoice 80	2026-01-16 14:03:52.271755
444	2026-01-14	Sale Invoice 81	2026-01-16 14:06:38.025599
446	2026-01-14	Sale Invoice 83	2026-01-16 14:52:06.975934
448	2026-01-14	Sale Invoice 85	2026-01-16 15:18:30.030001
449	2026-01-15	Sale Invoice 86	2026-01-16 15:31:47.307393
451	2026-01-15	Sale Invoice 88	2026-01-16 15:47:18.682388
452	2026-01-14	10800 cash received from fahad Lahore	2026-01-16 16:07:44.017638
454	2026-01-14	3400 cash recived from faraz GVT\r\n	2026-01-16 16:08:44.342515
455	2026-01-14	3880 cash received from faraz GVT	2026-01-16 16:09:19.44437
456	2026-01-14	10200 cash received from all digital	2026-01-16 16:09:55.847462
457	2026-01-14	41620 cash received from bilal G.49	2026-01-16 16:10:26.950891
458	2026-01-14	Cash received Hezartoo	2026-01-16 16:11:06.746949
459	2026-01-14	2950 cash received from Asad Bsmart	2026-01-16 16:11:40.282044
460	2026-01-15	Paid to ahsan Mohsin	2026-01-16 16:12:16.459538
461	2026-01-15	30,000 cash received from abuzar dubai	2026-01-16 16:12:46.034508
462	2026-01-15	38340 cash received from CTN	2026-01-16 16:13:37.534234
463	2026-01-15	30,800 cash received from abuzar Dubai	2026-01-16 16:14:28.552682
464	2026-01-15	73,320 cash received from qamar Sudani	2026-01-16 16:15:08.529775
465	2026-01-15	163320 cash paid to ahsan Mohsin jimmy	2026-01-16 16:16:21.557837
466	2026-01-15	70,000 pkr @79 from AR Meezan to BIA'S , waqas Aslam Carry KArachi office expense 	2026-01-16 16:21:39.670476
467	2026-01-15	70,000 pkr @79 from AR Meezan to BIA'S , waqas Aslam Carry KArachi office expense 	2026-01-16 16:22:16.561373
468	2026-01-15	11,000 pkr @79 from AR Meexan to Aman Anwer , aman carry karachi office expense 	2026-01-16 16:26:56.828369
469	2026-01-15	11,000 pkr @79 from AR Meexan to Aman Anwer , aman carry karachi office expense 	2026-01-16 16:27:21.987098
470	2026-01-15	11,400 cash received from fahad Lahore	2026-01-16 16:28:24.043045
472	2026-01-15	4600 cash recived \r\n1050 balance  msg by Abubaker 	2026-01-16 16:30:13.471326
474	2026-01-15	Cash counting machine	2026-01-16 16:34:23.069092
475	2026-01-15	153832 pkr @79 from SHY Traders ( Sajjad Attari ) to AR Meezan 	2026-01-16 16:37:28.088292
476	2026-01-15	153832 pkr @79 from SHY Traders ( Sajjad Attari ) to AR Meezan 	2026-01-16 16:39:11.985567
477	2026-01-15	5160 cash received from younus phone 4U	2026-01-16 16:41:49.119188
479	2026-01-15	17 pro I cloud removed \r\n300 charges	2026-01-16 16:45:50.565441
480	2026-01-15	26820 cash received raaad al Madina	2026-01-16 16:49:09.309454
481	2026-01-15	1050 cash received from fahad Lahore	2026-01-16 16:51:44.341474
483	2026-01-17	Purchase Invoice 86	2026-01-17 13:42:23.577929
484	2026-01-14	Sale Invoice 89	2026-01-17 14:45:34.793499
485	2026-01-14	Sale Invoice 90	2026-01-17 14:52:08.096127
486	2026-01-15	Sale Invoice 91	2026-01-17 14:56:22.785489
487	2026-01-15	Sale Invoice 92	2026-01-17 15:05:30.845006
488	2026-01-15	Sale Invoice 93	2026-01-17 15:10:47.308627
489	2026-01-15	Sale Invoice 94	2026-01-17 15:14:50.006941
491	2026-01-15	Sale Invoice 96	2026-01-17 15:21:31.62981
492	2026-01-15	Sale Invoice 97	2026-01-17 15:27:48.164118
493	2026-01-15	Sale Invoice 87	2026-01-17 15:53:55.870454
494	2026-01-15	Sale Invoice 84	2026-01-17 15:54:24.177426
495	2026-01-17	Sale Invoice 98	2026-01-19 11:17:20.780916
496	2026-01-15	Purchase Invoice 87	2026-01-19 12:01:58.741437
497	2026-01-17	Purchase Invoice 88	2026-01-19 12:09:09.904573
498	2026-01-08	Sale Invoice 23	2026-01-19 12:22:49.854164
499	2026-01-15	Purchase Invoice 89	2026-01-19 12:23:29.748252
500	2026-01-16	Sale Invoice 99	2026-01-19 12:24:40.52767
501	2026-01-17	Sale Invoice 100	2026-01-19 12:25:33.366416
502	2026-01-17	Sale Invoice 101	2026-01-19 12:27:02.543901
503	2026-01-08	Sale Invoice 33	2026-01-19 12:39:44.421242
504	2026-01-17	Sale Invoice 102	2026-01-19 12:39:56.941786
505	2026-01-17	Sale Invoice 103	2026-01-19 12:41:07.334818
506	2026-01-09	Sale Invoice 61	2026-01-19 12:46:06.180575
507	2026-01-17	Sale Invoice 104	2026-01-19 13:08:03.724155
508	2026-01-08	Sale Invoice 66	2026-01-19 13:15:12.232145
510	2026-01-10	Sale Invoice 69	2026-01-19 13:19:46.293327
511	2026-01-08	Sale Invoice 31	2026-01-19 13:22:42.299256
512	2026-01-08	Sale Invoice 16	2026-01-19 13:23:41.372253
513	2026-01-17	Sale Invoice 106	2026-01-19 13:41:58.301312
515	2026-01-18	Sale Invoice 107	2026-01-19 14:05:15.395915
519	2026-01-08	CR: 2.4285 |-> 17 pro max 256 silver officeworks Castle Hills -2- @2010$  @4881.285AED | 17 pro max 256 silver officeworks Northmead -2- @2010$ @4881.285AED | Starlink Standard Kit Adil Bhai -2- @398$ @966.543AED | PS5-DISK-BUNDLE Adil Bhai -8- @629$ @1527.5265AED |  PS5-DISK-BUNDLE Adil Bhai -2- @629$ @1527.5265AED | PS5 Digital Bundle Adil Bhai -4- @477$ @1158.3945AED | PS5 Disc Bundle Adil Bai Harvey norman Alex Pending Delivery Adil Bhai -2- @629$ @1527.5265AED | 	2026-01-19 14:38:16.383913
593	2026-01-19	40 cash out tu ZTK IP box charges	2026-01-21 11:58:31.476551
594	2026-01-19	250 JBL Flip 7 given to Office	2026-01-21 12:03:47.101532
595	2026-01-19	9700 received from shapoor	2026-01-21 12:04:19.906704
596	2026-01-19	Cash received from digi hub 31050	2026-01-21 12:04:53.568228
597	2026-01-19	Paid to ahsan mohsin	2026-01-21 12:06:09.502515
598	2026-01-21	Adjustment Entry For Humair Karachi Ledger for balancing the 10-dec s17 pro max sale	2026-01-21 12:06:17.461263
520	2026-01-08	CR: 2.4285 |-> 17 pro max 256 silver officeworks Castle Hills -2- @2010$  @4881.285AED | 17 pro max 256 silver officeworks Northmead -2- @2010$ @4881.285AED | Starlink Standard Kit Adil Bhai -2- @398$ @966.543AED | PS5-DISK-BUNDLE Adil Bhai -8- @629$ @1527.5265AED |  PS5-DISK-BUNDLE Adil Bhai -2- @629$ @1527.5265AED | PS5 Digital Bundle Adil Bhai -4- @477$ @1158.3945AED | PS5 Disc Bundle Adil Bai Harvey norman Alex Pending Delivery Adil Bhai -2- @629$ @1527.5265AED | 	2026-01-19 14:39:07.896594
523	2026-01-08	CR: 2.4285 |-> Iphone 17 pro max 256 Silver Office Works Northmead -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works WetheillPark -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED | Iphone 17 pro max 256 Silver Officeworks Auburn\r\n-2- @2010$ @4881.285AED\r\n	2026-01-19 15:18:37.229201
524	2026-01-08	CR: 2.4285 |-> Iphone 17 pro max 256 Silver Office Works Northmead -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works WetheillPark -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED | Iphone 17 pro max 256 Silver Officeworks Auburn\r\n-2- @2010$ @4881.285AED	2026-01-19 15:19:05.134192
525	2026-01-17	Sale Invoice 109	2026-01-19 15:59:04.075787
530	2026-01-19	Sale Invoice 111	2026-01-19 16:46:42.304788
531	2026-01-19	Swiss Tech Business name renew fees Expense in Australia	2026-01-19 17:03:23.081731
532	2026-01-19	Swiss Tech Business name renew fees Expense in Australia	2026-01-19 17:03:55.800537
534	2026-01-19	Commsison paid Adil bhai in Australia 510 AUD	2026-01-19 17:05:28.218845
537	2026-01-19	Shipping Charges Megatop Sydeney Expense 11,423.05 AUD @2.4285	2026-01-19 17:15:50.569356
538	2026-01-19	Sale Invoice 112	2026-01-20 10:32:09.58199
539	2026-01-19	Sale Invoice 114	2026-01-20 10:35:16.27054
540	2026-01-19	Sale Invoice 115	2026-01-20 10:36:54.448178
542	2026-01-19	Sale Invoice 116	2026-01-20 13:29:50.358818
544	2026-01-20	Sale Invoice 118	2026-01-20 13:51:26.565556
545	2026-01-19	Purchase Invoice 93	2026-01-20 13:58:33.544728
546	2026-01-19	Purchase Invoice 92	2026-01-20 14:27:02.408912
547	2026-01-19	Sale Invoice 119	2026-01-20 15:03:11.278637
549	2026-01-16	MW2V3 MacBook Cash received From SHAHZAD 5250	2026-01-20 15:13:13.962954
551	2026-01-19	Shipping Charges Megatop Sydeney Expense 11,423.05 AUD @2.4285	2026-01-20 15:13:38.243513
554	2026-01-16	4400 cash recieved from asad BSmart ( asad Link )	2026-01-20 15:18:37.652547
555	2026-01-16	Cash paid to Abubaker 300	2026-01-20 15:19:57.067608
556	2026-01-13	13-12-25, Cash recieved from Humair 3620	2026-01-20 15:21:07.506019
557	2026-01-16	12250 Cash received from hmb	2026-01-20 15:22:07.984113
558	2026-01-16	6900 Cash received from digi hub	2026-01-20 15:23:32.310033
559	2026-01-16	18615 cash received from sajjad atari fariya	2026-01-20 15:24:26.77659
560	2026-01-20	Sale Invoice 120	2026-01-20 15:36:01.510475
561	2026-01-15	CR : 2.4285 |-> Iphone 17 pro max 256 Silver Harvey Norman Fyshwick Pending Delivery/ 27-12 Deposit Update -7- @2.197$ @5335.4145AED | DJI Mavic 4 Pro DJI Macquarie Park Pending Collection -8- @2490$ @6046.965AED | DJI Mic 3 combo DJI Macquarie Park Pending Collection -25- @415$ @1007.8275AED | Mac Book Pro M5 24/1TB JBHIFI Bankstown -3- @2690$ @6532.665AED | Apple Air Pods 4 ANC JBHIFI Bankstown -3- @259$ @628.9815AED | DJI Mini 4K combo JBHIFI Bankstown\r\n-3- @519$ @1260.3915AED | DJI Mic 3 combo JBHIFI Bankstown -3- @419$ @1017.5415AED\r\n\r\n\r\n\r\n\r\n\r\n\r\n	2026-01-20 16:35:19.251955
562	2026-01-15	CR : 2.4285 |-> Iphone 17 pro max 256 Silver Harvey Norman Fyshwick Pending Delivery/ 27-12 Deposit Update -7- @2.197$ @5335.4145AED | DJI Mavic 4 Pro DJI Macquarie Park Pending Collection -8- @2490$ @6046.965AED | DJI Mic 3 combo DJI Macquarie Park Pending Collection -25- @415$ @1007.8275AED | Mac Book Pro M5 24/1TB JBHIFI Bankstown -3- @2690$ @6532.665AED | Apple Air Pods 4 ANC JBHIFI Bankstown -3- @259$ @628.9815AED | DJI Mini 4K combo JBHIFI Bankstown\r\n-3- @519$ @1260.3915AED | DJI Mic 3 combo JBHIFI Bankstown -3- @419$ @1017.5415AED	2026-01-20 16:35:45.69926
563	2026-01-13	CR : 2.12 | -> G7X Mark III  Noel Leeming Abdul K -10- @1449$ @3071.88AED\r\n	2026-01-20 16:39:10.285764
564	2026-01-13	CR : 2.12 | -> G7X Mark III  Noel Leeming Abdul K -10- @1449$ @3071.88AED\r\n	2026-01-20 16:39:44.827861
565	2026-01-19	Commission paid Adil bhai in Australia 510 AUD	2026-01-20 16:41:57.283241
566	2026-01-15	Shipping Charges CT Freight Melbourne @7980$\r\n	2026-01-20 16:43:31.807224
568	2026-01-15	Shipping Charges CT Freight Melbourne @7980$\r\n	2026-01-20 16:46:39.057543
569	2026-01-13	Shipping Charges CT Freight NZ Shipping Expense\r\n	2026-01-20 16:48:28.112784
570	2026-01-13	Shipping Charges CT Freight NZ Shipping Expense\r\n	2026-01-20 16:49:00.36606
571	2026-01-15	Sale Invoice 95	2026-01-21 10:27:05.277866
572	2026-01-08	Purchase Invoice 94	2026-01-21 10:32:23.290091
573	2026-01-08	Sale Invoice 121	2026-01-21 10:34:07.294185
574	2026-01-16	Paid to ahsan Mohsin jimmy	2026-01-21 10:51:33.520303
575	2026-01-16	Paid to ahsan Mohsin jimmy 45000 (12-01-26)	2026-01-21 10:52:16.45514
576	2026-01-16	50,000 paid to Mudassir (w)	2026-01-21 10:53:14.372271
577	2026-01-17	17290 cash received from Raad Al Madina	2026-01-21 11:03:34.326318
578	2026-01-17	7 customer refreshment	2026-01-21 11:04:00.207079
579	2026-01-17	15000 received from Adeel Bhai Karachi	2026-01-21 11:04:27.335527
580	2026-01-17	17,340 cash received from NY	2026-01-21 11:04:46.163771
581	2026-01-17	57000 cash paid to ahsan Mohsin jimmy	2026-01-21 11:05:10.086024
582	2026-01-17	3,150 cash received from Saeed	2026-01-21 11:05:33.384831
583	2026-01-17	1320 cash received from Raad Al Madina	2026-01-21 11:06:15.096163
584	2026-01-17	Hammali	2026-01-21 11:07:19.089414
585	2026-01-17	35 porter deilivery charges to Adeel	2026-01-21 11:07:39.817217
586	2026-01-17	30 hammali to games Hezartoo	2026-01-21 11:07:56.049673
587	2026-01-17	13205 cash paid to hmb	2026-01-21 11:08:26.772347
588	2026-01-16	All pending Invoice commission paid till today 1500 to Shahzad Mughal	2026-01-21 11:12:46.683506
589	2026-01-16	50 commisssion paid against Macbook to shehzad Mughal 	2026-01-21 11:13:11.451044
590	2026-01-15	20060 cash received from muzambil pindi	2026-01-21 11:56:01.041225
591	2026-01-15	6800 cash received from farhan turkish	2026-01-21 11:56:31.200651
592	2026-01-19	2600 cash received from hamza	2026-01-21 11:58:02.507406
599	2026-01-21	Adjustment Entry For Humair Karachi Ledger for balancing the 10-dec s17 pro max sale	2026-01-21 12:06:42.634492
600	2026-01-19	11-12-25 \r\nCash received from ahsan cba 18000	2026-01-21 12:06:52.147398
601	2026-01-19	6560 cash received from faraz GVT	2026-01-21 12:07:40.621421
602	2026-01-20	39330 cash received from CTN	2026-01-21 12:08:51.626792
603	2026-01-20	120000\r\ncash received from ahsan cba	2026-01-21 12:10:03.99624
604	2026-01-20	25000 cashvreceived from ahsan cba	2026-01-21 12:10:42.152323
605	2026-01-20	140,000 cash paid to ahsan cba(bank deposit)	2026-01-21 12:11:45.288382
606	2026-01-20	5000 cash received from Zeeshan dysomac	2026-01-21 12:12:15.047136
607	2026-01-20	10 hammali	2026-01-21 12:13:39.81015
608	2026-01-20	05-1- 26\r\n5800 cash received ultra deal	2026-01-21 12:14:21.472306
609	2026-01-20	13800 cash received from abuzar Dubai	2026-01-21 12:14:57.898111
610	2026-01-20	57200 cash paid to ahsan mohsin jimmy	2026-01-21 12:15:32.034062
611	2026-01-20	6450 cash received from fahad Lahore	2026-01-21 12:16:18.781665
612	2026-01-20	102000 pkr @79 from AR Meezan to BIA's, Waqas Aslam Carry karachi Office expense	2026-01-21 12:21:25.011852
613	2026-01-20	102000 pkr @79 from AR Meezan to BIA's, Waqas Aslam Carry karachi Office expense	2026-01-21 12:21:41.036037
615	2026-01-20	Cash received from Faraz gvt 10,000	2026-01-21 12:25:56.970558
616	2026-01-20	1600 cash received from hamza one tech	2026-01-21 12:26:20.803436
617	2026-01-20	13800 cash received from digi hub	2026-01-21 12:26:40.437375
618	2026-01-20	11600 cash received from abuzar	2026-01-21 12:27:02.737287
619	2026-01-20	2400 cash received from Adeel Karachi	2026-01-21 12:27:21.544862
620	2026-01-20	33585 cash paid to ahsan mohsin jimmy	2026-01-21 12:29:36.510003
621	2026-01-20	20,000 cash received from ahsan cba (Waseem)	2026-01-21 12:31:19.290634
622	2026-01-20	30000 cash out to Wajahat	2026-01-21 12:32:34.156545
623	2026-01-20	35 cash received for porter delivery from Adeel Karachi	2026-01-21 12:34:33.887629
624	2026-01-20	25 cash out to shaid commission	2026-01-21 12:36:14.937134
625	2026-01-20	650 cash received from assd links	2026-01-21 12:36:51.876289
626	2026-01-21	2930 cash received from bilal	2026-01-21 12:38:27.31374
627	2026-01-21	250000pkr @79 from AR Meezan to Fast Travels Services, Faisal Bhai 	2026-01-21 12:46:20.560093
628	2026-01-21	250000pkr @79 from AR Meezan to Fast Travels Services, Faisal Bhai 	2026-01-21 12:46:44.267648
629	2026-01-21	15000 pkr @79 from AR Meezan to Saqib Ali Khan 	2026-01-21 13:02:07.961732
630	2026-01-21	15000 pkr @79 from AR Meezan to Saqib Ali Khan 	2026-01-21 13:02:45.717774
631	2026-01-21	pkr 12024 @79 From Abdul Rehman Meezan to Khi Office Electric Bill , Karachi Office Expense	2026-01-21 13:08:33.827348
632	2026-01-21	pkr 12024 @79 From Abdul Rehman Meezan to Khi Office Electric Bill , Karachi Office Expense	2026-01-21 13:09:16.426595
633	2026-01-21	1450 cash received from digital game	2026-01-21 13:38:57.241906
634	2026-01-21	20,000 cash paid to Mudassir (Wajahat)	2026-01-21 13:39:29.055954
636	2026-01-20	Sale Invoice 117	2026-01-21 13:49:33.928586
637	2026-01-20	Sale Invoice 122	2026-01-21 13:58:03.42765
638	2026-01-20	Sale Invoice 123	2026-01-21 14:01:54.146155
639	2026-01-20	Sale Invoice 124	2026-01-21 14:05:07.97855
640	2026-01-21	Sale Invoice 125	2026-01-21 14:11:49.688659
641	2026-01-21	80 hammali u loading Perth shipment	2026-01-21 14:41:14.930285
643	2026-01-21	Sale Invoice 127	2026-01-21 15:50:46.691874
644	2026-01-21	Sale Invoice 128	2026-01-21 15:52:37.134583
645	2026-01-21	10 hammali	2026-01-21 15:53:57.758675
646	2026-01-21	700 cash received from faraz GVT	2026-01-21 15:54:45.474561
647	2026-01-21	3450 cash received from faraz GVT	2026-01-21 15:55:15.303033
648	2026-01-21	15 hammali	2026-01-21 15:55:53.695252
649	2026-01-21	300000PKR @79 FROM AR MEEZAN TO ANWAR SERVICES (PRIVATE) ,received from AR out to FB	2026-01-21 16:29:08.25198
650	2026-01-21	300000PKR @79 FROM AR MEEZAN TO ANWAR SERVICES (PRIVATE) ,received from AR out to FB	2026-01-21 16:29:51.312663
651	2026-01-22	Megatop Shipping invoices total amount for the month of december	2026-01-22 09:42:46.591167
652	2026-01-22	Megatop Shipping invoices total amount for the month of december	2026-01-22 09:43:32.573848
655	2026-01-20	17,700 cash received from rehan ONTEL, Nh ya shahzad atari khi sae received sae krne hein	2026-01-22 10:32:05.345817
656	2026-01-21	9,960 cash received central system	2026-01-22 10:33:57.704907
657	2026-01-21	6400 cash revived from hamza one tech	2026-01-22 10:34:30.780591
658	2026-01-22	3400 cash received from faraz GVT	2026-01-22 10:35:34.127024
659	2026-01-22	30 hammali	2026-01-22 10:36:07.711609
660	2026-01-22	56,025 received from phone 4 u	2026-01-22 10:36:50.186801
662	2026-01-22	7195 paid to hmb	2026-01-22 10:40:42.079568
663	2026-01-22	3100 cash received from asad links	2026-01-22 10:41:27.7723
665	2026-01-22	Sale Invoice 129	2026-01-22 11:21:11.182129
666	2026-01-22	Sale Invoice 130	2026-01-22 11:24:55.695106
667	2026-01-22	Sale Invoice 131	2026-01-22 11:35:03.850657
668	2026-01-15	pkr 150,000 @79 from Muhammad Ahsan to On Point It services(Mudassir) , Faizan Ground	2026-01-22 11:47:59.586507
669	2026-01-15	pkr 150,000 @79 from Muhammad Ahsan to On Point It services(Mudassir) , Faizan Ground	2026-01-22 11:48:28.705134
671	2026-01-15	pkr 2000 @79 , 2K Cash Out to Moshin Software Samsung Z Flip FRP	2026-01-22 11:52:24.366965
672	2026-01-16	pkr 128,000 @79 , from Muhammad Ahsan To On Point IT Services , Faizan Ground	2026-01-22 11:54:32.506755
674	2026-01-17	pkr 310,000 @79 , from Huzaifa (7500) - Abdullah (300000) - Huzaifa (2500) to AR Meezan,  by Ahmed Star City	2026-01-22 12:00:31.431516
675	2026-01-17	pkr 310,000 @79 , from Huzaifa (7500) - Abdullah (300000) - Huzaifa (2500) to AR Meezan,  by Ahmed Star City	2026-01-22 12:01:05.053291
676	2026-01-20	205,000 pkr @79 , from Muhammad Areeb Batla to On Point IT Services ( Mudassir ) , By Faizan Ground	2026-01-22 12:03:59.103075
677	2026-01-20	205,000 pkr @79 , from Muhammad Areeb Batla to On Point IT Services ( Mudassir ) , By Faizan Ground	2026-01-22 12:04:29.863113
683	2026-01-20	pkr 155,000 @79 , from Zeeshan to AR Meezan through RAAST , By Zeeshan FARIYA	2026-01-22 12:16:49.644679
685	2026-01-21	150,000 pkr @79 , By Ali Raza to AR MEezan , by Zeeshan Fariya	2026-01-22 12:19:34.284542
689	2026-01-21	Sale Invoice 132	2026-01-22 12:56:50.211883
695	2026-01-22	Purchase Invoice 98	2026-01-22 13:14:44.041247
696	2026-01-22	Sale Invoice 133	2026-01-22 13:20:02.886221
697	2026-01-22	Sale Invoice 134	2026-01-22 13:22:05.385374
699	2026-01-22	Purchase Invoice 99	2026-01-22 13:47:13.523866
700	2026-01-21	Sale Invoice 126	2026-01-22 13:51:08.979833
734	2026-01-07	Purchase Invoice 74	2026-01-22 16:25:58.722396
735	2026-01-22	3,365.14 NZD @2.12 all invoices till december out to Shipping Exp	2026-01-22 16:33:28.676921
736	2026-01-22	3,365.14 NZD @2.12 all invoices till december out to Shipping Exp CT Freight Newzealand	2026-01-22 16:34:04.609738
737	2026-01-22	7980 AUD @ 2.4285 shipping invoices CT Freight Melbourne for december	2026-01-22 16:36:59.784734
738	2026-01-22	7980 AUD @ 2.4285 shipping invoices CT Freight Melbourne for december	2026-01-22 16:37:19.346086
739	2026-01-16	pkr 128,000 @79 , from Muhammad Ahsan To On Point IT Services , Faizan Ground	2026-01-23 11:29:38.500645
740	2026-01-21	150,000 pkr @79 , By Ali Raza to AR MEezan , by Zeeshan Fariya	2026-01-23 11:45:54.626066
741	2026-01-20	pkr 155,000 @79 , from Zeeshan to AR Meezan through RAAST , By Zeeshan FARIYA	2026-01-23 11:46:34.413394
742	2026-01-22	54900 paid to Ahsan Mohsin	2026-01-23 11:50:10.418399
743	2026-01-17	(09-1-26) 50,000 usd received from ahsan Mohsin @3.595	2026-01-23 12:19:57.829828
744	2026-01-17	(09-1-26) 50,000 usd paid to owais Houston through Ahsan Mohsin	2026-01-23 12:20:40.028859
745	2026-01-17	(14-1-26)  50,000 usd received from ahsan Mohsin @3.595 paid to Owais HT	2026-01-23 12:21:49.79796
746	2026-01-17	(14-1-26)  50,000 usd received from ahsan Mohsin @3.595 paid to Owais HT	2026-01-23 12:22:10.30068
747	2026-01-22	Sale Invoice 136	2026-01-23 12:37:38.61745
748	2026-01-22	Sale Invoice 137	2026-01-23 12:43:37.302242
750	2026-01-22	15 Hammali, 10 Hammali	2026-01-23 13:51:38.776786
751	2026-01-22	8200 cash received Shahzad mughal	2026-01-23 13:52:05.47443
752	2026-01-22	Paid to ahsan Mohsin ayaaz	2026-01-23 13:53:35.907833
753	2026-01-23	186000 cash received from golden vision	2026-01-23 13:54:54.371132
754	2026-01-23	20,000 out to ahsan cba amgt	2026-01-23 13:56:01.899528
755	2026-01-23	Ahsan Mohsin	2026-01-23 13:57:29.454848
756	2026-01-15	pkr 2000 @79 , 2K Cash Out to Moshin Software Samsung Z Flip FRP	2026-01-23 14:21:32.699143
757	2026-01-23	pkr 200,000 @79 , from M. Sumair Qadri to AR Rehman , by Sumair Pasta	2026-01-23 14:34:05.701863
758	2026-01-23	pkr 200,000 @79 , from M. Sumair Qadri to AR Rehman , by Sumair Pasta	2026-01-23 14:34:30.039674
759	2026-01-23	82,000 pkr @79 , From Muhammad Ahsan to AR Meezan , by Faizan Ground	2026-01-23 14:36:53.622602
760	2026-01-23	82,000 pkr @79 , From Muhammad Ahsan to AR Meezan , by Faizan Ground	2026-01-23 14:37:11.486568
761	2026-01-23	pkr 153,000 @79 , from Ali Raza to Abdul Rehman Meezan , by Zeeshan Fariya	2026-01-23 14:41:11.069986
762	2026-01-23	pkr 153,000 @79 , from Ali Raza to Abdul Rehman Meezan , by Zeeshan Fariya	2026-01-23 14:41:28.383611
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
1213	500	6	111	17400.00	0.00
1214	500	3	\N	0.00	17400.00
1215	500	4	\N	16680.00	0.00
1216	500	7	\N	0.00	16680.00
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
1245	508	6	99	16800.00	0.00
1246	508	3	\N	0.00	16800.00
85	43	7	\N	14.00	0.00
86	43	1	5	0.00	14.00
87	44	7	\N	5300.00	0.00
88	44	1	5	0.00	5300.00
89	45	7	\N	13882.00	0.00
90	45	1	5	0.00	13882.00
91	46	7	\N	9700.00	0.00
92	46	1	5	0.00	9700.00
1247	508	4	\N	15840.00	0.00
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
1217	501	6	54	5250.00	0.00
1218	501	3	\N	0.00	5250.00
131	66	7	\N	42351.50	0.00
132	66	1	6	0.00	42351.50
133	67	7	\N	21627.52	0.00
134	67	1	6	0.00	21627.52
135	68	7	\N	41390.40	0.00
136	68	1	6	0.00	41390.40
137	69	7	\N	2584.80	0.00
138	69	1	6	0.00	2584.80
1219	501	4	\N	1.00	0.00
1220	501	7	\N	0.00	1.00
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
1221	502	6	112	3150.00	0.00
1222	502	3	\N	0.00	3150.00
247	124	6	4	641854.00	0.00
248	124	2	\N	0.00	641854.00
249	125	7	\N	11970.00	0.00
250	125	1	4	0.00	11970.00
251	126	6	6	529604.00	0.00
252	126	2	\N	0.00	529604.00
253	127	7	\N	21895.65	0.00
254	127	1	6	0.00	21895.65
1223	502	4	\N	3060.00	0.00
1224	502	7	\N	0.00	3060.00
257	129	7	\N	81940.00	0.00
258	129	1	5	0.00	81940.00
259	130	7	\N	79860.00	0.00
260	130	1	5	0.00	79860.00
261	131	7	\N	9960.00	0.00
262	131	1	4	0.00	9960.00
263	132	7	\N	4490.00	0.00
264	132	1	4	0.00	4490.00
265	133	6	68	12500.00	0.00
266	133	3	\N	0.00	12500.00
267	133	4	\N	11970.00	0.00
268	133	7	\N	0.00	11970.00
269	134	6	69	7100.00	0.00
270	134	3	\N	0.00	7100.00
271	134	4	\N	5658.38	0.00
272	134	7	\N	0.00	5658.38
273	135	6	53	2800.00	0.00
274	135	3	\N	0.00	2800.00
275	135	4	\N	2566.00	0.00
276	135	7	\N	0.00	2566.00
277	136	6	26	37680.00	0.00
278	136	3	\N	0.00	37680.00
279	136	4	\N	37140.50	0.00
280	136	7	\N	0.00	37140.50
281	137	6	70	8300.00	0.00
282	137	3	\N	0.00	8300.00
283	137	4	\N	7820.00	0.00
284	137	7	\N	0.00	7820.00
285	138	6	71	29150.00	0.00
286	138	3	\N	0.00	29150.00
287	138	4	\N	29379.61	0.00
288	138	7	\N	0.00	29379.61
289	139	6	72	71400.00	0.00
290	139	3	\N	0.00	71400.00
291	139	4	\N	59765.00	0.00
292	139	7	\N	0.00	59765.00
293	140	6	73	7260.00	0.00
294	140	3	\N	0.00	7260.00
295	140	4	\N	5977.00	0.00
296	140	7	\N	0.00	5977.00
297	141	6	74	12800.00	0.00
298	141	3	\N	0.00	12800.00
299	141	4	\N	11869.00	0.00
300	141	7	\N	0.00	11869.00
1248	508	7	\N	0.00	15840.00
305	143	6	69	17700.00	0.00
306	143	3	\N	0.00	17700.00
307	143	4	\N	17808.00	0.00
308	143	7	\N	0.00	17808.00
309	144	6	69	20400.00	0.00
310	144	3	\N	0.00	20400.00
311	144	4	\N	18113.39	0.00
312	144	7	\N	0.00	18113.39
1285	519	5	\N	44422.00	0.00
1286	519	6	4	0.00	44422.00
1293	523	5	\N	87863.00	0.00
317	146	6	75	9676.00	0.00
318	146	3	\N	0.00	9676.00
319	146	4	\N	9735.04	0.00
320	146	7	\N	0.00	9735.04
321	147	6	76	5800.00	0.00
322	147	3	\N	0.00	5800.00
323	147	4	\N	6248.00	0.00
324	147	7	\N	0.00	6248.00
325	148	6	71	122500.00	0.00
326	148	3	\N	0.00	122500.00
327	148	4	\N	95519.50	0.00
328	148	7	\N	0.00	95519.50
333	150	6	78	27750.00	0.00
334	150	3	\N	0.00	27750.00
335	150	4	\N	21194.58	0.00
336	150	7	\N	0.00	21194.58
337	151	6	75	7200.00	0.00
338	151	3	\N	0.00	7200.00
339	151	4	\N	5658.38	0.00
340	151	7	\N	0.00	5658.38
341	152	6	75	5000.00	0.00
342	152	3	\N	0.00	5000.00
343	152	4	\N	3811.24	0.00
344	152	7	\N	0.00	3811.24
345	153	6	79	36750.00	0.00
346	153	3	\N	0.00	36750.00
347	153	4	\N	28584.30	0.00
348	153	7	\N	0.00	28584.30
349	154	6	71	34800.00	0.00
350	154	3	\N	0.00	34800.00
351	154	4	\N	33767.22	0.00
352	154	7	\N	0.00	33767.22
353	155	6	75	7040.00	0.00
354	155	3	\N	0.00	7040.00
355	155	4	\N	6748.60	0.00
356	155	7	\N	0.00	6748.60
1294	523	6	4	0.00	87863.00
1315	531	5	\N	253.00	0.00
1316	531	6	4	0.00	253.00
1333	539	6	68	13800.00	0.00
373	160	6	80	122000.00	0.00
374	160	3	\N	0.00	122000.00
375	160	4	\N	95520.50	0.00
376	160	7	\N	0.00	95520.50
1334	539	3	\N	0.00	13800.00
1335	539	4	\N	13410.52	0.00
1336	539	7	\N	0.00	13410.52
1225	503	6	49	47630.00	0.00
1226	503	3	\N	0.00	47630.00
365	158	6	69	7500.00	0.00
366	158	3	\N	0.00	7500.00
367	158	4	\N	7279.15	0.00
368	158	7	\N	0.00	7279.15
377	161	6	81	8550.00	0.00
378	161	3	\N	0.00	8550.00
379	161	4	\N	7800.00	0.00
380	161	7	\N	0.00	7800.00
381	162	6	82	13680.00	0.00
382	162	3	\N	0.00	13680.00
383	162	4	\N	13120.00	0.00
384	162	7	\N	0.00	13120.00
385	163	6	81	12480.00	0.00
386	163	3	\N	0.00	12480.00
387	163	4	\N	11400.00	0.00
388	163	7	\N	0.00	11400.00
393	165	6	83	7950.00	0.00
394	165	3	\N	0.00	7950.00
395	165	4	\N	8883.00	0.00
396	165	7	\N	0.00	8883.00
401	167	6	84	27350.00	0.00
402	167	3	\N	0.00	27350.00
403	167	4	\N	25440.00	0.00
404	167	7	\N	0.00	25440.00
409	169	6	68	4200.00	0.00
410	169	3	\N	0.00	4200.00
411	169	4	\N	3849.00	0.00
412	169	7	\N	0.00	3849.00
413	170	6	62	2.00	0.00
414	170	3	\N	0.00	2.00
415	170	4	\N	3055.50	0.00
416	170	7	\N	0.00	3055.50
417	171	7	\N	162.00	0.00
418	171	1	4	0.00	162.00
1227	503	4	\N	43494.00	0.00
1228	503	7	\N	0.00	43494.00
421	173	7	\N	23.00	0.00
422	173	1	4	0.00	23.00
423	174	6	69	25500.00	0.00
424	174	3	\N	0.00	25500.00
425	174	4	\N	15.00	0.00
426	174	7	\N	0.00	15.00
427	175	6	53	2800.00	0.00
428	175	3	\N	0.00	2800.00
429	175	4	\N	2566.00	0.00
430	175	7	\N	0.00	2566.00
431	176	6	52	6860.00	0.00
432	176	3	\N	0.00	6860.00
433	176	4	\N	6560.00	0.00
434	176	7	\N	0.00	6560.00
435	177	6	75	7500.00	0.00
436	177	3	\N	0.00	7500.00
437	177	4	\N	5745.60	0.00
438	177	7	\N	0.00	5745.60
439	178	6	69	4200.00	0.00
440	178	3	\N	0.00	4200.00
441	178	4	\N	3849.00	0.00
442	178	7	\N	0.00	3849.00
447	180	6	85	30200.00	0.00
448	180	3	\N	0.00	30200.00
449	180	4	\N	23820.25	0.00
450	180	7	\N	0.00	23820.25
451	181	1	16	37615.00	0.00
452	181	5	\N	0.00	37615.00
1273	515	6	113	3950.00	0.00
1274	515	3	\N	0.00	3950.00
455	183	5	\N	6970.00	0.00
456	183	6	46	0.00	6970.00
457	184	25	40	65.00	0.00
458	184	5	\N	0.00	65.00
459	185	6	86	1740.00	0.00
460	185	3	\N	0.00	1740.00
461	185	4	\N	1.00	0.00
462	185	7	\N	0.00	1.00
463	186	5	\N	1740.00	0.00
464	186	6	86	0.00	1740.00
465	187	1	16	59210.00	0.00
466	187	5	\N	0.00	59210.00
467	188	5	\N	658.00	0.00
468	188	6	11	0.00	658.00
469	189	22	37	658.00	0.00
470	189	5	\N	0.00	658.00
471	190	5	\N	37680.00	0.00
472	190	6	26	0.00	37680.00
473	191	1	16	50000.00	0.00
474	191	5	\N	0.00	50000.00
475	192	5	\N	71400.00	0.00
476	192	6	72	0.00	71400.00
477	193	5	\N	7260.00	0.00
478	193	6	73	0.00	7260.00
479	194	5	\N	25040.00	0.00
480	194	6	46	0.00	25040.00
481	195	5	\N	11350.00	0.00
482	195	6	74	0.00	11350.00
483	196	5	\N	17700.00	0.00
484	196	6	69	0.00	17700.00
485	197	25	40	15.00	0.00
486	197	5	\N	0.00	15.00
487	198	1	16	50000.00	0.00
488	198	5	\N	0.00	50000.00
489	199	5	\N	1450.00	0.00
490	199	6	74	0.00	1450.00
491	200	5	\N	29150.00	0.00
492	200	6	71	0.00	29150.00
493	201	5	\N	20400.00	0.00
1275	515	4	\N	3523.10	0.00
1276	515	7	\N	0.00	3523.10
1287	520	1	117	44422.00	0.00
1288	520	5	\N	0.00	44422.00
1295	524	1	117	87863.00	0.00
1296	524	5	\N	0.00	87863.00
1317	532	18	20	253.00	0.00
1318	532	5	\N	0.00	253.00
1337	540	6	53	9700.00	0.00
1338	540	3	\N	0.00	9700.00
1339	540	4	\N	9269.20	0.00
494	201	6	69	0.00	20400.00
495	202	25	40	15.00	0.00
496	202	5	\N	0.00	15.00
497	203	5	\N	100000.00	0.00
498	203	6	15	0.00	100000.00
499	204	5	\N	19800.00	0.00
500	204	6	33	0.00	19800.00
501	205	5	\N	62000.00	0.00
502	205	6	15	0.00	62000.00
503	206	25	40	30.00	0.00
504	206	5	\N	0.00	30.00
505	207	1	15	155000.00	0.00
506	207	5	\N	0.00	155000.00
507	208	1	15	16830.00	0.00
508	208	5	\N	0.00	16830.00
509	209	1	5	50000.00	0.00
510	209	5	\N	0.00	50000.00
511	210	5	\N	254.00	0.00
512	210	6	11	0.00	254.00
513	211	22	37	254.00	0.00
514	211	5	\N	0.00	254.00
515	212	25	40	60.00	0.00
516	212	5	\N	0.00	60.00
517	213	25	40	10.00	0.00
518	213	5	\N	0.00	10.00
519	214	1	15	128550.00	0.00
520	214	5	\N	0.00	128550.00
521	215	25	40	30.00	0.00
522	215	5	\N	0.00	30.00
523	216	1	15	5500.00	0.00
524	216	5	\N	0.00	5500.00
525	217	5	\N	254.00	0.00
526	217	6	11	0.00	254.00
527	218	1	10	254.00	0.00
528	218	5	\N	0.00	254.00
529	219	5	\N	140.00	0.00
530	219	6	11	0.00	140.00
531	220	1	10	140.00	0.00
532	220	5	\N	0.00	140.00
533	221	25	40	50.00	0.00
534	221	5	\N	0.00	50.00
535	222	25	40	90.00	0.00
536	222	5	\N	0.00	90.00
537	223	5	\N	100000.00	0.00
538	223	6	71	0.00	100000.00
539	224	5	\N	9676.00	0.00
540	224	6	75	0.00	9676.00
541	225	1	11	275.00	0.00
542	225	5	\N	0.00	275.00
543	226	1	16	50000.00	0.00
544	226	5	\N	0.00	50000.00
1229	504	6	79	17340.00	0.00
1230	504	3	\N	0.00	17340.00
547	228	5	\N	22500.00	0.00
548	228	6	71	0.00	22500.00
549	229	1	15	97900.00	0.00
550	229	5	\N	0.00	97900.00
551	230	5	\N	10350.00	0.00
552	230	6	77	0.00	10350.00
553	231	5	\N	27750.00	0.00
554	231	6	78	0.00	27750.00
555	232	5	\N	7200.00	0.00
556	232	6	75	0.00	7200.00
557	233	5	\N	7040.00	0.00
558	233	6	75	0.00	7040.00
559	234	5	\N	7500.00	0.00
560	234	6	69	0.00	7500.00
561	235	25	40	35.00	0.00
562	235	5	\N	0.00	35.00
563	236	5	\N	122000.00	0.00
564	236	6	80	0.00	122000.00
565	237	5	\N	36700.00	0.00
566	237	6	79	0.00	36700.00
567	238	5	\N	50.00	0.00
568	238	6	79	0.00	50.00
569	239	20	25	50.00	0.00
570	239	5	\N	0.00	50.00
1231	504	4	\N	17340.00	0.00
1232	504	7	\N	0.00	17340.00
573	241	5	\N	5000.00	0.00
574	241	6	75	0.00	5000.00
575	242	28	60	17268.00	0.00
576	242	5	\N	0.00	17268.00
577	243	5	\N	5000.00	0.00
578	243	6	10	0.00	5000.00
579	244	5	\N	34800.00	0.00
580	244	6	71	0.00	34800.00
581	245	29	87	20000.00	0.00
582	245	5	\N	0.00	20000.00
583	246	1	5	12200.00	0.00
584	246	5	\N	0.00	12200.00
585	247	5	\N	8550.00	0.00
586	247	6	81	0.00	8550.00
587	248	5	\N	13680.00	0.00
588	248	6	82	0.00	13680.00
589	249	5	\N	12480.00	0.00
590	249	6	81	0.00	12480.00
591	250	5	\N	39500.00	0.00
592	250	6	36	0.00	39500.00
593	251	5	\N	7950.00	0.00
594	251	6	83	0.00	7950.00
595	252	25	40	60.00	0.00
596	252	5	\N	0.00	60.00
1253	510	6	54	35150.00	0.00
1254	510	3	\N	0.00	35150.00
1255	510	4	\N	18035.00	0.00
1256	510	7	\N	0.00	18035.00
601	255	27	51	1000.00	0.00
602	255	5	\N	0.00	1000.00
603	256	1	10	5000.00	0.00
604	256	5	\N	0.00	5000.00
605	257	5	\N	2630.00	0.00
606	257	6	71	0.00	2630.00
607	258	5	\N	22500.00	0.00
608	258	6	69	0.00	22500.00
609	259	25	40	10.00	0.00
610	259	5	\N	0.00	10.00
611	260	1	5	100000.00	0.00
612	260	5	\N	0.00	100000.00
613	261	5	\N	2800.00	0.00
614	261	6	53	0.00	2800.00
615	262	25	40	10.00	0.00
616	262	5	\N	0.00	10.00
617	263	5	\N	50430.00	0.00
618	263	6	85	0.00	50430.00
619	264	1	16	50430.00	0.00
620	264	5	\N	0.00	50430.00
621	265	5	\N	6860.00	0.00
622	265	6	52	0.00	6860.00
623	266	5	\N	4200.00	0.00
624	266	6	69	0.00	4200.00
625	267	5	\N	4200.00	0.00
626	267	6	68	0.00	4200.00
1233	505	6	84	2930.00	0.00
1234	505	3	\N	0.00	2930.00
629	269	5	\N	1600.00	0.00
630	269	6	58	0.00	1600.00
631	270	5	\N	43000.00	0.00
632	270	6	81	0.00	43000.00
635	272	1	5	10127.00	0.00
636	272	5	\N	0.00	10127.00
637	273	5	\N	10127.00	0.00
638	273	6	50	0.00	10127.00
639	274	5	\N	1899.00	0.00
640	274	6	50	0.00	1899.00
641	275	1	5	1899.00	0.00
642	275	5	\N	0.00	1899.00
643	276	1	16	39705.00	0.00
644	276	5	\N	0.00	39705.00
645	277	1	16	122000.00	0.00
646	277	5	\N	0.00	122000.00
647	278	1	16	65000.00	0.00
648	278	5	\N	0.00	65000.00
649	279	6	89	2430.00	0.00
650	279	2	\N	0.00	2430.00
651	280	6	88	1722.00	0.00
652	280	3	\N	0.00	1722.00
653	280	4	\N	1400.00	0.00
654	280	7	\N	0.00	1400.00
655	281	6	90	2595.00	0.00
656	281	3	\N	0.00	2595.00
657	281	4	\N	4.00	0.00
658	281	7	\N	0.00	4.00
659	282	5	\N	2595.00	0.00
660	282	6	90	0.00	2595.00
661	283	1	5	2595.00	0.00
662	283	5	\N	0.00	2595.00
663	284	5	\N	1722.00	0.00
664	284	6	88	0.00	1722.00
665	285	1	5	1722.00	0.00
666	285	5	\N	0.00	1722.00
667	286	6	88	4950.00	0.00
668	286	3	\N	0.00	4950.00
669	286	4	\N	1942.60	0.00
670	286	7	\N	0.00	1942.60
671	287	6	91	3937.00	0.00
672	287	3	\N	0.00	3937.00
673	287	4	\N	3666.90	0.00
674	287	7	\N	0.00	3666.90
679	289	6	56	1722.00	0.00
680	289	3	\N	0.00	1722.00
681	289	4	\N	1400.00	0.00
682	289	7	\N	0.00	1400.00
683	290	6	92	1950.00	0.00
684	290	3	\N	0.00	1950.00
685	290	4	\N	1650.00	0.00
686	290	7	\N	0.00	1650.00
687	291	5	\N	1950.00	0.00
688	291	6	92	0.00	1950.00
689	292	1	5	1950.00	0.00
690	292	5	\N	0.00	1950.00
693	294	5	\N	1899.00	0.00
694	294	6	91	0.00	1899.00
695	295	1	5	1899.00	0.00
696	295	5	\N	0.00	1899.00
697	296	5	\N	2532.00	0.00
698	296	6	88	0.00	2532.00
699	297	1	11	2532.00	0.00
700	297	5	\N	0.00	2532.00
701	298	6	91	1659.00	0.00
702	298	3	\N	0.00	1659.00
703	298	4	\N	1438.00	0.00
704	298	7	\N	0.00	1438.00
705	299	6	91	1443.00	0.00
706	299	3	\N	0.00	1443.00
707	299	4	\N	1006.60	0.00
708	299	7	\N	0.00	1006.60
709	300	5	\N	2025.00	0.00
710	300	6	91	0.00	2025.00
711	301	1	5	2025.00	0.00
712	301	5	\N	0.00	2025.00
713	302	6	93	1494.00	0.00
714	302	3	\N	0.00	1494.00
715	302	4	\N	1222.30	0.00
716	302	7	\N	0.00	1222.30
717	303	5	\N	26.00	0.00
718	303	6	89	0.00	26.00
719	304	1	15	26.00	0.00
720	304	5	\N	0.00	26.00
721	305	5	\N	26.00	0.00
722	305	6	15	0.00	26.00
723	306	1	11	26.00	0.00
724	306	5	\N	0.00	26.00
725	307	5	\N	1722.00	0.00
726	307	6	56	0.00	1722.00
727	308	1	11	1722.00	0.00
728	308	5	\N	0.00	1722.00
729	309	5	\N	2393.00	0.00
730	309	6	88	0.00	2393.00
731	310	1	11	2393.00	0.00
732	310	5	\N	0.00	2393.00
735	312	5	\N	1456.00	0.00
736	312	6	91	0.00	1456.00
737	313	1	5	1456.00	0.00
738	313	5	\N	0.00	1456.00
739	314	5	\N	120900.00	0.00
740	314	6	16	0.00	120900.00
741	315	1	4	120900.00	0.00
742	315	5	\N	0.00	120900.00
743	316	5	\N	241342.00	0.00
744	316	6	16	0.00	241342.00
745	317	1	4	241342.00	0.00
746	317	5	\N	0.00	241342.00
747	318	25	40	20.00	0.00
748	318	5	\N	0.00	20.00
1235	505	4	\N	2700.00	0.00
1236	505	7	\N	0.00	2700.00
751	320	5	\N	7100.00	0.00
752	320	6	69	0.00	7100.00
753	321	5	\N	500.00	0.00
754	321	6	14	0.00	500.00
755	322	5	\N	2800.00	0.00
756	322	6	53	0.00	2800.00
757	323	5	\N	12500.00	0.00
758	323	6	68	0.00	12500.00
759	324	1	13	150.00	0.00
760	324	5	\N	0.00	150.00
761	325	1	13	500.00	0.00
762	325	5	\N	0.00	500.00
763	326	6	94	17330.00	0.00
764	326	3	\N	0.00	17330.00
765	326	4	\N	16056.00	0.00
766	326	7	\N	0.00	16056.00
767	327	5	\N	17330.00	0.00
768	327	6	94	0.00	17330.00
1257	511	6	36	39500.00	0.00
1258	511	3	\N	0.00	39500.00
1259	511	4	\N	36668.00	0.00
1260	511	7	\N	0.00	36668.00
775	331	7	\N	112919.80	0.00
776	331	1	6	0.00	112919.80
777	332	6	81	48590.00	0.00
778	332	3	\N	0.00	48590.00
779	332	4	\N	44793.98	0.00
780	332	7	\N	0.00	44793.98
1297	525	6	114	250.00	0.00
1298	525	3	\N	0.00	250.00
1299	525	4	\N	252.63	0.00
785	334	6	68	27920.00	0.00
786	334	3	\N	0.00	27920.00
787	334	4	\N	21843.57	0.00
788	334	7	\N	0.00	21843.57
789	335	6	95	3750.00	0.00
790	335	3	\N	0.00	3750.00
791	335	4	\N	3163.64	0.00
792	335	7	\N	0.00	3163.64
793	336	6	53	2800.00	0.00
794	336	3	\N	0.00	2800.00
795	336	4	\N	2566.00	0.00
796	336	7	\N	0.00	2566.00
797	337	6	96	20190.00	0.00
798	337	3	\N	0.00	20190.00
799	337	4	\N	18981.84	0.00
800	337	7	\N	0.00	18981.84
801	338	6	52	9490.00	0.00
802	338	3	\N	0.00	9490.00
803	338	4	\N	8620.00	0.00
804	338	7	\N	0.00	8620.00
809	340	3	\N	2.00	0.00
810	340	6	62	0.00	2.00
811	340	7	\N	3055.50	0.00
812	340	4	\N	0.00	3055.50
813	341	6	98	31385.00	0.00
814	341	3	\N	0.00	31385.00
815	341	4	\N	28868.34	0.00
816	341	7	\N	0.00	28868.34
817	342	6	69	7000.00	0.00
818	342	3	\N	0.00	7000.00
819	342	4	\N	6415.00	0.00
820	342	7	\N	0.00	6415.00
821	343	6	68	5700.00	0.00
822	343	3	\N	0.00	5700.00
823	343	4	\N	6007.40	0.00
824	343	7	\N	0.00	6007.40
825	344	6	74	2550.00	0.00
826	344	3	\N	0.00	2550.00
827	344	4	\N	2393.20	0.00
828	344	7	\N	0.00	2393.20
829	345	5	\N	3730.00	0.00
830	345	6	95	0.00	3730.00
831	346	5	\N	20.00	0.00
832	346	6	95	0.00	20.00
833	347	20	25	20.00	0.00
834	347	5	\N	0.00	20.00
835	348	5	\N	2800.00	0.00
836	348	6	53	0.00	2800.00
837	349	5	\N	7500.00	0.00
838	349	6	75	0.00	7500.00
839	350	5	\N	20190.00	0.00
840	350	6	96	0.00	20190.00
841	351	1	16	100000.00	0.00
842	351	5	\N	0.00	100000.00
843	352	5	\N	9500.00	0.00
844	352	6	52	0.00	9500.00
845	353	1	52	10.00	0.00
846	353	5	\N	0.00	10.00
847	354	5	\N	2680.00	0.00
848	354	6	97	0.00	2680.00
849	355	1	5	60000.00	0.00
850	355	5	\N	0.00	60000.00
851	356	5	\N	5590.00	0.00
852	356	6	81	0.00	5590.00
853	357	5	\N	3000.00	0.00
854	357	6	69	0.00	3000.00
855	358	5	\N	27920.00	0.00
856	358	6	68	0.00	27920.00
857	359	5	\N	31385.00	0.00
858	359	6	98	0.00	31385.00
859	360	1	16	50000.00	0.00
860	360	5	\N	0.00	50000.00
861	361	1	16	5.00	0.00
862	361	5	\N	0.00	5.00
1300	525	7	\N	0.00	252.63
865	363	1	74	2550.00	0.00
866	363	5	\N	0.00	2550.00
1327	537	1	120	27741.00	0.00
1328	537	5	\N	0.00	27741.00
1340	540	7	\N	0.00	9269.20
877	368	5	\N	10080.00	0.00
878	368	6	99	0.00	10080.00
879	369	5	\N	6720.00	0.00
880	369	6	99	0.00	6720.00
1343	542	6	104	6560.00	0.00
1344	542	3	\N	0.00	6560.00
1345	542	4	\N	1740.00	0.00
881	370	6	52	5715.00	0.00
882	370	3	\N	0.00	5715.00
883	370	4	\N	5700.00	0.00
884	370	7	\N	0.00	5700.00
885	371	6	100	5000.00	0.00
886	371	3	\N	0.00	5000.00
887	371	4	\N	3830.40	0.00
888	371	7	\N	0.00	3830.40
889	372	5	\N	5000.00	0.00
890	372	6	100	0.00	5000.00
891	373	5	\N	5715.00	0.00
892	373	6	52	0.00	5715.00
897	375	5	\N	27350.00	0.00
898	375	6	84	0.00	27350.00
899	376	5	\N	7000.00	0.00
900	376	6	69	0.00	7000.00
901	377	5	\N	47360.00	0.00
902	377	6	49	0.00	47360.00
903	378	6	68	16400.00	0.00
904	378	3	\N	0.00	16400.00
905	378	4	\N	15640.00	0.00
906	378	7	\N	0.00	15640.00
907	379	6	68	5650.00	0.00
908	379	3	\N	0.00	5650.00
909	379	4	\N	5569.70	0.00
910	379	7	\N	0.00	5569.70
911	380	6	81	2950.00	0.00
912	380	3	\N	0.00	2950.00
913	380	4	\N	1974.50	0.00
914	380	7	\N	0.00	1974.50
915	381	25	40	700.00	0.00
916	381	5	\N	0.00	700.00
917	382	5	\N	27750.00	0.00
918	382	6	68	0.00	27750.00
919	383	5	\N	251650.00	0.00
920	383	6	16	0.00	251650.00
921	384	1	6	251650.00	0.00
922	384	5	\N	0.00	251650.00
923	385	5	\N	35950.00	0.00
924	385	6	16	0.00	35950.00
925	386	1	6	35950.00	0.00
926	386	5	\N	0.00	35950.00
927	387	5	\N	71900.00	0.00
928	387	6	16	0.00	71900.00
929	388	1	6	71900.00	0.00
930	388	5	\N	0.00	71900.00
931	389	7	\N	109368.00	0.00
932	389	1	6	0.00	109368.00
933	390	7	\N	4536.00	0.00
934	390	1	2	0.00	4536.00
935	391	5	\N	26.00	0.00
936	391	6	88	0.00	26.00
937	392	1	15	26.00	0.00
938	392	5	\N	0.00	26.00
939	393	5	\N	1519.00	0.00
940	393	6	93	0.00	1519.00
941	394	1	11	1519.00	0.00
942	394	5	\N	0.00	1519.00
943	395	6	93	2215.00	0.00
944	395	3	\N	0.00	2215.00
945	395	4	\N	4.00	0.00
946	395	7	\N	0.00	4.00
947	396	5	\N	1266.00	0.00
948	396	6	93	0.00	1266.00
951	398	1	11	1266.00	0.00
952	398	5	\N	0.00	1266.00
955	400	1	5	1659.00	0.00
956	400	5	\N	0.00	1659.00
957	401	5	\N	1659.00	0.00
958	401	6	91	0.00	1659.00
959	402	6	91	3519.00	0.00
960	402	3	\N	0.00	3519.00
961	402	4	\N	3235.50	0.00
962	402	7	\N	0.00	3235.50
963	403	5	\N	924.00	0.00
964	403	6	93	0.00	924.00
965	404	1	11	924.00	0.00
966	404	5	\N	0.00	924.00
967	405	6	101	1747.00	0.00
968	405	3	\N	0.00	1747.00
969	405	4	\N	1400.00	0.00
970	405	7	\N	0.00	1400.00
971	406	5	\N	1747.00	0.00
972	406	6	101	0.00	1747.00
973	407	1	15	1747.00	0.00
974	407	5	\N	0.00	1747.00
975	408	7	\N	35982.00	0.00
976	408	1	6	0.00	35982.00
977	409	6	54	10200.00	0.00
978	409	3	\N	0.00	10200.00
979	409	4	\N	8628.00	0.00
980	409	7	\N	0.00	8628.00
985	411	6	103	4900.00	0.00
986	411	3	\N	0.00	4900.00
987	411	4	\N	3811.20	0.00
988	411	7	\N	0.00	3811.20
989	412	5	\N	45350.00	0.00
990	412	6	54	0.00	45350.00
991	413	1	16	45350.00	0.00
992	413	5	\N	0.00	45350.00
993	414	1	10	100.00	0.00
994	414	5	\N	0.00	100.00
995	415	5	\N	4900.00	0.00
996	415	6	103	0.00	4900.00
997	416	1	5	35000.00	0.00
998	416	5	\N	0.00	35000.00
999	417	6	97	900.00	0.00
1000	417	3	\N	0.00	900.00
1001	417	4	\N	4.00	0.00
1002	417	7	\N	0.00	4.00
1003	418	5	\N	900.00	0.00
1004	418	6	97	0.00	900.00
1005	419	25	40	60.00	0.00
1006	419	5	\N	0.00	60.00
1007	420	5	\N	64.00	0.00
1008	420	6	11	0.00	64.00
1009	421	22	37	64.00	0.00
1010	421	5	\N	0.00	64.00
1011	422	5	\N	380.00	0.00
1012	422	6	11	0.00	380.00
1013	423	1	10	380.00	0.00
1014	423	5	\N	0.00	380.00
1015	424	5	\N	2912.00	0.00
1016	424	6	11	0.00	2912.00
1017	425	25	40	2912.00	0.00
1018	425	5	\N	0.00	2912.00
1019	426	5	\N	937.00	0.00
1020	426	6	11	0.00	937.00
1021	427	22	37	937.00	0.00
1022	427	5	\N	0.00	937.00
1023	428	5	\N	2082.00	0.00
1024	428	6	11	0.00	2082.00
1025	429	5	\N	2082.00	0.00
1026	429	6	11	0.00	2082.00
1027	430	1	4	2082.00	0.00
1028	430	5	\N	0.00	2082.00
1029	431	1	4	2082.00	0.00
1030	431	5	\N	0.00	2082.00
1031	432	5	\N	1238.00	0.00
1032	432	6	11	0.00	1238.00
1033	433	5	\N	1238.00	0.00
1034	433	6	11	0.00	1238.00
1035	434	1	4	1238.00	0.00
1036	434	5	\N	0.00	1238.00
1037	435	1	4	1238.00	0.00
1038	435	5	\N	0.00	1238.00
1039	436	5	\N	1577.00	0.00
1040	436	6	11	0.00	1577.00
1041	437	27	51	1577.00	0.00
1042	437	5	\N	0.00	1577.00
1043	438	5	\N	260.00	0.00
1044	438	6	11	0.00	260.00
1045	439	22	37	260.00	0.00
1046	439	5	\N	0.00	260.00
1237	506	6	97	2680.00	0.00
1238	506	3	\N	0.00	2680.00
1049	441	7	\N	69380.00	0.00
1050	441	1	5	0.00	69380.00
1051	442	6	95	10800.00	0.00
1052	442	3	\N	0.00	10800.00
1053	442	4	\N	9180.00	0.00
1054	442	7	\N	0.00	9180.00
1055	443	6	75	10200.00	0.00
1056	443	3	\N	0.00	10200.00
1057	443	4	\N	10122.90	0.00
1058	443	7	\N	0.00	10122.90
1059	444	6	104	3900.00	0.00
1060	444	3	\N	0.00	3900.00
1061	444	4	\N	3700.00	0.00
1062	444	7	\N	0.00	3700.00
1067	446	6	7	5620.00	0.00
1068	446	3	\N	0.00	5620.00
1069	446	4	\N	4889.56	0.00
1070	446	7	\N	0.00	4889.56
1239	506	4	\N	2052.00	0.00
1240	506	7	\N	0.00	2052.00
1261	512	6	77	10350.00	0.00
1262	512	3	\N	0.00	10350.00
1075	448	6	84	41620.00	0.00
1076	448	3	\N	0.00	41620.00
1077	448	4	\N	39300.00	0.00
1078	448	7	\N	0.00	39300.00
1079	449	6	71	5160.00	0.00
1080	449	3	\N	0.00	5160.00
1081	449	4	\N	3.00	0.00
1082	449	7	\N	0.00	3.00
1263	512	4	\N	9886.00	0.00
1264	512	7	\N	0.00	9886.00
1087	451	6	68	6900.00	0.00
1088	451	3	\N	0.00	6900.00
1089	451	4	\N	6590.46	0.00
1090	451	7	\N	0.00	6590.46
1091	452	5	\N	10800.00	0.00
1092	452	6	95	0.00	10800.00
1095	454	5	\N	3400.00	0.00
1096	454	6	104	0.00	3400.00
1097	455	5	\N	3880.00	0.00
1098	455	6	104	0.00	3880.00
1099	456	5	\N	10200.00	0.00
1100	456	6	75	0.00	10200.00
1101	457	5	\N	41620.00	0.00
1102	457	6	84	0.00	41620.00
1103	458	5	\N	62195.00	0.00
1104	458	6	7	0.00	62195.00
1105	459	5	\N	2950.00	0.00
1106	459	6	81	0.00	2950.00
1107	460	1	16	139870.00	0.00
1108	460	5	\N	0.00	139870.00
1109	461	5	\N	30000.00	0.00
1110	461	6	105	0.00	30000.00
1111	462	5	\N	38340.00	0.00
1112	462	6	96	0.00	38340.00
1113	463	5	\N	30800.00	0.00
1114	463	6	105	0.00	30800.00
1115	464	5	\N	73320.00	0.00
1116	464	6	106	0.00	73320.00
1117	465	1	16	163320.00	0.00
1118	465	5	\N	0.00	163320.00
1119	466	5	\N	886.00	0.00
1120	466	6	11	0.00	886.00
1121	467	22	37	886.00	0.00
1122	467	5	\N	0.00	886.00
1123	468	5	\N	139.00	0.00
1124	468	6	11	0.00	139.00
1125	469	22	37	139.00	0.00
1126	469	5	\N	0.00	139.00
1127	470	5	\N	11400.00	0.00
1128	470	6	95	0.00	11400.00
1131	472	5	\N	4600.00	0.00
1132	472	6	95	0.00	4600.00
1135	474	25	40	5100.00	0.00
1136	474	5	\N	0.00	5100.00
1137	475	5	\N	1948.00	0.00
1138	475	6	98	0.00	1948.00
1139	476	1	11	1948.00	0.00
1140	476	5	\N	0.00	1948.00
1141	477	5	\N	5160.00	0.00
1142	477	6	71	0.00	5160.00
1241	507	6	49	23890.00	0.00
1242	507	3	\N	0.00	23890.00
1145	479	25	40	300.00	0.00
1146	479	5	\N	0.00	300.00
1147	480	5	\N	26820.00	0.00
1148	480	6	49	0.00	26820.00
1149	481	5	\N	1050.00	0.00
1150	481	6	95	0.00	1050.00
1243	507	4	\N	22830.44	0.00
1244	507	7	\N	0.00	22830.44
1153	483	7	\N	275415.64	0.00
1154	483	1	6	0.00	275415.64
1155	484	6	105	60800.00	0.00
1156	484	3	\N	0.00	60800.00
1157	484	4	\N	54428.30	0.00
1158	484	7	\N	0.00	54428.30
1159	485	6	96	38340.00	0.00
1160	485	3	\N	0.00	38340.00
1161	485	4	\N	37100.40	0.00
1162	485	7	\N	0.00	37100.40
1163	486	6	95	17050.00	0.00
1164	486	3	\N	0.00	17050.00
1165	486	4	\N	16177.75	0.00
1166	486	7	\N	0.00	16177.75
1167	487	6	109	20060.00	0.00
1168	487	3	\N	0.00	20060.00
1169	487	4	\N	16055.28	0.00
1170	487	7	\N	0.00	16055.28
1171	488	6	98	20550.00	0.00
1172	488	3	\N	0.00	20550.00
1173	488	4	\N	19197.30	0.00
1174	488	7	\N	0.00	19197.30
1265	513	6	116	3120.00	0.00
1175	489	6	110	6800.00	0.00
1176	489	3	\N	0.00	6800.00
1177	489	4	\N	6399.10	0.00
1178	489	7	\N	0.00	6399.10
1183	491	6	49	26820.00	0.00
1184	491	3	\N	0.00	26820.00
1185	491	4	\N	24933.75	0.00
1186	491	7	\N	0.00	24933.75
1187	492	6	35	12250.00	0.00
1188	492	3	\N	0.00	12250.00
1189	492	4	\N	9528.00	0.00
1190	492	7	\N	0.00	9528.00
1191	493	6	106	73320.00	0.00
1192	493	3	\N	0.00	73320.00
1193	493	4	\N	57168.00	0.00
1194	493	7	\N	0.00	57168.00
1195	494	6	7	8105.00	0.00
1196	494	3	\N	0.00	8105.00
1197	494	4	\N	8243.50	0.00
1198	494	7	\N	0.00	8243.50
1199	495	6	68	31050.00	0.00
1200	495	3	\N	0.00	31050.00
1201	495	4	\N	30300.80	0.00
1202	495	7	\N	0.00	30300.80
1203	496	7	\N	36600.00	0.00
1204	496	1	5	0.00	36600.00
1205	497	7	\N	20400.00	0.00
1206	497	1	35	0.00	20400.00
1207	498	6	85	20200.00	0.00
1208	498	3	\N	0.00	20200.00
1209	498	4	\N	16031.38	0.00
1210	498	7	\N	0.00	16031.38
1211	499	7	\N	7000.00	0.00
1212	499	1	113	0.00	7000.00
1266	513	3	\N	0.00	3120.00
1267	513	4	\N	2678.00	0.00
1268	513	7	\N	0.00	2678.00
1311	530	6	78	2600.00	0.00
1312	530	3	\N	0.00	2600.00
1313	530	4	\N	2741.46	0.00
1314	530	7	\N	0.00	2741.46
1321	534	18	20	1239.00	0.00
1322	534	5	\N	0.00	1239.00
1329	538	6	105	13800.00	0.00
1330	538	3	\N	0.00	13800.00
1331	538	4	\N	9203.26	0.00
1332	538	7	\N	0.00	9203.26
1346	542	7	\N	0.00	1740.00
1351	544	6	98	17700.00	0.00
1352	544	3	\N	0.00	17700.00
1353	544	4	\N	4500.00	0.00
1354	544	7	\N	0.00	4500.00
1355	545	7	\N	3.00	0.00
1356	545	1	2	0.00	3.00
1357	546	7	\N	224923.00	0.00
1358	546	1	6	0.00	224923.00
1359	547	6	95	6450.00	0.00
1360	547	3	\N	0.00	6450.00
1361	547	4	\N	5760.00	0.00
1362	547	7	\N	0.00	5760.00
1365	549	5	\N	5250.00	0.00
1366	549	6	54	0.00	5250.00
1369	551	5	\N	27741.00	0.00
1370	551	6	4	0.00	27741.00
1375	554	5	\N	4400.00	0.00
1376	554	6	113	0.00	4400.00
1377	555	1	13	300.00	0.00
1378	555	5	\N	0.00	300.00
1379	556	5	\N	3620.00	0.00
1380	556	6	36	0.00	3620.00
1381	557	5	\N	12250.00	0.00
1382	557	6	35	0.00	12250.00
1383	558	5	\N	6900.00	0.00
1384	558	6	68	0.00	6900.00
1385	559	5	\N	18615.00	0.00
1386	559	6	98	0.00	18615.00
1387	560	6	78	1610.00	0.00
1388	560	3	\N	0.00	1610.00
1389	560	4	\N	1581.76	0.00
1390	560	7	\N	0.00	1581.76
1391	561	5	\N	139238.00	0.00
1392	561	6	4	0.00	139238.00
1393	562	1	117	139238.00	0.00
1394	562	5	\N	0.00	139238.00
1395	563	5	\N	30719.00	0.00
1396	563	6	4	0.00	30719.00
1397	564	1	118	30719.00	0.00
1398	564	5	\N	0.00	30719.00
1399	565	5	\N	1239.00	0.00
1400	565	6	4	0.00	1239.00
1401	566	5	\N	19379.00	0.00
1402	566	6	4	0.00	19379.00
1405	568	1	121	19379.00	0.00
1406	568	5	\N	0.00	19379.00
1407	569	5	\N	7225.00	0.00
1408	569	6	4	0.00	7225.00
1409	570	1	122	7225.00	0.00
1410	570	5	\N	0.00	7225.00
1411	571	6	113	4400.00	0.00
1412	571	3	\N	0.00	4400.00
1413	571	4	\N	4098.30	0.00
1414	571	7	\N	0.00	4098.30
1415	572	7	\N	4.00	0.00
1416	572	1	2	0.00	4.00
1417	573	6	113	1600.00	0.00
1418	573	3	\N	0.00	1600.00
1419	573	4	\N	4.00	0.00
1420	573	7	\N	0.00	4.00
1421	574	1	16	61905.00	0.00
1422	574	5	\N	0.00	61905.00
1423	575	1	16	45000.00	0.00
1424	575	5	\N	0.00	45000.00
1425	576	1	5	50000.00	0.00
1426	576	5	\N	0.00	50000.00
1427	577	5	\N	17290.00	0.00
1428	577	6	49	0.00	17290.00
1429	578	25	40	7.00	0.00
1430	578	5	\N	0.00	7.00
1431	579	5	\N	15000.00	0.00
1432	579	6	111	0.00	15000.00
1433	580	5	\N	17340.00	0.00
1434	580	6	79	0.00	17340.00
1435	581	1	16	57000.00	0.00
1436	581	5	\N	0.00	57000.00
1437	582	5	\N	3150.00	0.00
1438	582	6	112	0.00	3150.00
1439	583	5	\N	1320.00	0.00
1440	583	6	49	0.00	1320.00
1441	584	25	40	10.00	0.00
1442	584	5	\N	0.00	10.00
1443	585	25	40	35.00	0.00
1444	585	5	\N	0.00	35.00
1445	586	25	40	30.00	0.00
1446	586	5	\N	0.00	30.00
1447	587	1	35	13205.00	0.00
1448	587	5	\N	0.00	13205.00
1449	588	19	24	1500.00	0.00
1450	588	5	\N	0.00	1500.00
1451	589	19	24	50.00	0.00
1452	589	5	\N	0.00	50.00
1453	590	5	\N	20060.00	0.00
1454	590	6	109	0.00	20060.00
1455	591	5	\N	6800.00	0.00
1456	591	6	110	0.00	6800.00
1457	592	5	\N	2600.00	0.00
1458	592	6	78	0.00	2600.00
1459	593	25	40	40.00	0.00
1460	593	5	\N	0.00	40.00
1461	594	5	\N	250.00	0.00
1462	594	6	114	0.00	250.00
1463	595	5	\N	9700.00	0.00
1464	595	6	53	0.00	9700.00
1465	596	5	\N	31050.00	0.00
1466	596	6	68	0.00	31050.00
1467	597	1	16	56050.00	0.00
1468	597	5	\N	0.00	56050.00
1469	598	5	\N	3380.00	0.00
1470	598	6	40	0.00	3380.00
1471	599	1	36	3380.00	0.00
1472	599	5	\N	0.00	3380.00
1473	600	5	\N	18000.00	0.00
1474	600	6	15	0.00	18000.00
1475	601	5	\N	6560.00	0.00
1476	601	6	104	0.00	6560.00
1477	602	5	\N	39330.00	0.00
1478	602	6	96	0.00	39330.00
1479	603	5	\N	120000.00	0.00
1480	603	6	15	0.00	120000.00
1481	604	5	\N	25000.00	0.00
1482	604	6	15	0.00	25000.00
1483	605	1	15	140000.00	0.00
1484	605	5	\N	0.00	140000.00
1485	606	5	\N	5000.00	0.00
1486	606	6	85	0.00	5000.00
1487	607	25	40	10.00	0.00
1488	607	5	\N	0.00	10.00
1489	608	5	\N	5800.00	0.00
1490	608	6	76	0.00	5800.00
1491	609	5	\N	13800.00	0.00
1492	609	6	105	0.00	13800.00
1493	610	1	16	57200.00	0.00
1494	610	5	\N	0.00	57200.00
1495	611	5	\N	6450.00	0.00
1496	611	6	95	0.00	6450.00
1497	612	5	\N	1291.00	0.00
1498	612	6	11	0.00	1291.00
1499	613	22	37	1291.00	0.00
1500	613	5	\N	0.00	1291.00
1503	615	5	\N	10000.00	0.00
1504	615	6	104	0.00	10000.00
1505	616	5	\N	1600.00	0.00
1506	616	6	78	0.00	1600.00
1507	617	5	\N	13800.00	0.00
1508	617	6	68	0.00	13800.00
1509	618	5	\N	11600.00	0.00
1510	618	6	105	0.00	11600.00
1511	619	5	\N	2400.00	0.00
1512	619	6	111	0.00	2400.00
1513	620	1	16	33585.00	0.00
1514	620	5	\N	0.00	33585.00
1515	621	5	\N	20000.00	0.00
1516	621	6	15	0.00	20000.00
1517	622	1	5	30000.00	0.00
1518	622	5	\N	0.00	30000.00
1519	623	5	\N	35.00	0.00
1520	623	6	37	0.00	35.00
1521	624	19	24	25.00	0.00
1522	624	5	\N	0.00	25.00
1523	625	5	\N	650.00	0.00
1524	625	6	113	0.00	650.00
1525	626	5	\N	2930.00	0.00
1526	626	6	84	0.00	2930.00
1527	627	5	\N	3165.00	0.00
1528	627	6	11	0.00	3165.00
1529	628	1	10	3165.00	0.00
1530	628	5	\N	0.00	3165.00
1531	629	5	\N	190.00	0.00
1532	629	6	11	0.00	190.00
1533	630	1	10	190.00	0.00
1534	630	5	\N	0.00	190.00
1535	631	5	\N	152.20	0.00
1536	631	6	11	0.00	152.20
1537	632	22	37	152.20	0.00
1538	632	5	\N	0.00	152.20
1539	633	5	\N	1450.00	0.00
1540	633	6	123	0.00	1450.00
1541	634	1	5	20000.00	0.00
1542	634	5	\N	0.00	20000.00
1547	636	6	96	39330.00	0.00
1548	636	3	\N	0.00	39330.00
1549	636	4	\N	40660.00	0.00
1550	636	7	\N	0.00	40660.00
1551	637	6	104	10710.00	0.00
1552	637	3	\N	0.00	10710.00
1553	637	4	\N	8985.00	0.00
1554	637	7	\N	0.00	8985.00
1555	638	6	105	11600.00	0.00
1556	638	3	\N	0.00	11600.00
1557	638	4	\N	11576.00	0.00
1558	638	7	\N	0.00	11576.00
1559	639	6	113	3700.00	0.00
1560	639	3	\N	0.00	3700.00
1561	639	4	\N	3289.42	0.00
1562	639	7	\N	0.00	3289.42
1563	640	6	123	1450.00	0.00
1564	640	3	\N	0.00	1450.00
1565	640	4	\N	1283.00	0.00
1566	640	7	\N	0.00	1283.00
1567	641	25	40	80.00	0.00
1568	641	5	\N	0.00	80.00
1573	643	6	104	3450.00	0.00
1574	643	3	\N	0.00	3450.00
1575	643	4	\N	3272.00	0.00
1576	643	7	\N	0.00	3272.00
1577	644	6	113	3100.00	0.00
1578	644	3	\N	0.00	3100.00
1579	644	4	\N	2911.95	0.00
1580	644	7	\N	0.00	2911.95
1581	645	25	40	10.00	0.00
1582	645	5	\N	0.00	10.00
1583	646	5	\N	700.00	0.00
1584	646	6	104	0.00	700.00
1585	647	5	\N	3450.00	0.00
1586	647	6	104	0.00	3450.00
1587	648	25	40	15.00	0.00
1588	648	5	\N	0.00	15.00
1589	649	5	\N	3797.47	0.00
1590	649	6	11	0.00	3797.47
1591	650	1	10	3797.47	0.00
1592	650	5	\N	0.00	3797.47
1593	651	5	\N	89609.51	0.00
1594	651	6	120	0.00	89609.51
1595	652	29	87	89609.51	0.00
1596	652	5	\N	0.00	89609.51
1601	655	5	\N	17700.00	0.00
1602	655	6	98	0.00	17700.00
1603	656	5	\N	9960.00	0.00
1604	656	6	80	0.00	9960.00
1605	657	5	\N	6400.00	0.00
1606	657	6	78	0.00	6400.00
1607	658	5	\N	3400.00	0.00
1608	658	6	104	0.00	3400.00
1609	659	25	40	30.00	0.00
1610	659	5	\N	0.00	30.00
1611	660	5	\N	56025.00	0.00
1612	660	6	71	0.00	56025.00
1615	662	1	35	7195.00	0.00
1616	662	5	\N	0.00	7195.00
1617	663	5	\N	3100.00	0.00
1618	663	6	113	0.00	3100.00
1621	665	6	80	9960.00	0.00
1622	665	3	\N	0.00	9960.00
1623	665	4	\N	7622.40	0.00
1624	665	7	\N	0.00	7622.40
1625	666	6	68	13800.00	0.00
1626	666	3	\N	0.00	13800.00
1627	666	4	\N	13452.20	0.00
1628	666	7	\N	0.00	13452.20
1629	667	6	71	56025.00	0.00
1630	667	3	\N	0.00	56025.00
1631	667	4	\N	42960.96	0.00
1632	667	7	\N	0.00	42960.96
1633	668	5	\N	1898.73	0.00
1634	668	6	91	0.00	1898.73
1635	669	1	5	1898.73	0.00
1636	669	5	\N	0.00	1898.73
1639	671	22	37	25.32	0.00
1640	671	5	\N	0.00	25.32
1641	672	5	\N	1620.25	0.00
1642	672	6	91	0.00	1620.25
1645	674	5	\N	3924.05	0.00
1646	674	6	124	0.00	3924.05
1647	675	1	11	3924.05	0.00
1648	675	5	\N	0.00	3924.05
1649	676	5	\N	2594.94	0.00
1650	676	6	91	0.00	2594.94
1651	677	1	5	2594.94	0.00
1652	677	5	\N	0.00	2594.94
1663	683	1	11	1962.03	0.00
1664	683	5	\N	0.00	1962.03
1667	685	1	11	1898.73	0.00
1668	685	5	\N	0.00	1898.73
1675	689	6	104	3400.00	0.00
1676	689	3	\N	0.00	3400.00
1677	689	4	\N	3199.55	0.00
1678	689	7	\N	0.00	3199.55
1689	695	7	\N	247151.90	0.00
1690	695	1	4	0.00	247151.90
1691	696	6	7	48470.00	0.00
1692	696	3	\N	0.00	48470.00
1693	696	4	\N	42463.42	0.00
1694	696	7	\N	0.00	42463.42
1695	697	6	71	2630.00	0.00
1696	697	3	\N	0.00	2630.00
1697	697	4	\N	2295.32	0.00
1698	697	7	\N	0.00	2295.32
1703	699	7	\N	218815.17	0.00
1704	699	1	4	0.00	218815.17
1705	700	6	78	6400.00	0.00
1706	700	3	\N	0.00	6400.00
1707	700	4	\N	6258.65	0.00
1708	700	7	\N	0.00	6258.65
1777	734	7	\N	32.00	0.00
1778	734	1	2	0.00	32.00
1779	735	5	\N	7134.10	0.00
1780	735	6	122	0.00	7134.10
1781	736	29	87	7134.10	0.00
1782	736	5	\N	0.00	7134.10
1783	737	5	\N	19379.43	0.00
1784	737	6	121	0.00	19379.43
1785	738	29	87	19379.43	0.00
1786	738	5	\N	0.00	19379.43
1787	739	1	5	1620.25	0.00
1788	739	5	\N	0.00	1620.25
1789	740	5	\N	1898.73	0.00
1790	740	6	125	0.00	1898.73
1791	741	5	\N	1962.03	0.00
1792	741	6	125	0.00	1962.03
1793	742	1	16	54900.00	0.00
1794	742	5	\N	0.00	54900.00
1795	743	5	\N	179750.00	0.00
1796	743	6	16	0.00	179750.00
1797	744	1	6	179750.00	0.00
1798	744	5	\N	0.00	179750.00
1799	745	5	\N	179750.00	0.00
1800	745	6	16	0.00	179750.00
1801	746	1	6	179750.00	0.00
1802	746	5	\N	0.00	179750.00
1803	747	6	45	150770.00	0.00
1804	747	3	\N	0.00	150770.00
1805	747	4	\N	131082.15	0.00
1806	747	7	\N	0.00	131082.15
1807	748	6	54	8200.00	0.00
1808	748	3	\N	0.00	8200.00
1809	748	4	\N	7312.00	0.00
1810	748	7	\N	0.00	7312.00
1813	750	25	40	25.00	0.00
1814	750	5	\N	0.00	25.00
1815	751	5	\N	8200.00	0.00
1816	751	6	54	0.00	8200.00
1817	752	1	16	29500.00	0.00
1818	752	5	\N	0.00	29500.00
1819	753	5	\N	186000.00	0.00
1820	753	6	126	0.00	186000.00
1821	754	1	15	20000.00	0.00
1822	754	5	\N	0.00	20000.00
1823	755	1	16	166000.00	0.00
1824	755	5	\N	0.00	166000.00
1825	756	5	\N	25.32	0.00
1826	756	6	15	0.00	25.32
1827	757	5	\N	2531.64	0.00
1828	757	6	56	0.00	2531.64
1829	758	1	11	2531.64	0.00
1830	758	5	\N	0.00	2531.64
1831	759	5	\N	1037.97	0.00
1832	759	6	91	0.00	1037.97
1833	760	1	11	1037.97	0.00
1834	760	5	\N	0.00	1037.97
1835	761	5	\N	1936.70	0.00
1836	761	6	125	0.00	1936.70
1837	762	1	11	1936.70	0.00
1838	762	5	\N	0.00	1936.70
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
66	ZEESHAN	Both		Dubai, UAE	6	1	5770.00	Debit	2026-01-06 14:35:10.429398
67	HASSAN ASHRAF	Both		Dubai, UAE	6	1	46220.00	Debit	2026-01-06 15:05:48.887913
68	DJI HUB	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-07 13:11:57.474502
69	METRO DELUXE	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-07 13:52:25.537671
5	MUDASSIR	Both	+92 332 2563123	Karachi, Pakistan	6	1	15921.00	Debit	2026-01-05 14:57:31.959174
4	WAHEED BHAI	Both	+61 421 022 212	Sydney Australia (Vendor)	6	1	641854.00	Debit	2026-01-05 13:51:50.504729
70	SMT SURAN	Both			6	1	0.00	Debit	2026-01-08 15:38:54.143333
71	PHONE 4U	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-08 16:08:56.882322
72	KHAIRA JANI KABEER	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-08 16:14:19.736295
73	BBC	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-08 16:19:30.057812
74	CENTURY STORE	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 13:31:24.896078
75	ALL DIGITAL	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 14:15:42.918325
76	ULTRA DEAL	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 14:20:17.345717
77	AL-OHA	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 14:34:40.068156
78	HAMZA ONE TECH	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 14:38:07.709053
79	NY	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 14:47:53.722829
80	CENTRAL SYSTEM	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 15:25:07.876347
81	ASAD B SMART	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 15:30:10.727677
82	FARHAN ALHAMD	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 15:31:58.604729
83	SABEER SAM AMAL	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 15:43:03.991207
84	BILAL KARACHI	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 15:51:59.9062
85	ZEESHAN DYSOMAC	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-09 17:04:37.340182
86	FIJI ELECTRONICS	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-10 11:58:23.19365
87	SHIPPING AND CLEARANCE	Expense		For turbo Invoices	6	29	0.00	Debit	2026-01-10 13:16:12.886828
88	HASEEB 137 KARACHI	Both		Karachi, Pakistan	6	1	0.00	Debit	2026-01-10 13:56:52.305969
89	ANUS MOTA	Both		Karachi, Pakistan	6	1	2430.00	Debit	2026-01-10 13:58:26.708963
90	CELL ARENA KARACHI	Both		Karachi, Pakistan	6	1	0.00	Debit	2026-01-10 14:00:37.539996
91	FAIZAN GROUND KARACHI	Both		Karachi, Pakistan	6	1	0.00	Debit	2026-01-10 14:20:25.56519
92	ANUS 224 KARACHI	Both		karachi, Pakistan	6	1	0.00	Debit	2026-01-10 14:37:23.66138
93	WAQAS MOBILE TONE	Both		Shop G112, Amma Tower, Abdullah Haroon Road, Karachi, Pakistan	6	1	0.00	Debit	2026-01-10 14:54:11.865563
94	MAKHDUM HAMZA	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-10 16:02:20.653913
95	FAHAD LAHORE	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-12 14:11:52.674936
96	CTN	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-12 14:16:11.589994
97	AHSAN ALI SHEIKH	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-12 14:23:37.818785
98	SAJJAD ATARI	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-12 14:27:02.772247
99	ZAIDI-GUJRANWALA	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-12 15:33:42.14724
100	ARIYA MOBILE	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-12 15:58:02.532805
101	KUMAIL CUSTOMER	Both		Karachi, Pakistan	6	1	0.00	Debit	2026-01-13 13:30:18.764633
103	RAKESH	Both		Dubai, UAE	6	1	0.00	Debit	2026-01-14 12:26:53.286958
104	FARAZ GVT	Both		Dubai UAE	6	1	0.00	Debit	2026-01-16 14:05:47.495335
105	ABUZAR DUBAI	Both		Dubai UAE	6	1	0.00	Debit	2026-01-16 15:22:44.822104
106	QAMAR SUDANI	Both		Dubai UAE	6	1	0.00	Debit	2026-01-16 15:34:24.939412
109	MUZAMMIL-PINDI	Both		Dubai UAE	6	1	0.00	Debit	2026-01-17 15:05:17.551499
110	FARHAN TURKISH	Both		Dubai UAE	6	1	0.00	Debit	2026-01-17 15:14:37.908157
111	ADEEL KARACHI	Both		Dubai UAE	6	1	0.00	Debit	2026-01-17 15:37:05.843031
112	SAEED	Both		Dubai UAE\r\n	6	1	0.00	Debit	2026-01-19 11:04:43.860633
113	ASAD LINKS	Both		Dubai UAE	6	1	0.00	Debit	2026-01-19 12:20:05.304658
114	ABDULRAFAY FAISAL	Both		DUBAI UAE STAFF	6	1	0.00	Debit	2026-01-19 13:15:16.497339
116	FAHAD KARACHI	Both		KARACHI STARCITY MALL	6	1	0.00	Debit	2026-01-19 13:41:48.249873
117	AUSTRALIA PURCHASING	Both		Waheed Bhai Australia Purchasing account	6	1	0.00	Debit	2026-01-19 13:56:04.309587
118	NEW ZEALAND PURCHASING 	Both		Waheed Bhai New Zealand Purchasing account 	6	1	0.00	Debit	2026-01-19 13:56:49.243121
120	MEGATOP SHIPPING AUSTRALIA	Both		Shipping Party	6	1	0.00	Debit	2026-01-19 17:14:49.588785
121	CT FREIGHT AUSTRALIA	Both		Australia Shipping company 	6	1	0.00	Debit	2026-01-20 16:46:09.917541
122	CT FREIGHT NEW ZEALAND	Both		NewZealand Shipping Company	6	1	0.00	Debit	2026-01-20 16:47:24.760327
123	DIGITAL GAME	Both		Dubai UAE	6	1	0.00	Debit	2026-01-21 13:32:08.3366
124	AHMAD STAR CITY	Both		Karachi Star City Mall	6	1	0.00	Debit	2026-01-22 11:57:18.992483
125	ZEESHAN FARIYA	Both		Karachi Fariya mobile mall	6	1	0.00	Debit	2026-01-23 11:45:25.962282
126	GOLDEN VISION	Both		Dubai UAE	6	1	0.00	Debit	2026-01-23 13:54:21.761479
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payments (payment_id, party_id, account_id, amount, payment_date, method, reference_no, journal_id, date_created, notes, description) FROM stdin;
1	39	5	15000.0000	2026-01-06	Cash	PMT-1	116	2026-01-06 16:07:26.313194	\N	loss for hassan Ashraf 
2	16	5	37615.0000	2026-01-08	Cash	PMT-2	181	2026-01-10 11:53:33.158313	\N	37615 cash paid to ahsan Mohsin jimmy
41	5	5	10127.0000	2026-01-08	Cash	PMT-41	272	2026-01-10 13:46:41.149091	\N	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)
29	60	5	17268.0000	2026-01-08	Cash	PMT-29	242	2026-01-10 13:11:34.632346	\N	17,268 cash paid to mutee ur rehman for FedEx charges world mart For Owais 2 Shipments  #886948403809 1930.02 $ * 3.674,  #887197830975 2,769.99 * 3,674
3	40	5	65.0000	2026-01-08	Cash	PMT-3	184	2026-01-10 11:53:58.587205	\N	Hammali
4	16	5	59210.0000	2026-01-08	Cash	PMT-4	187	2026-01-10 12:00:48.638446	\N	Paid to ahsan Mohsin
5	37	5	658.0000	2026-01-08	Cash	PMT-5	189	2026-01-10 12:04:31.716656	\N	Caryy 52,000 PKR @79 For karachi Office Pieces to Waqas Aslam from Abdul Rehman
6	16	5	50000.0000	2026-01-08	Cash	PMT-6	191	2026-01-10 12:06:15.462593	\N	50,000 paid to ahsan Mohsin jimmy
7	40	5	15.0000	2026-01-08	Cash	PMT-7	197	2026-01-10 12:09:36.632213	\N	Hammali
8	16	5	50000.0000	2026-01-08	Cash	PMT-8	198	2026-01-10 12:10:51.054475	\N	50,000 paid to ahsan Mohsin jimmy
9	40	5	15.0000	2026-01-08	Cash	PMT-9	202	2026-01-10 12:12:45.164903	\N	15 packing material osmo pocket 3
10	40	5	30.0000	2026-01-08	Cash	PMT-10	206	2026-01-10 12:15:02.457879	\N	Hammali
11	15	5	155000.0000	2026-01-08	Cash	PMT-11	207	2026-01-10 12:15:38.161202	\N	155000 paid to ahsan cba bank deposit
12	15	5	16830.0000	2026-01-08	Cash	PMT-12	208	2026-01-10 12:16:03.914423	\N	16830 paid ahsan cba bank deposit
13	5	5	50000.0000	2026-01-08	Cash	PMT-13	209	2026-01-10 12:16:31.739877	\N	50,000 paid to Mudassir Wajahat
14	37	5	254.0000	2026-01-08	Cash	PMT-14	211	2026-01-10 12:18:16.511423	\N	To Anwer for Karachi Office Software 12 months payment from AR Meezan
15	40	5	60.0000	2026-01-08	Cash	PMT-15	212	2026-01-10 12:18:51.31607	\N	Packing Material
16	40	5	10.0000	2026-01-08	Cash	PMT-16	213	2026-01-10 12:19:10.09946	\N	Hammali
17	15	5	128550.0000	2026-01-08	Cash	PMT-17	214	2026-01-10 12:19:43.813636	\N	128550 paid bank  deposit ahsan cba
18	40	5	30.0000	2026-01-08	Cash	PMT-18	215	2026-01-10 12:20:03.937552	\N	30 packing material
19	15	5	5500.0000	2026-01-08	Cash	PMT-19	216	2026-01-10 12:20:24.928278	\N	5500 paid bank deposit ahsan cba
20	10	5	254.0000	2026-01-08	Cash	PMT-20	218	2026-01-10 12:21:57.27772	\N	20k PKR from AR Meezan to TAYYAB ANDLEEB (Faisal Bhai)
21	10	5	140.0000	2026-01-08	Cash	PMT-21	220	2026-01-10 12:23:04.567851	\N	11k PKR from AR Meezan to KHADIJA FAISAL (Faisal Bhai)
22	40	5	50.0000	2026-01-08	Cash	PMT-22	221	2026-01-10 12:23:23.061029	\N	Hammali
23	40	5	90.0000	2026-01-08	Cash	PMT-23	222	2026-01-10 12:23:47.598885	\N	sealing machine
24	11	5	275.0000	2026-01-08	Cash	PMT-24	225	2026-01-10 12:29:52.727733	\N	275 paid Abdul rehman(Waseem )
25	16	5	50000.0000	2026-01-08	Cash	PMT-25	226	2026-01-10 12:30:14.14033	\N	50000 paid to ahsan mohsin jimmy
26	15	5	97900.0000	2026-01-08	Cash	PMT-26	229	2026-01-10 12:31:39.486467	\N	97900 paid to ahsan  cba cash deposit bank
27	40	5	35.0000	2026-01-08	Cash	PMT-27	235	2026-01-10 12:35:55.829026	\N	Hammali
28	25	5	50.0000	2026-01-08	Cash	PMT-28	239	2026-01-10 13:02:51.482592	\N	Discount to NY
30	87	5	20000.0000	2026-01-08	Cash	PMT-30	245	2026-01-10 13:16:37.379337	\N	20,000 cash paid to turbo freight
31	5	5	12200.0000	2026-01-08	Cash	PMT-31	246	2026-01-10 13:17:11.531288	\N	12200 cash paid to Mudassir Wajahat
32	40	5	60.0000	2026-01-08	Cash	PMT-32	252	2026-01-10 13:25:31.614508	\N	Hammali
35	51	5	1000.0000	2026-01-08	Cash	PMT-35	255	2026-01-10 13:30:28.31084	\N	Abdul Rafay Salary for the month of December
36	10	5	5000.0000	2026-01-08	Cash	PMT-36	256	2026-01-10 13:30:55.985601	\N	5000 out to faisal self
37	40	5	10.0000	2026-01-08	Cash	PMT-37	259	2026-01-10 13:33:08.069064	\N	Hammali
38	5	5	100000.0000	2026-01-08	Cash	PMT-38	260	2026-01-10 13:33:52.932958	\N	100,000 paid to Mudassir
39	40	5	10.0000	2026-01-08	Cash	PMT-39	262	2026-01-10 13:35:14.282897	\N	Hammali
40	16	5	50430.0000	2026-01-08	Cash	PMT-40	264	2026-01-10 13:36:32.857635	\N	50430 cash paid to ahsan Mohsin jimmy
42	5	5	1899.0000	2026-01-10	Cash	PMT-42	275	2026-01-10 13:48:13.968511	\N	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)
43	16	5	39705.0000	2026-01-08	Cash	PMT-43	276	2026-01-10 13:50:11.281889	\N	Paid to ahsan Mohsin
44	16	5	122000.0000	2026-01-08	Cash	PMT-44	277	2026-01-10 13:53:29.786485	\N	122000 paid to ahsan Mohsin jimmy
45	16	5	65000.0000	2026-01-08	Cash	PMT-45	278	2026-01-10 13:53:52.666561	\N	65000 paid to ahsan Mohsin jimmy
46	5	5	2595.0000	2026-01-08	Cash	PMT-46	283	2026-01-10 14:03:40.954805	\N	205K PKR, from Cell Arena to ON POint IT Services(MUDASSIR)
47	5	5	1722.0000	2026-01-08	Cash	PMT-47	285	2026-01-10 14:05:03.859211	\N	From HASEEB AHMED to ON Point IT Services (MUDASSIR)
48	5	5	1950.0000	2026-01-08	Cash	PMT-48	292	2026-01-10 14:39:20.89246	\N	from Ahmed Hassan 224 to ON Point IT Services(Mudassir)
49	5	5	1899.0000	2026-01-08	Cash	PMT-49	295	2026-01-10 14:43:00.114849	\N	150K PKR from Faizan Ground (muhammad Ahsan) to ON Point It services( MUdassir)
50	11	5	2532.0000	2026-01-08	Cash	PMT-50	297	2026-01-10 14:44:32.271205	\N	200,000 PKR from haseeb 137 to AR Meezan 
51	5	5	2025.0000	2026-01-08	Cash	PMT-51	301	2026-01-10 14:50:47.639042	\N	from Faizan Ground (Muhammad Ahsan) to On point IT Services (Mudassir)
52	15	5	26.0000	2026-01-08	Cash	PMT-52	304	2026-01-10 15:04:57.310439	\N	Received from Anus paid to Ahmed 224
53	11	5	26.0000	2026-01-08	Cash	PMT-53	306	2026-01-10 15:07:16.266927	\N	from Ahmed Hassan CBA to AR Meezan 
54	11	5	1722.0000	2026-01-08	Cash	PMT-54	308	2026-01-10 15:09:31.358428	\N	136,000 PKR From sumair pasta to AR Meezan
55	11	5	2393.0000	2026-01-08	Cash	PMT-55	310	2026-01-10 15:12:36.29542	\N	189,000 PKR from Haseeb 137 to AR Meezan
56	5	5	1456.0000	2026-01-08	Cash	PMT-56	313	2026-01-10 15:14:40.480212	\N	115000 PKR from Faizan Ground to On point IT services ( Mudassir)
57	4	5	120900.0000	2026-01-06	Cash	PMT-57	315	2026-01-10 15:21:37.468463	\N	 50,000 AUD@2.4180 paid through Ahsan Mohsin to Waheed Bhai
58	4	5	241342.0000	2026-01-09	Cash	PMT-58	317	2026-01-10 15:28:04.551835	\N	 99,000 AUD @2.4378 from Ahsan Mohsin to Waheed bhai
59	40	5	20.0000	2026-01-05	Cash	PMT-59	318	2026-01-10 15:34:14.761306	\N	20 cash out to glass buff
60	13	5	150.0000	2026-01-05	Cash	PMT-60	324	2026-01-10 15:45:12.517352	\N	150 paid to Abubaker
61	13	5	500.0000	2026-01-05	Cash	PMT-61	325	2026-01-10 15:59:34.468503	\N	500 paid to Abubaker
62	25	5	20.0000	2026-01-09	Cash	PMT-62	347	2026-01-12 14:44:14.465798	\N	20 discount box damage Fahad Lahore
63	16	5	100000.0000	2026-01-09	Cash	PMT-63	351	2026-01-12 14:46:39.435308	\N	100,000 to Jimmy
64	52	5	10.0000	2026-01-09	Cash	PMT-64	353	2026-01-12 14:49:05.387728	\N	Commision
65	5	5	60000.0000	2026-01-09	Cash	PMT-65	355	2026-01-12 14:50:03.21557	\N	60000 cash out to wajahat 
66	16	5	50000.0000	2026-01-10	Cash	PMT-66	360	2026-01-12 14:52:43.938342	\N	50,000 paid to ahsan Mohsin jimmy
67	16	5	5.0000	2026-01-10	Cash	PMT-67	361	2026-01-12 14:53:09.522919	\N	5 out to jimmy
69	74	5	2550.0000	2026-01-10	Cash	PMT-69	363	2026-01-12 14:54:07.360287	\N	Received from century storr
70	40	5	700.0000	2026-01-12	Cash	PMT-70	381	2026-01-13 12:33:25.507816	\N	700 Aed out viza expanse by AR hand
71	6	5	251650.0000	2026-01-13	Cash	PMT-71	384	2026-01-13 12:48:01.645561	\N	70,000 USD @3.595 to Owais HT through Ahsan Mohsin (Dec-28-2025)
72	6	5	35950.0000	2026-01-13	Cash	PMT-72	386	2026-01-13 12:53:38.303678	\N	 10,000 USD to Owais HOUSTON@3.595 through Ahsan Mohsin (jan-08-2026)
73	6	5	71900.0000	2026-01-13	Cash	PMT-73	388	2026-01-13 12:55:45.412217	\N	20,000 USD to Owais HOUSTON @3.595 through Ahsan Mohsin (jan-09-2026)
74	15	5	26.0000	2026-01-08	Cash	PMT-74	392	2026-01-13 13:12:26.900099	\N	2,000 PKR cash received from Haseeb 137 out to Ahmed 224
75	11	5	1519.0000	2026-01-08	Cash	PMT-75	394	2026-01-13 13:14:04.187089	\N	120,000 PKR from Waqas Abdul Wahab to AR Meezan A/C
77	5	5	1659.0000	2026-01-09	Cash	PMT-77	400	2026-01-13 13:22:32.969587	\N	131,000 PKR from Faizan GR (MUHAMMAD AHSAN) to Mudassir(ON POINT IT SERVICES) Reference #516046
76	11	5	1266.0000	2026-01-08	Cash	PMT-76	398	2026-01-13 13:19:43.482655	\N	100,000 PKR Waqas MT(KULSUM ABDUL WAHAB) to AR Meezan A/C
78	11	5	924.0000	2026-01-12	Cash	PMT-78	404	2026-01-13 13:28:27.624052	\N	73,000 PKR from Waqas MT( KULSUM ABDUL WAHAB) to AR Meezan A/C
79	15	5	1747.0000	2026-01-13	Cash	PMT-79	407	2026-01-13 13:31:54.391237	\N	Cash received from Kumail Customer out to Ahsan 224
80	16	5	45350.0000	2026-01-13	Cash	PMT-80	413	2026-01-14 13:03:18.33692	\N	45,350 paid to ahsan mohsin jimmy
81	10	5	100.0000	2026-01-13	Cash	PMT-81	414	2026-01-14 13:04:03.724375	\N	Cash out to Faisal Bhai Message by Abdul Rafay
82	5	5	35000.0000	2026-01-14	Cash	PMT-82	416	2026-01-14 13:05:55.226964	\N	35000 cash out to wajahat Message by Abubaker
83	40	5	60.0000	2026-01-14	Cash	PMT-83	419	2026-01-14 13:24:16.227301	\N	60 hammali
84	37	5	64.0000	2026-01-16	Cash	PMT-84	421	2026-01-16 12:57:26.063968	\N	from AR Meezan to ARSH IMRAN (Karachi Office Internet) EXP (jan-06-2026)
85	10	5	380.0000	2026-01-16	Cash	PMT-85	423	2026-01-16 13:00:19.847326	\N	from AR Meezan to MEHREEN (Faisal Bhai) (jan-10-2026)
86	40	5	2912.0000	2026-01-16	Cash	PMT-86	425	2026-01-16 13:02:44.646528	\N	from AR Meezan to JAS TRAVELS (office exp saudi travelling exp ammi baba) jan-07-2026
87	37	5	937.0000	2026-01-16	Cash	PMT-87	427	2026-01-16 13:06:58.051599	\N	from AR Meezan to CONNECT (Karachi Office Rent ) (jan-10-2026)
88	4	5	2082.0000	2026-01-16	Cash	PMT-88	430	2026-01-16 13:09:54.334361	\N	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)
89	4	5	2082.0000	2026-01-16	Cash	PMT-89	431	2026-01-16 13:10:07.828386	\N	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)
90	4	5	1238.0000	2026-01-16	Cash	PMT-90	434	2026-01-16 13:12:04.125451	\N	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)
91	4	5	1238.0000	2026-01-16	Cash	PMT-91	435	2026-01-16 13:12:15.853559	\N	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)
92	51	5	1577.0000	2026-01-16	Cash	PMT-92	437	2026-01-16 13:17:17.595746	\N	124,516 PKR from AR Meezan to Saqib Meezan for (Maaz,Saqib,Hassan) Salary (jan-05-2026)
93	37	5	260.0000	2026-01-16	Cash	PMT-93	439	2026-01-16 13:19:07.154337	\N	20,484 from AR Meezan to Saqib Meezan Karachi Office Expense Amount (jan-05-2026)
94	16	5	139870.0000	2026-01-15	Cash	PMT-94	460	2026-01-16 16:12:16.459538	\N	Paid to ahsan Mohsin
95	16	5	163320.0000	2026-01-15	Cash	PMT-95	465	2026-01-16 16:16:21.557837	\N	163320 cash paid to ahsan Mohsin jimmy
96	37	5	886.0000	2026-01-15	Cash	PMT-96	467	2026-01-16 16:22:16.561373	\N	70,000 pkr @79 from AR Meezan to BIA'S , waqas Aslam Carry KArachi office expense 
97	37	5	139.0000	2026-01-15	Cash	PMT-97	469	2026-01-16 16:27:21.987098	\N	11,000 pkr @79 from AR Meexan to Aman Anwer , aman carry karachi office expense 
98	40	5	5100.0000	2026-01-15	Cash	PMT-98	474	2026-01-16 16:34:23.069092	\N	Cash counting machine
99	11	5	1948.0000	2026-01-15	Cash	PMT-99	476	2026-01-16 16:39:11.985567	\N	153832 pkr @79 from SHY Traders ( Sajjad Attari ) to AR Meezan 
100	40	5	300.0000	2026-01-15	Cash	PMT-100	479	2026-01-16 16:45:50.565441	\N	17 pro I cloud removed \r\n300 charges
101	117	5	44422.0000	2026-01-08	Cash	PMT-101	520	2026-01-19 14:39:07.896594	\N	CR: 2.4285 |-> 17 pro max 256 silver officeworks Castle Hills -2- @2010$  @4881.285AED | 17 pro max 256 silver officeworks Northmead -2- @2010$ @4881.285AED | Starlink Standard Kit Adil Bhai -2- @398$ @966.543AED | PS5-DISK-BUNDLE Adil Bhai -8- @629$ @1527.5265AED |  PS5-DISK-BUNDLE Adil Bhai -2- @629$ @1527.5265AED | PS5 Digital Bundle Adil Bhai -4- @477$ @1158.3945AED | PS5 Disc Bundle Adil Bai Harvey norman Alex Pending Delivery Adil Bhai -2- @629$ @1527.5265AED | 
127	16	5	57200.0000	2026-01-20	Cash	PMT-127	610	2026-01-21 12:15:32.034062	\N	57200 cash paid to ahsan mohsin jimmy
102	117	5	87863.0000	2026-01-08	Cash	PMT-102	524	2026-01-19 14:56:07.303614	\N	CR: 2.4285 |-> Iphone 17 pro max 256 Silver Office Works Northmead -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works WetheillPark -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED | Iphone 17 pro max 256 Silver Officeworks Auburn\r\n-2- @2010$ @4881.285AED
103	20	5	253.0000	2026-01-19	Cash	PMT-103	532	2026-01-19 17:03:55.800537	\N	Swiss Tech Business name renew fees Expense in Australia
104	20	5	1239.0000	2026-01-19	Cash	PMT-104	534	2026-01-19 17:05:28.218845	\N	Commsison paid Adil bhai in Australia 510 AUD
113	16	5	61905.0000	2026-01-16	Cash	PMT-113	574	2026-01-21 10:51:33.520303	\N	Paid to ahsan Mohsin jimmy
105	120	5	27741.0000	2026-01-19	Cash	PMT-105	537	2026-01-19 17:15:22.46062	\N	Shipping Charges Megatop Sydeney Expense 11,423.05 AUD @2.4285
114	16	5	45000.0000	2026-01-16	Cash	PMT-114	575	2026-01-21 10:52:16.45514	\N	Paid to ahsan Mohsin jimmy 45000 (12-01-26)
115	5	5	50000.0000	2026-01-16	Cash	PMT-115	576	2026-01-21 10:53:14.372271	\N	50,000 paid to Mudassir (w)
128	37	5	1291.0000	2026-01-20	Cash	PMT-128	613	2026-01-21 12:21:41.036037	\N	102000 pkr @79 from AR Meezan to BIA's, Waqas Aslam Carry karachi Office expense
108	13	5	300.0000	2026-01-16	Cash	PMT-108	555	2026-01-20 15:19:57.067608	\N	Cash paid to Abubaker 300
109	117	5	139238.0000	2026-01-15	Cash	PMT-109	562	2026-01-20 16:35:45.69926	\N	CR : 2.4285 |-> Iphone 17 pro max 256 Silver Harvey Norman Fyshwick Pending Delivery/ 27-12 Deposit Update -7- @2.197$ @5335.4145AED | DJI Mavic 4 Pro DJI Macquarie Park Pending Collection -8- @2490$ @6046.965AED | DJI Mic 3 combo DJI Macquarie Park Pending Collection -25- @415$ @1007.8275AED | Mac Book Pro M5 24/1TB JBHIFI Bankstown -3- @2690$ @6532.665AED | Apple Air Pods 4 ANC JBHIFI Bankstown -3- @259$ @628.9815AED | DJI Mini 4K combo JBHIFI Bankstown\r\n-3- @519$ @1260.3915AED | DJI Mic 3 combo JBHIFI Bankstown -3- @419$ @1017.5415AED
110	118	5	30719.0000	2026-01-13	Cash	PMT-110	564	2026-01-20 16:39:44.827861	\N	CR : 2.12 | -> G7X Mark III  Noel Leeming Abdul K -10- @1449$ @3071.88AED\r\n
116	40	5	7.0000	2026-01-17	Cash	PMT-116	578	2026-01-21 11:04:00.207079	\N	7 customer refreshment
111	121	5	19379.0000	2026-01-15	Cash	PMT-111	568	2026-01-20 16:46:28.868268	\N	Shipping Charges CT Freight Melbourne @7980$\r\n
112	122	5	7225.0000	2026-01-13	Cash	PMT-112	570	2026-01-20 16:49:00.36606	\N	Shipping Charges CT Freight NZ Shipping Expense\r\n
117	16	5	57000.0000	2026-01-17	Cash	PMT-117	581	2026-01-21 11:05:10.086024	\N	57000 cash paid to ahsan Mohsin jimmy
118	40	5	10.0000	2026-01-17	Cash	PMT-118	584	2026-01-21 11:07:19.089414	\N	Hammali
119	40	5	35.0000	2026-01-17	Cash	PMT-119	585	2026-01-21 11:07:39.817217	\N	35 porter deilivery charges to Adeel
120	40	5	30.0000	2026-01-17	Cash	PMT-120	586	2026-01-21 11:07:56.049673	\N	30 hammali to games Hezartoo
121	35	5	13205.0000	2026-01-17	Cash	PMT-121	587	2026-01-21 11:08:26.772347	\N	13205 cash paid to hmb
129	16	5	33585.0000	2026-01-20	Cash	PMT-129	620	2026-01-21 12:29:36.510003	\N	33585 cash paid to ahsan mohsin jimmy
106	24	5	1500.0000	2026-01-16	Cash	PMT-106	588	2026-01-20 15:09:27.393246	\N	All pending Invoice commission paid till today 1500 to Shahzad Mughal
107	24	5	50.0000	2026-01-16	Cash	PMT-107	589	2026-01-20 15:14:44.604707	\N	50 commisssion paid against Macbook to shehzad Mughal 
122	40	5	40.0000	2026-01-19	Cash	PMT-122	593	2026-01-21 11:58:31.476551	\N	40 cash out tu ZTK IP box charges
123	16	5	56050.0000	2026-01-19	Cash	PMT-123	597	2026-01-21 12:06:09.502515	\N	Paid to ahsan mohsin
124	36	5	3380.0000	2026-01-21	Cash	PMT-124	599	2026-01-21 12:06:42.634492	\N	Adjustment Entry For Humair Karachi Ledger for balancing the 10-dec s17 pro max sale
125	15	5	140000.0000	2026-01-20	Cash	PMT-125	605	2026-01-21 12:11:45.288382	\N	140,000 cash paid to ahsan cba(bank deposit)
126	40	5	10.0000	2026-01-20	Cash	PMT-126	607	2026-01-21 12:13:39.81015	\N	10 hammali
130	5	5	30000.0000	2026-01-20	Cash	PMT-130	622	2026-01-21 12:32:34.156545	\N	30000 cash out to Wajahat
131	24	5	25.0000	2026-01-20	Cash	PMT-131	624	2026-01-21 12:36:14.937134	\N	25 cash out to shaid commission
132	10	5	3165.0000	2026-01-21	Cash	PMT-132	628	2026-01-21 12:46:44.267648	\N	250000pkr @79 from AR Meezan to Fast Travels Services, Faisal Bhai 
133	10	5	190.0000	2026-01-21	Cash	PMT-133	630	2026-01-21 13:02:45.717774	\N	15000 pkr @79 from AR Meezan to Saqib Ali Khan 
134	37	5	152.2020	2026-01-21	Cash	PMT-134	632	2026-01-21 13:09:16.426595	\N	pkr 12024 @79 From Abdul Rehman Meezan to Khi Office Electric Bill , Karachi Office Expense
135	5	5	20000.0000	2026-01-21	Cash	PMT-135	634	2026-01-21 13:39:29.055954	\N	20,000 cash paid to Mudassir (Wajahat)
136	40	5	80.0000	2026-01-21	Cash	PMT-136	641	2026-01-21 14:41:14.930285	\N	80 hammali u loading Perth shipment
137	40	5	10.0000	2026-01-21	Cash	PMT-137	645	2026-01-21 15:53:57.758675	\N	10 hammali
138	40	5	15.0000	2026-01-21	Cash	PMT-138	648	2026-01-21 15:55:53.695252	\N	15 hammali
139	10	5	3797.4680	2026-01-21	Cash	PMT-139	650	2026-01-21 16:29:51.312663	\N	300000PKR @79 FROM AR MEEZAN TO ANWAR SERVICES (PRIVATE) ,received from AR out to FB
140	87	5	89609.5129	2026-01-22	Cash	PMT-140	652	2026-01-22 09:43:32.573848	\N	Megatop Shipping invoices total amount for the month of december
141	40	5	30.0000	2026-01-22	Cash	PMT-141	659	2026-01-22 10:36:07.711609	\N	30 hammali
142	35	5	7195.0000	2026-01-22	Cash	PMT-142	662	2026-01-22 10:40:42.079568	\N	7195 paid to hmb
143	5	5	1898.7340	2026-01-15	Cash	PMT-143	669	2026-01-22 11:48:28.705134	\N	pkr 150,000 @79 from Muhammad Ahsan to On Point It services(Mudassir) , Faizan Ground
144	37	5	25.3160	2026-01-15	Cash	PMT-144	671	2026-01-22 11:52:24.366965	\N	pkr 2000 @79 , 2K Cash Out to Moshin Software Samsung Z Flip FRP
146	11	5	3924.0500	2026-01-17	Cash	PMT-146	675	2026-01-22 12:01:05.053291	\N	pkr 310,000 @79 , from Huzaifa (7500) - Abdullah (300000) - Huzaifa (2500) to AR Meezan,  by Ahmed Star City
147	5	5	2594.9360	2026-01-20	Cash	PMT-147	677	2026-01-22 12:04:29.863113	\N	205,000 pkr @79 , from Muhammad Areeb Batla to On Point IT Services ( Mudassir ) , By Faizan Ground
148	11	5	1962.0250	2026-01-20	Cash	PMT-148	683	2026-01-22 12:16:49.644679	\N	pkr 155,000 @79 , from Zeeshan to AR Meezan through RAAST , By Zeeshan FARIYA
149	11	5	1898.7340	2026-01-21	Cash	PMT-149	685	2026-01-22 12:19:34.284542	\N	150,000 pkr @79 , By Ali Raza to AR MEezan , by Zeeshan Fariya
150	87	5	7134.0968	2026-01-22	Cash	PMT-150	736	2026-01-22 16:34:04.609738	\N	3,365.14 NZD @2.12 all invoices till december out to Shipping Exp CT Freight Newzealand
151	87	5	19379.4300	2026-01-22	Cash	PMT-151	738	2026-01-22 16:37:19.346086	\N	7980 AUD @ 2.4285 shipping invoices CT Freight Melbourne for december
145	5	5	1620.2530	2026-01-16	Cash	PMT-145	739	2026-01-22 11:55:10.692945	\N	pkr 128,000 @79 , from Muhammad Ahsan To On Point IT Services , Faizan Ground
152	16	5	54900.0000	2026-01-22	Cash	PMT-152	742	2026-01-23 11:50:10.418399	\N	54900 paid to Ahsan Mohsin
153	6	5	179750.0000	2026-01-17	Cash	PMT-153	744	2026-01-23 12:20:40.028859	\N	(09-1-26) 50,000 usd paid to owais Houston through Ahsan Mohsin
154	6	5	179750.0000	2026-01-17	Cash	PMT-154	746	2026-01-23 12:22:10.30068	\N	(14-1-26)  50,000 usd received from ahsan Mohsin @3.595 paid to Owais HT
155	40	5	25.0000	2026-01-22	Cash	PMT-155	750	2026-01-23 13:51:11.77336	\N	15 Hammali, 10 Hammali
156	16	5	29500.0000	2026-01-22	Cash	PMT-156	752	2026-01-23 13:53:35.907833	\N	Paid to ahsan Mohsin ayaaz
157	15	5	20000.0000	2026-01-23	Cash	PMT-157	754	2026-01-23 13:56:01.899528	\N	20,000 out to ahsan cba amgt
158	16	5	166000.0000	2026-01-23	Cash	PMT-158	755	2026-01-23 13:57:29.454848	\N	Ahsan Mohsin
159	11	5	2531.6400	2026-01-23	Cash	PMT-159	758	2026-01-23 14:34:30.039674	\N	pkr 200,000 @79 , from M. Sumair Qadri to AR Rehman , by Sumair Pasta
160	11	5	1037.9700	2026-01-23	Cash	PMT-160	760	2026-01-23 14:37:11.486568	\N	82,000 pkr @79 , From Muhammad Ahsan to AR Meezan , by Faizan Ground
161	11	5	1936.7000	2026-01-23	Cash	PMT-161	762	2026-01-23 14:41:28.383611	\N	pkr 153,000 @79 , from Ali Raza to Abdul Rehman Meezan , by Zeeshan Fariya
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
99	4	2026-01-22	218815.17	699
38	4	2026-01-05	1544.65	40
89	113	2026-01-15	7000.00	499
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
83	6	2026-01-10	112919.80	331
51	6	2026-01-05	7760.28	55
68	8	2026-01-05	77.00	77
52	6	2026-01-05	2586.76	56
53	6	2026-01-05	646.00	57
80	4	2026-01-05	9960.00	131
54	6	2026-01-05	8862.00	58
69	5	2026-01-07	2700.00	118
55	6	2026-01-05	791.00	59
56	6	2026-01-05	6111.00	60
57	6	2026-01-05	1452.98	61
70	5	2026-01-07	2800.00	119
58	6	2026-01-05	4577.00	62
59	6	2026-01-05	14595.68	63
85	5	2026-01-14	69380.00	441
60	6	2026-01-05	3091.00	64
71	5	2026-01-07	1650.00	120
62	6	2026-01-05	42351.50	66
81	4	2026-01-05	4490.00	132
72	5	2026-01-07	2430.00	121
93	2	2026-01-19	3.00	545
98	4	2026-01-22	247151.90	695
77	6	2026-01-08	109368.00	389
6	4	2026-01-05	162.00	171
75	4	2026-01-07	11970.00	125
76	6	2026-01-07	21895.65	127
84	2	2026-01-09	4536.00	390
78	5	2026-01-08	81940.00	129
86	6	2026-01-17	275415.64	483
92	6	2026-01-19	224923.00	546
82	4	2026-01-05	23.00	173
61	6	2026-01-05	35982.00	408
87	5	2026-01-15	36600.00	496
88	35	2026-01-17	20400.00	497
94	2	2026-01-08	4.00	572
74	2	2026-01-07	32.00	734
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
500	94	174	1	4.00
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
516	98	3	50	1147.66
517	98	3	9	1152.44
518	98	3	10	1141.90
519	98	3	9	1207.22
520	98	3	8	1207.25
521	98	3	7	1207.28
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
522	98	3	124	1121.00
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
523	99	2	37	1513.37
524	99	2	11	1495.18
525	99	2	9	1513.33
526	99	2	9	1505.77
527	99	2	5	1505.80
528	99	2	9	1362.00
529	99	2	67	1483.80
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
547	74	134	1	4.00
548	74	135	1	4.00
549	74	136	1	4.00
550	74	137	1	4.00
551	74	133	1	4.00
545	74	79	2	4.00
546	74	81	1	4.00
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
299	80	1	8	958.00
300	80	3	2	1148.00
301	81	2	1	2360.00
302	81	1	3	710.00
303	6	4	1	162.00
305	82	161	23	1.00
312	83	4	6	161.78
313	83	68	11	3235.50
314	83	68	20	3163.64
315	83	68	6	1366.11
316	83	70	1	1006.60
317	83	162	8	485.32
318	77	42	4	702.00
319	77	43	3	450.00
320	77	63	2	1026.00
321	77	66	1	3060.00
322	77	68	3	3240.00
323	77	68	7	3168.00
324	77	75	1	3528.00
325	77	79	1	2628.00
326	77	80	1	2232.00
327	77	86	1	1476.00
328	77	88	1	3402.00
329	77	103	1	1260.00
330	77	105	1	720.00
331	77	106	1	648.00
332	77	136	1	630.00
333	77	138	1	1008.00
334	77	140	1	2232.00
335	77	141	1	1692.00
336	77	141	1	1692.00
337	77	142	4	738.00
338	77	143	1	1512.00
339	77	144	1	720.00
340	77	145	1	288.00
341	77	146	1	2160.00
342	77	146	1	1980.00
343	77	147	1	1548.00
344	77	148	1	1710.00
345	77	149	2	5580.00
346	77	150	1	6012.00
347	77	151	1	5868.00
348	77	152	1	2304.00
349	77	154	1	1080.00
350	77	155	1	1260.00
351	77	156	1	1260.00
352	77	157	2	1080.00
353	77	158	1	1080.00
354	84	153	3	1512.00
355	61	53	1	8628.00
356	61	54	1	9886.00
357	61	55	1	2685.00
358	61	56	1	2624.00
359	61	56	1	2517.00
360	61	59	1	2000.00
361	61	60	1	1300.00
362	61	61	1	4008.00
363	61	62	1	2334.00
374	85	67	1	3950.00
375	85	68	4	3400.00
376	85	68	2	3300.00
377	85	68	4	3080.00
378	85	70	2	2720.00
379	85	70	2	2680.00
380	85	70	2	2580.00
381	85	104	1	1350.00
382	85	152	5	2380.00
383	85	160	2	1850.00
414	86	40	4	1527.88
415	86	63	1	1258.25
416	86	67	1	3990.45
417	86	68	2	4098.30
418	86	68	13	3415.25
419	86	68	6	3379.30
420	86	68	1	3253.48
421	86	68	15	3199.55
422	86	68	12	3091.70
423	86	70	4	3738.80
424	86	70	1	3.60
425	86	75	1	4601.60
426	86	77	1	2911.95
427	86	79	1	3523.10
428	86	90	1	1096.48
429	86	102	2	2696.25
430	86	102	1	2480.55
431	86	104	1	1168.38
432	86	105	2	736.98
433	86	142	4	736.98
434	86	146	2	2157.00
435	86	151	2	5859.85
436	86	152	5	2336.75
437	86	163	1	4026.40
438	86	164	1	1438.00
439	86	165	2	2228.90
440	86	166	1	1797.50
441	86	167	1	1545.85
442	86	168	2	4493.75
443	86	169	1	3666.90
444	86	42	3	719.00
445	86	42	1	521.00
446	86	171	1	719.00
447	86	170	2	1366.00
448	86	155	2	1258.00
449	87	68	2	3300.00
450	87	68	1	3080.00
451	87	70	1	2700.00
452	87	77	3	1920.00
453	87	152	7	2380.00
454	87	105	2	900.00
455	88	172	20	1020.00
456	89	68	2	3500.00
470	92	69	1	6219.00
487	92	70	2	1010.00
498	93	66	1	1.00
499	93	152	2	1.00
493	92	66	1	3595.00
494	92	66	1	3038.00
495	92	66	1	3595.00
491	92	67	1	4008.00
460	92	68	1	4170.00
461	92	68	2	3272.00
462	92	68	1	3487.00
463	92	68	1	4170.00
464	92	68	1	3272.00
465	92	68	1	3487.00
466	92	68	1	4170.00
467	92	68	2	3128.00
468	92	68	1	3919.00
471	92	68	1	3919.00
472	92	68	1	3236.00
473	92	68	1	3487.00
474	92	68	2	4170.00
475	92	68	1	3236.00
476	92	68	1	3919.00
477	92	68	8	3236.00
478	92	68	1	3919.00
479	92	68	4	3236.00
480	92	70	3	3846.00
482	92	70	1	3847.00
483	92	70	1	3811.00
486	92	70	1	3847.00
469	92	75	1	4853.00
488	92	77	5	1797.00
497	92	97	2	4817.00
489	92	102	1	2660.00
490	92	142	1	1528.00
496	92	147	1	1618.00
481	92	159	1	4170.00
484	92	159	1	4422.00
485	92	159	2	4170.00
492	92	173	5	3918.00
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
99	11	355067541901427	t
100	12	SHP4MF2TF9Q	t
98	10	355122367429969	f
3769	516	S01E456016ER10403419	t
3770	516	S01E55901J5310256430	t
3771	516	S01E55901J5310261191	t
3772	516	S01E55901J5310258792	t
3773	516	S01E55901J5310251068	t
3774	516	S01E55A01J5310266654	t
3775	516	S01E55A01J5310266678	t
3776	516	S01E55901J5310257073	t
3777	516	S01E55901J5310261178	t
3778	516	S01E55901J5310258774	t
3779	516	S01E55901J5310261158	t
3780	517	S01E55901J5310258822	t
3781	517	S01E55901J5310261157	t
3782	517	S01E55A01J5310266653	t
3783	517	S01E55901J5310257080	t
3784	517	S01E55901J5310251070	t
3785	517	S01E55901J5310257041	t
3786	517	S01E55901J5310258777	t
3787	517	S01E55A01J5310266651	t
3788	517	S01E55901J5310257042	t
3789	518	S01E55A01J5310266698	t
3790	518	S01E55A01J5310266640	t
3791	518	S01E55901J5310258737	t
3792	518	S01E55A01J5310266652	t
3793	518	S01E55901J5310261152	t
3794	518	S01E55A01J5310261220	t
3795	518	S01E55901J5310257074	t
3796	518	S01E55901J5310261192	t
3797	518	S01E55901J5310258738	t
3798	518	S01E55901J5310258802	t
3799	519	S01E55901J5310258823	t
3800	519	S01E55901J5310258779	t
3801	519	S01E55A01J5310266681	t
3802	519	S01E55901J5310257093	t
3803	519	S01E55901J5310258770	t
3804	519	S01E55A01J5310261214	t
3805	519	S01E55901J5310258821	t
3806	519	S01E55901J5310261165	t
3807	519	S01E55A01J5310266655	t
3808	520	S01E55A01J5310266639	t
3809	520	S01E55A01J5310266697	t
3810	520	S01E55901J5310257035	t
466	28	psvr200001	t
467	28	psvr200002	t
468	28	psvr200003	t
469	28	psvr200004	t
471	29	1581F9DEC258W02910YR	t
3811	520	S01E55A01J5310261219	t
3812	520	S01E55A01J5310266661	t
478	30	1581F9DEC258U029X6E4	t
3813	520	S01E55901J5310251067	t
3814	520	S01E55901J5310261166	t
3815	520	S01E55901J5310258791	t
483	31	1581F9DEC258M0298CTZ	t
3816	521	S01E55901J5310258814	t
3817	521	S01E55901J5310257079	t
3818	521	S01E55A01J5310261213	t
2494	296	352190327421734	f
2462	287	350208033173753	f
3819	521	ps5slimdigital00050	t
3820	521	ps5slimdigital00051	t
3821	521	ps5slimdigital00052	t
3822	521	ps5slimdigital00053	t
2465	287	356250549139179	f
498	33	1581F986C257S0022VS4	t
499	33	djimavic4ceratorcombo0001	t
500	33	djimavic4ceratorcombo0002	t
3761	516	S01F55701RRC10253396	f
504	35	djimavic4proflymorecombo00001	t
502	34	1581F8LQC253G0020HJ4	f
501	34	1581F8LQC255A0021ZQA	f
487	32	1581F9DEC25AL0291CTX	f
491	32	1581F9DEC25A90292N7Y	f
492	32	1581F9DEC25AK029B5VH	f
494	32	1581F9DEC25B3029PV6M	f
477	30	1581F9DEC259A029V3M1	f
472	29	1581F9DEC258S029B1UX	f
474	30	1581F9DEC258W0291QN2	f
470	29	1581F9DEC2592029S107	f
482	30	1581F9DEC258W0293K3G	f
475	30	1581F9DEC258H029J9SS	f
3757	516	S01V558019CN10250136	f
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
529	38	1581F6Z9A24CRML3CZ3H	t
530	38	1581F6Z9A248WML359Z9	t
531	38	1581F6Z9A248WML3V5FG	t
532	39	1581F6Z9A248WML302VE	t
536	39	1581F6Z9A248WML3KK1E	t
540	41	1581F6Z9C254F003E8PX	t
541	41	1581F6Z9C251C003BCNG	t
542	41	1581F6Z9C2458003SP1X	t
543	41	1581F6Z9C251D003BKKT	t
544	41	1581F6Z9C253R003CSR1	t
545	41	1581F6Z9C251D003BN7E	t
546	41	1581F6Z9C251C003BAQ4	t
549	41	1581F6Z9C254C003E003	t
550	41	1581F6Z9C2466003V1W2	t
619	44	9SDXN8L0124RC5	f
618	44	9SDXN4F012075H	f
568	42	1581F8PJC24BL0020T9Q	t
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
2503	298	357586344726028	f
604	44	9SDXN7G0221TMP	t
2474	290	356188163778437	f
606	44	9SDXN6Q0122K0Z	t
607	44	9SDXN9N012613Q	t
557	42	1581F8PJC24CS0022S3P	f
609	44	9SDXN570120SUR	t
610	44	9SDXN9N01261ER	t
575	42	1581F8PJC24BP00212CD	f
566	42	1581F8PJC24CR0022MKF	f
571	42	1581F8PJC253V001H1V5	f
614	44	9SDXN9N0126472	t
615	44	8PBWN8K0069TGQ	t
562	42	1581F8PJC24B6001BKXK	f
617	44	8PBWN8M006A8XU	t
620	44	9SDXN9N01261FN	t
621	44	9SDXNA70126HJ6	t
572	42	1581F8PJC24CR0022JYK	f
623	44	9SDXN7B0122ZFE	t
624	44	9SDXN7H0123A7B	t
625	44	9SDXN950125ESB	t
626	44	9SDXN980233VAF	t
627	44	9SDXN660220J7G	t
628	44	9SDXN5K02202MW	t
629	44	9SDXN980233W52	t
558	42	1581F8PJC24CR0022JYA	f
552	42	1581F8PJC24B5001BCXM	f
573	42	1581F8PJC24BC00202KW	f
569	42	1581F8PJC24CR0022LFH	f
533	39	1581F6Z9A248WML33640	f
534	39	1581F6Z9A24CRML37S28	f
528	38	1581F6Z9A24CRML3JZY0	f
3823	522	ps5slimdigital00054	t
3824	522	ps5slimdigital00055	t
3825	522	ps5slimdigital00056	t
3826	522	ps5slimdigital00057	t
554	42	1581F8PJC24CR0022N4Y	f
565	42	1581F8PJC24CQ0022HSV	f
555	42	1581F8PJC24BN00210EG	f
567	42	1581F8PJC24CQ0022HMQ	f
553	42	1581F8PJC24BL0020SV0	f
576	42	1581F8PJC24CR0022K1X	f
551	42	1581F8PJC253V001GYLW	f
537	40	1581F6Z9C2489003YS6P	f
538	40	1581F6Z9A24A1ML3ZC4G	f
535	39	1581F6Z9A24CRML3TKW1	f
563	42	1581F8PJC24BF0020EU1	f
564	42	1581F8PJC24CR0022M1Z	f
539	40	1581F6Z9A249DML38T1H	f
547	41	1581F6Z9C254D003E2UE	f
574	42	1581F8PJC24BN0020ZS4	f
556	42	1581F8PJC24BN00210P6	f
561	42	1581F8PJC253V001H1V2	f
548	41	1581F6Z9C24AX0034Z36	f
577	42	1581F8PJC24BP002137K	f
570	42	1581F8PJC24AK0009PEJ	f
3827	522	ps5slimdigital00058	t
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
680	50	]C121115082000637	f
616	44	9SDXN5E01214SH	f
608	44	9SDXN5K0220150	f
2457	285	350795041545725	f
2458	285	357223745121191	f
3828	522	ps5slimdigital00059	t
3829	522	ps5slimdigital00060	t
666	49	]C121105082001945	f
665	49	]C121105082001943	f
612	44	9SDXN6S02219C8	f
611	44	9SDXN9N0126152	f
603	44	9SDXN6D012292X	f
613	44	9SDXN6U0122PYR	f
622	44	9SDXN7B0122ZUB	f
605	44	9SDXN980233VD9	f
681	50	]C121115082000643	f
675	50	]C121105082001939	f
667	49	]C121095082002402	f
668	49	]C121085082000785	f
3830	522	ps5slimdigital00061	t
3831	522	ps5slimdigital00062	t
682	50	]C121115082000173	t
683	50	]C121115082000175	t
684	50	]C121115082000176	t
669	49	]C121095082001715	f
700	51	]C121115081000720	f
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
655	48	]C121105082000101	f
654	47	]C121105082000106	f
653	47	]C121105082000293	f
701	51	]C121115081000723	f
699	51	]C121115081000722	f
698	51	]C121115081000721	f
702	51	]C121095081000253	f
677	50	]C121105082001947	f
676	50	]C121105082001940	f
3832	522	ps5slimdigital00063	t
3833	522	ps5slimdigital00064	t
3834	522	ps5slimdigital00065	t
3835	522	ps5slimdigital00066	t
670	49	]C121095082002349	f
685	50	]C121115082000636	f
678	50	]C121105082001944	f
679	50	]C121105082001942	f
673	49	]C121085082000927	f
672	49	]C121095082001792	f
2104	97	SMH6XKV42GN	f
2030	84	SJWMFJKY3N4	f
2031	84	SL7XYP0G23D	f
2032	84	SG720G7T46C	f
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
3836	522	ps5slimdigital00067	t
3837	522	ps5slimdigital00068	t
3838	522	ps5slimdigital00069	t
3839	522	ps5slimdigital00070	t
3840	522	ps5slimdigital00071	t
3841	522	ps5slimdigital00072	t
3842	522	ps5slimdigital00073	t
3843	522	ps5slimdigital00074	t
3844	522	ps5slimdigital00075	t
3845	522	ps5slimdigital00076	t
3846	522	ps5slimdigital00077	t
3847	522	ps5slimdigital00078	t
3848	522	ps5slimdigital00079	t
3849	522	ps5slimdigital00080	t
3850	522	ps5slimdigital00081	t
3851	522	ps5slimdigital00082	t
3852	522	ps5slimdigital00083	t
3853	522	ps5slimdigital00084	t
3854	522	ps5slimdigital00085	t
3855	522	ps5slimdigital00086	t
3856	522	ps5slimdigital00087	t
3857	522	ps5slimdigital00088	t
3858	522	ps5slimdigital00089	t
3859	522	ps5slimdigital00090	t
3860	522	ps5slimdigital00091	t
3861	522	ps5slimdigital00092	t
3862	522	ps5slimdigital00093	t
3863	522	ps5slimdigital00094	t
3864	522	ps5slimdigital00095	t
3865	522	ps5slimdigital00096	t
3866	522	ps5slimdigital00097	t
3867	522	ps5slimdigital00098	t
3868	522	ps5slimdigital00099	t
3869	522	ps5slimdigital00100	t
3870	522	ps5slimdigital00101	t
3871	522	ps5slimdigital00102	t
3872	522	ps5slimdigital00103	t
3873	522	ps5slimdigital00104	t
2504	298	350889864968799	f
2507	298	358051322301210	f
2506	298	356188163860573	f
2467	287	352190324660847	f
2459	286	351317522499402	f
2496	296	356661405453746	f
2460	287	356250549251677	f
3874	522	ps5slimdigital00105	t
1652	60	starlinkv40150	f
1653	60	starlinkv40151	f
1654	60	starlinkv40152	f
1655	60	starlinkv40153	f
1656	60	starlinkv40154	f
1657	60	starlinkv40155	f
1658	60	starlinkv40156	f
1659	60	starlinkv40157	f
1660	60	starlinkv40158	f
1661	60	starlinkv40159	f
485	31	1581F9DEC259202929ZB	f
480	30	1581F9DEC258S0294XWP	f
493	32	1581F9DEC25AL029R2T3	f
476	30	1581F9DEC25920299MLT	f
484	31	1581F9DEC258W029027D	f
3875	522	ps5slimdigital00106	t
3876	522	ps5slimdigital00107	t
3877	522	ps5slimdigital00108	t
3878	522	ps5slimdigital00109	t
3879	522	ps5slimdigital00110	t
3880	522	ps5slimdigital00111	t
3881	522	ps5slimdigital00112	t
3882	522	ps5slimdigital00113	t
3883	522	ps5slimdigital00114	t
3884	522	ps5slimdigital00115	t
2477	291	352673830520696	f
2131	112	359132192725040	f
2130	112	359132196544314	f
2478	291	355201220205269	f
2455	283	358135794723439	f
2485	292	358135794112948	f
2484	292	356187983372108	f
2454	283	358135794483430	f
1334	54	instaxfilm20pack00361	f
1335	54	instaxfilm20pack00362	f
1336	54	instaxfilm20pack00363	f
1337	54	instaxfilm20pack00364	f
1338	54	instaxfilm20pack00365	f
1339	54	instaxfilm20pack00366	f
1340	54	instaxfilm20pack00367	f
1341	54	instaxfilm20pack00368	f
1342	54	instaxfilm20pack00369	f
1343	54	instaxfilm20pack00370	f
1344	54	instaxfilm20pack00371	f
1345	54	instaxfilm20pack00372	f
1346	54	instaxfilm20pack00373	f
1347	54	instaxfilm20pack00374	f
1348	54	instaxfilm20pack00375	f
1349	54	instaxfilm20pack00376	f
1686	60	starlinkv40184	f
1687	60	starlinkv40185	f
1688	60	starlinkv40186	f
1689	60	starlinkv40187	f
1690	60	starlinkv40188	f
1691	60	starlinkv40189	f
1692	60	starlinkv40190	f
1693	60	starlinkv40191	f
1694	60	starlinkv40192	f
1695	60	starlinkv40193	f
1696	60	starlinkv40194	f
1697	60	starlinkv40195	f
1698	60	starlinkv40196	f
1699	60	starlinkv40197	f
1700	60	starlinkv40198	f
1701	60	starlinkv40199	f
1702	60	starlinkv40200	f
1703	60	starlinkv40201	f
1704	60	starlinkv40202	f
1705	60	starlinkv40203	f
1706	60	starlinkv40204	f
1707	60	starlinkv40205	f
1708	60	starlinkv40206	f
1709	60	starlinkv40207	f
1710	60	starlinkv40208	f
1711	60	starlinkv40209	f
1712	61	starlinkv40210	f
1713	61	starlinkv40211	f
1714	61	starlinkv40212	f
1715	61	starlinkv40213	f
1716	61	starlinkv40214	f
1717	61	starlinkv40215	f
1718	61	starlinkv40216	f
1719	61	starlinkv40217	f
1720	61	starlinkv40218	f
1721	61	starlinkv40219	f
1722	61	starlinkv40220	f
1723	61	starlinkv40221	f
1724	61	starlinkv40222	f
1725	61	starlinkv40223	f
1726	61	starlinkv40224	f
1727	61	starlinkv40225	f
1728	61	starlinkv40226	f
1729	61	starlinkv40227	f
1730	61	starlinkv40228	f
1731	61	starlinkv40229	f
1732	61	starlinkv40230	f
1733	61	starlinkv40231	f
1734	61	starlinkv40232	f
1735	61	starlinkv40233	f
1736	61	starlinkv40234	f
1737	61	starlinkv40235	f
1738	61	starlinkv40236	f
1739	61	starlinkv40237	f
1740	61	starlinkv40238	f
1741	61	starlinkv40239	f
1742	61	starlinkv40240	f
1743	61	starlinkv40241	f
1744	61	starlinkv40242	f
1745	61	starlinkv40243	f
1746	61	starlinkv40244	f
1747	61	starlinkv40245	f
1748	61	starlinkv40246	f
1749	61	starlinkv40247	f
1750	61	starlinkv40248	f
1751	61	starlinkv40249	f
1752	61	starlinkv40250	f
1753	61	starlinkv40251	f
1754	61	starlinkv40252	f
1755	61	starlinkv40253	f
1756	61	starlinkv40254	f
1757	61	starlinkv40255	f
1758	61	starlinkv40256	f
1759	61	starlinkv40257	f
1760	61	starlinkv40258	f
1761	61	starlinkv40259	f
1288	54	instaxfilm20pack00315	f
1289	54	instaxfilm20pack00316	f
1290	54	instaxfilm20pack00317	f
1291	54	instaxfilm20pack00318	f
1292	54	instaxfilm20pack00319	f
1293	54	instaxfilm20pack00320	f
1294	54	instaxfilm20pack00321	f
1295	54	instaxfilm20pack00322	f
1296	54	instaxfilm20pack00323	f
1297	54	instaxfilm20pack00324	f
1298	54	instaxfilm20pack00325	f
1299	54	instaxfilm20pack00326	f
1300	54	instaxfilm20pack00327	f
1301	54	instaxfilm20pack00328	f
1302	54	instaxfilm20pack00329	f
1303	54	instaxfilm20pack00330	f
1304	54	instaxfilm20pack00331	f
1305	54	instaxfilm20pack00332	f
1306	54	instaxfilm20pack00333	f
1307	54	instaxfilm20pack00334	f
1308	54	instaxfilm20pack00335	f
1309	54	instaxfilm20pack00336	f
1310	54	instaxfilm20pack00337	f
1311	54	instaxfilm20pack00338	f
1312	54	instaxfilm20pack00339	f
1313	54	instaxfilm20pack00340	f
1314	54	instaxfilm20pack00341	f
1315	54	instaxfilm20pack00342	f
1316	54	instaxfilm20pack00343	f
1317	54	instaxfilm20pack00344	f
1318	54	instaxfilm20pack00345	f
1319	54	instaxfilm20pack00346	f
1320	54	instaxfilm20pack00347	f
1321	54	instaxfilm20pack00348	f
1322	54	instaxfilm20pack00349	f
1323	54	instaxfilm20pack00350	f
1324	54	instaxfilm20pack00351	f
1325	54	instaxfilm20pack00352	f
1326	54	instaxfilm20pack00353	f
1327	54	instaxfilm20pack00354	f
1328	54	instaxfilm20pack00355	f
1329	54	instaxfilm20pack00356	f
1330	54	instaxfilm20pack00357	f
1331	54	instaxfilm20pack00358	f
1332	54	instaxfilm20pack00359	f
1333	54	instaxfilm20pack00360	f
1350	54	instaxfilm20pack00377	f
1351	54	instaxfilm20pack00378	f
1352	54	instaxfilm20pack00379	f
1353	54	instaxfilm20pack00380	f
1354	54	instaxfilm20pack00381	f
1355	54	instaxfilm20pack00382	f
1356	54	instaxfilm20pack00383	f
1357	54	instaxfilm20pack00384	f
1358	54	instaxfilm20pack00385	f
1359	54	instaxfilm20pack00386	f
1360	54	instaxfilm20pack00387	f
1361	54	instaxfilm20pack00388	f
1362	54	instaxfilm20pack00389	f
1363	54	instaxfilm20pack00390	f
1364	54	instaxfilm20pack00391	f
1365	54	instaxfilm20pack00392	f
1366	54	instaxfilm20pack00393	f
1367	54	instaxfilm20pack00394	f
1368	54	instaxfilm20pack00395	f
1369	54	instaxfilm20pack00396	f
1370	54	instaxfilm20pack00397	f
1371	54	instaxfilm20pack00398	f
1372	54	instaxfilm20pack00399	f
1373	54	instaxfilm20pack00400	f
1374	54	instaxfilm20pack00401	f
1375	54	instaxfilm20pack00402	f
1376	54	instaxfilm20pack00403	f
1377	54	instaxfilm20pack00404	f
1378	54	instaxfilm20pack00405	f
1379	54	instaxfilm20pack00406	f
1380	54	instaxfilm20pack00407	f
1381	54	instaxfilm20pack00408	f
1382	54	instaxfilm20pack00409	f
1383	54	instaxfilm20pack00410	f
1384	54	instaxfilm20pack00411	f
1385	54	instaxfilm20pack00412	f
1386	54	instaxfilm20pack00413	f
1387	54	instaxfilm20pack00414	f
1388	54	instaxfilm20pack00415	f
1389	54	instaxfilm20pack00416	f
1390	54	instaxfilm20pack00417	f
1391	54	instaxfilm20pack00418	f
1392	54	instaxfilm20pack00419	f
1393	54	instaxfilm20pack00420	f
1394	54	instaxfilm20pack00421	f
1395	54	instaxfilm20pack00422	f
1396	54	instaxfilm20pack00423	f
1397	54	instaxfilm20pack00424	f
1398	54	instaxfilm20pack00425	f
1399	54	instaxfilm20pack00426	f
1400	54	instaxfilm20pack00427	f
1401	54	instaxfilm20pack00428	f
1402	54	instaxfilm20pack00429	f
1403	54	instaxfilm20pack00430	f
1404	54	instaxfilm20pack00431	f
1405	54	instaxfilm20pack00432	f
1406	54	instaxfilm20pack00433	f
1407	54	instaxfilm20pack00434	f
1408	54	instaxfilm20pack00435	f
1409	54	instaxfilm20pack00436	f
1410	54	instaxfilm20pack00437	f
1411	54	instaxfilm20pack00438	f
1412	54	instaxfilm20pack00439	f
1413	54	instaxfilm20pack00440	f
1414	54	instaxfilm20pack00441	f
1415	54	instaxfilm20pack00442	f
1416	54	instaxfilm20pack00443	f
1417	54	instaxfilm20pack00444	f
1418	54	instaxfilm20pack00445	f
1419	54	instaxfilm20pack00446	f
1420	54	instaxfilm20pack00447	f
1421	54	instaxfilm20pack00448	f
1422	54	instaxfilm20pack00449	f
1423	54	instaxfilm20pack00450	f
3885	522	ps5slimdigital00116	t
3886	522	ps5slimdigital00117	t
2634	313	357063607465264	t
2655	314	353263427082901	f
2647	314	359912586795810	f
2646	314	353263426755861	f
2648	314	356188162356185	f
2650	314	350889862475052	f
2653	314	359614546217410	f
2638	313	350889865663902	f
2631	313	359802898116179	f
2633	313	356605223669785	f
2658	314	356605222182244	f
2632	313	359614541233842	f
2637	313	350889867176291	f
2628	313	352791394722647	f
2636	313	359614542002816	f
2649	314	358051321099997	f
2644	314	358051326224004	f
2641	314	356188160423706	f
2657	314	358051321426497	f
2645	314	357586344585994	f
2642	314	356188160049063	f
2651	314	350889862618701	f
2652	314	357586344610396	f
2643	314	353263427359440	f
2654	314	352791397736289	f
2656	314	356188161863918	f
2639	314	353263424083571	f
2640	314	352791396686626	f
2635	313	359614542086678	f
2629	313	353263425811954	f
2630	313	357586346058651	f
3887	522	ps5slimdigital00118	t
3888	522	ps5slimdigital00119	t
3889	522	ps5slimdigital00120	t
3890	522	ps5slimdigital00121	t
3891	522	ps5slimdigital00122	t
3892	522	ps5slimdigital00123	t
3893	522	ps5slimdigital00124	t
3894	522	ps5slimdigital00125	t
3895	522	ps5slimdigital00126	t
3896	522	ps5slimdigital00127	t
3897	522	ps5slimdigital00128	t
3898	522	ps5slimdigital00129	t
3899	522	ps5slimdigital00130	t
3900	522	ps5slimdigital00131	t
3901	522	ps5slimdigital00132	t
3902	522	ps5slimdigital00133	t
3903	522	ps5slimdigital00134	t
2666	317	dualsenseedgewirelesscontroller0001	f
2667	317	dualsenseedgewirelesscontroller0002	f
2668	317	dualsenseedgewirelesscontroller0003	f
2669	317	dualsenseedgewirelesscontroller0004	f
2670	317	dualsenseedgewirelesscontroller0005	f
1424	54	instaxfilm20pack00451	f
1425	54	instaxfilm20pack00452	f
1426	54	instaxfilm20pack00453	f
1427	54	instaxfilm20pack00454	f
1428	54	instaxfilm20pack00455	f
1429	54	instaxfilm20pack00456	f
1430	54	instaxfilm20pack00457	f
1431	54	instaxfilm20pack00458	f
1432	54	instaxfilm20pack00459	f
1433	54	instaxfilm20pack00460	f
1434	54	instaxfilm20pack00461	f
1435	54	instaxfilm20pack00462	f
1436	54	instaxfilm20pack00463	f
1437	54	instaxfilm20pack00464	f
1274	54	instaxfilm20pack00301	f
1275	54	instaxfilm20pack00302	f
1276	54	instaxfilm20pack00303	f
1277	54	instaxfilm20pack00304	f
1278	54	instaxfilm20pack00305	f
1279	54	instaxfilm20pack00306	f
1280	54	instaxfilm20pack00307	f
1281	54	instaxfilm20pack00308	f
1282	54	instaxfilm20pack00309	f
1283	54	instaxfilm20pack00310	f
1284	54	instaxfilm20pack00311	f
1285	54	instaxfilm20pack00312	f
1286	54	instaxfilm20pack00313	f
1287	54	instaxfilm20pack00314	f
2671	317	dualsenseedgewirelesscontroller0006	f
2672	317	dualsenseedgewirelesscontroller0007	f
2673	317	dualsenseedgewirelesscontroller0008	f
2659	315	356364246005268	f
2660	315	356364246059356	f
2661	315	356364245823588	f
2662	315	356764176095702	f
2663	315	357063606855754	f
2664	315	356764176012640	f
2626	312	dualsensewirelesscontroller00042	f
2627	312	dualsensewirelesscontroller00043	f
2622	312	dualsensewirelesscontroller00038	f
2623	312	dualsensewirelesscontroller00039	f
2624	312	dualsensewirelesscontroller00040	f
2625	312	dualsensewirelesscontroller00041	f
2665	316	354956977937882	f
3904	522	ps5slimdigital00135	t
3905	522	ps5slimdigital00136	t
3906	522	ps5slimdigital00137	t
3907	522	ps5slimdigital00138	t
3908	522	ps5slimdigital00139	t
3909	522	ps5slimdigital00140	t
3910	522	ps5slimdigital00141	t
3911	522	ps5slimdigital00142	t
3912	522	ps5slimdigital00143	t
3913	522	ps5slimdigital00144	t
3914	522	ps5slimdigital00145	t
3915	522	ps5slimdigital00146	t
3916	522	ps5slimdigital00147	t
3917	522	ps5slimdigital00148	t
2674	318	SD2WYWYFPLV	f
671	49	]C121095082001773	f
674	49	]C121085082000922	f
2683	321	358112930542452	t
2684	322	359912587219711	t
2685	322	359614541610171	t
2686	322	359614540060931	t
2687	323	358051322533887	t
2688	323	353837419391642	t
2677	318	SM7RR6FRW7N	f
2675	318	SDX9XWFKW42	f
2695	325	355008282401839	t
2696	326	357719281961635	t
2697	327	357773240293275	t
2698	328	356334540274274	t
2699	329	353685834007800	t
2676	318	SL9W0J24GDM	f
2702	332	353894107001488	t
2703	333	356832826585198	t
2704	334	355445520481381	t
2705	335	357762265949689	t
2706	336	357985605788059	t
2707	337	355852812209224	t
2708	337	350138782777415	t
2709	337	352515983937724	t
2710	337	350304975570948	t
2711	338	357773241392274	t
2712	339	358691739992588	t
2713	340	358229303109360	t
2714	341	SLJ2DW1GJPG	t
2715	342	SJ56LKQX91F	t
2716	343	357153132623899	t
2717	344	SM04W37XK2M	t
2718	345	SMT79VX36C5	t
2719	345	SMJF72R0W6K	t
2678	319	SMT43DHJRGH	f
2723	349	4V0ZH17H7X01K1	t
2724	350	4V37W23H8Y03BB	t
2725	351	2Q0ZT00H9108MM	t
2726	352	4V0ZS17H8H02KD	t
2727	352	4V0ZS12H8M0121	t
2728	353	2Q0ZY01H6R0088	t
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
2679	319	SK946HW04X3	f
2680	319	SGD4TR707KJ	f
2700	330	SH6W4PFQWCW	f
2681	320	350094261697964	f
2682	320	350094261355704	f
2689	323	358051321265978	f
2690	323	356605225057831	f
2691	323	350889862536879	f
2721	347	SDF9R6G97J0	f
2694	324	353263423932034	f
2720	346	SF3W6VGQT49	f
1499	57	ninjaportableblender0009	t
1500	57	ninjaportableblender0010	t
1501	58	starlinkhp00001	t
1502	58	starlinkhp00002	t
3042	466	356188161706919	f
3039	464	357826991408870	f
3044	468	356605227703804	f
3038	463	355224250996854	f
3041	465	353263427193989	f
3040	465	350889860529314	f
3045	469	356188163093639	f
3046	470	351687746863769	f
3047	471	355224251427081	f
2246	147	SDKJYYPYHW5	f
2729	354	359800206266629	t
2730	354	358344510337678	t
2731	354	359800204422869	t
1805	62	starlinkv40303	f
1806	62	starlinkv40304	f
1807	62	starlinkv40305	f
1808	62	starlinkv40306	f
1809	62	starlinkv40307	f
1810	62	starlinkv40308	f
1811	62	starlinkv40309	f
1812	62	starlinkv40310	f
1813	62	starlinkv40311	f
1814	62	starlinkv40312	f
1815	62	starlinkv40313	f
1816	62	starlinkv40314	f
1817	62	starlinkv40315	f
1818	62	starlinkv40316	f
1819	62	starlinkv40317	f
1820	62	starlinkv40318	f
1821	62	starlinkv40319	f
1822	62	starlinkv40320	f
1823	62	starlinkv40321	f
1824	62	starlinkv40322	f
1825	62	starlinkv40323	f
1826	62	starlinkv40324	f
1827	62	starlinkv40325	f
1828	62	starlinkv40326	f
1829	62	starlinkv40327	f
1830	62	starlinkv40328	f
1603	60	starlinkv40101	f
1604	60	starlinkv40102	f
1605	60	starlinkv40103	f
1606	60	starlinkv40104	f
1607	60	starlinkv40105	f
1608	60	starlinkv40106	f
1609	60	starlinkv40107	f
1610	60	starlinkv40108	f
1611	60	starlinkv40109	f
1612	60	starlinkv40110	f
1613	60	starlinkv40111	f
1614	60	starlinkv40112	f
1615	60	starlinkv40113	f
1616	60	starlinkv40114	f
1617	60	starlinkv40115	f
1618	60	starlinkv40116	f
1619	60	starlinkv40117	f
1620	60	starlinkv40118	f
1621	60	starlinkv40119	f
1622	60	starlinkv40120	f
1623	60	starlinkv40121	f
1624	60	starlinkv40122	f
1625	60	starlinkv40123	f
1626	60	starlinkv40124	f
1627	60	starlinkv40125	f
1628	60	starlinkv40126	f
1629	60	starlinkv40127	f
1630	60	starlinkv40128	f
1631	60	starlinkv40129	f
1632	60	starlinkv40130	f
1633	60	starlinkv40131	f
1831	62	starlinkv40329	f
1832	62	starlinkv40330	f
1833	62	starlinkv40331	f
1834	62	starlinkv40332	f
1835	62	starlinkv40333	f
490	32	1581F9DEC25AQ029SBVR	f
495	32	1581F9DEC25AL029CRJ2	f
496	32	1581F9DEC25AL0294V02	f
481	30	1581F9DEC258S0292B6T	f
486	31	1581F9DEC258U0294KUU	f
479	30	1581F9DEC2592029L653	f
473	30	1581F9DEC258W029589P	f
3000	455	starlinkmini0001	f
3001	455	starlinkmini0002	f
3002	455	starlinkmini0003	f
2701	331	359132197678855	f
2722	348	356187982445939	f
3003	455	starlinkmini0004	f
3004	455	starlinkmini0005	f
3005	455	starlinkmini0006	f
3006	455	starlinkmini0007	f
3007	455	starlinkmini0008	f
3008	455	starlinkmini0009	f
3009	455	starlinkmini0010	f
2692	323	353263425144000	f
2693	323	359614544687390	f
3043	467	355224255457688	f
3037	462	353263427557704	f
2555	305	5WTZN99002RTU6	t
2558	305	5WTZN8W002K4LH	t
2568	305	5WTZN8800234DJ	t
2569	305	5WTZN8N002ML5R	t
2566	305	5WTZN8P002QXC3	f
2563	305	5WTZN3N0023GL9	f
2562	305	5WTZN8D002GB8D	f
2561	305	5WTZN93002GB67	f
2549	305	5WTZN7L002SWHP	f
2551	305	5WTZN9P002P7PU	f
2565	305	5WTZN92002P48K	f
2556	305	5WTZN6N002EQW5	f
2567	305	5WTZN9N002NEBJ	f
2553	305	5WTZN88002M6E2	f
2557	305	5WTZN8T0020WX7	f
2559	305	5WTZN8P002NQ2F	f
2547	305	5WTZN8S0020274	f
2550	305	5WTZN8T0022PQ0	f
2560	305	5WTZN9S002CSL7	f
1762	61	starlinkv40260	f
1763	61	starlinkv40261	f
1764	61	starlinkv40262	f
1765	61	starlinkv40263	f
1766	61	starlinkv40264	f
1767	61	starlinkv40265	f
1637	60	starlinkv40135	f
1638	60	starlinkv40136	f
2548	305	5WTZN8S002UDXU	f
1768	61	starlinkv40266	f
1769	61	starlinkv40267	f
1770	61	starlinkv40268	f
1771	61	starlinkv40269	f
2732	355	SK6GQGF74F4	f
2552	305	5WTZN9P0020BFS	f
2564	305	5WTZN93002545V	f
2554	305	5WTZN99002381Z	f
2199	126	dualsensewirelesscontroller00031	f
2200	126	dualsensewirelesscontroller00032	f
2201	126	dualsensewirelesscontroller00033	f
2195	126	dualsensewirelesscontroller00027	f
2196	126	dualsensewirelesscontroller00028	f
2197	126	dualsensewirelesscontroller00029	f
2198	126	dualsensewirelesscontroller00030	f
2193	126	dualsensewirelesscontroller00025	f
2194	126	dualsensewirelesscontroller00026	f
2187	126	dualsensewirelesscontroller00019	f
2188	126	dualsensewirelesscontroller00020	f
2189	126	dualsensewirelesscontroller00021	f
2190	126	dualsensewirelesscontroller00022	f
1662	60	starlinkv40160	f
1663	60	starlinkv40161	f
1664	60	starlinkv40162	f
1665	60	starlinkv40163	f
1666	60	starlinkv40164	f
1667	60	starlinkv40165	f
1668	60	starlinkv40166	f
1669	60	starlinkv40167	f
1670	60	starlinkv40168	f
1671	60	starlinkv40169	f
1672	60	starlinkv40170	f
1673	60	starlinkv40171	f
1674	60	starlinkv40172	f
1675	60	starlinkv40173	f
1676	60	starlinkv40174	f
1677	60	starlinkv40175	f
1678	60	starlinkv40176	f
1679	60	starlinkv40177	f
1680	60	starlinkv40178	f
1681	60	starlinkv40179	f
1682	60	starlinkv40180	f
1683	60	starlinkv40181	f
1684	60	starlinkv40182	f
1685	60	starlinkv40183	f
2191	126	dualsensewirelesscontroller00023	f
2192	126	dualsensewirelesscontroller00024	f
2181	125	dualsensewirelesscontroller00013	f
2182	125	dualsensewirelesscontroller00014	f
2183	125	dualsensewirelesscontroller00015	f
2184	125	dualsensewirelesscontroller00016	f
2739	362	SL93Y0GWVRC	f
2734	357	ST76N06VX9D	f
2736	359	SF7J9C4WVDW	f
2735	358	SK327X51Q91	f
2737	360	SGPGK00MPQ7	f
2740	363	SC91KHM70VM	f
2733	356	SGVQ2RQRCMW	f
2738	361	SFVFHN160Q6L5	f
1846	62	starlinkv40344	f
1847	62	starlinkv40345	f
1848	62	starlinkv40346	f
1849	62	starlinkv40347	f
1850	62	starlinkv40348	f
1851	62	starlinkv40349	f
1852	62	starlinkv40350	f
1853	62	starlinkv40351	f
1854	62	starlinkv40352	f
1855	62	starlinkv40353	f
1856	62	starlinkv40354	f
1857	62	starlinkv40355	f
1858	62	starlinkv40356	f
1859	62	starlinkv40357	f
1860	62	starlinkv40358	f
1861	62	starlinkv40359	f
1862	62	starlinkv40360	f
1863	62	starlinkv40361	f
1864	62	starlinkv40362	f
1865	62	starlinkv40363	f
1866	62	starlinkv40364	f
1867	62	starlinkv40365	f
1868	62	starlinkv40366	f
1869	62	starlinkv40367	f
1870	62	starlinkv40368	f
1871	62	starlinkv40369	f
1872	62	starlinkv40370	f
1873	62	starlinkv40371	f
1874	62	starlinkv40372	f
1875	62	starlinkv40373	f
1876	62	starlinkv40374	f
1877	62	starlinkv40375	f
1878	63	starlinkv40376	f
1879	63	starlinkv40377	f
1880	63	starlinkv40378	f
1881	63	starlinkv40379	f
1882	63	starlinkv40380	f
1883	63	starlinkv40381	f
1884	63	starlinkv40382	f
1885	63	starlinkv40383	f
1886	63	starlinkv40384	f
1887	63	starlinkv40385	f
1888	63	starlinkv40386	f
1889	63	starlinkv40387	f
1890	63	starlinkv40388	f
1891	63	starlinkv40389	f
1892	63	starlinkv40390	f
1893	64	starlinkv40391	f
1894	64	starlinkv40392	f
1895	64	starlinkv40393	f
1896	64	starlinkv40394	f
1897	64	starlinkv40395	f
1898	64	starlinkv40396	f
3918	522	ps5slimdigital00149	t
3919	522	ps5slimdigital00150	t
3920	522	ps5slimdigital00151	t
3921	522	ps5slimdigital00152	t
3922	522	ps5slimdigital00153	t
3923	522	ps5slimdigital00154	t
3924	522	ps5slimdigital00155	t
3925	522	ps5slimdigital00156	t
1899	64	starlinkv40397	t
1900	64	starlinkv40398	t
1901	64	starlinkv40399	t
1902	64	starlinkv40400	t
1903	64	starlinkv40401	t
1904	64	starlinkv40402	t
1905	64	starlinkv40403	t
3926	522	ps5slimdigital00157	t
1772	62	starlinkv40270	f
3927	522	ps5slimdigital00158	t
3928	522	ps5slimdigital00159	t
3929	522	ps5slimdigital00160	t
1836	62	starlinkv40334	f
1837	62	starlinkv40335	f
1838	62	starlinkv40336	f
1839	62	starlinkv40337	f
1840	62	starlinkv40338	f
1841	62	starlinkv40339	f
1842	62	starlinkv40340	f
1843	62	starlinkv40341	f
1844	62	starlinkv40342	f
1845	62	starlinkv40343	f
1776	62	starlinkv40274	f
1777	62	starlinkv40275	f
1778	62	starlinkv40276	f
1779	62	starlinkv40277	f
3930	522	ps5slimdigital00161	t
3931	522	ps5slimdigital00162	t
3932	522	ps5slimdigital00163	t
3933	522	ps5slimdigital00164	t
3934	522	ps5slimdigital00165	t
3935	522	ps5slimdigital00166	t
3936	522	ps5slimdigital00167	t
3937	522	ps5slimdigital00168	t
3938	522	ps5slimdigital00169	t
3939	522	ps5slimdigital00170	t
3940	522	ps5slimdigital00171	t
3941	522	ps5slimdigital00172	t
3942	522	ps5slimdigital00173	t
3943	522	ps5slimdigital00174	t
3944	522	ps5slimdigital00175	t
3945	522	ps5slimdigital00176	t
3946	522	ps5slimdigital00177	t
3746	516	S01F55701RRC10252722	f
3756	516	S01F55901RRC10290683	f
3759	516	S01F55801RRC10263357	f
3752	516	S01F55901RRC10282523	f
3753	516	S01F55801RRC10263355	f
3744	516	S01F55801RRC10263353	f
3748	516	S01F55801RRC10263356	f
3749	516	S01F55801RRC10263364	f
3762	516	S01F55801RRC10263351	f
3747	516	S01F55701RRC10252874	f
3751	516	S01F55701RRC10252869	f
3743	516	S01F55701RRC10253418	f
3745	516	S01V558019CN10256717	f
3735	516	S01F55701RRC10260047	f
3760	516	S01F55701RRC10252721	f
3750	516	S01F55701RRC10253425	f
3763	516	S01F55901RRC10303746	f
3764	516	S01V558019CN10256466	f
3737	516	S01F55801RRC10263365	f
3754	516	S01F55901RRC10287502	f
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
3736	516	S01V558019CN10258939	f
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
1639	60	starlinkv40137	f
1640	60	starlinkv40138	f
1641	60	starlinkv40139	f
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
2099	92	359811269284607	t
2100	93	356334540191734	t
2101	94	356706681483527	t
2149	121	S01V55601Z1L10345699	f
3738	516	S01F55701RRC10259204	f
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
2122	107	356706681272813	t
2124	108	354123755217074	t
2125	108	354123752557134	t
2127	109	358911633611088	t
2128	110	358911632167553	t
2129	111	357550247169306	t
3768	516	S01F55901RRC10289942	f
3765	516	S01F55701RRC10252797	f
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
2153	121	S01V55601Z1L10504969	t
2154	121	S01V55601Z1L10377962	t
2155	121	S01K5560179810281816	t
2156	121	S01V55801Z1L11001841	t
2157	121	S01V55701Z1L10846630	t
2158	121	S01V55801Z1L11086063	t
2159	121	S01V55801Z1L11081301	t
2160	121	S01V55801Z1L11057425	t
2161	121	S01V55801Z1L11086045	t
2098	91	357205987236407	t
3732	516	S01V558019CN10255412	f
3767	516	S01F55901RRC10304141	f
2121	106	356422163856533	f
2103	96	SK4J0CJP9GD	f
2123	108	354123754950428	f
2126	108	354123758609392	f
2102	95	SLT21H7HQ07	f
2105	98	SCLJDXQM0M5	f
2106	98	SLW5X9YYFV4	f
2162	122	S01V55801UNL11264243	t
2163	122	S01V55901UNL11364709	t
2164	123	S01E44A01X4912823801	t
2165	123	S011558343F	t
2166	123	S0115405247	t
3755	516	S01F55701RRC10252798	f
3766	516	S01F55701RRC10253379	f
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
2245	146	SV49N6TXD96	f
1503	59	starlinkv40001	f
1504	59	starlinkv40002	f
1505	59	starlinkv40003	f
1642	60	starlinkv40140	f
2167	124	playstationportal00001	f
2168	124	playstationportal00002	f
2169	125	dualsensewirelesscontroller00001	f
2170	125	dualsensewirelesscontroller00002	f
2171	125	dualsensewirelesscontroller00003	f
2172	125	dualsensewirelesscontroller00004	f
2173	125	dualsensewirelesscontroller00005	f
2174	125	dualsensewirelesscontroller00006	f
3734	516	S01F55701RRC10253380	f
3742	516	S01F55701RRC10252801	f
3739	516	S01F55701RRC10252786	f
3758	516	S01F55901RRC10290623	f
3730	516	S01V558019CN10258177	f
3733	516	S01F55701RRC10252871	f
3731	516	S01F55701RRC10260424	f
3741	516	S01F55701RRC10252785	f
3740	516	S01F55701RRC10252873	f
2240	144	SC0Y0F9X7QC	f
2242	144	SG2D1H6GKVC	f
2241	144	SGCF92TLQXH	f
2243	144	SHLQQTX9JGW	f
2244	145	SGHJYWKVQXD	f
2281	169	352066342215865	t
2282	170	SJXKF950C3P	t
2334	209	354512320823475	f
2296	181	358419940353196	t
2297	182	359724852602210	t
2299	184	351523426490179	t
2300	185	359222381700076	t
2301	186	356541620272248	t
2302	187	356864569740201	t
2303	188	359222389749273	t
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
1506	59	starlinkv40004	f
2316	201	357494474437690	t
2317	202	358911632646218	t
2318	203	353173803445491	t
2319	204	356799836296837	t
2320	205	SJ460W9GH4F	t
2321	206	SDCLXG1749Y	t
2322	207	355783829033440	t
2294	179	353837412105817	f
2293	178	355478870898102	f
2382	238	359724859410781	f
2292	177	356764175496547	f
2298	183	358271520320685	f
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
2295	180	355122363950588	f
2357	216	350773430942266	t
1507	59	starlinkv40005	f
1508	59	starlinkv40006	f
1509	59	starlinkv40007	f
1510	59	starlinkv40008	f
1511	59	starlinkv40009	f
1512	59	starlinkv40010	f
1513	59	starlinkv40011	f
1514	59	starlinkv40012	f
2376	232	354136652903232	t
2379	235	354359265927857	t
2383	239	352676524778959	t
2385	241	351687742123226	t
2387	243	L0FVM00VD9	t
2152	121	S01V55601Z1L10345582	f
2151	121	S01V55601Z1L10304899	f
2150	121	S01V55601Z1L10458423	f
2374	231	1581F8LQC259V0025QND	f
2375	231	1581F8LQC255Q0022GVN	f
2286	174	352355706850411	f
2287	174	352355704532573	f
2288	174	352355700973722	f
2289	174	352355701807754	f
2290	175	352355709742698	f
2283	171	358112930502035	f
2284	172	358112931678883	f
2333	209	352602317458153	f
2332	209	354512323488342	f
2324	208	352758404050616	f
2327	208	358936958142898	f
2323	208	352368545956687	f
1515	59	starlinkv40013	f
1643	60	starlinkv40141	f
1644	60	starlinkv40142	f
1645	60	starlinkv40143	f
1646	60	starlinkv40144	f
1647	60	starlinkv40145	f
1648	60	starlinkv40146	f
2377	233	357463448249218	f
2381	237	356764170580642	f
2384	240	358001685550705	f
2355	214	356422165489838	f
2356	215	359103740084792	f
2380	236	351399081079239	f
2386	242	SKVNHV9WJ4J	f
2304	189	357031376241620	t
2291	176	350247150243361	f
3948	523	S01E45601CE810570281	t
3949	523	S01E45601CE810595951	t
3950	523	S01E45601CE810570323	t
3951	523	S01E45601CE810573044	t
3952	523	S01E45601CE810565094	t
3953	523	S01E45601CE810573039	t
3954	523	S01E45501CE810557417	t
3955	523	S01F44C01NXM10424000	t
3956	523	S01E45601CE810599344	t
3957	523	S01E45601CE810573040	t
3958	523	S01E45601CE810573043	t
3959	523	S01E45601CE810599343	t
3960	523	S01E45601CE810565069	t
3961	523	S01F55901DR210321979	t
3962	523	S01E45601CE810585832	t
3963	523	S01F55801DR210266420	t
3964	523	S01E45601CE810576101	t
3965	523	S01E45601CE810580025	t
3966	523	S01E45601CE810578019	t
3967	523	S01E45601CE810578011	t
3968	523	S01E45601CE810576162	t
3969	523	S01F55901DR210294300	t
3970	523	S01F55901DR210295627	t
3971	523	S01F55901DR210294297	t
3972	523	S01F55901DR210295628	t
3973	523	S01F55901DR210294298	t
3974	523	S01F55901DR210291093	t
3975	523	S01F55901DR210307406	t
3976	523	S01F55901DR210312178	t
3977	523	S01F55901DR210291063	t
3978	523	S01F55901DR210308751	t
3979	523	S01F55901DR210308695	t
3980	523	S01F55901DR210324687	t
3981	523	S01F55901DR210307410	t
3982	523	S01F55701DR210256752	t
3983	523	S01F55901DR210307414	t
3984	524	S01F55901DR210307409	t
3985	524	S01F55701DR210256751	t
3986	524	S01F55901DR210308722	t
3987	524	S01F55901DR210307418	t
3988	524	S01F55901DR210307417	t
3989	524	S01F55901DR210309768	t
3990	524	S01F55901DR210307389	t
3991	524	S01F55901DR210307390	t
2446	281	356768323979858	t
3992	524	S01F55901DR210294799	t
3993	524	S01F55901DR210308752	t
2456	284	352355700400171	t
3994	524	S01F55901DR210307405	t
3995	525	S01F55901DR210294345	t
3996	525	S01F55901DR210312177	t
3997	525	S01F55901DR210307413	t
3998	525	S01F55901DR210308942	t
3999	525	S01F55901DR210308676	t
4000	525	S01F55901DR210294299	t
4001	525	S01F55901DR210308710	t
4002	525	S01F55901DR210308696	t
4003	525	S01F55901DR210295652	t
4004	526	S01F55901DR210312011	t
4005	526	S01F55901DR210308931	t
2489	294	352355707404705	t
2509	299	starlinkv40451	t
2510	299	starlinkv40452	t
2511	299	starlinkv40453	t
2512	299	starlinkv40454	t
2513	299	starlinkv40455	t
2514	299	starlinkv40456	t
2515	299	starlinkv40457	t
2516	299	starlinkv40458	t
2517	300	ps5slimdigital00178	t
2518	300	ps5slimdigital00179	t
2519	301	ps5slim00126	t
2520	302	starlinkv40459	t
2521	302	starlinkv40460	t
2522	302	starlinkv40461	t
686	50	]C121105082001941	f
2471	290	358051322163339	f
2472	290	350889865420378	f
2492	295	350795041218463	f
2490	295	350795040883309	f
2493	295	350795041085185	f
2491	295	357247591394057	f
2479	292	355827874060491	f
2475	290	358051322098196	f
2476	290	357586344596264	f
2473	290	357586344694234	f
2497	296	356250543171277	f
2498	296	356250549338896	f
2499	296	352190327764315	f
2500	296	353708846189133	f
2468	288	350208037361842	f
2469	288	350208037531998	f
2505	298	358051322474710	f
2508	298	358051321091101	f
2448	282	355827873912551	f
2450	283	355827874548040	f
2452	283	355827874619494	f
2449	283	356768327697845	f
2451	283	356768323955908	f
2502	297	356605226033781	f
2470	289	355224250029748	f
2501	297	355450218650917	f
2447	282	355827874735076	f
2482	292	355827874760009	f
2483	292	356768328441524	f
2464	287	356250549428937	f
2466	287	350208033166849	f
2463	287	350208033299269	f
2461	287	350208033090551	f
2486	293	351878871049411	f
2487	293	351878871034231	f
2488	293	356930604129856	f
2495	296	354956974267937	f
2480	292	356768325047464	f
2453	283	355827874116541	f
2481	292	355827873857608	f
687	50	]C121105082001938	f
559	42	1581F8PJC24CR0022MDB	f
560	42	1581F8PJC24B6001BKLQ	f
2285	173	358112932166375	f
2315	200	352066342213241	f
2278	168	356196182587945	f
2279	168	356196183103940	f
2280	168	355205568606640	f
503	34	1581F8LQC252U00200ND	f
656	48	]C121105082000418	f
657	48	]C121105082000110	f
658	48	]C121105082000416	f
659	48	]C121105082000294	f
660	48	]C121105082000362	f
661	48	]C121105082000048	f
662	48	]C121105082000010	f
663	48	]C121105082000046	f
664	48	]C121095082000754	f
644	47	]C121105082000001	f
645	47	]C121105082000415	f
646	47	]C121105082000044	f
647	47	]C121105082000006	f
648	47	]C121105082000007	f
650	47	]C121105082000042	f
651	47	]C121105082000009	f
652	47	]C121105082000049	f
649	47	]C121105082000411	f
643	47	]C121105082000414	f
497	33	1581F986C258U0023MZ5	f
1516	59	starlinkv40014	f
1517	59	starlinkv40015	f
1518	59	starlinkv40016	f
1519	59	starlinkv40017	f
1520	59	starlinkv40018	f
1521	59	starlinkv40019	f
1522	59	starlinkv40020	f
1523	59	starlinkv40021	f
1524	59	starlinkv40022	f
1525	59	starlinkv40023	f
1526	59	starlinkv40024	f
1527	59	starlinkv40025	f
1528	59	starlinkv40026	f
1529	59	starlinkv40027	f
1530	59	starlinkv40028	f
1531	59	starlinkv40029	f
1532	59	starlinkv40030	f
1533	59	starlinkv40031	f
1534	59	starlinkv40032	f
1535	59	starlinkv40033	f
1536	59	starlinkv40034	f
1537	59	starlinkv40035	f
1538	59	starlinkv40036	f
1539	59	starlinkv40037	f
1540	59	starlinkv40038	f
1541	59	starlinkv40039	f
1542	59	starlinkv40040	f
1543	59	starlinkv40041	f
1544	59	starlinkv40042	f
1545	59	starlinkv40043	f
1546	59	starlinkv40044	f
1547	59	starlinkv40045	f
1548	59	starlinkv40046	f
1549	59	starlinkv40047	f
1550	59	starlinkv40048	f
1551	59	starlinkv40049	f
1552	59	starlinkv40050	f
1553	60	starlinkv40051	f
1554	60	starlinkv40052	f
1555	60	starlinkv40053	f
1556	60	starlinkv40054	f
1557	60	starlinkv40055	f
1558	60	starlinkv40056	f
1559	60	starlinkv40057	f
1560	60	starlinkv40058	f
1561	60	starlinkv40059	f
1562	60	starlinkv40060	f
1563	60	starlinkv40061	f
1564	60	starlinkv40062	f
1565	60	starlinkv40063	f
1566	60	starlinkv40064	f
1567	60	starlinkv40065	f
1568	60	starlinkv40066	f
1569	60	starlinkv40067	f
1570	60	starlinkv40068	f
1571	60	starlinkv40069	f
1572	60	starlinkv40070	f
1573	60	starlinkv40071	f
1574	60	starlinkv40072	f
1575	60	starlinkv40073	f
1576	60	starlinkv40074	f
1577	60	starlinkv40075	f
1578	60	starlinkv40076	f
1579	60	starlinkv40077	f
1580	60	starlinkv40078	f
1581	60	starlinkv40079	f
1582	60	starlinkv40080	f
1583	60	starlinkv40081	f
1584	60	starlinkv40082	f
1585	60	starlinkv40083	f
1586	60	starlinkv40084	f
1587	60	starlinkv40085	f
1588	60	starlinkv40086	f
1589	60	starlinkv40087	f
1590	60	starlinkv40088	f
1591	60	starlinkv40089	f
1592	60	starlinkv40090	f
1593	60	starlinkv40091	f
1594	60	starlinkv40092	f
1595	60	starlinkv40093	f
1596	60	starlinkv40094	f
1597	60	starlinkv40095	f
1598	60	starlinkv40096	f
1599	60	starlinkv40097	f
1600	60	starlinkv40098	f
1601	60	starlinkv40099	f
1602	60	starlinkv40100	f
1634	60	starlinkv40132	f
1635	60	starlinkv40133	f
1636	60	starlinkv40134	f
4006	526	S01F55901DR210294788	t
4007	526	ps5slim00039	t
4008	526	ps5slim00040	t
4009	526	ps5slim00041	t
4010	526	ps5slim00042	t
4011	526	ps5slim00043	t
4012	526	ps5slim00044	t
4013	527	ps5slim00045	t
4014	527	ps5slim00046	t
4015	527	ps5slim00047	t
4016	527	ps5slim00048	t
4017	527	ps5slim00049	t
4018	528	ps5slim00050	t
2944	426	355413813310535	f
1649	60	starlinkv40147	f
1650	60	starlinkv40148	f
1651	60	starlinkv40149	f
2925	421	356605220228296	f
4019	528	ps5slim00051	t
4020	528	ps5slim00052	t
4021	528	ps5slim00053	t
1773	62	starlinkv40271	f
1774	62	starlinkv40272	f
1775	62	starlinkv40273	f
2883	414	2G97BMMHB601P5	t
2884	414	2G97BMMHB601NY	t
2885	414	2G97BMMHB600R2	t
2886	414	2G97BMMHB6010Y	t
2887	415	359655271258475	t
2888	416	352355705267526	t
4022	528	ps5slim00054	t
4023	528	ps5slim00055	t
2914	421	357826993263109	t
2919	421	356605226470314	t
2945	427	358594364461483	t
2950	431	SFPXDW0F6CT	t
2953	433	355852813543027	t
2954	433	355852813455594	t
2955	433	352700323139724	t
2956	433	357020913138365	t
2957	434	SC74KD030F2	t
2958	434	SLJJ2LCQ36Y	t
2959	435	SFF97Y7172H	t
2960	435	SHFW30C4DQ0	t
2966	437	SM5J2KJ4X0Q	t
2967	438	FW1A31902D02	t
2968	439	AFYZZ542048F7	t
2969	439	AFYZZ53701D2A	t
2970	440	AFVZZ53401A7C	t
2971	441	SK29QKJJJWP	t
2972	442	SFX9RCXGJ32	t
2973	442	SFNVN41YFM6	t
2974	443	359222380879988	t
2979	446	SM37D7CT6GQ	t
2980	447	3Z37V01H9Z02GQ	t
2981	447	3Z37V03HBM007D	t
2982	448	4V37W32HBM006R	t
2983	448	4V0ZW26H9901XZ	t
2893	418	355450217184959	f
2897	418	355450219567110	f
2896	418	350889861204131	f
2906	419	356605228798647	f
2909	419	356605228327546	f
2907	419	356605228254161	f
2903	418	356605227911035	f
2935	422	355224254052001	f
2928	422	355224250070676	f
2934	422	350889866041819	f
2933	422	356605226024244	f
2926	422	355224250266969	f
2937	422	355224250889430	f
2930	422	355224251493604	f
2929	422	355224251542483	f
2932	422	358051326069136	f
2927	422	358051326418366	f
2931	422	359426269498758	f
2936	422	358051326306199	f
2891	418	350889861168955	f
2898	418	356188165309348	f
2895	418	355450216932796	f
2915	421	359426269639708	f
2913	421	359614544913366	f
2920	421	356188163896601	f
2922	421	358482497669539	f
2910	420	357586348805398	f
2942	424	359572768921269	f
2921	421	359614546774345	f
2912	421	359614547089768	f
2924	421	356188166134521	f
2917	421	357063606283254	f
2916	421	353263425398234	f
2918	421	357586344621054	f
2923	421	356605226216295	f
2911	421	356188164272612	f
2961	436	358135792809040	f
2962	436	355827874792937	f
2963	436	355827873795535	f
2964	436	358135790828976	f
2965	436	353938643193174	f
2523	303	711719575894	f
2202	126	dualsensewirelesscontroller00034	f
2203	126	dualsensewirelesscontroller00035	f
2204	126	dualsensewirelesscontroller00036	f
2205	126	dualsensewirelesscontroller00037	f
2185	125	dualsensewirelesscontroller00017	f
2186	125	dualsensewirelesscontroller00018	f
2177	125	dualsensewirelesscontroller00009	f
2178	125	dualsensewirelesscontroller00010	f
2179	125	dualsensewirelesscontroller00011	f
2180	125	dualsensewirelesscontroller00012	f
2946	428	359606750181787	f
2952	432	357550248095872	f
2951	432	357550241279424	f
2107	98	SDHWJP7GCTQ	f
2108	98	SJQ1034P73F	f
2109	98	SK9HQP762LY	f
2110	98	SG03VC4XHGQ	f
2977	444	SDDV9XGJ76Y	f
2978	445	SMC6WD6M2FP	f
2976	444	SG170QWTJJ6	f
2975	444	SKT7QLY2H9N	f
2890	417	359614546386934	f
2330	208	352368545993615	f
2329	208	352758404073113	f
2328	208	352758404284538	f
2331	208	352368546192654	f
2325	208	354512320603638	f
2326	208	354512324560990	f
2354	214	359493733064400	f
4024	528	ps5slim00056	t
4025	528	ps5slim00057	t
4026	528	ps5slim00058	t
4027	529	ps5slim00059	t
4028	529	ps5slim00060	t
4029	529	ps5slim00061	t
4030	529	ps5slim00062	t
4031	529	ps5slim00063	t
2901	418	357586345419276	f
974	54	instaxfilm20pack00001	f
975	54	instaxfilm20pack00002	f
976	54	instaxfilm20pack00003	f
977	54	instaxfilm20pack00004	f
978	54	instaxfilm20pack00005	f
979	54	instaxfilm20pack00006	f
980	54	instaxfilm20pack00007	f
981	54	instaxfilm20pack00008	f
982	54	instaxfilm20pack00009	f
983	54	instaxfilm20pack00010	f
984	54	instaxfilm20pack00011	f
985	54	instaxfilm20pack00012	f
986	54	instaxfilm20pack00013	f
987	54	instaxfilm20pack00014	f
988	54	instaxfilm20pack00015	f
989	54	instaxfilm20pack00016	f
990	54	instaxfilm20pack00017	f
991	54	instaxfilm20pack00018	f
992	54	instaxfilm20pack00019	f
993	54	instaxfilm20pack00020	f
994	54	instaxfilm20pack00021	f
995	54	instaxfilm20pack00022	f
996	54	instaxfilm20pack00023	f
997	54	instaxfilm20pack00024	f
998	54	instaxfilm20pack00025	f
999	54	instaxfilm20pack00026	f
1000	54	instaxfilm20pack00027	f
1001	54	instaxfilm20pack00028	f
1002	54	instaxfilm20pack00029	f
1003	54	instaxfilm20pack00030	f
1004	54	instaxfilm20pack00031	f
2899	418	355450217081908	f
2894	418	350889861022111	f
2900	418	355450216993962	f
2892	418	355450217194271	f
2908	419	350889868063860	f
2905	419	356605228190878	f
2904	419	350889868314636	f
2902	418	356605228262263	f
1780	62	starlinkv40278	f
1781	62	starlinkv40279	f
1782	62	starlinkv40280	f
1783	62	starlinkv40281	f
1784	62	starlinkv40282	f
1785	62	starlinkv40283	f
1786	62	starlinkv40284	f
1787	62	starlinkv40285	f
1788	62	starlinkv40286	f
1789	62	starlinkv40287	f
1790	62	starlinkv40288	f
1791	62	starlinkv40289	f
1792	62	starlinkv40290	f
1793	62	starlinkv40291	f
1794	62	starlinkv40292	f
1795	62	starlinkv40293	f
1796	62	starlinkv40294	f
1797	62	starlinkv40295	f
1798	62	starlinkv40296	f
1799	62	starlinkv40297	f
1800	62	starlinkv40298	f
1801	62	starlinkv40299	f
1802	62	starlinkv40300	f
1803	62	starlinkv40301	f
1804	62	starlinkv40302	f
2175	125	dualsensewirelesscontroller00007	f
2176	125	dualsensewirelesscontroller00008	f
2998	454	357550247373999	t
3020	456	359614545075645	f
3021	456	356188161941771	f
2984	449	356188162226958	f
2985	449	353263425436349	f
2986	450	355450210206460	f
3010	455	starlinkmini0011	f
3011	455	starlinkmini0012	f
3012	455	starlinkmini0013	f
3013	455	starlinkmini0014	f
3015	455	starlinkmini0016	f
3016	455	starlinkmini0017	f
3017	455	starlinkmini0018	f
3018	455	starlinkmini0019	f
3019	455	starlinkmini0020	f
3014	455	starlinkmini0015	f
2987	451	356250549929496	f
2991	453	358135792056733	f
2992	453	358135792481378	f
2993	453	355827874494583	f
2994	453	353938640453852	f
2995	453	358135791751391	f
2996	453	353938643033149	f
2997	453	356187982019536	f
2999	454	357550246083979	f
3032	462	358051325062371	f
1963	69	RS0290-GP0344450	f
3034	462	358105432135304	f
3028	460	359426267055675	f
3030	462	353263427011769	f
3036	462	359614547271069	f
2989	452	357223745708245	f
2990	452	357247595058732	f
2988	452	358271520542197	f
1005	54	instaxfilm20pack00032	f
1006	54	instaxfilm20pack00033	f
1007	54	instaxfilm20pack00034	f
1008	54	instaxfilm20pack00035	f
1009	54	instaxfilm20pack00036	f
1010	54	instaxfilm20pack00037	f
1011	54	instaxfilm20pack00038	f
1012	54	instaxfilm20pack00039	f
1013	54	instaxfilm20pack00040	f
1014	54	instaxfilm20pack00041	f
1015	54	instaxfilm20pack00042	f
1016	54	instaxfilm20pack00043	f
1017	54	instaxfilm20pack00044	f
1018	54	instaxfilm20pack00045	f
1019	54	instaxfilm20pack00046	f
1020	54	instaxfilm20pack00047	f
1021	54	instaxfilm20pack00048	f
1022	54	instaxfilm20pack00049	f
1023	54	instaxfilm20pack00050	f
1024	54	instaxfilm20pack00051	f
1025	54	instaxfilm20pack00052	f
1026	54	instaxfilm20pack00053	f
1027	54	instaxfilm20pack00054	f
1028	54	instaxfilm20pack00055	f
1029	54	instaxfilm20pack00056	f
1030	54	instaxfilm20pack00057	f
1031	54	instaxfilm20pack00058	f
1032	54	instaxfilm20pack00059	f
1033	54	instaxfilm20pack00060	f
1034	54	instaxfilm20pack00061	f
1035	54	instaxfilm20pack00062	f
1036	54	instaxfilm20pack00063	f
1037	54	instaxfilm20pack00064	f
1038	54	instaxfilm20pack00065	f
1039	54	instaxfilm20pack00066	f
1040	54	instaxfilm20pack00067	f
1041	54	instaxfilm20pack00068	f
1042	54	instaxfilm20pack00069	f
1043	54	instaxfilm20pack00070	f
1044	54	instaxfilm20pack00071	f
1045	54	instaxfilm20pack00072	f
1046	54	instaxfilm20pack00073	f
1047	54	instaxfilm20pack00074	f
1048	54	instaxfilm20pack00075	f
1049	54	instaxfilm20pack00076	f
1050	54	instaxfilm20pack00077	f
1051	54	instaxfilm20pack00078	f
1052	54	instaxfilm20pack00079	f
1053	54	instaxfilm20pack00080	f
1054	54	instaxfilm20pack00081	f
1055	54	instaxfilm20pack00082	f
1056	54	instaxfilm20pack00083	f
1057	54	instaxfilm20pack00084	f
1058	54	instaxfilm20pack00085	f
1059	54	instaxfilm20pack00086	f
1060	54	instaxfilm20pack00087	f
1061	54	instaxfilm20pack00088	f
1062	54	instaxfilm20pack00089	f
1063	54	instaxfilm20pack00090	f
1064	54	instaxfilm20pack00091	f
1065	54	instaxfilm20pack00092	f
1066	54	instaxfilm20pack00093	f
1067	54	instaxfilm20pack00094	f
1068	54	instaxfilm20pack00095	f
1069	54	instaxfilm20pack00096	f
1070	54	instaxfilm20pack00097	f
1071	54	instaxfilm20pack00098	f
1072	54	instaxfilm20pack00099	f
1073	54	instaxfilm20pack00100	f
1074	54	instaxfilm20pack00101	f
1075	54	instaxfilm20pack00102	f
1076	54	instaxfilm20pack00103	f
1077	54	instaxfilm20pack00104	f
1078	54	instaxfilm20pack00105	f
1079	54	instaxfilm20pack00106	f
1080	54	instaxfilm20pack00107	f
1081	54	instaxfilm20pack00108	f
1082	54	instaxfilm20pack00109	f
1083	54	instaxfilm20pack00110	f
1084	54	instaxfilm20pack00111	f
1085	54	instaxfilm20pack00112	f
1086	54	instaxfilm20pack00113	f
1087	54	instaxfilm20pack00114	f
1088	54	instaxfilm20pack00115	f
1089	54	instaxfilm20pack00116	f
1090	54	instaxfilm20pack00117	f
1091	54	instaxfilm20pack00118	f
1092	54	instaxfilm20pack00119	f
1093	54	instaxfilm20pack00120	f
1094	54	instaxfilm20pack00121	f
1095	54	instaxfilm20pack00122	f
1096	54	instaxfilm20pack00123	f
1097	54	instaxfilm20pack001124	f
1098	54	instaxfilm20pack00125	f
1099	54	instaxfilm20pack00126	f
1100	54	instaxfilm20pack00127	f
1101	54	instaxfilm20pack00128	f
1102	54	instaxfilm20pack00129	f
1103	54	instaxfilm20pack00130	f
1104	54	instaxfilm20pack00131	f
1105	54	instaxfilm20pack00132	f
1106	54	instaxfilm20pack00133	f
1107	54	instaxfilm20pack00134	f
1108	54	instaxfilm20pack00135	f
1109	54	instaxfilm20pack00136	f
1110	54	instaxfilm20pack00137	f
1111	54	instaxfilm20pack00138	f
1112	54	instaxfilm20pack00139	f
1113	54	instaxfilm20pack00140	f
1114	54	instaxfilm20pack00141	f
1115	54	instaxfilm20pack00142	f
1116	54	instaxfilm20pack00143	f
1117	54	instaxfilm20pack00144	f
1118	54	instaxfilm20pack00145	f
1119	54	instaxfilm20pack00146	f
1120	54	instaxfilm20pack00147	f
1121	54	instaxfilm20pack00148	f
1122	54	instaxfilm20pack00149	f
1123	54	instaxfilm20pack00150	f
1124	54	instaxfilm20pack00151	f
1125	54	instaxfilm20pack00152	f
1126	54	instaxfilm20pack00153	f
1127	54	instaxfilm20pack00154	f
1128	54	instaxfilm20pack00155	f
1129	54	instaxfilm20pack00156	f
1130	54	instaxfilm20pack00157	f
1131	54	instaxfilm20pack00158	f
1132	54	instaxfilm20pack00159	f
1133	54	instaxfilm20pack00160	f
1134	54	instaxfilm20pack00161	f
1135	54	instaxfilm20pack00162	f
1136	54	instaxfilm20pack00163	f
1137	54	instaxfilm20pack00164	f
1138	54	instaxfilm20pack00165	f
1139	54	instaxfilm20pack00166	f
1140	54	instaxfilm20pack00167	f
1141	54	instaxfilm20pack00168	f
1142	54	instaxfilm20pack00169	f
1143	54	instaxfilm20pack00170	f
1144	54	instaxfilm20pack00171	f
1145	54	instaxfilm20pack00172	f
1146	54	instaxfilm20pack00173	f
1147	54	instaxfilm20pack00174	f
1148	54	instaxfilm20pack001175	f
1149	54	instaxfilm20pack00176	f
1150	54	instaxfilm20pack00177	f
1151	54	instaxfilm20pack00178	f
1152	54	instaxfilm20pack00179	f
1153	54	instaxfilm20pack00180	f
1154	54	instaxfilm20pack00181	f
1155	54	instaxfilm20pack00182	f
1156	54	instaxfilm20pack00183	f
1157	54	instaxfilm20pack00184	f
1158	54	instaxfilm20pack00185	f
1159	54	instaxfilm20pack001186	f
1160	54	instaxfilm20pack00187	f
1161	54	instaxfilm20pack00188	f
1162	54	instaxfilm20pack00189	f
1163	54	instaxfilm20pack00190	f
1164	54	instaxfilm20pack00191	f
1165	54	instaxfilm20pack00192	f
1166	54	instaxfilm20pack00193	f
1167	54	instaxfilm20pack00194	f
1168	54	instaxfilm20pack00195	f
1169	54	instaxfilm20pack00196	f
1170	54	instaxfilm20pack00197	f
1171	54	instaxfilm20pack00198	f
1172	54	instaxfilm20pack00199	f
1173	54	instaxfilm20pack00200	f
1174	54	instaxfilm20pack00201	f
1175	54	instaxfilm20pack00202	f
1176	54	instaxfilm20pack00203	f
1177	54	instaxfilm20pack00204	f
1178	54	instaxfilm20pack00205	f
1179	54	instaxfilm20pack00206	f
1180	54	instaxfilm20pack00207	f
1181	54	instaxfilm20pack00208	f
1182	54	instaxfilm20pack00209	f
1183	54	instaxfilm20pack00210	f
1184	54	instaxfilm20pack00211	f
1185	54	instaxfilm20pack00212	f
1186	54	instaxfilm20pack00213	f
1187	54	instaxfilm20pack00214	f
1188	54	instaxfilm20pack00215	f
1189	54	instaxfilm20pack00216	f
1190	54	instaxfilm20pack00217	f
1191	54	instaxfilm20pack00218	f
1192	54	instaxfilm20pack00219	f
1193	54	instaxfilm20pack00220	f
1194	54	instaxfilm20pack00221	f
1195	54	instaxfilm20pack00222	f
1196	54	instaxfilm20pack00223	f
1197	54	instaxfilm20pack00224	f
1198	54	instaxfilm20pack00225	f
1199	54	instaxfilm20pack00226	f
1200	54	instaxfilm20pack00227	f
1201	54	instaxfilm20pack00228	f
1202	54	instaxfilm20pack00229	f
1203	54	instaxfilm20pack00230	f
1204	54	instaxfilm20pack00231	f
1205	54	instaxfilm20pack00232	f
1206	54	instaxfilm20pack00233	f
1207	54	instaxfilm20pack00234	f
1208	54	instaxfilm20pack00235	f
1209	54	instaxfilm20pack00236	f
1210	54	instaxfilm20pack00237	f
1211	54	instaxfilm20pack00238	f
1212	54	instaxfilm20pack00239	f
1213	54	instaxfilm20pack00240	f
1214	54	instaxfilm20pack00241	f
1215	54	instaxfilm20pack00242	f
1216	54	instaxfilm20pack00243	f
1217	54	instaxfilm20pack00244	f
1218	54	instaxfilm20pack00245	f
1219	54	instaxfilm20pack00246	f
1220	54	instaxfilm20pack00247	f
1221	54	instaxfilm20pack00248	f
1222	54	instaxfilm20pack00249	f
1223	54	instaxfilm20pack00250	f
1224	54	instaxfilm20pack00251	f
1225	54	instaxfilm20pack00252	f
1226	54	instaxfilm20pack00253	f
1227	54	instaxfilm20pack00254	f
1228	54	instaxfilm20pack00255	f
1229	54	instaxfilm20pack00256	f
1230	54	instaxfilm20pack00257	f
1231	54	instaxfilm20pack00258	f
1232	54	instaxfilm20pack00259	f
1233	54	instaxfilm20pack00260	f
1234	54	instaxfilm20pack00261	f
1235	54	instaxfilm20pack00262	f
1236	54	instaxfilm20pack00263	f
1237	54	instaxfilm20pack00264	f
1238	54	instaxfilm20pack00265	f
1239	54	instaxfilm20pack00266	f
1240	54	instaxfilm20pack00267	f
1241	54	instaxfilm20pack00268	f
1242	54	instaxfilm20pack00269	f
1243	54	instaxfilm20pack00270	f
1244	54	instaxfilm20pack00271	f
1245	54	instaxfilm20pack00272	f
1246	54	instaxfilm20pack00273	f
1247	54	instaxfilm20pack00274	f
1248	54	instaxfilm20pack00275	f
1249	54	instaxfilm20pack00276	f
1250	54	instaxfilm20pack00277	f
1251	54	instaxfilm20pack00278	f
1252	54	instaxfilm20pack00279	f
1253	54	instaxfilm20pack00280	f
1254	54	instaxfilm20pack00281	f
1255	54	instaxfilm20pack00282	f
1256	54	instaxfilm20pack00283	f
1257	54	instaxfilm20pack00284	f
1258	54	instaxfilm20pack00285	f
1259	54	instaxfilm20pack00286	f
1260	54	instaxfilm20pack00287	f
1261	54	instaxfilm20pack00288	f
1262	54	instaxfilm20pack00289	f
1263	54	instaxfilm20pack00290	f
1264	54	instaxfilm20pack00291	f
1265	54	instaxfilm20pack00292	f
1266	54	instaxfilm20pack00293	f
1267	54	instaxfilm20pack00294	f
1268	54	instaxfilm20pack00295	f
1269	54	instaxfilm20pack00296	f
1270	54	instaxfilm20pack00297	f
1271	54	instaxfilm20pack00298	f
1272	54	instaxfilm20pack00299	f
1273	54	instaxfilm20pack00300	f
489	32	1581F9DEC258W0291F67	f
488	32	1581F9DEC25AQ0297HQU	f
2378	234	352315400015596	f
2766	374	352355700414206	t
2772	376	356188164176789	f
2771	376	356188161552859	f
2782	380	353748539961141	f
2789	383	351878870270182	f
2790	383	351878871215095	f
2774	377	356605224923694	f
2776	377	355450218138897	f
2773	377	353263423163911	f
2775	377	355450217775111	f
2767	375	358482493529307	f
2769	375	359614541093337	f
2768	375	358482493270399	f
2770	375	355478878442325	f
2779	379	353708842036635	f
2780	379	356250543300421	f
2781	380	350208034439278	f
2777	378	356839679159534	f
2778	378	355500357943893	f
4032	529	ps5slim00064	t
4033	529	ps5slim00065	t
4034	529	ps5slim00066	t
4035	529	ps5slim00067	t
4036	529	ps5slim00068	t
4037	529	ps5slim00069	t
4038	529	ps5slim00070	t
4039	529	ps5slim00071	t
4040	529	ps5slim00072	t
4041	529	ps5slim00073	t
4042	529	ps5slim00074	t
4043	529	ps5slim00075	t
4044	529	ps5slim00076	t
4045	529	ps5slim00077	t
4046	529	ps5slim00078	t
4047	529	ps5slim00079	t
4048	529	ps5slim00080	t
4049	529	ps5slim00081	t
4050	529	ps5slim00082	t
4051	529	ps5slim00083	t
4052	529	ps5slim00084	t
4053	529	ps5slim00085	t
4054	529	ps5slim00086	t
4055	529	ps5slim00087	t
4056	529	ps5slim00088	t
4057	529	ps5slim00089	t
4058	529	ps5slim00090	t
4059	529	ps5slim00091	t
4060	529	ps5slim00092	t
4061	529	ps5slim00093	t
4062	529	ps5slim00094	t
4063	529	ps5slim00095	t
4064	529	ps5slim00096	t
4065	529	ps5slim00097	t
4066	529	ps5slim00098	t
4067	529	ps5slim00099	t
4068	529	ps5slim00100	t
4069	529	ps5slim00101	t
4070	529	ps5slim00102	t
4071	529	ps5slim00103	t
4072	529	ps5slim00104	t
4073	529	ps5slim00105	t
4074	529	ps5slim00106	t
4075	529	ps5slim00107	t
4076	529	ps5slim00108	t
4077	529	ps5slim00109	t
4078	529	ps5slim00110	t
2784	382	356187982541513	f
2786	382	353938640357954	f
2785	382	353938642157444	f
2787	382	356187982623444	f
2788	382	356187983034039	f
2783	381	354123752650640	f
4079	529	ps5slim00111	t
4080	529	ps5slim00112	t
4081	529	ps5slim00113	t
4082	529	ps5slim00114	t
4083	529	ps5slim00115	t
4084	529	ps5slim00116	t
4085	529	ps5slim00117	t
4086	529	ps5slim00118	t
4087	529	ps5slim00119	t
4088	529	ps5slim00120	t
4089	529	ps5slim00121	t
4090	529	ps5slim00122	t
4091	529	ps5slim00123	t
4092	529	ps5slim00124	t
4093	529	ps5slim00125	t
4123	545	352315403679901	t
4124	545	357205981249315	t
4125	546	356295606462741	t
4126	547	352653442265609	t
4127	548	353247105566665	t
4128	549	353890109487576	t
3076	490	357020912351308	t
3077	491	352355707588655	t
3078	492	SLT2MV51QW9	t
3079	492	SLW0X16LT0H	t
3080	492	SC99QQYR2VX	t
3081	492	SJQCD417L6T	t
3082	492	SD9N903G00V	t
3083	493	358112933972698	t
3084	494	358112932514061	t
3085	495	358112934561524	t
3086	496	357153137093346	t
3087	497	SD61JXRWF9J	t
3088	497	SCRH444H617	t
3048	472	353263421628196	f
3049	472	353263421777209	f
3071	488	357247595304755	f
3073	488	358838945990324	f
3074	488	355413814844524	f
3089	498	358112933425135	t
3090	499	356768321404982	t
3091	499	356187983011615	t
3092	500	350158864209897	f
3070	488	351605722195832	f
3072	488	358271521457833	f
3051	474	357586342264501	f
3054	477	355224256513240	f
3947	523	S01E45601CE810572356	f
4129	550	355964948552797	t
4130	551	pixel70001	t
3055	478	359614546797635	f
3056	478	350889864418803	f
3052	475	356605224177770	f
3026	460	350889861054247	f
3025	460	359614547064746	f
3027	460	357826991518611	f
3035	462	357826992298429	f
3033	462	358051328034526	f
3031	462	359614547846704	f
3053	476	356764177275477	f
3050	473	356605224108312	f
3057	479	353263426675176	f
3058	480	351317529884903	f
3061	482	356250548298976	f
3066	486	350208032986825	f
3065	486	352440634381554	f
3067	486	352294448173529	f
3062	483	356250548267765	f
3068	487	351317522022725	f
3069	487	351317529770219	f
3059	481	350455774515615	f
3060	481	356661400563283	f
3064	485	352591613065434	f
3063	484	350208037479339	f
3075	489	351523427089996	f
3029	461	356605227683113	f
2943	425	357826990550276	f
2889	417	359614541291014	f
2938	423	351317520845499	f
2939	423	356250541701943	f
2940	423	352294449552580	f
2941	423	355500353647993	f
2949	430	356484792035632	f
2947	429	359045767346721	f
2948	429	359045769093669	f
\.


--
-- Data for Name: receipts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.receipts (receipt_id, party_id, account_id, amount, receipt_date, method, reference_no, journal_id, date_created, notes, description) FROM stdin;
1	67	5	15000.0000	2026-01-06	Cash	RCT-1	115	2026-01-06 16:06:41.776409	\N	Out to loss Account 
2	46	5	6970.0000	2026-01-08	Cash	RCT-2	183	2026-01-10 11:55:05.643216	\N	6970 cash received power play
3	86	5	1740.0000	2026-01-08	Cash	RCT-3	186	2026-01-10 12:00:03.495489	\N	1740 cash received Fiji electronics
4	11	5	658.0000	2026-01-08	Cash	RCT-4	188	2026-01-10 12:03:57.288467	\N	Caryy 52,000 PKR @79 For karachi Office Pieces to Waqas Aslam
5	26	5	37680.0000	2026-01-08	Cash	RCT-5	190	2026-01-10 12:05:45.705735	\N	37680 cash received from easy buy
6	72	5	71400.0000	2026-01-08	Cash	RCT-6	192	2026-01-10 12:06:57.072922	\N	Cash received Khaira jaani bur Dubai 71,400
7	73	5	7260.0000	2026-01-08	Cash	RCT-7	193	2026-01-10 12:07:32.319435	\N	7,260 cash received from BBC
8	46	5	25040.0000	2026-01-08	Cash	RCT-8	194	2026-01-10 12:08:07.425558	\N	25040 cash received from power play
9	74	5	11350.0000	2026-01-08	Cash	RCT-9	195	2026-01-10 12:08:38.563087	\N	11350 cash received century store
10	69	5	17700.0000	2026-01-08	Cash	RCT-10	196	2026-01-10 12:09:09.870876	\N	17,700 cash received metro delux
11	74	5	1450.0000	2026-01-08	Cash	RCT-11	199	2026-01-10 12:11:23.469767	\N	1450 cash received century store
12	71	5	29150.0000	2026-01-08	Cash	RCT-12	200	2026-01-10 12:11:51.617068	\N	29150 cash received phone 4 u
13	69	5	20400.0000	2026-01-08	Cash	RCT-13	201	2026-01-10 12:12:17.402666	\N	20400 cash received from metro by abdul wasay
14	15	5	100000.0000	2026-01-08	Cash	RCT-14	203	2026-01-10 12:13:14.77815	\N	100,000 cash received from ahsan cba
15	33	5	19800.0000	2026-01-08	Cash	RCT-15	204	2026-01-10 12:14:10.594311	\N	19800 cash received from Hanzala laptop
16	15	5	62000.0000	2026-01-08	Cash	RCT-16	205	2026-01-10 12:14:37.091616	\N	62000 cash received ahsan cba
17	11	5	254.0000	2026-01-08	Cash	RCT-17	210	2026-01-10 12:17:59.354552	\N	To Anwer for Karachi Office Software 12 months payment from AR Meezan
18	11	5	254.0000	2026-01-08	Cash	RCT-18	217	2026-01-10 12:21:40.280949	\N	20k PKR from AR Meezan to TAYYAB ANDLEEB (Faisal Bhai)
19	11	5	140.0000	2026-01-08	Cash	RCT-19	219	2026-01-10 12:22:47.981239	\N	11k PKR from AR Meezan to KHADIJA FAISAL (Faisal Bhai)
20	71	5	100000.0000	2026-01-08	Cash	RCT-20	223	2026-01-10 12:25:12.525469	\N	100,000 cash received phone 4 u
21	75	5	9676.0000	2026-01-08	Cash	RCT-21	224	2026-01-10 12:25:43.85413	\N	9676 cash received all digital
23	71	5	22500.0000	2026-01-08	Cash	RCT-23	228	2026-01-10 12:31:06.344256	\N	22500 cash received from phone for u
24	77	5	10350.0000	2026-01-08	Cash	RCT-24	230	2026-01-10 12:32:13.578334	\N	10350 cash received al oha
25	78	5	27750.0000	2026-01-08	Cash	RCT-25	231	2026-01-10 12:32:43.699754	\N	27750 cash received hamza one touch
26	75	5	7200.0000	2026-01-08	Cash	RCT-26	232	2026-01-10 12:33:12.048472	\N	7200 cash received from all digital
27	75	5	7040.0000	2026-01-08	Cash	RCT-27	233	2026-01-10 12:34:54.924713	\N	7040 cash received from all digital
28	69	5	7500.0000	2026-01-08	Cash	RCT-28	234	2026-01-10 12:35:24.589915	\N	7500 cash received from metro deluxe
29	80	5	122000.0000	2026-01-08	Cash	RCT-29	236	2026-01-10 12:37:01.604676	\N	122,000 cash received central system
30	79	5	36700.0000	2026-01-08	Cash	RCT-30	237	2026-01-10 13:02:10.598109	\N	36,700 received from NY 
31	79	5	50.0000	2026-01-08	Cash	RCT-31	238	2026-01-10 13:02:31.673349	\N	Discount to NY
32	75	5	5000.0000	2026-01-08	Cash	RCT-32	241	2026-01-10 13:11:59.94835	\N	Cash received all digital 5000
33	10	5	5000.0000	2026-01-08	Cash	RCT-33	243	2026-01-10 13:14:20.659484	\N	5000 received from faisal self for daily visa deposit
34	71	5	34800.0000	2026-01-08	Cash	RCT-34	244	2026-01-10 13:15:03.589534	\N	34800 cash received phone 4 u
35	81	5	8550.0000	2026-01-08	Cash	RCT-35	247	2026-01-10 13:21:08.756249	\N	8550 cash received from asad Bsamart
36	82	5	13680.0000	2026-01-08	Cash	RCT-36	248	2026-01-10 13:22:02.373029	\N	13680 cash received from farhan alhamd
37	81	5	12480.0000	2026-01-08	Cash	RCT-37	249	2026-01-10 13:23:18.308004	\N	12480 cash received from Asad Bsmart
38	36	5	39500.0000	2026-01-08	Cash	RCT-38	250	2026-01-10 13:23:44.357321	\N	39500 cash received from humair karachi
39	83	5	7950.0000	2026-01-08	Cash	RCT-39	251	2026-01-10 13:24:11.622641	\N	7950 cash received from sabeer sama almal
40	71	5	2630.0000	2026-01-08	Cash	RCT-40	257	2026-01-10 13:32:14.077503	\N	2630 cash received from phone 4U
41	69	5	22500.0000	2026-01-08	Cash	RCT-41	258	2026-01-10 13:32:35.934412	\N	22500 cash received from metro delux
42	53	5	2800.0000	2026-01-08	Cash	RCT-42	261	2026-01-10 13:34:23.328195	\N	2800 cash received from shapoor
43	85	5	50430.0000	2026-01-08	Cash	RCT-43	263	2026-01-10 13:35:53.44112	\N	50430 cash received from Zeeshan dysomac
44	52	5	6860.0000	2026-01-08	Cash	RCT-44	265	2026-01-10 13:38:04.104266	\N	6860 cash received from shaid karachi
45	69	5	4200.0000	2026-01-08	Cash	RCT-45	266	2026-01-10 13:38:23.559611	\N	4200 cash received from metro delux
46	68	5	4200.0000	2026-01-08	Cash	RCT-46	267	2026-01-10 13:38:41.956333	\N	4200 cash received from digi hub
65	69	5	7100.0000	2026-01-05	Cash	RCT-65	320	2026-01-10 15:41:29.556263	\N	7100 cash received from metro delux 01-01-2026
54	91	5	1899.0000	2026-01-08	Cash	RCT-54	294	2026-01-10 14:42:29.653378	\N	150K PKR from Faizan Ground (muhammad Ahsan) to ON Point It services( MUdassir)
47	58	5	1600.0000	2026-01-08	Cash	RCT-47	269	2026-01-10 13:39:44.008728	\N	1600 cash received from bsmart
48	81	5	43000.0000	2026-01-08	Cash	RCT-48	270	2026-01-10 13:42:29.410012	\N	43,000 cash received from Asad Bsmart
55	88	5	2532.0000	2026-01-08	Cash	RCT-55	296	2026-01-10 14:44:14.560684	\N	200,000 PKR from haseeb 137 to AR Meezan 
49	50	5	10127.0000	2026-01-08	Cash	RCT-49	273	2026-01-10 13:46:15.111589	\N	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)
50	50	5	1899.0000	2026-01-10	Cash	RCT-50	274	2026-01-10 13:47:59.794721	\N	FROM Muhammad Bilal Khan(Saad & Wajahat) to ON Point IT Services(MUDASSIR)
51	90	5	2595.0000	2026-01-08	Cash	RCT-51	282	2026-01-10 14:03:18.633106	\N	205K PKR, from Cell Arena to ON POint IT Services(MUDASSIR)
52	88	5	1722.0000	2026-01-08	Cash	RCT-52	284	2026-01-10 14:04:46.375486	\N	From HASEEB AHMED to ON Point IT Services (MUDASSIR)
53	92	5	1950.0000	2026-01-08	Cash	RCT-53	291	2026-01-10 14:38:55.650588	\N	from Ahmed Hassan 224 to ON Point IT Services(Mudassir)
56	91	5	2025.0000	2026-01-08	Cash	RCT-56	300	2026-01-10 14:50:28.47004	\N	from Faizan Ground (Muhammad Ahsan) to On point IT Services (Mudassir)
57	89	5	26.0000	2026-01-08	Cash	RCT-57	303	2026-01-10 15:03:23.627941	\N	Received from Anus paid to Ahmed 224
58	15	5	26.0000	2026-01-08	Cash	RCT-58	305	2026-01-10 15:06:36.594315	\N	from Ahmed Hassan CBA to AR Meezan 
59	56	5	1722.0000	2026-01-08	Cash	RCT-59	307	2026-01-10 15:09:09.551794	\N	136,000 PKR From sumair pasta to AR Meezan
60	88	5	2393.0000	2026-01-08	Cash	RCT-60	309	2026-01-10 15:12:15.024877	\N	189,000 PKR from Haseeb 137 to AR Meezan
66	14	5	500.0000	2026-01-05	Cash	RCT-66	321	2026-01-10 15:42:00.550368	\N	500 cash received from adeel dubai
67	53	5	2800.0000	2026-01-05	Cash	RCT-67	322	2026-01-10 15:43:31.148565	\N	2800 cash received from shapoor
61	91	5	1456.0000	2026-01-08	Cash	RCT-61	312	2026-01-10 15:13:43.191485	\N	115000 PKR from Faizan Ground to On point IT services ( Mudassir)
62	16	5	120900.0000	2026-01-06	Cash	RCT-62	314	2026-01-10 15:21:18.395534	\N	 50,000 AUD@2.4180 paid through Ahsan Mohsin to Waheed Bhai
63	16	5	241342.0000	2026-01-09	Cash	RCT-63	316	2026-01-10 15:27:45.586781	\N	 99,000 AUD @2.4378 from Ahsan Mohsin to Waheed bhai
68	68	5	12500.0000	2026-01-05	Cash	RCT-68	323	2026-01-10 15:44:39.817006	\N	12500 cash received from digi hub
69	94	5	17330.0000	2026-01-08	Cash	RCT-69	327	2026-01-10 16:12:40.53053	\N	17330 cash received from hamza makhdum
71	95	5	3730.0000	2026-01-09	Cash	RCT-71	345	2026-01-12 14:43:27.120844	\N	3730 cash received from fahad Lahore \r\n20 discount box damage
72	95	5	20.0000	2026-01-09	Cash	RCT-72	346	2026-01-12 14:44:00.287736	\N	20 discount box damage Fahad Lahore
73	53	5	2800.0000	2026-01-09	Cash	RCT-73	348	2026-01-12 14:45:07.02094	\N	2800 cash received from shapoor
74	75	5	7500.0000	2026-01-09	Cash	RCT-74	349	2026-01-12 14:45:30.497061	\N	7500 cash received from all digital
75	96	5	20190.0000	2026-01-09	Cash	RCT-75	350	2026-01-12 14:45:53.208924	\N	20190 cash received from CTN
76	52	5	9500.0000	2026-01-09	Cash	RCT-76	352	2026-01-12 14:47:59.030551	\N	9500 cash received from shaid karachi \r\n
77	97	5	2680.0000	2026-01-09	Cash	RCT-77	354	2026-01-12 14:49:33.679346	\N	2680 cash received from ahsan ali
78	81	5	5590.0000	2026-01-10	Cash	RCT-78	356	2026-01-12 14:50:27.609022	\N	5590 cash received from asad Bsmart
79	69	5	3000.0000	2026-01-10	Cash	RCT-79	357	2026-01-12 14:50:59.771473	\N	3000 cash received from metro delux
80	68	5	27920.0000	2026-01-10	Cash	RCT-80	358	2026-01-12 14:51:21.546555	\N	27920 cas received from digi hub
81	98	5	31385.0000	2026-01-10	Cash	RCT-81	359	2026-01-12 14:52:01.118603	\N	31385 cash recived from sajjad atari fariya
96	91	5	1659.0000	2026-01-09	Cash	RCT-96	401	2026-01-13 13:23:16.542347	\N	131,000 PKR from Faizan GR (MUHAMMAD AHSAN) to Mudassir(ON POINT IT SERVICES) Reference #516046
85	99	5	10080.0000	2026-01-08	Cash	RCT-85	368	2026-01-12 15:36:40.4233	\N	10,080 received from Zaidi gujranwala
86	99	5	6720.0000	2026-01-08	Cash	RCT-86	369	2026-01-12 15:48:23.562857	\N	Cash received by Abubaker NO message in any Fianace Group
87	100	5	5000.0000	2026-01-12	Cash	RCT-87	372	2026-01-12 16:00:38.615534	\N	5000 cash received from Ariya mobail
88	52	5	5715.0000	2026-01-12	Cash	RCT-88	373	2026-01-12 16:01:03.556119	\N	5715 cash received from shaid karachi
97	93	5	924.0000	2026-01-12	Cash	RCT-97	403	2026-01-13 13:28:10.379594	\N	73,000 PKR from Waqas MT( KULSUM ABDUL WAHAB) to AR Meezan A/C
84	84	5	27350.0000	2026-01-08	Cash	RCT-84	375	2026-01-12 15:09:15.485723	\N	27350 cash received from bilal karachi
98	101	5	1747.0000	2026-01-13	Cash	RCT-98	406	2026-01-13 13:31:38.39315	\N	Cash received from Kumail Customer out to Ahsan 224
83	69	5	7000.0000	2026-01-08	Cash	RCT-83	376	2026-01-12 15:07:49.284103	\N	7000 cash received from metro delux
99	54	5	45350.0000	2026-01-13	Cash	RCT-99	412	2026-01-14 13:01:43.089364	\N	45,350 total cash received from Shahzad Mughal
82	49	5	47360.0000	2026-01-08	Cash	RCT-82	377	2026-01-12 15:05:57.794873	\N	47,630 cash received Raad Al Madina
89	68	5	27750.0000	2026-01-12	Cash	RCT-89	382	2026-01-13 12:34:06.75983	\N	27750 cash recived from digi hub by Abubaker
90	16	5	251650.0000	2026-01-13	Cash	RCT-90	383	2026-01-13 12:47:23.672287	\N	70,000 USD @3.595 to Owais HT through Ahsan Mohsin (Dec-28-2025)
91	16	5	35950.0000	2026-01-13	Cash	RCT-91	385	2026-01-13 12:52:44.501271	\N	 10,000 USD to Owais HOUSTON@3.595 through Ahsan Mohsin (jan-08-2026)
92	16	5	71900.0000	2026-01-13	Cash	RCT-92	387	2026-01-13 12:55:11.309011	\N	20,000 USD to Owais HOUSTON @3.595 through Ahsan Mohsin (jan-09-2026)
93	88	5	26.0000	2026-01-08	Cash	RCT-93	391	2026-01-13 13:12:09.525421	\N	2,000 PKR cash received from Haseeb 137 out to Ahmed 224
94	93	5	1519.0000	2026-01-08	Cash	RCT-94	393	2026-01-13 13:13:45.098649	\N	120,000 PKR from Waqas Abdul Wahab to AR Meezan A/C
95	93	5	1266.0000	2026-01-08	Cash	RCT-95	396	2026-01-13 13:19:19.880603	\N	100,000 PKR Waqas MT(KULSUM ABDUL WAHAB) to AR Meezan A/C
100	103	5	4900.0000	2026-01-13	Cash	RCT-100	415	2026-01-14 13:05:11.82834	\N	Cash received Rakesh 4900
101	97	5	900.0000	2026-01-14	Cash	RCT-101	418	2026-01-14 13:18:50.71692	\N	900 cash received from ahsan ali sheikh
102	11	5	64.0000	2026-01-16	Cash	RCT-102	420	2026-01-16 12:56:58.758066	\N	from AR Meezan to ARSH IMRAN (Karachi Office Internet) EXP (jan-06-2026)
103	11	5	380.0000	2026-01-16	Cash	RCT-103	422	2026-01-16 12:59:39.58355	\N	from AR Meezan to MEHREEN (Faisal Bhai) (jan-10-2026)
104	11	5	2912.0000	2026-01-16	Cash	RCT-104	424	2026-01-16 13:02:28.122879	\N	from AR Meezan to JAS TRAVELS (office exp saudi travelling exp ammi baba) jan-07-2026
105	11	5	937.0000	2026-01-16	Cash	RCT-105	426	2026-01-16 13:06:41.000814	\N	from AR Meezan to CONNECT (Karachi Office Rent ) (jan-10-2026)
106	11	5	2082.0000	2026-01-16	Cash	RCT-106	428	2026-01-16 13:09:00.319449	\N	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)
107	11	5	2082.0000	2026-01-16	Cash	RCT-107	429	2026-01-16 13:09:24.825557	\N	from AR Meezan to ARY Laguna (Waheed Bhai) 164,448 PKR @79 (jan-08-2026)
108	11	5	1238.0000	2026-01-16	Cash	RCT-108	432	2026-01-16 13:11:32.223677	\N	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)
109	11	5	1238.0000	2026-01-16	Cash	RCT-109	433	2026-01-16 13:11:45.867331	\N	97,774 PKR @79 from AR Meezan to ARY Laguna (jan-08-2026)
110	11	5	1577.0000	2026-01-16	Cash	RCT-110	436	2026-01-16 13:16:57.676429	\N	124,516 PKR from AR Meezan to Saqib Meezan for (Maaz,Saqib,Hassan) Salary (jan-05-2026)
111	11	5	260.0000	2026-01-16	Cash	RCT-111	438	2026-01-16 13:18:52.781792	\N	20,484 from AR Meezan to Saqib Meezan Karachi Office Expense Amount (jan-05-2026)
112	95	5	10800.0000	2026-01-14	Cash	RCT-112	452	2026-01-16 16:07:44.017638	\N	10800 cash received from fahad Lahore
113	104	5	3400.0000	2026-01-14	Cash	RCT-113	454	2026-01-16 16:08:30.607462	\N	3400 cash recived from faraz GVT\r\n
114	104	5	3880.0000	2026-01-14	Cash	RCT-114	455	2026-01-16 16:09:19.44437	\N	3880 cash received from faraz GVT
115	75	5	10200.0000	2026-01-14	Cash	RCT-115	456	2026-01-16 16:09:55.847462	\N	10200 cash received from all digital
116	84	5	41620.0000	2026-01-14	Cash	RCT-116	457	2026-01-16 16:10:26.950891	\N	41620 cash received from bilal G.49
117	7	5	62195.0000	2026-01-14	Cash	RCT-117	458	2026-01-16 16:11:06.746949	\N	Cash received Hezartoo
118	81	5	2950.0000	2026-01-14	Cash	RCT-118	459	2026-01-16 16:11:40.282044	\N	2950 cash received from Asad Bsmart
119	105	5	30000.0000	2026-01-15	Cash	RCT-119	461	2026-01-16 16:12:46.034508	\N	30,000 cash received from abuzar dubai
120	96	5	38340.0000	2026-01-15	Cash	RCT-120	462	2026-01-16 16:13:37.534234	\N	38340 cash received from CTN
121	105	5	30800.0000	2026-01-15	Cash	RCT-121	463	2026-01-16 16:14:28.552682	\N	30,800 cash received from abuzar Dubai
122	106	5	73320.0000	2026-01-15	Cash	RCT-122	464	2026-01-16 16:15:08.529775	\N	73,320 cash received from qamar Sudani
123	11	5	886.0000	2026-01-15	Cash	RCT-123	466	2026-01-16 16:21:39.670476	\N	70,000 pkr @79 from AR Meezan to BIA'S , waqas Aslam Carry KArachi office expense 
124	11	5	139.0000	2026-01-15	Cash	RCT-124	468	2026-01-16 16:26:56.828369	\N	11,000 pkr @79 from AR Meexan to Aman Anwer , aman carry karachi office expense 
125	95	5	11400.0000	2026-01-15	Cash	RCT-125	470	2026-01-16 16:28:24.043045	\N	11,400 cash received from fahad Lahore
158	68	5	31050.0000	2026-01-19	Cash	RCT-158	596	2026-01-21 12:04:53.568228	\N	Cash received from digi hub 31050
159	40	5	3380.0000	2026-01-21	Cash	RCT-159	598	2026-01-21 12:06:17.461263	\N	Adjustment Entry For Humair Karachi Ledger for balancing the 10-dec s17 pro max sale
126	95	5	4600.0000	2026-01-15	Cash	RCT-126	472	2026-01-16 16:29:31.771064	\N	4600 cash recived \r\n1050 balance  msg by Abubaker 
174	105	5	11600.0000	2026-01-20	Cash	RCT-174	618	2026-01-21 12:27:02.737287	\N	11600 cash received from abuzar
128	98	5	1948.0000	2026-01-15	Cash	RCT-128	475	2026-01-16 16:37:28.088292	\N	153832 pkr @79 from SHY Traders ( Sajjad Attari ) to AR Meezan 
129	71	5	5160.0000	2026-01-15	Cash	RCT-129	477	2026-01-16 16:41:49.119188	\N	5160 cash received from younus phone 4U
131	49	5	26820.0000	2026-01-15	Cash	RCT-131	480	2026-01-16 16:49:09.309454	\N	26820 cash received raaad al Madina
132	95	5	1050.0000	2026-01-15	Cash	RCT-132	481	2026-01-16 16:51:44.341474	\N	1050 cash received from fahad Lahore
133	4	5	44422.0000	2026-01-08	Cash	RCT-133	519	2026-01-19 14:38:16.383913	\N	CR: 2.4285 |-> 17 pro max 256 silver officeworks Castle Hills -2- @2010$  @4881.285AED | 17 pro max 256 silver officeworks Northmead -2- @2010$ @4881.285AED | Starlink Standard Kit Adil Bhai -2- @398$ @966.543AED | PS5-DISK-BUNDLE Adil Bhai -8- @629$ @1527.5265AED |  PS5-DISK-BUNDLE Adil Bhai -2- @629$ @1527.5265AED | PS5 Digital Bundle Adil Bhai -4- @477$ @1158.3945AED | PS5 Disc Bundle Adil Bai Harvey norman Alex Pending Delivery Adil Bhai -2- @629$ @1527.5265AED | 
175	111	5	2400.0000	2026-01-20	Cash	RCT-175	619	2026-01-21 12:27:21.544862	\N	2400 cash received from Adeel Karachi
179	84	5	2930.0000	2026-01-21	Cash	RCT-179	626	2026-01-21 12:38:27.31374	\N	2930 cash received from bilal
181	11	5	190.0000	2026-01-21	Cash	RCT-181	629	2026-01-21 13:02:07.961732	\N	15000 pkr @79 from AR Meezan to Saqib Ali Khan 
144	4	5	139238.0000	2026-01-15	Cash	RCT-144	561	2026-01-20 16:35:19.251955	\N	CR : 2.4285 |-> Iphone 17 pro max 256 Silver Harvey Norman Fyshwick Pending Delivery/ 27-12 Deposit Update -7- @2.197$ @5335.4145AED | DJI Mavic 4 Pro DJI Macquarie Park Pending Collection -8- @2490$ @6046.965AED | DJI Mic 3 combo DJI Macquarie Park Pending Collection -25- @415$ @1007.8275AED | Mac Book Pro M5 24/1TB JBHIFI Bankstown -3- @2690$ @6532.665AED | Apple Air Pods 4 ANC JBHIFI Bankstown -3- @259$ @628.9815AED | DJI Mini 4K combo JBHIFI Bankstown\r\n-3- @519$ @1260.3915AED | DJI Mic 3 combo JBHIFI Bankstown -3- @419$ @1017.5415AED\r\n\r\n\r\n\r\n\r\n\r\n\r\n
134	4	5	87863.0000	2026-01-08	Cash	RCT-134	523	2026-01-19 14:54:39.792027	\N	CR: 2.4285 |-> Iphone 17 pro max 256 Silver Office Works Northmead -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works CastleHills -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works BlackTown -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works WetheillPark -2- @2010$ @4881.285AED |  Iphone 17 pro max 256 Silver Office Works Wentworth Ville -1- @2010$ @4881.285AED | Iphone 17 pro max 256 Silver Officeworks Auburn\r\n-2- @2010$ @4881.285AED\r\n
135	4	5	253.0000	2026-01-19	Cash	RCT-135	531	2026-01-19 17:03:23.081731	\N	Swiss Tech Business name renew fees Expense in Australia
138	54	5	5250.0000	2026-01-16	Cash	RCT-138	549	2026-01-20 15:13:13.962954	\N	MW2V3 MacBook Cash received From SHAHZAD 5250
145	4	5	30719.0000	2026-01-13	Cash	RCT-145	563	2026-01-20 16:39:10.285764	\N	CR : 2.12 | -> G7X Mark III  Noel Leeming Abdul K -10- @1449$ @3071.88AED\r\n
160	15	5	18000.0000	2026-01-19	Cash	RCT-160	600	2026-01-21 12:06:52.147398	\N	11-12-25 \r\nCash received from ahsan cba 18000
136	4	5	1239.0000	2026-01-19	Cash	RCT-136	565	2026-01-19 17:05:08.44106	\N	Commission paid Adil bhai in Australia 510 AUD
137	4	5	27741.0000	2026-01-19	Cash	RCT-137	551	2026-01-19 17:08:34.477632	\N	Shipping Charges Megatop Sydeney Expense 11,423.05 AUD @2.4285
139	113	5	4400.0000	2026-01-16	Cash	RCT-139	554	2026-01-20 15:18:37.652547	\N	4400 cash recieved from asad BSmart ( asad Link )
140	36	5	3620.0000	2026-01-13	Cash	RCT-140	556	2026-01-20 15:21:07.506019	\N	13-12-25, Cash recieved from Humair 3620
141	35	5	12250.0000	2026-01-16	Cash	RCT-141	557	2026-01-20 15:22:07.984113	\N	12250 Cash received from hmb
142	68	5	6900.0000	2026-01-16	Cash	RCT-142	558	2026-01-20 15:23:32.310033	\N	6900 Cash received from digi hub
143	98	5	18615.0000	2026-01-16	Cash	RCT-143	559	2026-01-20 15:24:26.77659	\N	18615 cash received from sajjad atari fariya
146	4	5	19379.0000	2026-01-15	Cash	RCT-146	566	2026-01-20 16:43:31.807224	\N	Shipping Charges CT Freight Melbourne @7980$\r\n
147	4	5	7225.0000	2026-01-13	Cash	RCT-147	569	2026-01-20 16:48:28.112784	\N	Shipping Charges CT Freight NZ Shipping Expense\r\n
148	49	5	17290.0000	2026-01-17	Cash	RCT-148	577	2026-01-21 11:03:34.326318	\N	17290 cash received from Raad Al Madina
149	111	5	15000.0000	2026-01-17	Cash	RCT-149	579	2026-01-21 11:04:27.335527	\N	15000 received from Adeel Bhai Karachi
150	79	5	17340.0000	2026-01-17	Cash	RCT-150	580	2026-01-21 11:04:46.163771	\N	17,340 cash received from NY
151	112	5	3150.0000	2026-01-17	Cash	RCT-151	582	2026-01-21 11:05:33.384831	\N	3,150 cash received from Saeed
152	49	5	1320.0000	2026-01-17	Cash	RCT-152	583	2026-01-21 11:06:15.096163	\N	1320 cash received from Raad Al Madina
153	109	5	20060.0000	2026-01-15	Cash	RCT-153	590	2026-01-21 11:56:01.041225	\N	20060 cash received from muzambil pindi
154	110	5	6800.0000	2026-01-15	Cash	RCT-154	591	2026-01-21 11:56:31.200651	\N	6800 cash received from farhan turkish
155	78	5	2600.0000	2026-01-19	Cash	RCT-155	592	2026-01-21 11:58:02.507406	\N	2600 cash received from hamza
156	114	5	250.0000	2026-01-19	Cash	RCT-156	594	2026-01-21 12:03:47.101532	\N	250 JBL Flip 7 given to Office
157	53	5	9700.0000	2026-01-19	Cash	RCT-157	595	2026-01-21 12:04:19.906704	\N	9700 received from shapoor
161	104	5	6560.0000	2026-01-19	Cash	RCT-161	601	2026-01-21 12:07:40.621421	\N	6560 cash received from faraz GVT
162	96	5	39330.0000	2026-01-20	Cash	RCT-162	602	2026-01-21 12:08:51.626792	\N	39330 cash received from CTN
163	15	5	120000.0000	2026-01-20	Cash	RCT-163	603	2026-01-21 12:10:03.99624	\N	120000\r\ncash received from ahsan cba
164	15	5	25000.0000	2026-01-20	Cash	RCT-164	604	2026-01-21 12:10:42.152323	\N	25000 cashvreceived from ahsan cba
165	85	5	5000.0000	2026-01-20	Cash	RCT-165	606	2026-01-21 12:12:15.047136	\N	5000 cash received from Zeeshan dysomac
166	76	5	5800.0000	2026-01-20	Cash	RCT-166	608	2026-01-21 12:14:21.472306	\N	05-1- 26\r\n5800 cash received ultra deal
167	105	5	13800.0000	2026-01-20	Cash	RCT-167	609	2026-01-21 12:14:57.898111	\N	13800 cash received from abuzar Dubai
168	95	5	6450.0000	2026-01-20	Cash	RCT-168	611	2026-01-21 12:16:18.781665	\N	6450 cash received from fahad Lahore
169	11	5	1291.0000	2026-01-20	Cash	RCT-169	612	2026-01-21 12:21:25.011852	\N	102000 pkr @79 from AR Meezan to BIA's, Waqas Aslam Carry karachi Office expense
171	104	5	10000.0000	2026-01-20	Cash	RCT-171	615	2026-01-21 12:25:56.970558	\N	Cash received from Faraz gvt 10,000
172	78	5	1600.0000	2026-01-20	Cash	RCT-172	616	2026-01-21 12:26:20.803436	\N	1600 cash received from hamza one tech
173	68	5	13800.0000	2026-01-20	Cash	RCT-173	617	2026-01-21 12:26:40.437375	\N	13800 cash received from digi hub
176	15	5	20000.0000	2026-01-20	Cash	RCT-176	621	2026-01-21 12:31:19.290634	\N	20,000 cash received from ahsan cba (Waseem)
177	37	5	35.0000	2026-01-20	Cash	RCT-177	623	2026-01-21 12:34:33.887629	\N	35 cash received for porter delivery from Adeel Karachi
178	113	5	650.0000	2026-01-20	Cash	RCT-178	625	2026-01-21 12:36:51.876289	\N	650 cash received from assd links
180	11	5	3165.0000	2026-01-21	Cash	RCT-180	627	2026-01-21 12:46:20.560093	\N	250000pkr @79 from AR Meezan to Fast Travels Services, Faisal Bhai 
182	11	5	152.2020	2026-01-21	Cash	RCT-182	631	2026-01-21 13:08:33.827348	\N	pkr 12024 @79 From Abdul Rehman Meezan to Khi Office Electric Bill , Karachi Office Expense
183	123	5	1450.0000	2026-01-21	Cash	RCT-183	633	2026-01-21 13:38:57.241906	\N	1450 cash received from digital game
184	104	5	700.0000	2026-01-21	Cash	RCT-184	646	2026-01-21 15:54:45.474561	\N	700 cash received from faraz GVT
185	104	5	3450.0000	2026-01-21	Cash	RCT-185	647	2026-01-21 15:55:15.303033	\N	3450 cash received from faraz GVT
186	11	5	3797.4680	2026-01-21	Cash	RCT-186	649	2026-01-21 16:29:08.25198	\N	300000PKR @79 FROM AR MEEZAN TO ANWAR SERVICES (PRIVATE) ,received from AR out to FB
187	120	5	89609.5129	2026-01-22	Cash	RCT-187	651	2026-01-22 09:42:46.591167	\N	Megatop Shipping invoices total amount for the month of december
170	98	5	17700.0000	2026-01-20	Cash	RCT-170	655	2026-01-21 12:25:30.339236	\N	17,700 cash received from rehan ONTEL, Nh ya shahzad atari khi sae received sae krne hein
188	80	5	9960.0000	2026-01-21	Cash	RCT-188	656	2026-01-22 10:33:57.704907	\N	9,960 cash received central system
189	78	5	6400.0000	2026-01-21	Cash	RCT-189	657	2026-01-22 10:34:30.780591	\N	6400 cash revived from hamza one tech
190	104	5	3400.0000	2026-01-22	Cash	RCT-190	658	2026-01-22 10:35:34.127024	\N	3400 cash received from faraz GVT
191	71	5	56025.0000	2026-01-22	Cash	RCT-191	660	2026-01-22 10:36:50.186801	\N	56,025 received from phone 4 u
193	113	5	3100.0000	2026-01-22	Cash	RCT-193	663	2026-01-22 10:41:27.7723	\N	3100 cash received from asad links
194	91	5	1898.7340	2026-01-15	Cash	RCT-194	668	2026-01-22 11:47:59.586507	\N	pkr 150,000 @79 from Muhammad Ahsan to On Point It services(Mudassir) , Faizan Ground
195	91	5	1620.2530	2026-01-16	Cash	RCT-195	672	2026-01-22 11:54:32.506755	\N	pkr 128,000 @79 , from Muhammad Ahsan To On Point IT Services , Faizan Ground
196	124	5	3924.0500	2026-01-17	Cash	RCT-196	674	2026-01-22 12:00:31.431516	\N	pkr 310,000 @79 , from Huzaifa (7500) - Abdullah (300000) - Huzaifa (2500) to AR Meezan,  by Ahmed Star City
197	91	5	2594.9360	2026-01-20	Cash	RCT-197	676	2026-01-22 12:03:59.103075	\N	205,000 pkr @79 , from Muhammad Areeb Batla to On Point IT Services ( Mudassir ) , By Faizan Ground
200	122	5	7134.0968	2026-01-22	Cash	RCT-200	735	2026-01-22 16:33:28.676921	\N	3,365.14 NZD @2.12 all invoices till december out to Shipping Exp
201	121	5	19379.4300	2026-01-22	Cash	RCT-201	737	2026-01-22 16:36:59.784734	\N	7980 AUD @ 2.4285 shipping invoices CT Freight Melbourne for december
199	125	5	1898.7340	2026-01-21	Cash	RCT-199	740	2026-01-22 12:19:06.791819	\N	150,000 pkr @79 , By Ali Raza to AR MEezan , by Zeeshan Fariya
198	125	5	1962.0250	2026-01-20	Cash	RCT-198	741	2026-01-22 12:16:21.345915	\N	pkr 155,000 @79 , from Zeeshan to AR Meezan through RAAST , By Zeeshan FARIYA
202	16	5	179750.0000	2026-01-17	Cash	RCT-202	743	2026-01-23 12:19:57.829828	\N	(09-1-26) 50,000 usd received from ahsan Mohsin @3.595
203	16	5	179750.0000	2026-01-17	Cash	RCT-203	745	2026-01-23 12:21:49.79796	\N	(14-1-26)  50,000 usd received from ahsan Mohsin @3.595 paid to Owais HT
204	54	5	8200.0000	2026-01-22	Cash	RCT-204	751	2026-01-23 13:52:05.47443	\N	8200 cash received Shahzad mughal
205	126	5	186000.0000	2026-01-23	Cash	RCT-205	753	2026-01-23 13:54:54.371132	\N	186000 cash received from golden vision
206	15	5	25.3160	2026-01-15	Cash	RCT-206	756	2026-01-23 14:21:32.699143	\N	pkr 2000 @79 , 2K Cash Out to Moshin Software Samsung Z Flip FRP
207	56	5	2531.6400	2026-01-23	Cash	RCT-207	757	2026-01-23 14:34:05.701863	\N	pkr 200,000 @79 , from M. Sumair Qadri to AR Rehman , by Sumair Pasta
208	91	5	1037.9700	2026-01-23	Cash	RCT-208	759	2026-01-23 14:36:53.622602	\N	82,000 pkr @79 , From Muhammad Ahsan to AR Meezan , by Faizan Ground
209	125	5	1936.7000	2026-01-23	Cash	RCT-209	761	2026-01-23 14:41:11.069986	\N	pkr 153,000 @79 , from Ali Raza to Abdul Rehman Meezan , by Zeeshan Fariya
\.


--
-- Data for Name: salesinvoices; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesinvoices (sales_invoice_id, customer_id, invoice_date, total_amount, journal_id) FROM stdin;
1	68	2026-01-08	12500.00	133
2	69	2026-01-08	7100.00	134
3	53	2026-01-08	2800.00	135
4	26	2026-01-08	37680.00	136
45	90	2026-01-08	2595.00	281
5	70	2026-01-08	8300.00	137
6	71	2026-01-08	29150.00	138
67	52	2026-01-11	5715.00	370
7	72	2026-01-08	71400.00	139
46	88	2026-01-08	4950.00	286
8	73	2026-01-08	7260.00	140
9	74	2026-01-08	12800.00	141
24	69	2026-01-08	7500.00	158
47	91	2026-01-08	3937.00	287
79	95	2026-01-14	10800.00	442
10	69	2026-01-08	17700.00	143
68	100	2026-01-12	5000.00	371
12	69	2026-01-09	20400.00	144
27	80	2026-01-09	122000.00	160
28	81	2026-01-08	8550.00	161
13	75	2026-01-08	9676.00	146
29	82	2026-01-08	13680.00	162
14	76	2026-01-08	5800.00	147
15	71	2026-01-09	122500.00	148
49	56	2026-01-08	1722.00	289
30	81	2026-01-08	12480.00	163
17	78	2026-01-08	27750.00	150
18	75	2026-01-08	7200.00	151
19	75	2026-01-08	5000.00	152
20	79	2026-01-09	36750.00	153
21	71	2026-01-08	34800.00	154
106	116	2026-01-17	3120.00	513
22	75	2026-01-08	7040.00	155
32	83	2026-01-08	7950.00	165
96	49	2026-01-15	26820.00	491
34	84	2026-01-08	27350.00	167
48	92	2026-01-08	1950.00	290
36	68	2026-01-08	4200.00	169
70	68	2026-01-12	16400.00	378
37	62	2026-01-08	2.00	170
50	91	2026-01-08	1659.00	298
38	69	2026-01-09	25500.00	174
39	53	2026-01-08	2800.00	175
40	52	2026-01-08	6860.00	176
51	91	2026-01-08	1443.00	299
41	75	2026-01-08	7500.00	177
42	69	2026-01-08	4200.00	178
80	75	2026-01-14	10200.00	443
52	93	2026-01-08	1494.00	302
71	68	2026-01-12	5650.00	379
53	94	2026-01-08	17330.00	326
54	81	2026-01-09	48590.00	332
26	85	2026-01-09	30200.00	180
43	86	2026-01-08	1740.00	185
44	88	2026-01-08	1722.00	280
90	96	2026-01-14	38340.00	485
81	104	2026-01-14	3900.00	444
56	68	2026-01-09	27920.00	334
57	95	2026-01-09	3750.00	335
58	53	2026-01-09	2800.00	336
55	81	2026-01-13	2950.00	380
59	96	2026-01-09	20190.00	337
60	52	2026-01-09	9490.00	338
73	93	2026-01-08	2215.00	395
62	98	2026-01-09	31385.00	341
63	69	2026-01-09	7000.00	342
64	68	2026-01-09	5700.00	343
74	91	2026-01-12	3519.00	402
65	74	2026-01-10	2550.00	344
75	101	2026-01-13	1747.00	405
83	7	2026-01-14	5620.00	446
76	54	2026-01-13	10200.00	409
91	95	2026-01-15	17050.00	486
103	84	2026-01-17	2930.00	505
85	84	2026-01-14	41620.00	448
77	103	2026-01-13	4900.00	411
78	97	2026-01-14	900.00	417
100	54	2026-01-17	5250.00	501
86	71	2026-01-15	5160.00	449
92	109	2026-01-15	20060.00	487
88	68	2026-01-15	6900.00	451
97	35	2026-01-15	12250.00	492
89	105	2026-01-14	60800.00	484
93	98	2026-01-15	20550.00	488
23	85	2026-01-08	20200.00	498
94	110	2026-01-15	6800.00	489
84	7	2026-01-15	8105.00	494
98	68	2026-01-17	31050.00	495
87	106	2026-01-15	73320.00	493
102	79	2026-01-17	17340.00	504
101	112	2026-01-17	3150.00	502
99	111	2026-01-16	17400.00	500
33	49	2026-01-08	47630.00	503
104	49	2026-01-17	23890.00	507
61	97	2026-01-09	2680.00	506
16	77	2026-01-08	10350.00	512
66	99	2026-01-08	16800.00	508
31	36	2026-01-08	39500.00	511
69	54	2026-01-10	35150.00	510
109	114	2026-01-17	250.00	525
107	113	2026-01-18	3950.00	515
111	78	2026-01-19	2600.00	530
112	105	2026-01-19	13800.00	538
114	68	2026-01-19	13800.00	539
115	53	2026-01-19	9700.00	540
116	104	2026-01-19	6560.00	542
118	98	2026-01-20	17700.00	544
119	95	2026-01-19	6450.00	547
120	78	2026-01-20	1610.00	560
95	113	2026-01-15	4400.00	571
121	113	2026-01-08	1600.00	573
117	96	2026-01-20	39330.00	636
122	104	2026-01-20	10710.00	637
123	105	2026-01-20	11600.00	638
124	113	2026-01-20	3700.00	639
125	123	2026-01-21	1450.00	640
127	104	2026-01-21	3450.00	643
128	113	2026-01-21	3100.00	644
129	80	2026-01-22	9960.00	665
130	68	2026-01-22	13800.00	666
131	71	2026-01-22	56025.00	667
132	104	2026-01-21	3400.00	689
133	7	2026-01-22	48470.00	696
134	71	2026-01-22	2630.00	697
126	78	2026-01-21	6400.00	700
136	45	2026-01-22	150770.00	747
137	54	2026-01-22	8200.00	748
\.


--
-- Data for Name: salesitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesitems (sales_item_id, sales_invoice_id, item_id, quantity, unit_price) FROM stdin;
1	1	131	2	6250.00
2	2	17	2	3550.00
3	3	12	2	1400.00
4	4	67	2	4220.00
5	4	67	3	4000.00
6	4	66	3	3250.00
7	4	88	1	3650.00
8	4	63	3	1280.00
9	5	8	1	8300.00
10	6	75	5	5830.00
11	7	17	20	3570.00
12	8	17	2	3630.00
13	9	7	1	11350.00
14	9	12	1	1450.00
16	10	20	300	59.00
19	12	17	3	3550.00
20	12	14	10	975.00
22	13	20	164	59.00
23	14	75	1	5800.00
24	15	1	100	1225.00
26	17	17	5	3550.00
27	17	18	5	2000.00
28	18	17	2	3600.00
29	19	1	4	1250.00
30	20	1	30	1225.00
31	21	75	6	5800.00
32	22	6	2	3520.00
37	24	9	3	2500.00
40	27	1	100	1220.00
41	28	70	3	2850.00
42	29	68	3	3430.00
43	29	68	1	3390.00
44	30	77	6	2080.00
50	32	69	2	3975.00
56	34	68	3	3430.00
57	34	70	4	2850.00
58	34	159	2	2830.00
60	36	12	3	1400.00
61	37	79	1	1.00
62	37	79	1	1.00
63	38	161	15	1700.00
64	39	12	2	1400.00
65	40	68	2	3430.00
66	41	1	6	1250.00
67	42	12	3	1400.00
71	26	1	25	1208.00
72	43	161	1	1740.00
73	44	103	1	1722.00
74	45	79	1	2595.00
75	46	81	1	2355.00
76	46	79	1	2595.00
77	47	75	1	3937.00
79	49	103	1	1722.00
80	48	132	1	1950.00
81	50	86	1	1659.00
82	51	138	1	1443.00
83	52	104	1	1494.00
84	53	68	3	3510.00
85	53	68	2	3400.00
86	54	68	6	3430.00
87	54	68	5	3520.00
88	54	68	3	3470.00
90	56	17	8	3490.00
91	57	68	1	3750.00
92	58	12	2	1400.00
93	59	68	6	3365.00
94	60	68	2	3180.00
95	60	68	1	3130.00
97	62	68	6	3430.00
98	62	68	3	3520.00
99	62	45	1	245.00
100	63	12	5	1400.00
101	64	10	2	2850.00
102	65	9	1	2550.00
104	67	160	3	1905.00
105	68	1	4	1250.00
114	70	8	2	8200.00
115	71	12	2	1400.00
116	71	10	1	2850.00
118	55	77	1	2950.00
119	73	81	1	2215.00
120	74	76	1	3519.00
121	75	103	1	1747.00
122	76	53	1	10200.00
124	77	1	4	1225.00
125	78	44	1	900.00
126	79	68	2	3800.00
127	79	70	1	3200.00
128	80	6	3	3400.00
129	81	160	2	1950.00
131	83	28	2	650.00
132	83	162	8	540.00
141	85	68	4	3220.00
142	85	68	4	3580.00
143	85	70	1	2860.00
144	85	70	1	2810.00
145	85	70	1	2950.00
146	85	70	2	2900.00
147	86	161	3	1720.00
149	88	11	1	2700.00
150	88	12	3	1400.00
151	89	68	16	3800.00
152	90	68	6	3220.00
153	90	68	6	3170.00
154	91	68	3	3800.00
155	91	69	1	5650.00
156	92	68	1	3450.00
157	92	68	3	3400.00
158	92	68	1	3550.00
159	92	70	1	2860.00
160	93	68	3	3450.00
161	93	68	3	3400.00
162	94	68	2	3400.00
164	96	152	4	2470.00
165	96	152	2	2820.00
166	96	152	4	2470.00
167	96	104	1	1420.00
168	97	1	10	1225.00
169	87	1	60	1222.00
170	84	4	3	1.00
171	84	4	11	202.00
172	84	4	4	202.00
173	84	4	2	193.00
174	84	4	6	193.00
175	84	4	6	202.00
176	84	4	4	193.00
177	84	4	8	193.00
178	98	6	9	3450.00
179	23	61	1	4200.00
180	23	99	1	3400.00
181	23	126	3	4200.00
182	99	68	4	3540.00
183	99	68	1	3240.00
184	100	98	1	5250.00
185	101	172	3	1050.00
186	33	105	1	850.00
187	33	106	5	760.00
188	33	152	4	2470.00
189	33	152	10	2470.00
190	33	152	3	2800.00
191	102	172	17	1020.00
192	103	70	1	2930.00
193	61	63	2	1340.00
194	104	152	4	2470.00
195	104	152	1	2460.00
196	104	152	2	2470.00
197	104	104	2	1410.00
198	104	90	1	1240.00
199	104	105	3	850.00
200	66	68	5	3360.00
202	69	55	1	2350.00
203	69	56	1	2650.00
204	69	56	1	2300.00
205	69	59	1	2100.00
206	69	62	1	2080.00
207	69	97	1	5050.00
208	69	100	6	2070.00
209	69	151	1	6200.00
210	31	68	3	3430.00
211	31	70	1	2820.00
212	31	70	1	2640.00
213	31	70	7	2850.00
214	31	75	1	3800.00
215	16	54	1	10350.00
216	106	42	4	780.00
218	107	68	1	3950.00
220	109	72	1	250.00
222	111	11	1	2600.00
223	112	68	6	2000.00
224	112	70	1	1800.00
226	114	6	4	3450.00
227	115	6	2	3450.00
228	115	12	2	1400.00
229	116	68	1	3260.00
230	116	68	1	3300.00
233	118	68	5	3540.00
234	119	77	3	2150.00
235	120	2	1	1610.00
236	95	68	1	4400.00
237	121	174	1	1600.00
240	117	68	3	3670.00
241	117	68	8	3540.00
242	122	77	3	2150.00
243	122	77	2	2130.00
244	123	68	2	3900.00
245	123	68	1	3800.00
246	124	70	1	3700.00
247	125	12	1	1450.00
249	127	68	1	3450.00
250	128	77	1	3100.00
251	129	1	8	1245.00
252	130	6	4	3450.00
253	131	1	30	1245.00
254	131	1	15	1245.00
255	132	68	1	3400.00
256	133	3	37	1310.00
257	134	3	2	1315.00
259	126	2	4	1600.00
261	136	68	3	4400.00
262	136	68	2	4500.00
263	136	75	1	5000.00
264	136	75	1	4900.00
265	136	69	1	6700.00
266	136	68	3	4500.00
267	136	68	1	4350.00
268	136	68	1	4400.00
269	136	70	10	4050.00
270	136	70	3	3850.00
271	136	159	2	4450.00
272	136	159	1	4600.00
273	136	159	1	4500.00
274	136	102	1	2900.00
275	136	102	3	2950.00
276	136	42	8	760.00
277	136	43	4	460.00
278	137	150	1	6700.00
279	137	60	1	1500.00
\.


--
-- Data for Name: salesreturnitems; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesreturnitems (return_item_id, sales_return_id, item_id, sold_price, cost_price, serial_number) FROM stdin;
1	1	79	1.00	4.00	357205987236407
2	1	79	1.00	3051.50	357031376241620
\.


--
-- Data for Name: salesreturns; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salesreturns (sales_return_id, customer_id, return_date, total_amount, journal_id) FROM stdin;
1	62	2026-01-12	2.00	340
\.


--
-- Data for Name: soldunits; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.soldunits (sold_unit_id, sales_item_id, unit_id, sold_price, status) FROM stdin;
1	1	2374	6250.00	Sold
2	1	2375	6250.00	Sold
3	2	686	3550.00	Sold
4	2	687	3550.00	Sold
5	3	559	1400.00	Sold
6	3	560	1400.00	Sold
7	4	2286	4220.00	Sold
8	4	2287	4220.00	Sold
9	5	2288	4000.00	Sold
10	5	2289	4000.00	Sold
11	5	2290	4000.00	Sold
12	6	2283	3250.00	Sold
13	6	2284	3250.00	Sold
14	6	2285	3250.00	Sold
15	7	2315	3650.00	Sold
16	8	2278	1280.00	Sold
17	8	2279	1280.00	Sold
18	8	2280	1280.00	Sold
19	9	503	8300.00	Sold
20	10	2333	5830.00	Sold
21	10	2332	5830.00	Sold
22	10	2324	5830.00	Sold
23	10	2327	5830.00	Sold
24	10	2323	5830.00	Sold
25	11	655	3570.00	Sold
26	11	656	3570.00	Sold
27	11	657	3570.00	Sold
28	11	658	3570.00	Sold
29	11	659	3570.00	Sold
30	11	660	3570.00	Sold
31	11	661	3570.00	Sold
32	11	662	3570.00	Sold
33	11	663	3570.00	Sold
34	11	664	3570.00	Sold
35	11	644	3570.00	Sold
36	11	645	3570.00	Sold
37	11	646	3570.00	Sold
38	11	647	3570.00	Sold
39	11	648	3570.00	Sold
40	11	650	3570.00	Sold
41	11	651	3570.00	Sold
42	11	652	3570.00	Sold
43	11	649	3570.00	Sold
44	11	643	3570.00	Sold
45	12	654	3630.00	Sold
46	12	653	3630.00	Sold
47	13	497	11350.00	Sold
48	14	558	1450.00	Sold
1002	24	1503	1225.00	Sold
1003	24	1504	1225.00	Sold
1004	24	1505	1225.00	Sold
1005	24	1506	1225.00	Sold
1006	24	1507	1225.00	Sold
1007	24	1508	1225.00	Sold
1008	24	1509	1225.00	Sold
1009	24	1510	1225.00	Sold
1010	24	1511	1225.00	Sold
1011	24	1512	1225.00	Sold
1012	24	1513	1225.00	Sold
660	19	666	3550.00	Sold
661	19	665	3550.00	Sold
662	19	680	3550.00	Sold
663	20	619	975.00	Sold
664	20	618	975.00	Sold
665	20	616	975.00	Sold
666	20	608	975.00	Sold
667	20	612	975.00	Sold
668	20	611	975.00	Sold
669	20	603	975.00	Sold
670	20	613	975.00	Sold
671	20	622	975.00	Sold
672	20	605	975.00	Sold
1013	24	1514	1225.00	Sold
1014	24	1515	1225.00	Sold
1015	24	1516	1225.00	Sold
1016	24	1517	1225.00	Sold
1017	24	1518	1225.00	Sold
1018	24	1519	1225.00	Sold
1019	24	1520	1225.00	Sold
1020	24	1521	1225.00	Sold
1021	24	1522	1225.00	Sold
1022	24	1523	1225.00	Sold
1023	24	1524	1225.00	Sold
1024	24	1525	1225.00	Sold
1025	24	1526	1225.00	Sold
1026	24	1527	1225.00	Sold
1027	24	1528	1225.00	Sold
1028	24	1529	1225.00	Sold
1029	24	1530	1225.00	Sold
1030	24	1531	1225.00	Sold
1031	24	1532	1225.00	Sold
1032	24	1533	1225.00	Sold
1033	24	1534	1225.00	Sold
1034	24	1535	1225.00	Sold
1035	24	1536	1225.00	Sold
1036	24	1537	1225.00	Sold
1037	24	1538	1225.00	Sold
1038	24	1539	1225.00	Sold
1039	24	1540	1225.00	Sold
1040	24	1541	1225.00	Sold
1041	24	1542	1225.00	Sold
1042	24	1543	1225.00	Sold
1043	24	1544	1225.00	Sold
1044	24	1545	1225.00	Sold
1045	24	1546	1225.00	Sold
1046	24	1547	1225.00	Sold
1047	24	1548	1225.00	Sold
1048	24	1549	1225.00	Sold
1049	24	1550	1225.00	Sold
1050	24	1551	1225.00	Sold
1051	24	1552	1225.00	Sold
1052	24	1553	1225.00	Sold
1053	24	1554	1225.00	Sold
1054	24	1555	1225.00	Sold
1055	24	1556	1225.00	Sold
1056	24	1557	1225.00	Sold
1057	24	1558	1225.00	Sold
1058	24	1559	1225.00	Sold
1059	24	1560	1225.00	Sold
1060	24	1561	1225.00	Sold
1061	24	1562	1225.00	Sold
1062	24	1563	1225.00	Sold
1063	24	1564	1225.00	Sold
1064	24	1565	1225.00	Sold
1065	24	1566	1225.00	Sold
1066	24	1567	1225.00	Sold
1067	24	1568	1225.00	Sold
1068	24	1569	1225.00	Sold
1069	24	1570	1225.00	Sold
1070	24	1571	1225.00	Sold
1071	24	1572	1225.00	Sold
1072	24	1573	1225.00	Sold
1073	24	1574	1225.00	Sold
1074	24	1575	1225.00	Sold
1075	24	1576	1225.00	Sold
1076	24	1577	1225.00	Sold
1077	24	1578	1225.00	Sold
1078	24	1579	1225.00	Sold
1079	24	1580	1225.00	Sold
1080	24	1581	1225.00	Sold
1081	24	1582	1225.00	Sold
1082	24	1583	1225.00	Sold
1083	24	1584	1225.00	Sold
1084	24	1585	1225.00	Sold
1085	24	1586	1225.00	Sold
1086	24	1587	1225.00	Sold
1087	24	1588	1225.00	Sold
1088	24	1589	1225.00	Sold
1089	24	1590	1225.00	Sold
1090	24	1591	1225.00	Sold
1091	24	1592	1225.00	Sold
1092	24	1593	1225.00	Sold
1093	24	1594	1225.00	Sold
1094	24	1595	1225.00	Sold
1095	24	1596	1225.00	Sold
1096	24	1597	1225.00	Sold
1097	24	1598	1225.00	Sold
1098	24	1599	1225.00	Sold
1099	24	1600	1225.00	Sold
1100	24	1601	1225.00	Sold
1101	24	1602	1225.00	Sold
1103	26	681	3550.00	Sold
1104	26	675	3550.00	Sold
1105	26	667	3550.00	Sold
1106	26	668	3550.00	Sold
1107	26	669	3550.00	Sold
1108	27	700	2000.00	Sold
1109	27	701	2000.00	Sold
1110	27	699	2000.00	Sold
1111	27	698	2000.00	Sold
1112	27	702	2000.00	Sold
1115	29	1603	1250.00	Sold
1116	29	1604	1250.00	Sold
1117	29	1605	1250.00	Sold
1118	29	1606	1250.00	Sold
1132	30	1620	1225.00	Sold
1133	30	1621	1225.00	Sold
1134	30	1622	1225.00	Sold
1135	30	1623	1225.00	Sold
1136	30	1624	1225.00	Sold
1137	30	1625	1225.00	Sold
1138	30	1626	1225.00	Sold
1139	30	1627	1225.00	Sold
1140	30	1628	1225.00	Sold
1141	30	1629	1225.00	Sold
1142	30	1630	1225.00	Sold
1143	30	1631	1225.00	Sold
1144	30	1632	1225.00	Sold
1145	30	1633	1225.00	Sold
1146	30	1634	1225.00	Sold
1147	30	1635	1225.00	Sold
1148	30	1636	1225.00	Sold
1149	31	2330	5800.00	Sold
1150	31	2329	5800.00	Sold
1151	31	2328	5800.00	Sold
1152	31	2331	5800.00	Sold
1153	31	2325	5800.00	Sold
1154	31	2326	5800.00	Sold
1155	32	489	3520.00	Sold
1156	32	488	3520.00	Sold
1165	37	533	2500.00	Sold
1166	37	534	2500.00	Sold
1167	37	528	2500.00	Sold
1001	23	2334	5800.00	Sold
1193	40	1662	1220.00	Sold
1194	40	1663	1220.00	Sold
1195	40	1664	1220.00	Sold
1196	40	1665	1220.00	Sold
1197	40	1666	1220.00	Sold
837	22	1288	59.00	Sold
838	22	1289	59.00	Sold
839	22	1290	59.00	Sold
840	22	1291	59.00	Sold
841	22	1292	59.00	Sold
842	22	1293	59.00	Sold
843	22	1294	59.00	Sold
844	22	1295	59.00	Sold
845	22	1296	59.00	Sold
846	22	1297	59.00	Sold
847	22	1298	59.00	Sold
848	22	1299	59.00	Sold
849	22	1300	59.00	Sold
850	22	1301	59.00	Sold
851	22	1302	59.00	Sold
852	22	1303	59.00	Sold
853	22	1304	59.00	Sold
854	22	1305	59.00	Sold
855	22	1306	59.00	Sold
856	22	1307	59.00	Sold
857	22	1308	59.00	Sold
858	22	1309	59.00	Sold
859	22	1310	59.00	Sold
860	22	1311	59.00	Sold
861	22	1312	59.00	Sold
862	22	1313	59.00	Sold
863	22	1314	59.00	Sold
864	22	1315	59.00	Sold
865	22	1316	59.00	Sold
866	22	1317	59.00	Sold
867	22	1318	59.00	Sold
868	22	1319	59.00	Sold
869	22	1320	59.00	Sold
870	22	1321	59.00	Sold
871	22	1322	59.00	Sold
872	22	1323	59.00	Sold
873	22	1324	59.00	Sold
874	22	1325	59.00	Sold
875	22	1326	59.00	Sold
876	22	1327	59.00	Sold
877	22	1328	59.00	Sold
878	22	1329	59.00	Sold
879	22	1330	59.00	Sold
880	22	1331	59.00	Sold
881	22	1332	59.00	Sold
882	22	1333	59.00	Sold
883	22	1334	59.00	Sold
884	22	1335	59.00	Sold
885	22	1336	59.00	Sold
886	22	1337	59.00	Sold
887	22	1338	59.00	Sold
888	22	1339	59.00	Sold
889	22	1340	59.00	Sold
890	22	1341	59.00	Sold
891	22	1342	59.00	Sold
892	22	1343	59.00	Sold
893	22	1344	59.00	Sold
894	22	1345	59.00	Sold
895	22	1346	59.00	Sold
896	22	1347	59.00	Sold
897	22	1348	59.00	Sold
898	22	1349	59.00	Sold
899	22	1350	59.00	Sold
900	22	1351	59.00	Sold
901	22	1352	59.00	Sold
902	22	1353	59.00	Sold
903	22	1354	59.00	Sold
904	22	1355	59.00	Sold
905	22	1356	59.00	Sold
906	22	1357	59.00	Sold
907	22	1358	59.00	Sold
908	22	1359	59.00	Sold
909	22	1360	59.00	Sold
910	22	1361	59.00	Sold
911	22	1362	59.00	Sold
912	22	1363	59.00	Sold
913	22	1364	59.00	Sold
914	22	1365	59.00	Sold
915	22	1366	59.00	Sold
916	22	1367	59.00	Sold
917	22	1368	59.00	Sold
918	22	1369	59.00	Sold
919	22	1370	59.00	Sold
920	22	1371	59.00	Sold
921	22	1372	59.00	Sold
922	22	1373	59.00	Sold
923	22	1374	59.00	Sold
924	22	1375	59.00	Sold
925	22	1376	59.00	Sold
926	22	1377	59.00	Sold
927	22	1378	59.00	Sold
928	22	1379	59.00	Sold
929	22	1380	59.00	Sold
930	22	1381	59.00	Sold
931	22	1382	59.00	Sold
932	22	1383	59.00	Sold
933	22	1384	59.00	Sold
934	22	1385	59.00	Sold
935	22	1386	59.00	Sold
936	22	1387	59.00	Sold
937	22	1388	59.00	Sold
938	22	1389	59.00	Sold
939	22	1390	59.00	Sold
940	22	1391	59.00	Sold
941	22	1392	59.00	Sold
942	22	1393	59.00	Sold
943	22	1394	59.00	Sold
944	22	1395	59.00	Sold
349	16	974	59.00	Sold
350	16	975	59.00	Sold
351	16	976	59.00	Sold
352	16	977	59.00	Sold
353	16	978	59.00	Sold
354	16	979	59.00	Sold
355	16	980	59.00	Sold
356	16	981	59.00	Sold
357	16	982	59.00	Sold
358	16	983	59.00	Sold
359	16	984	59.00	Sold
360	16	985	59.00	Sold
361	16	986	59.00	Sold
362	16	987	59.00	Sold
363	16	988	59.00	Sold
364	16	989	59.00	Sold
365	16	990	59.00	Sold
366	16	991	59.00	Sold
367	16	992	59.00	Sold
368	16	993	59.00	Sold
369	16	994	59.00	Sold
370	16	995	59.00	Sold
371	16	996	59.00	Sold
372	16	997	59.00	Sold
373	16	998	59.00	Sold
374	16	999	59.00	Sold
375	16	1000	59.00	Sold
376	16	1001	59.00	Sold
377	16	1002	59.00	Sold
378	16	1003	59.00	Sold
379	16	1004	59.00	Sold
380	16	1005	59.00	Sold
381	16	1006	59.00	Sold
382	16	1007	59.00	Sold
383	16	1008	59.00	Sold
384	16	1009	59.00	Sold
385	16	1010	59.00	Sold
386	16	1011	59.00	Sold
387	16	1012	59.00	Sold
388	16	1013	59.00	Sold
389	16	1014	59.00	Sold
390	16	1015	59.00	Sold
391	16	1016	59.00	Sold
392	16	1017	59.00	Sold
393	16	1018	59.00	Sold
394	16	1019	59.00	Sold
395	16	1020	59.00	Sold
396	16	1021	59.00	Sold
397	16	1022	59.00	Sold
398	16	1023	59.00	Sold
399	16	1024	59.00	Sold
400	16	1025	59.00	Sold
401	16	1026	59.00	Sold
402	16	1027	59.00	Sold
403	16	1028	59.00	Sold
404	16	1029	59.00	Sold
405	16	1030	59.00	Sold
406	16	1031	59.00	Sold
407	16	1032	59.00	Sold
408	16	1033	59.00	Sold
409	16	1034	59.00	Sold
410	16	1035	59.00	Sold
411	16	1036	59.00	Sold
412	16	1037	59.00	Sold
413	16	1038	59.00	Sold
414	16	1039	59.00	Sold
415	16	1040	59.00	Sold
416	16	1041	59.00	Sold
417	16	1042	59.00	Sold
418	16	1043	59.00	Sold
419	16	1044	59.00	Sold
420	16	1045	59.00	Sold
421	16	1046	59.00	Sold
422	16	1047	59.00	Sold
423	16	1048	59.00	Sold
424	16	1049	59.00	Sold
425	16	1050	59.00	Sold
426	16	1051	59.00	Sold
427	16	1052	59.00	Sold
428	16	1053	59.00	Sold
429	16	1054	59.00	Sold
430	16	1055	59.00	Sold
431	16	1056	59.00	Sold
432	16	1057	59.00	Sold
433	16	1058	59.00	Sold
434	16	1059	59.00	Sold
435	16	1060	59.00	Sold
436	16	1061	59.00	Sold
437	16	1062	59.00	Sold
438	16	1063	59.00	Sold
439	16	1064	59.00	Sold
440	16	1065	59.00	Sold
441	16	1066	59.00	Sold
442	16	1067	59.00	Sold
443	16	1068	59.00	Sold
444	16	1069	59.00	Sold
445	16	1070	59.00	Sold
446	16	1071	59.00	Sold
447	16	1072	59.00	Sold
448	16	1073	59.00	Sold
449	16	1074	59.00	Sold
450	16	1075	59.00	Sold
451	16	1076	59.00	Sold
452	16	1077	59.00	Sold
453	16	1078	59.00	Sold
454	16	1079	59.00	Sold
455	16	1080	59.00	Sold
456	16	1081	59.00	Sold
457	16	1082	59.00	Sold
458	16	1083	59.00	Sold
459	16	1084	59.00	Sold
460	16	1085	59.00	Sold
461	16	1086	59.00	Sold
462	16	1087	59.00	Sold
463	16	1088	59.00	Sold
464	16	1089	59.00	Sold
465	16	1090	59.00	Sold
466	16	1091	59.00	Sold
467	16	1092	59.00	Sold
468	16	1093	59.00	Sold
469	16	1094	59.00	Sold
470	16	1095	59.00	Sold
471	16	1096	59.00	Sold
472	16	1097	59.00	Sold
473	16	1098	59.00	Sold
474	16	1099	59.00	Sold
475	16	1100	59.00	Sold
476	16	1101	59.00	Sold
477	16	1102	59.00	Sold
478	16	1103	59.00	Sold
479	16	1104	59.00	Sold
480	16	1105	59.00	Sold
481	16	1106	59.00	Sold
482	16	1107	59.00	Sold
483	16	1108	59.00	Sold
484	16	1109	59.00	Sold
485	16	1110	59.00	Sold
486	16	1111	59.00	Sold
487	16	1112	59.00	Sold
488	16	1113	59.00	Sold
489	16	1114	59.00	Sold
490	16	1115	59.00	Sold
491	16	1116	59.00	Sold
492	16	1117	59.00	Sold
493	16	1118	59.00	Sold
494	16	1119	59.00	Sold
495	16	1120	59.00	Sold
496	16	1121	59.00	Sold
497	16	1122	59.00	Sold
498	16	1123	59.00	Sold
499	16	1124	59.00	Sold
500	16	1125	59.00	Sold
501	16	1126	59.00	Sold
502	16	1127	59.00	Sold
503	16	1128	59.00	Sold
504	16	1129	59.00	Sold
505	16	1130	59.00	Sold
506	16	1131	59.00	Sold
507	16	1132	59.00	Sold
508	16	1133	59.00	Sold
509	16	1134	59.00	Sold
510	16	1135	59.00	Sold
511	16	1136	59.00	Sold
512	16	1137	59.00	Sold
513	16	1138	59.00	Sold
514	16	1139	59.00	Sold
515	16	1140	59.00	Sold
516	16	1141	59.00	Sold
517	16	1142	59.00	Sold
518	16	1143	59.00	Sold
519	16	1144	59.00	Sold
520	16	1145	59.00	Sold
521	16	1146	59.00	Sold
522	16	1147	59.00	Sold
523	16	1148	59.00	Sold
524	16	1149	59.00	Sold
525	16	1150	59.00	Sold
526	16	1151	59.00	Sold
527	16	1152	59.00	Sold
528	16	1153	59.00	Sold
529	16	1154	59.00	Sold
530	16	1155	59.00	Sold
531	16	1156	59.00	Sold
532	16	1157	59.00	Sold
533	16	1158	59.00	Sold
534	16	1159	59.00	Sold
535	16	1160	59.00	Sold
536	16	1161	59.00	Sold
537	16	1162	59.00	Sold
538	16	1163	59.00	Sold
539	16	1164	59.00	Sold
540	16	1165	59.00	Sold
541	16	1166	59.00	Sold
542	16	1167	59.00	Sold
543	16	1168	59.00	Sold
544	16	1169	59.00	Sold
545	16	1170	59.00	Sold
546	16	1171	59.00	Sold
547	16	1172	59.00	Sold
548	16	1173	59.00	Sold
549	16	1174	59.00	Sold
550	16	1175	59.00	Sold
551	16	1176	59.00	Sold
552	16	1177	59.00	Sold
553	16	1178	59.00	Sold
554	16	1179	59.00	Sold
555	16	1180	59.00	Sold
556	16	1181	59.00	Sold
557	16	1182	59.00	Sold
558	16	1183	59.00	Sold
559	16	1184	59.00	Sold
560	16	1185	59.00	Sold
561	16	1186	59.00	Sold
562	16	1187	59.00	Sold
563	16	1188	59.00	Sold
564	16	1189	59.00	Sold
565	16	1190	59.00	Sold
566	16	1191	59.00	Sold
567	16	1192	59.00	Sold
568	16	1193	59.00	Sold
569	16	1194	59.00	Sold
570	16	1195	59.00	Sold
571	16	1196	59.00	Sold
572	16	1197	59.00	Sold
573	16	1198	59.00	Sold
574	16	1199	59.00	Sold
575	16	1200	59.00	Sold
576	16	1201	59.00	Sold
577	16	1202	59.00	Sold
578	16	1203	59.00	Sold
579	16	1204	59.00	Sold
580	16	1205	59.00	Sold
581	16	1206	59.00	Sold
582	16	1207	59.00	Sold
583	16	1208	59.00	Sold
584	16	1209	59.00	Sold
585	16	1210	59.00	Sold
586	16	1211	59.00	Sold
587	16	1212	59.00	Sold
588	16	1213	59.00	Sold
589	16	1214	59.00	Sold
590	16	1215	59.00	Sold
591	16	1216	59.00	Sold
592	16	1217	59.00	Sold
593	16	1218	59.00	Sold
594	16	1219	59.00	Sold
595	16	1220	59.00	Sold
596	16	1221	59.00	Sold
597	16	1222	59.00	Sold
598	16	1223	59.00	Sold
599	16	1224	59.00	Sold
600	16	1225	59.00	Sold
601	16	1226	59.00	Sold
602	16	1227	59.00	Sold
603	16	1228	59.00	Sold
604	16	1229	59.00	Sold
605	16	1230	59.00	Sold
606	16	1231	59.00	Sold
607	16	1232	59.00	Sold
608	16	1233	59.00	Sold
609	16	1234	59.00	Sold
610	16	1235	59.00	Sold
611	16	1236	59.00	Sold
612	16	1237	59.00	Sold
613	16	1238	59.00	Sold
614	16	1239	59.00	Sold
615	16	1240	59.00	Sold
616	16	1241	59.00	Sold
617	16	1242	59.00	Sold
618	16	1243	59.00	Sold
619	16	1244	59.00	Sold
620	16	1245	59.00	Sold
621	16	1246	59.00	Sold
622	16	1247	59.00	Sold
623	16	1248	59.00	Sold
624	16	1249	59.00	Sold
625	16	1250	59.00	Sold
626	16	1251	59.00	Sold
627	16	1252	59.00	Sold
628	16	1253	59.00	Sold
629	16	1254	59.00	Sold
630	16	1255	59.00	Sold
631	16	1256	59.00	Sold
632	16	1257	59.00	Sold
633	16	1258	59.00	Sold
634	16	1259	59.00	Sold
635	16	1260	59.00	Sold
636	16	1261	59.00	Sold
637	16	1262	59.00	Sold
638	16	1263	59.00	Sold
639	16	1264	59.00	Sold
640	16	1265	59.00	Sold
641	16	1266	59.00	Sold
642	16	1267	59.00	Sold
643	16	1268	59.00	Sold
644	16	1269	59.00	Sold
645	16	1270	59.00	Sold
646	16	1271	59.00	Sold
647	16	1272	59.00	Sold
648	16	1273	59.00	Sold
945	22	1396	59.00	Sold
946	22	1397	59.00	Sold
947	22	1398	59.00	Sold
948	22	1399	59.00	Sold
949	22	1400	59.00	Sold
950	22	1401	59.00	Sold
951	22	1402	59.00	Sold
952	22	1403	59.00	Sold
953	22	1404	59.00	Sold
954	22	1405	59.00	Sold
955	22	1406	59.00	Sold
956	22	1407	59.00	Sold
957	22	1408	59.00	Sold
958	22	1409	59.00	Sold
959	22	1410	59.00	Sold
960	22	1411	59.00	Sold
961	22	1412	59.00	Sold
962	22	1413	59.00	Sold
963	22	1414	59.00	Sold
964	22	1415	59.00	Sold
965	22	1416	59.00	Sold
966	22	1417	59.00	Sold
967	22	1418	59.00	Sold
968	22	1419	59.00	Sold
969	22	1420	59.00	Sold
970	22	1421	59.00	Sold
971	22	1422	59.00	Sold
972	22	1423	59.00	Sold
973	22	1424	59.00	Sold
974	22	1425	59.00	Sold
975	22	1426	59.00	Sold
976	22	1427	59.00	Sold
977	22	1428	59.00	Sold
978	22	1429	59.00	Sold
979	22	1430	59.00	Sold
980	22	1431	59.00	Sold
981	22	1432	59.00	Sold
982	22	1433	59.00	Sold
983	22	1434	59.00	Sold
984	22	1435	59.00	Sold
985	22	1436	59.00	Sold
986	22	1437	59.00	Sold
987	22	1274	59.00	Sold
988	22	1275	59.00	Sold
989	22	1276	59.00	Sold
990	22	1277	59.00	Sold
991	22	1278	59.00	Sold
992	22	1279	59.00	Sold
993	22	1280	59.00	Sold
994	22	1281	59.00	Sold
995	22	1282	59.00	Sold
996	22	1283	59.00	Sold
997	22	1284	59.00	Sold
998	22	1285	59.00	Sold
999	22	1286	59.00	Sold
1000	22	1287	59.00	Sold
1113	28	677	3600.00	Sold
1114	28	676	3600.00	Sold
1119	30	1607	1225.00	Sold
1120	30	1608	1225.00	Sold
1121	30	1609	1225.00	Sold
1122	30	1610	1225.00	Sold
1123	30	1611	1225.00	Sold
1124	30	1612	1225.00	Sold
1125	30	1613	1225.00	Sold
1126	30	1614	1225.00	Sold
1127	30	1615	1225.00	Sold
1128	30	1616	1225.00	Sold
1129	30	1617	1225.00	Sold
1130	30	1618	1225.00	Sold
1131	30	1619	1225.00	Sold
1198	40	1667	1220.00	Sold
1199	40	1668	1220.00	Sold
1200	40	1669	1220.00	Sold
1201	40	1670	1220.00	Sold
1202	40	1671	1220.00	Sold
1203	40	1672	1220.00	Sold
1204	40	1673	1220.00	Sold
1205	40	1674	1220.00	Sold
1206	40	1675	1220.00	Sold
1207	40	1676	1220.00	Sold
1208	40	1677	1220.00	Sold
1209	40	1678	1220.00	Sold
1210	40	1679	1220.00	Sold
1211	40	1680	1220.00	Sold
1212	40	1681	1220.00	Sold
1213	40	1682	1220.00	Sold
1214	40	1683	1220.00	Sold
1215	40	1684	1220.00	Sold
1216	40	1685	1220.00	Sold
1217	40	1686	1220.00	Sold
1218	40	1687	1220.00	Sold
1219	40	1688	1220.00	Sold
1220	40	1689	1220.00	Sold
1221	40	1690	1220.00	Sold
1222	40	1691	1220.00	Sold
1223	40	1692	1220.00	Sold
1224	40	1693	1220.00	Sold
1225	40	1694	1220.00	Sold
1226	40	1695	1220.00	Sold
1227	40	1696	1220.00	Sold
1228	40	1697	1220.00	Sold
1229	40	1698	1220.00	Sold
1230	40	1699	1220.00	Sold
1231	40	1700	1220.00	Sold
1232	40	1701	1220.00	Sold
1233	40	1702	1220.00	Sold
1234	40	1703	1220.00	Sold
1235	40	1704	1220.00	Sold
1236	40	1705	1220.00	Sold
1237	40	1706	1220.00	Sold
1238	40	1707	1220.00	Sold
1239	40	1708	1220.00	Sold
1240	40	1709	1220.00	Sold
1241	40	1710	1220.00	Sold
1242	40	1711	1220.00	Sold
1243	40	1712	1220.00	Sold
1244	40	1713	1220.00	Sold
1245	40	1714	1220.00	Sold
1246	40	1715	1220.00	Sold
1247	40	1716	1220.00	Sold
1248	40	1717	1220.00	Sold
1249	40	1718	1220.00	Sold
1250	40	1719	1220.00	Sold
1251	40	1720	1220.00	Sold
1252	40	1721	1220.00	Sold
1253	40	1722	1220.00	Sold
1254	40	1723	1220.00	Sold
1255	40	1724	1220.00	Sold
1256	40	1725	1220.00	Sold
1257	40	1726	1220.00	Sold
1258	40	1727	1220.00	Sold
1259	40	1728	1220.00	Sold
1260	40	1729	1220.00	Sold
1261	40	1730	1220.00	Sold
1262	40	1731	1220.00	Sold
1263	40	1732	1220.00	Sold
1264	40	1733	1220.00	Sold
1265	40	1734	1220.00	Sold
1266	40	1735	1220.00	Sold
1267	40	1736	1220.00	Sold
1268	40	1737	1220.00	Sold
1269	40	1738	1220.00	Sold
1270	40	1739	1220.00	Sold
1271	40	1740	1220.00	Sold
1272	40	1741	1220.00	Sold
1273	40	1742	1220.00	Sold
1274	40	1743	1220.00	Sold
1275	40	1744	1220.00	Sold
1276	40	1745	1220.00	Sold
1277	40	1746	1220.00	Sold
1278	40	1747	1220.00	Sold
1279	40	1748	1220.00	Sold
1280	40	1749	1220.00	Sold
1281	40	1750	1220.00	Sold
1282	40	1751	1220.00	Sold
1283	40	1752	1220.00	Sold
1284	40	1753	1220.00	Sold
1285	40	1754	1220.00	Sold
1286	40	1755	1220.00	Sold
1287	40	1756	1220.00	Sold
1288	40	1757	1220.00	Sold
1289	40	1758	1220.00	Sold
1290	40	1759	1220.00	Sold
1291	40	1760	1220.00	Sold
1292	40	1761	1220.00	Sold
1293	41	2494	2850.00	Sold
1294	41	2462	2850.00	Sold
1295	41	2465	2850.00	Sold
1296	42	2471	3430.00	Sold
1297	42	2472	3430.00	Sold
1298	42	2503	3430.00	Sold
1299	43	2474	3390.00	Sold
1300	44	2492	2080.00	Sold
1301	44	2490	2080.00	Sold
1302	44	2493	2080.00	Sold
1303	44	2491	2080.00	Sold
1304	44	2457	2080.00	Sold
1305	44	2458	2080.00	Sold
1319	50	2294	3975.00	Sold
1320	50	2293	3975.00	Sold
1344	56	2475	3430.00	Sold
1345	56	2476	3430.00	Sold
1346	56	2473	3430.00	Sold
1347	57	2497	2850.00	Sold
1348	57	2498	2850.00	Sold
1349	57	2499	2850.00	Sold
1350	57	2500	2850.00	Sold
1351	58	2468	2830.00	Sold
1352	58	2469	2830.00	Sold
1355	60	557	1400.00	Sold
1356	60	575	1400.00	Sold
1357	60	566	1400.00	Sold
1360	63	2566	1700.00	Sold
1361	63	2563	1700.00	Sold
1362	63	2562	1700.00	Sold
1363	63	2561	1700.00	Sold
1364	63	2549	1700.00	Sold
1365	63	2551	1700.00	Sold
1366	63	2565	1700.00	Sold
1367	63	2556	1700.00	Sold
1368	63	2567	1700.00	Sold
1369	63	2553	1700.00	Sold
1370	63	2557	1700.00	Sold
1371	63	2559	1700.00	Sold
1372	63	2547	1700.00	Sold
1373	63	2550	1700.00	Sold
1374	63	2560	1700.00	Sold
1375	64	571	1400.00	Sold
1376	64	562	1400.00	Sold
1377	65	2505	3430.00	Sold
1378	65	2508	3430.00	Sold
1379	66	1762	1250.00	Sold
1380	66	1763	1250.00	Sold
1381	66	1764	1250.00	Sold
1382	66	1765	1250.00	Sold
1383	66	1766	1250.00	Sold
1384	66	1767	1250.00	Sold
1385	67	572	1400.00	Sold
1386	67	552	1400.00	Sold
1387	67	573	1400.00	Sold
1393	71	1652	1208.00	Sold
1394	71	1653	1208.00	Sold
1395	71	1654	1208.00	Sold
1396	71	1655	1208.00	Sold
1397	71	1656	1208.00	Sold
1398	71	1657	1208.00	Sold
1399	71	1658	1208.00	Sold
1400	71	1659	1208.00	Sold
1401	71	1660	1208.00	Sold
1402	71	1661	1208.00	Sold
1403	71	1637	1208.00	Sold
1404	71	1638	1208.00	Sold
1405	71	1639	1208.00	Sold
1406	71	1640	1208.00	Sold
1407	71	1641	1208.00	Sold
1408	71	1642	1208.00	Sold
1409	71	1643	1208.00	Sold
1410	71	1644	1208.00	Sold
1411	71	1645	1208.00	Sold
1412	71	1646	1208.00	Sold
1413	71	1647	1208.00	Sold
1414	71	1648	1208.00	Sold
1415	71	1649	1208.00	Sold
1416	71	1650	1208.00	Sold
1417	71	1651	1208.00	Sold
1418	72	2548	1740.00	Sold
1419	73	2354	1722.00	Sold
1421	75	2377	2355.00	Sold
1422	76	2378	2595.00	Sold
1423	77	2381	3937.00	Sold
1425	79	2355	1722.00	Sold
1426	80	2356	1950.00	Sold
1427	81	2384	1659.00	Sold
1428	82	2380	1443.00	Sold
1429	83	2386	1494.00	Sold
1435	86	2655	3430.00	Sold
1436	86	2647	3430.00	Sold
1437	86	2646	3430.00	Sold
1438	86	2648	3430.00	Sold
1439	86	2650	3430.00	Sold
1440	86	2653	3430.00	Sold
1441	87	2638	3520.00	Sold
1442	87	2631	3520.00	Sold
1443	87	2633	3520.00	Sold
1444	87	2658	3520.00	Sold
1445	87	2632	3520.00	Sold
1446	88	2637	3470.00	Sold
1447	88	2628	3470.00	Sold
1448	88	2636	3470.00	Sold
1450	90	670	3490.00	Sold
1451	90	685	3490.00	Sold
1452	90	678	3490.00	Sold
1453	90	679	3490.00	Sold
1454	90	673	3490.00	Sold
1455	90	672	3490.00	Sold
1456	90	671	3490.00	Sold
1457	90	674	3490.00	Sold
1458	91	2649	3750.00	Sold
1459	92	554	1400.00	Sold
1460	92	565	1400.00	Sold
1461	93	2644	3365.00	Sold
1462	93	2641	3365.00	Sold
1463	93	2657	3365.00	Sold
1464	93	2645	3365.00	Sold
1465	93	2642	3365.00	Sold
1466	93	2651	3365.00	Sold
1467	94	2502	3180.00	Sold
1468	94	2470	3180.00	Sold
1469	95	2501	3130.00	Sold
1358	61	2098	1.00	Returned
1359	62	2304	1.00	Returned
1472	97	2652	3430.00	Sold
1473	97	2643	3430.00	Sold
1474	97	2654	3430.00	Sold
1475	97	2656	3430.00	Sold
1476	97	2639	3430.00	Sold
1477	97	2640	3430.00	Sold
1478	98	2635	3520.00	Sold
1479	98	2629	3520.00	Sold
1480	98	2630	3520.00	Sold
1481	99	2246	245.00	Sold
1482	100	555	1400.00	Sold
1483	100	567	1400.00	Sold
1484	100	553	1400.00	Sold
1485	100	576	1400.00	Sold
1486	100	551	1400.00	Sold
1487	101	537	2850.00	Sold
1488	101	538	2850.00	Sold
1489	102	535	2550.00	Sold
1495	104	2486	1905.00	Sold
1496	104	2487	1905.00	Sold
1497	104	2488	1905.00	Sold
1498	105	1768	1250.00	Sold
1499	105	1769	1250.00	Sold
1500	105	1770	1250.00	Sold
1501	105	1771	1250.00	Sold
1515	114	502	8200.00	Sold
1516	114	501	8200.00	Sold
1517	115	563	1400.00	Sold
1518	115	564	1400.00	Sold
1519	116	539	2850.00	Sold
1520	118	2298	2950.00	Sold
1522	120	2382	3519.00	Sold
1523	121	2121	1747.00	Sold
1524	122	2732	10200.00	Sold
1526	124	1772	1225.00	Sold
1527	124	1773	1225.00	Sold
1528	124	1774	1225.00	Sold
1529	124	1775	1225.00	Sold
1530	125	2245	900.00	Sold
1531	126	2772	3800.00	Sold
1532	126	2771	3800.00	Sold
1533	127	2782	3200.00	Sold
1534	128	487	3400.00	Sold
1535	128	491	3400.00	Sold
1536	128	493	3400.00	Sold
1537	129	2789	1950.00	Sold
1538	129	2790	1950.00	Sold
1576	131	2167	650.00	Sold
1577	131	2168	650.00	Sold
1578	132	2666	540.00	Sold
1579	132	2667	540.00	Sold
1580	132	2668	540.00	Sold
1581	132	2669	540.00	Sold
1582	132	2670	540.00	Sold
1583	132	2671	540.00	Sold
1584	132	2672	540.00	Sold
1585	132	2673	540.00	Sold
1630	141	2774	3220.00	Sold
1631	141	2776	3220.00	Sold
1632	141	2773	3220.00	Sold
1633	141	2775	3220.00	Sold
1634	142	2767	3580.00	Sold
1635	142	2769	3580.00	Sold
1636	142	2768	3580.00	Sold
1637	142	2770	3580.00	Sold
1638	143	2779	2860.00	Sold
1639	144	2780	2810.00	Sold
1640	145	2781	2950.00	Sold
1641	146	2777	2900.00	Sold
1642	146	2778	2900.00	Sold
1643	147	2552	1720.00	Sold
1644	147	2564	1720.00	Sold
1645	147	2554	1720.00	Sold
1706	149	547	2700.00	Sold
1707	150	574	1400.00	Sold
1708	150	556	1400.00	Sold
1709	150	561	1400.00	Sold
1710	151	2893	3800.00	Sold
1711	151	2897	3800.00	Sold
1712	151	2896	3800.00	Sold
1713	151	2906	3800.00	Sold
1714	151	2909	3800.00	Sold
1715	151	2907	3800.00	Sold
1716	151	2903	3800.00	Sold
1717	151	2901	3800.00	Sold
1718	151	2899	3800.00	Sold
1719	151	2894	3800.00	Sold
1720	151	2900	3800.00	Sold
1721	151	2892	3800.00	Sold
1722	151	2908	3800.00	Sold
1723	151	2905	3800.00	Sold
1724	151	2904	3800.00	Sold
1725	151	2902	3800.00	Sold
1726	152	2935	3220.00	Sold
1727	152	2928	3220.00	Sold
1728	152	2934	3220.00	Sold
1729	152	2933	3220.00	Sold
1730	152	2926	3220.00	Sold
1731	152	2937	3220.00	Sold
1732	153	2930	3170.00	Sold
1733	153	2929	3170.00	Sold
1734	153	2932	3170.00	Sold
1735	153	2927	3170.00	Sold
1736	153	2931	3170.00	Sold
1737	153	2936	3170.00	Sold
1738	154	2891	3800.00	Sold
1739	154	2898	3800.00	Sold
1740	154	2895	3800.00	Sold
1741	155	2292	5650.00	Sold
1742	156	2915	3450.00	Sold
1743	157	2913	3400.00	Sold
1744	157	2920	3400.00	Sold
1745	157	2922	3400.00	Sold
1746	158	2910	3550.00	Sold
1747	159	2942	2860.00	Sold
1748	160	2921	3450.00	Sold
1749	160	2912	3450.00	Sold
1750	160	2924	3450.00	Sold
1751	161	2917	3400.00	Sold
1752	161	2916	3400.00	Sold
1753	161	2918	3400.00	Sold
1754	162	2923	3400.00	Sold
1755	162	2911	3400.00	Sold
1757	164	2784	2470.00	Sold
1758	164	2961	2470.00	Sold
1759	164	2962	2470.00	Sold
1760	164	2963	2470.00	Sold
1761	165	2786	2820.00	Sold
1762	165	2785	2820.00	Sold
1763	166	2964	2470.00	Sold
1764	166	2787	2470.00	Sold
1765	166	2965	2470.00	Sold
1766	166	2788	2470.00	Sold
1767	167	2783	1420.00	Sold
1768	168	1836	1225.00	Sold
1769	168	1837	1225.00	Sold
1770	168	1838	1225.00	Sold
1771	168	1839	1225.00	Sold
1772	168	1840	1225.00	Sold
1773	168	1841	1225.00	Sold
1774	168	1842	1225.00	Sold
1775	168	1843	1225.00	Sold
1776	168	1844	1225.00	Sold
1777	168	1845	1225.00	Sold
1778	169	1776	1222.00	Sold
1779	169	1777	1222.00	Sold
1780	169	1778	1222.00	Sold
1781	169	1779	1222.00	Sold
1782	169	1780	1222.00	Sold
1783	169	1781	1222.00	Sold
1784	169	1782	1222.00	Sold
1785	169	1783	1222.00	Sold
1786	169	1784	1222.00	Sold
1787	169	1785	1222.00	Sold
1788	169	1786	1222.00	Sold
1789	169	1787	1222.00	Sold
1790	169	1788	1222.00	Sold
1791	169	1789	1222.00	Sold
1792	169	1790	1222.00	Sold
1793	169	1791	1222.00	Sold
1794	169	1792	1222.00	Sold
1795	169	1793	1222.00	Sold
1796	169	1794	1222.00	Sold
1797	169	1795	1222.00	Sold
1798	169	1796	1222.00	Sold
1799	169	1797	1222.00	Sold
1800	169	1798	1222.00	Sold
1801	169	1799	1222.00	Sold
1802	169	1800	1222.00	Sold
1803	169	1801	1222.00	Sold
1804	169	1802	1222.00	Sold
1805	169	1803	1222.00	Sold
1806	169	1804	1222.00	Sold
1807	169	1805	1222.00	Sold
1808	169	1806	1222.00	Sold
1809	169	1807	1222.00	Sold
1810	169	1808	1222.00	Sold
1811	169	1809	1222.00	Sold
1812	169	1810	1222.00	Sold
1813	169	1811	1222.00	Sold
1814	169	1812	1222.00	Sold
1815	169	1813	1222.00	Sold
1816	169	1814	1222.00	Sold
1817	169	1815	1222.00	Sold
1818	169	1816	1222.00	Sold
1819	169	1817	1222.00	Sold
1820	169	1818	1222.00	Sold
1821	169	1819	1222.00	Sold
1822	169	1820	1222.00	Sold
1823	169	1821	1222.00	Sold
1824	169	1822	1222.00	Sold
1825	169	1823	1222.00	Sold
1826	169	1824	1222.00	Sold
1827	169	1825	1222.00	Sold
1828	169	1826	1222.00	Sold
1829	169	1827	1222.00	Sold
1830	169	1828	1222.00	Sold
1831	169	1829	1222.00	Sold
1832	169	1830	1222.00	Sold
1833	169	1831	1222.00	Sold
1834	169	1832	1222.00	Sold
1835	169	1833	1222.00	Sold
1836	169	1834	1222.00	Sold
1837	169	1835	1222.00	Sold
1838	170	2626	1.00	Sold
1839	170	2627	1.00	Sold
1840	170	2523	1.00	Sold
1841	171	2622	202.00	Sold
1842	171	2623	202.00	Sold
1843	171	2624	202.00	Sold
1844	171	2625	202.00	Sold
1845	171	2199	202.00	Sold
1846	171	2200	202.00	Sold
1847	171	2201	202.00	Sold
1848	171	2202	202.00	Sold
1849	171	2203	202.00	Sold
1850	171	2204	202.00	Sold
1851	171	2205	202.00	Sold
1852	172	2195	202.00	Sold
1853	172	2196	202.00	Sold
1854	172	2197	202.00	Sold
1855	172	2198	202.00	Sold
1856	173	2193	193.00	Sold
1857	173	2194	193.00	Sold
1858	174	2187	193.00	Sold
1859	174	2188	193.00	Sold
1860	174	2189	193.00	Sold
1861	174	2190	193.00	Sold
1862	174	2191	193.00	Sold
1863	174	2192	193.00	Sold
1864	175	2181	202.00	Sold
1865	175	2182	202.00	Sold
1866	175	2183	202.00	Sold
1867	175	2184	202.00	Sold
1868	175	2185	202.00	Sold
1869	175	2186	202.00	Sold
1870	176	2177	193.00	Sold
1871	176	2178	193.00	Sold
1872	176	2179	193.00	Sold
1873	176	2180	193.00	Sold
1874	177	2175	193.00	Sold
1875	177	2176	193.00	Sold
1876	177	2169	193.00	Sold
1877	177	2170	193.00	Sold
1878	177	2171	193.00	Sold
1879	177	2172	193.00	Sold
1880	177	2173	193.00	Sold
1881	177	2174	193.00	Sold
1882	178	492	3450.00	Sold
1883	178	494	3450.00	Sold
1884	178	490	3450.00	Sold
1885	178	495	3450.00	Sold
1886	178	496	3450.00	Sold
1887	178	481	3450.00	Sold
1888	178	486	3450.00	Sold
1889	178	479	3450.00	Sold
1890	178	473	3450.00	Sold
1891	179	2739	4200.00	Sold
1892	180	2104	3400.00	Sold
1893	181	2030	4200.00	Sold
1894	181	2031	4200.00	Sold
1895	181	2032	4200.00	Sold
1896	182	3020	3540.00	Sold
1897	182	3021	3540.00	Sold
1898	182	2984	3540.00	Sold
1899	182	2985	3540.00	Sold
1900	183	2986	3240.00	Sold
1901	184	2103	5250.00	Sold
1902	185	3000	1050.00	Sold
1903	185	3001	1050.00	Sold
1904	185	3002	1050.00	Sold
1905	186	2700	850.00	Sold
1906	187	2477	760.00	Sold
1907	187	2131	760.00	Sold
1908	187	2130	760.00	Sold
1909	187	2478	760.00	Sold
1910	187	2701	760.00	Sold
1911	188	2455	2470.00	Sold
1912	188	2485	2470.00	Sold
1913	188	2484	2470.00	Sold
1914	188	2454	2470.00	Sold
1915	189	2480	2470.00	Sold
1916	189	2453	2470.00	Sold
1917	189	2481	2470.00	Sold
1918	189	2479	2470.00	Sold
1919	189	2448	2470.00	Sold
1920	189	2450	2470.00	Sold
1921	189	2452	2470.00	Sold
1922	189	2449	2470.00	Sold
1923	189	2451	2470.00	Sold
1924	189	2447	2470.00	Sold
1925	190	2482	2800.00	Sold
1926	190	2483	2800.00	Sold
1927	190	2722	2800.00	Sold
1928	191	3003	1020.00	Sold
1929	191	3004	1020.00	Sold
1930	191	3005	1020.00	Sold
1931	191	3006	1020.00	Sold
1932	191	3007	1020.00	Sold
1933	191	3008	1020.00	Sold
1934	191	3009	1020.00	Sold
1935	191	3010	1020.00	Sold
1936	191	3011	1020.00	Sold
1937	191	3012	1020.00	Sold
1938	191	3013	1020.00	Sold
1939	191	3015	1020.00	Sold
1940	191	3016	1020.00	Sold
1941	191	3017	1020.00	Sold
1942	191	3018	1020.00	Sold
1943	191	3019	1020.00	Sold
1944	191	3014	1020.00	Sold
1945	192	2987	2930.00	Sold
1946	193	2681	1340.00	Sold
1947	193	2682	1340.00	Sold
1948	194	2991	2470.00	Sold
1949	194	2992	2470.00	Sold
1950	194	2993	2470.00	Sold
1951	194	2994	2470.00	Sold
1952	195	2995	2460.00	Sold
1953	196	2996	2470.00	Sold
1954	196	2997	2470.00	Sold
1955	197	2123	1410.00	Sold
1956	197	2126	1410.00	Sold
1957	198	2946	1240.00	Sold
1958	199	2952	850.00	Sold
1959	199	2951	850.00	Sold
1960	199	2999	850.00	Sold
1961	200	2689	3360.00	Sold
1962	200	2690	3360.00	Sold
1963	200	2691	3360.00	Sold
1964	200	2692	3360.00	Sold
1965	200	2693	3360.00	Sold
1967	202	2734	2350.00	Sold
1968	203	2736	2650.00	Sold
1969	204	2735	2300.00	Sold
1970	205	2737	2100.00	Sold
1971	206	2740	2080.00	Sold
1972	207	2102	5050.00	Sold
1973	208	2105	2070.00	Sold
1974	208	2106	2070.00	Sold
1975	208	2107	2070.00	Sold
1976	208	2108	2070.00	Sold
1977	208	2109	2070.00	Sold
1978	208	2110	2070.00	Sold
1979	209	2721	6200.00	Sold
1980	210	2504	3430.00	Sold
1981	210	2507	3430.00	Sold
1982	210	2506	3430.00	Sold
1983	211	2467	2820.00	Sold
1984	212	2459	2640.00	Sold
1985	213	2464	2850.00	Sold
1986	213	2466	2850.00	Sold
1987	213	2463	2850.00	Sold
1988	213	2461	2850.00	Sold
1989	213	2495	2850.00	Sold
1990	213	2496	2850.00	Sold
1991	213	2460	2850.00	Sold
1992	214	2694	3800.00	Sold
1993	215	2733	10350.00	Sold
1994	216	2977	780.00	Sold
1995	216	2978	780.00	Sold
1996	216	2976	780.00	Sold
1997	216	2975	780.00	Sold
1999	218	2291	3950.00	Sold
2001	220	1963	250.00	Sold
2003	222	548	2600.00	Sold
2004	223	2659	2000.00	Sold
2005	223	2660	2000.00	Sold
2006	223	2661	2000.00	Sold
2007	223	2662	2000.00	Sold
2008	223	2663	2000.00	Sold
2009	223	2664	2000.00	Sold
2010	224	2665	1800.00	Sold
2011	226	477	3450.00	Sold
2012	226	472	3450.00	Sold
2013	226	474	3450.00	Sold
2014	226	470	3450.00	Sold
2015	227	482	3450.00	Sold
2016	227	475	3450.00	Sold
2017	228	577	1400.00	Sold
2018	228	570	1400.00	Sold
2019	229	3048	3260.00	Sold
2020	230	3049	3300.00	Sold
2032	233	3034	3540.00	Sold
2033	233	3028	3540.00	Sold
2034	233	3030	3540.00	Sold
2035	233	3036	3540.00	Sold
2036	233	3037	3540.00	Sold
2037	234	2989	2150.00	Sold
2038	234	2990	2150.00	Sold
2039	234	2988	2150.00	Sold
2040	235	2149	1610.00	Sold
2041	236	2890	4400.00	Sold
2042	237	3092	1600.00	Sold
2054	240	3055	3670.00	Sold
2055	240	3056	3670.00	Sold
2056	240	3052	3670.00	Sold
2057	241	3032	3540.00	Sold
2058	241	3026	3540.00	Sold
2059	241	3025	3540.00	Sold
2060	241	3027	3540.00	Sold
2061	241	3035	3540.00	Sold
2062	241	3033	3540.00	Sold
2063	241	3043	3540.00	Sold
2064	241	3031	3540.00	Sold
2065	242	3071	2150.00	Sold
2066	242	3073	2150.00	Sold
2067	242	3074	2150.00	Sold
2068	243	3070	2130.00	Sold
2069	243	3072	2130.00	Sold
2070	244	3042	3900.00	Sold
2071	244	3051	3900.00	Sold
2072	245	3054	3800.00	Sold
2073	246	2295	3700.00	Sold
2074	247	569	1450.00	Sold
2079	249	3039	3450.00	Sold
2080	250	2944	3100.00	Sold
2081	251	1846	1245.00	Sold
2082	251	1847	1245.00	Sold
2083	251	1848	1245.00	Sold
2084	251	1849	1245.00	Sold
2085	251	1850	1245.00	Sold
2086	251	1851	1245.00	Sold
2087	251	1852	1245.00	Sold
2088	251	1853	1245.00	Sold
2089	252	485	3450.00	Sold
2090	252	480	3450.00	Sold
2091	252	476	3450.00	Sold
2092	252	484	3450.00	Sold
2093	253	1854	1245.00	Sold
2094	253	1855	1245.00	Sold
2095	253	1856	1245.00	Sold
2096	253	1857	1245.00	Sold
2097	253	1858	1245.00	Sold
2098	253	1859	1245.00	Sold
2099	253	1860	1245.00	Sold
2100	253	1861	1245.00	Sold
2101	253	1862	1245.00	Sold
2102	253	1863	1245.00	Sold
2103	253	1864	1245.00	Sold
2104	253	1865	1245.00	Sold
2105	253	1866	1245.00	Sold
2106	253	1867	1245.00	Sold
2107	253	1868	1245.00	Sold
2108	253	1869	1245.00	Sold
2109	253	1870	1245.00	Sold
2110	253	1871	1245.00	Sold
2111	253	1872	1245.00	Sold
2112	253	1873	1245.00	Sold
2113	253	1874	1245.00	Sold
2114	253	1875	1245.00	Sold
2115	253	1876	1245.00	Sold
2116	253	1877	1245.00	Sold
2117	253	1878	1245.00	Sold
2118	253	1879	1245.00	Sold
2119	253	1880	1245.00	Sold
2120	253	1881	1245.00	Sold
2121	253	1882	1245.00	Sold
2122	253	1883	1245.00	Sold
2123	254	1884	1245.00	Sold
2124	254	1885	1245.00	Sold
2125	254	1886	1245.00	Sold
2126	254	1887	1245.00	Sold
2127	254	1888	1245.00	Sold
2128	254	1889	1245.00	Sold
2129	254	1890	1245.00	Sold
2130	254	1891	1245.00	Sold
2131	254	1892	1245.00	Sold
2132	254	1893	1245.00	Sold
2133	254	1894	1245.00	Sold
2134	254	1895	1245.00	Sold
2135	254	1896	1245.00	Sold
2136	254	1897	1245.00	Sold
2137	254	1898	1245.00	Sold
2138	255	2925	3400.00	Sold
2139	256	3746	1310.00	Sold
2140	256	3756	1310.00	Sold
2141	256	3759	1310.00	Sold
2142	256	3752	1310.00	Sold
2143	256	3753	1310.00	Sold
2144	256	3744	1310.00	Sold
2145	256	3748	1310.00	Sold
2146	256	3749	1310.00	Sold
2147	256	3762	1310.00	Sold
2148	256	3747	1310.00	Sold
2149	256	3751	1310.00	Sold
2150	256	3743	1310.00	Sold
2151	256	3745	1310.00	Sold
2152	256	3735	1310.00	Sold
2153	256	3760	1310.00	Sold
2154	256	3750	1310.00	Sold
2155	256	3763	1310.00	Sold
2156	256	3764	1310.00	Sold
2157	256	3737	1310.00	Sold
2158	256	3754	1310.00	Sold
2159	256	3736	1310.00	Sold
2160	256	3738	1310.00	Sold
2161	256	3768	1310.00	Sold
2162	256	3765	1310.00	Sold
2163	256	3732	1310.00	Sold
2164	256	3767	1310.00	Sold
2165	256	3755	1310.00	Sold
2166	256	3766	1310.00	Sold
2167	256	3734	1310.00	Sold
2168	256	3742	1310.00	Sold
2169	256	3739	1310.00	Sold
2170	256	3758	1310.00	Sold
2171	256	3730	1310.00	Sold
2172	256	3733	1310.00	Sold
2173	256	3731	1310.00	Sold
2174	256	3741	1310.00	Sold
2175	256	3740	1310.00	Sold
2176	257	3761	1315.00	Sold
2177	257	3757	1315.00	Sold
2181	259	2152	1600.00	Sold
2182	259	2151	1600.00	Sold
2183	259	2150	1600.00	Sold
2184	259	3947	1600.00	Sold
2186	261	3029	4400.00	Sold
2187	261	3044	4400.00	Sold
2188	261	3038	4400.00	Sold
2189	262	3041	4500.00	Sold
2190	262	3040	4500.00	Sold
2191	263	3045	5000.00	Sold
2192	264	2943	4900.00	Sold
2193	265	3046	6700.00	Sold
2194	266	2889	4500.00	Sold
2195	266	3053	4500.00	Sold
2196	266	3050	4500.00	Sold
2197	267	3047	4350.00	Sold
2198	268	3057	4400.00	Sold
2199	269	3058	4050.00	Sold
2200	269	98	4050.00	Sold
2201	269	3061	4050.00	Sold
2202	269	3066	4050.00	Sold
2203	269	2938	4050.00	Sold
2204	269	3065	4050.00	Sold
2205	269	2939	4050.00	Sold
2206	269	3067	4050.00	Sold
2207	269	2940	4050.00	Sold
2208	269	2941	4050.00	Sold
2209	270	3062	3850.00	Sold
2210	270	3068	3850.00	Sold
2211	270	3069	3850.00	Sold
2212	271	3059	4450.00	Sold
2213	271	3060	4450.00	Sold
2214	272	3064	4600.00	Sold
2215	273	3063	4500.00	Sold
2216	274	2949	2900.00	Sold
2217	275	2947	2950.00	Sold
2218	275	2948	2950.00	Sold
2219	275	3075	2950.00	Sold
2220	276	2240	760.00	Sold
2221	276	2242	760.00	Sold
2222	276	2241	760.00	Sold
2223	276	2674	760.00	Sold
2224	276	2677	760.00	Sold
2225	276	2675	760.00	Sold
2226	276	2676	760.00	Sold
2227	276	2243	760.00	Sold
2228	277	2678	460.00	Sold
2229	277	2679	460.00	Sold
2230	277	2680	460.00	Sold
2231	277	2244	460.00	Sold
2232	278	2720	6700.00	Sold
2233	279	2738	1500.00	Sold
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
5604	68	356605220228296	OUT	SalesInvoice	132	2026-01-22 12:56:50.211883	1
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
5605	3	S01V558019CN10258177	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5606	3	S01F55701RRC10260424	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5607	3	S01V558019CN10255412	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5608	3	S01F55701RRC10252871	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5609	3	S01F55701RRC10253380	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5610	3	S01F55701RRC10260047	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5611	3	S01V558019CN10258939	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5612	3	S01F55801RRC10263365	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
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
5613	3	S01F55701RRC10259204	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5614	3	S01F55701RRC10252786	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5615	3	S01F55701RRC10252873	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5616	3	S01F55701RRC10252785	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5617	3	S01F55701RRC10252801	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5618	3	S01F55701RRC10253418	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5619	3	S01F55801RRC10263353	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5620	3	S01V558019CN10256717	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5621	3	S01F55701RRC10252722	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5622	3	S01F55701RRC10252874	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5623	3	S01F55801RRC10263356	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5624	3	S01F55801RRC10263364	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5625	3	S01F55701RRC10253425	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5626	3	S01F55701RRC10252869	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5627	3	S01F55901RRC10282523	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5628	3	S01F55801RRC10263355	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5629	3	S01F55901RRC10287502	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5630	3	S01F55701RRC10252798	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5631	3	S01F55901RRC10290683	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5632	3	S01V558019CN10250136	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5633	3	S01F55901RRC10290623	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5634	3	S01F55801RRC10263357	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5635	3	S01F55701RRC10252721	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5636	3	S01F55701RRC10253396	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5637	3	S01F55801RRC10263351	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5638	3	S01F55901RRC10303746	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5639	3	S01V558019CN10256466	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5640	3	S01F55701RRC10252797	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5641	3	S01F55701RRC10253379	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5642	3	S01F55901RRC10304141	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5643	3	S01F55901RRC10289942	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5644	3	S01E456016ER10403419	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5645	3	S01E55901J5310256430	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5646	3	S01E55901J5310261191	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5647	3	S01E55901J5310258792	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5648	3	S01E55901J5310251068	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5649	3	S01E55A01J5310266654	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5650	3	S01E55A01J5310266678	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5651	3	S01E55901J5310257073	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5652	3	S01E55901J5310261178	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5653	3	S01E55901J5310258774	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5654	3	S01E55901J5310261158	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5655	3	S01E55901J5310258822	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5656	3	S01E55901J5310261157	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5657	3	S01E55A01J5310266653	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5658	3	S01E55901J5310257080	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5659	3	S01E55901J5310251070	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5660	3	S01E55901J5310257041	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5661	3	S01E55901J5310258777	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5662	3	S01E55A01J5310266651	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5663	3	S01E55901J5310257042	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5664	3	S01E55A01J5310266698	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5665	3	S01E55A01J5310266640	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5666	3	S01E55901J5310258737	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5667	3	S01E55A01J5310266652	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5668	3	S01E55901J5310261152	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5669	3	S01E55A01J5310261220	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
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
2517	1	starlinkv40451	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2518	1	starlinkv40452	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2519	1	starlinkv40453	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2520	1	starlinkv40454	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2521	1	starlinkv40455	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2522	1	starlinkv40456	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2523	1	starlinkv40457	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2524	1	starlinkv40458	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2525	3	ps5slimdigital00178	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2526	3	ps5slimdigital00179	IN	PurchaseInvoice	80	2026-01-08 14:11:03.685037	1
2527	2	ps5slim00126	IN	PurchaseInvoice	81	2026-01-08 14:15:14.649235	1
2528	1	starlinkv40459	IN	PurchaseInvoice	81	2026-01-08 14:15:14.649235	1
2529	1	starlinkv40460	IN	PurchaseInvoice	81	2026-01-08 14:15:14.649235	1
2530	1	starlinkv40461	IN	PurchaseInvoice	81	2026-01-08 14:15:14.649235	1
2531	131	1581F8LQC259V0025QND	OUT	SalesInvoice	1	2026-01-08 15:48:18.704672	1
2532	131	1581F8LQC255Q0022GVN	OUT	SalesInvoice	1	2026-01-08 15:48:18.704672	1
2533	17	]C121105082001941	OUT	SalesInvoice	2	2026-01-08 15:48:18.715356	1
2534	17	]C121105082001938	OUT	SalesInvoice	2	2026-01-08 15:48:18.715356	1
2535	12	1581F8PJC24CR0022MDB	OUT	SalesInvoice	3	2026-01-08 15:48:18.718899	1
2536	12	1581F8PJC24B6001BKLQ	OUT	SalesInvoice	3	2026-01-08 15:48:18.718899	1
2537	67	352355706850411	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2538	67	352355704532573	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2539	67	352355700973722	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2540	67	352355701807754	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2541	67	352355709742698	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2542	66	358112930502035	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2543	66	358112931678883	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2544	66	358112932166375	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2545	88	352066342213241	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2546	63	356196182587945	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2547	63	356196183103940	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2548	63	355205568606640	OUT	SalesInvoice	4	2026-01-08 15:48:18.721873	1
2549	8	1581F8LQC252U00200ND	OUT	SalesInvoice	5	2026-01-08 15:52:58.528036	1
2550	75	352602317458153	OUT	SalesInvoice	6	2026-01-08 16:09:26.178065	1
2551	75	354512323488342	OUT	SalesInvoice	6	2026-01-08 16:09:26.178065	1
2552	75	352758404050616	OUT	SalesInvoice	6	2026-01-08 16:09:26.178065	1
2553	75	358936958142898	OUT	SalesInvoice	6	2026-01-08 16:09:26.178065	1
2554	75	352368545956687	OUT	SalesInvoice	6	2026-01-08 16:09:26.178065	1
2555	17	]C121105082000101	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2556	17	]C121105082000418	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2557	17	]C121105082000110	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2558	17	]C121105082000416	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2559	17	]C121105082000294	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2560	17	]C121105082000362	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2561	17	]C121105082000048	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2562	17	]C121105082000010	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2563	17	]C121105082000046	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2564	17	]C121095082000754	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2565	17	]C121105082000001	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2566	17	]C121105082000415	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2567	17	]C121105082000044	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2568	17	]C121105082000006	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2569	17	]C121105082000007	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2570	17	]C121105082000042	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2571	17	]C121105082000009	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2572	17	]C121105082000049	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2573	17	]C121105082000411	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2574	17	]C121105082000414	OUT	SalesInvoice	7	2026-01-08 16:18:27.095922	1
2575	17	]C121105082000106	OUT	SalesInvoice	8	2026-01-09 13:30:53.533113	1
2576	17	]C121105082000293	OUT	SalesInvoice	8	2026-01-09 13:30:53.533113	1
2577	7	1581F986C258U0023MZ5	OUT	SalesInvoice	9	2026-01-09 13:34:12.373214	1
2578	12	1581F8PJC24CR0022JYA	OUT	SalesInvoice	9	2026-01-09 13:34:12.373214	1
3645	1	starlinkv40101	OUT	SalesInvoice	19	2026-01-09 14:46:41.773201	1
3646	1	starlinkv40102	OUT	SalesInvoice	19	2026-01-09 14:46:41.773201	1
3647	1	starlinkv40103	OUT	SalesInvoice	19	2026-01-09 14:46:41.773201	1
3648	1	starlinkv40104	OUT	SalesInvoice	19	2026-01-09 14:46:41.773201	1
3826	68	358051322163339	OUT	SalesInvoice	29	2026-01-09 15:34:38.570262	1
3827	68	350889865420378	OUT	SalesInvoice	29	2026-01-09 15:34:38.570262	1
3828	68	357586344726028	OUT	SalesInvoice	29	2026-01-09 15:34:38.570262	1
3829	68	356188163778437	OUT	SalesInvoice	29	2026-01-09 15:34:38.570262	1
3885	12	1581F8PJC24CS0022S3P	OUT	SalesInvoice	36	2026-01-09 16:00:18.559281	1
3886	12	1581F8PJC24BP00212CD	OUT	SalesInvoice	36	2026-01-09 16:00:18.559281	1
3887	12	1581F8PJC24CR0022MKF	OUT	SalesInvoice	36	2026-01-09 16:00:18.559281	1
3952	12	1581F8PJC253V001H1V5	OUT	SalesInvoice	39	2026-01-09 16:33:35.995383	1
3953	12	1581F8PJC24B6001BKXK	OUT	SalesInvoice	39	2026-01-09 16:33:35.995383	1
3990	1	starlinkv40145	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3991	1	starlinkv40146	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3992	1	starlinkv40147	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3993	1	starlinkv40148	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3994	1	starlinkv40149	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
4000	75	356764170580642	OUT	SalesInvoice	47	2026-01-10 14:22:43.957872	1
4005	138	351399081079239	OUT	SalesInvoice	51	2026-01-10 14:48:58.281093	1
4064	4	dualsensewirelesscontroller00038	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4065	4	dualsensewirelesscontroller00039	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4066	4	dualsensewirelesscontroller00040	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4067	4	dualsensewirelesscontroller00041	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4068	4	dualsensewirelesscontroller00042	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4069	4	dualsensewirelesscontroller00043	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4070	68	352791394722647	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4071	68	353263425811954	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4072	68	357586346058651	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4073	68	359802898116179	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4074	68	359614541233842	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4075	68	356605223669785	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4076	68	357063607465264	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4077	68	359614542086678	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4078	68	359614542002816	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4079	68	350889867176291	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4080	68	350889865663902	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4081	68	353263424083571	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4082	68	352791396686626	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4083	68	356188160423706	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4084	68	356188160049063	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4085	68	353263427359440	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4086	68	358051326224004	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
3649	1	starlinkv40105	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3650	1	starlinkv40106	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3651	1	starlinkv40107	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3652	1	starlinkv40108	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3653	1	starlinkv40109	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3654	1	starlinkv40110	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3655	1	starlinkv40111	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3656	1	starlinkv40112	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3657	1	starlinkv40113	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3658	1	starlinkv40114	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3659	1	starlinkv40115	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3660	1	starlinkv40116	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3661	1	starlinkv40117	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3662	1	starlinkv40118	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3663	1	starlinkv40119	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3664	1	starlinkv40120	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3665	1	starlinkv40121	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3666	1	starlinkv40122	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3667	1	starlinkv40123	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3668	1	starlinkv40124	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3669	1	starlinkv40125	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3670	1	starlinkv40126	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3671	1	starlinkv40127	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3672	1	starlinkv40128	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3673	1	starlinkv40129	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3674	1	starlinkv40130	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3675	1	starlinkv40131	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3676	1	starlinkv40132	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3677	1	starlinkv40133	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
3678	1	starlinkv40134	OUT	SalesInvoice	20	2026-01-09 14:50:58.199463	1
5670	3	S01E55901J5310257074	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5671	3	S01E55901J5310261192	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5672	3	S01E55901J5310258738	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5673	3	S01E55901J5310258802	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5674	3	S01E55901J5310258823	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5675	3	S01E55901J5310258779	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5676	3	S01E55A01J5310266681	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5677	3	S01E55901J5310257093	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5678	3	S01E55901J5310258770	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5679	3	S01E55A01J5310261214	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5680	3	S01E55901J5310258821	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5681	3	S01E55901J5310261165	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5682	3	S01E55A01J5310266655	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5683	3	S01E55A01J5310266639	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5684	3	S01E55A01J5310266697	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5685	3	S01E55901J5310257035	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5686	3	S01E55A01J5310261219	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5687	3	S01E55A01J5310266661	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5688	3	S01E55901J5310251067	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5689	3	S01E55901J5310261166	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5690	3	S01E55901J5310258791	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5691	3	S01E55901J5310258814	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5692	3	S01E55901J5310257079	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3723	1	starlinkv40160	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3724	1	starlinkv40161	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3725	1	starlinkv40162	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3726	1	starlinkv40163	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3727	1	starlinkv40164	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3728	1	starlinkv40165	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3729	1	starlinkv40166	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3730	1	starlinkv40167	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3731	1	starlinkv40168	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3732	1	starlinkv40169	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3733	1	starlinkv40170	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3734	1	starlinkv40171	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3735	1	starlinkv40172	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3736	1	starlinkv40173	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3737	1	starlinkv40174	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3738	1	starlinkv40175	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3739	1	starlinkv40176	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3740	1	starlinkv40177	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3741	1	starlinkv40178	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3742	1	starlinkv40179	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3743	1	starlinkv40180	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3744	1	starlinkv40181	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3745	1	starlinkv40182	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3746	1	starlinkv40183	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3747	1	starlinkv40184	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3748	1	starlinkv40185	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3679	75	352368545993615	OUT	SalesInvoice	21	2026-01-09 14:54:11.863896	1
3680	75	352758404073113	OUT	SalesInvoice	21	2026-01-09 14:54:11.863896	1
3681	75	352758404284538	OUT	SalesInvoice	21	2026-01-09 14:54:11.863896	1
3682	75	352368546192654	OUT	SalesInvoice	21	2026-01-09 14:54:11.863896	1
3683	75	354512320603638	OUT	SalesInvoice	21	2026-01-09 14:54:11.863896	1
3684	75	354512324560990	OUT	SalesInvoice	21	2026-01-09 14:54:11.863896	1
3830	77	350795041218463	OUT	SalesInvoice	30	2026-01-09 15:36:10.394453	1
3831	77	350795040883309	OUT	SalesInvoice	30	2026-01-09 15:36:10.394453	1
3832	77	350795041085185	OUT	SalesInvoice	30	2026-01-09 15:36:10.394453	1
3833	77	357247591394057	OUT	SalesInvoice	30	2026-01-09 15:36:10.394453	1
3834	77	350795041545725	OUT	SalesInvoice	30	2026-01-09 15:36:10.394453	1
3835	77	357223745121191	OUT	SalesInvoice	30	2026-01-09 15:36:10.394453	1
3888	79	357205987236407	OUT	SalesInvoice	37	2026-01-09 16:05:11.019644	1
3889	79	357031376241620	OUT	SalesInvoice	37	2026-01-09 16:05:11.019644	1
3954	68	358051322474710	OUT	SalesInvoice	40	2026-01-09 16:34:47.338244	1
3955	68	358051321091101	OUT	SalesInvoice	40	2026-01-09 16:34:47.338244	1
3995	161	5WTZN8S002UDXU	OUT	SalesInvoice	43	2026-01-10 11:59:42.216685	1
5693	3	S01E55A01J5310261213	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
4006	104	SKVNHV9WJ4J	OUT	SalesInvoice	52	2026-01-10 14:57:28.165552	1
4087	68	357586344585994	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4088	68	353263426755861	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4089	68	359912586795810	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4090	68	356188162356185	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4091	68	358051321099997	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4092	68	350889862475052	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4093	68	350889862618701	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4094	68	357586344610396	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4095	68	359614546217410	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4096	68	352791397736289	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4097	68	353263427082901	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4098	68	356188161863918	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4099	68	358051321426497	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4100	68	356605222182244	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4101	68	356364246005268	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4102	68	356364246059356	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4103	68	356364245823588	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4104	68	356764176095702	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4105	68	357063606855754	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4106	68	356764176012640	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4107	70	354956977937882	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4108	162	dualsenseedgewirelesscontroller0001	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4109	162	dualsenseedgewirelesscontroller0002	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4110	162	dualsenseedgewirelesscontroller0003	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4111	162	dualsenseedgewirelesscontroller0004	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4112	162	dualsenseedgewirelesscontroller0005	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4113	162	dualsenseedgewirelesscontroller0006	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4114	162	dualsenseedgewirelesscontroller0007	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4115	162	dualsenseedgewirelesscontroller0008	IN	PurchaseInvoice	83	2026-01-12 13:54:11.503843	1
4131	17	]C121095082002349	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4132	17	]C121115082000636	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4133	17	]C121105082001944	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4134	17	]C121105082001942	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4135	17	]C121085082000927	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4136	17	]C121095082001792	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4137	17	]C121095082001773	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4138	17	]C121085082000922	OUT	SalesInvoice	56	2026-01-12 14:10:21.991543	1
4142	68	358051326224004	OUT	SalesInvoice	59	2026-01-12 14:18:07.199599	1
4143	68	356188160423706	OUT	SalesInvoice	59	2026-01-12 14:18:07.199599	1
4144	68	358051321426497	OUT	SalesInvoice	59	2026-01-12 14:18:07.199599	1
4145	68	357586344585994	OUT	SalesInvoice	59	2026-01-12 14:18:07.199599	1
4146	68	356188160049063	OUT	SalesInvoice	59	2026-01-12 14:18:07.199599	1
4147	68	350889862618701	OUT	SalesInvoice	59	2026-01-12 14:18:07.199599	1
4153	79	357205987236407	IN	SalesReturn	1	2026-01-12 14:26:09.848258	1
4154	79	357031376241620	IN	SalesReturn	1	2026-01-12 14:26:09.848258	1
4165	12	1581F8PJC24BN00210EG	OUT	SalesInvoice	63	2026-01-12 14:32:20.152304	1
4166	12	1581F8PJC24CQ0022HMQ	OUT	SalesInvoice	63	2026-01-12 14:32:20.152304	1
4167	12	1581F8PJC24BL0020SV0	OUT	SalesInvoice	63	2026-01-12 14:32:20.152304	1
4168	12	1581F8PJC24CR0022K1X	OUT	SalesInvoice	63	2026-01-12 14:32:20.152304	1
4169	12	1581F8PJC253V001GYLW	OUT	SalesInvoice	63	2026-01-12 14:32:20.152304	1
4172	9	1581F6Z9A24CRML3TKW1	OUT	SalesInvoice	65	2026-01-12 14:39:51.864026	1
4178	160	351878871049411	OUT	SalesInvoice	67	2026-01-12 15:55:26.074668	1
4179	160	351878871034231	OUT	SalesInvoice	67	2026-01-12 15:55:26.074668	1
4180	160	356930604129856	OUT	SalesInvoice	67	2026-01-12 15:55:26.074668	1
5694	3	ps5slimdigital00050	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3685	6	1581F9DEC258W0291F67	OUT	SalesInvoice	22	2026-01-09 14:56:48.674896	1
3686	6	1581F9DEC25AQ0297HQU	OUT	SalesInvoice	22	2026-01-09 14:56:48.674896	1
5695	3	ps5slimdigital00051	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5696	3	ps5slimdigital00052	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5697	3	ps5slimdigital00053	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5698	3	ps5slimdigital00054	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5699	3	ps5slimdigital00055	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5700	3	ps5slimdigital00056	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5701	3	ps5slimdigital00057	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5702	3	ps5slimdigital00058	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5703	3	ps5slimdigital00059	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5704	3	ps5slimdigital00060	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5705	3	ps5slimdigital00061	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5706	3	ps5slimdigital00062	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5707	3	ps5slimdigital00063	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3890	4	711719575894	IN	PurchaseInvoice	6	2026-01-09 16:11:42.26849	1
3956	1	starlinkv40260	OUT	SalesInvoice	41	2026-01-09 16:36:17.126877	1
3957	1	starlinkv40261	OUT	SalesInvoice	41	2026-01-09 16:36:17.126877	1
3958	1	starlinkv40262	OUT	SalesInvoice	41	2026-01-09 16:36:17.126877	1
3959	1	starlinkv40263	OUT	SalesInvoice	41	2026-01-09 16:36:17.126877	1
3960	1	starlinkv40264	OUT	SalesInvoice	41	2026-01-09 16:36:17.126877	1
3961	1	starlinkv40265	OUT	SalesInvoice	41	2026-01-09 16:36:17.126877	1
3996	103	359493733064400	OUT	SalesInvoice	44	2026-01-10 13:59:59.266664	1
4002	103	356422165489838	OUT	SalesInvoice	49	2026-01-10 14:32:21.611488	1
4007	68	359912587219711	OUT	SalesInvoice	53	2026-01-10 16:05:17.404368	1
4008	68	359614541610171	OUT	SalesInvoice	53	2026-01-10 16:05:17.404368	1
4009	68	359614540060931	OUT	SalesInvoice	53	2026-01-10 16:05:17.404368	1
4010	68	358051322533887	OUT	SalesInvoice	53	2026-01-10 16:05:17.404368	1
4011	68	353837419391642	OUT	SalesInvoice	53	2026-01-10 16:05:17.404368	1
4116	68	353263427082901	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4117	68	359912586795810	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4118	68	353263426755861	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4119	68	356188162356185	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4120	68	350889862475052	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4121	68	359614546217410	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4122	68	350889865663902	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4123	68	359802898116179	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4124	68	356605223669785	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4125	68	356605222182244	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4126	68	359614541233842	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4127	68	350889867176291	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4128	68	352791394722647	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4129	68	359614542002816	OUT	SalesInvoice	54	2026-01-12 14:04:43.660247	1
4139	68	358051321099997	OUT	SalesInvoice	57	2026-01-12 14:12:33.574286	1
4148	68	356605226033781	OUT	SalesInvoice	60	2026-01-12 14:22:51.759548	1
4149	68	355224250029748	OUT	SalesInvoice	60	2026-01-12 14:22:51.759548	1
4150	68	355450218650917	OUT	SalesInvoice	60	2026-01-12 14:22:51.759548	1
4155	68	357586344610396	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4156	68	353263427359440	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4157	68	352791397736289	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4158	68	356188161863918	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4159	68	353263424083571	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4160	68	352791396686626	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4161	68	359614542086678	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4162	68	353263425811954	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4163	68	357586346058651	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4164	45	SDKJYYPYHW5	OUT	SalesInvoice	62	2026-01-12 14:29:26.845081	1
4170	10	1581F6Z9C2489003YS6P	OUT	SalesInvoice	64	2026-01-12 14:36:20.992596	1
4171	10	1581F6Z9A24A1ML3ZC4G	OUT	SalesInvoice	64	2026-01-12 14:36:20.992596	1
5708	3	ps5slimdigital00064	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5709	3	ps5slimdigital00065	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5710	3	ps5slimdigital00066	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5711	3	ps5slimdigital00067	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5712	3	ps5slimdigital00068	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
4181	1	starlinkv40266	OUT	SalesInvoice	68	2026-01-12 15:59:03.04829	1
4182	1	starlinkv40267	OUT	SalesInvoice	68	2026-01-12 15:59:03.04829	1
4183	1	starlinkv40268	OUT	SalesInvoice	68	2026-01-12 15:59:03.04829	1
4184	1	starlinkv40269	OUT	SalesInvoice	68	2026-01-12 15:59:03.04829	1
5713	3	ps5slimdigital00069	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5714	3	ps5slimdigital00070	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5715	3	ps5slimdigital00071	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5716	3	ps5slimdigital00072	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5717	3	ps5slimdigital00073	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5718	3	ps5slimdigital00074	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
4198	8	1581F8LQC253G0020HJ4	OUT	SalesInvoice	70	2026-01-13 12:19:26.408038	1
4199	8	1581F8LQC255A0021ZQA	OUT	SalesInvoice	70	2026-01-13 12:19:26.408038	1
5719	3	ps5slimdigital00075	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5720	3	ps5slimdigital00076	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5721	3	ps5slimdigital00077	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5722	3	ps5slimdigital00078	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5723	3	ps5slimdigital00079	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3849	69	353837412105817	OUT	SalesInvoice	32	2026-01-09 15:44:03.749986	1
3850	69	355478870898102	OUT	SalesInvoice	32	2026-01-09 15:44:03.749986	1
5724	3	ps5slimdigital00080	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5725	3	ps5slimdigital00081	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5726	3	ps5slimdigital00082	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5727	3	ps5slimdigital00083	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5728	3	ps5slimdigital00084	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5729	3	ps5slimdigital00085	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5730	3	ps5slimdigital00086	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5731	3	ps5slimdigital00087	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5732	3	ps5slimdigital00088	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5733	3	ps5slimdigital00089	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5734	3	ps5slimdigital00090	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5735	3	ps5slimdigital00091	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5736	3	ps5slimdigital00092	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5737	3	ps5slimdigital00093	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5738	3	ps5slimdigital00094	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5739	3	ps5slimdigital00095	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5740	3	ps5slimdigital00096	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5741	3	ps5slimdigital00097	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5742	3	ps5slimdigital00098	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5743	3	ps5slimdigital00099	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3962	12	1581F8PJC24CR0022JYK	OUT	SalesInvoice	42	2026-01-09 16:37:35.871792	1
3963	12	1581F8PJC24B5001BCXM	OUT	SalesInvoice	42	2026-01-09 16:37:35.871792	1
2879	20	instaxfilm20pack00001	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2880	20	instaxfilm20pack00002	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2881	20	instaxfilm20pack00003	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2882	20	instaxfilm20pack00004	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2883	20	instaxfilm20pack00005	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2884	20	instaxfilm20pack00006	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2885	20	instaxfilm20pack00007	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2886	20	instaxfilm20pack00008	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2887	20	instaxfilm20pack00009	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2888	20	instaxfilm20pack00010	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2889	20	instaxfilm20pack00011	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2890	20	instaxfilm20pack00012	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2891	20	instaxfilm20pack00013	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2892	20	instaxfilm20pack00014	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2893	20	instaxfilm20pack00015	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2894	20	instaxfilm20pack00016	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2895	20	instaxfilm20pack00017	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2896	20	instaxfilm20pack00018	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2897	20	instaxfilm20pack00019	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2898	20	instaxfilm20pack00020	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2899	20	instaxfilm20pack00021	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2900	20	instaxfilm20pack00022	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2901	20	instaxfilm20pack00023	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2902	20	instaxfilm20pack00024	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2903	20	instaxfilm20pack00025	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2904	20	instaxfilm20pack00026	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2905	20	instaxfilm20pack00027	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2906	20	instaxfilm20pack00028	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2907	20	instaxfilm20pack00029	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2908	20	instaxfilm20pack00030	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2909	20	instaxfilm20pack00031	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2910	20	instaxfilm20pack00032	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2911	20	instaxfilm20pack00033	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2912	20	instaxfilm20pack00034	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2913	20	instaxfilm20pack00035	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2914	20	instaxfilm20pack00036	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2915	20	instaxfilm20pack00037	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2916	20	instaxfilm20pack00038	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2917	20	instaxfilm20pack00039	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2918	20	instaxfilm20pack00040	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2919	20	instaxfilm20pack00041	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2920	20	instaxfilm20pack00042	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2921	20	instaxfilm20pack00043	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3964	12	1581F8PJC24BC00202KW	OUT	SalesInvoice	42	2026-01-09 16:37:35.871792	1
3997	79	357205981249315	OUT	SalesInvoice	45	2026-01-10 14:01:55.188918	1
4003	132	359103740084792	OUT	SalesInvoice	48	2026-01-10 14:37:37.021822	1
2922	20	instaxfilm20pack00044	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2923	20	instaxfilm20pack00045	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2924	20	instaxfilm20pack00046	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2925	20	instaxfilm20pack00047	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2926	20	instaxfilm20pack00048	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2927	20	instaxfilm20pack00049	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2928	20	instaxfilm20pack00050	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2929	20	instaxfilm20pack00051	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2930	20	instaxfilm20pack00052	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2931	20	instaxfilm20pack00053	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2932	20	instaxfilm20pack00054	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2933	20	instaxfilm20pack00055	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2934	20	instaxfilm20pack00056	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2935	20	instaxfilm20pack00057	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2936	20	instaxfilm20pack00058	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2937	20	instaxfilm20pack00059	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2938	20	instaxfilm20pack00060	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2939	20	instaxfilm20pack00061	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2940	20	instaxfilm20pack00062	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2941	20	instaxfilm20pack00063	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2942	20	instaxfilm20pack00064	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2943	20	instaxfilm20pack00065	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2944	20	instaxfilm20pack00066	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2945	20	instaxfilm20pack00067	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2946	20	instaxfilm20pack00068	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2947	20	instaxfilm20pack00069	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2948	20	instaxfilm20pack00070	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2949	20	instaxfilm20pack00071	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2950	20	instaxfilm20pack00072	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2951	20	instaxfilm20pack00073	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2952	20	instaxfilm20pack00074	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2953	20	instaxfilm20pack00075	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2954	20	instaxfilm20pack00076	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2955	20	instaxfilm20pack00077	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2956	20	instaxfilm20pack00078	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2957	20	instaxfilm20pack00079	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2958	20	instaxfilm20pack00080	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2959	20	instaxfilm20pack00081	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2960	20	instaxfilm20pack00082	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2961	20	instaxfilm20pack00083	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2962	20	instaxfilm20pack00084	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2963	20	instaxfilm20pack00085	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2964	20	instaxfilm20pack00086	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2965	20	instaxfilm20pack00087	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2966	20	instaxfilm20pack00088	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2967	20	instaxfilm20pack00089	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2968	20	instaxfilm20pack00090	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2969	20	instaxfilm20pack00091	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2970	20	instaxfilm20pack00092	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2971	20	instaxfilm20pack00093	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2972	20	instaxfilm20pack00094	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2973	20	instaxfilm20pack00095	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2974	20	instaxfilm20pack00096	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2975	20	instaxfilm20pack00097	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2976	20	instaxfilm20pack00098	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2977	20	instaxfilm20pack00099	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2978	20	instaxfilm20pack00100	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2979	20	instaxfilm20pack00101	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2980	20	instaxfilm20pack00102	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2981	20	instaxfilm20pack00103	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2982	20	instaxfilm20pack00104	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2983	20	instaxfilm20pack00105	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2984	20	instaxfilm20pack00106	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2985	20	instaxfilm20pack00107	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2986	20	instaxfilm20pack00108	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2987	20	instaxfilm20pack00109	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2988	20	instaxfilm20pack00110	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2989	20	instaxfilm20pack00111	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2990	20	instaxfilm20pack00112	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2991	20	instaxfilm20pack00113	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2992	20	instaxfilm20pack00114	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2993	20	instaxfilm20pack00115	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2994	20	instaxfilm20pack00116	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2995	20	instaxfilm20pack00117	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2996	20	instaxfilm20pack00118	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2997	20	instaxfilm20pack00119	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2998	20	instaxfilm20pack00120	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
2999	20	instaxfilm20pack00121	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3000	20	instaxfilm20pack00122	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3001	20	instaxfilm20pack00123	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3002	20	instaxfilm20pack001124	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3003	20	instaxfilm20pack00125	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3004	20	instaxfilm20pack00126	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3005	20	instaxfilm20pack00127	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3006	20	instaxfilm20pack00128	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3007	20	instaxfilm20pack00129	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3008	20	instaxfilm20pack00130	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3009	20	instaxfilm20pack00131	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3010	20	instaxfilm20pack00132	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3011	20	instaxfilm20pack00133	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3012	20	instaxfilm20pack00134	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3013	20	instaxfilm20pack00135	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3014	20	instaxfilm20pack00136	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3015	20	instaxfilm20pack00137	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3016	20	instaxfilm20pack00138	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3017	20	instaxfilm20pack00139	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3018	20	instaxfilm20pack00140	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3019	20	instaxfilm20pack00141	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3020	20	instaxfilm20pack00142	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3021	20	instaxfilm20pack00143	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3022	20	instaxfilm20pack00144	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3023	20	instaxfilm20pack00145	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3024	20	instaxfilm20pack00146	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3025	20	instaxfilm20pack00147	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3026	20	instaxfilm20pack00148	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3027	20	instaxfilm20pack00149	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3028	20	instaxfilm20pack00150	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3029	20	instaxfilm20pack00151	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3030	20	instaxfilm20pack00152	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3031	20	instaxfilm20pack00153	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3032	20	instaxfilm20pack00154	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3033	20	instaxfilm20pack00155	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3034	20	instaxfilm20pack00156	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3035	20	instaxfilm20pack00157	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3036	20	instaxfilm20pack00158	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3037	20	instaxfilm20pack00159	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3038	20	instaxfilm20pack00160	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3039	20	instaxfilm20pack00161	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3040	20	instaxfilm20pack00162	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3041	20	instaxfilm20pack00163	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3042	20	instaxfilm20pack00164	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3043	20	instaxfilm20pack00165	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3044	20	instaxfilm20pack00166	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3045	20	instaxfilm20pack00167	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3046	20	instaxfilm20pack00168	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3047	20	instaxfilm20pack00169	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3048	20	instaxfilm20pack00170	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3049	20	instaxfilm20pack00171	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3050	20	instaxfilm20pack00172	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3051	20	instaxfilm20pack00173	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3052	20	instaxfilm20pack00174	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3053	20	instaxfilm20pack001175	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3054	20	instaxfilm20pack00176	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3055	20	instaxfilm20pack00177	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3056	20	instaxfilm20pack00178	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3057	20	instaxfilm20pack00179	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3058	20	instaxfilm20pack00180	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3059	20	instaxfilm20pack00181	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3060	20	instaxfilm20pack00182	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3061	20	instaxfilm20pack00183	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3062	20	instaxfilm20pack00184	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3063	20	instaxfilm20pack00185	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3064	20	instaxfilm20pack001186	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3065	20	instaxfilm20pack00187	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3066	20	instaxfilm20pack00188	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3067	20	instaxfilm20pack00189	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3068	20	instaxfilm20pack00190	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3069	20	instaxfilm20pack00191	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3070	20	instaxfilm20pack00192	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3071	20	instaxfilm20pack00193	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3072	20	instaxfilm20pack00194	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3073	20	instaxfilm20pack00195	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3074	20	instaxfilm20pack00196	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3075	20	instaxfilm20pack00197	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3076	20	instaxfilm20pack00198	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3077	20	instaxfilm20pack00199	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3078	20	instaxfilm20pack00200	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3079	20	instaxfilm20pack00201	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3080	20	instaxfilm20pack00202	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3081	20	instaxfilm20pack00203	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3082	20	instaxfilm20pack00204	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3083	20	instaxfilm20pack00205	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3084	20	instaxfilm20pack00206	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3085	20	instaxfilm20pack00207	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3086	20	instaxfilm20pack00208	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3087	20	instaxfilm20pack00209	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3088	20	instaxfilm20pack00210	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3089	20	instaxfilm20pack00211	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3090	20	instaxfilm20pack00212	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3091	20	instaxfilm20pack00213	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3092	20	instaxfilm20pack00214	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3093	20	instaxfilm20pack00215	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3094	20	instaxfilm20pack00216	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3095	20	instaxfilm20pack00217	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3096	20	instaxfilm20pack00218	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3097	20	instaxfilm20pack00219	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3098	20	instaxfilm20pack00220	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3099	20	instaxfilm20pack00221	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3100	20	instaxfilm20pack00222	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3101	20	instaxfilm20pack00223	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3102	20	instaxfilm20pack00224	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3103	20	instaxfilm20pack00225	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3104	20	instaxfilm20pack00226	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3105	20	instaxfilm20pack00227	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3106	20	instaxfilm20pack00228	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3107	20	instaxfilm20pack00229	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3108	20	instaxfilm20pack00230	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3109	20	instaxfilm20pack00231	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3110	20	instaxfilm20pack00232	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3111	20	instaxfilm20pack00233	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3112	20	instaxfilm20pack00234	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3113	20	instaxfilm20pack00235	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3114	20	instaxfilm20pack00236	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3115	20	instaxfilm20pack00237	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3116	20	instaxfilm20pack00238	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3117	20	instaxfilm20pack00239	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3118	20	instaxfilm20pack00240	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3119	20	instaxfilm20pack00241	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3120	20	instaxfilm20pack00242	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3121	20	instaxfilm20pack00243	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3122	20	instaxfilm20pack00244	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3123	20	instaxfilm20pack00245	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3124	20	instaxfilm20pack00246	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3125	20	instaxfilm20pack00247	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3126	20	instaxfilm20pack00248	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3127	20	instaxfilm20pack00249	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3128	20	instaxfilm20pack00250	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3129	20	instaxfilm20pack00251	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3130	20	instaxfilm20pack00252	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3131	20	instaxfilm20pack00253	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3132	20	instaxfilm20pack00254	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3133	20	instaxfilm20pack00255	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3134	20	instaxfilm20pack00256	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3135	20	instaxfilm20pack00257	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3136	20	instaxfilm20pack00258	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3137	20	instaxfilm20pack00259	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3138	20	instaxfilm20pack00260	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3139	20	instaxfilm20pack00261	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3140	20	instaxfilm20pack00262	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3141	20	instaxfilm20pack00263	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3142	20	instaxfilm20pack00264	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3143	20	instaxfilm20pack00265	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3144	20	instaxfilm20pack00266	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3145	20	instaxfilm20pack00267	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3146	20	instaxfilm20pack00268	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3147	20	instaxfilm20pack00269	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3148	20	instaxfilm20pack00270	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3149	20	instaxfilm20pack00271	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3150	20	instaxfilm20pack00272	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3151	20	instaxfilm20pack00273	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3152	20	instaxfilm20pack00274	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3153	20	instaxfilm20pack00275	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3154	20	instaxfilm20pack00276	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3155	20	instaxfilm20pack00277	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3156	20	instaxfilm20pack00278	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3157	20	instaxfilm20pack00279	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3158	20	instaxfilm20pack00280	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3159	20	instaxfilm20pack00281	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3160	20	instaxfilm20pack00282	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3161	20	instaxfilm20pack00283	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3162	20	instaxfilm20pack00284	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3163	20	instaxfilm20pack00285	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3164	20	instaxfilm20pack00286	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3165	20	instaxfilm20pack00287	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3166	20	instaxfilm20pack00288	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3167	20	instaxfilm20pack00289	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3168	20	instaxfilm20pack00290	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3169	20	instaxfilm20pack00291	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3170	20	instaxfilm20pack00292	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3171	20	instaxfilm20pack00293	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3172	20	instaxfilm20pack00294	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3173	20	instaxfilm20pack00295	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3174	20	instaxfilm20pack00296	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3175	20	instaxfilm20pack00297	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3176	20	instaxfilm20pack00298	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3177	20	instaxfilm20pack00299	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
3178	20	instaxfilm20pack00300	OUT	SalesInvoice	10	2026-01-09 13:43:09.35116	1
5744	3	ps5slimdigital00100	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5745	3	ps5slimdigital00101	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5746	3	ps5slimdigital00102	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5747	3	ps5slimdigital00103	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5748	3	ps5slimdigital00104	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5749	3	ps5slimdigital00105	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5750	3	ps5slimdigital00106	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5751	3	ps5slimdigital00107	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5752	3	ps5slimdigital00108	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5753	3	ps5slimdigital00109	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5754	3	ps5slimdigital00110	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3190	17	]C121105082001945	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3191	17	]C121105082001943	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3192	17	]C121115082000637	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3193	14	9SDXN8L0124RC5	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3194	14	9SDXN4F012075H	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3195	14	9SDXN5E01214SH	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3196	14	9SDXN5K0220150	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3197	14	9SDXN6S02219C8	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3198	14	9SDXN9N0126152	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3199	14	9SDXN6D012292X	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3200	14	9SDXN6U0122PYR	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3201	14	9SDXN7B0122ZUB	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
3202	14	9SDXN980233VD9	OUT	SalesInvoice	12	2026-01-09 14:12:30.007796	1
5755	3	ps5slimdigital00111	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5756	3	ps5slimdigital00112	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5757	3	ps5slimdigital00113	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5758	3	ps5slimdigital00114	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5759	3	ps5slimdigital00115	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5760	3	ps5slimdigital00116	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5761	3	ps5slimdigital00117	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5762	3	ps5slimdigital00118	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5763	3	ps5slimdigital00119	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5764	3	ps5slimdigital00120	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5765	3	ps5slimdigital00121	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5766	3	ps5slimdigital00122	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3914	161	5WTZN8S0020274	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3915	161	5WTZN8S002UDXU	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3916	161	5WTZN7L002SWHP	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3917	161	5WTZN8T0022PQ0	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3918	161	5WTZN9P002P7PU	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3603	1	starlinkv40072	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3919	161	5WTZN9P0020BFS	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3920	161	5WTZN88002M6E2	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3695	9	1581F6Z9A248WML33640	OUT	SalesInvoice	24	2026-01-09 15:16:47.431197	1
3696	9	1581F6Z9A24CRML37S28	OUT	SalesInvoice	24	2026-01-09 15:16:47.431197	1
3697	9	1581F6Z9A24CRML3JZY0	OUT	SalesInvoice	24	2026-01-09 15:16:47.431197	1
3874	68	358051322098196	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3875	68	357586344596264	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3876	68	357586344694234	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3877	70	356250543171277	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3878	70	356250549338896	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3879	70	352190327764315	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3880	70	353708846189133	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3881	159	350208037361842	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3882	159	350208037531998	OUT	SalesInvoice	34	2026-01-09 15:54:12.141482	1
3921	161	5WTZN99002381Z	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3922	161	5WTZN99002RTU6	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3923	161	5WTZN6N002EQW5	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3924	161	5WTZN8T0020WX7	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3925	161	5WTZN8W002K4LH	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3926	161	5WTZN8P002NQ2F	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3927	161	5WTZN9S002CSL7	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3928	161	5WTZN93002GB67	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3929	161	5WTZN8D002GB8D	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3930	161	5WTZN3N0023GL9	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3931	161	5WTZN93002545V	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3932	161	5WTZN92002P48K	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3933	161	5WTZN8P002QXC3	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3934	161	5WTZN9N002NEBJ	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3935	161	5WTZN8800234DJ	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
3936	161	5WTZN8N002ML5R	IN	PurchaseInvoice	82	2026-01-09 16:20:44.556728	1
5767	3	ps5slimdigital00123	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5768	3	ps5slimdigital00124	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5769	3	ps5slimdigital00125	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5770	3	ps5slimdigital00126	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5771	3	ps5slimdigital00127	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3998	81	357463448249218	OUT	SalesInvoice	46	2026-01-10 14:19:52.988639	1
3999	79	352315400015596	OUT	SalesInvoice	46	2026-01-10 14:19:52.988639	1
4004	86	358001685550705	OUT	SalesInvoice	50	2026-01-10 14:46:51.67825	1
5772	3	ps5slimdigital00128	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5773	3	ps5slimdigital00129	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5774	3	ps5slimdigital00130	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5775	3	ps5slimdigital00131	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5776	3	ps5slimdigital00132	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5777	3	ps5slimdigital00133	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5778	3	ps5slimdigital00134	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5779	3	ps5slimdigital00135	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5780	3	ps5slimdigital00136	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5781	3	ps5slimdigital00137	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5782	3	ps5slimdigital00138	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5783	3	ps5slimdigital00139	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5784	3	ps5slimdigital00140	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5785	3	ps5slimdigital00141	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5786	3	ps5slimdigital00142	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5787	3	ps5slimdigital00143	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5788	3	ps5slimdigital00144	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5789	3	ps5slimdigital00145	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5790	3	ps5slimdigital00146	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5791	3	ps5slimdigital00147	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5792	3	ps5slimdigital00148	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5793	3	ps5slimdigital00149	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5794	3	ps5slimdigital00150	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5795	3	ps5slimdigital00151	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5796	3	ps5slimdigital00152	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5797	3	ps5slimdigital00153	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5798	3	ps5slimdigital00154	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5799	3	ps5slimdigital00155	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5800	3	ps5slimdigital00156	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5801	3	ps5slimdigital00157	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5802	3	ps5slimdigital00158	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5803	3	ps5slimdigital00159	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5804	3	ps5slimdigital00160	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5805	3	ps5slimdigital00161	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5806	3	ps5slimdigital00162	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
4140	12	1581F8PJC24CR0022N4Y	OUT	SalesInvoice	58	2026-01-12 14:15:01.727995	1
4141	12	1581F8PJC24CQ0022HSV	OUT	SalesInvoice	58	2026-01-12 14:15:01.727995	1
5807	3	ps5slimdigital00163	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5808	3	ps5slimdigital00164	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3749	1	starlinkv40186	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3750	1	starlinkv40187	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3751	1	starlinkv40188	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3752	1	starlinkv40189	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3753	1	starlinkv40190	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3754	1	starlinkv40191	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3755	1	starlinkv40192	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3756	1	starlinkv40193	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3757	1	starlinkv40194	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3758	1	starlinkv40195	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3759	1	starlinkv40196	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3760	1	starlinkv40197	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3761	1	starlinkv40198	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3762	1	starlinkv40199	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3763	1	starlinkv40200	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3764	1	starlinkv40201	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3765	1	starlinkv40202	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3766	1	starlinkv40203	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3767	1	starlinkv40204	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3768	1	starlinkv40205	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3769	1	starlinkv40206	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3770	1	starlinkv40207	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3771	1	starlinkv40208	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3772	1	starlinkv40209	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3773	1	starlinkv40210	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3774	1	starlinkv40211	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3775	1	starlinkv40212	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3776	1	starlinkv40213	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3777	1	starlinkv40214	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3778	1	starlinkv40215	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3779	1	starlinkv40216	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3780	1	starlinkv40217	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3781	1	starlinkv40218	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3782	1	starlinkv40219	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3783	1	starlinkv40220	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3784	1	starlinkv40221	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3785	1	starlinkv40222	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3786	1	starlinkv40223	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3787	1	starlinkv40224	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3788	1	starlinkv40225	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3789	1	starlinkv40226	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3790	1	starlinkv40227	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3791	1	starlinkv40228	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3792	1	starlinkv40229	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3793	1	starlinkv40230	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3794	1	starlinkv40231	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3795	1	starlinkv40232	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3796	1	starlinkv40233	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3797	1	starlinkv40234	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3798	1	starlinkv40235	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3799	1	starlinkv40236	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3800	1	starlinkv40237	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3801	1	starlinkv40238	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3802	1	starlinkv40239	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3803	1	starlinkv40240	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3804	1	starlinkv40241	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3805	1	starlinkv40242	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3806	1	starlinkv40243	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3807	1	starlinkv40244	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3808	1	starlinkv40245	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3809	1	starlinkv40246	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3810	1	starlinkv40247	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3811	1	starlinkv40248	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3812	1	starlinkv40249	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3813	1	starlinkv40250	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3814	1	starlinkv40251	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3815	1	starlinkv40252	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3816	1	starlinkv40253	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3817	1	starlinkv40254	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3367	20	instaxfilm20pack00315	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3368	20	instaxfilm20pack00316	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3369	20	instaxfilm20pack00317	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3370	20	instaxfilm20pack00318	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3371	20	instaxfilm20pack00319	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3372	20	instaxfilm20pack00320	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3818	1	starlinkv40255	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3819	1	starlinkv40256	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3820	1	starlinkv40257	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3821	1	starlinkv40258	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3822	1	starlinkv40259	OUT	SalesInvoice	27	2026-01-09 15:28:02.763274	1
3883	3	S01F55701RRC10253396	OUT	SalesInvoice	35	2026-01-09 15:58:56.045436	1
3373	20	instaxfilm20pack00321	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3374	20	instaxfilm20pack00322	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3375	20	instaxfilm20pack00323	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3376	20	instaxfilm20pack00324	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3377	20	instaxfilm20pack00325	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3378	20	instaxfilm20pack00326	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3379	20	instaxfilm20pack00327	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3380	20	instaxfilm20pack00328	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3381	20	instaxfilm20pack00329	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3382	20	instaxfilm20pack00330	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3383	20	instaxfilm20pack00331	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3384	20	instaxfilm20pack00332	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3385	20	instaxfilm20pack00333	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3386	20	instaxfilm20pack00334	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3387	20	instaxfilm20pack00335	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3388	20	instaxfilm20pack00336	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3389	20	instaxfilm20pack00337	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3390	20	instaxfilm20pack00338	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3391	20	instaxfilm20pack00339	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3392	20	instaxfilm20pack00340	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3393	20	instaxfilm20pack00341	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3394	20	instaxfilm20pack00342	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3395	20	instaxfilm20pack00343	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3396	20	instaxfilm20pack00344	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3397	20	instaxfilm20pack00345	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3398	20	instaxfilm20pack00346	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3399	20	instaxfilm20pack00347	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3400	20	instaxfilm20pack00348	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3401	20	instaxfilm20pack00349	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3402	20	instaxfilm20pack00350	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3403	20	instaxfilm20pack00351	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3404	20	instaxfilm20pack00352	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3405	20	instaxfilm20pack00353	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3406	20	instaxfilm20pack00354	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3407	20	instaxfilm20pack00355	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3408	20	instaxfilm20pack00356	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3409	20	instaxfilm20pack00357	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3410	20	instaxfilm20pack00358	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3411	20	instaxfilm20pack00359	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3412	20	instaxfilm20pack00360	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3413	20	instaxfilm20pack00361	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3414	20	instaxfilm20pack00362	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3415	20	instaxfilm20pack00363	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3416	20	instaxfilm20pack00364	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3417	20	instaxfilm20pack00365	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3418	20	instaxfilm20pack00366	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3419	20	instaxfilm20pack00367	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3420	20	instaxfilm20pack00368	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3421	20	instaxfilm20pack00369	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3422	20	instaxfilm20pack00370	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3423	20	instaxfilm20pack00371	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3424	20	instaxfilm20pack00372	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3425	20	instaxfilm20pack00373	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3426	20	instaxfilm20pack00374	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3427	20	instaxfilm20pack00375	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3428	20	instaxfilm20pack00376	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3429	20	instaxfilm20pack00377	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3430	20	instaxfilm20pack00378	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3431	20	instaxfilm20pack00379	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3432	20	instaxfilm20pack00380	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3433	20	instaxfilm20pack00381	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3434	20	instaxfilm20pack00382	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3435	20	instaxfilm20pack00383	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3436	20	instaxfilm20pack00384	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3437	20	instaxfilm20pack00385	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3438	20	instaxfilm20pack00386	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3439	20	instaxfilm20pack00387	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3440	20	instaxfilm20pack00388	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3441	20	instaxfilm20pack00389	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3442	20	instaxfilm20pack00390	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3443	20	instaxfilm20pack00391	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3444	20	instaxfilm20pack00392	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3445	20	instaxfilm20pack00393	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3446	20	instaxfilm20pack00394	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3447	20	instaxfilm20pack00395	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3448	20	instaxfilm20pack00396	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3449	20	instaxfilm20pack00397	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3450	20	instaxfilm20pack00398	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3451	20	instaxfilm20pack00399	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3452	20	instaxfilm20pack00400	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3453	20	instaxfilm20pack00401	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3454	20	instaxfilm20pack00402	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3455	20	instaxfilm20pack00403	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3456	20	instaxfilm20pack00404	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3457	20	instaxfilm20pack00405	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3458	20	instaxfilm20pack00406	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3459	20	instaxfilm20pack00407	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3460	20	instaxfilm20pack00408	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3461	20	instaxfilm20pack00409	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3462	20	instaxfilm20pack00410	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3463	20	instaxfilm20pack00411	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3464	20	instaxfilm20pack00412	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3465	20	instaxfilm20pack00413	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3466	20	instaxfilm20pack00414	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3467	20	instaxfilm20pack00415	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3468	20	instaxfilm20pack00416	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3469	20	instaxfilm20pack00417	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3470	20	instaxfilm20pack00418	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3471	20	instaxfilm20pack00419	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3472	20	instaxfilm20pack00420	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3473	20	instaxfilm20pack00421	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3474	20	instaxfilm20pack00422	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3475	20	instaxfilm20pack00423	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3476	20	instaxfilm20pack00424	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3477	20	instaxfilm20pack00425	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3478	20	instaxfilm20pack00426	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3479	20	instaxfilm20pack00427	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3480	20	instaxfilm20pack00428	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3481	20	instaxfilm20pack00429	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3482	20	instaxfilm20pack00430	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3483	20	instaxfilm20pack00431	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3484	20	instaxfilm20pack00432	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3485	20	instaxfilm20pack00433	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3486	20	instaxfilm20pack00434	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3487	20	instaxfilm20pack00435	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3488	20	instaxfilm20pack00436	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3489	20	instaxfilm20pack00437	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3490	20	instaxfilm20pack00438	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3491	20	instaxfilm20pack00439	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3492	20	instaxfilm20pack00440	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3493	20	instaxfilm20pack00441	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3494	20	instaxfilm20pack00442	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3495	20	instaxfilm20pack00443	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3496	20	instaxfilm20pack00444	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3497	20	instaxfilm20pack00445	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3498	20	instaxfilm20pack00446	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3499	20	instaxfilm20pack00447	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3500	20	instaxfilm20pack00448	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3501	20	instaxfilm20pack00449	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3502	20	instaxfilm20pack00450	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3503	20	instaxfilm20pack00451	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3504	20	instaxfilm20pack00452	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3505	20	instaxfilm20pack00453	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3506	20	instaxfilm20pack00454	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3507	20	instaxfilm20pack00455	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3508	20	instaxfilm20pack00456	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3509	20	instaxfilm20pack00457	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3510	20	instaxfilm20pack00458	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3511	20	instaxfilm20pack00459	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3512	20	instaxfilm20pack00460	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3513	20	instaxfilm20pack00461	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3514	20	instaxfilm20pack00462	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3515	20	instaxfilm20pack00463	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3516	20	instaxfilm20pack00464	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3517	20	instaxfilm20pack00301	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3518	20	instaxfilm20pack00302	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3519	20	instaxfilm20pack00303	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3520	20	instaxfilm20pack00304	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3521	20	instaxfilm20pack00305	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3522	20	instaxfilm20pack00306	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3523	20	instaxfilm20pack00307	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3524	20	instaxfilm20pack00308	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3525	20	instaxfilm20pack00309	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3526	20	instaxfilm20pack00310	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3527	20	instaxfilm20pack00311	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3528	20	instaxfilm20pack00312	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3529	20	instaxfilm20pack00313	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3530	20	instaxfilm20pack00314	OUT	SalesInvoice	13	2026-01-09 14:20:27.866434	1
3531	75	354512320823475	OUT	SalesInvoice	14	2026-01-09 14:21:17.940202	1
3532	1	starlinkv40001	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3533	1	starlinkv40002	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3534	1	starlinkv40003	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3535	1	starlinkv40004	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3536	1	starlinkv40005	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3537	1	starlinkv40006	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3538	1	starlinkv40007	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3539	1	starlinkv40008	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3540	1	starlinkv40009	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3541	1	starlinkv40010	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3542	1	starlinkv40011	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3543	1	starlinkv40012	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3544	1	starlinkv40013	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3545	1	starlinkv40014	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3546	1	starlinkv40015	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3547	1	starlinkv40016	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3548	1	starlinkv40017	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3549	1	starlinkv40018	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3550	1	starlinkv40019	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3551	1	starlinkv40020	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3552	1	starlinkv40021	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3553	1	starlinkv40022	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3554	1	starlinkv40023	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3555	1	starlinkv40024	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3556	1	starlinkv40025	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3557	1	starlinkv40026	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3558	1	starlinkv40027	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3559	1	starlinkv40028	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3560	1	starlinkv40029	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3561	1	starlinkv40030	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3562	1	starlinkv40031	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3563	1	starlinkv40032	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3564	1	starlinkv40033	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3565	1	starlinkv40034	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3566	1	starlinkv40035	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3567	1	starlinkv40036	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3568	1	starlinkv40037	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3569	1	starlinkv40038	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3570	1	starlinkv40039	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3571	1	starlinkv40040	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3572	1	starlinkv40041	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3573	1	starlinkv40042	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3574	1	starlinkv40043	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3575	1	starlinkv40044	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3576	1	starlinkv40045	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3577	1	starlinkv40046	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3578	1	starlinkv40047	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3579	1	starlinkv40048	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3580	1	starlinkv40049	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3581	1	starlinkv40050	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3582	1	starlinkv40051	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3583	1	starlinkv40052	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3584	1	starlinkv40053	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3585	1	starlinkv40054	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3586	1	starlinkv40055	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3587	1	starlinkv40056	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3588	1	starlinkv40057	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3589	1	starlinkv40058	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3590	1	starlinkv40059	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3591	1	starlinkv40060	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3592	1	starlinkv40061	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3593	1	starlinkv40062	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3594	1	starlinkv40063	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3595	1	starlinkv40064	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3596	1	starlinkv40065	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3597	1	starlinkv40066	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3598	1	starlinkv40067	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3599	1	starlinkv40068	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3600	1	starlinkv40069	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3601	1	starlinkv40070	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3602	1	starlinkv40071	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3604	1	starlinkv40073	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3605	1	starlinkv40074	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3606	1	starlinkv40075	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3607	1	starlinkv40076	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3608	1	starlinkv40077	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3609	1	starlinkv40078	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3610	1	starlinkv40079	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3611	1	starlinkv40080	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3612	1	starlinkv40081	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3613	1	starlinkv40082	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3614	1	starlinkv40083	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3615	1	starlinkv40084	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3616	1	starlinkv40085	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3617	1	starlinkv40086	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3618	1	starlinkv40087	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3619	1	starlinkv40088	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3620	1	starlinkv40089	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3621	1	starlinkv40090	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3622	1	starlinkv40091	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3623	1	starlinkv40092	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3624	1	starlinkv40093	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3625	1	starlinkv40094	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3626	1	starlinkv40095	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3627	1	starlinkv40096	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3628	1	starlinkv40097	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3629	1	starlinkv40098	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3630	1	starlinkv40099	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
3631	1	starlinkv40100	OUT	SalesInvoice	15	2026-01-09 14:27:52.181083	1
5809	3	ps5slimdigital00165	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
3633	17	]C121115082000643	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3634	17	]C121105082001939	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3635	17	]C121095082002402	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3636	17	]C121085082000785	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3637	17	]C121095082001715	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3638	18	]C121115081000720	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3639	18	]C121115081000723	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3640	18	]C121115081000722	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3641	18	]C121115081000721	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3642	18	]C121095081000253	OUT	SalesInvoice	17	2026-01-09 14:40:29.194573	1
3643	17	]C121105082001947	OUT	SalesInvoice	18	2026-01-09 14:43:45.384582	1
3644	17	]C121105082001940	OUT	SalesInvoice	18	2026-01-09 14:43:45.384582	1
3823	70	352190327421734	OUT	SalesInvoice	28	2026-01-09 15:31:16.077963	1
3824	70	350208033173753	OUT	SalesInvoice	28	2026-01-09 15:31:16.077963	1
3825	70	356250549139179	OUT	SalesInvoice	28	2026-01-09 15:31:16.077963	1
3884	3	S01V558019CN10250136	OUT	SalesInvoice	35	2026-01-09 15:58:56.045436	1
3937	161	5WTZN8P002QXC3	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3938	161	5WTZN3N0023GL9	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3939	161	5WTZN8D002GB8D	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3940	161	5WTZN93002GB67	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3941	161	5WTZN7L002SWHP	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3942	161	5WTZN9P002P7PU	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3943	161	5WTZN92002P48K	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3944	161	5WTZN6N002EQW5	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3945	161	5WTZN9N002NEBJ	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3946	161	5WTZN88002M6E2	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3947	161	5WTZN8T0020WX7	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3948	161	5WTZN8P002NQ2F	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3949	161	5WTZN8S0020274	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3950	161	5WTZN8T0022PQ0	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3951	161	5WTZN9S002CSL7	OUT	SalesInvoice	38	2026-01-09 16:25:09.146762	1
3970	1	starlinkv40150	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3971	1	starlinkv40151	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3972	1	starlinkv40152	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3973	1	starlinkv40153	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3974	1	starlinkv40154	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3975	1	starlinkv40155	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3976	1	starlinkv40156	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3977	1	starlinkv40157	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3978	1	starlinkv40158	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3979	1	starlinkv40159	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3980	1	starlinkv40135	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3981	1	starlinkv40136	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3982	1	starlinkv40137	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3983	1	starlinkv40138	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3984	1	starlinkv40139	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3985	1	starlinkv40140	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3986	1	starlinkv40141	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3987	1	starlinkv40142	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3988	1	starlinkv40143	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
3989	1	starlinkv40144	OUT	SalesInvoice	26	2026-01-09 17:05:55.065656	1
4200	12	1581F8PJC24BF0020EU1	OUT	SalesInvoice	71	2026-01-13 12:28:28.908955	1
4201	12	1581F8PJC24CR0022M1Z	OUT	SalesInvoice	71	2026-01-13 12:28:28.908955	1
4202	10	1581F6Z9A249DML38T1H	OUT	SalesInvoice	71	2026-01-13 12:28:28.908955	1
4203	77	358271520320685	OUT	SalesInvoice	55	2026-01-13 12:32:02.968113	1
4204	42	SD2WYWYFPLV	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4205	42	SDX9XWFKW42	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4206	42	SL9W0J24GDM	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4207	42	SM7RR6FRW7N	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4208	43	SMT43DHJRGH	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4209	43	SK946HW04X3	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4210	43	SGD4TR707KJ	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4211	63	350094261697964	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4212	63	350094261355704	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4213	66	358112930542452	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4214	68	359912587219711	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4215	68	359614541610171	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4216	68	359614540060931	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4217	68	358051322533887	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4218	68	353837419391642	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4219	68	358051321265978	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4220	68	356605225057831	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4221	68	350889862536879	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4222	68	353263425144000	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4223	68	359614544687390	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4224	75	353263423932034	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4225	79	355008282401839	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4226	80	357719281961635	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4227	86	357773240293275	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4228	88	356334540274274	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4229	103	353685834007800	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4230	105	SH6W4PFQWCW	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4231	106	359132197678855	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4232	136	353894107001488	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4233	138	356832826585198	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4234	140	355445520481381	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4235	141	357762265949689	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4236	141	357985605788059	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4237	142	355852812209224	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4238	142	350138782777415	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4239	142	352515983937724	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4240	142	350304975570948	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4241	143	357773241392274	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4242	144	358691739992588	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4243	145	358229303109360	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4244	146	SLJ2DW1GJPG	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4245	146	SJ56LKQX91F	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4246	147	357153132623899	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4247	148	SM04W37XK2M	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4248	149	SMT79VX36C5	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4249	149	SMJF72R0W6K	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4250	150	SF3W6VGQT49	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4251	151	SDF9R6G97J0	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4252	152	356187982445939	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4253	154	4V0ZH17H7X01K1	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4254	155	4V37W23H8Y03BB	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4255	156	2Q0ZT00H9108MM	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4256	157	4V0ZS17H8H02KD	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4257	157	4V0ZS12H8M0121	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4258	158	2Q0ZY01H6R0088	IN	PurchaseInvoice	77	2026-01-13 13:05:52.839235	1
4259	153	359800206266629	IN	PurchaseInvoice	84	2026-01-13 13:06:48.685721	1
4260	153	358344510337678	IN	PurchaseInvoice	84	2026-01-13 13:06:48.685721	1
4261	153	359800204422869	IN	PurchaseInvoice	84	2026-01-13 13:06:48.685721	1
4262	81	356295606462741	OUT	SalesInvoice	73	2026-01-13 13:16:56.435549	1
4263	76	359724859410781	OUT	SalesInvoice	74	2026-01-13 13:26:51.269534	1
4264	103	356422163856533	OUT	SalesInvoice	75	2026-01-13 13:31:00.925398	1
4265	53	SK6GQGF74F4	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4266	54	SGVQ2RQRCMW	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4267	55	ST76N06VX9D	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4268	56	SK327X51Q91	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4269	56	SF7J9C4WVDW	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4270	59	SGPGK00MPQ7	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4271	60	SFVFHN160Q6L5	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4272	61	SL93Y0GWVRC	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4273	62	SC91KHM70VM	IN	PurchaseInvoice	61	2026-01-14 12:12:19.841542	1
4274	53	SK6GQGF74F4	OUT	SalesInvoice	76	2026-01-14 12:14:45.226055	1
5810	3	ps5slimdigital00166	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
4276	1	starlinkv40270	OUT	SalesInvoice	77	2026-01-14 12:27:37.08907	1
4277	1	starlinkv40271	OUT	SalesInvoice	77	2026-01-14 12:27:37.08907	1
4278	1	starlinkv40272	OUT	SalesInvoice	77	2026-01-14 12:27:37.08907	1
4279	1	starlinkv40273	OUT	SalesInvoice	77	2026-01-14 12:27:37.08907	1
4280	44	SV49N6TXD96	OUT	SalesInvoice	78	2026-01-14 13:18:15.398603	1
5811	3	ps5slimdigital00167	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5812	3	ps5slimdigital00168	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5813	3	ps5slimdigital00169	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5814	3	ps5slimdigital00170	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5815	3	ps5slimdigital00171	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5816	3	ps5slimdigital00172	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5817	3	ps5slimdigital00173	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5818	3	ps5slimdigital00174	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5819	3	ps5slimdigital00175	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5820	3	ps5slimdigital00176	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5821	3	ps5slimdigital00177	IN	PurchaseInvoice	96	2026-01-22 13:01:46.312447	1
5957	3	S01E55A01J5310261219	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5958	3	S01E55A01J5310266661	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5959	3	S01E55901J5310251067	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5960	3	S01E55901J5310261166	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5961	3	S01E55901J5310258791	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5962	3	S01E55A01J5310261213	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5963	3	S01E55901J5310258823	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5964	3	S01E55901J5310258779	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5965	3	S01E55A01J5310266681	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5966	3	S01E55901J5310257093	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5967	3	S01E55901J5310258770	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5968	3	S01E55A01J5310261214	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5969	3	S01E55901J5310258821	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
6336	68	321	OUT	PurchaseInvoice-Delete	95	2026-01-22 13:14:04.534252	1
4306	67	352355700414206	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4307	68	358482493529307	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4308	68	358482493270399	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4309	68	359614541093337	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4310	68	355478878442325	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4311	68	356188161552859	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4312	68	356188164176789	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4313	68	353263423163911	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4314	68	356605224923694	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4315	68	355450217775111	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4316	68	355450218138897	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4317	70	356839679159534	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4318	70	355500357943893	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4319	70	353708842036635	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4320	70	356250543300421	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4321	70	350208034439278	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4322	70	353748539961141	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4323	104	354123752650640	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4324	152	356187982541513	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4325	152	353938642157444	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4326	152	353938640357954	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4327	152	356187982623444	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4328	152	356187983034039	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4329	160	351878870270182	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4330	160	351878871215095	IN	PurchaseInvoice	85	2026-01-16 13:42:04.522401	1
4331	68	356188164176789	OUT	SalesInvoice	79	2026-01-16 13:54:57.271046	1
4332	68	356188161552859	OUT	SalesInvoice	79	2026-01-16 13:54:57.271046	1
4333	70	353748539961141	OUT	SalesInvoice	79	2026-01-16 13:54:57.271046	1
4334	6	1581F9DEC25AL0291CTX	OUT	SalesInvoice	80	2026-01-16 14:03:52.271755	1
4335	6	1581F9DEC25A90292N7Y	OUT	SalesInvoice	80	2026-01-16 14:03:52.271755	1
4336	6	1581F9DEC25AL029R2T3	OUT	SalesInvoice	80	2026-01-16 14:03:52.271755	1
4337	160	351878870270182	OUT	SalesInvoice	81	2026-01-16 14:06:38.025599	1
4338	160	351878871215095	OUT	SalesInvoice	81	2026-01-16 14:06:38.025599	1
4339	3	S01F55701RRC10252722	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4340	3	S01F55901RRC10290683	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4341	3	S01F55801RRC10263357	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4342	3	S01F55901RRC10282523	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4343	3	S01F55801RRC10263355	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4344	3	S01F55801RRC10263353	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4345	3	S01F55801RRC10263356	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4346	3	S01F55801RRC10263364	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4347	3	S01F55801RRC10263351	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4348	3	S01F55701RRC10252874	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4349	3	S01F55701RRC10252869	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4350	3	S01F55701RRC10253418	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4351	3	S01V558019CN10256717	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4352	3	S01F55701RRC10260047	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4353	3	S01F55701RRC10252721	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4354	3	S01F55701RRC10253425	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4355	3	S01F55901RRC10303746	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4356	3	S01V558019CN10256466	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4357	3	S01F55801RRC10263365	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4358	3	S01F55901RRC10287502	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4359	3	S01V558019CN10258939	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4360	3	S01F55701RRC10259204	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4361	3	S01F55901RRC10289942	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4362	3	S01F55701RRC10252797	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4363	3	S01V558019CN10255412	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4364	3	S01F55901RRC10304141	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4365	3	S01F55701RRC10252798	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4366	3	S01F55701RRC10253379	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4367	3	S01F55701RRC10253380	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4368	3	S01F55701RRC10252801	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4369	3	S01F55701RRC10252786	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4370	3	S01F55901RRC10290623	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4371	3	S01V558019CN10258177	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4372	3	S01F55701RRC10252871	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4373	3	S01F55701RRC10260424	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4374	3	S01F55701RRC10252785	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4375	3	S01F55701RRC10252873	OUT	SalesInvoice	82	2026-01-16 14:33:13.786767	1
4376	28	playstationportal00001	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4377	28	playstationportal00002	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4378	162	dualsenseedgewirelesscontroller0001	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4379	162	dualsenseedgewirelesscontroller0002	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4380	162	dualsenseedgewirelesscontroller0003	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4381	162	dualsenseedgewirelesscontroller0004	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4382	162	dualsenseedgewirelesscontroller0005	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4383	162	dualsenseedgewirelesscontroller0006	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4384	162	dualsenseedgewirelesscontroller0007	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
4385	162	dualsenseedgewirelesscontroller0008	OUT	SalesInvoice	83	2026-01-16 14:52:06.975934	1
5822	3	S01E55A01J5310266698	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5823	3	S01E55A01J5310266640	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5824	3	S01E55901J5310258737	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5825	3	S01E55A01J5310266652	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5826	3	S01E55901J5310261152	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5827	3	S01E55A01J5310261220	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5828	3	S01E55901J5310257074	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5829	3	S01E55901J5310261192	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5830	3	S01E55901J5310258738	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5831	3	S01E55901J5310258802	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5832	3	S01E55901J5310258822	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5833	3	S01E55901J5310261157	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5834	3	S01E55A01J5310266653	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5835	3	S01E55901J5310257080	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5836	3	S01E55901J5310251070	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5837	3	S01E55901J5310257041	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5838	3	S01E55901J5310258777	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5839	3	S01E55A01J5310266651	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5840	3	S01E55901J5310257042	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5841	3	S01V558019CN10258177	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5842	3	S01F55701RRC10260424	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5843	3	S01V558019CN10255412	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5844	3	S01F55701RRC10252871	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5845	3	S01F55701RRC10253380	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5846	3	S01F55701RRC10260047	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5847	3	S01V558019CN10258939	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5848	3	S01F55801RRC10263365	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5849	3	S01F55701RRC10259204	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5850	3	S01F55701RRC10252786	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5851	3	S01F55701RRC10252873	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5852	3	S01F55701RRC10252785	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5853	3	S01F55701RRC10252801	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5854	3	S01F55701RRC10253418	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5855	3	S01F55801RRC10263353	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5856	3	S01V558019CN10256717	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5857	3	S01F55701RRC10252722	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5858	3	S01F55701RRC10252874	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5859	3	S01F55801RRC10263356	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5860	3	S01F55801RRC10263364	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5861	3	S01F55701RRC10253425	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5862	3	S01F55701RRC10252869	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5863	3	S01F55901RRC10282523	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5864	3	S01F55801RRC10263355	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5865	3	S01F55901RRC10287502	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5866	3	S01F55701RRC10252798	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5867	3	S01F55901RRC10290683	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5868	3	S01V558019CN10250136	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5869	3	S01F55901RRC10290623	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5870	3	S01F55801RRC10263357	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
4430	68	356605224923694	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4431	68	355450218138897	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4432	68	353263423163911	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4433	68	355450217775111	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4434	68	358482493529307	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4435	68	359614541093337	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4436	68	358482493270399	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4437	68	355478878442325	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4438	70	353708842036635	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4439	70	356250543300421	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4440	70	350208034439278	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4441	70	356839679159534	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4442	70	355500357943893	OUT	SalesInvoice	85	2026-01-16 15:18:30.030001	1
4443	161	5WTZN9P0020BFS	OUT	SalesInvoice	86	2026-01-16 15:31:47.307393	1
4444	161	5WTZN93002545V	OUT	SalesInvoice	86	2026-01-16 15:31:47.307393	1
4445	161	5WTZN99002381Z	OUT	SalesInvoice	86	2026-01-16 15:31:47.307393	1
5871	3	S01F55701RRC10252721	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5872	3	S01F55701RRC10253396	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5873	3	S01F55801RRC10263351	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5874	3	S01F55901RRC10303746	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5875	3	S01V558019CN10256466	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5876	3	S01F55701RRC10252797	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5877	3	S01F55701RRC10253379	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5878	3	S01F55901RRC10304141	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5879	3	S01F55901RRC10289942	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5880	3	S01E456016ER10403419	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5881	3	S01E55901J5310256430	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5882	3	S01E55901J5310261191	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5883	3	S01E55901J5310258792	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5884	3	S01E55901J5310251068	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5885	3	S01E55A01J5310266654	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5886	3	S01E55A01J5310266678	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5887	3	S01E55901J5310257073	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5888	3	S01E55901J5310261178	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5889	3	S01E55901J5310258774	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5890	3	S01E55901J5310261158	IN	PurchaseInvoice	96	2026-01-22 13:02:16.28575	1
5970	3	S01E55901J5310261165	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5971	3	S01E55A01J5310266655	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
6032	3	S01E55A01J5310266640	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6033	3	S01E55901J5310258737	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6034	3	S01E55A01J5310266652	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6035	3	S01E55901J5310261152	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6036	3	S01E55A01J5310261220	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6037	3	S01E55901J5310257074	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6038	3	S01E55901J5310261192	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6039	3	S01E55901J5310258738	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6040	3	S01E55901J5310258802	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6041	3	S01E55901J5310258823	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6042	3	S01E55901J5310258779	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6043	3	S01E55A01J5310266681	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6044	3	S01E55901J5310257093	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6045	3	S01E55901J5310258770	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6046	3	S01E55A01J5310261214	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6047	3	S01E55901J5310258821	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6048	3	S01E55901J5310261165	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6049	3	S01E55A01J5310266655	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6050	3	S01E55A01J5310266639	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6051	3	S01E55A01J5310266697	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6052	3	S01E55901J5310257035	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6053	3	S01E55A01J5310261219	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6054	3	S01E55A01J5310266661	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6055	3	S01E55901J5310251067	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6056	3	S01E55901J5310261166	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6057	3	S01E55901J5310258791	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6058	3	S01E55901J5310258814	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6059	3	S01E55901J5310257079	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5891	3	S01E55A01J5310266639	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5892	3	S01E55A01J5310266697	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5893	3	S01E55901J5310257035	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5894	3	S01E55A01J5310261219	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5895	3	S01E55A01J5310266661	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5896	3	S01E55901J5310251067	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
4506	11	1581F6Z9C254D003E2UE	OUT	SalesInvoice	88	2026-01-16 15:47:18.682388	1
4507	12	1581F8PJC24BN0020ZS4	OUT	SalesInvoice	88	2026-01-16 15:47:18.682388	1
4508	12	1581F8PJC24BN00210P6	OUT	SalesInvoice	88	2026-01-16 15:47:18.682388	1
4509	12	1581F8PJC253V001H1V2	OUT	SalesInvoice	88	2026-01-16 15:47:18.682388	1
5897	3	S01E55901J5310261166	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5898	3	S01E55901J5310258791	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5899	3	S01E55901J5310258814	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5900	3	S01E55901J5310257079	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5901	3	S01E55A01J5310261213	IN	PurchaseInvoice	96	2026-01-22 13:08:47.72567	1
5972	3	S01V558019CN10258177	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5973	3	S01F55701RRC10260424	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5974	3	S01V558019CN10255412	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5975	3	S01F55701RRC10252871	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5976	3	S01F55701RRC10253380	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5977	3	S01F55701RRC10260047	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5978	3	S01V558019CN10258939	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5979	3	S01F55801RRC10263365	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5980	3	S01F55701RRC10259204	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5981	3	S01F55701RRC10252786	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5982	3	S01F55701RRC10252873	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5983	3	S01F55701RRC10252785	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5984	3	S01F55701RRC10252801	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5985	3	S01F55701RRC10253418	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5986	3	S01F55801RRC10263353	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5987	3	S01V558019CN10256717	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5988	3	S01F55701RRC10252722	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5989	3	S01F55701RRC10252874	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5990	3	S01F55801RRC10263356	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5991	3	S01F55801RRC10263364	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5992	3	S01F55701RRC10253425	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5993	3	S01F55701RRC10252869	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5994	3	S01F55901RRC10282523	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5995	3	S01F55801RRC10263355	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5996	3	S01F55901RRC10287502	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5997	3	S01F55701RRC10252798	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5998	3	S01F55901RRC10290683	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5999	3	S01V558019CN10250136	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6000	3	S01F55901RRC10290623	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6001	3	S01F55801RRC10263357	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6002	3	S01F55701RRC10252721	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6003	3	S01F55701RRC10253396	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6004	3	S01F55801RRC10263351	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6005	3	S01F55901RRC10303746	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6006	3	S01V558019CN10256466	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6007	3	S01F55701RRC10252797	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6008	3	S01F55701RRC10253379	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6009	3	S01F55901RRC10304141	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6010	3	S01F55901RRC10289942	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6011	3	S01E456016ER10403419	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6012	3	S01E55901J5310256430	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6013	3	S01E55901J5310261191	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6014	3	S01E55901J5310258792	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6015	3	S01E55901J5310251068	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6016	3	S01E55A01J5310266654	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6017	3	S01E55A01J5310266678	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6018	3	S01E55901J5310257073	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6019	3	S01E55901J5310261178	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6020	3	S01E55901J5310258774	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6021	3	S01E55901J5310261158	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6022	3	S01E55901J5310258822	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6023	3	S01E55901J5310261157	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6024	3	S01E55A01J5310266653	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6025	3	S01E55901J5310257080	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6026	3	S01E55901J5310251070	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6027	3	S01E55901J5310257041	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6028	3	S01E55901J5310258777	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6029	3	S01E55A01J5310266651	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6030	3	S01E55901J5310257042	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6031	3	S01E55A01J5310266698	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
5902	3	S01V558019CN10258177	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5903	3	S01F55701RRC10260424	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5904	3	S01V558019CN10255412	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5905	3	S01F55701RRC10252871	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5906	3	S01F55701RRC10253380	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5907	3	S01F55701RRC10260047	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5908	3	S01V558019CN10258939	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5909	3	S01F55801RRC10263365	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5910	3	S01F55701RRC10259204	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5911	3	S01F55701RRC10252786	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5912	3	S01F55701RRC10252873	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5913	3	S01F55701RRC10252785	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5914	3	S01F55701RRC10252801	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5915	3	S01F55701RRC10253418	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5916	3	S01F55801RRC10263353	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5917	3	S01V558019CN10256717	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5918	3	S01F55701RRC10252722	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5919	3	S01F55701RRC10252874	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5920	3	S01F55801RRC10263356	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5921	3	S01F55801RRC10263364	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5922	3	S01F55701RRC10253425	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5923	3	S01F55701RRC10252869	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5924	3	S01F55901RRC10282523	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5925	3	S01F55801RRC10263355	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
4602	40	2G97BMMHB601P5	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4603	40	2G97BMMHB601NY	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4604	40	2G97BMMHB600R2	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4605	40	2G97BMMHB6010Y	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4606	63	359655271258475	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4607	67	352355705267526	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4608	68	359614541291014	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4609	68	359614546386934	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4610	68	350889861168955	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4611	68	355450217194271	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4612	68	355450217184959	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4613	68	350889861022111	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4614	68	355450216932796	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4615	68	350889861204131	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4616	68	355450219567110	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4617	68	356188165309348	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4618	68	355450217081908	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4619	68	355450216993962	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4620	68	357586345419276	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4621	68	356605228262263	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4622	68	356605227911035	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4623	68	350889868314636	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4624	68	356605228190878	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4625	68	356605228798647	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4626	68	356605228254161	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4627	68	350889868063860	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4628	68	356605228327546	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4629	68	357586348805398	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4630	68	356188164272612	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4631	68	359614547089768	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4632	68	359614544913366	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4633	68	357826993263109	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4634	68	359426269639708	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4635	68	353263425398234	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4636	68	357063606283254	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4637	68	357586344621054	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4638	68	356605226470314	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4639	68	356188163896601	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4640	68	359614546774345	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4641	68	358482497669539	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4642	68	356605226216295	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4643	68	356188166134521	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4644	68	356605220228296	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4645	68	355224250266969	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4646	68	358051326418366	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4647	68	355224250070676	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4648	68	355224251542483	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4649	68	355224251493604	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4650	68	359426269498758	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4651	68	358051326069136	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4652	68	356605226024244	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4653	68	350889866041819	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4654	68	355224254052001	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4655	68	358051326306199	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4656	68	355224250889430	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4657	70	351317520845499	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4658	70	356250541701943	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4659	70	352294449552580	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4660	70	355500353647993	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4661	70	359572768921269	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4662	75	357826990550276	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4663	77	355413813310535	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4664	79	358594364461483	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4665	90	359606750181787	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4666	102	359045767346721	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4667	102	359045769093669	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4668	102	356484792035632	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4669	104	SFPXDW0F6CT	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4670	105	357550241279424	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4671	105	357550248095872	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4672	142	355852813543027	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4673	142	355852813455594	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4674	142	352700323139724	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4675	142	357020913138365	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4676	146	SC74KD030F2	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4677	146	SLJJ2LCQ36Y	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4678	151	SFF97Y7172H	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4679	151	SHFW30C4DQ0	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4680	152	358135792809040	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4681	152	355827874792937	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4682	152	355827873795535	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4683	152	358135790828976	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4684	152	353938643193174	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4685	163	SM5J2KJ4X0Q	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4686	164	FW1A31902D02	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4687	165	AFYZZ542048F7	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4688	165	AFYZZ53701D2A	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4689	166	AFVZZ53401A7C	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4690	167	SK29QKJJJWP	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4691	168	SFX9RCXGJ32	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4692	168	SFNVN41YFM6	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4693	169	359222380879988	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4694	42	SKT7QLY2H9N	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4695	42	SG170QWTJJ6	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4696	42	SDDV9XGJ76Y	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4697	42	SMC6WD6M2FP	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4698	171	SM37D7CT6GQ	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4699	170	3Z37V01H9Z02GQ	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4700	170	3Z37V03HBM007D	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4701	155	4V37W32HBM006R	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4702	155	4V0ZW26H9901XZ	IN	PurchaseInvoice	86	2026-01-17 13:42:23.577929	1
4703	68	355450217184959	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4704	68	355450219567110	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4705	68	350889861204131	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4706	68	356605228798647	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4707	68	356605228327546	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4708	68	356605228254161	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4709	68	356605227911035	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4710	68	357586345419276	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4711	68	355450217081908	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4712	68	350889861022111	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4713	68	355450216993962	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4714	68	355450217194271	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4715	68	350889868063860	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4716	68	356605228190878	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4717	68	350889868314636	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4718	68	356605228262263	OUT	SalesInvoice	89	2026-01-17 14:45:34.793499	1
4719	68	355224254052001	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4720	68	355224250070676	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4721	68	350889866041819	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4722	68	356605226024244	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4723	68	355224250266969	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4724	68	355224250889430	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4725	68	355224251493604	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4726	68	355224251542483	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4727	68	358051326069136	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4728	68	358051326418366	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4729	68	359426269498758	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4730	68	358051326306199	OUT	SalesInvoice	90	2026-01-17 14:52:08.096127	1
4731	68	350889861168955	OUT	SalesInvoice	91	2026-01-17 14:56:22.785489	1
4732	68	356188165309348	OUT	SalesInvoice	91	2026-01-17 14:56:22.785489	1
4733	68	355450216932796	OUT	SalesInvoice	91	2026-01-17 14:56:22.785489	1
4734	69	356764175496547	OUT	SalesInvoice	91	2026-01-17 14:56:22.785489	1
4735	68	359426269639708	OUT	SalesInvoice	92	2026-01-17 15:05:30.845006	1
4736	68	359614544913366	OUT	SalesInvoice	92	2026-01-17 15:05:30.845006	1
4737	68	356188163896601	OUT	SalesInvoice	92	2026-01-17 15:05:30.845006	1
4738	68	358482497669539	OUT	SalesInvoice	92	2026-01-17 15:05:30.845006	1
4739	68	357586348805398	OUT	SalesInvoice	92	2026-01-17 15:05:30.845006	1
4740	70	359572768921269	OUT	SalesInvoice	92	2026-01-17 15:05:30.845006	1
4741	68	359614546774345	OUT	SalesInvoice	93	2026-01-17 15:10:47.308627	1
4742	68	359614547089768	OUT	SalesInvoice	93	2026-01-17 15:10:47.308627	1
4743	68	356188166134521	OUT	SalesInvoice	93	2026-01-17 15:10:47.308627	1
4744	68	357063606283254	OUT	SalesInvoice	93	2026-01-17 15:10:47.308627	1
4745	68	353263425398234	OUT	SalesInvoice	93	2026-01-17 15:10:47.308627	1
4746	68	357586344621054	OUT	SalesInvoice	93	2026-01-17 15:10:47.308627	1
4747	68	356605226216295	OUT	SalesInvoice	94	2026-01-17 15:14:50.006941	1
4748	68	356188164272612	OUT	SalesInvoice	94	2026-01-17 15:14:50.006941	1
5926	3	S01F55901RRC10287502	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
4750	152	356187982541513	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4751	152	358135792809040	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4752	152	355827874792937	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4753	152	355827873795535	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4754	152	353938640357954	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4755	152	353938642157444	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4756	152	358135790828976	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4757	152	356187982623444	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4758	152	353938643193174	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4759	152	356187983034039	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4760	104	354123752650640	OUT	SalesInvoice	96	2026-01-17 15:21:31.62981	1
4761	1	starlinkv40334	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4762	1	starlinkv40335	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4763	1	starlinkv40336	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4764	1	starlinkv40337	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4765	1	starlinkv40338	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4766	1	starlinkv40339	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4767	1	starlinkv40340	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4768	1	starlinkv40341	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4769	1	starlinkv40342	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4770	1	starlinkv40343	OUT	SalesInvoice	97	2026-01-17 15:27:48.164118	1
4771	1	starlinkv40274	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4772	1	starlinkv40275	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4773	1	starlinkv40276	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4774	1	starlinkv40277	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4775	1	starlinkv40278	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4776	1	starlinkv40279	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4777	1	starlinkv40280	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4778	1	starlinkv40281	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4779	1	starlinkv40282	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4780	1	starlinkv40283	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4781	1	starlinkv40284	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4782	1	starlinkv40285	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4783	1	starlinkv40286	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4784	1	starlinkv40287	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4785	1	starlinkv40288	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4786	1	starlinkv40289	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4787	1	starlinkv40290	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4788	1	starlinkv40291	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4789	1	starlinkv40292	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4790	1	starlinkv40293	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4791	1	starlinkv40294	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4792	1	starlinkv40295	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4793	1	starlinkv40296	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4794	1	starlinkv40297	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4795	1	starlinkv40298	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4796	1	starlinkv40299	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4797	1	starlinkv40300	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4798	1	starlinkv40301	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4799	1	starlinkv40302	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4800	1	starlinkv40303	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4801	1	starlinkv40304	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4802	1	starlinkv40305	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4803	1	starlinkv40306	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4804	1	starlinkv40307	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4805	1	starlinkv40308	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4806	1	starlinkv40309	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4807	1	starlinkv40310	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4808	1	starlinkv40311	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4809	1	starlinkv40312	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4810	1	starlinkv40313	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4811	1	starlinkv40314	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4812	1	starlinkv40315	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4813	1	starlinkv40316	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4814	1	starlinkv40317	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4815	1	starlinkv40318	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4816	1	starlinkv40319	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4817	1	starlinkv40320	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4818	1	starlinkv40321	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4819	1	starlinkv40322	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4820	1	starlinkv40323	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4821	1	starlinkv40324	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4822	1	starlinkv40325	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4823	1	starlinkv40326	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4824	1	starlinkv40327	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4825	1	starlinkv40328	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4826	1	starlinkv40329	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4827	1	starlinkv40330	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4828	1	starlinkv40331	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4829	1	starlinkv40332	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4830	1	starlinkv40333	OUT	SalesInvoice	87	2026-01-17 15:53:55.870454	1
4831	4	dualsensewirelesscontroller00042	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4832	4	dualsensewirelesscontroller00043	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4833	4	711719575894	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4834	4	dualsensewirelesscontroller00038	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4835	4	dualsensewirelesscontroller00039	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4836	4	dualsensewirelesscontroller00040	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4837	4	dualsensewirelesscontroller00041	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4838	4	dualsensewirelesscontroller00031	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4839	4	dualsensewirelesscontroller00032	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4840	4	dualsensewirelesscontroller00033	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4841	4	dualsensewirelesscontroller00034	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4842	4	dualsensewirelesscontroller00035	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4843	4	dualsensewirelesscontroller00036	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4844	4	dualsensewirelesscontroller00037	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4845	4	dualsensewirelesscontroller00027	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4846	4	dualsensewirelesscontroller00028	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4847	4	dualsensewirelesscontroller00029	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4848	4	dualsensewirelesscontroller00030	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4849	4	dualsensewirelesscontroller00025	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4850	4	dualsensewirelesscontroller00026	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4851	4	dualsensewirelesscontroller00019	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4852	4	dualsensewirelesscontroller00020	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4853	4	dualsensewirelesscontroller00021	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4854	4	dualsensewirelesscontroller00022	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4855	4	dualsensewirelesscontroller00023	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4856	4	dualsensewirelesscontroller00024	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4857	4	dualsensewirelesscontroller00013	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4858	4	dualsensewirelesscontroller00014	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4859	4	dualsensewirelesscontroller00015	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4860	4	dualsensewirelesscontroller00016	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4861	4	dualsensewirelesscontroller00017	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4862	4	dualsensewirelesscontroller00018	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4863	4	dualsensewirelesscontroller00009	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4864	4	dualsensewirelesscontroller00010	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4865	4	dualsensewirelesscontroller00011	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4866	4	dualsensewirelesscontroller00012	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4867	4	dualsensewirelesscontroller00007	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4868	4	dualsensewirelesscontroller00008	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4869	4	dualsensewirelesscontroller00001	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4870	4	dualsensewirelesscontroller00002	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4871	4	dualsensewirelesscontroller00003	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4872	4	dualsensewirelesscontroller00004	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4873	4	dualsensewirelesscontroller00005	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4874	4	dualsensewirelesscontroller00006	OUT	SalesInvoice	84	2026-01-17 15:54:24.177426	1
4875	6	1581F9DEC25AK029B5VH	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4876	6	1581F9DEC25B3029PV6M	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4877	6	1581F9DEC25AQ029SBVR	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4878	6	1581F9DEC25AL029CRJ2	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4879	6	1581F9DEC25AL0294V02	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4880	6	1581F9DEC258S0292B6T	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4881	6	1581F9DEC258U0294KUU	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4882	6	1581F9DEC2592029L653	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4883	6	1581F9DEC258W029589P	OUT	SalesInvoice	98	2026-01-19 11:17:20.780916	1
4884	68	356188162226958	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4885	68	353263425436349	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4886	68	355450210206460	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4887	70	356250549929496	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4888	77	358271520542197	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4889	77	357223745708245	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4890	77	357247595058732	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4891	152	358135792056733	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4892	152	358135792481378	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4893	152	355827874494583	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4894	152	353938640453852	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4895	152	358135791751391	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4896	152	353938643033149	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4897	152	356187982019536	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4898	105	357550247373999	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4899	105	357550246083979	IN	PurchaseInvoice	87	2026-01-19 12:01:58.741437	1
4900	172	starlinkmini0001	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4901	172	starlinkmini0002	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4902	172	starlinkmini0003	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4903	172	starlinkmini0004	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4904	172	starlinkmini0005	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4905	172	starlinkmini0006	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4906	172	starlinkmini0007	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4907	172	starlinkmini0008	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4908	172	starlinkmini0009	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4909	172	starlinkmini0010	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4910	172	starlinkmini0011	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4911	172	starlinkmini0012	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4912	172	starlinkmini0013	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4913	172	starlinkmini0014	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4914	172	starlinkmini0015	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4915	172	starlinkmini0016	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4916	172	starlinkmini0017	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4917	172	starlinkmini0018	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4918	172	starlinkmini0019	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4919	172	starlinkmini0020	IN	PurchaseInvoice	88	2026-01-19 12:09:09.904573	1
4920	61	SL93Y0GWVRC	OUT	SalesInvoice	23	2026-01-19 12:22:49.854164	1
4921	99	SMH6XKV42GN	OUT	SalesInvoice	23	2026-01-19 12:22:49.854164	1
4922	126	SJWMFJKY3N4	OUT	SalesInvoice	23	2026-01-19 12:22:49.854164	1
4923	126	SL7XYP0G23D	OUT	SalesInvoice	23	2026-01-19 12:22:49.854164	1
4924	126	SG720G7T46C	OUT	SalesInvoice	23	2026-01-19 12:22:49.854164	1
4925	68	359614545075645	IN	PurchaseInvoice	89	2026-01-19 12:23:29.748252	1
4926	68	356188161941771	IN	PurchaseInvoice	89	2026-01-19 12:23:29.748252	1
4927	68	359614545075645	OUT	SalesInvoice	99	2026-01-19 12:24:40.52767	1
4928	68	356188161941771	OUT	SalesInvoice	99	2026-01-19 12:24:40.52767	1
4929	68	356188162226958	OUT	SalesInvoice	99	2026-01-19 12:24:40.52767	1
4930	68	353263425436349	OUT	SalesInvoice	99	2026-01-19 12:24:40.52767	1
4931	68	355450210206460	OUT	SalesInvoice	99	2026-01-19 12:24:40.52767	1
4932	98	SK4J0CJP9GD	OUT	SalesInvoice	100	2026-01-19 12:25:33.366416	1
4933	172	starlinkmini0001	OUT	SalesInvoice	101	2026-01-19 12:27:02.543901	1
4934	172	starlinkmini0002	OUT	SalesInvoice	101	2026-01-19 12:27:02.543901	1
4935	172	starlinkmini0003	OUT	SalesInvoice	101	2026-01-19 12:27:02.543901	1
4936	105	SH6W4PFQWCW	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4937	106	352673830520696	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4938	106	359132192725040	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4939	106	359132196544314	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4940	106	355201220205269	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4941	106	359132197678855	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4942	152	358135794723439	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4943	152	358135794112948	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4944	152	356187983372108	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4945	152	358135794483430	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4946	152	356768325047464	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4947	152	355827874116541	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4948	152	355827873857608	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4949	152	355827874060491	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4950	152	355827873912551	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4951	152	355827874548040	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4952	152	355827874619494	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4953	152	356768327697845	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4954	152	356768323955908	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4955	152	355827874735076	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4956	152	355827874760009	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4957	152	356768328441524	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4958	152	356187982445939	OUT	SalesInvoice	33	2026-01-19 12:39:44.421242	1
4959	172	starlinkmini0004	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4960	172	starlinkmini0005	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4961	172	starlinkmini0006	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4962	172	starlinkmini0007	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4963	172	starlinkmini0008	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4964	172	starlinkmini0009	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4965	172	starlinkmini0010	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4966	172	starlinkmini0011	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4967	172	starlinkmini0012	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4968	172	starlinkmini0013	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4969	172	starlinkmini0014	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4970	172	starlinkmini0016	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4971	172	starlinkmini0017	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4972	172	starlinkmini0018	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4973	172	starlinkmini0019	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4974	172	starlinkmini0020	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4975	172	starlinkmini0015	OUT	SalesInvoice	102	2026-01-19 12:39:56.941786	1
4976	70	356250549929496	OUT	SalesInvoice	103	2026-01-19 12:41:07.334818	1
4977	63	350094261697964	OUT	SalesInvoice	61	2026-01-19 12:46:06.180575	1
4978	63	350094261355704	OUT	SalesInvoice	61	2026-01-19 12:46:06.180575	1
4979	152	358135792056733	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4980	152	358135792481378	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4981	152	355827874494583	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4982	152	353938640453852	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4983	152	358135791751391	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4984	152	353938643033149	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4985	152	356187982019536	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4986	104	354123754950428	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4987	104	354123758609392	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4988	90	359606750181787	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4989	105	357550248095872	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4990	105	357550241279424	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4991	105	357550246083979	OUT	SalesInvoice	104	2026-01-19 13:08:03.724155	1
4992	68	358051321265978	OUT	SalesInvoice	66	2026-01-19 13:15:12.232145	1
4993	68	356605225057831	OUT	SalesInvoice	66	2026-01-19 13:15:12.232145	1
4994	68	350889862536879	OUT	SalesInvoice	66	2026-01-19 13:15:12.232145	1
4995	68	353263425144000	OUT	SalesInvoice	66	2026-01-19 13:15:12.232145	1
4996	68	359614544687390	OUT	SalesInvoice	66	2026-01-19 13:15:12.232145	1
4997	72	RS0290-GP0344450	OUT	SalesInvoice	105	2026-01-19 13:18:13.398329	1
4998	55	ST76N06VX9D	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
4999	56	SF7J9C4WVDW	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5000	56	SK327X51Q91	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5001	59	SGPGK00MPQ7	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5002	62	SC91KHM70VM	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5003	97	SLT21H7HQ07	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5004	100	SCLJDXQM0M5	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5005	100	SLW5X9YYFV4	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5006	100	SDHWJP7GCTQ	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5007	100	SJQ1034P73F	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5008	100	SK9HQP762LY	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5009	100	SG03VC4XHGQ	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5010	151	SDF9R6G97J0	OUT	SalesInvoice	69	2026-01-19 13:19:46.293327	1
5011	68	350889864968799	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5012	68	358051322301210	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5013	68	356188163860573	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5014	70	352190324660847	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5015	70	351317522499402	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5016	70	356250549428937	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5017	70	350208033166849	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5018	70	350208033299269	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5019	70	350208033090551	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5020	70	354956974267937	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5021	70	356661405453746	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5022	70	356250549251677	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5023	75	353263423932034	OUT	SalesInvoice	31	2026-01-19 13:22:42.299256	1
5024	54	SGVQ2RQRCMW	OUT	SalesInvoice	16	2026-01-19 13:23:41.372253	1
5025	42	SDDV9XGJ76Y	OUT	SalesInvoice	106	2026-01-19 13:41:58.301312	1
5026	42	SMC6WD6M2FP	OUT	SalesInvoice	106	2026-01-19 13:41:58.301312	1
5027	42	SG170QWTJJ6	OUT	SalesInvoice	106	2026-01-19 13:41:58.301312	1
5028	42	SKT7QLY2H9N	OUT	SalesInvoice	106	2026-01-19 13:41:58.301312	1
5029	72	RS0290-GP0344450	IN	SalesInvoice-Delete	105	2026-01-19 13:42:36.136867	1
5927	3	S01F55701RRC10252798	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5031	68	350247150243361	OUT	SalesInvoice	107	2026-01-19 14:05:15.395915	1
5928	3	S01F55901RRC10290683	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5033	68	1234	OUT	SalesInvoice	108	2026-01-19 14:24:06.340608	1
5034	68	1234	IN	PurchaseInvoice	90	2026-01-19 14:24:34.973344	1
5035	68	1234	OUT	PurchaseInvoice-Delete	90	2026-01-19 15:46:55.030483	1
5036	72	RS0290-GP0344450	OUT	SalesInvoice	109	2026-01-19 15:59:04.075787	1
5037	68	456	IN	PurchaseInvoice	91	2026-01-19 16:27:02.30062	1
5038	68	456	OUT	SalesInvoice	110	2026-01-19 16:27:19.529342	1
5039	68	456	IN	SalesInvoice-Delete	110	2026-01-19 16:31:12.046138	1
5040	68	456	OUT	PurchaseInvoice-Delete	91	2026-01-19 16:31:20.754173	1
5041	11	1581F6Z9C24AX0034Z36	OUT	SalesInvoice	111	2026-01-19 16:46:42.304788	1
5042	68	356364246005268	OUT	SalesInvoice	112	2026-01-20 10:32:09.58199	1
5043	68	356364246059356	OUT	SalesInvoice	112	2026-01-20 10:32:09.58199	1
5044	68	356364245823588	OUT	SalesInvoice	112	2026-01-20 10:32:09.58199	1
5045	68	356764176095702	OUT	SalesInvoice	112	2026-01-20 10:32:09.58199	1
5046	68	357063606855754	OUT	SalesInvoice	112	2026-01-20 10:32:09.58199	1
5047	68	356764176012640	OUT	SalesInvoice	112	2026-01-20 10:32:09.58199	1
5048	70	354956977937882	OUT	SalesInvoice	112	2026-01-20 10:32:09.58199	1
5049	6	1581F9DEC259A029V3M1	OUT	SalesInvoice	114	2026-01-20 10:35:16.27054	1
5050	6	1581F9DEC258S029B1UX	OUT	SalesInvoice	114	2026-01-20 10:35:16.27054	1
5051	6	1581F9DEC258W0291QN2	OUT	SalesInvoice	114	2026-01-20 10:35:16.27054	1
5052	6	1581F9DEC2592029S107	OUT	SalesInvoice	114	2026-01-20 10:35:16.27054	1
5053	6	1581F9DEC258W0293K3G	OUT	SalesInvoice	115	2026-01-20 10:36:54.448178	1
5054	6	1581F9DEC258H029J9SS	OUT	SalesInvoice	115	2026-01-20 10:36:54.448178	1
5055	12	1581F8PJC24BP002137K	OUT	SalesInvoice	115	2026-01-20 10:36:54.448178	1
5056	12	1581F8PJC24AK0009PEJ	OUT	SalesInvoice	115	2026-01-20 10:36:54.448178	1
5057	68	359614547064746	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5058	68	350889861054247	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5059	68	357826991518611	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5060	68	359426267055675	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5061	68	356605227683113	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5062	68	353263427011769	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5063	68	359614547846704	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5064	68	358051325062371	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5065	68	358051328034526	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5066	68	358105432135304	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5067	68	357826992298429	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5068	68	359614547271069	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5069	68	353263427557704	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5070	68	355224250996854	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5071	68	357826991408870	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5072	68	350889860529314	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5073	68	353263427193989	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5074	68	356188161706919	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5075	68	355224255457688	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5076	68	356605227703804	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5077	75	356188163093639	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5078	69	351687746863769	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5079	68	355224251427081	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5080	68	353263421628196	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5081	68	353263421777209	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5082	68	356605224108312	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5083	68	357586342264501	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5084	68	356605224177770	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5085	68	356764177275477	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5086	68	355224256513240	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5087	68	359614546797635	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5088	68	350889864418803	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5089	68	353263426675176	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5090	70	351317529884903	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5091	159	350455774515615	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5092	159	356661400563283	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5093	70	356250548298976	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5094	70	356250548267765	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5095	159	350208037479339	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5096	159	352591613065434	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5097	70	352440634381554	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5098	70	350208032986825	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5099	70	352294448173529	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5100	70	351317522022725	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5101	70	351317529770219	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5102	77	351605722195832	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5103	77	357247595304755	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5104	77	358271521457833	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5105	77	358838945990324	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5106	77	355413814844524	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5107	102	351523427089996	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5108	142	357020912351308	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5109	67	352355707588655	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5110	173	SLT2MV51QW9	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5111	173	SLW0X16LT0H	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5112	173	SC99QQYR2VX	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5113	173	SJQCD417L6T	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5114	173	SD9N903G00V	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5115	66	358112933972698	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5116	66	358112932514061	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5117	66	358112934561524	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5118	147	357153137093346	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5119	97	SD61JXRWF9J	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5120	97	SCRH444H617	IN	PurchaseInvoice	92	2026-01-20 13:11:28.297879	1
5121	68	353263421628196	OUT	SalesInvoice	116	2026-01-20 13:29:50.358818	1
5122	68	353263421777209	OUT	SalesInvoice	116	2026-01-20 13:29:50.358818	1
5929	3	S01V558019CN10250136	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5930	3	S01F55901RRC10290623	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5931	3	S01F55801RRC10263357	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5932	3	S01F55701RRC10252721	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5933	3	S01F55701RRC10253396	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5934	3	S01F55801RRC10263351	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5935	3	S01F55901RRC10303746	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5936	3	S01V558019CN10256466	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5937	3	S01F55701RRC10252797	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5938	3	S01F55701RRC10253379	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5939	3	S01F55901RRC10304141	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5134	68	358105432135304	OUT	SalesInvoice	118	2026-01-20 13:51:26.565556	1
5135	68	359426267055675	OUT	SalesInvoice	118	2026-01-20 13:51:26.565556	1
5136	68	353263427011769	OUT	SalesInvoice	118	2026-01-20 13:51:26.565556	1
5137	68	359614547271069	OUT	SalesInvoice	118	2026-01-20 13:51:26.565556	1
5138	68	353263427557704	OUT	SalesInvoice	118	2026-01-20 13:51:26.565556	1
5139	66	358112933425135	IN	PurchaseInvoice	93	2026-01-20 13:58:33.544728	1
5140	152	356768321404982	IN	PurchaseInvoice	93	2026-01-20 13:58:33.544728	1
5141	152	356187983011615	IN	PurchaseInvoice	93	2026-01-20 13:58:33.544728	1
5142	77	357223745708245	OUT	SalesInvoice	119	2026-01-20 15:03:11.278637	1
5143	77	357247595058732	OUT	SalesInvoice	119	2026-01-20 15:03:11.278637	1
5144	77	358271520542197	OUT	SalesInvoice	119	2026-01-20 15:03:11.278637	1
5145	2	S01V55601Z1L10345699	OUT	SalesInvoice	120	2026-01-20 15:36:01.510475	1
5146	68	359614546386934	OUT	SalesInvoice	95	2026-01-21 10:27:05.277866	1
5147	174	350158864209897	IN	PurchaseInvoice	94	2026-01-21 10:32:23.290091	1
5148	174	350158864209897	OUT	SalesInvoice	121	2026-01-21 10:34:07.294185	1
5940	3	S01F55901RRC10289942	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5941	3	S01E456016ER10403419	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5942	3	S01E55901J5310256430	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5943	3	S01E55901J5310261191	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5944	3	S01E55901J5310258792	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5945	3	S01E55901J5310251068	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5946	3	S01E55A01J5310266654	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5947	3	S01E55A01J5310266678	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5948	3	S01E55901J5310257073	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5160	68	359614546797635	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5161	68	350889864418803	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5162	68	356605224177770	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5163	68	358051325062371	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5164	68	350889861054247	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5165	68	359614547064746	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5166	68	357826991518611	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5167	68	357826992298429	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5168	68	358051328034526	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5169	68	355224255457688	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5170	68	359614547846704	OUT	SalesInvoice	117	2026-01-21 13:49:33.928586	1
5171	77	357247595304755	OUT	SalesInvoice	122	2026-01-21 13:58:03.42765	1
5172	77	358838945990324	OUT	SalesInvoice	122	2026-01-21 13:58:03.42765	1
5173	77	355413814844524	OUT	SalesInvoice	122	2026-01-21 13:58:03.42765	1
5174	77	351605722195832	OUT	SalesInvoice	122	2026-01-21 13:58:03.42765	1
5175	77	358271521457833	OUT	SalesInvoice	122	2026-01-21 13:58:03.42765	1
5176	68	356188161706919	OUT	SalesInvoice	123	2026-01-21 14:01:54.146155	1
5177	68	357586342264501	OUT	SalesInvoice	123	2026-01-21 14:01:54.146155	1
5178	68	355224256513240	OUT	SalesInvoice	123	2026-01-21 14:01:54.146155	1
5179	70	355122363950588	OUT	SalesInvoice	124	2026-01-21 14:05:07.97855	1
5180	12	1581F8PJC24CR0022LFH	OUT	SalesInvoice	125	2026-01-21 14:11:49.688659	1
5185	68	357826991408870	OUT	SalesInvoice	127	2026-01-21 15:50:46.691874	1
5186	77	355413813310535	OUT	SalesInvoice	128	2026-01-21 15:52:37.134583	1
5187	3	S01E55901J5310258814	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5188	3	S01E55901J5310257079	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5189	3	S01E55A01J5310261213	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5190	3	S01E55901J5310258770	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5191	3	S01E55A01J5310266639	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5192	3	S01E55A01J5310266697	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5193	3	S01E55901J5310257035	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5194	3	S01E55A01J5310261219	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5195	3	S01E55A01J5310266661	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5196	3	S01E55901J5310251067	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5197	3	S01E55901J5310261166	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5198	3	S01E55901J5310258791	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5199	3	S01E55901J5310258823	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5200	3	S01E55901J5310258779	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5201	3	S01E55A01J5310266681	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5202	3	S01E55901J5310257093	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5203	3	S01E55901J5310258824	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5204	3	S01E55A01J5310261214	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5205	3	S01E55901J5310258821	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5206	3	S01E55901J5310261165	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5207	3	S01E55A01J5310266655	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5208	3	S01E55A01J5310266698	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5209	3	S01E55A01J5310266640	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5210	3	S01E55901J5310258737	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5211	3	S01E55A01J5310266652	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5212	3	S01E55901J5310261152	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5213	3	S01E55A01J5310261220	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5214	3	S01E55901J5310257074	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5215	3	S01E55901J5310261192	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5216	3	S01E55901J5310258738	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5217	3	S01E55901J5310258802	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5218	3	S01E55901J5310258822	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5219	3	S01E55901J5310261157	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5220	3	S01E55A01J5310266653	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5221	3	S01E55901J5310257080	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5222	3	S01E55901J5310251070	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5223	3	S01E55901J5310257041	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5224	3	S01E55901J5310258777	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5225	3	S01E55A01J5310266651	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5226	3	S01E55901J5310257042	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5227	3	S01E55901J5310256430	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5228	3	S01E55901J5310261191	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5229	3	S01E55901J5310258792	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5230	3	S01E55901J5310251068	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5231	3	S01E55A01J5310266654	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5232	3	S01E55A01J5310266678	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5233	3	S01E55901J5310257073	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5234	3	S01E55901J5310261178	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5235	3	S01E55901J5310258774	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5236	3	S01E55901J5310261158	IN	PurchaseInvoice	5	2026-01-22 10:19:00.731761	1
5237	1	starlinkv40344	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5238	1	starlinkv40345	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5239	1	starlinkv40346	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5240	1	starlinkv40347	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5241	1	starlinkv40348	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5242	1	starlinkv40349	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5243	1	starlinkv40350	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5244	1	starlinkv40351	OUT	SalesInvoice	129	2026-01-22 11:21:11.182129	1
5245	6	1581F9DEC259202929ZB	OUT	SalesInvoice	130	2026-01-22 11:24:55.695106	1
5246	6	1581F9DEC258S0294XWP	OUT	SalesInvoice	130	2026-01-22 11:24:55.695106	1
5247	6	1581F9DEC25920299MLT	OUT	SalesInvoice	130	2026-01-22 11:24:55.695106	1
5248	6	1581F9DEC258W029027D	OUT	SalesInvoice	130	2026-01-22 11:24:55.695106	1
5249	1	starlinkv40352	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5250	1	starlinkv40353	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5251	1	starlinkv40354	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5252	1	starlinkv40355	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5253	1	starlinkv40356	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5254	1	starlinkv40357	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5255	1	starlinkv40358	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5256	1	starlinkv40359	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5257	1	starlinkv40360	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5258	1	starlinkv40361	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5259	1	starlinkv40362	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5260	1	starlinkv40363	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5261	1	starlinkv40364	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5262	1	starlinkv40365	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5263	1	starlinkv40366	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5264	1	starlinkv40367	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5265	1	starlinkv40368	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5266	1	starlinkv40369	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5267	1	starlinkv40370	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5268	1	starlinkv40371	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5269	1	starlinkv40372	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5270	1	starlinkv40373	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5271	1	starlinkv40374	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5272	1	starlinkv40375	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5273	1	starlinkv40376	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5274	1	starlinkv40377	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5275	1	starlinkv40378	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5276	1	starlinkv40379	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5277	1	starlinkv40380	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5278	1	starlinkv40381	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5279	1	starlinkv40382	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5280	1	starlinkv40383	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5281	1	starlinkv40384	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5282	1	starlinkv40385	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5283	1	starlinkv40386	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5284	1	starlinkv40387	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5285	1	starlinkv40388	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5286	1	starlinkv40389	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5287	1	starlinkv40390	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5288	1	starlinkv40391	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5289	1	starlinkv40392	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5290	1	starlinkv40393	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5291	1	starlinkv40394	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5292	1	starlinkv40395	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5293	1	starlinkv40396	OUT	SalesInvoice	131	2026-01-22 11:35:03.850657	1
5294	68	321	IN	PurchaseInvoice	95	2026-01-22 12:07:04.378032	1
5295	68	654	IN	PurchaseInvoice	95	2026-01-22 12:07:17.558833	1
5296	68	987	IN	PurchaseInvoice	95	2026-01-22 12:41:45.412936	1
5297	68	321	IN	PurchaseInvoice	95	2026-01-22 12:42:05.215894	1
5298	3	S01F55701RRC10252722	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5299	3	S01F55901RRC10290683	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5300	3	S01F55801RRC10263357	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5301	3	S01F55901RRC10282523	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5302	3	S01F55801RRC10263355	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5303	3	S01F55801RRC10263353	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5304	3	S01F55801RRC10263356	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5305	3	S01F55801RRC10263364	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5306	3	S01F55801RRC10263351	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5307	3	S01F55701RRC10252874	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5308	3	S01F55701RRC10252869	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5309	3	S01F55701RRC10253418	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5310	3	S01V558019CN10256717	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5311	3	S01F55701RRC10260047	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5312	3	S01F55701RRC10252721	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5313	3	S01F55701RRC10253425	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5314	3	S01F55901RRC10303746	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5315	3	S01V558019CN10256466	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5316	3	S01F55801RRC10263365	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5317	3	S01F55901RRC10287502	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5318	3	S01V558019CN10258939	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5319	3	S01F55701RRC10259204	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5320	3	S01F55901RRC10289942	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5321	3	S01F55701RRC10252797	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5322	3	S01V558019CN10255412	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5323	3	S01F55901RRC10304141	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5324	3	S01F55701RRC10252798	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5325	3	S01F55701RRC10253379	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5326	3	S01F55701RRC10253380	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5327	3	S01F55701RRC10252801	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5328	3	S01F55701RRC10252786	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5329	3	S01F55901RRC10290623	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5330	3	S01V558019CN10258177	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5331	3	S01F55701RRC10252871	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5332	3	S01F55701RRC10260424	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5333	3	S01F55701RRC10252785	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5334	3	S01F55701RRC10252873	IN	SalesInvoice-Delete	82	2026-01-22 12:44:06.888618	1
5335	3	S01F55701RRC10253396	IN	SalesInvoice-Delete	35	2026-01-22 12:44:46.967862	1
5336	3	S01V558019CN10250136	IN	SalesInvoice-Delete	35	2026-01-22 12:44:46.967862	1
5337	3	S01E55901J5310258814	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5338	3	S01E55901J5310257079	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5339	3	S01E55A01J5310261213	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5340	3	S01E55901J5310258770	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5341	3	S01E55A01J5310266639	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5342	3	S01E55A01J5310266697	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5343	3	S01E55901J5310257035	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5344	3	S01E55A01J5310261219	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5345	3	S01E55A01J5310266661	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5346	3	S01E55901J5310251067	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5347	3	S01E55901J5310261166	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5348	3	S01E55901J5310258791	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5349	3	S01E55901J5310258823	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5350	3	S01E55901J5310258779	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5351	3	S01E55A01J5310266681	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5352	3	S01E55901J5310257093	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5353	3	S01E55901J5310258824	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5354	3	S01E55A01J5310261214	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5355	3	S01E55901J5310258821	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5356	3	S01E456016ER10403419	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5357	3	ps5slimdigital00001	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5358	3	ps5slimdigital00002	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5359	3	ps5slimdigital00003	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5360	3	ps5slimdigital00004	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5361	3	ps5slimdigital00005	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5362	3	ps5slimdigital00006	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5363	3	ps5slimdigital00007	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5364	3	ps5slimdigital00008	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5365	3	ps5slimdigital00009	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5366	3	ps5slimdigital00010	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5367	3	ps5slimdigital00011	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5368	3	ps5slimdigital00012	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5369	3	ps5slimdigital00013	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5370	3	ps5slimdigital00014	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5371	3	ps5slimdigital00015	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5372	3	ps5slimdigital00016	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5373	3	ps5slimdigital00017	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5374	3	ps5slimdigital00018	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5375	3	ps5slimdigital00019	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5376	3	ps5slimdigital00020	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5377	3	ps5slimdigital00021	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5378	3	ps5slimdigital00022	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5379	3	ps5slimdigital00023	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5380	3	ps5slimdigital00024	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5381	3	ps5slimdigital00025	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5382	3	ps5slimdigital00026	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5383	3	ps5slimdigital00027	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5384	3	ps5slimdigital00028	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5385	3	ps5slimdigital00029	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5386	3	ps5slimdigital00030	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5387	3	ps5slimdigital00031	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5388	3	ps5slimdigital00032	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5389	3	ps5slimdigital00033	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5390	3	ps5slimdigital00034	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5391	3	ps5slimdigital00035	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5392	3	ps5slimdigital00036	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5393	3	ps5slimdigital00037	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5394	3	ps5slimdigital00038	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5395	3	ps5slimdigital00039	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5396	3	ps5slimdigital00040	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5397	3	ps5slimdigital00041	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5398	3	ps5slimdigital00042	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5399	3	ps5slimdigital00043	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5400	3	ps5slimdigital00044	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5401	3	ps5slimdigital00045	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5402	3	ps5slimdigital00046	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5403	3	ps5slimdigital00047	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5404	3	ps5slimdigital00048	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5405	3	ps5slimdigital00049	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5406	3	ps5slimdigital00050	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5407	3	ps5slimdigital00051	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5408	3	ps5slimdigital00052	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5409	3	ps5slimdigital00053	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5410	3	ps5slimdigital00054	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5411	3	ps5slimdigital00055	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5412	3	ps5slimdigital00056	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5413	3	ps5slimdigital00057	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5414	3	ps5slimdigital00058	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5415	3	ps5slimdigital00059	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5416	3	ps5slimdigital00060	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5417	3	ps5slimdigital00061	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5418	3	ps5slimdigital00062	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5419	3	ps5slimdigital00063	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5420	3	ps5slimdigital00064	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5421	3	ps5slimdigital00065	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5422	3	ps5slimdigital00066	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5423	3	ps5slimdigital00067	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5424	3	ps5slimdigital00068	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5425	3	ps5slimdigital00069	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5426	3	ps5slimdigital00070	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5427	3	ps5slimdigital00071	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5428	3	ps5slimdigital00072	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5429	3	ps5slimdigital00073	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5430	3	ps5slimdigital00074	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5431	3	ps5slimdigital00075	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5432	3	ps5slimdigital00076	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5433	3	ps5slimdigital00077	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5434	3	ps5slimdigital00078	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5435	3	ps5slimdigital00079	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5436	3	ps5slimdigital00080	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5437	3	ps5slimdigital00081	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5438	3	ps5slimdigital00082	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5439	3	ps5slimdigital00083	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5440	3	ps5slimdigital00084	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5441	3	ps5slimdigital00085	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5442	3	ps5slimdigital00086	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5443	3	ps5slimdigital00087	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5444	3	ps5slimdigital00088	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5445	3	ps5slimdigital00089	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5446	3	ps5slimdigital00090	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5447	3	ps5slimdigital00091	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5448	3	ps5slimdigital00092	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5449	3	ps5slimdigital00093	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5450	3	ps5slimdigital00094	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5451	3	ps5slimdigital00095	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5452	3	ps5slimdigital00096	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5453	3	ps5slimdigital00097	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5454	3	ps5slimdigital00098	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5455	3	ps5slimdigital00099	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5456	3	ps5slimdigital00100	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5457	3	ps5slimdigital00101	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5458	3	ps5slimdigital00102	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5459	3	ps5slimdigital00103	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5460	3	ps5slimdigital00104	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5461	3	ps5slimdigital00105	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5462	3	ps5slimdigital00106	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5463	3	ps5slimdigital00107	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5464	3	ps5slimdigital00108	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5465	3	ps5slimdigital00109	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5466	3	ps5slimdigital00110	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5467	3	ps5slimdigital00111	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5468	3	ps5slimdigital00112	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5469	3	ps5slimdigital00113	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5470	3	ps5slimdigital00114	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5471	3	ps5slimdigital00115	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5472	3	ps5slimdigital00116	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5473	3	ps5slimdigital00117	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5474	3	ps5slimdigital00118	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5475	3	ps5slimdigital00119	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5476	3	ps5slimdigital00120	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5477	3	ps5slimdigital00121	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5478	3	ps5slimdigital00122	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5479	3	ps5slimdigital00123	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5480	3	ps5slimdigital00124	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5481	3	ps5slimdigital00125	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5482	3	ps5slimdigital00126	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5483	3	ps5slimdigital00127	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5484	3	ps5slimdigital00128	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5485	3	ps5slimdigital00129	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5486	3	ps5slimdigital00130	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5487	3	ps5slimdigital00131	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5488	3	ps5slimdigital00132	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5489	3	ps5slimdigital00133	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5490	3	ps5slimdigital00134	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5491	3	ps5slimdigital00135	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5492	3	ps5slimdigital00136	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5493	3	ps5slimdigital00137	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5494	3	ps5slimdigital00138	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5495	3	ps5slimdigital00139	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5496	3	ps5slimdigital00140	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5497	3	ps5slimdigital00141	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5498	3	ps5slimdigital00142	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5499	3	ps5slimdigital00143	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5500	3	ps5slimdigital00144	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5501	3	ps5slimdigital00145	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5502	3	ps5slimdigital00146	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5503	3	ps5slimdigital00147	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5504	3	ps5slimdigital00148	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5505	3	ps5slimdigital00149	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5506	3	ps5slimdigital00150	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5507	3	ps5slimdigital00151	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5508	3	ps5slimdigital00152	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5509	3	ps5slimdigital00153	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5510	3	ps5slimdigital00154	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5511	3	ps5slimdigital00155	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5512	3	ps5slimdigital00156	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5513	3	ps5slimdigital00157	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5514	3	ps5slimdigital00158	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5515	3	ps5slimdigital00159	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5516	3	ps5slimdigital00160	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5517	3	ps5slimdigital00161	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5518	3	ps5slimdigital00162	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5519	3	ps5slimdigital00163	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5520	3	ps5slimdigital00164	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5521	3	ps5slimdigital00165	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5522	3	ps5slimdigital00166	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5523	3	ps5slimdigital00167	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5524	3	ps5slimdigital00168	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5525	3	ps5slimdigital00169	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5526	3	ps5slimdigital00170	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5527	3	ps5slimdigital00171	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5528	3	ps5slimdigital00172	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5529	3	ps5slimdigital00173	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5530	3	ps5slimdigital00174	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5531	3	ps5slimdigital00175	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5532	3	ps5slimdigital00176	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5533	3	ps5slimdigital00177	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5534	3	S01E55901J5310261165	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5535	3	S01E55A01J5310266655	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5536	3	S01E55A01J5310266698	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5537	3	S01E55A01J5310266640	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5538	3	S01E55901J5310258737	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5539	3	S01E55A01J5310266652	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5540	3	S01E55901J5310261152	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5541	3	S01E55A01J5310261220	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5542	3	S01E55901J5310257074	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5543	3	S01E55901J5310261192	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5544	3	S01E55901J5310258738	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5545	3	S01E55901J5310258802	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5546	3	S01E55901J5310258822	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5547	3	S01E55901J5310261157	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5548	3	S01E55A01J5310266653	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5549	3	S01E55901J5310257080	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5550	3	S01E55901J5310251070	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5551	3	S01E55901J5310257041	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5552	3	S01E55901J5310258777	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5553	3	S01E55A01J5310266651	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5554	3	S01E55901J5310257042	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5555	3	S01E55901J5310256430	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5556	3	S01E55901J5310261191	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5557	3	S01E55901J5310258792	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5558	3	S01E55901J5310251068	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5559	3	S01E55A01J5310266654	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5560	3	S01E55A01J5310266678	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5561	3	S01E55901J5310257073	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5562	3	S01E55901J5310261178	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5563	3	S01E55901J5310258774	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5564	3	S01E55901J5310261158	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5565	3	S01F55701RRC10252722	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5566	3	S01F55901RRC10282523	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5567	3	S01F55801RRC10263355	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5568	3	S01F55801RRC10263353	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5569	3	S01F55801RRC10263356	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5570	3	S01F55801RRC10263364	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5571	3	S01F55801RRC10263351	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5572	3	S01F55701RRC10252874	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5573	3	S01F55701RRC10252869	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5574	3	S01F55701RRC10253418	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5575	3	S01V558019CN10256717	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5576	3	S01F55701RRC10260047	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5577	3	S01F55701RRC10252721	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5578	3	S01F55701RRC10253396	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5579	3	S01V558019CN10250136	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5580	3	S01F55901RRC10287502	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5581	3	S01V558019CN10258939	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5582	3	S01F55701RRC10259204	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5583	3	S01F55901RRC10289942	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5584	3	S01F55901RRC10290683	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5585	3	S01F55801RRC10263357	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5586	3	S01F55701RRC10253425	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5587	3	S01F55901RRC10303746	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5588	3	S01V558019CN10256466	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5589	3	S01F55801RRC10263365	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5590	3	S01F55701RRC10252797	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5591	3	S01V558019CN10255412	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5592	3	S01F55901RRC10304141	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5593	3	S01F55701RRC10252798	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5594	3	S01F55701RRC10253379	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5595	3	S01F55701RRC10253380	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5596	3	S01F55701RRC10252801	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5597	3	S01F55701RRC10252786	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5598	3	S01F55901RRC10290623	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5599	3	S01V558019CN10258177	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5600	3	S01F55701RRC10252871	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5601	3	S01F55701RRC10260424	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5602	3	S01F55701RRC10252785	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5603	3	S01F55701RRC10252873	OUT	PurchaseInvoice-Delete	5	2026-01-22 12:45:11.749804	1
5949	3	S01E55901J5310261178	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5950	3	S01E55901J5310258774	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5951	3	S01E55901J5310261158	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5952	3	S01E55901J5310258814	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5953	3	S01E55901J5310257079	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5954	3	S01E55A01J5310266639	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5955	3	S01E55A01J5310266697	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
5956	3	S01E55901J5310257035	OUT	PurchaseInvoice-Delete	96	2026-01-22 13:09:21.854471	1
6060	3	S01E55A01J5310261213	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6061	3	ps5slimdigital00050	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6062	3	ps5slimdigital00051	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6063	3	ps5slimdigital00052	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6064	3	ps5slimdigital00053	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6065	3	ps5slimdigital00054	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6066	3	ps5slimdigital00055	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6067	3	ps5slimdigital00056	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6068	3	ps5slimdigital00057	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6069	3	ps5slimdigital00058	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6070	3	ps5slimdigital00059	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6071	3	ps5slimdigital00060	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6072	3	ps5slimdigital00061	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6073	3	ps5slimdigital00062	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6074	3	ps5slimdigital00063	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6075	3	ps5slimdigital00064	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6076	3	ps5slimdigital00065	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6077	3	ps5slimdigital00066	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6078	3	ps5slimdigital00067	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6079	3	ps5slimdigital00068	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6080	3	ps5slimdigital00069	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6081	3	ps5slimdigital00070	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6082	3	ps5slimdigital00071	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6083	3	ps5slimdigital00072	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6084	3	ps5slimdigital00073	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6085	3	ps5slimdigital00074	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6086	3	ps5slimdigital00075	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6087	3	ps5slimdigital00076	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6088	3	ps5slimdigital00077	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6089	3	ps5slimdigital00078	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6090	3	ps5slimdigital00079	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6091	3	ps5slimdigital00080	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6092	3	ps5slimdigital00081	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6093	3	ps5slimdigital00082	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6094	3	ps5slimdigital00083	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6095	3	ps5slimdigital00084	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6096	3	ps5slimdigital00085	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6097	3	ps5slimdigital00086	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6098	3	ps5slimdigital00087	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6099	3	ps5slimdigital00088	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6100	3	ps5slimdigital00089	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6101	3	ps5slimdigital00090	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6102	3	ps5slimdigital00091	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6103	3	ps5slimdigital00092	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6104	3	ps5slimdigital00093	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6105	3	ps5slimdigital00094	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6106	3	ps5slimdigital00095	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6107	3	ps5slimdigital00096	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6108	3	ps5slimdigital00097	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6109	3	ps5slimdigital00098	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6110	3	ps5slimdigital00099	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6111	3	ps5slimdigital00100	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6112	3	ps5slimdigital00101	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6113	3	ps5slimdigital00102	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6114	3	ps5slimdigital00103	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6115	3	ps5slimdigital00104	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6116	3	ps5slimdigital00105	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6117	3	ps5slimdigital00106	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6118	3	ps5slimdigital00107	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6119	3	ps5slimdigital00108	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6120	3	ps5slimdigital00109	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6121	3	ps5slimdigital00110	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6122	3	ps5slimdigital00111	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6123	3	ps5slimdigital00112	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6124	3	ps5slimdigital00113	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6125	3	ps5slimdigital00114	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6126	3	ps5slimdigital00115	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6127	3	ps5slimdigital00116	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6128	3	ps5slimdigital00117	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6129	3	ps5slimdigital00118	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6130	3	ps5slimdigital00119	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6131	3	ps5slimdigital00120	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6132	3	ps5slimdigital00121	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6133	3	ps5slimdigital00122	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6134	3	ps5slimdigital00123	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6135	3	ps5slimdigital00124	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6136	3	ps5slimdigital00125	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6137	3	ps5slimdigital00126	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6138	3	ps5slimdigital00127	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6139	3	ps5slimdigital00128	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6140	3	ps5slimdigital00129	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6141	3	ps5slimdigital00130	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6142	3	ps5slimdigital00131	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6143	3	ps5slimdigital00132	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6144	3	ps5slimdigital00133	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6145	3	ps5slimdigital00134	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6146	3	ps5slimdigital00135	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6147	3	ps5slimdigital00136	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6148	3	ps5slimdigital00137	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6149	3	ps5slimdigital00138	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6150	3	ps5slimdigital00139	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6151	3	ps5slimdigital00140	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6152	3	ps5slimdigital00141	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6153	3	ps5slimdigital00142	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6154	3	ps5slimdigital00143	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6155	3	ps5slimdigital00144	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6156	3	ps5slimdigital00145	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6157	3	ps5slimdigital00146	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6158	3	ps5slimdigital00147	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6159	3	ps5slimdigital00148	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6160	3	ps5slimdigital00149	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6161	3	ps5slimdigital00150	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6162	3	ps5slimdigital00151	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6163	3	ps5slimdigital00152	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6164	3	ps5slimdigital00153	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6165	3	ps5slimdigital00154	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6166	3	ps5slimdigital00155	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6167	3	ps5slimdigital00156	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6168	3	ps5slimdigital00157	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6169	3	ps5slimdigital00158	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6170	3	ps5slimdigital00159	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6171	3	ps5slimdigital00160	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6172	3	ps5slimdigital00161	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6173	3	ps5slimdigital00162	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6174	3	ps5slimdigital00163	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6175	3	ps5slimdigital00164	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6176	3	ps5slimdigital00165	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6177	3	ps5slimdigital00166	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6178	3	ps5slimdigital00167	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6179	3	ps5slimdigital00168	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6180	3	ps5slimdigital00169	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6181	3	ps5slimdigital00170	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6182	3	ps5slimdigital00171	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6183	3	ps5slimdigital00172	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6184	3	ps5slimdigital00173	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6185	3	ps5slimdigital00174	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6186	3	ps5slimdigital00175	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6187	3	ps5slimdigital00176	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6188	3	ps5slimdigital00177	IN	PurchaseInvoice	97	2026-01-22 13:09:48.828873	1
6189	3	S01E55A01J5310266698	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6190	3	S01E55A01J5310266640	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6191	3	S01E55901J5310258737	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6192	3	S01E55A01J5310266652	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6193	3	S01E55901J5310261152	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6194	3	S01E55A01J5310261220	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6195	3	S01E55901J5310257074	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6196	3	S01E55901J5310261192	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6197	3	S01E55901J5310258738	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6198	3	S01E55901J5310258802	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6199	3	S01E55901J5310258822	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6200	3	S01E55901J5310261157	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6201	3	S01E55A01J5310266653	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6202	3	S01E55901J5310257080	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6203	3	S01E55901J5310251070	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6204	3	S01E55901J5310257041	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6205	3	S01E55901J5310258777	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6206	3	S01E55A01J5310266651	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6207	3	S01E55901J5310257042	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6208	3	S01V558019CN10258177	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6209	3	S01F55701RRC10260424	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6210	3	S01V558019CN10255412	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6211	3	S01F55701RRC10252871	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6212	3	S01F55701RRC10253380	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6213	3	S01F55701RRC10260047	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6214	3	S01V558019CN10258939	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6215	3	S01F55801RRC10263365	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6216	3	S01F55701RRC10259204	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6217	3	S01F55701RRC10252786	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6218	3	S01F55701RRC10252873	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6219	3	S01F55701RRC10252785	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6220	3	S01F55701RRC10252801	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6221	3	S01F55701RRC10253418	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6222	3	S01F55801RRC10263353	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6223	3	S01V558019CN10256717	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6224	3	S01F55701RRC10252722	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6225	3	S01F55701RRC10252874	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6226	3	S01F55801RRC10263356	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6227	3	S01F55801RRC10263364	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6228	3	S01F55701RRC10253425	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6229	3	S01F55701RRC10252869	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6230	3	S01F55901RRC10282523	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6231	3	S01F55801RRC10263355	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6232	3	S01F55901RRC10287502	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6233	3	S01F55701RRC10252798	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6234	3	S01F55901RRC10290683	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6235	3	S01V558019CN10250136	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6236	3	S01F55901RRC10290623	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6237	3	S01F55801RRC10263357	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6238	3	S01F55701RRC10252721	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6239	3	S01F55701RRC10253396	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6240	3	S01F55801RRC10263351	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6241	3	S01F55901RRC10303746	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6242	3	S01V558019CN10256466	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6243	3	S01F55701RRC10252797	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6244	3	S01F55701RRC10253379	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6245	3	S01F55901RRC10304141	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6246	3	S01F55901RRC10289942	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6247	3	S01E456016ER10403419	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6248	3	S01E55901J5310256430	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6249	3	S01E55901J5310261191	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6250	3	S01E55901J5310258792	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6251	3	S01E55901J5310251068	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6252	3	S01E55A01J5310266654	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6253	3	S01E55A01J5310266678	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6254	3	S01E55901J5310257073	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6255	3	S01E55901J5310261178	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6256	3	S01E55901J5310258774	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6257	3	S01E55901J5310261158	IN	PurchaseInvoice	97	2026-01-22 13:13:37.759633	1
6258	3	S01E55A01J5310266698	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6259	3	S01E55A01J5310266640	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6260	3	S01E55901J5310258821	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6261	3	S01E55901J5310261165	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6262	3	S01E55A01J5310266655	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6263	3	S01E55901J5310258737	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6264	3	S01E55A01J5310266652	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6265	3	S01E55901J5310261152	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6266	3	S01E55A01J5310261220	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6267	3	S01E55901J5310257074	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6268	3	S01E55901J5310261192	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6269	3	S01E55901J5310258738	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6270	3	S01E55901J5310258802	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6271	3	S01E55901J5310258822	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6272	3	S01E55901J5310261157	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6273	3	S01E55A01J5310266653	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6274	3	S01E55901J5310257080	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6275	3	S01E55901J5310251070	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6276	3	S01E55901J5310257041	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6277	3	S01E55901J5310258777	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6278	3	S01E55A01J5310266651	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6279	3	S01E55901J5310257042	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6280	3	S01V558019CN10258177	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6281	3	S01F55701RRC10260424	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6282	3	S01V558019CN10255412	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6283	3	S01F55701RRC10252871	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6284	3	S01F55701RRC10253380	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6285	3	S01F55701RRC10260047	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6286	3	S01V558019CN10258939	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6287	3	S01F55801RRC10263365	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6288	3	S01F55701RRC10259204	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6289	3	S01F55701RRC10252786	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6290	3	S01F55701RRC10252873	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6291	3	S01F55701RRC10252785	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6292	3	S01F55701RRC10252801	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6293	3	S01F55701RRC10253418	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6294	3	S01F55801RRC10263353	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6295	3	S01V558019CN10256717	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6296	3	S01F55701RRC10252722	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6297	3	S01F55701RRC10252874	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6298	3	S01F55801RRC10263356	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6299	3	S01F55801RRC10263364	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6300	3	S01F55701RRC10253425	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6301	3	S01F55701RRC10252869	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6302	3	S01F55901RRC10282523	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6303	3	S01F55801RRC10263355	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6304	3	S01F55901RRC10287502	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6305	3	S01F55701RRC10252798	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6306	3	S01F55901RRC10290683	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6307	3	S01V558019CN10250136	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6308	3	S01F55901RRC10290623	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6309	3	S01F55801RRC10263357	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6310	3	S01F55701RRC10252721	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6311	3	S01F55701RRC10253396	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6312	3	S01F55801RRC10263351	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6313	3	S01F55901RRC10303746	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6314	3	S01V558019CN10256466	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6315	3	S01F55701RRC10252797	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6316	3	S01F55701RRC10253379	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6317	3	S01F55901RRC10304141	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6318	3	S01F55901RRC10289942	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6319	3	S01E456016ER10403419	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6320	3	S01E55901J5310256430	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6321	3	S01E55901J5310261191	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6322	3	S01E55901J5310258792	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6323	3	S01E55901J5310251068	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6324	3	S01E55A01J5310266654	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6325	3	S01E55A01J5310266678	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6326	3	S01E55901J5310257073	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6327	3	S01E55901J5310261178	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6328	3	S01E55901J5310258774	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6329	3	S01E55901J5310261158	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6330	3	S01E55901J5310258823	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6331	3	S01E55901J5310258779	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6332	3	S01E55A01J5310266681	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6333	3	S01E55901J5310257093	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6334	3	S01E55901J5310258770	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6335	3	S01E55A01J5310261214	OUT	PurchaseInvoice-Delete	97	2026-01-22 13:13:57.662873	1
6337	3	S01V558019CN10258177	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6338	3	S01F55701RRC10260424	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6339	3	S01V558019CN10255412	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6340	3	S01F55701RRC10252871	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6341	3	S01F55701RRC10253380	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6342	3	S01F55701RRC10260047	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6343	3	S01V558019CN10258939	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6344	3	S01F55801RRC10263365	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6345	3	S01F55701RRC10259204	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6346	3	S01F55701RRC10252786	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6347	3	S01F55701RRC10252873	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6348	3	S01F55701RRC10252785	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6349	3	S01F55701RRC10252801	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6350	3	S01F55701RRC10253418	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6351	3	S01F55801RRC10263353	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6352	3	S01V558019CN10256717	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6353	3	S01F55701RRC10252722	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6354	3	S01F55701RRC10252874	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6355	3	S01F55801RRC10263356	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6356	3	S01F55801RRC10263364	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6357	3	S01F55701RRC10253425	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6358	3	S01F55701RRC10252869	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6359	3	S01F55901RRC10282523	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6360	3	S01F55801RRC10263355	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6361	3	S01F55901RRC10287502	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6362	3	S01F55701RRC10252798	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6363	3	S01F55901RRC10290683	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6364	3	S01V558019CN10250136	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6365	3	S01F55901RRC10290623	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6366	3	S01F55801RRC10263357	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6367	3	S01F55701RRC10252721	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6368	3	S01F55701RRC10253396	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6369	3	S01F55801RRC10263351	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6370	3	S01F55901RRC10303746	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6371	3	S01V558019CN10256466	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6372	3	S01F55701RRC10252797	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6373	3	S01F55701RRC10253379	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6374	3	S01F55901RRC10304141	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6375	3	S01F55901RRC10289942	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6376	3	S01E456016ER10403419	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6377	3	S01E55901J5310256430	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6378	3	S01E55901J5310261191	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6379	3	S01E55901J5310258792	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6380	3	S01E55901J5310251068	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6381	3	S01E55A01J5310266654	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6382	3	S01E55A01J5310266678	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6383	3	S01E55901J5310257073	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6384	3	S01E55901J5310261178	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6385	3	S01E55901J5310258774	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6386	3	S01E55901J5310261158	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6387	3	S01E55901J5310258822	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6388	3	S01E55901J5310261157	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6389	3	S01E55A01J5310266653	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6390	3	S01E55901J5310257080	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6391	3	S01E55901J5310251070	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6392	3	S01E55901J5310257041	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6393	3	S01E55901J5310258777	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6394	3	S01E55A01J5310266651	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6395	3	S01E55901J5310257042	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6396	3	S01E55A01J5310266698	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6397	3	S01E55A01J5310266640	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6398	3	S01E55901J5310258737	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6399	3	S01E55A01J5310266652	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6400	3	S01E55901J5310261152	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6401	3	S01E55A01J5310261220	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6402	3	S01E55901J5310257074	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6403	3	S01E55901J5310261192	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6404	3	S01E55901J5310258738	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6405	3	S01E55901J5310258802	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6406	3	S01E55901J5310258823	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6407	3	S01E55901J5310258779	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6408	3	S01E55A01J5310266681	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6409	3	S01E55901J5310257093	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6410	3	S01E55901J5310258770	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6411	3	S01E55A01J5310261214	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6412	3	S01E55901J5310258821	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6413	3	S01E55901J5310261165	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6414	3	S01E55A01J5310266655	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6415	3	S01E55A01J5310266639	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6416	3	S01E55A01J5310266697	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6417	3	S01E55901J5310257035	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6418	3	S01E55A01J5310261219	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6419	3	S01E55A01J5310266661	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6420	3	S01E55901J5310251067	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6421	3	S01E55901J5310261166	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6422	3	S01E55901J5310258791	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6423	3	S01E55901J5310258814	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6424	3	S01E55901J5310257079	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6425	3	S01E55A01J5310261213	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6426	3	ps5slimdigital00050	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6427	3	ps5slimdigital00051	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6428	3	ps5slimdigital00052	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6429	3	ps5slimdigital00053	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6430	3	ps5slimdigital00054	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6431	3	ps5slimdigital00055	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6432	3	ps5slimdigital00056	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6433	3	ps5slimdigital00057	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6434	3	ps5slimdigital00058	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6435	3	ps5slimdigital00059	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6436	3	ps5slimdigital00060	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6437	3	ps5slimdigital00061	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6438	3	ps5slimdigital00062	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6439	3	ps5slimdigital00063	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6440	3	ps5slimdigital00064	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6441	3	ps5slimdigital00065	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6442	3	ps5slimdigital00066	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6443	3	ps5slimdigital00067	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6444	3	ps5slimdigital00068	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6445	3	ps5slimdigital00069	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6446	3	ps5slimdigital00070	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6447	3	ps5slimdigital00071	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6448	3	ps5slimdigital00072	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6449	3	ps5slimdigital00073	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6450	3	ps5slimdigital00074	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6451	3	ps5slimdigital00075	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6452	3	ps5slimdigital00076	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6453	3	ps5slimdigital00077	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6454	3	ps5slimdigital00078	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6455	3	ps5slimdigital00079	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6456	3	ps5slimdigital00080	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6457	3	ps5slimdigital00081	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6458	3	ps5slimdigital00082	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6459	3	ps5slimdigital00083	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6460	3	ps5slimdigital00084	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6461	3	ps5slimdigital00085	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6462	3	ps5slimdigital00086	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6463	3	ps5slimdigital00087	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6464	3	ps5slimdigital00088	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6465	3	ps5slimdigital00089	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6466	3	ps5slimdigital00090	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6467	3	ps5slimdigital00091	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6468	3	ps5slimdigital00092	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6469	3	ps5slimdigital00093	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6470	3	ps5slimdigital00094	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6471	3	ps5slimdigital00095	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6472	3	ps5slimdigital00096	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6473	3	ps5slimdigital00097	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6474	3	ps5slimdigital00098	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6475	3	ps5slimdigital00099	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6476	3	ps5slimdigital00100	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6477	3	ps5slimdigital00101	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6478	3	ps5slimdigital00102	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6479	3	ps5slimdigital00103	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6480	3	ps5slimdigital00104	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6481	3	ps5slimdigital00105	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6482	3	ps5slimdigital00106	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6483	3	ps5slimdigital00107	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6484	3	ps5slimdigital00108	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6485	3	ps5slimdigital00109	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6486	3	ps5slimdigital00110	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6487	3	ps5slimdigital00111	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6488	3	ps5slimdigital00112	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6489	3	ps5slimdigital00113	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6490	3	ps5slimdigital00114	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6491	3	ps5slimdigital00115	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6492	3	ps5slimdigital00116	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6493	3	ps5slimdigital00117	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6494	3	ps5slimdigital00118	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6495	3	ps5slimdigital00119	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6496	3	ps5slimdigital00120	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6497	3	ps5slimdigital00121	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6498	3	ps5slimdigital00122	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6499	3	ps5slimdigital00123	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6500	3	ps5slimdigital00124	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6501	3	ps5slimdigital00125	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6502	3	ps5slimdigital00126	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6503	3	ps5slimdigital00127	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6504	3	ps5slimdigital00128	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6505	3	ps5slimdigital00129	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6506	3	ps5slimdigital00130	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6507	3	ps5slimdigital00131	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6508	3	ps5slimdigital00132	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6509	3	ps5slimdigital00133	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6510	3	ps5slimdigital00134	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6511	3	ps5slimdigital00135	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6512	3	ps5slimdigital00136	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6513	3	ps5slimdigital00137	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6514	3	ps5slimdigital00138	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6515	3	ps5slimdigital00139	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6516	3	ps5slimdigital00140	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6517	3	ps5slimdigital00141	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6518	3	ps5slimdigital00142	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6519	3	ps5slimdigital00143	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6520	3	ps5slimdigital00144	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6521	3	ps5slimdigital00145	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6522	3	ps5slimdigital00146	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6523	3	ps5slimdigital00147	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6524	3	ps5slimdigital00148	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6525	3	ps5slimdigital00149	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6526	3	ps5slimdigital00150	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6527	3	ps5slimdigital00151	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6528	3	ps5slimdigital00152	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6529	3	ps5slimdigital00153	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6530	3	ps5slimdigital00154	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6531	3	ps5slimdigital00155	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6532	3	ps5slimdigital00156	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6533	3	ps5slimdigital00157	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6534	3	ps5slimdigital00158	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6535	3	ps5slimdigital00159	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6536	3	ps5slimdigital00160	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6537	3	ps5slimdigital00161	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6538	3	ps5slimdigital00162	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6539	3	ps5slimdigital00163	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6540	3	ps5slimdigital00164	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6541	3	ps5slimdigital00165	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6542	3	ps5slimdigital00166	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6543	3	ps5slimdigital00167	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6544	3	ps5slimdigital00168	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6545	3	ps5slimdigital00169	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6546	3	ps5slimdigital00170	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6547	3	ps5slimdigital00171	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6548	3	ps5slimdigital00172	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6549	3	ps5slimdigital00173	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6550	3	ps5slimdigital00174	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6551	3	ps5slimdigital00175	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6552	3	ps5slimdigital00176	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6553	3	ps5slimdigital00177	IN	PurchaseInvoice	98	2026-01-22 13:14:44.041247	1
6554	3	S01F55701RRC10252722	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6555	3	S01F55901RRC10290683	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6556	3	S01F55801RRC10263357	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6557	3	S01F55901RRC10282523	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6558	3	S01F55801RRC10263355	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6559	3	S01F55801RRC10263353	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6560	3	S01F55801RRC10263356	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6561	3	S01F55801RRC10263364	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6562	3	S01F55801RRC10263351	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6563	3	S01F55701RRC10252874	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6564	3	S01F55701RRC10252869	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6565	3	S01F55701RRC10253418	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6566	3	S01V558019CN10256717	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6567	3	S01F55701RRC10260047	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6568	3	S01F55701RRC10252721	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6569	3	S01F55701RRC10253425	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6570	3	S01F55901RRC10303746	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6571	3	S01V558019CN10256466	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6572	3	S01F55801RRC10263365	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6573	3	S01F55901RRC10287502	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6574	3	S01V558019CN10258939	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6575	3	S01F55701RRC10259204	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6576	3	S01F55901RRC10289942	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6577	3	S01F55701RRC10252797	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6578	3	S01V558019CN10255412	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6579	3	S01F55901RRC10304141	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6580	3	S01F55701RRC10252798	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6581	3	S01F55701RRC10253379	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6582	3	S01F55701RRC10253380	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6583	3	S01F55701RRC10252801	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6584	3	S01F55701RRC10252786	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6585	3	S01F55901RRC10290623	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6586	3	S01V558019CN10258177	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6587	3	S01F55701RRC10252871	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6588	3	S01F55701RRC10260424	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6589	3	S01F55701RRC10252785	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6590	3	S01F55701RRC10252873	OUT	SalesInvoice	133	2026-01-22 13:20:02.886221	1
6591	3	S01F55701RRC10253396	OUT	SalesInvoice	134	2026-01-22 13:22:05.385374	1
6592	3	S01V558019CN10250136	OUT	SalesInvoice	134	2026-01-22 13:22:05.385374	1
6596	2	S01E45601CE810570281	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6597	2	S01E45601CE810595951	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6598	2	S01E45601CE810570323	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6599	2	S01E45601CE810573044	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6600	2	S01E45601CE810565094	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6601	2	S01E45601CE810573039	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6602	2	S01E45501CE810557417	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6603	2	S01F44C01NXM10424000	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6604	2	S01E45601CE810599344	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6605	2	S01E45601CE810573040	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6606	2	S01E45601CE810573043	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6607	2	S01E45601CE810599343	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6608	2	S01E45601CE810565069	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6609	2	S01F55901DR210321979	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6610	2	S01E45601CE810585832	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6611	2	S01F55801DR210266420	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6612	2	S01E45601CE810576101	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6613	2	S01E45601CE810580025	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6614	2	S01E45601CE810578019	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6615	2	S01E45601CE810578011	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6616	2	S01E45601CE810576162	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6617	2	ps5slim00001	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6618	2	ps5slim00002	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6619	2	ps5slim00003	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6620	2	ps5slim00004	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6621	2	ps5slim00005	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6622	2	ps5slim00006	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6623	2	ps5slim00007	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6624	2	ps5slim00008	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6625	2	ps5slim00009	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6626	2	ps5slim00010	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6627	2	ps5slim00011	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6628	2	ps5slim00012	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6629	2	ps5slim00013	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6630	2	ps5slim00014	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6631	2	ps5slim00015	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6632	2	ps5slim00016	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6633	2	ps5slim00017	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6634	2	ps5slim00018	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6635	2	ps5slim00019	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6636	2	ps5slim00020	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6637	2	ps5slim00021	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6638	2	ps5slim00022	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6639	2	ps5slim00023	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6640	2	ps5slim00024	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6641	2	ps5slim00025	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6642	2	ps5slim00026	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6643	2	ps5slim00027	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6644	2	ps5slim00028	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6645	2	ps5slim00029	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6646	2	ps5slim00030	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6647	2	ps5slim00031	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6648	2	ps5slim00032	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6649	2	ps5slim00033	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6650	2	ps5slim00034	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6651	2	ps5slim00035	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6652	2	ps5slim00036	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6653	2	ps5slim00037	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6654	2	ps5slim00038	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6655	2	ps5slim00039	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6656	2	ps5slim00040	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6657	2	ps5slim00041	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6658	2	ps5slim00042	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6659	2	ps5slim00043	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6660	2	ps5slim00044	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6661	2	ps5slim00045	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6662	2	ps5slim00046	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6663	2	ps5slim00047	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6664	2	ps5slim00048	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6665	2	ps5slim00049	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6666	2	ps5slim00050	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6667	2	ps5slim00051	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6668	2	ps5slim00052	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6669	2	ps5slim00053	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6670	2	ps5slim00054	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6671	2	ps5slim00055	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6672	2	ps5slim00056	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6673	2	ps5slim00057	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6674	2	ps5slim00058	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6675	2	ps5slim00059	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6676	2	ps5slim00060	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6677	2	ps5slim00061	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6678	2	ps5slim00062	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6679	2	ps5slim00063	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6680	2	ps5slim00064	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6681	2	ps5slim00065	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6682	2	ps5slim00066	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6683	2	ps5slim00067	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6684	2	ps5slim00068	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6685	2	ps5slim00069	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6686	2	ps5slim00070	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6687	2	ps5slim00071	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6688	2	ps5slim00072	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6689	2	ps5slim00073	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6690	2	ps5slim00074	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6691	2	ps5slim00075	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6692	2	ps5slim00076	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6693	2	ps5slim00077	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6694	2	ps5slim00078	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6695	2	ps5slim00079	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6696	2	ps5slim00080	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6697	2	ps5slim00081	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6698	2	ps5slim00082	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6699	2	ps5slim00083	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6700	2	ps5slim00084	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6701	2	ps5slim00085	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6702	2	ps5slim00086	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6703	2	ps5slim00087	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6704	2	ps5slim00088	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6705	2	ps5slim00089	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6706	2	ps5slim00090	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6707	2	ps5slim00091	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6708	2	ps5slim00092	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6709	2	ps5slim00093	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6710	2	ps5slim00094	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6711	2	ps5slim00095	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6712	2	ps5slim00096	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6713	2	ps5slim00097	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6714	2	ps5slim00098	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6715	2	ps5slim00099	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6716	2	ps5slim00100	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6717	2	ps5slim00101	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6718	2	ps5slim00102	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6719	2	ps5slim00103	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6720	2	ps5slim00104	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6721	2	ps5slim00105	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6722	2	ps5slim00106	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6723	2	ps5slim00107	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6724	2	ps5slim00108	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6725	2	ps5slim00109	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6726	2	ps5slim00110	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6727	2	ps5slim00111	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6728	2	ps5slim00112	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6729	2	ps5slim00113	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6730	2	ps5slim00114	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6731	2	ps5slim00115	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6732	2	ps5slim00116	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6733	2	ps5slim00117	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6734	2	ps5slim00118	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6735	2	ps5slim00119	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6736	2	ps5slim00120	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6737	2	ps5slim00121	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6738	2	ps5slim00122	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6739	2	ps5slim00123	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6740	2	ps5slim00124	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6741	2	ps5slim00125	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6742	2	S01E45601CE810572356	OUT	PurchaseInvoice-Delete	4	2026-01-22 13:40:24.937043	1
6743	2	S01E45601CE810572356	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6744	2	S01E45601CE810570281	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6745	2	S01E45601CE810595951	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6746	2	S01E45601CE810570323	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6747	2	S01E45601CE810573044	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6748	2	S01E45601CE810565094	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6749	2	S01E45601CE810573039	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6750	2	S01E45501CE810557417	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6751	2	S01F44C01NXM10424000	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6752	2	S01E45601CE810599344	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6753	2	S01E45601CE810573040	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6754	2	S01E45601CE810573043	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6755	2	S01E45601CE810599343	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6756	2	S01E45601CE810565069	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6757	2	S01F55901DR210321979	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6758	2	S01E45601CE810585832	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6759	2	S01F55801DR210266420	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6760	2	S01E45601CE810576101	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6761	2	S01E45601CE810580025	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6762	2	S01E45601CE810578019	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6763	2	S01E45601CE810578011	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6764	2	S01E45601CE810576162	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6765	2	S01F55901DR210294300	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6766	2	S01F55901DR210295627	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6767	2	S01F55901DR210294297	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6768	2	S01F55901DR210295628	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6769	2	S01F55901DR210294298	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6770	2	S01F55901DR210291093	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6771	2	S01F55901DR210307406	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6772	2	S01F55901DR210312178	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6773	2	S01F55901DR210291063	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6774	2	S01F55901DR210308751	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6775	2	S01F55901DR210308695	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6776	2	S01F55901DR210324687	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6777	2	S01F55901DR210307410	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6778	2	S01F55701DR210256752	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6779	2	S01F55901DR210307414	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6780	2	S01F55901DR210307409	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6781	2	S01F55701DR210256751	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6782	2	S01F55901DR210308722	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6783	2	S01F55901DR210307418	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6784	2	S01F55901DR210307417	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6785	2	S01F55901DR210309768	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6786	2	S01F55901DR210307389	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6787	2	S01F55901DR210307390	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6788	2	S01F55901DR210294799	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6789	2	S01F55901DR210308752	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6790	2	S01F55901DR210307405	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6791	2	S01F55901DR210294345	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6792	2	S01F55901DR210312177	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6793	2	S01F55901DR210307413	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6794	2	S01F55901DR210308942	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6795	2	S01F55901DR210308676	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6796	2	S01F55901DR210294299	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6797	2	S01F55901DR210308710	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6798	2	S01F55901DR210308696	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6799	2	S01F55901DR210295652	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6800	2	S01F55901DR210312011	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6801	2	S01F55901DR210308931	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6802	2	S01F55901DR210294788	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6803	2	ps5slim00039	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6804	2	ps5slim00040	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6805	2	ps5slim00041	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6806	2	ps5slim00042	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6807	2	ps5slim00043	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6808	2	ps5slim00044	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6809	2	ps5slim00045	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6810	2	ps5slim00046	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6811	2	ps5slim00047	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6812	2	ps5slim00048	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6813	2	ps5slim00049	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6814	2	ps5slim00050	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6815	2	ps5slim00051	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6816	2	ps5slim00052	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6817	2	ps5slim00053	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6818	2	ps5slim00054	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6819	2	ps5slim00055	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6820	2	ps5slim00056	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6821	2	ps5slim00057	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6822	2	ps5slim00058	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6823	2	ps5slim00059	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6824	2	ps5slim00060	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6825	2	ps5slim00061	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6826	2	ps5slim00062	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6827	2	ps5slim00063	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6828	2	ps5slim00064	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6829	2	ps5slim00065	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6830	2	ps5slim00066	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6831	2	ps5slim00067	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6832	2	ps5slim00068	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6833	2	ps5slim00069	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6834	2	ps5slim00070	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6835	2	ps5slim00071	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6836	2	ps5slim00072	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6837	2	ps5slim00073	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6838	2	ps5slim00074	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6839	2	ps5slim00075	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6840	2	ps5slim00076	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6841	2	ps5slim00077	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6842	2	ps5slim00078	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6843	2	ps5slim00079	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6844	2	ps5slim00080	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6845	2	ps5slim00081	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6846	2	ps5slim00082	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6847	2	ps5slim00083	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6848	2	ps5slim00084	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6849	2	ps5slim00085	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6850	2	ps5slim00086	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6851	2	ps5slim00087	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6852	2	ps5slim00088	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6853	2	ps5slim00089	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6854	2	ps5slim00090	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6855	2	ps5slim00091	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6856	2	ps5slim00092	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6857	2	ps5slim00093	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6858	2	ps5slim00094	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6859	2	ps5slim00095	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6860	2	ps5slim00096	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6861	2	ps5slim00097	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6862	2	ps5slim00098	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6863	2	ps5slim00099	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6864	2	ps5slim00100	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6865	2	ps5slim00101	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6866	2	ps5slim00102	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6867	2	ps5slim00103	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6868	2	ps5slim00104	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6869	2	ps5slim00105	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6870	2	ps5slim00106	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6871	2	ps5slim00107	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6872	2	ps5slim00108	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6873	2	ps5slim00109	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6874	2	ps5slim00110	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6875	2	ps5slim00111	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6876	2	ps5slim00112	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6877	2	ps5slim00113	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6878	2	ps5slim00114	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6879	2	ps5slim00115	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6880	2	ps5slim00116	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6881	2	ps5slim00117	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6882	2	ps5slim00118	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6883	2	ps5slim00119	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6884	2	ps5slim00120	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6885	2	ps5slim00121	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6886	2	ps5slim00122	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6887	2	ps5slim00123	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6888	2	ps5slim00124	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6889	2	ps5slim00125	IN	PurchaseInvoice	99	2026-01-22 13:47:13.523866	1
6890	2	S01V55601Z1L10345582	OUT	SalesInvoice	126	2026-01-22 13:51:08.979833	1
6891	2	S01V55601Z1L10304899	OUT	SalesInvoice	126	2026-01-22 13:51:08.979833	1
6892	2	S01V55601Z1L10458423	OUT	SalesInvoice	126	2026-01-22 13:51:08.979833	1
6893	2	S01E45601CE810572356	OUT	SalesInvoice	126	2026-01-22 13:51:08.979833	1
6894	68	321	IN	PurchaseInvoice	100	2026-01-22 13:53:27.373879	1
6895	68	654	IN	PurchaseInvoice	100	2026-01-22 13:54:00.546805	1
6896	68	654	OUT	SalesInvoice	135	2026-01-22 14:07:12.396066	1
6897	68	987	IN	PurchaseInvoice	100	2026-01-22 14:11:50.555199	1
6898	68	0001	IN	PurchaseInvoice	100	2026-01-22 14:13:33.517111	1
6899	68	0003	IN	PurchaseInvoice	100	2026-01-22 14:13:33.517111	1
6900	68	0004	IN	PurchaseInvoice	100	2026-01-22 14:13:33.517111	1
6901	68	oi1	IN	PurchaseInvoice	100	2026-01-22 14:13:46.443241	1
6902	68	654	IN	SalesInvoice-Delete	135	2026-01-22 14:30:51.047387	1
6903	68	654	OUT	PurchaseInvoice-Delete	100	2026-01-22 14:30:57.578103	1
6904	68	0003	OUT	PurchaseInvoice-Delete	100	2026-01-22 14:30:57.578103	1
6905	68	0004	OUT	PurchaseInvoice-Delete	100	2026-01-22 14:30:57.578103	1
6906	68	oi1	OUT	PurchaseInvoice-Delete	100	2026-01-22 14:30:57.578103	1
6920	68	987	IN	PurchaseInvoice	101	2026-01-22 16:22:39.706808	1
6921	68	fsdfsdf	IN	PurchaseInvoice	101	2026-01-22 16:22:39.706808	1
6922	68	987	OUT	PurchaseInvoice-Delete	101	2026-01-22 16:22:50.196151	1
6923	68	fsdfsdf	OUT	PurchaseInvoice-Delete	101	2026-01-22 16:22:50.196151	1
6931	79	352315403679901	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6932	79	357205981249315	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6933	81	356295606462741	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6934	134	352653442265609	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6935	135	353247105566665	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6936	136	353890109487576	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6937	137	355964948552797	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6938	133	pixel70001	IN	PurchaseInvoice	74	2026-01-22 16:25:58.722396	1
6939	68	356605227683113	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6940	68	356605227703804	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6941	68	355224250996854	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6942	68	353263427193989	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6943	68	350889860529314	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6944	75	356188163093639	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6945	75	357826990550276	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6946	69	351687746863769	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6947	68	359614541291014	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6948	68	356764177275477	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6949	68	356605224108312	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6950	68	355224251427081	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6951	68	353263426675176	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6952	70	351317529884903	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6953	70	355122367429969	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6954	70	356250548298976	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6955	70	350208032986825	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6956	70	351317520845499	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6957	70	352440634381554	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6958	70	356250541701943	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6959	70	352294448173529	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6960	70	352294449552580	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6961	70	355500353647993	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6962	70	356250548267765	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6963	70	351317522022725	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6964	70	351317529770219	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6965	159	350455774515615	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6966	159	356661400563283	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6967	159	352591613065434	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6968	159	350208037479339	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6969	102	356484792035632	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6970	102	359045767346721	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6971	102	359045769093669	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6972	102	351523427089996	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6973	42	SC0Y0F9X7QC	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6974	42	SG2D1H6GKVC	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6975	42	SGCF92TLQXH	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6976	42	SD2WYWYFPLV	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6977	42	SM7RR6FRW7N	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6978	42	SDX9XWFKW42	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6979	42	SL9W0J24GDM	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6980	42	SHLQQTX9JGW	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6981	43	SMT43DHJRGH	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6982	43	SK946HW04X3	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6983	43	SGD4TR707KJ	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6984	43	SGHJYWKVQXD	OUT	SalesInvoice	136	2026-01-23 12:37:38.61745	1
6985	150	SF3W6VGQT49	OUT	SalesInvoice	137	2026-01-23 12:43:37.302242	1
6986	60	SFVFHN160Q6L5	OUT	SalesInvoice	137	2026-01-23 12:43:37.302242	1
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

SELECT pg_catalog.setval('public.chartofaccounts_account_id_seq', 30, true);


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

SELECT pg_catalog.setval('public.items_item_id_seq', 174, true);


--
-- Name: journalentries_journal_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.journalentries_journal_id_seq', 762, true);


--
-- Name: journallines_line_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.journallines_line_id_seq', 1838, true);


--
-- Name: parties_party_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.parties_party_id_seq', 126, true);


--
-- Name: payments_payment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payments_payment_id_seq', 161, true);


--
-- Name: payments_ref_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.payments_ref_seq', 161, true);


--
-- Name: purchaseinvoices_purchase_invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseinvoices_purchase_invoice_id_seq', 101, true);


--
-- Name: purchaseitems_purchase_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchaseitems_purchase_item_id_seq', 551, true);


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

SELECT pg_catalog.setval('public.purchaseunits_unit_id_seq', 4130, true);


--
-- Name: receipts_receipt_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.receipts_receipt_id_seq', 209, true);


--
-- Name: receipts_ref_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.receipts_ref_seq', 209, true);


--
-- Name: salesinvoices_sales_invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesinvoices_sales_invoice_id_seq', 137, true);


--
-- Name: salesitems_sales_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesitems_sales_item_id_seq', 279, true);


--
-- Name: salesreturnitems_return_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesreturnitems_return_item_id_seq', 2, true);


--
-- Name: salesreturns_sales_return_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salesreturns_sales_return_id_seq', 1, true);


--
-- Name: soldunits_sold_unit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.soldunits_sold_unit_id_seq', 2233, true);


--
-- Name: stockmovements_movement_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.stockmovements_movement_id_seq', 6986, true);


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

\unrestrict Ibiku0xaY5yAkBqstFDzbH5EHFnKXOuLHJhXa0z8eKIWxEQbz3oeq2EaLoam2dp

