# Module: `sale`

> **Role:** Manages customer sales invoices with full serial-number tracking. Each sale records which specific purchased units (by serial number) were sold, at what price, to which customer. Automatic journal entries post revenue and COGS. Supports full invoice lifecycle: create, update, delete, navigate.

---

## Folder Structure

```
sale/
├── functions/
│   ├── create_sale_bigint__date__jsonb_.sql                   ← Create sale (no warehouse)
│   ├── create_sale_bigint__date__jsonb__integer_.sql          ← Create sale (with warehouse)
│   ├── update_sale_invoice_bigint__jsonb__text__date_.sql     ← Full invoice update
│   ├── update_sale_invoice_bigint__jsonb__text__date__integer_.sql ← Update with warehouse
│   ├── delete_sale.sql                                         ← Delete a sale
│   ├── validate_sales_delete.sql                               ← Pre-delete validation
│   ├── validate_sales_update.sql                               ← Pre-update validation
│   ├── rebuild_sales_journal.sql                               ← Re-create journal
│   ├── get_current_sale.sql                                    ← Fetch sale by ID
│   ├── get_sales_summary.sql                                   ← Summary with line items
│   ├── get_last_sale.sql                                       ← Most recent sale
│   ├── get_last_sale_id.sql                                    ← Most recent sale ID only
│   ├── get_next_sale.sql                                       ← Navigation: next
│   └── get_previous_sale.sql                                   ← Navigation: previous
└── tables/
    ├── salesinvoices.sql   ← Invoice header
    ├── salesitems.sql      ← Line items (item + qty + unit price)
    └── soldunits.sql       ← Individual sold units (serial-level)
```

---

## Tables

### `salesinvoices`

One row per sales invoice.

| Column | Type | Notes |
|--------|------|-------|
| `sales_invoice_id` | bigint PK | Auto-incremented |
| `customer_id` | bigint FK → parties | The buying customer; ON DELETE CASCADE |
| `invoice_date` | date | Defaults to `CURRENT_DATE` |
| `total_amount` | numeric(14,2) NOT NULL | Total invoice value |
| `journal_id` | bigint FK → journalentries | Linked journal entry; SET NULL on delete |
| `created_by` | integer FK → auth_user | Audit field |

---

### `salesitems`

Line items within a sales invoice — one row per item type sold.

| Column | Type | Notes |
|--------|------|-------|
| `sales_item_id` | bigint PK | Auto-incremented |
| `sales_invoice_id` | bigint FK → salesinvoices | ON DELETE CASCADE |
| `item_id` | bigint FK → items | Which product was sold |
| `quantity` | integer NOT NULL | Must be > 0 (CHECK constraint) |
| `unit_price` | numeric(12,2) NOT NULL | Selling price per unit on this invoice |

---

### `soldunits`

Individual physical unit sales — one row per serial number sold. Links the sold unit back to the exact `purchaseunits` row, enabling cost-of-goods-sold calculation.

| Column | Type | Notes |
|--------|------|-------|
| `sold_unit_id` | bigint PK | Auto-incremented |
| `sales_item_id` | bigint FK → salesitems | ON DELETE CASCADE |
| `unit_id` | bigint FK → purchaseunits | The exact purchased unit being sold |
| `sold_price` | numeric(12,2) NOT NULL | Actual selling price for this specific unit |
| `status` | varchar(20) | `Sold`, `Returned`, or `Damaged`; defaults to `Sold` |

**Key design:** The `soldunits.unit_id → purchaseunits.unit_id` link is what allows per-unit profit calculation: `sold_price - purchaseunits.unit_price = gross profit per unit`.

---

## Key Functions

### `create_sale_bigint__date__jsonb_(customer_id, date, items_json)`
Main sale creation function. Accepts a customer ID, invoice date, and a JSON array of items (each with `item_id`, `quantity`, `unit_price`, and an array of `serial_numbers` to sell). Per transaction:
1. Inserts `salesinvoices` header
2. For each item: inserts `salesitems` row
3. For each serial number: finds the matching `purchaseunits` row, sets `in_stock = false`, inserts `soldunits` row
4. Posts journal: DEBIT Customer AR, CREDIT Sales Revenue + DEBIT COGS, CREDIT Inventory
5. Records `stockmovements` OUT records

### `delete_sale(sales_invoice_id)`
Deletes a sale and cascades. First validates via `validate_sales_delete` that none of the sold units have been returned (a sale cannot be deleted if any items have come back as `saleReturn` entries).

### `validate_sales_delete(sales_invoice_id)` / `validate_sales_update(sales_invoice_id, items_json)`
Guard functions that check for downstream dependencies before allowing modification. A sale with returned units or units referenced in reports is protected from casual deletion.

### `rebuild_sales_journal(sales_invoice_id)`
Regenerates the complete double-entry journal for a sale from scratch by scanning `salesitems` and `soldunits`. Used for data repair.

---

## Journal Entry Pattern for Sale

