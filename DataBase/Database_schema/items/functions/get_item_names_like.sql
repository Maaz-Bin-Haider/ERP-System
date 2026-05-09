--
-- ============================================================
-- FUNCTION: get_item_names_like(text)
-- ============================================================
--

CREATE FUNCTION public.get_item_names_like(search_term text) RETURNS TABLE(item_name text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT item_name
    FROM items
    WHERE UPPER(item_name) LIKE search_term || '%';
END;
$$;


ALTER FUNCTION public.get_item_names_like(search_term text) OWNER TO postgres;
