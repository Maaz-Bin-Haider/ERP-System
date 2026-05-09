--
-- ============================================================
-- FUNCTION: get_last_purchase()
-- ============================================================
--

CREATE FUNCTION public.get_last_purchase() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO last_id
    FROM PurchaseInvoices
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    RETURN get_current_purchase(last_id);
END;
$$;


ALTER FUNCTION public.get_last_purchase() OWNER TO postgres;
