--
-- ============================================================
-- FUNCTION: get_last_purchase_return()
-- ============================================================
--

CREATE FUNCTION public.get_last_purchase_return() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_return_id INTO last_id
    FROM PurchaseReturns
    ORDER BY purchase_return_id DESC
    LIMIT 1;

    RETURN get_current_purchase_return(last_id);
END;
$$;


ALTER FUNCTION public.get_last_purchase_return() OWNER TO postgres;
