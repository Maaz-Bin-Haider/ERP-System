--
-- ============================================================
-- FUNCTION: get_previous_receipt(bigint)
-- ============================================================
--

CREATE FUNCTION public.get_previous_receipt(p_receipt_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE result JSONB;
BEGIN
    SELECT to_jsonb(r)
        || jsonb_build_object('party_name', pt.party_name)
        || jsonb_build_object('created_by', COALESCE(u.username, 'N/A'))
    INTO result
    FROM Receipts r
    LEFT JOIN Parties pt ON pt.party_id = r.party_id
    LEFT JOIN auth_user u ON u.id = r.created_by
    WHERE r.receipt_id < p_receipt_id
    ORDER BY r.receipt_id DESC LIMIT 1;
    RETURN result;
END;
$$;


ALTER FUNCTION public.get_previous_receipt(p_receipt_id bigint) OWNER TO postgres;
