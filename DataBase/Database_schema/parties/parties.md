# Module: `parties`

> **Role:** Unified master table for all external entities — customers, vendors, expense parties, and entities that act as both. Every financial relationship (invoices, payments, receipts, journal lines) ties back to a party. Opening balances are automatically journalized via a trigger on insert.

---

## Folder Structure

```
parties/
├── functions/
│   ├── add_party_from_json.sql              ← Create new party from JSON
│   ├── get_parties_json.sql                 ← Return all parties as JSON
│   ├── get_party_by_name.sql                ← Fetch party by exact name
│   ├── get_party_balances_json.sql          ← Current AR/AP balances for all parties
│   ├── get_party_balances_json_excluding.sql ← Balances excluding a specific party
│   ├── get_expense_party_balances_json.sql  ← Balances for Expense-type parties only
│   └── update_party_from_json.sql           ← Full party update from JSON
├── tables/
│   └── parties.sql                          ← Unified party master table
├── triggers/
│   └── trg_party_insert.sql                 ← AFTER INSERT trigger definition
└── trigger_functions/
    └── trg_party_opening_balance.sql        ← Auto-journal opening balance on insert
```

---

## Tables

### `parties`

Single unified table for all external entities the business transacts with.

| Column | Type | Notes |
|--------|------|-------|
| `party_id` | bigint PK | Auto-incremented via sequence |
| `party_name` | varchar(150) UNIQUE NOT NULL | Must be unique across all party types |
| `party_type` | varchar(20) | `Customer`, `Vendor`, `Both`, or `Expense` |
| `contact_info` | varchar(50) | Phone number or other contact |
| `address` | text | Full address |
| `ar_account_id` | bigint FK → chartofaccounts | Accounts Receivable ledger account |
| `ap_account_id` | bigint FK → chartofaccounts | Accounts Payable or Expense ledger account |
| `opening_balance` | numeric(14,2) | Initial balance at time of creation; defaults to 0 |
| `balance_type` | varchar(10) | `Debit` or `Credit` — direction of opening balance |
| `date_created` | timestamp | Defaults to `CURRENT_TIMESTAMP` |
| `created_by` | integer FK → auth_user | Audit field; SET NULL on user deletion |

**Constraints:**
- `party_name` is globally unique
- `party_type` must be one of: `Customer`, `Vendor`, `Both`, `Expense`
- `balance_type` must be `Debit` or `Credit`
- `ar_account_id` ON DELETE SET NULL
- `ap_account_id` ON DELETE SET NULL

**Party Type Logic:**

| `party_type` | Has AR Account | Has AP Account | Opening Balance Direction |
|---|---|---|---|
| `Customer` | ✅ | ❌ | `Debit` (they owe us) |
| `Vendor` | ❌ | ✅ | `Credit` (we owe them) |
| `Both` | ✅ | ✅ | Either direction |
| `Expense` | ❌ | ✅ (Expense A/C) | `Debit` (expense pre-paid) |

---

## Trigger: `trg_party_insert`

**Definition:** `AFTER INSERT ON parties FOR EACH ROW`  
**Calls:** `trg_party_opening_balance()`

Fires automatically whenever a new party is created. If `opening_balance > 0`, it creates a journal entry to record the starting financial position.

---

## Trigger Function: `trg_party_opening_balance()`

Implements the automatic journaling of opening balances:

```
IF new party has opening_balance > 0:
    Look up "Owner's Capital" account in COA (required to exist)
    Create a JournalEntry with description "Opening Balance for <party_name>"

    CASE party_type:
        Customer / Both (Debit balance):
            DEBIT  → party's AR account  (they owe us money)
            CREDIT → Owner's Capital     (funded from capital)

        Vendor / Both (Credit balance):
            DEBIT  → Owner's Capital     (capital reduced)
            CREDIT → party's AP account  (we owe them money)

        Expense party:
            DEBIT  → party's AP/Expense account
            CREDIT → Owner's Capital
```

**Error Handling:** Raises an exception if `Owner's Capital` account is not found in the COA — this account is a hard requirement for the system.

---

## Functions

### `add_party_from_json(json)`
Creates a new party from a JSON payload. Handles all party types with their respective account linkages. After INSERT, the trigger fires automatically to record any opening balance.

### `update_party_from_json(bigint, json)`
Updates an existing party record. This is a comprehensive update function (~5.5 KB) that handles name changes, contact info, address, account reassignment, and balance adjustments. Includes logic to reverse and re-create journal entries if the opening balance changes.

### `get_parties_json()`
Returns all parties serialized as a JSON array. Used for populating dropdowns and party selection components in the UI.

### `get_party_by_name(text)`
Returns a single party record by exact name match. Used for lookups during invoice creation.

### `get_party_balances_json()`
Queries `journallines` grouped by `party_id` to compute the current net debit/credit balance for every party. Returns JSON with party name, type, and running balance. Used for AR/AP summary screens.

### `get_party_balances_json_excluding(bigint)`
Same as above but excludes a specific `party_id`. Useful for forms that are editing a party and need to show all others.

### `get_expense_party_balances_json()`
Returns balances only for `party_type = 'Expense'` parties. Used for the expense tracking section of the dashboard and reports.

---

## Dependencies

- **Depends on:** `chartofaccounts` (ar/ap account FKs), `auth_user` (created_by)
- **Used by:** `payments`, `receipts`, `purchaseinvoices`, `purchasereturns`, `salesinvoices`, `salesreturns`, `journallines`, all reporting functions and views
