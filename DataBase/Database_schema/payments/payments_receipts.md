# Module: `payments`

> **Role:** Records outgoing payments made to vendors. Every payment automatically generates a double-entry journal entry via a trigger, debiting the vendor's AP account and crediting the selected cash/bank account. Supports multiple payment methods and navigation between payment records.

---

## Folder Structure

```
payments/
├── functions/
│   ├── make_payment.sql                ← Create a new payment
│   ├── update_payment.sql              ← Modify an existing payment
│   ├── delete_payment.sql              ← Remove a payment (and its journal)
│   ├── get_payment_details.sql         ← Full details for one payment
│   ├── get_last_20_payments_json.sql   ← Latest 20 payments as JSON
│   ├── get_payments_by_date_json.sql   ← Payments filtered by date range
│   ├── get_last_payment.sql            ← Most recent payment record
│   ├── get_next_payment.sql            ← Navigation: next payment by ID
│   └── get_previous_payment.sql        ← Navigation: previous payment by ID
├── tables/
│   └── payments.sql                    ← Payment records table
├── triggers/
│   ├── trg_payment_insert.sql          ← AFTER INSERT trigger
│   ├── trg_payment_update.sql          ← AFTER UPDATE trigger
│   └── trg_payment_delete.sql          ← AFTER DELETE trigger
└── trigger_functions/
    └── trg_payment_journal.sql         ← Auto-journal on insert/update/delete
```

---

## Table: `payments`

| Column | Type | Notes |
|--------|------|-------|
| `payment_id` | bigint PK | Auto-incremented via sequence |
| `party_id` | bigint FK → parties | The vendor being paid; ON DELETE CASCADE |
| `account_id` | bigint FK → chartofaccounts | Cash or bank account being debited |
| `amount` | numeric(14,4) NOT NULL | Must be > 0 (CHECK constraint) |
| `payment_date` | date | Defaults to `CURRENT_DATE` |
| `method` | varchar(20) | `Cash`, `Bank`, `Cheque`, or `Online` |
| `reference_no` | varchar(100) | Cheque number, transfer ID, etc. |
| `journal_id` | bigint FK → journalentries | Linked journal entry; SET NULL on delete |
| `notes` | text | Internal notes |
| `description` | text | Used as journal entry description if set |
| `date_created` | timestamp | Defaults to `CURRENT_TIMESTAMP` |
| `created_by` | integer FK → auth_user | Audit field |

**Constraints:**
- `amount > 0` enforced by CHECK
- `method` must be one of: `Cash`, `Bank`, `Cheque`, `Online`
- `party_id` ON DELETE CASCADE — deleting a vendor removes their payments
- A separate sequence `payments_ref_seq` exists for auto-generating reference numbers

---

## Trigger: Auto-Journal on Payment

All three triggers (`trg_payment_insert`, `trg_payment_update`, `trg_payment_delete`) call the same function `trg_payment_journal()`.

### `trg_payment_journal()` — Logic Summary

```
ON DELETE:
    DELETE from JournalEntries WHERE journal_id = OLD.journal_id
    (cascades to JournalLines automatically)

ON UPDATE:
    If amount, account_id, party_id, description, or payment_date changed:
        DELETE old JournalEntries
        Re-create as if INSERT
    Else: no-op (skip re-journal)

ON INSERT / UPDATE (new journal creation):
    1. Look up vendor's AP account from parties.ap_account_id
    2. Create JournalEntry with payment_date and description
    3. Link journal_id back to payments row
       (uses session_replication_role = replica to prevent trigger recursion)
    4. DEBIT  → vendor's AP account (reduces liability)
    5. CREDIT → selected cash/bank account
```

**Error Handling:** Raises an exception if the vendor has no AP account configured.

---

## Functions Summary

| Function | Purpose |
|----------|---------|
| `make_payment` | Full payment creation with validation |
| `update_payment` | Modify payment; trigger handles journal re-creation |
| `delete_payment` | Delete payment; trigger removes journal entry |
| `get_payment_details` | Single payment with party name, account name, journal info |
| `get_last_20_payments_json` | Dashboard/list: 20 most recent payments as JSON |
| `get_payments_by_date_json` | Filter payments between two dates, return JSON |
| `get_last_payment` | Fetch the highest `payment_id` (most recent) |
| `get_next_payment(id)` | Navigation: next record after given ID |
| `get_previous_payment(id)` | Navigation: previous record before given ID |

