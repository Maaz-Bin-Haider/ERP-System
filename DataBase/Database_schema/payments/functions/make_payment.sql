--
-- ============================================================
-- FUNCTION: make_payment(jsonb)
-- ============================================================
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


ALTER FUNCTION public.make_payment(p_data jsonb) OWNER TO postgres;
