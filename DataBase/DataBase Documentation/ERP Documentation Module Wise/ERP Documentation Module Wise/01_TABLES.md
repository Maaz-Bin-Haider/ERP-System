# 📊 Django-Based Accounting Plus Inventory Management ERP System
## Complete PostgreSQL Database Documentation

**Generated:** February 13, 2026  
**Database System:** PostgreSQL 14+  
**Application Framework:** Django 4.x  
**System Type:** Enterprise Resource Planning (ERP)  
**Core Modules:** Accounting, Inventory Management, Sales, Purchases, Returns, Payments, Receipts  

---

## 📋 Executive Summary

This documentation provides a comprehensive technical reference for a professional Django-based ERP system built on PostgreSQL. The system integrates double-entry accounting with serial number-based inventory tracking, providing complete financial and stock management capabilities.

**Key Features:**
- ✅ Double-entry accounting with full journal entry automation
- ✅ Serial number tracking for every inventory item
- ✅ Complete purchase and sales cycle management  
- ✅ Purchase and sales returns processing
- ✅ Payment and receipt management with party tracking
- ✅ Real-time stock movements and valuation (FIFO)
- ✅ Comprehensive reporting (P&L, Balance Sheet, Stock Reports)
- ✅ Party management (customers, vendors, expense categories)
- ✅ Hierarchical chart of accounts

---

## 📑 Table of Contents

