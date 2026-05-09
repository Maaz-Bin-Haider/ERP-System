--
-- ============================================================
-- FUNCTION: update_payment(bigint, jsonb)
-- ============================================================
--

CREATE FUNCTION public.update_payment(p_payment_id bigint, p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.update_payment(p_payment_id bigint, p_data jsonb) OWNER TO postgres;
