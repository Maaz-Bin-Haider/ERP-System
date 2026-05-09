--
-- ============================================================
-- FUNCTION: get_item_stock_by_name(character varying)
-- ============================================================
--

CREATE FUNCTION public.get_item_stock_by_name(p_item_name character varying) RETURNS TABLE(item_id_out text, item_name_out character varying, serial_number_out character varying, serial_comment_out text, quantity_out text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH stock AS (
        SELECT 
            i.item_id,
            i.item_name,
            pu.serial_number,
            pu.serial_comment,
            COUNT(*) OVER () AS total_quantity,
            ROW_NUMBER() OVER (ORDER BY pu.serial_number) AS rn
        FROM purchaseunits pu
        JOIN purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
        JOIN items i ON pit.item_id = i.item_id
        WHERE i.item_name = p_item_name
          AND pu.in_stock = true
          AND NOT EXISTS (
              SELECT 1 FROM soldunits su
              WHERE su.unit_id = pu.unit_id AND su.status = 'Sold'
          )
          AND NOT EXISTS (
              SELECT 1 FROM purchasereturnitems pri
              WHERE pri.serial_number = pu.serial_number
          )
    )
    SELECT 
        CASE WHEN rn = 1 THEN item_id::TEXT ELSE '' END,
        CASE WHEN rn = 1 THEN item_name ELSE ''::VARCHAR END,
        serial_number,
        serial_comment,
        CASE WHEN rn = 1 THEN total_quantity::TEXT ELSE '' END
    FROM stock
    ORDER BY rn;
END;
$$;


ALTER FUNCTION public.get_item_stock_by_name(p_item_name character varying) OWNER TO postgres;