1. [Database Tables](#-database-tables)
2. [Stored Functions](#-stored-functions)
3. [Triggers](#-triggers)
4. [Data Flow](#-data-flow)
5. [Key Design Principles](#-key-design-principles)
6. [System Architecture](#-system-architecture)
7. [Summary Statistics](#-summary-statistics)

---

## 🗄️ Database Tables

### Overview

The database schema consists of 18 core business tables organized into four functional groups:
- **Master Data**: Chart of Accounts, Items, Parties
- **Transaction Headers**: Purchase/Sales Invoices, Returns, Payments, Receipts
- **Transaction Details**: Line items and serial number tracking
- **Accounting**: Journal Entries and Journal Lines

---

### 🏢 Master Data Tables

#### 1. **ChartOfAccounts**
General Ledger account structure with hierarchical support.

| Column | Type | Description |
|--------|------|-------------|
| account_id | BIGSERIAL | Primary key |
| account_code | VARCHAR(20) | Unique account code (e.g., "1000", "2000") |
| account_name | VARCHAR(150) | Account name (e.g., "Cash", "Inventory") |
| account_type | VARCHAR(20) | Asset/Liability/Equity/Revenue/Expense |
| parent_account | BIGINT | Parent account for hierarchical structure (self-FK) |
| date_created | TIMESTAMP | Creation timestamp |

**Constraints:**
- `account_code` is UNIQUE
- `account_type` CHECK constraint: `('Asset', 'Liability', 'Equity', 'Revenue', 'Expense')`
- Self-referencing FK for parent_account (hierarchical COA)

**Business Logic:**
- Supports multi-level account hierarchy
- System requires specific accounts: Cash, Inventory, AR, AP, Revenue, COGS, Expenses
- Parent accounts typically used for grouping/reporting

**Example Accounts:**
```
1000 - Cash (Asset)
1100 - Accounts Receivable (Asset)
1200 - Inventory (Asset)
2000 - Accounts Payable (Liability)
3000 - Capital (Equity)
4000 - Sales Revenue (Revenue)
5000 - Cost of Goods Sold (Expense)
6000 - Expenses (Expense)
  6100 - Rent Expense (child of 6000)
  6200 - Utilities (child of 6000)
```

---

#### 2. **Parties**
Customers, vendors, and expense categories.

| Column | Type | Description |
|--------|------|-------------|
| party_id | BIGSERIAL | Primary key |
| party_name | VARCHAR(150) | Party name (UNIQUE) |
| party_type | VARCHAR(20) | Customer/Vendor/Both/Expense |
| contact_info | VARCHAR(50) | Phone/email |
| address | TEXT | Physical address |
| ar_account_id | BIGINT | FK to ChartOfAccounts (AR account) |
| ap_account_id | BIGINT | FK to ChartOfAccounts (AP/Expense account) |
| opening_balance | NUMERIC(14,2) | Opening balance (default 0) |
| balance_type | VARCHAR(10) | Debit/Credit |
| date_created | TIMESTAMP | Creation timestamp |

**Constraints:**
- `party_name` is UNIQUE
- `party_type` CHECK: `('Customer', 'Vendor', 'Both', 'Expense')`
- `balance_type` CHECK: `('Debit', 'Credit')`

**Business Logic:**
- **Customer**: Has AR account, can make sales
- **Vendor**: Has AP account, can make purchases
- **Both**: Has both AR and AP accounts
- **Expense**: Special type - auto-creates expense GL account for direct expense tracking
- Opening balance creates automatic journal entry on INSERT (via trigger)
- Each party links to specific GL accounts for automatic posting

**Example:**
```
Party: "ABC Suppliers" 
  Type: Vendor
  AP Account: "Accounts Payable"
  Opening Balance: 5000 (Credit) - we owe them
```

---

#### 3. **Items**
Inventory master data for products/items.

| Column | Type | Description |
|--------|------|-------------|
| item_id | BIGSERIAL | Primary key |
| item_name | VARCHAR(150) | Item name (UNIQUE) |
| storage | VARCHAR(100) | Storage location/bin |
| sale_price | NUMERIC(12,2) | Default selling price |
| item_code | VARCHAR(50) | Optional SKU/barcode (UNIQUE) |
| category | VARCHAR(100) | Item category/group |
| brand | VARCHAR(100) | Brand name |
| created_at | TIMESTAMP | Creation timestamp |
| updated_at | TIMESTAMP | Last update timestamp |

**Constraints:**
- `item_name` is UNIQUE
- `item_code` is UNIQUE (if provided)
- `sale_price` default is 0.00

**Business Logic:**
- Items can be auto-created during purchase if not found
- Each unit tracked by unique serial number (in PurchaseUnits)
- Cost tracking via FIFO (First-In-First-Out) through serial numbers
- Sale price is default; actual price set per invoice

---

### 💼 Transaction Header Tables

#### 4. **PurchaseInvoices**
Purchase invoice headers (vendor invoices).

| Column | Type | Description |
|--------|------|-------------|
| purchase_invoice_id | BIGSERIAL | Primary key |
| vendor_id | BIGINT | FK to Parties (vendor) |
| invoice_date | DATE | Invoice date (default CURRENT_DATE) |
| total_amount | NUMERIC(14,2) | Total invoice amount |
| journal_id | BIGINT | FK to JournalEntries (accounting link) |

**Constraints:**
- FK to Parties (vendor_id) with CASCADE delete
- FK to JournalEntries with SET NULL delete

**Business Logic:**
- Each purchase creates journal entry: Dr Inventory, Cr AP
- Total calculated from PurchaseItems
- Deleting invoice reverses stock movements and journal entries

---

#### 5. **SalesInvoices**
Sales invoice headers (customer invoices).

| Column | Type | Description |
|--------|------|-------------|
| sales_invoice_id | BIGSERIAL | Primary key |
| customer_id | BIGINT | FK to Parties (customer) |
| invoice_date | DATE | Invoice date (default CURRENT_DATE) |
| total_amount | NUMERIC(14,2) | Total invoice amount |
| journal_id | BIGINT | FK to JournalEntries (accounting link) |

**Constraints:**
- FK to Parties (customer_id) with CASCADE delete
- FK to JournalEntries with SET NULL delete

**Business Logic:**
- Creates journal entry: 
  - Dr AR / Cr Revenue (for sale amount)
  - Dr COGS / Cr Inventory (for cost)
- Must have available stock (serial numbers in stock)
- Marks serial numbers as sold (in_stock = FALSE)

---

#### 6. **PurchaseReturns**
Purchase return headers (returns to vendors).

| Column | Type | Description |
|--------|------|-------------|
| purchase_return_id | BIGSERIAL | Primary key |
| vendor_id | BIGINT | FK to Parties (vendor) |
| return_date | DATE | Return date (default CURRENT_DATE) |
| total_amount | NUMERIC(14,2) | Total return amount |
| journal_id | BIGINT | FK to JournalEntries |

**Business Logic:**
- Reverses purchase: Cr Inventory, Dr AP
- Returns must reference purchased serial numbers
- Serial numbers removed from stock

---

#### 7. **SalesReturns**
Sales return headers (returns from customers).

| Column | Type | Description |
|--------|------|-------------|
| sales_return_id | BIGSERIAL | Primary key |
| customer_id | BIGINT | FK to Parties (customer) |
| return_date | DATE | Return date (default CURRENT_DATE) |
| total_amount | NUMERIC(14,2) | Total return amount |
| journal_id | BIGINT | FK to JournalEntries |

**Business Logic:**
- Reverses sale:
  - Dr Revenue / Cr AR (reverse revenue)
  - Dr Inventory / Cr COGS (restore inventory at cost)
- Serial numbers returned to stock (in_stock = TRUE)
- Must reference previously sold serial numbers

---

#### 8. **Payments**
Outgoing payments to vendors/parties.

| Column | Type | Description |
|--------|------|-------------|
| payment_id | BIGSERIAL | Primary key |
| party_id | BIGINT | FK to Parties (vendor/payee) |
| account_id | BIGINT | FK to ChartOfAccounts (payment account, e.g., Cash) |
| amount | NUMERIC(14,4) | Payment amount (4 decimals for precision) |
| payment_date | DATE | Payment date (default CURRENT_DATE) |
| method | VARCHAR(20) | Cash/Bank/Cheque/Online |
| reference_no | VARCHAR(100) | Check number, transaction ID, etc. |
| journal_id | BIGINT | FK to JournalEntries |
| date_created | TIMESTAMP | Creation timestamp |
| notes | TEXT | Optional notes |
| description | TEXT | Payment description |

**Constraints:**
- `amount` CHECK: amount > 0
- `method` CHECK: `('Cash', 'Bank', 'Cheque', 'Online')`

**Business Logic:**
- Creates journal: Dr AP, Cr Cash/Bank
- Links to party's AP account automatically
- Reference number can be auto-generated (PMT-XXXX)

---

#### 9. **Receipts**
Incoming receipts from customers.

| Column | Type | Description |
|--------|------|-------------|
| receipt_id | BIGSERIAL | Primary key |
| party_id | BIGINT | FK to Parties (customer/payer) |
| account_id | BIGINT | FK to ChartOfAccounts (receipt account, e.g., Cash) |
| amount | NUMERIC(14,4) | Receipt amount (4 decimals) |
| receipt_date | DATE | Receipt date (default CURRENT_DATE) |
| method | VARCHAR(20) | Cash/Bank/Cheque/Online |
| reference_no | VARCHAR(100) | Check number, transaction ID, etc. |
| journal_id | BIGINT | FK to JournalEntries |
| date_created | TIMESTAMP | Creation timestamp |
| notes | TEXT | Optional notes |
| description | TEXT | Receipt description |

**Constraints:**
- `amount` CHECK: amount > 0
- `method` CHECK: `('Cash', 'Bank', 'Cheque', 'Online')`

**Business Logic:**
- Creates journal: Dr Cash/Bank, Cr AR
- Links to party's AR account automatically
- Reference number can be auto-generated (RCT-XXXX)

---

### 📦 Transaction Detail Tables

#### 10. **PurchaseItems**
Line items for purchase invoices.

| Column | Type | Description |
|--------|------|-------------|
| purchase_item_id | BIGSERIAL | Primary key |
| purchase_invoice_id | BIGINT | FK to PurchaseInvoices |
| item_id | BIGINT | FK to Items |
| quantity | INT | Quantity purchased (must be > 0) |
| unit_price | NUMERIC(12,2) | Purchase price per unit |

**Constraints:**
- FK to PurchaseInvoices with CASCADE delete
- FK to Items
- `quantity` CHECK: quantity > 0

**Business Logic:**
- Each line item can have multiple serial numbers (in PurchaseUnits)
- Quantity must equal count of serial numbers provided
- Unit price becomes cost basis for inventory valuation

---

#### 11. **PurchaseUnits**
Individual serial numbers for purchased items.

| Column | Type | Description |
|--------|------|-------------|
| unit_id | BIGSERIAL | Primary key |
| purchase_item_id | BIGINT | FK to PurchaseItems |
| serial_number | VARCHAR(100) | Unique serial/IMEI (UNIQUE) |
| serial_comment | TEXT | Optional comment for this serial |
| in_stock | BOOLEAN | TRUE if available, FALSE if sold |

**Constraints:**
- FK to PurchaseItems with CASCADE delete
- `serial_number` is UNIQUE across entire system

**Business Logic:**
- Each unit tracked individually from purchase to sale
- `in_stock` flag prevents duplicate sales
- Serial comment added Feb 2026 for notes (non-accounting)
- Cost retrieved via JOIN to PurchaseItems.unit_price

---

#### 12. **SalesItems**
Line items for sales invoices.

| Column | Type | Description |
|--------|------|-------------|
| sales_item_id | BIGSERIAL | Primary key |
| sales_invoice_id | BIGINT | FK to SalesInvoices |
| item_id | BIGINT | FK to Items |
| quantity | INT | Quantity sold (must be > 0) |
| unit_price | NUMERIC(12,2) | Selling price per unit |

**Constraints:**
- FK to SalesInvoices with CASCADE delete
- FK to Items
- `quantity` CHECK: quantity > 0

**Business Logic:**
- Quantity must match count of serials in SoldUnits
- Unit price is selling price (revenue)
- Profit = (unit_price - cost_price) per unit

---

#### 13. **SoldUnits**
Tracking which specific serial numbers were sold.

| Column | Type | Description |
|--------|------|-------------|
| sold_unit_id | BIGSERIAL | Primary key |
| sales_item_id | BIGINT | FK to SalesItems |
| unit_id | BIGINT | FK to PurchaseUnits |
| sold_price | NUMERIC(12,2) | Actual selling price for this unit |
| status | VARCHAR(20) | Sold/Returned/Damaged |

**Constraints:**
- FK to SalesItems with CASCADE delete
- FK to PurchaseUnits with CASCADE delete
- `status` CHECK: `('Sold', 'Returned', 'Damaged')`

**Business Logic:**
- Links sale to original purchase (for COGS calculation)
- Allows individual unit pricing (though typically same as line item)
- Status tracks returns and damages
- When sold, PurchaseUnits.in_stock set to FALSE

---

#### 14. **PurchaseReturnItems**
Line items for purchase returns.

| Column | Type | Description |
|--------|------|-------------|
| return_item_id | BIGSERIAL | Primary key |
| purchase_return_id | BIGINT | FK to PurchaseReturns |
| item_id | BIGINT | FK to Items |
| unit_price | NUMERIC(12,2) | Original purchase price |
| serial_number | VARCHAR(100) | Serial being returned |

**Constraints:**
- FK to PurchaseReturns with CASCADE delete
- FK to Items

**Business Logic:**
- Must return previously purchased serials
- Serial removed from stock
- Reverses original purchase cost

---

#### 15. **SalesReturnItems**
Line items for sales returns.

| Column | Type | Description |
|--------|------|-------------|
| return_item_id | BIGSERIAL | Primary key |
| sales_return_id | BIGINT | FK to SalesReturns |
| item_id | BIGINT | FK to Items |
| sold_price | NUMERIC(12,2) | Original selling price |
| cost_price | NUMERIC(12,2) | Original cost (for COGS reversal) |
| serial_number | VARCHAR(100) | Serial being returned |

**Constraints:**
- FK to SalesReturns with CASCADE delete
- FK to Items

**Business Logic:**
- Must return previously sold serials
- Serial returned to stock (in_stock = TRUE)
- Reverses both revenue and COGS
- Maintains cost basis from original purchase

---

### 🧾 Accounting Tables

#### 16. **JournalEntries**
Journal entry headers (accounting transactions).

| Column | Type | Description |
|--------|------|-------------|
| journal_id | BIGSERIAL | Primary key |
| entry_date | DATE | Transaction date (default CURRENT_DATE) |
| description | TEXT | Entry description/reference |
| date_created | TIMESTAMP | Creation timestamp |

**Business Logic:**
- Each business transaction creates one journal entry
- Journal entry contains multiple lines (JournalLines)
- Debits must equal credits (enforced by application logic)
- Links back to source transaction (invoice, payment, etc.)

---

#### 17. **JournalLines**
Individual debit/credit lines within journal entries.

| Column | Type | Description |
|--------|------|-------------|
| line_id | BIGSERIAL | Primary key |
| journal_id | BIGINT | FK to JournalEntries |
| account_id | BIGINT | FK to ChartOfAccounts |
| party_id | BIGINT | FK to Parties (optional, for AR/AP) |
| debit | NUMERIC(14,2) | Debit amount (default 0) |
| credit | NUMERIC(14,2) | Credit amount (default 0) |

**Constraints:**
- FK to JournalEntries
- FK to ChartOfAccounts
- FK to Parties (optional, for subsidiary ledger tracking)

**Business Logic:**
- Each line is either debit OR credit (not both)
- Party_id used for AR/AP subledger tracking
- Sum of debits must equal sum of credits per journal_id
- Account balances calculated by summing all lines

---

### 📊 Audit & Tracking Tables

#### 18. **StockMovements**
Audit trail for all inventory movements.

| Column | Type | Description |
|--------|------|-------------|
| movement_id | BIGSERIAL | Primary key |
| item_id | BIGINT | FK to Items |
| serial_number | TEXT | Serial number affected |
| movement_type | VARCHAR(20) | IN/OUT |
| reference_type | VARCHAR(50) | PurchaseInvoice/SalesInvoice/etc. |
| reference_id | BIGINT | ID of source transaction |
| movement_date | TIMESTAMP | Movement timestamp |
| quantity | INT | Quantity (typically 1 for serialized items) |

**Constraints:**
- FK to Items
- `movement_type` CHECK: `('IN', 'OUT')`

**Business Logic:**
- **IN**: Purchase, Sales Return
- **OUT**: Sale, Purchase Return
- Provides complete audit trail
- Used for stock reports and reconciliation
- Reference fields link back to source transaction

---

