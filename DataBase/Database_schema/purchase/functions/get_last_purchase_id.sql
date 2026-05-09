--
-- ============================================================
-- FUNCTION: get_last_purchase_id()
-- ============================================================
--

CREATE FUNCTION public.get_last_purchase_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_invoice_id
    INTO last_id
    FROM PurchaseInvoices
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_purchase_id() OWNER TO postgres;
