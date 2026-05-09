--
-- ============================================================
-- FUNCTION: get_item_by_name(text)
-- ============================================================
--

CREATE FUNCTION public.get_item_by_name(p_item_name text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.get_item_by_name(p_item_name text) OWNER TO postgres;
