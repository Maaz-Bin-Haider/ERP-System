--
-- ============================================================
-- FUNCTION: serial_exists_in_sales_return(bigint, text)
-- ============================================================
--

CREATE FUNCTION public.serial_exists_in_sales_return(p_sales_return_id bigint, p_serial_number text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT TRUE
    INTO v_exists
    FROM SalesReturnItems
    WHERE sales_return_id = p_sales_return_id
      AND serial_number = p_serial_number
    LIMIT 1;

    RETURN COALESCE(v_exists, FALSE);
END;
$$;


ALTER FUNCTION public.serial_exists_in_sales_return(p_sales_return_id bigint, p_serial_number text) OWNER TO postgres;