```
Entry 1 — Revenue recognition:
    DEBIT  → Customer AR Account (party)    (customer owes us)
    CREDIT → Sales Revenue Account          (revenue earned)

Entry 2 — Cost of goods sold:
    DEBIT  → Cost of Goods Sold Account     (expense recognized)
    CREDIT → Inventory/Stock Account        (asset leaves)
```

---

## Dependencies

- **Depends on:** `parties` (customer), `items`, `purchaseunits` (unit_id FK), `chartofaccounts`, `journalentries`, `auth_user`
- **Used by:** `saleReturn`, `stockReports`, `accountsReports`, `home` (dashboard KPIs)

---
---

# Module: `saleReturn`

> **Role:** Handles customer returns of sold goods (credit notes). Each return specifies which serial numbers are coming back, records both the original sell price and cost price for accurate reversal, and posts correcting journal entries. Returned units are put back into stock.

---

## Folder Structure

```
saleReturn/
├── functions/
│   ├── create_sale_return_text__jsonb_.sql                ← Create return (no warehouse)
│   ├── create_sale_return_text__jsonb__integer_.sql       ← Create return (with warehouse)
│   ├── update_sale_return_bigint__jsonb_.sql              ← Update return
│   ├── update_sale_return_bigint__jsonb__integer_.sql     ← Update return with warehouse
│   ├── delete_sale_return.sql                             ← Delete a return
│   ├── get_current_sales_return.sql                       ← Fetch return by ID
│   ├── get_sales_return_summary.sql                       ← Summary with items
│   ├── get_last_sales_return.sql                          ← Most recent return
│   ├── get_last_sales_return_id.sql                       ← Most recent return ID
│   ├── get_next_sales_return.sql                          ← Navigation: next
│   ├── get_previous_sales_return.sql                      ← Navigation: previous
│   ├── serial_exists_in_sales_return.sql                  ← Check if serial already returned
│   └── rebuild_sales_return_journal.sql                   ← Re-create journal
└── tables/
    ├── salesreturns.sql        ← Return header
    └── salesreturnitems.sql    ← Items returned (serial-level)
```

---

## Tables

### `salesreturns`

Header record for a customer return.

| Column | Type | Notes |
|--------|------|-------|
| `sales_return_id` | bigint PK | Auto-incremented |
| `customer_id` | bigint FK → parties | The customer returning goods; ON DELETE CASCADE |
| `return_date` | date | Defaults to `CURRENT_DATE` |
| `total_amount` | numeric(14,2) | Total value being refunded; defaults to 0 |
| `journal_id` | bigint FK → journalentries | Linked journal entry |
| `created_by` | integer FK → auth_user | Audit field |

---

### `salesreturnitems`

One row per unit returned. Captures both sell price and cost price for complete reversal.

| Column | Type | Notes |
|--------|------|-------|
| `return_item_id` | bigint PK | Auto-incremented |
| `sales_return_id` | bigint FK → salesreturns | ON DELETE CASCADE |
| `item_id` | bigint FK → items | Which product type |
| `sold_price` | numeric(12,2) | Price at which it was originally sold (for refund) |
| `cost_price` | numeric(12,2) | Purchase cost (for COGS reversal) |
| `serial_number` | varchar(100) NOT NULL | The specific unit coming back |

**Design note:** Both `sold_price` and `cost_price` are stored here because both must be reversed: the revenue entry and the COGS entry from the original sale must be unwound separately.

---

## Key Functions

### `create_sale_return_text__jsonb_(customer_name, items_json)`
Creates a sale return. For each returned serial number:
1. Validates the serial hasn't already been returned (`serial_exists_in_sales_return`)
2. Sets `soldunits.status = 'Returned'` for the original sold unit
3. Sets `purchaseunits.in_stock = true` to put the unit back in stock
4. Posts reverse journal: DEBIT Sales Revenue (reversal), CREDIT Customer AR (refund)
5. Posts COGS reversal: DEBIT Inventory, CREDIT COGS

### `serial_exists_in_sales_return(text)`
Returns true if a given serial number is already in `salesreturnitems`. Prevents duplicate return processing.

### `rebuild_sales_return_journal(sales_return_id)`
Regenerates the journal entry for a sales return from scratch. For data repair scenarios.

---

## Journal Entry Pattern for Sale Return

```
Entry 1 — Revenue reversal:
    DEBIT  → Sales Revenue Account          (revenue reduced)
    CREDIT → Customer AR Account (party)    (customer credit issued)

Entry 2 — COGS reversal:
    DEBIT  → Inventory/Stock Account        (asset restored)
    CREDIT → Cost of Goods Sold Account     (expense reduced)
```

---

## Dependencies

- **Depends on:** `parties`, `items`, `salesinvoices`/`soldunits` (for serial validation), `purchaseunits` (in_stock update), `journalentries`, `auth_user`
- **Used by:** `stockReports` (serial ledger), `accountsReports`
