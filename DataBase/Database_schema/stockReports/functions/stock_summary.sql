--
-- ============================================================
-- FUNCTION: stock_summary()
-- ============================================================
--

CREATE FUNCTION public.stock_summary() RETURNS TABLE(item_id bigint, item_name character varying, category character varying, brand character varying, quantity_in_stock bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        i.item_id,
        i.item_name,
        i.category,
        i.brand,
        COUNT(pu.unit_id) FILTER (
            WHERE pu.in_stock = TRUE
              AND NOT EXISTS (
                  SELECT 1 FROM soldunits su
                  WHERE su.unit_id = pu.unit_id AND su.status = 'Sold'
              )
              AND NOT EXISTS (
                  SELECT 1 FROM purchasereturnitems pri
                  WHERE pri.serial_number = pu.serial_number
              )
        ) AS quantity_in_stock
    FROM Items i
    LEFT JOIN PurchaseItems pi ON i.item_id = pi.item_id
    LEFT JOIN PurchaseUnits pu ON pi.purchase_item_id = pu.purchase_item_id
    GROUP BY i.item_id, i.item_name, i.category, i.brand
    ORDER BY i.item_name ASC;
END;
$$;


ALTER FUNCTION public.stock_summary() OWNER TO postgres;
