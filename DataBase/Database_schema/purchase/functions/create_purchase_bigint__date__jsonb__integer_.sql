--
-- ================================================================
-- FUNCTION: create_purchase(bigint, date, jsonb, integer)  |  App: Purchase
-- ================================================================
--

CREATE FUNCTION public.create_purchase(p_party_id bigint, p_invoice_date date, p_items jsonb, p_created_by integer DEFAULT NULL::integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_invoice_id       BIGINT;
    v_purchase_item_id BIGINT;
    v_total            NUMERIC(14,2) := 0;
    v_item_id          BIGINT;
    v_item             JSONB;
    v_serial           JSONB;
BEGIN
    INSERT INTO PurchaseInvoices(vendor_id, invoice_date, total_amount, created_by)
    VALUES (p_party_id, p_invoice_date, 0, p_created_by)
    RETURNING purchase_invoice_id INTO v_invoice_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        SELECT item_id INTO v_item_id FROM Items
        WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            INSERT INTO Items(item_name, sale_price)
            VALUES ((v_item->>'item_name'), (v_item->>'unit_price')::NUMERIC)
            RETURNING item_id INTO v_item_id;
        END IF;

        INSERT INTO PurchaseItems(purchase_invoice_id, item_id, quantity, unit_price)
        VALUES (v_invoice_id, v_item_id, (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING purchase_item_id INTO v_purchase_item_id;

        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        FOR v_serial IN SELECT * FROM jsonb_array_elements(v_item->'serials')
        LOOP
            INSERT INTO PurchaseUnits(purchase_item_id, serial_number, serial_comment, in_stock)
            VALUES (v_purchase_item_id, v_serial->>'serial',
                    NULLIF(TRIM(COALESCE(v_serial->>'comment', '')), ''), TRUE);
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial->>'serial', 'IN', 'PurchaseInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    UPDATE PurchaseInvoices SET total_amount = v_total WHERE purchase_invoice_id = v_invoice_id;
    PERFORM rebuild_purchase_journal(v_invoice_id);
    RETURN v_invoice_id;
END;
$$;
