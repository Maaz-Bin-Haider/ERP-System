# Item Functions - Complete Documentation

**Category:** Item Functions
**Total Functions:** 4

---


## 📦 ITEM FUNCTIONS

**Total Functions:** 4

---

### Function 1: `add_item_from_json()`

#### Complete SQL Code:

```sql
CREATE OR REPLACE FUNCTION public.add_item_from_json(item_data jsonb) RETURNS void
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
```

#### Parameters:
- `item_data jsonb`

#### Returns:
`void`

#### Purpose:
Add Item From Json - Performs specialized database operation.

#### Example SQL Call:

```sql
SELECT add_item_from_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 2: `update_item_from_json()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `item_data jsonb`

#### Returns:
`void`

#### Purpose:
Update Item From Json - Updates an existing record with validation to maintain data integrity.

#### Example SQL Call:

```sql
SELECT update_item_from_json('{
    -- JSON parameters here
}'::jsonb);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 3: `get_items_json()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- None

#### Returns:
`jsonb`

#### Purpose:
Get Items Json - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_items_json();
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

### Function 4: `get_item_by_name()`

#### Complete SQL Code:

```sql
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
```

#### Parameters:
- `p_item_name text`

#### Returns:
`jsonb`

#### Purpose:
Get Item By Name - Retrieves data from the database in JSON format.

#### Example SQL Call:

```sql
SELECT get_item_by_name(...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

