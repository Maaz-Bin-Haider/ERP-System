--
-- ============================================================
-- FUNCTION: update_item_from_json(jsonb)
-- ============================================================
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
        updated_at  = NOW(),
        -- Update last modifier if provided
        created_by  = CASE
                        WHEN NULLIF(item_data->>'created_by_id', '') IS NOT NULL
                        THEN (item_data->>'created_by_id')::INTEGER
                        ELSE created_by
                      END
    WHERE item_id = (item_data->>'item_id')::BIGINT;
END;
$$;


ALTER FUNCTION public.update_item_from_json(item_data jsonb) OWNER TO postgres;
