# Module: `purchase`

> **Role:** Manages vendor purchase invoices with full serial-number tracking. Each purchase records which units (by serial number) were acquired, at what price, and from which vendor. A journal entry is automatically created when a purchase is posted. Supports creation, update, deletion, and navigation with extensive validation.

---

## Folder Structure

```
purchase/
├── functions/
│   ├── create_purchase_bigint__date__jsonb_.sql               ← Create purchase (no warehouse)
│   ├── create_purchase_bigint__date__jsonb__integer_.sql      ← Create purchase (with warehouse)
│   ├── update_purchase_invoice_bigint__jsonb__text__date_.sql ← Full invoice update
│   ├── update_purchase_invoice_bigint__jsonb__text__date__integer_.sql ← Update with warehouse
│   ├── update_purchase_items_bigint__jsonb_.sql               ← Update items only
│   ├── update_purchase_items_bigint__jsonb__text_.sql         ← Update items with serial handling
│   ├── delete_purchase.sql                                    ← Delete a purchase invoice
│   ├── validate_purchase_delete.sql                           ← Pre-delete validation
│   ├── validate_purchase_update.sql                           ← Pre-update validation
│   ├── validate_purchase_update2.sql                          ← Extended update validation
│   ├── get_current_purchase.sql                               ← Fetch purchase by ID
│   ├── get_purchase_summary.sql                               ← Summary with line items
│   ├── get_last_purchase.sql                                  ← Most recent purchase
│   ├── get_last_purchase_id.sql                               ← Most recent purchase ID only
│   ├── get_next_purchase.sql                                  ← Navigation: next
│   ├── get_previous_purchase.sql                              ← Navigation: previous
│   └── rebuild_purchase_journal.sql                           ← Re-create journal from scratch
└── tables/
    ├── purchaseinvoices.sql   ← Invoice header
    ├── purchaseitems.sql      ← Line items (item + qty + unit price)
    └── purchaseunits.sql      ← Individual units with serial numbers
```

---

## Tables

### `purchaseinvoices`

One row per purchase invoice (the document-level record).

| Column | Type | Notes |
|--------|------|-------|
| `purchase_invoice_id` | bigint PK | Auto-incremented |
| `vendor_id` | bigint FK → parties | The vendor supplying goods; ON DELETE CASCADE |
| `invoice_date` | date | Defaults to `CURRENT_DATE` |
| `total_amount` | numeric(14,2) NOT NULL | Sum of all line items |
| `journal_id` | bigint FK → journalentries | Linked accounting entry; SET NULL on delete |
| `created_by` | integer FK → auth_user | Audit field |

---

### `purchaseitems`

Line items within a purchase invoice — one row per item type purchased.

| Column | Type | Notes |
|--------|------|-------|
| `purchase_item_id` | bigint PK | Auto-incremented |
| `purchase_invoice_id` | bigint FK → purchaseinvoices | ON DELETE CASCADE |
| `item_id` | bigint FK → items | Which product was purchased |
| `quantity` | integer NOT NULL | Must be > 0 (CHECK constraint) |
| `unit_price` | numeric(12,2) NOT NULL | Price per unit at time of purchase |

---

### `purchaseunits`

Individual physical units — one row per serial number purchased. This is the heart of the serial-number tracking system.

| Column | Type | Notes |
|--------|------|-------|
| `unit_id` | bigint PK | Auto-incremented |
| `purchase_item_id` | bigint FK → purchaseitems | ON DELETE CASCADE |
| `serial_number` | varchar(100) UNIQUE NOT NULL | Must be globally unique across all purchases |
| `in_stock` | boolean | `true` if unit is currently in inventory |
| `serial_comment` | text | Notes about this specific unit (condition, specs, etc.) |

**Critical constraint:** `serial_number` is globally unique — no two units across any purchase can share a serial number. This ensures traceability at the individual unit level.

---

## Key Functions

### `create_purchase_bigint__date__jsonb_(vendor_id, date, items_json)`
Main purchase creation function. Accepts a vendor ID, invoice date, and a JSON array of items (each with `item_id`, `quantity`, `unit_price`, and an array of `serial_numbers`). In a single transaction:
1. Inserts `purchaseinvoices` header
2. For each item in JSON: inserts `purchaseitems` row and one `purchaseunits` row per serial number
3. Creates a double-entry journal: DEBIT Inventory/Asset accounts, CREDIT vendor AP account
4. Updates `stockmovements` with IN records

### `delete_purchase(purchase_invoice_id)`
Deletes a purchase invoice and cascades to `purchaseitems` and `purchaseunits`. First calls `validate_purchase_delete` to ensure no units from this invoice have been sold (cannot delete a purchase if any of its units appear in `soldunits`).

### `validate_purchase_delete(purchase_invoice_id)`
Pre-deletion check: queries `soldunits` to see if any `purchaseunits.unit_id` from this invoice has been sold. Returns an error or OK status. Prevents inventory integrity violations.

