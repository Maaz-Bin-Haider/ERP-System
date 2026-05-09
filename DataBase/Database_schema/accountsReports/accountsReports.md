# Module: `accountsReports`

> **Role:** Provides all formal financial reporting — trial balance, party ledger, income statement, cash ledger, company net worth, AP/AR summaries, and per-sale profit analysis. These functions and views are built directly on the double-entry journal system in `accounting_core` and give management a complete financial picture.

---

## Folder Structure

```
accountsReports/
├── functions/
│   ├── detailed_ledger.sql                                ← Party ledger with running balance
│   ├── detailed_ledger2.sql                               ← Extended ledger (all parties / by type)
│   ├── get_cash_ledger_with_party.sql                     ← Cash account movements with party
│   ├── monthly_income_statement.sql                       ← P&L statement for a period
│   ├── monthly_company_position.sql                       ← Balance sheet snapshot
│   ├── sale_wise_profit.sql                               ← Per-unit profit on each sale
│   ├── get_accounts_payable_json_excluding.sql            ← AP balances excluding a party
│   └── get_accounts_receivable_json_excluding.sql         ← AR balances excluding a party
└── views/
    ├── vw_trial_balance.sql                               ← Full trial balance
    └── standing_company_worth_view.sql                    ← Net worth / balance sheet view
```

---

## Views

### `vw_trial_balance`
The most comprehensive view in the system. Generates a full trial balance that correctly handles:

- **Regular accounts:** All COA accounts with their net debit/credit from `journallines`
- **AR/AP control accounts:** Replaced with per-party breakdowns (each customer/vendor shown individually)
- **Expense parties:** Separated from regular vendors and shown under their own expense accounts
- **Balance classification:** Customers with negative balances are reclassified as AP; vendors with positive balances are reclassified as AR

**Output columns:** `code`, `name`, `type`, `total_debit`, `total_credit`, `balance`

The view uses multiple CTEs:
1. `journal_summary` — raw debit/credit totals per account+party
2. `account_totals` — COA-level aggregation
3. `party_totals` — per-party balance computation
4. `classified_parties` — smart reclassification based on party type and balance direction
5. `control_adjustment` — substitutes control account totals with party-level detail
6. Final UNION ALL combines account rows + party rows

This view is consumed by `fn_dash_smart_alerts` (to check cash balance) and `monthly_company_position`.

---

### `standing_company_worth_view`
A balance-sheet-oriented view that computes the company's current net worth. Groups all accounts by type (Asset, Liability, Equity, Revenue, Expense) and applies the accounting equation:

```
Net Worth = Total Assets - Total Liabilities
```

Uses the same multi-CTE pattern as `vw_trial_balance` but aggregates to type-level totals and includes party-level AR/AP balances. Used for the "Company Position" report.

---

## Functions

### `detailed_ledger(p_party_name text, p_start_date date, p_end_date date)`
Generates a complete chronological ledger for a single party within a date range.

**Returns table with columns:**
- `entry_date`, `journal_id`, `description`
- `party_name`, `account_type` (account name)
- `debit`, `credit`
- `running_balance` — computed as `SUM(debit - credit) OVER (ORDER BY entry_date, journal_id ROWS UNBOUNDED PRECEDING)`
- `created_by` — the username who created the source document

**How `created_by` is resolved:** A `journal_author` CTE unions all source tables (`purchaseinvoices`, `salesinvoices`, `receipts`, `payments`, etc.) joining `auth_user` to find who created the transaction linked to each `journal_id`. Falls back to `'N/A'` if not found.

### `detailed_ledger2(...)` (Extended)
An extended version (~9KB) of the ledger function that supports additional filtering: by party type, by account type, or across all parties. Powers more flexible ledger query screens.

### `get_cash_ledger_with_party(p_start_date date, p_end_date date)`
Returns all journal line movements on the Cash account, enriched with the party name from the associated journal line (the other side of the entry). Useful for the cash book / bank statement view. Shows every cash inflow and outflow with the counterparty name.

### `monthly_income_statement(p_from_date date, p_to_date date, p_sales_revenue numeric, p_cogs numeric)`
Generates a Profit & Loss statement for a period. The caller supplies `sales_revenue` and `COGS` (pre-computed from the sales module). This function:
1. Computes `gross_profit = sales_revenue - COGS`
2. Queries `journallines` for all expense-type account debits in the period (excluding COGS and Profit accounts)
3. Sums operating expenses by category
4. Computes `net_income = gross_profit - total_expenses`

**Returns JSON:**
```json
{
  "from_date": "...", "to_date": "...",
  "sales_revenue": 0.00, "cogs": 0.00,
  "gross_profit": 0.00,
  "expenses": [{"category": "Rent", "amount": 0.00}, ...],
  "total_expenses": 0.00,
  "net_income": 0.00
}
```

### `monthly_company_position(p_from_date date, p_to_date date)`
Generates a balance sheet snapshot for the period. Aggregates balances from `vw_trial_balance` grouped into Assets, Liabilities, Equity, Revenue, and Expense categories with subtotals and net worth calculation. Returns structured JSON suitable for rendering a formal balance sheet.

### `sale_wise_profit(p_from_date date, p_to_date date)`
Per-unit profitability report. For every unit sold in the date range:

| Column | Source |
|--------|--------|
| `sale_date` | `salesinvoices.invoice_date` |
| `item_name` | `items.item_name` |
| `serial_number` | `purchaseunits.serial_number` |
| `serial_comment` | `purchaseunits.serial_comment` |
| `sale_price` | `soldunits.sold_price` |
| `purchase_price` | `purchaseitems.unit_price` |
| `profit_loss` | `sale_price - purchase_price` |
| `profit_loss_percent` | `(profit / cost) × 100` |
| `vendor_name` | Original vendor from `purchaseinvoices` |

Joins `soldunits → purchaseunits → purchaseitems → purchaseinvoices → parties` to trace each sold unit back to its original vendor and purchase cost. This is the most join-heavy report in the system.

### `get_accounts_payable_json_excluding(p_exclude_party_id bigint)`
Returns current AP balances (net credit position) for all vendor parties, excluding a specified party. Used in update forms to show the full AP position without the party being edited. Returns JSON array.

### `get_accounts_receivable_json_excluding(p_exclude_party_id bigint)`
Returns current AR balances (net debit position) for all customer parties, excluding a specified party. Mirror of the AP function for the receivables side.

---

## Report Coverage Summary

| Report | Function/View | Key Insight |
|--------|--------------|-------------|
| Trial Balance | `vw_trial_balance` | All accounts + parties balanced |
| Company Net Worth | `standing_company_worth_view` | Assets vs Liabilities |
| Party Ledger | `detailed_ledger` | Per-party running balance |
| Cash Book | `get_cash_ledger_with_party` | Cash movements with counterparty |
| Income Statement | `monthly_income_statement` | Revenue - COGS - Expenses |
| Balance Sheet | `monthly_company_position` | Snapshot financial position |
| Unit Profit | `sale_wise_profit` | Margin per sold serial number |
| AR Summary | `get_accounts_receivable_json_excluding` | Outstanding receivables |
| AP Summary | `get_accounts_payable_json_excluding` | Outstanding payables |

---

## Dependencies

- **Depends on:** `journallines`, `journalentries`, `chartofaccounts`, `parties`, `purchaseinvoices`, `purchasereturns`, `salesinvoices`, `salesreturns`, `receipts`, `payments`, `soldunits`, `purchaseunits`, `purchaseitems`, `auth_user`
- **Used by:** `home` module (`fn_dash_smart_alerts` reads `vw_trial_balance`); reporting screens in the UI
