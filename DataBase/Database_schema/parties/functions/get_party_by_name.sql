--
-- ============================================================
-- FUNCTION: get_party_by_name(text)
-- ============================================================
--

CREATE FUNCTION public.get_party_by_name(p_name text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.get_party_by_name(p_name text) OWNER TO postgres;
