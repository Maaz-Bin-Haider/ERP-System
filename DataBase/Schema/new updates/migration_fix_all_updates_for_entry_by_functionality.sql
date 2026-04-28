-- ============================================================
-- MIGRATION: Fix created_by in all remaining update functions
--
-- Functions fixed:
--   1. update_payment        — reads created_by_id from JSON payload
--   2. update_receipt        — reads created_by_id from JSON payload
--   3. update_sale_return    — new 3rd parameter p_created_by
--   4. update_purchase_return— new 3rd parameter p_created_by
--
-- update_item_from_json and update_party_from_json were
-- already fixed in the previous migration.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. update_payment — add created_by to the SET clause
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_payment(
    p_payment_id BIGINT,
    p_data       JSONB
) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_amount     NUMERIC(14,4);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_party_id   BIGINT;
    v_created_by INTEGER;
    v_updated    RECORD;
BEGIN
    v_amount     := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method     := NULLIF(p_data->>'method','');
    v_reference  := NULLIF(p_data->>'reference_no','');
    v_desc       := NULLIF(p_data->>'description','');
    v_date       := NULLIF(p_data->>'payment_date','')::DATE;
    v_created_by := NULLIF(p_data->>'created_by_id','')::INTEGER;

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
    SET amount       = COALESCE(v_amount,     amount),
        method       = COALESCE(v_method,     method),
        reference_no = COALESCE(v_reference,  reference_no),
        party_id     = COALESCE(v_party_id,   party_id),
        description  = COALESCE(v_desc,       description),
        payment_date = COALESCE(v_date,       payment_date),
        created_by   = COALESCE(v_created_by, created_by)   -- NEW
    WHERE payment_id = p_payment_id
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id;
    END IF;

    RETURN jsonb_build_object(
        'status',  'success',
        'message', 'Payment updated successfully',
        'payment', to_jsonb(v_updated)
    );
END;
$$;


-- ============================================================
-- 2. update_receipt — add created_by to the SET clause
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_receipt(
    p_receipt_id BIGINT,
    p_data       JSONB
) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_amount     NUMERIC(14,4);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_party_id   BIGINT;
    v_created_by INTEGER;
    v_updated    RECORD;
BEGIN
    v_amount     := NULLIF(p_data->>'amount','')::NUMERIC;
    v_method     := NULLIF(p_data->>'method','');
    v_reference  := NULLIF(p_data->>'reference_no','');
    v_desc       := NULLIF(p_data->>'description','');
    v_date       := NULLIF(p_data->>'receipt_date','')::DATE;
    v_created_by := NULLIF(p_data->>'created_by_id','')::INTEGER;

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
    SET amount       = COALESCE(v_amount,     amount),
        method       = COALESCE(v_method,     method),
        reference_no = COALESCE(v_reference,  reference_no),
        party_id     = COALESCE(v_party_id,   party_id),
        description  = COALESCE(v_desc,       description),
        receipt_date = COALESCE(v_date,       receipt_date),
        created_by   = COALESCE(v_created_by, created_by)   -- NEW
    WHERE receipt_id = p_receipt_id
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt ID % not found', p_receipt_id;
    END IF;

    RETURN jsonb_build_object(
        'status',  'success',
        'message', 'Receipt updated successfully',
        'receipt', to_jsonb(v_updated)
    );
END;
$$;


-- ============================================================
-- 3. update_sale_return — add p_created_by parameter
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_sale_return(
    p_return_id  BIGINT,
    p_serials    JSONB,
    p_created_by INTEGER DEFAULT NULL    -- NEW: last modifier
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    rec           RECORD;
    v_serial      TEXT;
    v_unit        RECORD;
    v_total       NUMERIC(14,2) := 0;
    v_cost        NUMERIC(14,2) := 0;
    v_customer_id BIGINT;
BEGIN
    -- Reverse old items
    FOR rec IN
        SELECT serial_number, item_id
        FROM SalesReturnItems
        WHERE sales_return_id = p_return_id
    LOOP
        UPDATE SoldUnits
        SET status = 'Sold'
        WHERE unit_id = (
            SELECT unit_id FROM PurchaseUnits
            WHERE serial_number = rec.serial_number LIMIT 1
        );

        UPDATE PurchaseUnits
        SET in_stock = FALSE
        WHERE serial_number = rec.serial_number;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'OUT', 'SalesReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    DELETE FROM SalesReturnItems WHERE sales_return_id = p_return_id;

    SELECT customer_id INTO v_customer_id
    FROM SalesReturns WHERE sales_return_id = p_return_id;

    -- Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si    ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s  ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        WHERE pu.serial_number = v_serial
          AND su.status = 'Sold';

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in SoldUnits or is not currently in Sold status', v_serial;
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
        v_cost  := v_cost  + v_unit.unit_price;
    END LOOP;

    -- Update totals and last modifier
    UPDATE SalesReturns
    SET total_amount = v_total,
        created_by   = COALESCE(p_created_by, created_by)   -- NEW
    WHERE sales_return_id = p_return_id;

    PERFORM rebuild_sales_return_journal(p_return_id);
END;
$$;


-- ============================================================
-- 4. update_purchase_return — add p_created_by parameter
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_purchase_return(
    p_return_id  BIGINT,
    p_serials    JSONB,
    p_created_by INTEGER DEFAULT NULL    -- NEW: last modifier
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    rec         RECORD;
    v_serial    TEXT;
    v_unit      RECORD;
    v_total     NUMERIC(14,2) := 0;
    v_vendor_id BIGINT;
BEGIN
    -- Get vendor id
    SELECT vendor_id INTO v_vendor_id
    FROM PurchaseReturns WHERE purchase_return_id = p_return_id;

    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Purchase Return % not found', p_return_id;
    END IF;

    -- Reverse old items (restore stock)
    FOR rec IN
        SELECT serial_number, item_id
        FROM PurchaseReturnItems
        WHERE purchase_return_id = p_return_id
    LOOP
        UPDATE PurchaseUnits SET in_stock = TRUE
        WHERE serial_number = rec.serial_number;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (rec.item_id, rec.serial_number, 'IN', 'PurchaseReturn-Update-Reverse', p_return_id, 1);
    END LOOP;

    -- Remove old items
    DELETE FROM PurchaseReturnItems WHERE purchase_return_id = p_return_id;

    -- Insert new items
    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.serial_number, pi.item_id, pi.unit_price, p.vendor_id
        INTO v_unit
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi     ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p   ON pi.purchase_invoice_id = p.purchase_invoice_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Serial % not found in PurchaseUnits', v_serial;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM PurchaseUnits WHERE unit_id = v_unit.unit_id AND in_stock = TRUE
        ) THEN
            RAISE EXCEPTION 'Serial % is not currently in stock', v_serial;
        END IF;

        UPDATE PurchaseUnits SET in_stock = FALSE WHERE unit_id = v_unit.unit_id;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'OUT', 'PurchaseReturn-Update', p_return_id, 1);

        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (p_return_id, v_unit.item_id, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.unit_price;
    END LOOP;

    -- Update totals and last modifier
    UPDATE PurchaseReturns
    SET total_amount = v_total,
        created_by   = COALESCE(p_created_by, created_by)   -- NEW
    WHERE purchase_return_id = p_return_id;

    PERFORM rebuild_purchase_return_journal(p_return_id);
END;
$$;

COMMIT;
