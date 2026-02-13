# Receipt Functions - Complete Documentation

**Category:** Receipt Functions
**Total Functions:** 9

---


## 🧾 RECEIPT FUNCTIONS

**Total Functions:** 9

---

### Function 1: `make_receipt()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Make Receipt - Performs specialized database operation.

#### Example SQL Call:

```sql
SELECT make_receipt('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 2: `delete_receipt()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_receipt_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Delete Receipt - Deletes a record after validation, cleaning up all related entries.

#### Example SQL Call:

```sql
SELECT delete_receipt(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 3: `update_receipt()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_receipt_id bigint`
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Update Receipt - Updates an existing record with validation to maintain data integrity.

#### Example SQL Call:

```sql
SELECT update_receipt('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 4: `get_last_20_receipts_json()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Get Last 20 Receipts Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_20_receipts_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 5: `get_last_receipt()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- None

#### Returns:
`jsonb`

#### Purpose:
Get Last Receipt - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_last_receipt();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 6: `get_next_receipt()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_receipt_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Get Next Receipt - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_next_receipt(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 7: `get_previous_receipt()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_receipt_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Get Previous Receipt - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_previous_receipt(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 8: `get_receipt_details()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_receipt_id bigint`

#### Returns:
`jsonb`

#### Purpose:
Get Receipt Details - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_receipt_details(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 9: `get_receipts_by_date_json()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_data jsonb`

#### Returns:
`jsonb`

#### Purpose:
Get Receipts By Date Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_receipts_by_date_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

