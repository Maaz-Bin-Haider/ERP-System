# Module: `accounting_core`

> **Role:** The backbone of the entire financial system. Implements a standard double-entry bookkeeping structure via a Chart of Accounts and a Journal system. Every monetary transaction in Financee ultimately writes to these three tables.

---

## Folder Structure

```
accounting_core/
└── tables/
    ├── chartofaccounts.sql   ← Account master (hierarchical, 5 account types)
    ├── journalentries.sql    ← Journal entry headers (one per transaction)
    └── journallines.sql      ← Debit/credit line items for each entry
```

---

## Tables

### `chartofaccounts`

The hierarchical master list of all ledger accounts in the system.

| Column | Type | Notes |
|--------|------|-------|
| `account_id` | bigint PK | Auto-incremented via sequence |
| `account_code` | varchar(20) UNIQUE | Short alphanumeric code (e.g. `1001`) |
| `account_name` | varchar(150) | Display name (e.g. `Cash`, `Accounts Receivable`) |
| `account_type` | varchar(20) | One of: `Asset`, `Liability`, `Equity`, `Revenue`, `Expense` |
| `parent_account` | bigint FK → self | Enables account hierarchy; NULL for top-level accounts |
| `date_created` | timestamp | Defaults to `CURRENT_TIMESTAMP` |

**Constraints:**
- `account_code` must be unique across all accounts
- `account_type` is validated by a CHECK constraint to the five standard types
- `parent_account` self-references the same table (ON DELETE SET NULL — parent deletion doesn't cascade)

**Design Notes:**
- Supports tree-structured COA (e.g. `Assets → Current Assets → Cash`)
- Special account names like `Accounts Receivable`, `Accounts Payable`, `Owner's Capital`, and `Cost of Goods Sold` are referenced by name in trigger functions — these must exist for the system to function correctly
- Expense-type parties use their own dedicated expense accounts (not the generic Expense category)

---

### `journalentries`

One row per journal entry (the "header" of a double-entry pair or group).

| Column | Type | Notes |
|--------|------|-------|
| `journal_id` | bigint PK | Auto-incremented via sequence |
| `entry_date` | date | The accounting date; defaults to `CURRENT_DATE` |
| `description` | text | Human-readable description of the transaction |
| `date_created` | timestamp | System timestamp of when the entry was inserted |

**Design Notes:**
- This table is primarily written to by trigger functions, not directly by application code
- Deleting a `journalentry` cascades to all its `journallines` (ON DELETE CASCADE)
- When a payment or receipt is updated, its old journal entry is deleted and a new one is created, keeping the ledger clean

---

### `journallines`

Individual debit or credit line items belonging to a journal entry.

| Column | Type | Notes |
|--------|------|-------|
| `line_id` | bigint PK | Auto-incremented via sequence |
| `journal_id` | bigint FK → journalentries | ON DELETE CASCADE |
| `account_id` | bigint FK → chartofaccounts | The ledger account being debited or credited |
| `party_id` | bigint FK → parties | Optional; links the line to a specific party (for AR/AP tracking) |
| `debit` | numeric(14,2) | Defaults to 0 |
| `credit` | numeric(14,2) | Defaults to 0 |

**Constraints:**
- Both `debit` and `credit` must be ≥ 0
- At least one of `debit` or `credit` must be > 0 (cannot be an empty line)
- `party_id` is nullable — set on AR/AP lines, NULL on cash/expense lines
- `party_id` ON DELETE SET NULL — party deletion orphans the line but does not remove the journal

**Design Notes:**
- The `party_id` on journal lines is the mechanism for tracking per-party balances (AR/AP)
- Reporting views (e.g. `vw_trial_balance`) join `journallines` to `chartofaccounts` and group by `party_id` to compute individual party balances
- The `detailed_ledger` function computes running balances using `SUM() OVER (ORDER BY entry_date ROWS UNBOUNDED PRECEDING)`

---

## How Journal Entries Are Created

Journal entries are **never created directly by application code**. They are created by:

1. **Triggers on `payments` and `receipts`** — `trg_payment_journal` / `trg_receipt_journal` fire on INSERT, UPDATE, and DELETE
2. **Triggers on `parties`** — `trg_party_opening_balance` fires on INSERT if `opening_balance > 0`
3. **Stored functions for purchases and sales** — `create_purchase_*`, `create_sale_*` functions insert journal entries as part of their transaction

### Standard Journal Entry Patterns

| Transaction | Debit | Credit |
|-------------|-------|--------|
| Sale | Accounts Receivable (party) | Sales Revenue |
| Sale (COGS) | Cost of Goods Sold | Inventory / Stock |
| Purchase | Inventory / Stock | Accounts Payable (party) |
| Payment to Vendor | Accounts Payable (party) | Cash/Bank |
| Receipt from Customer | Cash/Bank | Accounts Receivable (party) |
| Opening Balance (Customer) | Accounts Receivable | Owner's Capital |
| Opening Balance (Vendor) | Owner's Capital | Accounts Payable |

---

## Dependencies

- **Used by:** Every other module. `journallines.account_id` → `chartofaccounts`. All transactional tables (`payments`, `receipts`, `purchaseinvoices`, etc.) hold a `journal_id` FK back to `journalentries`.
- **Depends on:** `parties` (for `party_id` on journal lines) and `auth_user` indirectly (via the source documents that create journal entries).
