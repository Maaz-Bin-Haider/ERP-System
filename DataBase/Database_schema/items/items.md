# Module: `items`

> **Role:** Manages the inventory item master catalogue and tracks all stock movements. Every product bought, sold, or returned must exist as an `items` row. Individual physical units are tracked by serial number via `purchaseunits` (in the `purchase` module).

---

## Folder Structure

```
items/
├── functions/
│   ├── add_item_from_json.sql          ← Create a new item from JSON payload
│   ├── get_items_json.sql              ← Return all items as JSON array
│   ├── get_item_by_name.sql            ← Fetch single item by exact name
│   ├── get_item_names_like.sql         ← Search items by name (ILIKE)
│   ├── get_serial_number_details.sql   ← Full details for a specific serial number
│   └── update_item_from_json.sql       ← Update item fields from JSON payload
└── tables/
    ├── items.sql                       ← Product master table
    └── stockmovements.sql              ← Aggregate stock IN/OUT log
```

---

## Tables

### `items`

The product catalogue. Every distinct product sold or purchased must have a row here.

| Column | Type | Notes |
|--------|------|-------|
| `item_id` | bigint PK | Auto-incremented via sequence |
| `item_name` | varchar(150) UNIQUE NOT NULL | Product name; must be unique |
| `item_code` | varchar(50) UNIQUE | Optional internal SKU/barcode |
| `category` | varchar(100) | Product category (e.g. "Laptops", "Phones") |
| `brand` | varchar(100) | Brand name |
| `storage` | varchar(100) | Storage/capacity descriptor (e.g. "256GB", "1TB") |
| `sale_price` | numeric(12,2) | Default selling price; defaults to 0.00 |
| `created_at` | timestamp | Defaults to `CURRENT_TIMESTAMP` |
| `updated_at` | timestamp | Defaults to `CURRENT_TIMESTAMP` |
| `created_by` | integer FK → auth_user | Audit field; SET NULL on user deletion |

**Constraints:**
- `item_name` is unique — no duplicate product names allowed
- `item_code` is unique if provided
- `sale_price` defaults to 0.00 and must accommodate up to 10 integer digits + 2 decimal places

**Design Notes:**
- The `items` table is purely a master catalogue. Actual stock counts are derived dynamically from `purchaseunits.in_stock` and `soldunits` — there is no `quantity` column here.
- Stock is tracked at the individual unit (serial number) level, not as aggregate counts on this table.
- `sale_price` is a default/suggested price; actual sold price per transaction is stored in `soldunits.sold_price`.

---

### `stockmovements`

A chronological ledger of all stock IN and OUT events. Provides an audit trail of inventory changes separate from the invoice/return tables.

| Column | Type | Notes |
|--------|------|-------|
| `movement_id` | bigint PK | Auto-incremented via sequence |
| `item_id` | bigint FK → items | Which product moved |
| `serial_number` | text | Serial number of the specific unit (if applicable) |
| `movement_type` | varchar(20) | Either `IN` or `OUT` (enforced by CHECK) |
| `reference_type` | varchar(50) | Source of movement: e.g. `Purchase`, `Sale`, `PurchaseReturn`, `SaleReturn` |
| `reference_id` | bigint | ID of the source record (e.g. `purchase_invoice_id`) |
| `movement_date` | timestamp | Defaults to `CURRENT_TIMESTAMP` |
| `quantity` | integer NOT NULL | Number of units moved |

**Constraints:**
- `movement_type` must be exactly `IN` or `OUT`
- `item_id` ON DELETE is not cascaded (movement history is preserved even if the item record changes)

**Design Notes:**
- This table acts as a secondary audit log. The primary stock calculation method is via `purchaseunits.in_stock` and joins on `soldunits`, as shown in `stock_report` view.
- `reference_type` + `reference_id` together form a polymorphic reference to the source document.

---

## Functions

### `add_item_from_json(json)`
Accepts a JSON object with item fields and inserts a new row into `items`. Returns the newly created item's ID or details. Used by the API layer to create items without raw SQL.

### `update_item_from_json(bigint, json)`
Updates an existing item (by `item_id`) with fields provided in a JSON payload. Allows partial updates — only provided fields are changed.

### `get_items_json()`
Returns all items from the `items` table serialized as a JSON array. Used by dropdowns and item selection UIs.

### `get_item_by_name(text)`
Fetches a single item record by its exact `item_name`. Returns item details as a row or JSON. Used for lookup when the name is already known.

### `get_item_names_like(text)`
Performs an `ILIKE` search on `item_name`, returning matching names. Powers autocomplete/search UI components.

### `get_serial_number_details(text)`
Given a serial number, returns full traceability details: the item it belongs to, the purchase invoice, purchase date, vendor, current stock status, and whether it has been sold or returned. Cross-joins `purchaseunits`, `purchaseitems`, `purchaseinvoices`, `items`, and `parties`.

---

## Dependencies

- **Depends on:** `auth_user` (created_by)
- **Used by:** `purchase`, `purchaseReturn`, `sale`, `saleReturn`, `stockmovements`, `stockReports`
