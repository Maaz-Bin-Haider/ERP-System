--
-- ============================================================
-- FUNCTION: add_item_from_json(jsonb)
-- ============================================================
--

CREATE FUNCTION public.add_item_from_json(item_data jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.add_item_from_json(item_data jsonb) OWNER TO postgres;
