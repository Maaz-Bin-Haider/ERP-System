--
-- ============================================================
-- FUNCTION: get_last_payment()
-- ============================================================
--

CREATE FUNCTION public.get_last_payment() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(p)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Payments p
    LEFT JOIN Parties pt ON pt.party_id = p.party_id
    LEFT JOIN auth_user u ON u.id = p.created_by
    ORDER BY p.payment_id DESC LIMIT 1;
    RETURN result;
END;
$$;


ALTER FUNCTION public.get_last_payment() OWNER TO postgres;
