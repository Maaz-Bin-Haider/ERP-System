-- ============================================================
-- MIGRATION: Add created_by tracking to all transactional tables
-- Run this ONCE on your PostgreSQL database.
--
-- Safe for existing data:
--   - All new columns are nullable (old rows get NULL, shown as N/A)
--   - All new function parameters have DEFAULT NULL
--   - CREATE OR REPLACE is non-destructive
--   - ADD COLUMN IF NOT EXISTS is idempotent
-- ============================================================

BEGIN;

-- ============================================================
-- PART 1: ADD created_by COLUMNS TO TABLES
-- ============================================================

ALTER TABLE public.salesinvoices
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;

ALTER TABLE public.purchaseinvoices
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;

ALTER TABLE public.salesreturns
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;

ALTER TABLE public.purchasereturns
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;

ALTER TABLE public.payments
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;

ALTER TABLE public.receipts
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;

ALTER TABLE public.items
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;

ALTER TABLE public.parties
    ADD COLUMN IF NOT EXISTS created_by INTEGER
        REFERENCES public.auth_user(id) ON DELETE SET NULL;


-- ============================================================
-- PART 2: UPDATE CREATE/MAKE/ADD FUNCTIONS
-- (accept user ID, store it in the new column)
-- All new parameters have DEFAULT NULL so existing callers
-- that don't pass user ID continue to work unchanged.
-- ============================================================

