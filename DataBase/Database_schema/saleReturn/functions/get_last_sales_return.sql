--
-- ============================================================
-- FUNCTION: get_last_sales_return()
-- ============================================================
--

CREATE FUNCTION public.get_last_sales_return() RETURNS json
    LANGUAGE plpgsql
    AS $$
DECLARE
    last_id BIGINT;
BEGIN
    SELECT sales_return_id INTO last_id
    FROM SalesReturns
    ORDER BY sales_return_id DESC
    LIMIT 1;

    RETURN get_current_sales_return(last_id);
END;
$$;


ALTER FUNCTION public.get_last_sales_return() OWNER TO postgres;
