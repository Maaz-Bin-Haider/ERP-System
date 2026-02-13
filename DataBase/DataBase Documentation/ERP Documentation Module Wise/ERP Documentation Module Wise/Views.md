# 📊 DATABASE VIEWS - COMPLETE DOCUMENTATION

## Overview

This document provides comprehensive documentation for all database views in the ERP system. Views are virtual tables that provide simplified access to complex queries and reporting data.

**Total Views:** 4

---

## 📑 Table of Contents

1. [vw_trial_balance](#1-vw_trial_balance)
2. [standing_company_worth_view](#2-standing_company_worth_view)
3. [stock_worth_report](#3-stock_worth_report)
4. [stock_report](#4-stock_report)

---

## 1. `vw_trial_balance`

### Purpose
Generates a complete trial balance report showing all account balances and party balances, properly classified by account type.

### Complete SQL Code

```sql
CREATE VIEW public.vw_trial_balance AS
 WITH journal_summary AS (
         SELECT jl.account_id,
            jl.party_id,
            COALESCE(sum(jl.debit), (0)::numeric) AS debit,
            COALESCE(sum(jl.credit), (0)::numeric) AS credit
           FROM public.journallines jl
          GROUP BY jl.account_id, jl.party_id
        ), account_totals AS (
         SELECT coa.account_id,
            coa.account_code,
            coa.account_name,
            coa.account_type,
            sum(js.debit) AS total_debit,
            sum(js.credit) AS total_credit
           FROM (public.chartofaccounts coa
             LEFT JOIN journal_summary js ON (((coa.account_id = js.account_id) AND (((coa.account_name)::text = ANY (ARRAY[('Accounts Receivable'::character varying)::text, ('Accounts Payable'::character varying)::text])) OR (js.party_id IS NULL)))))
          WHERE (NOT (coa.account_id IN ( SELECT DISTINCT p.ap_account_id
                   FROM public.parties p
                  WHERE (((p.party_type)::text = 'Expense'::text) AND (p.ap_account_id IS NOT NULL)))))
          GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
        ), party_totals AS (
         SELECT p.party_id,
            p.party_name,
            p.party_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit,
            (COALESCE(sum(js.debit), (0)::numeric) - COALESCE(sum(js.credit), (0)::numeric)) AS balance
           FROM (public.parties p
             LEFT JOIN journal_summary js ON ((js.party_id = p.party_id)))
          GROUP BY p.party_id, p.party_name, p.party_type
        ), classified_parties AS (
         SELECT pt.party_id,
            pt.party_name,
            pt.party_type,
            pt.total_debit,
            pt.total_credit,
            pt.balance,
                CASE
                    WHEN (((pt.party_type)::text = 'Customer'::text) AND (pt.balance < (0)::numeric)) THEN 'Accounts Payable'::text
                    WHEN (((pt.party_type)::text = 'Vendor'::text) AND (pt.balance > (0)::numeric)) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Both'::text) THEN
                    CASE
                        WHEN (pt.balance >= (0)::numeric) THEN 'Accounts Receivable'::text
                        ELSE 'Accounts Payable'::text
                    END
                    WHEN ((pt.party_type)::text = 'Customer'::text) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Vendor'::text) THEN 'Accounts Payable'::text
                    ELSE 'Expense Party'::text
                END AS effective_type
           FROM party_totals pt
        ), control_adjustment AS (
         SELECT classified_parties.effective_type AS account_name,
            sum(GREATEST(classified_parties.balance, (0)::numeric)) AS debit_side,
            sum(abs(LEAST(classified_parties.balance, (0)::numeric))) AS credit_side
           FROM classified_parties
          WHERE (classified_parties.effective_type = ANY (ARRAY['Accounts Receivable'::text, 'Accounts Payable'::text]))
          GROUP BY classified_parties.effective_type
        )
 SELECT at.account_code AS code,
    at.account_name AS name,
    at.account_type AS type,
    COALESCE(ca.debit_side, at.total_debit, (0)::numeric) AS total_debit,
    COALESCE(ca.credit_side, at.total_credit, (0)::numeric) AS total_credit,
    (COALESCE(ca.debit_side, at.total_debit, (0)::numeric) - COALESCE(ca.credit_side, at.total_credit, (0)::numeric)) AS balance
   FROM (account_totals at
     LEFT JOIN control_adjustment ca ON ((ca.account_name = (at.account_name)::text)))
UNION ALL
 SELECT NULL::character varying AS code,
    pt.party_name AS name,
    pt.effective_type AS type,
    pt.total_debit,
    pt.total_credit,
    pt.balance
   FROM classified_parties pt
  WHERE ((pt.total_debit <> (0)::numeric) OR (pt.total_credit <> (0)::numeric))
  ORDER BY 1 NULLS FIRST, 2;
```

### Output Columns

| Column | Type | Description |
|--------|------|-------------|
| code | VARCHAR | Account code (NULL for party entries) |
| name | VARCHAR | Account name or party name |
| type | VARCHAR | Account type or effective classification |
| total_debit | NUMERIC | Total debit amount |
| total_credit | NUMERIC | Total credit amount |
| balance | NUMERIC | Net balance (debit - credit) |

### How It Works

The view uses multiple Common Table Expressions (CTEs) to build the trial balance:

#### 1. **journal_summary** CTE
- Aggregates all journal lines by account_id and party_id
- Calculates total debits and credits for each combination

#### 2. **account_totals** CTE
- Summarizes balances for all Chart of Accounts entries
- Excludes expense-type parties (they're handled separately)
- Handles AR/AP accounts specially to exclude party-level detail at account level

#### 3. **party_totals** CTE
- Calculates balances for all parties
- Computes running balance (debit - credit)

#### 4. **classified_parties** CTE
- Classifies each party into its effective type
- **Logic:**
  - Customer with credit balance → "Accounts Payable" (they owe us but balance is negative)
  - Vendor with debit balance → "Accounts Receivable" (we owe them but balance is positive)
  - "Both" type → Classified based on balance sign
  - Expense parties → "Expense Party"

#### 5. **control_adjustment** CTE
- Aggregates party balances by effective type (AR/AP)
- Separates debit-side and credit-side amounts
- Used to adjust control account (AR/AP) totals

#### 6. **Final SELECT**
- Combines account-level totals with party-level details
- Shows account totals first (with adjusted AR/AP)
- Then shows individual party details
- Orders by code (NULLs first for parties), then by name

### Usage Example

```sql
-- Get complete trial balance
SELECT * FROM vw_trial_balance;

-- Get only account-level totals (no party detail)
SELECT * FROM vw_trial_balance WHERE code IS NOT NULL;

-- Get only party details
SELECT * FROM vw_trial_balance WHERE code IS NULL;

-- Get trial balance for specific account type
SELECT * FROM vw_trial_balance WHERE type = 'Asset';

-- Verify trial balance (debits should equal credits)
SELECT 
    SUM(total_debit) as total_debits,
    SUM(total_credit) as total_credits,
    SUM(total_debit) - SUM(total_credit) as difference
FROM vw_trial_balance
WHERE code IS NOT NULL;
```

### Business Logic

**Key Features:**
1. **Control Account Reconciliation**: AR and AP control accounts are adjusted to match subsidiary ledger (party balances)
2. **Party Classification**: Parties are dynamically classified based on their balance
3. **Expense Party Handling**: Expense-type parties shown separately from regular expense accounts
4. **Complete Audit Trail**: Shows both summary and detail views

**Expected Output:**
```
code  | name                    | type              | total_debit | total_credit | balance
------|-------------------------|-------------------|-------------|--------------|--------
1000  | Cash                    | Asset             | 500000.00   | 300000.00    | 200000.00
1100  | Accounts Receivable     | Asset             | 250000.00   | 100000.00    | 150000.00
NULL  | ABC Corp                | Accounts Receivable| 50000.00    | 20000.00     | 30000.00
NULL  | XYZ Ltd                 | Accounts Receivable| 30000.00    | 10000.00     | 20000.00
...
```

---

## 2. `standing_company_worth_view`

### Purpose
Provides a comprehensive financial standing report showing the company's financial position (Balance Sheet) and profitability (P&L) in JSON format.

### Complete SQL Code

```sql
CREATE VIEW public.standing_company_worth_view AS
 WITH journal_summary AS (
         SELECT jl.account_id,
            jl.party_id,
            COALESCE(sum(jl.debit), (0)::numeric) AS debit,
            COALESCE(sum(jl.credit), (0)::numeric) AS credit
           FROM public.journallines jl
          GROUP BY jl.account_id, jl.party_id
        ), account_totals AS (
         SELECT coa.account_id,
            coa.account_code,
            coa.account_name,
            coa.account_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit
           FROM (public.chartofaccounts coa
             LEFT JOIN journal_summary js ON (((coa.account_id = js.account_id) AND (((coa.account_name)::text = ANY (ARRAY[('Accounts Receivable'::character varying)::text, ('Accounts Payable'::character varying)::text])) OR (js.party_id IS NULL)))))
          WHERE (NOT (coa.account_id IN ( SELECT DISTINCT p.ap_account_id
                   FROM public.parties p
                  WHERE (((p.party_type)::text = 'Expense'::text) AND (p.ap_account_id IS NOT NULL)))))
          GROUP BY coa.account_id, coa.account_code, coa.account_name, coa.account_type
        ), party_totals AS (
         SELECT p.party_id,
            p.party_name,
            p.party_type,
            COALESCE(sum(js.debit), (0)::numeric) AS total_debit,
            COALESCE(sum(js.credit), (0)::numeric) AS total_credit,
            (COALESCE(sum(js.debit), (0)::numeric) - COALESCE(sum(js.credit), (0)::numeric)) AS balance
           FROM (public.parties p
             LEFT JOIN journal_summary js ON ((js.party_id = p.party_id)))
          GROUP BY p.party_id, p.party_name, p.party_type
        ), classified_parties AS (
         SELECT pt.party_id,
            pt.party_name,
            pt.party_type,
            pt.total_debit,
            pt.total_credit,
            pt.balance,
                CASE
                    WHEN (((pt.party_type)::text = 'Customer'::text) AND (pt.balance < (0)::numeric)) THEN 'Accounts Payable'::text
                    WHEN (((pt.party_type)::text = 'Vendor'::text) AND (pt.balance > (0)::numeric)) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Both'::text) THEN
                    CASE
                        WHEN (pt.balance >= (0)::numeric) THEN 'Accounts Receivable'::text
                        ELSE 'Accounts Payable'::text
                    END
                    WHEN ((pt.party_type)::text = 'Customer'::text) THEN 'Accounts Receivable'::text
                    WHEN ((pt.party_type)::text = 'Vendor'::text) THEN 'Accounts Payable'::text
                    ELSE 'Expense Party'::text
                END AS effective_type
           FROM party_totals pt
        ), control_adjustment AS (
         SELECT classified_parties.effective_type AS account_name,
            sum(GREATEST(classified_parties.balance, (0)::numeric)) AS debit_side,
            sum(abs(LEAST(classified_parties.balance, (0)::numeric))) AS credit_side
           FROM classified_parties
          WHERE (classified_parties.effective_type = ANY (ARRAY['Accounts Receivable'::text, 'Accounts Payable'::text]))
          GROUP BY classified_parties.effective_type
        ), merged_totals AS (
         SELECT coa.account_type,
                CASE
                    WHEN ((coa.account_type)::text = ANY (ARRAY[('Asset'::character varying)::text, ('Expense'::character varying)::text])) THEN (COALESCE(ca.debit_side, at.total_debit, (0)::numeric) - COALESCE(ca.credit_side, at.total_credit, (0)::numeric))
                    WHEN ((coa.account_type)::text = ANY (ARRAY[('Liability'::character varying)::text, ('Equity'::character varying)::text, ('Revenue'::character varying)::text])) THEN (COALESCE(ca.credit_side, at.total_credit, (0)::numeric) - COALESCE(ca.debit_side, at.total_debit, (0)::numeric))
                    ELSE (0)::numeric
                END AS net_balance
           FROM ((account_totals at
             JOIN public.chartofaccounts coa ON ((at.account_id = coa.account_id)))
             LEFT JOIN control_adjustment ca ON ((ca.account_name = (coa.account_name)::text)))
        ), summary AS (
         SELECT merged_totals.account_type,
            sum(merged_totals.net_balance) AS total
           FROM merged_totals
          GROUP BY merged_totals.account_type
        ), party_expenses AS (
         SELECT sum(classified_parties.balance) AS total_party_expenses
           FROM classified_parties
          WHERE (classified_parties.effective_type = 'Expense Party'::text)
        ), totals AS (
         SELECT COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Asset'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS assets,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Liability'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS liabilities,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Equity'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS equity,
            COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Revenue'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) AS revenue,
            (COALESCE(sum(
                CASE
                    WHEN ((summary.account_type)::text = 'Expense'::text) THEN summary.total
                    ELSE NULL::numeric
                END), (0)::numeric) + COALESCE(( SELECT party_expenses.total_party_expenses
                   FROM party_expenses), (0)::numeric)) AS expenses
           FROM summary
        )
 SELECT json_build_object('financial_position', json_build_object('total_assets', round(assets, 2), 'total_liabilities', round(liabilities, 2), 'total_equity', round(equity, 2), 'net_worth', round((assets - liabilities), 2)), 'profit_and_loss', json_build_object('total_revenue', round(revenue, 2), 'total_expenses', round(expenses, 2), 'net_profit_loss', round((revenue - expenses), 2))) AS company_standing
   FROM totals;
```

### Output Structure

**Returns:** Single JSON object

### JSON Output Format

```json
{
  "financial_position": {
    "total_assets": 1500000.00,
    "total_liabilities": 500000.00,
    "total_equity": 800000.00,
    "net_worth": 1000000.00
  },
  "profit_and_loss": {
    "total_revenue": 2000000.00,
    "total_expenses": 1500000.00,
    "net_profit_loss": 500000.00
  }
}
```

### How It Works

The view uses a series of CTEs similar to `vw_trial_balance`, then adds additional calculations:

#### Additional CTEs Beyond Trial Balance Base:

**6. merged_totals** CTE
- Calculates net balance for each account type
- **For Assets & Expenses**: Net = Debit - Credit (normal debit balance)
- **For Liabilities, Equity, Revenue**: Net = Credit - Debit (normal credit balance)

**7. summary** CTE
- Aggregates totals by account type (Asset, Liability, Equity, Revenue, Expense)

**8. party_expenses** CTE
- Separately calculates total for expense-type parties
- These are added to regular expenses

**9. totals** CTE
- Pivots summary data into individual columns
- Adds party expenses to regular expenses

**10. Final SELECT**
- Builds nested JSON structure
- Calculates derived values:
  - **Net Worth** = Total Assets - Total Liabilities
  - **Net Profit/Loss** = Total Revenue - Total Expenses
- Rounds all values to 2 decimal places

### Usage Example

```sql
-- Get complete company standing
SELECT * FROM standing_company_worth_view;

-- Extract specific values from JSON
SELECT 
    company_standing->'financial_position'->>'total_assets' as total_assets,
    company_standing->'financial_position'->>'net_worth' as net_worth,
    company_standing->'profit_and_loss'->>'net_profit_loss' as net_profit
FROM standing_company_worth_view;

-- Pretty print the JSON
SELECT jsonb_pretty(company_standing::jsonb) 
FROM standing_company_worth_view;
```

### Business Logic

**Financial Position (Balance Sheet):**
- **Total Assets** = Sum of all asset account balances (debit - credit)
- **Total Liabilities** = Sum of all liability account balances (credit - debit)
- **Total Equity** = Sum of all equity account balances (credit - debit)
- **Net Worth** = Total Assets - Total Liabilities (should equal Total Equity)

**Profit and Loss (Income Statement):**
- **Total Revenue** = Sum of all revenue account balances (credit - debit)
- **Total Expenses** = Sum of all expense accounts + expense-type parties (debit - credit)
- **Net Profit/Loss** = Total Revenue - Total Expenses

**Accounting Equation Verification:**
```
Assets = Liabilities + Equity
Net Worth = Assets - Liabilities
Net Worth ≈ Equity (should be equal)
```

---

## 3. `stock_worth_report`

### Purpose
Provides detailed inventory valuation report showing purchase price vs market price for all items in stock, with running totals.

### Complete SQL Code

```sql
CREATE VIEW public.stock_worth_report AS
WITH stock AS (
    SELECT 
        i.item_id,
        i.item_name,
        COUNT(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
        pu.serial_number,
        pu.serial_comment,
        pit.unit_price AS purchase_price,
        i.sale_price AS market_price,
        ROW_NUMBER() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
    FROM public.purchaseunits pu
    JOIN public.purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN public.items i ON pit.item_id = i.item_id
    WHERE pu.in_stock = true
), 
running AS (
    SELECT 
        stock.item_id,
        stock.item_name,
        stock.quantity,
        stock.serial_number,
        stock.serial_comment,
        stock.purchase_price,
        stock.market_price,
        SUM(stock.purchase_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_purchase,
        SUM(stock.market_price) OVER (ORDER BY stock.item_id, stock.rn) AS running_total_market,
        stock.rn
    FROM stock
)
SELECT
    CASE WHEN rn = 1 THEN item_id::TEXT ELSE ''::TEXT END AS item_id,
    CASE WHEN rn = 1 THEN item_name ELSE ''::VARCHAR END AS item_name,
    CASE WHEN rn = 1 THEN quantity::TEXT ELSE ''::TEXT END AS quantity,
    serial_number,
    serial_comment,
    purchase_price,
    market_price,
    running_total_purchase,
    running_total_market
FROM running
ORDER BY item_id::INTEGER, rn;
```

### Output Columns

| Column | Type | Description |
|--------|------|-------------|
| item_id | TEXT | Item ID (shown only on first row per item) |
| item_name | VARCHAR | Item name (shown only on first row per item) |
| quantity | TEXT | Total quantity in stock (shown only on first row per item) |
| serial_number | VARCHAR | Serial/IMEI number |
| serial_comment | TEXT | Optional comment for this serial |
| purchase_price | NUMERIC | Original purchase price for this unit |
| market_price | NUMERIC | Current market/sale price |
| running_total_purchase | NUMERIC | Running total of purchase prices |
| running_total_market | NUMERIC | Running total of market prices |

### How It Works

#### 1. **stock** CTE
- Joins PurchaseUnits → PurchaseItems → Items
- Filters only items where `in_stock = true`
- Uses window function `COUNT() OVER (PARTITION BY item_id)` to get quantity per item
- Assigns row number within each item group

#### 2. **running** CTE
- Calculates running totals using window functions
- `SUM() OVER (ORDER BY item_id, rn)` creates cumulative sums
- Running totals show cumulative inventory value

#### 3. **Final SELECT**
- Display logic: Shows item_id, item_name, quantity only on first row (rn=1)
- Subsequent rows for same item show empty strings for grouping clarity
- Each serial number gets its own row

### Usage Example

```sql
-- Get complete stock worth report
SELECT * FROM stock_worth_report;

-- Get total inventory value
SELECT 
    MAX(running_total_purchase) as total_cost,
    MAX(running_total_market) as total_market_value,
    MAX(running_total_market) - MAX(running_total_purchase) as potential_profit
FROM stock_worth_report;

-- Get stock worth for specific item
SELECT * FROM stock_worth_report 
WHERE item_id::INTEGER = 5 OR item_name LIKE '%iPhone%';

-- Count total items in stock
SELECT COUNT(DISTINCT item_id::INTEGER) as total_items,
       SUM(CASE WHEN quantity <> '' THEN quantity::INTEGER ELSE 0 END) as total_units
FROM stock_worth_report;
```

### Sample Output

```
item_id | item_name      | quantity | serial_number  | serial_comment | purchase_price | market_price | running_total_purchase | running_total_market
--------|----------------|----------|----------------|----------------|----------------|--------------|----------------------|-------------------
1       | iPhone 15 Pro  | 3        | IMEI001        | Black 256GB    | 45000.00       | 52000.00     | 45000.00             | 52000.00
        |                |          | IMEI002        | White 512GB    | 46000.00       | 52000.00     | 91000.00             | 104000.00
        |                |          | IMEI003        | NULL           | 45500.00       | 52000.00     | 136500.00            | 156000.00
2       | MacBook Pro    | 1        | MBP001         | M3 Max         | 120000.00      | 135000.00    | 256500.00            | 291000.00
```

### Business Logic

**Key Features:**
1. **Inventory Valuation**: Shows both cost basis (purchase_price) and current value (market_price)
2. **Serial-Level Detail**: Every unit tracked individually
3. **Running Totals**: Cumulative values help track total inventory worth
4. **Profit Potential**: Difference between market and purchase price shows potential profit
5. **Visual Grouping**: Empty strings for item details after first row make report easier to read

**Calculations:**
- **Total Cost** = Sum of all purchase_price (last running_total_purchase)
- **Total Market Value** = Sum of all market_price (last running_total_market)
- **Unrealized Profit** = Total Market Value - Total Cost

---

## 4. `stock_report`

### Purpose
Simplified stock report showing current inventory with serial numbers and comments, without pricing information.

### Complete SQL Code

```sql
CREATE VIEW public.stock_report AS
WITH stock AS (
    SELECT 
        i.item_id,
        i.item_name,
        COUNT(pu.unit_id) OVER (PARTITION BY i.item_id) AS quantity,
        pu.serial_number,
        pu.serial_comment,
        ROW_NUMBER() OVER (PARTITION BY i.item_id ORDER BY pu.serial_number) AS rn
    FROM public.purchaseunits pu
    JOIN public.purchaseitems pit ON pu.purchase_item_id = pit.purchase_item_id
    JOIN public.items i ON pit.item_id = i.item_id
    WHERE pu.in_stock = true
)
SELECT
    CASE WHEN rn = 1 THEN item_id::TEXT ELSE ''::TEXT END AS item_id,
    CASE WHEN rn = 1 THEN item_name ELSE ''::VARCHAR END AS item_name,
    CASE WHEN rn = 1 THEN quantity::TEXT ELSE ''::TEXT END AS quantity,
    serial_number,
    serial_comment
FROM stock
ORDER BY item_id::INTEGER, rn;
```

### Output Columns

| Column | Type | Description |
|--------|------|-------------|
| item_id | TEXT | Item ID (shown only on first row per item) |
| item_name | VARCHAR | Item name (shown only on first row per item) |
| quantity | TEXT | Total quantity in stock (shown only on first row per item) |
| serial_number | VARCHAR | Serial/IMEI number |
| serial_comment | TEXT | Optional comment for this serial |

### How It Works

#### 1. **stock** CTE
- Similar to `stock_worth_report` but without pricing columns
- Joins PurchaseUnits → PurchaseItems → Items
- Filters `in_stock = true`
- Counts quantity per item using window function
- Assigns row numbers for ordering

#### 2. **Final SELECT**
- Same display logic as `stock_worth_report`
- Shows item details only on first row (rn=1)
- Each serial gets its own row

### Usage Example

```sql
-- Get complete stock report
SELECT * FROM stock_report;

-- Count items by category
SELECT 
    item_name,
    MAX(quantity::INTEGER) as qty
FROM stock_report
WHERE quantity <> ''
GROUP BY item_name
ORDER BY qty DESC;

-- Search for specific serial
SELECT * FROM stock_report 
WHERE serial_number LIKE '%IMEI001%';

-- Get all serials for an item
SELECT serial_number, serial_comment
FROM stock_report
WHERE item_name = 'iPhone 15 Pro';

-- Total units in stock
SELECT SUM(quantity::INTEGER) as total_units
FROM stock_report
WHERE quantity <> '';
```

### Sample Output

```
item_id | item_name      | quantity | serial_number  | serial_comment
--------|----------------|----------|----------------|------------------
1       | iPhone 15 Pro  | 3        | IMEI001        | Black 256GB
        |                |          | IMEI002        | White 512GB
        |                |          | IMEI003        | NULL
2       | MacBook Pro    | 1        | MBP001         | M3 Max 16-inch
3       | iPad Air       | 5        | IPAD001        | Blue
        |                |          | IPAD002        | Pink
        |                |          | IPAD003        | NULL
        |                |          | IPAD004        | Space Gray
        |                |          | IPAD005        | NULL
```

### Business Logic

**Key Features:**
1. **Simplified View**: No pricing information - pure inventory count
2. **Serial Tracking**: Complete list of all serials in stock
3. **Comments Visible**: Shows any notes/comments added during purchase
4. **Clean Display**: Grouped by item for easy reading

**Use Cases:**
- Quick stock check
- Serial number lookup
- Inventory count verification
- Non-financial stock reporting

**Difference from stock_worth_report:**
- No pricing information (simpler, faster)
- No running totals
- Suitable for warehouse/operations staff (not accounting)

---

## 📊 View Comparison Summary

| Feature | vw_trial_balance | standing_company_worth_view | stock_worth_report | stock_report |
|---------|------------------|----------------------------|-------------------|--------------|
| **Purpose** | Trial balance | Financial summary | Inventory valuation | Simple stock list |
| **Output Format** | Rows | JSON | Rows | Rows |
| **Includes Pricing** | No | Yes (aggregated) | Yes (detailed) | No |
| **Party Detail** | Yes | No | No | No |
| **Serial Detail** | No | No | Yes | Yes |
| **Running Totals** | No | No | Yes | No |
| **Primary Users** | Accountants | Management | Accounting/Inventory | Warehouse |

---

## 🔧 Common View Patterns

### Pattern 1: Window Functions for Grouping
All stock views use:
```sql
COUNT(*) OVER (PARTITION BY item_id) -- Total per group
ROW_NUMBER() OVER (PARTITION BY item_id ORDER BY serial) -- Row number within group
```

### Pattern 2: Conditional Display
All stock views use:
```sql
CASE WHEN rn = 1 THEN value ELSE '' END
```
This shows grouped values only once for readability.

### Pattern 3: CTEs for Complex Logic
All views use Common Table Expressions (WITH clauses) to:
- Break complex queries into logical steps
- Improve readability and maintenance
- Enable reuse of intermediate results

---

## 📝 Usage Best Practices

### Performance Considerations

1. **Views are Recomputed**: Views execute the query each time accessed
2. **Index Recommendations**:
   - Index on `PurchaseUnits.in_stock`
   - Index on `JournalLines.account_id, party_id`
   - Index on `Parties.party_type`

3. **Materialized Views** (if needed for performance):
```sql
-- Convert to materialized view if data doesn't need to be real-time
CREATE MATERIALIZED VIEW mv_stock_report AS 
SELECT * FROM stock_report;

-- Refresh when needed
REFRESH MATERIALIZED VIEW mv_stock_report;
```

### Query Optimization

```sql
-- Instead of SELECT * on large reports, specify columns
SELECT item_name, quantity, serial_number 
FROM stock_report;

-- Use WHERE clauses to filter early
SELECT * FROM stock_report 
WHERE item_id::INTEGER = 5;  -- Filter specific item
```

---

## 📚 Integration with Functions

These views work alongside stored functions:

```sql
-- Get stock report
SELECT * FROM stock_report;

-- Then create a sale using the serial numbers
SELECT create_sale(
    customer_id,
    CURRENT_DATE,
    '[{"item_name":"iPhone 15 Pro","qty":1,"unit_price":52000,"serials":["IMEI001"]}]'::jsonb
);

-- Verify stock updated
SELECT * FROM stock_report WHERE serial_number = 'IMEI001';
-- Should not appear (in_stock=FALSE after sale)
```

---

**Document Version:** 1.0  
**Date:** February 13, 2026  
**Views Documented:** 4  
**Status:** Complete  

---
