--
-- ============================================================
-- FUNCTION: get_payment_details(bigint)
-- ============================================================
--

CREATE FUNCTION public.get_payment_details(p_payment_id bigint) RETURNS jsonb
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
    WHERE p.payment_id = p_payment_id;
    RETURN result;
END;
$$;


ALTER FUNCTION public.get_payment_details(p_payment_id bigint) OWNER TO postgres;
