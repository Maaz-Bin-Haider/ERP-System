--
-- ============================================================
-- FUNCTION: get_next_purchase(bigint)
-- ============================================================
--

CREATE FUNCTION public.get_next_purchase(p_invoice_id bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_id BIGINT;
BEGIN
    SELECT purchase_invoice_id INTO next_id
    FROM PurchaseInvoices
    WHERE purchase_invoice_id > p_invoice_id
    ORDER BY purchase_invoice_id ASC
    LIMIT 1;

    IF next_id IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN get_current_purchase(next_id);
END;
$$;


ALTER FUNCTION public.get_next_purchase(p_invoice_id bigint) OWNER TO postgres;
