# Module: `stockReports`

> **Role:** Provides inventory reporting — current stock levels, stock valuations, serial number traceability, and full transaction history per item. All functions and views query the purchase/sale/return tables and return structured results for reporting screens.

---

## Folder Structure

```
stockReports/
├── functions/
│   ├── stock_summary.sql                                   ← Current stock count per item
│   ├── get_item_stock_by_name.sql                          ← Stock for a specific item
│   ├── item_transaction_history_text_.sql                  ← All transactions for an item
│   ├── item_transaction_history_text__date__date_.sql      ← Transaction history with date filter
│   ├── get_serial_ledger.sql                               ← Full life of a serial number
│   ├── get_serial_ledger_purchase.sql                      ← Purchase side of serial history
│   └── get_serial_ledger_sales.sql                         ← Sales side of serial history
└── views/
    ├── stock_report.sql                                    ← Detailed per-unit stock listing
    ├── stock_worth_report.sql                              ← Stock valuation (qty × purchase price)
    ├── item_last_purchase_view.sql                         ← Most recent purchase per item
    └── item_last_sale_view.sql                             ← Most recent sale per item
```

---

## Views

### `stock_report`
The primary inventory view. Shows every unit currently in stock with full details:

| Column | Description |
|--------|-------------|
| `item_id` | Shown only on first row per item (grouped display) |
| `item_name` | Item name (shown only on first row per item) |
| `quantity` | Total units in stock for this item (window function) |
| `serial_number` | Individual unit serial number |
| `serial_comment` | Notes on the specific unit |
| `age_in_days` | Days since purchase date (`CURRENT_DATE - invoice_date`) |
| `age_in_months` | Age rounded to 1 decimal month |

**Filters:** Only shows units where:
- `purchaseunits.in_stock = true`
- No matching `soldunits` row with `status = 'Sold'`
- No matching `purchasereturnitems` row (unit hasn't been returned to vendor)

Uses `ROW_NUMBER() OVER (PARTITION BY item_id)` and `COUNT() OVER (PARTITION BY item_id)` for grouped display formatting.

---

### `stock_worth_report`
Extends `stock_report` with valuation data. Computes:
- `purchase_price` per unit (from `purchaseitems.unit_price`)
- `total_worth` = `quantity × purchase_price` per item
- `suggested_sale_value` using `items.sale_price`
- Overall portfolio cost and projected revenue

Used for balance sheet inventory valuation and purchasing decisions.

---

### `item_last_purchase_view`
Shows the most recent purchase details for each item:
- Last `invoice_date`
- Last `unit_price` paid
- Vendor name
- Purchase invoice ID

Built by ranking `purchaseinvoices` rows partitioned by `item_id` and taking `rank = 1`. Useful for price trend analysis.

---

### `item_last_sale_view`
Shows the most recent sale details for each item:
- Last `invoice_date`
- Last `sold_price`
- Customer name
- Sales invoice ID

Built similarly to `item_last_purchase_view`. Used for pricing decisions and customer activity.

---

## Functions

### `stock_summary()`
Returns a simplified JSON array of all items with their current in-stock quantity. Faster than the full `stock_report` view for dashboard-level counts. Groups by item and counts `purchaseunits WHERE in_stock = true`.

### `get_item_stock_by_name(p_item_name text)`
Returns detailed stock information for a single item identified by name. Returns all in-stock serial numbers, purchase dates, ages, and comments for that item.

### `item_transaction_history_text_(p_item_name text)`
Returns the complete transaction history for an item — every purchase, sale, purchase return, and sale return that involved this item, sorted chronologically. Each row includes:
- Transaction type (Purchase / Sale / Purchase Return / Sale Return)
- Date, quantity, price, party name, reference ID

### `item_transaction_history_text__date__date_(p_item_name text, p_from date, p_to date)`
Same as above but filtered to a specific date range. Used for period-based inventory audits.

### `get_serial_ledger(p_serial text)`
The most detailed traceability function. Given a serial number, returns the complete lifecycle:
1. **Purchase event:** when purchased, from whom, at what price, on which invoice
2. **Sale event** (if sold): when sold, to whom, at what price, on which invoice
3. **Return events** (if any): purchase return or sale return details
4. **Current status:** in stock / sold / returned

Returns a chronological table of events with journal references.

### `get_serial_ledger_purchase(p_serial text)`
Returns only the purchase side of a serial number's history: which purchase invoice, which vendor, date, and purchase price. Used when only procurement traceability is needed.

### `get_serial_ledger_sales(p_serial text)`
Returns only the sales side of a serial number's history: which sales invoice, which customer, date, sold price, and current status. Used for warranty and customer service lookups.

---

## Dependencies

- **Depends on:** `items`, `purchaseinvoices`, `purchaseitems`, `purchaseunits`, `purchasereturnitems`, `salesinvoices`, `salesitems`, `soldunits`, `salesreturnitems`, `parties`
- **Used by:** Frontend stock management screens; `home` uses `vw_dash_stock_overview` for dashboard counts