---

## Dependencies

- **Depends on:** `parties` (vendor + AP account), `chartofaccounts` (account_id), `journalentries` (journal_id), `auth_user` (created_by)
- **Used by:** `accountsReports` (ledger, trial balance), `home` (dashboard KPIs)

---
---

# Module: `receipts`

> **Role:** Records incoming payments from customers. Mirrors the `payments` module exactly — every receipt automatically generates a double-entry journal entry debiting the cash/bank account and crediting the customer's AR account.

---

## Folder Structure

```
receipts/
├── functions/
│   ├── make_receipt.sql                ← Create a new receipt
│   ├── update_receipt.sql              ← Modify an existing receipt
│   ├── delete_receipt.sql              ← Remove a receipt (and its journal)
│   ├── get_receipt_details.sql         ← Full details for one receipt
│   ├── get_last_20_receipts_json.sql   ← Latest 20 receipts as JSON
│   ├── get_receipts_by_date_json.sql   ← Receipts filtered by date range
│   ├── get_last_receipt.sql            ← Most recent receipt record
│   ├── get_next_receipt.sql            ← Navigation: next receipt by ID
│   └── get_previous_receipt.sql        ← Navigation: previous receipt by ID
├── tables/
│   └── receipts.sql                    ← Receipt records table
├── triggers/
│   ├── trg_receipt_insert.sql          ← AFTER INSERT trigger
│   ├── trg_receipt_update.sql          ← AFTER UPDATE trigger
│   └── trg_receipt_delete.sql          ← AFTER DELETE trigger
└── trigger_functions/
    └── trg_receipt_journal.sql         ← Auto-journal on insert/update/delete
```

---

## Table: `receipts`

Structurally identical to `payments` — mirrors every field with receipt-specific naming.

| Column | Type | Notes |
|--------|------|-------|
| `receipt_id` | bigint PK | Auto-incremented via sequence |
| `party_id` | bigint FK → parties | The customer paying; ON DELETE CASCADE |
| `account_id` | bigint FK → chartofaccounts | Cash or bank account receiving funds |
| `amount` | numeric(14,4) NOT NULL | Must be > 0 |
| `receipt_date` | date | Defaults to `CURRENT_DATE` |
| `method` | varchar(20) | `Cash`, `Bank`, `Cheque`, or `Online` |
| `reference_no` | varchar(100) | Cheque number, transfer ref, etc. |
| `journal_id` | bigint FK → journalentries | Linked journal entry |
| `notes` | text | Internal notes |
| `description` | text | Journal description override |
| `date_created` | timestamp | Defaults to `CURRENT_TIMESTAMP` |
| `created_by` | integer FK → auth_user | Audit field |

---

## Trigger: Auto-Journal on Receipt

### `trg_receipt_journal()` — Logic Summary

```
ON DELETE:
    DELETE from JournalEntries WHERE journal_id = OLD.journal_id

ON UPDATE:
    If financial fields changed: delete old journal, re-create
    Else: no-op

ON INSERT / UPDATE (new journal creation):
    1. Look up customer's AR account from parties.ar_account_id
    2. Create JournalEntry
    3. Link journal_id back to receipts row
    4. DEBIT  → cash/bank account (money received)
    5. CREDIT → customer's AR account (reduces receivable)
```

---

## Functions Summary

| Function | Purpose |
|----------|---------|
| `make_receipt` | Full receipt creation |
| `update_receipt` | Modify receipt; trigger handles journal |
| `delete_receipt` | Delete receipt; trigger removes journal |
| `get_receipt_details` | Single receipt with party and account info |
| `get_last_20_receipts_json` | 20 most recent receipts as JSON |
| `get_receipts_by_date_json` | Filter by date range, return JSON |
| `get_last_receipt` | Most recent receipt ID |
| `get_next_receipt(id)` | Navigation: next record |
| `get_previous_receipt(id)` | Navigation: previous record |

---

## Dependencies

- **Depends on:** `parties` (customer + AR account), `chartofaccounts`, `journalentries`, `auth_user`
- **Used by:** `accountsReports` (ledger, AR aging), `home` (dashboard KPIs, smart alerts)
