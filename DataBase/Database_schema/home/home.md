# Module: `home`

> **Role:** Powers the application's real-time dashboard. Provides 15 PostgreSQL functions and 4 views that compute KPIs, alert conditions, sales trends, stock health, and receivables aging — all designed to return JSON directly to the frontend without additional application-layer processing.

---

## Folder Structure

```
home/
├── functions/
│   ├── fn_dash_sales_today_kpi.sql        ← Today's sales total and invoice count
│   ├── fn_dash_sales_last7days.sql        ← Sales trend for last 7 days
│   ├── fn_dash_sales_range.sql            ← Sales for a custom date range
│   ├── fn_dash_expense_kpi.sql            ← Total expenses KPI
│   ├── fn_dash_stock_kpi.sql              ← Current stock count KPI
│   ├── fn_dash_stale_stock.sql            ← Items in stock > N days
│   ├── fn_dash_low_stock_items.sql        ← Items with quantity below threshold
│   ├── fn_dash_fast_moving_items.sql      ← Top-selling items by volume
│   ├── fn_dash_top_customers.sql          ← Customers by revenue generated
│   ├── fn_dash_top_vendors.sql            ← Vendors by purchase volume
│   ├── fn_dash_top_expense_categories.sql ← Expense breakdown by COA account
│   ├── fn_dash_top_expense_descriptions.sql ← Expense breakdown by description
│   ├── fn_dash_receivables_aging.sql      ← AR aging buckets (fresh/medium/overdue)
│   ├── fn_dash_recent_transactions.sql    ← Last N transactions across all types
│   └── fn_dash_smart_alerts.sql           ← Intelligent business alert generator
└── views/
    ├── vw_dash_daily_sales.sql            ← Daily sales aggregation view
    ├── vw_dash_expenses.sql               ← Expense journal lines view
    ├── vw_dash_party_ar_balance.sql       ← Per-party AR balance with last txn date
    └── vw_dash_stock_overview.sql         ← Per-item stock count summary
```

---

## Views

### `vw_dash_daily_sales`
Aggregates `salesinvoices` by `invoice_date`, computing total sales amount and invoice count per day. Used as the base for the 7-day trend chart.

### `vw_dash_expenses`
Joins `journallines` → `journalentries` → `chartofaccounts` filtering for expense-type accounts. Exposes individual expense debit entries with account name and date. Powers expense KPIs and category breakdowns.

### `vw_dash_party_ar_balance`
Per-party accounts receivable balance view. Computes:
- `ar_balance = SUM(debit) - SUM(credit)` from `journallines` grouped by `party_id`
- `last_transaction_date = MAX(entry_date)` from linked `journalentries`
- Filters only parties with `ar_account_id IS NOT NULL` and positive balance

This view is used by both the receivables aging function and the smart alerts function.

### `vw_dash_stock_overview`
Counts current in-stock units per item by querying `purchaseunits WHERE in_stock = true` and excluding any units present in `soldunits` with status `Sold` or in `purchasereturnitems`. Groups by `item_id` to show quantity on hand.

---

## Functions

### KPI Functions

#### `fn_dash_sales_today_kpi()`
Returns JSON with:
- `total_sales`: sum of `salesinvoices.total_amount` for `CURRENT_DATE`
- `invoice_count`: number of invoices today
- `avg_sale_value`: average invoice amount today

#### `fn_dash_expense_kpi()`
Returns JSON with total expenses debited to expense-type accounts from `journallines` in the current month.

#### `fn_dash_stock_kpi()`
Returns JSON with total count of all units currently `in_stock = true` from `purchaseunits`, excluding sold/returned units.

---

### Trend & Range Functions

#### `fn_dash_sales_last7days()`
Returns a JSON array with one entry per day for the last 7 days (including days with zero sales). Useful for bar/line charts on the dashboard. Pulls from `vw_dash_daily_sales`.

#### `fn_dash_sales_range(p_from date, p_to date)`
Returns total sales amount and count for a custom date range. Used for dynamic date picker queries.

---

### Stock Health Functions

#### `fn_dash_low_stock_items(p_threshold integer)`
Returns items where current in-stock quantity (from `vw_dash_stock_overview`) is at or below the given threshold. Returns item name and current quantity as JSON.

#### `fn_dash_stale_stock(p_days integer)`
Returns items (with serial numbers) that have been sitting in stock for more than `p_days` days. Calculated as `CURRENT_DATE - purchase_date`. Uses the `stock_report` view logic.

#### `fn_dash_fast_moving_items(p_limit integer)`
Returns the top N items by total units sold (from `soldunits` + `salesitems`), aggregated by `item_id`. Useful for identifying best-sellers.

---

### Party Analysis Functions

#### `fn_dash_top_customers(p_limit integer)`
Returns the top N customers ranked by total `salesinvoices.total_amount` purchased. Joins `parties` for names.

#### `fn_dash_top_vendors(p_limit integer)`
Returns the top N vendors ranked by total `purchaseinvoices.total_amount`. Useful for procurement analysis.

#### `fn_dash_top_expense_categories(p_limit integer)`
Returns top N expense categories (COA account names) by total debit amount from `journallines`. Groups by `account_name`.

#### `fn_dash_top_expense_descriptions(p_limit integer)`
Returns top N expense descriptions (journal entry descriptions) by total amount. More granular than categories — shows individual expense types.

---

### Receivables Aging

#### `fn_dash_receivables_aging()`
Returns a comprehensive JSON object with three buckets based on days since last transaction (from `vw_dash_party_ar_balance`):

| Bucket | Condition |
|--------|-----------|
| `fresh` | `last_transaction_date` < 30 days ago |
| `medium_risk` | 30–60 days since last transaction |
| `overdue` | > 60 days since last transaction |

Each bucket is a JSON array of `{party_id, party_name, balance, last_txn, days_overdue}`. Also returns total amounts per bucket.

---

### Recent Transactions

#### `fn_dash_recent_transactions(p_limit integer)`
Returns the most recent N transactions across all types (sales, purchases, purchase returns, sales returns, payments, receipts) in a unified JSON array, sorted by date descending. Each row includes type, reference ID, party name, amount, and date.

---

### Smart Alerts

#### `fn_dash_smart_alerts()`
The most sophisticated dashboard function. Generates an array of actionable business alerts by scanning real-time data. Alert conditions checked (in order):

| Alert Type | Condition | Severity |
|---|---|---|
| Negative Cash Balance | `vw_trial_balance` cash account balance < 0 | `danger` |
| No Sales Today | `SUM(salesinvoices.total_amount)` for today = 0 | `warning` |
| Stale Receivables | Parties in `vw_dash_party_ar_balance` with last activity ≥ 30 days (top 5) | `warning` |
| Risky Customers | AR balance > PKR 50,000 AND no receipt in last 45 days (top 3) | `danger` |

Returns JSON array with `{type, icon, title, message}` for each active alert. Returns `[]` if no alerts.

---

## Dependencies

- **Depends on:** `salesinvoices`, `purchaseinvoices`, `journallines`, `journalentries`, `chartofaccounts`, `parties`, `purchaseunits`, `soldunits`, `receipts`, `payments`, `vw_trial_balance` (from `accountsReports`)
- **Used by:** Frontend dashboard; no other DB modules depend on home
