--
-- ============================================================
-- FUNCTION: get_previous_purchase(bigint)
-- ============================================================
--

CREATE FUNCTION public.get_previous_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    prev_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO prev_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id < p_invoice_id
    ORDER BY purchase_invoice_id DESC
    LIMIT 1;

    IF prev_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase(prev_id);
END;
$$;


ALTER FUNCTION public.get_previous_purchase(p_invoice_id bigint) OWNER TO postgres;
