# Profit Report Functions - Complete Documentation

**Category:** Profit Report Functions
**Total Functions:** 1

---


## 💹 PROFIT REPORT FUNCTIONS

**Total Functions:** 1

---

### Function 1: `sale_wise_profit()`

#### Complete SQL Code:

```sql
CREATE OR REPLACE FUNCTION public.sale_wise_profit(
    p_from_date DATE, 
    p_to_date DATE
) RETURNS TABLE (
    sale_date DATE,
    item_name TEXT,
    serial_number TEXT,
    serial_comment TEXT,
    sale_price NUMERIC,
    purchase_price NUMERIC,
    profit_loss NUMERIC,
    profit_loss_percent NUMERIC,
    vendor_name TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH sold_serials AS (
        SELECT 
            su.sold_unit_id,
            su.sold_price,
            pu.serial_number::TEXT AS serial_number,
            pu.serial_comment::TEXT AS serial_comment,
            si.sales_item_id,
            s.sales_invoice_id,
            s.invoice_date AS sale_date,
            i.item_name::TEXT AS item_name,
            i.item_code,
            i.brand,
            i.category,
            si.item_id,
            pu.unit_id
        FROM SoldUnits su
        JOIN PurchaseUnits pu ON su.unit_id = pu.unit_id
        JOIN SalesItems si ON su.sales_item_id = si.sales_item_id
        JOIN SalesInvoices s ON si.sales_invoice_id = s.sales_invoice_id
        JOIN Items i ON si.item_id = i.item_id
        WHERE s.invoice_date BETWEEN p_from_date AND p_to_date
    ),
    purchased_serials AS (
        SELECT 
            pu.unit_id,
            pu.serial_number::TEXT AS serial_number,
            pi.purchase_item_id,
            p.purchase_invoice_id,
            p.vendor_id,
            i.item_id,
            i.item_name::TEXT AS item_name,
            pi.unit_price AS purchase_price
        FROM PurchaseUnits pu
        JOIN PurchaseItems pi ON pu.purchase_item_id = pi.purchase_item_id
        JOIN PurchaseInvoices p ON pi.purchase_invoice_id = p.purchase_invoice_id
        JOIN Items i ON pi.item_id = i.item_id
    )
    SELECT 
        ss.sale_date,
        ss.item_name,
        ss.serial_number,
        ss.serial_comment,
        ss.sold_price AS sale_price,
        ps.purchase_price,
        ROUND(ss.sold_price - ps.purchase_price, 2) AS profit_loss,
        CASE 
            WHEN ps.purchase_price > 0 THEN 
                ROUND(((ss.sold_price - ps.purchase_price) / ps.purchase_price) * 100, 2)
            ELSE 
                NULL
        END AS profit_loss_percent,
        v.party_name::TEXT AS vendor_name
    FROM sold_serials ss
    LEFT JOIN purchased_serials ps 
        ON ss.unit_id = ps.unit_id
    LEFT JOIN Parties v 
        ON ps.vendor_id = v.party_id
    ORDER BY ss.sale_date, ss.item_name, ss.serial_number;
END;
$$;
```

#### Parameters:
- `p_from_date DATE`
- `p_to_date DATE`

#### Returns:
`TABLE (
    sale_date DATE,
    item_name TEXT,
    serial_number TEXT,
    serial_comment TEXT,
    sale_price NUMERIC,
    purchase_price NUMERIC,
    profit_loss NUMERIC,
    profit_loss_percent NUMERIC,
    vendor_name TEXT
)`

#### Purpose:
Sale Wise Profit - Performs specialized database operation.

#### Example SQL Call:

```sql
SELECT sale_wise_profit(..., ...);
```

#### Function Behavior:
See complete SQL implementation above for detailed logic.

---

