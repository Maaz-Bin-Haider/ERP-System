--
-- ============================================================
-- FUNCTION: get_last_sale_id()
-- ============================================================
--

CREATE FUNCTION public.get_last_sale_id() RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_invoice_id
    INTO last_id
    FROM SalesInvoices
    ORDER BY sales_invoice_id DESC
    LIMIT 1;

    RETURN last_id;
END;
$$;


ALTER FUNCTION public.get_last_sale_id() OWNER TO postgres;
