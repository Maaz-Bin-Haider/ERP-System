# Payment Functions - Complete Documentation

**Category:** Payment Functions
**Total Functions:** 9

---


## 💵 PAYMENT FUNCTIONS

**Total Functions:** 9

---

### Function 1: `make_payment()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Make Payment - Performs specialized database operation.

#### Example SQL Call:

```sql
SELECT make_payment('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 2: `delete_payment()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_payment_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Delete Payment - Deletes a record after validation, cleaning up all related entries.

#### Example SQL Call:

```sql
SELECT delete_payment(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 3: `update_payment()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_payment_id bigint`
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Update Payment - Updates an existing record with validation to maintain data integrity.

#### Example SQL Call:

```sql
SELECT update_payment('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 4: `get_last_20_payments_json()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Get Last 20 Payments Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_20_payments_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 5: `get_last_payment()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- None

#### Returns:
`jsonb`

#### Purpose:
Get Last Payment - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_payment();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 6: `get_next_payment()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_payment_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Get Next Payment - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_next_payment(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 7: `get_payment_details()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_payment_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Get Payment Details - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_payment_details(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 8: `get_payments_by_date_json()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Get Payments By Date Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_payments_by_date_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 9: `get_previous_payment()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_payment_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Get Previous Payment - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_previous_payment(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