### `validate_purchase_update(purchase_invoice_id, items_json)`
Pre-update validation: checks if any serial numbers being removed or changed are already sold or returned, preventing data corruption during edits.

### `rebuild_purchase_journal(purchase_invoice_id)`
Deletes and regenerates the journal entry for a specific purchase invoice from scratch, based on current `purchaseitems` data. Useful for fixing corrupted or missing journal entries.

### Navigation Functions
`get_last_purchase`, `get_last_purchase_id`, `get_next_purchase(id)`, `get_previous_purchase(id)` — enable record-by-record navigation through purchase invoices in the UI.

---

## Journal Entry Pattern for Purchase

```
DEBIT  → Inventory/Stock Account       (asset increases)
CREDIT → Vendor AP Account (party)     (liability increases — we owe vendor)
```

---

## Dependencies

- **Depends on:** `parties` (vendor), `items`, `chartofaccounts`, `journalentries`, `auth_user`
- **Used by:** `purchaseReturn` (references serial numbers), `sale` (purchaseunits are sold via soldunits), `stockReports`, `accountsReports`

---
---

# Module: `purchaseReturn`

> **Role:** Handles returns of purchased goods back to vendors (debit notes). Each purchase return references specific serial numbers that are being returned, reverses the inventory entry, and posts a correcting journal entry (reverse of the original purchase journal).

---

## Folder Structure

```
purchaseReturn/
├── functions/
│   ├── create_purchase_return_text__jsonb_.sql             ← Create return (no warehouse)
│   ├── create_purchase_return_text__jsonb__integer_.sql    ← Create return (with warehouse)
│   ├── update_purchase_return_bigint__jsonb_.sql           ← Update return
│   ├── update_purchase_return_bigint__jsonb__integer_.sql  ← Update return with warehouse
│   ├── delete_purchase_return.sql                          ← Delete a return
│   ├── get_current_purchase_return.sql                     ← Fetch return by ID
│   ├── get_purchase_return_summary.sql                     ← Summary with items
│   ├── get_last_purchase_return.sql                        ← Most recent return
│   ├── get_last_purchase_return_id.sql                     ← Most recent return ID
│   ├── get_next_purchase_return.sql                        ← Navigation: next
│   ├── get_previous_purchase_return.sql                    ← Navigation: previous
│   ├── serial_exists_in_purchase_return.sql                ← Check if serial already returned
│   └── rebuild_purchase_return_journal.sql                 ← Re-create journal
└── tables/
    ├── purchasereturns.sql        ← Return invoice header
    └── purchasereturnitems.sql    ← Individual items (serial-level)
```

---

## Tables

### `purchasereturns`

Header record for a vendor return.

| Column | Type | Notes |
|--------|------|-------|
| `purchase_return_id` | bigint PK | Auto-incremented |
| `vendor_id` | bigint FK → parties | Vendor receiving the returned goods |
| `return_date` | date | Defaults to `CURRENT_DATE` |
| `total_amount` | numeric(14,2) | Sum of returned items' values; defaults to 0 |
| `journal_id` | bigint FK → journalentries | Linked journal entry |
| `created_by` | integer FK → auth_user | Audit field |

---

### `purchasereturnitems`

One row per unit returned. References by serial number (not unit_id FK) to maintain audit integrity.

| Column | Type | Notes |
|--------|------|-------|
| `return_item_id` | bigint PK | Auto-incremented |
| `purchase_return_id` | bigint FK → purchasereturns | ON DELETE CASCADE |
| `item_id` | bigint FK → items | Which product type |
| `unit_price` | numeric(12,2) | Price at which the unit was originally purchased |
| `serial_number` | varchar(100) NOT NULL | The specific unit being returned |

---

## Key Functions

### `create_purchase_return_text__jsonb_(vendor_name, items_json)`
Creates a purchase return from a vendor name and JSON array of items (each with `serial_number`, `item_id`, `unit_price`). Validates that:
- Each serial number exists in `purchaseunits`
- The serial has not already been returned (`serial_exists_in_purchase_return`)
- Sets `purchaseunits.in_stock = false` for returned units
- Posts a reverse journal: DEBIT AP (reduces liability), CREDIT Inventory

### `serial_exists_in_purchase_return(text)`
Utility function: returns true if a given serial number already appears in `purchasereturnitems`. Prevents double-returns of the same unit.

### `rebuild_purchase_return_journal(purchase_return_id)`
Re-creates the journal entry for a return from scratch. Used for data repair or post-edit journal correction.

---

## Journal Entry Pattern for Purchase Return

```
DEBIT  → Vendor AP Account (party)     (liability decreases — vendor owes us)
CREDIT → Inventory/Stock Account       (asset decreases — goods left our stock)
```

---

## Dependencies

- **Depends on:** `parties`, `items`, `purchaseinvoices`/`purchaseunits` (serial reference), `journalentries`, `auth_user`
- **Used by:** `stockReports` (serial ledger), `accountsReports`