-- ---- 2.1  create_sale ----
CREATE OR REPLACE FUNCTION public.create_sale(
    p_party_id      bigint,
    p_invoice_date  date,
    p_items         jsonb,
    p_created_by    integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_invoice_id    BIGINT;
    v_sales_item_id BIGINT;
    v_total         NUMERIC(14,2) := 0;
    v_unit_id       BIGINT;
    v_serial        TEXT;
    v_item_id       BIGINT;
    v_item          JSONB;
BEGIN
    INSERT INTO SalesInvoices(customer_id, invoice_date, total_amount, created_by)
    VALUES (p_party_id, p_invoice_date, 0, p_created_by)
    RETURNING sales_invoice_id INTO v_invoice_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        SELECT item_id INTO v_item_id FROM Items
        WHERE item_name = (v_item->>'item_name') LIMIT 1;
        IF v_item_id IS NULL THEN
            RAISE EXCEPTION 'Item "%" not found in Items table', (v_item->>'item_name');
        END IF;

        INSERT INTO SalesItems(sales_invoice_id, item_id, quantity, unit_price)
        VALUES (v_invoice_id, v_item_id, (v_item->>'qty')::INT, (v_item->>'unit_price')::NUMERIC)
        RETURNING sales_item_id INTO v_sales_item_id;

        v_total := v_total + ((v_item->>'qty')::INT * (v_item->>'unit_price')::NUMERIC);

        FOR v_serial IN SELECT jsonb_array_elements_text(v_item->'serials')
        LOOP
            SELECT unit_id INTO v_unit_id FROM PurchaseUnits
            WHERE serial_number = v_serial AND in_stock = TRUE LIMIT 1;
            IF v_unit_id IS NULL THEN
                RAISE EXCEPTION 'Serial % not found or already sold', v_serial;
            END IF;
            INSERT INTO SoldUnits(sales_item_id, unit_id, sold_price, status)
            VALUES (v_sales_item_id, v_unit_id, (v_item->>'unit_price')::NUMERIC, 'Sold');
            UPDATE PurchaseUnits SET in_stock = FALSE WHERE unit_id = v_unit_id;
            INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
            VALUES (v_item_id, v_serial, 'OUT', 'SalesInvoice', v_invoice_id, 1);
        END LOOP;
    END LOOP;

    UPDATE SalesInvoices SET total_amount = v_total WHERE sales_invoice_id = v_invoice_id;
    PERFORM rebuild_sales_journal(v_invoice_id);
    RETURN v_invoice_id;
END;
$$;


-- ---- 2.2  create_purchase ----
CREATE OR REPLACE FUNCTION public.create_purchase(
    p_party_id      bigint,
    p_invoice_date  date,
    p_items         jsonb,
    p_created_by    integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
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


-- ---- 2.3  create_sale_return ----
CREATE OR REPLACE FUNCTION public.create_sale_return(
    p_party_name text,
    p_serials    jsonb,
    p_created_by integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_return_id   BIGINT;
    v_customer_id BIGINT;
    v_serial      TEXT;
    v_unit        RECORD;
    v_total       NUMERIC(14,2) := 0;
BEGIN
    SELECT party_id INTO v_customer_id FROM Parties WHERE party_name = p_party_name LIMIT 1;
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Party "%" not found', p_party_name;
    END IF;

    INSERT INTO SalesReturns(customer_id, return_date, total_amount, created_by)
    VALUES (v_customer_id, CURRENT_DATE, 0, p_created_by)
    RETURNING sales_return_id INTO v_return_id;

    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT su.sold_unit_id, su.unit_id, su.sold_price, si.item_id,
               si.sales_invoice_id, pu.serial_number, pi2.unit_price, s.customer_id
        INTO v_unit
        FROM SoldUnits su
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN PurchaseItems pi2 ON pu.purchase_item_id = pi2.purchase_item_id
        WHERE pu.serial_number = v_serial;

        IF NOT FOUND THEN RAISE EXCEPTION 'Serial % not found in SoldUnits', v_serial; END IF;
        IF v_unit.customer_id <> v_customer_id THEN
            RAISE EXCEPTION 'Serial % was not sold to this customer', v_serial;
        END IF;

        UPDATE SoldUnits SET status = 'Returned' WHERE sold_unit_id = v_unit.sold_unit_id;
        UPDATE PurchaseUnits SET in_stock = TRUE WHERE unit_id = v_unit.unit_id;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_unit.item_id, v_serial, 'IN', 'SalesReturn', v_return_id, 1);

        INSERT INTO SalesReturnItems(sales_return_id, item_id, sold_price, cost_price, serial_number)
        VALUES (v_return_id, v_unit.item_id, v_unit.sold_price, v_unit.unit_price, v_serial);

        v_total := v_total + v_unit.sold_price;
    END LOOP;

    UPDATE SalesReturns SET total_amount = v_total WHERE sales_return_id = v_return_id;
    PERFORM rebuild_sales_return_journal(v_return_id);
    RETURN v_return_id;
END;
$$;


-- ---- 2.4  create_purchase_return ----
CREATE OR REPLACE FUNCTION public.create_purchase_return(
    p_party_name text,
    p_serials    jsonb,
    p_created_by integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_return_id BIGINT;
    v_vendor_id BIGINT;
    v_serial    TEXT;
    v_rec       RECORD;
    v_total     NUMERIC(14,2) := 0;
BEGIN
    SELECT party_id INTO v_vendor_id FROM Parties WHERE party_name = p_party_name LIMIT 1;
    IF v_vendor_id IS NULL THEN
        RAISE EXCEPTION 'Vendor "%" not found', p_party_name;
    END IF;

    INSERT INTO PurchaseReturns(vendor_id, return_date, total_amount, created_by)
    VALUES (v_vendor_id, CURRENT_DATE, 0, p_created_by)
    RETURNING purchase_return_id INTO v_return_id;

    FOR v_serial IN SELECT jsonb_array_elements_text(p_serials)
    LOOP
        SELECT pu.unit_id, pu.purchase_item_id, pi2.unit_price, pi2.item_id,
               pi2.purchase_invoice_id, pu.serial_number
        INTO v_rec
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi2 ON pu.purchase_item_id = pi2.purchase_item_id
        JOIN PurchaseInvoices pinv ON pi2.purchase_invoice_id = pinv.purchase_invoice_id
        WHERE pu.serial_number = v_serial AND pinv.vendor_id = v_vendor_id;

        IF NOT FOUND THEN RAISE EXCEPTION 'Serial % not found for this vendor', v_serial; END IF;

        UPDATE PurchaseUnits SET in_stock = FALSE WHERE unit_id = v_rec.unit_id;

        INSERT INTO StockMovements(item_id, serial_number, movement_type, reference_type, reference_id, quantity)
        VALUES (v_rec.item_id, v_serial, 'OUT', 'PurchaseReturn', v_return_id, 1);

        INSERT INTO PurchaseReturnItems(purchase_return_id, item_id, unit_price, serial_number)
        VALUES (v_return_id, v_rec.item_id, v_rec.unit_price, v_serial);

        v_total := v_total + v_rec.unit_price;
    END LOOP;

    UPDATE PurchaseReturns SET total_amount = v_total WHERE purchase_return_id = v_return_id;
    PERFORM rebuild_purchase_return_journal(v_return_id);
    RETURN v_return_id;
END;
$$;


-- ---- 2.5  make_payment (minimal: add created_by to INSERT only) ----
CREATE OR REPLACE FUNCTION public.make_payment(p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_party_id   BIGINT;
    v_account_id BIGINT;
    v_amount     NUMERIC(14,4);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_id         BIGINT;
    v_created_by INTEGER;
BEGIN
    v_amount     := (p_data->>'amount')::NUMERIC;
    v_method     := p_data->>'method';
    v_reference  := p_data->>'reference_no';
    v_desc       := p_data->>'description';
    v_date       := NULLIF(p_data->>'payment_date', '')::DATE;
    v_created_by := NULLIF(p_data->>'created_by_id', '')::INTEGER;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    SELECT party_id INTO v_party_id FROM Parties
    WHERE party_name = p_data->>'party_name' LIMIT 1;
    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Vendor % not found', p_data->>'party_name';
    END IF;

    SELECT account_id INTO v_account_id FROM ChartOfAccounts
    WHERE account_name = 'Cash';
    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found';
    END IF;

    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'PMT-' || nextval('payments_ref_seq');
    END IF;

    INSERT INTO Payments(party_id, account_id, amount, method, reference_no,
                         description, payment_date, created_by)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference,
            v_desc, COALESCE(v_date, CURRENT_DATE), v_created_by)
    RETURNING payment_id INTO v_id;

    RETURN jsonb_build_object('status', 'success',
                              'message', 'Payment created successfully',
                              'payment_id', v_id);
END;
$$;


-- ---- 2.6  make_receipt (minimal: add created_by to INSERT only) ----
CREATE OR REPLACE FUNCTION public.make_receipt(p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_party_id   BIGINT;
    v_account_id BIGINT;
    v_amount     NUMERIC(14,4);
    v_method     TEXT;
    v_reference  TEXT;
    v_desc       TEXT;
    v_date       DATE;
    v_id         BIGINT;
    v_created_by INTEGER;
BEGIN
    v_amount     := (p_data->>'amount')::NUMERIC;
    v_method     := p_data->>'method';
    v_reference  := p_data->>'reference_no';
    v_desc       := p_data->>'description';
    v_date       := NULLIF(p_data->>'receipt_date', '')::DATE;
    v_created_by := NULLIF(p_data->>'created_by_id', '')::INTEGER;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: must be > 0';
    END IF;

    SELECT party_id INTO v_party_id FROM Parties
    WHERE party_name = p_data->>'party_name' LIMIT 1;
    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Customer % not found', p_data->>'party_name';
    END IF;

    SELECT account_id INTO v_account_id FROM ChartOfAccounts
    WHERE account_name = 'Cash';
    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found';
    END IF;

    IF v_reference IS NULL OR v_reference = '' THEN
        v_reference := 'RCT-' || nextval('receipts_ref_seq');
    END IF;

    INSERT INTO Receipts(party_id, account_id, amount, method, reference_no,
                         description, receipt_date, created_by)
    VALUES (v_party_id, v_account_id, v_amount, v_method, v_reference,
            v_desc, COALESCE(v_date, CURRENT_DATE), v_created_by)
    RETURNING receipt_id INTO v_id;

    RETURN jsonb_build_object('status', 'success',
                              'message', 'Receipt created successfully',
                              'receipt_id', v_id);
END;
$$;


-- ---- 2.7  add_item_from_json ----
CREATE OR REPLACE FUNCTION public.add_item_from_json(item_data jsonb) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO Items(item_name, storage, sale_price, item_code, category, brand,
                      created_at, updated_at, created_by)
    VALUES (
        item_data->>'item_name',
        COALESCE(item_data->>'storage', 'Main Warehouse'),
        COALESCE((item_data->>'sale_price')::NUMERIC, 0.00),
        NULLIF(item_data->>'item_code', ''),
        NULLIF(item_data->>'category', ''),
        NULLIF(item_data->>'brand', ''),
        COALESCE((item_data->>'created_at')::TIMESTAMP, NOW()),
        COALESCE((item_data->>'updated_at')::TIMESTAMP, NOW()),
        NULLIF(item_data->>'created_by_id', '')::INTEGER
    );
END;
$$;


-- ============================================================
-- PART 3: UPDATE READ FUNCTIONS (return created_by username)
-- ============================================================

-- ---- 3.1  get_current_sale ----
-- (get_next_sale, get_previous_sale, get_last_sale call this internally
--  so they automatically inherit the new 'created_by' field)
CREATE OR REPLACE FUNCTION public.get_current_sale(p_invoice_id bigint) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE result JSON;
BEGIN
    SELECT json_build_object(
        'sales_invoice_id', si.sales_invoice_id,
        'Party',            p.party_name,
        'invoice_date',     si.invoice_date,
        'total_amount',     si.total_amount,
        'description',      je.description,
        'created_by',       COALESCE(u.username, 'N/A'),
        'items', (
            SELECT json_agg(json_build_object(
                'item_name',  i.item_name,
                'qty',        s_items.quantity,
                'unit_price', s_items.unit_price,
                'serials', (
                    SELECT json_agg(pu.serial_number)
                    FROM SoldUnits su
                    JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
                    WHERE su.sales_item_id = s_items.sales_item_id
                )
            ))
            FROM SalesItems s_items
            JOIN Items i ON i.item_id = s_items.item_id
            WHERE s_items.sales_invoice_id = si.sales_invoice_id
        )
    ) INTO result
    FROM SalesInvoices si
    JOIN Parties p ON p.party_id = si.customer_id
    LEFT JOIN JournalEntries je ON je.journal_id = si.journal_id
    LEFT JOIN auth_user u ON u.id = si.created_by
    WHERE si.sales_invoice_id = p_invoice_id;
    RETURN result;
END;
$$;


-- ---- 3.2  get_current_purchase ----
-- (get_next_purchase, get_previous_purchase, get_last_purchase inherit this)
CREATE OR REPLACE FUNCTION public.get_current_purchase(p_invoice_id bigint) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE result JSON;
BEGIN
    SELECT json_build_object(
        'purchase_invoice_id', pi.purchase_invoice_id,
        'Party',               p.party_name,
        'invoice_date',        pi.invoice_date,
        'total_amount',        pi.total_amount,
        'description',         je.description,
        'created_by',          COALESCE(u.username, 'N/A'),
        'items', (
            SELECT json_agg(json_build_object(
                'item_name',  i.item_name,
                'qty',        pi2.quantity,
                'unit_price', pi2.unit_price,
                'serials', (
                    SELECT json_agg(json_build_object('serial', pu.serial_number, 'comment', pu.serial_comment))
                    FROM PurchaseUnits pu
                    WHERE pu.purchase_item_id = pi2.purchase_item_id
                )
            ))
            FROM PurchaseItems pi2
            JOIN Items i ON i.item_id = pi2.item_id
            WHERE pi2.purchase_invoice_id = pi.purchase_invoice_id
        )
    ) INTO result
    FROM PurchaseInvoices pi
    JOIN Parties p ON p.party_id = pi.vendor_id
    LEFT JOIN JournalEntries je ON je.journal_id = pi.journal_id
    LEFT JOIN auth_user u ON u.id = pi.created_by
    WHERE pi.purchase_invoice_id = p_invoice_id;
    RETURN result;
END;
$$;


-- ---- 3.3  get_current_sales_return ----
CREATE OR REPLACE FUNCTION public.get_current_sales_return(p_return_id bigint) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE result JSON;
BEGIN
    SELECT json_build_object(
        'sales_return_id', sr.sales_return_id,
        'Customer',        pa.party_name,
        'return_date',     sr.return_date,
        'total_amount',    sr.total_amount,
        'description',     je.description,
        'created_by',      COALESCE(u.username, 'N/A'),
        'items', (
            SELECT json_agg(json_build_object(
                'item_name',     i.item_name,
                'sold_price',    sri.sold_price,
                'cost_price',    sri.cost_price,
                'serial_number', sri.serial_number
            ))
            FROM SalesReturnItems sri
            JOIN Items i ON i.item_id = sri.item_id
            WHERE sri.sales_return_id = sr.sales_return_id
        )
    ) INTO result
    FROM SalesReturns sr
    JOIN Parties pa ON pa.party_id = sr.customer_id
    LEFT JOIN JournalEntries je ON je.journal_id = sr.journal_id
    LEFT JOIN auth_user u ON u.id = sr.created_by
    WHERE sr.sales_return_id = p_return_id;
    RETURN result;
END;
$$;


-- ---- 3.4  get_current_purchase_return ----
CREATE OR REPLACE FUNCTION public.get_current_purchase_return(p_return_id bigint) RETURNS json
LANGUAGE plpgsql AS $$
DECLARE result JSON;
BEGIN
    SELECT json_build_object(
        'purchase_return_id', pr.purchase_return_id,
        'Vendor',             pa.party_name,
        'return_date',        pr.return_date,
        'total_amount',       pr.total_amount,
        'description',        je.description,
        'created_by',         COALESCE(u.username, 'N/A'),
        'items', (
            SELECT json_agg(json_build_object(
                'item_name',     i.item_name,
                'unit_price',    pri.unit_price,
                'serial_number', pri.serial_number
            ))
            FROM PurchaseReturnItems pri
            JOIN Items i ON i.item_id = pri.item_id
            WHERE pri.purchase_return_id = pr.purchase_return_id
        )
    ) INTO result
    FROM PurchaseReturns pr
    JOIN Parties pa ON pa.party_id = pr.vendor_id
    LEFT JOIN JournalEntries je ON je.journal_id = pr.journal_id
    LEFT JOIN auth_user u ON u.id = pr.created_by
    WHERE pr.purchase_return_id = p_return_id;
    RETURN result;
END;
$$;


-- ---- 3.5  get_payment_details ----
CREATE OR REPLACE FUNCTION public.get_payment_details(p_payment_id bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(p)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    LEFT JOIN auth_user u ON u.id = p.created_by
    WHERE p.payment_id = p_payment_id;
    RETURN result;
END;
$$;


-- ---- 3.6  get_last_payment ----
CREATE OR REPLACE FUNCTION public.get_last_payment() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(p)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    LEFT JOIN auth_user u ON u.id = p.created_by
    ORDER BY p.payment_id DESC LIMIT 1;
    RETURN result;
END;
$$;


-- ---- 3.7  get_next_payment ----
CREATE OR REPLACE FUNCTION public.get_next_payment(p_payment_id bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(p)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    LEFT JOIN auth_user u ON u.id = p.created_by
    WHERE p.payment_id > p_payment_id
    ORDER BY p.payment_id ASC LIMIT 1;
    RETURN result;
END;
$$;


-- ---- 3.8  get_previous_payment ----
CREATE OR REPLACE FUNCTION public.get_previous_payment(p_payment_id bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(p)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    LEFT JOIN auth_user u ON u.id = p.created_by
    WHERE p.payment_id < p_payment_id
    ORDER BY p.payment_id DESC LIMIT 1;
    RETURN result;
END;
$$;


-- ---- 3.9  get_receipt_details ----
CREATE OR REPLACE FUNCTION public.get_receipt_details(p_receipt_id bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(r)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    LEFT JOIN auth_user u ON u.id = r.created_by
    WHERE r.receipt_id = p_receipt_id;
    RETURN result;
END;
$$;


-- ---- 3.10  get_last_receipt ----
CREATE OR REPLACE FUNCTION public.get_last_receipt() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(r)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    LEFT JOIN auth_user u ON u.id = r.created_by
    ORDER BY r.receipt_id DESC LIMIT 1;
    RETURN result;
END;
$$;


-- ---- 3.11  get_next_receipt ----
CREATE OR REPLACE FUNCTION public.get_next_receipt(p_receipt_id bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(r)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    LEFT JOIN auth_user u ON u.id = r.created_by
    WHERE r.receipt_id > p_receipt_id
    ORDER BY r.receipt_id ASC LIMIT 1;
    RETURN result;
END;
$$;


-- ---- 3.12  get_previous_receipt ----
CREATE OR REPLACE FUNCTION public.get_previous_receipt(p_receipt_id bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(r)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    LEFT JOIN auth_user u ON u.id = r.created_by
    WHERE r.receipt_id < p_receipt_id
    ORDER BY r.receipt_id DESC LIMIT 1;
    RETURN result;
END;
$$;


-- ---- 3.13  get_item_by_name ----
CREATE OR REPLACE FUNCTION public.get_item_by_name(p_item_name text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT COALESCE(
        jsonb_agg(
            (to_jsonb(i) - 'updated_at' - 'created_at')
            || jsonb_build_object('created_by_username', COALESCE(u.username, 'N/A'))
        ),
        '[]'::jsonb
    )
    INTO result
    FROM Items i
    LEFT JOIN auth_user u ON u.id = i.created_by
    WHERE i.item_name ILIKE p_item_name;
    RETURN result;
END;
$$;


-- ---- 3.14  get_party_by_name ----
CREATE OR REPLACE FUNCTION public.get_party_by_name(p_name text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE result JSONB;
BEGIN
    SELECT COALESCE(
        jsonb_agg(
            to_jsonb(p)
            || jsonb_build_object('created_by_username', COALESCE(u.username, 'N/A'))
        ),
        '[]'::jsonb
    )
    INTO result
    FROM Parties p
    LEFT JOIN auth_user u ON u.id = p.created_by
    WHERE p.party_name ILIKE p_name;
    RETURN result;
END;
$$;

COMMIT;
