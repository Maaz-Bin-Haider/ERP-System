# 📊 Accounting + Inventory Management System
## PostgreSQL Database Schema - Complete Documentation

**Generated:** 2026-02-12 13:43:21  
**Database:** PostgreSQL 12+  
**Framework:** Django  
**Purpose:** Integrated Accounting + Inventory Management

---

## 📑 Table of Contents

1. [Overview](#1-overview)
2. [All Database Tables (28)](#2-all-database-tables-28)
3. [All Stored Functions (82)](#3-all-stored-functions-82)
4. [Database Views (4)](#4-database-views-4)
5. [Trigger Functions (3)](#5-trigger-functions-3)
6. [Data Flow & Business Processes](#6-data-flow--business-processes)
7. [Key Design Principles](#7-key-design-principles)
8. [Database Architecture](#8-database-architecture)
9. [Summary Statistics](#9-summary-statistics)

---

## 1. Overview

### System Purpose

This database implements a complete **Double-Entry Accounting System** with **Serial-Level Inventory Management**. Every financial transaction creates proper journal entries while tracking each physical inventory unit individually.

### Core Features

✅ **Full Double-Entry Accounting** - Every transaction posts to General Ledger  
✅ **Serial Number Tracking** - Individual unit-level inventory control  
✅ **Automated Journal Entries** - Purchase/Sale/Payment/Receipt all create GL entries automatically  
✅ **Multi-Party Types** - Customers, Vendors, Both, Expense parties in single entity  
✅ **Multi-Reference Payments** - One payment settles multiple invoices  
✅ **Hierarchical COA** - Unlimited account hierarchy depth  
✅ **Purchase & Sales Returns** - Full return processing with journal reversal  
✅ **Profit Tracking** - Unit-level profit calculation on each sale  
✅ **Real-Time Reports** - Trial Balance, P&L, Balance Sheet views  

### Technology Stack

- **Database:** PostgreSQL 12+ (using JSONB, CTEs, Window Functions)
- **Application:** Django 3.x/4.x (Python ORM)
- **Language:** PL/pgSQL for stored procedures
- **Triggers:** AFTER INSERT/UPDATE/DELETE for automated accounting

---

## 2. All Database Tables (28)

### Table Categories

| Category | Count | Purpose |
|----------|-------|---------|
| Django Auth/Admin | 10 | User authentication, permissions, sessions |
| Master Data | 3 | Chart of Accounts, Parties, Items |
| Purchase Transactions | 3 | PurchaseInvoices, PurchaseItems, PurchaseUnits |
| Sales Transactions | 3 | SalesInvoices, SalesItems, SoldUnits |
| Payments & Receipts | 2 | Payments, Receipts |
| Returns | 4 | Purchase/Sales Returns + line items |
| Journal/Accounting | 3 | JournalEntries, JournalLines, StockMovements |

---

### 🔐 Django Authentication & Admin Tables (10)

#### 1. auth_user
Core user table for Django authentication.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| username | VARCHAR(150) | Unique username (NOT NULL) |
| password | VARCHAR(128) | Hashed password |
| email | VARCHAR(254) | Email address |
| first_name | VARCHAR(150) | User's first name |
| last_name | VARCHAR(150) | User's last name |
| is_superuser | BOOLEAN | Superuser status |
| is_staff | BOOLEAN | Can access Django admin |
| is_active | BOOLEAN | Account is active |
| last_login | TIMESTAMPTZ | Last login time |
| date_joined | TIMESTAMPTZ | Account creation time |

**Indexes:** username (UNIQUE), email

---

#### 2. auth_group
Permission groups.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| name | VARCHAR(150) | Group name (UNIQUE) |

---

#### 3. auth_permission
Individual permissions.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| name | VARCHAR(255) | Permission name |
| content_type_id | INTEGER | FK to django_content_type |
| codename | VARCHAR(100) | Permission code |

**Unique:** (content_type_id, codename)

---

#### 4-6. Permission Linking Tables

**auth_group_permissions** - Links groups to permissions  
**auth_user_groups** - Links users to groups  
**auth_user_user_permissions** - Direct user permissions  

---

#### 7. django_content_type
Django model registry.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| app_label | VARCHAR(100) | Django app |
| model | VARCHAR(100) | Model name |

---

#### 8. django_admin_log
Admin action audit trail.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| action_time | TIMESTAMPTZ | When action occurred |
| object_id | TEXT | ID of affected object |
| object_repr | VARCHAR(200) | String representation |
| action_flag | SMALLINT | 1=add, 2=change, 3=delete |
| change_message | TEXT | What changed |
| content_type_id | INTEGER | What model |
| user_id | INTEGER | Who did it |

---

#### 9. django_session
Session storage.

| Column | Type | Description |
|--------|------|-------------|
| session_key | VARCHAR(40) | PK, session identifier |
| session_data | TEXT | Serialized session data |
| expire_date | TIMESTAMPTZ | Expiration time |

**Index:** expire_date

---

#### 10. django_migrations
Migration history.

| Column | Type | Description |
|--------|------|-------------|
| id | BIGINT | Primary key |
| app | VARCHAR(255) | App name |
| name | VARCHAR(255) | Migration filename |
| applied | TIMESTAMPTZ | When applied |

---

### 🏢 Master Data Tables

#### 11. ChartOfAccounts
General Ledger chart of accounts with hierarchical structure.

```sql
CREATE TABLE ChartOfAccounts (
    account_id BIGSERIAL PRIMARY KEY,
    account_code VARCHAR(20) UNIQUE NOT NULL,
    account_name VARCHAR(150) NOT NULL,
    account_type VARCHAR(20) NOT NULL 
        CHECK (account_type IN ('Asset','Liability','Equity','Revenue','Expense')),
    parent_account BIGINT REFERENCES ChartOfAccounts(account_id) ON DELETE SET NULL,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

| Column | Type | Description |
|--------|------|-------------|
| account_id | BIGSERIAL | Primary key |
| account_code | VARCHAR(20) | Unique account code |
| account_name | VARCHAR(150) | Account name |
| account_type | VARCHAR(20) | Asset/Liability/Equity/Revenue/Expense |
| parent_account | BIGINT | Self-FK for hierarchy |
| date_created | TIMESTAMP | Creation timestamp |

**Constraints:**
- `account_code` UNIQUE NOT NULL
- `account_type` CHECK with 5 values
- Self-referencing FK allows unlimited hierarchy depth

**Business Logic:**
- Asset/Expense accounts normally have Debit balances
- Liability/Equity/Revenue accounts normally have Credit balances
- Control accounts (AR, AP) link to Parties table
- Hierarchy enables rollup reporting

**Example:**
```
1000 - Assets
  1100 - Current Assets  
    1110 - Cash
    1120 - Bank
    1130 - Accounts Receivable (AR Control)
  1200 - Fixed Assets
2000 - Liabilities
  2100 - Current Liabilities
    2110 - Accounts Payable (AP Control)
3000 - Equity
  3100 - Owner's Capital
4000 - Revenue
  4100 - Sales Revenue
5000 - Expenses
  5100 - Operating Expenses
```

---


#### 12. Parties
Master table for all business parties: Customers, Vendors, Expense entities.

```sql
CREATE TABLE Parties (
    party_id BIGSERIAL PRIMARY KEY,
    party_name VARCHAR(150) NOT NULL,
    party_type VARCHAR(20) NOT NULL 
        CHECK (party_type IN ('Customer','Vendor','Both','Expense')),
    contact_info VARCHAR(50),
    address TEXT,
    ar_account_id BIGINT REFERENCES ChartOfAccounts(account_id) ON DELETE SET NULL,
    ap_account_id BIGINT REFERENCES ChartOfAccounts(account_id) ON DELETE SET NULL,
    opening_balance NUMERIC(14,2) DEFAULT 0,
    balance_type VARCHAR(10) CHECK (balance_type IN ('Debit','Credit')) DEFAULT 'Debit',
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_party_name UNIQUE (party_name)
);
```

| Column | Type | Description |
|--------|------|-------------|
| party_id | BIGSERIAL | Primary key |
| party_name | VARCHAR(150) | Unique party name |
| party_type | VARCHAR(20) | Customer/Vendor/Both/Expense |
| contact_info | VARCHAR(50) | Phone, email, etc. |
| address | TEXT | Physical address |
| ar_account_id | BIGINT | FK to AR control account |
| ap_account_id | BIGINT | FK to AP control account or Expense account |
| opening_balance | NUMERIC(14,2) | Opening balance amount |
| balance_type | VARCHAR(10) | Debit/Credit |
| date_created | TIMESTAMP | Creation timestamp |

**Constraints:**
- `party_name` UNIQUE
- `party_type` CHECK: 'Customer', 'Vendor', 'Both', 'Expense'
- `balance_type` CHECK: 'Debit', 'Credit'

**Business Logic:**
- **Customer**: Can only receive sales invoices and make payments (AR)
- **Vendor**: Can only receive purchase invoices and make receipts (AP)
- **Both**: Can function as both customer and vendor
- **Expense**: Represents an expense account (utilities, salaries, rent, etc.)

**Opening Balance Trigger:**
When a party is created with opening_balance > 0, trigger `trg_party_opening_balance` automatically creates a journal entry:
- Customer Debit → AR Dr, Owner's Capital Cr
- Vendor Credit → Owner's Capital Dr, AP Cr
- Expense → Expense Account Dr, Owner's Capital Cr

**Example Records:**
```sql
-- Customer
INSERT INTO Parties (party_name, party_type, ar_account_id, opening_balance, balance_type)
VALUES ('ABC Corporation', 'Customer', 4, 5000.00, 'Debit');

-- Vendor
INSERT INTO Parties (party_name, party_type, ap_account_id, opening_balance, balance_type)
VALUES ('XYZ Suppliers', 'Vendor', 5, 3000.00, 'Credit');

-- Expense Party
INSERT INTO Parties (party_name, party_type, ap_account_id)
VALUES ('Electric Company', 'Expense', 23);
```

---

#### 13. Items
Product/service master data.

```sql
CREATE TABLE Items (
    item_id BIGSERIAL PRIMARY KEY,
    item_name VARCHAR(150) NOT NULL UNIQUE,
    storage VARCHAR(100),
    sale_price NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    item_code VARCHAR(50) UNIQUE,
    category VARCHAR(100),
    brand VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

| Column | Type | Description |
|--------|------|-------------|
| item_id | BIGSERIAL | Primary key |
| item_name | VARCHAR(150) | Unique item name |
| storage | VARCHAR(100) | Storage location/warehouse |
| sale_price | NUMERIC(12,2) | Default selling price |
| item_code | VARCHAR(50) | SKU/item code (optional) |
| category | VARCHAR(100) | Product category |
| brand | VARCHAR(100) | Brand name |
| created_at | TIMESTAMP | Creation timestamp |
| updated_at | TIMESTAMP | Last update timestamp |

**Constraints:**
- `item_name` UNIQUE NOT NULL
- `item_code` UNIQUE (if provided)

**Business Logic:**
- Used for both inventory and services
- `sale_price` is default; actual prices on invoices
- Can track by serial number in PurchaseUnits/SoldUnits
- Category and brand for reporting/filtering

---

### 📦 Transaction Tables

#### 14. PurchaseInvoices
Purchase invoice header.

```sql
CREATE TABLE PurchaseInvoices (
    purchase_invoice_id BIGSERIAL PRIMARY KEY,
    vendor_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);
```

| Column | Type | Description |
|--------|------|-------------|
| purchase_invoice_id | BIGSERIAL | Primary key |
| vendor_id | BIGINT | FK to Parties (must be Vendor or Both) |
| invoice_date | DATE | Invoice date |
| total_amount | NUMERIC(14,2) | Total invoice amount |
| journal_id | BIGINT | FK to associated journal entry |

**Related Tables:**
- PurchaseItems (line items)
- PurchaseUnits (serial numbers)
- JournalEntries (accounting)

**Accounting Impact:**
```
Dr Inventory/Expense (total_amount)
  Cr Accounts Payable (vendor_id) (total_amount)
```

---

#### 15. PurchaseItems
Purchase invoice line items.

```sql
CREATE TABLE PurchaseItems (
    purchase_item_id BIGSERIAL PRIMARY KEY,
    purchase_invoice_id BIGINT NOT NULL REFERENCES PurchaseInvoices(purchase_invoice_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL
);
```

| Column | Type | Description |
|--------|------|-------------|
| purchase_item_id | BIGSERIAL | Primary key |
| purchase_invoice_id | BIGINT | FK to purchase invoice |
| item_id | BIGINT | FK to Items |
| quantity | INTEGER | Quantity purchased (must be > 0) |
| unit_price | NUMERIC(12,2) | Purchase price per unit |

**Business Logic:**
- Line amount = quantity × unit_price
- Each line can have multiple PurchaseUnits (serials)
- Quantity must match number of serial numbers in PurchaseUnits

---

#### 16. PurchaseUnits
Individual serialized inventory units from purchases.

```sql
CREATE TABLE PurchaseUnits (
    unit_id BIGSERIAL PRIMARY KEY,
    purchase_item_id BIGINT NOT NULL REFERENCES PurchaseItems(purchase_item_id) ON DELETE CASCADE,
    serial_number VARCHAR(100) UNIQUE NOT NULL,
    in_stock BOOLEAN DEFAULT TRUE,
    serial_comment TEXT NULL
);
```

| Column | Type | Description |
|--------|------|-------------|
| unit_id | BIGSERIAL | Primary key |
| purchase_item_id | BIGINT | FK to purchase line item |
| serial_number | VARCHAR(100) | Unique serial/identifier |
| in_stock | BOOLEAN | TRUE until sold |
| serial_comment | TEXT | Optional comment about unit |

**Constraints:**
- `serial_number` UNIQUE NOT NULL (globally unique across all purchases)
- `in_stock` defaults to TRUE

**Business Logic:**
- Each physical unit has unique serial number
- `in_stock` set to FALSE when sold (via SoldUnits)
- serial_comment for notes (e.g., "damaged", "refurbished")
- Links to SoldUnits when sold for profit calculation

**Example:**
```sql
-- Purchase of 3 laptops with serial numbers
INSERT INTO PurchaseUnits (purchase_item_id, serial_number, serial_comment)
VALUES 
  (1, 'LAP-001', NULL),
  (1, 'LAP-002', 'Minor scratch on lid'),
  (1, 'LAP-003', NULL);
```

---

#### 17. SalesInvoices
Sales invoice header.

```sql
CREATE TABLE SalesInvoices (
    sales_invoice_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_amount NUMERIC(14,2) NOT NULL,
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL
);
```

| Column | Type | Description |
|--------|------|-------------|
| sales_invoice_id | BIGSERIAL | Primary key |
| customer_id | BIGINT | FK to Parties (Customer or Both) |
| invoice_date | DATE | Sale date |
| total_amount | NUMERIC(14,2) | Total invoice amount |
| journal_id | BIGINT | FK to journal entry |

**Accounting Impact:**
```
Dr Accounts Receivable (customer_id) (total_amount)
  Cr Sales Revenue (total_amount)
```

---

#### 18. SalesItems
Sales invoice line items.

```sql
CREATE TABLE SalesItems (
    sales_item_id BIGSERIAL PRIMARY KEY,
    sales_invoice_id BIGINT NOT NULL REFERENCES SalesInvoices(sales_invoice_id) ON DELETE CASCADE,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL
);
```

Similar to PurchaseItems but for sales.

---

#### 19. SoldUnits
Specific serialized units sold.

```sql
CREATE TABLE SoldUnits (
    sold_unit_id BIGSERIAL PRIMARY KEY,
    sales_item_id BIGINT NOT NULL REFERENCES SalesItems(sales_item_id) ON DELETE CASCADE,
    unit_id BIGINT NOT NULL REFERENCES PurchaseUnits(unit_id) ON DELETE CASCADE,
    sold_price NUMERIC(12,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'Sold' CHECK (status IN ('Sold','Returned','Damaged'))
);
```

| Column | Type | Description |
|--------|------|-------------|
| sold_unit_id | BIGSERIAL | Primary key |
| sales_item_id | BIGINT | FK to sales line item |
| unit_id | BIGINT | FK to PurchaseUnits (which unit was sold) |
| sold_price | NUMERIC(12,2) | Actual selling price |
| status | VARCHAR(20) | Sold/Returned/Damaged |

**Business Logic:**
- Links each sale to the specific purchased unit
- Enables unit-level profit calculation: `sold_price - purchase_price`
- When inserted, PurchaseUnits.in_stock set to FALSE
- Status tracks if unit was returned or damaged

---

#### 20. Payments
Outgoing payment transactions.

```sql
CREATE TABLE Payments (
    payment_id BIGSERIAL PRIMARY KEY,
    party_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES ChartOfAccounts(account_id),
    amount NUMERIC(14,4) NOT NULL CHECK (amount > 0),
    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    method VARCHAR(20) CHECK (method IN ('Cash','Bank','Cheque','Online')),
    reference_no VARCHAR(100),
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes TEXT,
    description TEXT
);
```

| Column | Type | Description |
|--------|------|-------------|
| payment_id | BIGSERIAL | Primary key |
| party_id | BIGINT | FK to payee (Vendor/Expense party) |
| account_id | BIGINT | FK to payment account (Cash/Bank) |
| amount | NUMERIC(14,4) | Payment amount |
| payment_date | DATE | Payment date |
| method | VARCHAR(20) | Cash/Bank/Cheque/Online |
| reference_no | VARCHAR(100) | Cheque #, transaction ID, etc. |
| journal_id | BIGINT | FK to journal entry |
| notes | TEXT | Payment notes |
| description | TEXT | Description |

**Accounting Impact:**
```
Dr Accounts Payable (party_id) (amount)
  Cr Cash/Bank (account_id) (amount)
```

**Trigger:** `trg_payment_journal` - Auto-creates journal entry on INSERT/UPDATE

---

#### 21. Receipts
Incoming receipt transactions from customers.

```sql
CREATE TABLE Receipts (
    receipt_id BIGSERIAL PRIMARY KEY,
    party_id BIGINT NOT NULL REFERENCES Parties(party_id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES ChartOfAccounts(account_id),
    amount NUMERIC(14,4) NOT NULL CHECK (amount > 0),
    receipt_date DATE NOT NULL DEFAULT CURRENT_DATE,
    method VARCHAR(20) CHECK (method IN ('Cash','Bank','Cheque','Online')),
    reference_no VARCHAR(100),
    journal_id BIGINT REFERENCES JournalEntries(journal_id) ON DELETE SET NULL,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes TEXT,
    description TEXT
);
```

**Accounting Impact:**
```
Dr Cash/Bank (account_id) (amount)
  Cr Accounts Receivable (party_id) (amount)
```

**Trigger:** `trg_receipt_journal` - Auto-creates journal entry on INSERT/UPDATE

---

#### 22-25. Return Tables

**PurchaseReturns** - Return of goods to vendor
**PurchaseReturnItems** - Line items for purchase returns
**SalesReturns** - Customer returns
**SalesReturnItems** - Line items for sales returns

These work similarly to invoices but reverse the accounting entries.

---

### 📒 Journal & Accounting Tables

#### 26. JournalEntries
Journal entry header (double-entry accounting).

```sql
CREATE TABLE JournalEntries (
    journal_id BIGSERIAL PRIMARY KEY,
    entry_date DATE NOT NULL DEFAULT CURRENT_DATE,
    description TEXT,
    date_created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

| Column | Type | Description |
|--------|------|-------------|
| journal_id | BIGSERIAL | Primary key |
| entry_date | DATE | Entry date |
| description | TEXT | Entry description |
| date_created | TIMESTAMP | Creation timestamp |

**Business Logic:**
- Each transaction creates ONE journal entry
- Journal entry has multiple lines (JournalLines)
- Sum of debits must equal sum of credits

---

#### 27. JournalLines
Individual journal entry lines (debits/credits).

```sql
CREATE TABLE JournalLines (
    line_id BIGSERIAL PRIMARY KEY,
    journal_id BIGINT NOT NULL REFERENCES JournalEntries(journal_id) ON DELETE CASCADE,
    account_id BIGINT NOT NULL REFERENCES ChartOfAccounts(account_id),
    party_id BIGINT REFERENCES Parties(party_id) ON DELETE SET NULL,
    debit NUMERIC(14,2) DEFAULT 0,
    credit NUMERIC(14,2) DEFAULT 0,
    CHECK (debit >= 0 AND credit >= 0),
    CHECK (NOT (debit = 0 AND credit = 0))
);
```

| Column | Type | Description |
|--------|------|-------------|
| line_id | BIGSERIAL | Primary key |
| journal_id | BIGINT | FK to journal entry |
| account_id | BIGINT | FK to Chart of Accounts |
| party_id | BIGINT | FK to Parties (for AR/AP) |
| debit | NUMERIC(14,2) | Debit amount (≥ 0) |
| credit | NUMERIC(14,2) | Credit amount (≥ 0) |

**Constraints:**
- Each line must have EITHER debit OR credit (not both, not neither)
- Both debit and credit must be ≥ 0
- For AR/AP lines, party_id must be populated

**Business Logic:**
- party_id populated for AR/AP transactions
- NULL party_id for non-AR/AP accounts
- Sum of debits = Sum of credits per journal_id

**Example Journal Entry (Purchase Invoice):**
```sql
-- Journal Entry for Purchase Invoice #1 for $1,000
INSERT INTO JournalEntries (entry_date, description)
VALUES ('2024-01-15', 'Purchase Invoice #1');  -- Returns journal_id = 1

INSERT INTO JournalLines (journal_id, account_id, party_id, debit, credit)
VALUES 
  (1, 10, NULL, 1000, 0),    -- Dr Inventory
  (1, 20, 5, 0, 1000);        -- Cr AP (Vendor #5)
```

---

#### 28. StockMovements
Inventory movement audit trail.

```sql
CREATE TABLE StockMovements (
    movement_id BIGSERIAL PRIMARY KEY,
    item_id BIGINT NOT NULL REFERENCES Items(item_id),
    serial_number TEXT,
    movement_type VARCHAR(20) NOT NULL CHECK (movement_type IN ('IN','OUT')),
    reference_type VARCHAR(50),
    reference_id BIGINT,
    movement_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    quantity INT NOT NULL
);
```

| Column | Type | Description |
|--------|------|-------------|
| movement_id | BIGSERIAL | Primary key |
| item_id | BIGINT | FK to Items |
| serial_number | TEXT | Serial number moved |
| movement_type | VARCHAR(20) | IN/OUT |
| reference_type | VARCHAR(50) | 'PurchaseInvoice', 'SalesInvoice', etc. |
| reference_id | BIGINT | ID of source transaction |
| movement_date | TIMESTAMP | Movement timestamp |
| quantity | INTEGER | +quantity for IN, -quantity for OUT |

**Business Logic:**
- **IN** - Purchase, Sales Return
- **OUT** - Sale, Purchase Return
- Provides complete audit trail
- Used for inventory reconciliation

---


## 3. All Stored Functions (82)

This system has 82 stored functions organized into 11 categories. Functions handle all business logic including transaction creation, updates, deletions, data retrieval, and reporting.

### Function Summary by Category

| Category | Count | Purpose |
|----------|-------|---------|
| **Purchase Functions** | 12 | Create, update, delete, navigate purchase invoices |
| **Sales Functions** | 13 | Create, update, delete, navigate sales invoices |
| **Payment Functions** | 10 | Process vendor/expense payments |
| **Receipt Functions** | 10 | Process customer receipts |
| **Return Functions** | 22 | Handle purchase and sales returns |
| **Party Functions** | 8 | Manage customers, vendors, expense parties |
| **Item Functions** | 4 | Manage product/service master data |
| **Stock Functions** | 2 | Inventory reporting and queries |
| **Accounting Functions** | 8 | Ledger queries and journal operations |
| **Reporting Functions** | 6 | Financial and profit reports |
| **Trigger Functions** | 3 | Auto-execute on table events |

**Total:** 82 functions

---

### 📦 Purchase Functions (12)

#### `create_purchase(p_party_id, p_invoice_date, p_items)`

**Purpose:** Creates a complete purchase invoice with line items and serial numbers, automatically creating journal entries.

**Signature:**
```sql
create_purchase(
    p_party_id BIGINT,
    p_invoice_date DATE,
    p_items JSONB
) RETURNS BIGINT
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_party_id` | BIGINT | Vendor ID (from Parties table) |
| `p_invoice_date` | DATE | Purchase invoice date |
| `p_items` | JSONB | Array of items with serials (see format below) |

**Returns:** `purchase_invoice_id` (BIGINT) - ID of created invoice

**JSON Format for p_items:**
```json
[
  {
    "item_name": "Laptop",
    "qty": 2,
    "unit_price": 500.00,
    "serials": [
      {"serial": "LAP-001", "comment": ""},
      {"serial": "LAP-002", "comment": "Minor scratch"}
    ]
  },
  {
    "item_name": "Mouse",
    "qty": 5,
    "unit_price": 10.00,
    "serials": [
      {"serial": "MOU-001"},
      {"serial": "MOU-002"},
      {"serial": "MOU-003"},
      {"serial": "MOU-004"},
      {"serial": "MOU-005"}
    ]
  }
]
```

**Function Behavior:**
1. Creates PurchaseInvoices header record
2. For each item in p_items:
   - Looks up item_id from Items table by item_name
   - If item doesn't exist, creates it automatically
   - Inserts PurchaseItems record
   - For each serial in item.serials:
     - Inserts PurchaseUnits record (serial_number, serial_comment, in_stock=TRUE)
     - Inserts StockMovements record (movement_type='IN')
3. Calculates and updates total_amount on invoice
4. Calls `rebuild_purchase_journal()` to create accounting entries:
   ```
   Dr Inventory (total_amount)
     Cr Accounts Payable (vendor, total_amount)
   ```
5. Returns the new purchase_invoice_id

**Example Usage:**
```sql
SELECT create_purchase(
    5,  -- Vendor ID
    '2024-01-15',  -- Invoice date
    '[
      {
        "item_name": "Laptop Dell XPS",
        "qty": 2,
        "unit_price": 1200.00,
        "serials": [
          {"serial": "DXPS-2024-001", "comment": ""},
          {"serial": "DXPS-2024-002", "comment": "Refurbished"}
        ]
      }
    ]'::jsonb
) AS new_invoice_id;

-- Returns: 123 (new purchase_invoice_id)
```

**Related Tables:** PurchaseInvoices, PurchaseItems, PurchaseUnits, Items, StockMovements, JournalEntries, JournalLines

**Error Handling:**
- Raises exception if vendor (p_party_id) not found
- Raises exception if serial numbers are duplicates
- Transaction rolls back on any error

---

#### `update_purchase_invoice(p_purchase_invoice_id, p_party_id, p_invoice_date, p_items)`

**Purpose:** Updates an existing purchase invoice - deletes old items/serials and recreates with new data.

**Signature:**
```sql
update_purchase_invoice(
    p_purchase_invoice_id BIGINT,
    p_party_id BIGINT,
    p_invoice_date DATE,
    p_items JSONB
) RETURNS VOID
```

**Function Behavior:**
1. Validates invoice exists and can be updated (via `validate_purchase_update2`)
2. Deletes existing PurchaseItems and PurchaseUnits (CASCADE)
3. Updates invoice header (vendor_id, invoice_date)
4. Recreates items and serials from p_items (same as create_purchase)
5. Recalculates total_amount
6. Rebuilds journal entries

**Example Usage:**
```sql
SELECT update_purchase_invoice(
    123,  -- purchase_invoice_id to update
    5,  -- vendor_id
    '2024-01-16',  -- new date
    '[{"item_name": "Updated Item", "qty": 1, "unit_price": 500, "serials": [{"serial": "NEW-001"}]}]'::jsonb
);
```

---

#### `delete_purchase(p_purchase_invoice_id)`

**Purpose:** Deletes a purchase invoice and reverses all accounting entries.

**Signature:**
```sql
delete_purchase(p_purchase_invoice_id BIGINT) RETURNS VOID
```

**Function Behavior:**
1. Validates invoice can be deleted (via `validate_purchase_delete`)
   - Checks if any units have been sold
   - Raises exception if any units marked as sold
2. Deletes journal entry (CASCADE deletes journal lines)
3. Deletes PurchaseInvoice (CASCADE deletes items, units, stock movements)

**Example Usage:**
```sql
SELECT delete_purchase(123);
```

**Validation:** Cannot delete if any purchased units have been sold!

---

#### `rebuild_purchase_journal(p_purchase_invoice_id)`

**Purpose:** Regenerates journal entries for a purchase invoice.

**Signature:**
```sql
rebuild_purchase_journal(p_purchase_invoice_id BIGINT) RETURNS VOID
```

**Function Behavior:**
1. Deletes existing journal entry for this invoice
2. Gets vendor details and total amount
3. Finds Inventory account (first Asset account)
4. Creates new journal entry:
   ```sql
   Dr Inventory (total_amount)
     Cr AP (vendor, total_amount)
   ```
5. Updates PurchaseInvoices.journal_id

**Example Usage:**
```sql
SELECT rebuild_purchase_journal(123);
```

---

#### Navigation Functions (5)

These functions help navigate through purchase invoices in order:

**`get_current_purchase(p_purchase_invoice_id)`** - Returns full invoice details as JSON  
**`get_last_purchase()`** - Returns most recent purchase  
**`get_next_purchase(p_purchase_invoice_id)`** - Returns next purchase after given ID  
**`get_previous_purchase(p_purchase_invoice_id)`** - Returns previous purchase  
**`get_last_purchase_id()`** - Returns latest purchase_invoice_id  

**Example:**
```sql
-- Get current purchase details
SELECT get_current_purchase(123);

-- Navigate to next purchase
SELECT get_next_purchase(123);

-- Get latest purchase ID
SELECT get_last_purchase_id();
```

---

#### `get_purchase_summary(p_purchase_invoice_id)`

**Purpose:** Retrieves complete purchase invoice with all items and serials as structured JSON.

**Returns:** JSONB with structure:
```json
{
  "purchase_invoice_id": 123,
  "vendor_id": 5,
  "vendor_name": "ABC Suppliers",
  "invoice_date": "2024-01-15",
  "total_amount": 2400.00,
  "items": [
    {
      "item_id": 10,
      "item_name": "Laptop",
      "quantity": 2,
      "unit_price": 1200.00,
      "serials": [
        {"serial_number": "LAP-001", "comment": ""},
        {"serial_number": "LAP-002", "comment": "Refurbished"}
      ]
    }
  ]
}
```

**Example Usage:**
```sql
SELECT get_purchase_summary(123);
```

---

### 💰 Sales Functions (13)

#### `create_sale(p_party_id, p_invoice_date, p_items)`

**Purpose:** Creates a sales invoice, marks inventory units as sold, creates journal entries.

**Signature:**
```sql
create_sale(
    p_party_id BIGINT,
    p_invoice_date DATE,
    p_items JSONB
) RETURNS BIGINT
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_party_id` | BIGINT | Customer ID |
| `p_invoice_date` | DATE | Sales invoice date |
| `p_items` | JSONB | Array of items with specific serial numbers to sell |

**JSON Format for p_items:**
```json
[
  {
    "item_name": "Laptop",
    "qty": 1,
    "unit_price": 1500.00,
    "serials": ["LAP-001"]
  }
]
```

**Function Behavior:**
1. Creates SalesInvoices header
2. For each item:
   - Inserts SalesItems record
   - For each serial:
     - Finds unit_id from PurchaseUnits WHERE serial_number = serial
     - Inserts SoldUnits (links to unit_id)
     - Updates PurchaseUnits.in_stock = FALSE
     - Inserts StockMovements (movement_type='OUT')
3. Calculates total_amount
4. Creates journal entry:
   ```
   Dr Accounts Receivable (customer, total_amount)
     Cr Sales Revenue (total_amount)
   ```
5. Returns sales_invoice_id

**Example Usage:**
```sql
SELECT create_sale(
    12,  -- Customer ID
    '2024-01-20',
    '[
      {
        "item_name": "Laptop Dell XPS",
        "qty": 1,
        "unit_price": 1500.00,
        "serials": ["DXPS-2024-001"]
      }
    ]'::jsonb
) AS new_sale_id;
```

**Important:** Serial numbers must exist in PurchaseUnits and be in_stock=TRUE!

---

#### `update_sale_invoice(p_sales_invoice_id, p_party_id, p_invoice_date, p_items)`

Similar to `update_purchase_invoice` but for sales.

---

#### `delete_sale(p_sales_invoice_id)`

**Purpose:** Deletes a sales invoice and restores inventory.

**Function Behavior:**
1. Validates (via `validate_sales_delete`)
2. Marks all SoldUnits as in_stock=TRUE (restores to inventory)
3. Deletes journal entry
4. Deletes sales invoice (CASCADE)

**Example:**
```sql
SELECT delete_sale(456);
```

---

#### Sales Navigation Functions (5)

**`get_current_sale(p_sales_invoice_id)`** - Full invoice JSON  
**`get_last_sale()`** - Most recent sale  
**`get_next_sale(p_sales_invoice_id)`** - Next sale  
**`get_previous_sale(p_sales_invoice_id)`** - Previous sale  
**`get_last_sale_id()`** - Latest sales_invoice_id  

---

#### `get_sales_summary(p_sales_invoice_id)`

Returns complete sales invoice with items and sold serials as JSON.

**Example:**
```sql
SELECT get_sales_summary(456);
```

**Returns:**
```json
{
  "sales_invoice_id": 456,
  "customer_id": 12,
  "customer_name": "John Doe",
  "invoice_date": "2024-01-20",
  "total_amount": 1500.00,
  "items": [
    {
      "item_name": "Laptop",
      "quantity": 1,
      "unit_price": 1500.00,
      "serials": ["DXPS-2024-001"]
    }
  ]
}
```

---

### 💳 Payment Functions (10)

#### `make_payment(p_party_id, p_account_id, p_amount, p_date, p_method, p_reference_no, p_description)`

**Purpose:** Records a payment to a vendor or expense party.

**Signature:**
```sql
make_payment(
    p_party_id BIGINT,
    p_account_id BIGINT,
    p_amount NUMERIC(14,4),
    p_date DATE,
    p_method VARCHAR(20),
    p_reference_no VARCHAR(100),
    p_description TEXT
) RETURNS BIGINT
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_party_id` | BIGINT | Vendor or Expense party ID |
| `p_account_id` | BIGINT | Payment account (Cash/Bank) |
| `p_amount` | NUMERIC(14,4) | Payment amount |
| `p_date` | DATE | Payment date |
| `p_method` | VARCHAR(20) | Cash/Bank/Cheque/Online |
| `p_reference_no` | VARCHAR(100) | Cheque #, transaction ref |
| `p_description` | TEXT | Payment description |

**Returns:** `payment_id` (BIGINT)

**Journal Entry (auto-created by trigger):**
```
Dr Accounts Payable/Expense (party, p_amount)
  Cr Cash/Bank (p_account_id, p_amount)
```

**Example Usage:**
```sql
SELECT make_payment(
    5,  -- vendor_id
    2,  -- account_id (Bank account)
    1000.00,  -- amount
    '2024-01-25',  -- payment date
    'Bank',  -- method
    'TXN-12345',  -- reference
    'Payment for Invoice #123'  -- description
) AS payment_id;
```

**Related Tables:** Payments, JournalEntries, JournalLines

---

#### Payment Navigation & Query Functions (9)

**`get_last_20_payments_json()`** - Returns last 20 payments as JSON array  
**`get_last_payment()`** - Most recent payment  
**`get_next_payment(p_payment_id)`** - Next payment  
**`get_previous_payment(p_payment_id)`** - Previous payment  
**`get_payment_details(p_payment_id)`** - Full payment details JSON  
**`get_payments_by_date_json(p_from_date, p_to_date)`** - Payments in date range  

**`update_payment(...)`** - Updates existing payment  
**`delete_payment(p_payment_id)`** - Deletes payment and reverses journal  

**Example:**
```sql
-- Get last 20 payments
SELECT get_last_20_payments_json();

-- Get payments for January 2024
SELECT get_payments_by_date_json('2024-01-01', '2024-01-31');

-- Delete a payment
SELECT delete_payment(789);
```

---

### 📥 Receipt Functions (10)

#### `make_receipt(p_party_id, p_account_id, p_amount, p_date, p_method, p_reference_no, p_description)`

**Purpose:** Records a receipt from a customer.

**Parameters:** Same as `make_payment`

**Journal Entry (auto-created by trigger):**
```
Dr Cash/Bank (p_account_id, p_amount)
  Cr Accounts Receivable (party, p_amount)
```

**Example Usage:**
```sql
SELECT make_receipt(
    12,  -- customer_id
    1,  -- account_id (Cash)
    500.00,
    '2024-01-26',
    'Cash',
    '',
    'Receipt for Invoice #456'
) AS receipt_id;
```

---

#### Receipt Navigation Functions (9)

**`get_last_20_receipts_json()`**  
**`get_last_receipt()`**  
**`get_next_receipt(p_receipt_id)`**  
**`get_previous_receipt(p_receipt_id)`**  
**`get_receipt_details(p_receipt_id)`**  
**`get_receipts_by_date_json(p_from_date, p_to_date)`**  
**`update_receipt(...)`**  
**`delete_receipt(p_receipt_id)`**  

---

### ↩️ Return Functions (22)

These functions handle purchase returns (to vendors) and sales returns (from customers).

#### Purchase Return Functions (11)

**`create_purchase_return(p_vendor_id, p_return_date, p_items)`** - Creates purchase return  
**`update_purchase_return(...)`** - Updates return  
**`delete_purchase_return(p_purchase_return_id)`** - Deletes return  
**`rebuild_purchase_return_journal(p_purchase_return_id)`** - Regenerates journal  
**`get_current_purchase_return(p_purchase_return_id)`** - Return details  
**`get_last_purchase_return()`** - Most recent return  
**`get_next_purchase_return(p_purchase_return_id)`** - Next return  
**`get_previous_purchase_return(p_purchase_return_id)`** - Previous return  
**`get_purchase_return_summary(p_purchase_return_id)`** - Full return JSON  
**`get_last_purchase_return_id()`** - Latest return ID  
**`serial_exists_in_purchase_return(p_serial_number)`** - Check if serial already returned  

**Journal Entry for Purchase Return:**
```
Dr Accounts Payable (vendor, amount)
  Cr Inventory (amount)
```

---

#### Sales Return Functions (11)

Similar to purchase returns but for customer returns:

**`create_sale_return(p_customer_id, p_return_date, p_items)`**  
**`update_sale_return(...)`**  
**`delete_sale_return(p_sales_return_id)`**  
**`rebuild_sales_return_journal(p_sales_return_id)`**  
**`get_current_sales_return(p_sales_return_id)`**  
**`get_last_sales_return()`**  
**`get_next_sales_return(p_sales_return_id)`**  
**`get_previous_sales_return(p_sales_return_id)`**  
**`get_sales_return_summary(p_sales_return_id)`**  
**`get_last_sales_return_id()`**  
**`serial_exists_in_sales_return(p_serial_number)`**  

**Journal Entry for Sales Return:**
```
Dr Sales Returns (amount)
  Cr Accounts Receivable (customer, amount)
```

---

### 👥 Party Functions (8)

#### `add_party_from_json(party_data)`

**Purpose:** Creates a new party (Customer/Vendor/Both/Expense) from JSON.

**Signature:**
```sql
add_party_from_json(party_data JSONB) RETURNS VOID
```

**JSON Format:**
```json
{
  "party_name": "ABC Corporation",
  "party_type": "Customer",
  "contact_info": "555-1234",
  "address": "123 Main St",
  "opening_balance": 5000.00,
  "balance_type": "Debit"
}
```

**Function Behavior:**
1. For Expense type: Auto-creates expense GL account
2. Links to appropriate AR/AP accounts
3. Inserts into Parties table
4. Trigger creates opening balance journal entry if opening_balance > 0

**Example:**
```sql
SELECT add_party_from_json('{
  "party_name": "New Customer Inc",
  "party_type": "Customer",
  "contact_info": "customer@example.com",
  "opening_balance": 1000.00,
  "balance_type": "Debit"
}'::jsonb);
```

---

#### Other Party Functions

**`update_party_from_json(p_id, party_data)`** - Updates party  
**`get_parties_json()`** - All parties as JSON array  
**`get_party_balances_json()`** - Customer/Vendor balances  
**`get_party_by_name(p_party_name)`** - Find party by name  
**`get_expense_party_balances_json()`** - Expense party balances  
**`get_cash_ledger_with_party()`** - Cash ledger with party details  

---

### 📦 Item Functions (4)

**`add_item_from_json(item_data)`** - Creates new item  
**`update_item_from_json(item_data)`** - Updates item  

**Example:**
```sql
SELECT add_item_from_json('{
  "item_name": "Wireless Mouse",
  "storage": "Warehouse A",
  "sale_price": 25.00,
  "item_code": "MS-001",
  "category": "Electronics",
  "brand": "Logitech"
}'::jsonb);
```

**`item_transaction_history(p_item_name)`** - Complete transaction history for item  
**`get_item_stock_by_name(p_item_name)`** - Current stock for item  

---

### 📊 Stock Functions (2)

#### `stock_summary()`

**Purpose:** Returns current stock summary for all items.

**Returns:** Table with columns:
- item_id
- item_name
- total_purchased
- total_sold
- in_stock_count

**Example:**
```sql
SELECT * FROM stock_summary();
```

---

#### `get_item_stock_by_name(p_item_name)`

**Purpose:** Gets current stock for a specific item.

**Example:**
```sql
SELECT get_item_stock_by_name('Laptop Dell XPS');
```

---

### 📒 Accounting Functions (8)

#### `detailed_ledger(p_account_id, p_from_date, p_to_date)`

**Purpose:** Generates detailed general ledger report for an account.

**Returns:** Table with:
- entry_date
- description
- debit
- credit
- balance (running balance)

**Example:**
```sql
SELECT * FROM detailed_ledger(
    4,  -- Account Receivable account
    '2024-01-01',
    '2024-01-31'
);
```

---

#### `get_serial_ledger(p_serial_number)`

**Purpose:** Complete lifecycle ledger for a specific serial number.

**Returns:** Purchase → Sale → Return history for a serial

**Example:**
```sql
SELECT get_serial_ledger('LAP-001');
```

---

#### Other Accounting Functions

**`get_cash_ledger_with_party()`** - Cash account ledger with party details

---

### 📈 Reporting Functions (6)

#### `sale_wise_profit(p_from_date, p_to_date)`

**Purpose:** Calculates profit/loss for each sold unit in date range.

**Returns:** Table with columns:
- sale_date
- item_name
- serial_number
- sale_price
- purchase_price
- profit_loss (sale_price - purchase_price)
- profit_loss_percent
- vendor_name (who it was purchased from)

**Example:**
```sql
SELECT * FROM sale_wise_profit('2024-01-01', '2024-01-31');
```

**Sample Output:**
| sale_date | item_name | serial_number | sale_price | purchase_price | profit_loss | profit_loss_percent | vendor_name |
|-----------|-----------|---------------|------------|----------------|-------------|---------------------|-------------|
| 2024-01-20 | Laptop | DXPS-2024-001 | 1500.00 | 1200.00 | 300.00 | 25.00 | ABC Suppliers |

---


## 4. Database Views (4)

Views provide read-only reporting interfaces to complex queries.

### vw_trial_balance

**Purpose:** Generates a trial balance report showing all account balances.

**Columns:**
- account_code
- account_name
- account_type
- debit_balance
- credit_balance

**Definition:**
Aggregates all journal lines by account, calculating total debits and credits.

**Usage:**
```sql
SELECT * FROM vw_trial_balance
ORDER BY account_code;
```

---

### stock_worth_report

**Purpose:** Calculates total inventory value at cost.

**Columns:**
- item_id
- item_name
- total_units_in_stock
- total_purchase_value (sum of unit costs for in-stock items)

**Usage:**
```sql
SELECT * FROM stock_worth_report;
```

---

### stock_report

**Purpose:** Detailed stock report with item details.

**Columns:**
- item_id
- item_name
- category
- brand
- units_purchased
- units_sold
- units_in_stock
- purchase_value
- potential_sale_value

**Usage:**
```sql
SELECT * FROM stock_report
WHERE units_in_stock > 0;
```

---

### standing_company_worth_view

**Purpose:** Complete financial position and P&L summary.

**Returns:** Single JSON object with:
```json
{
  "financial_position": {
    "total_assets": 50000.00,
    "total_liabilities": 20000.00,
    "total_equity": 15000.00,
    "net_worth": 30000.00
  },
  "profit_and_loss": {
    "total_revenue": 45000.00,
    "total_expenses": 30000.00,
    "net_profit_loss": 15000.00
  }
}
```

**Logic:**
- Aggregates all journal lines by account type
- Calculates asset/liability/equity balances
- Includes party balances (AR/AP)
- Calculates revenue vs expenses

**Usage:**
```sql
SELECT * FROM standing_company_worth_view;
```

---

## 5. Trigger Functions (3)

Trigger functions execute automatically when certain table events occur.

### `trg_party_opening_balance()`

**Trigger:** AFTER INSERT ON Parties  
**Purpose:** Automatically creates journal entry for party opening balance

**Behavior:**
1. If NEW.opening_balance > 0:
2. Creates JournalEntry
3. Based on party_type and balance_type:
   - **Customer (Debit):** Dr AR, Cr Owner's Capital
   - **Vendor (Credit):** Dr Owner's Capital, Cr AP
   - **Expense:** Dr Expense Account, Cr Owner's Capital
4. Links party_id to journal line for AR/AP

**Example:**
When this INSERT occurs:
```sql
INSERT INTO Parties (party_name, party_type, ar_account_id, opening_balance, balance_type)
VALUES ('New Customer', 'Customer', 4, 5000.00, 'Debit');
```

Trigger automatically creates:
```sql
-- Journal Entry
Dr Accounts Receivable (party: New Customer) 5000.00
  Cr Owner's Capital                         5000.00
```

---

### `trg_payment_journal()`

**Trigger:** AFTER INSERT OR UPDATE OR DELETE ON Payments  
**Purpose:** Maintains journal entries for payment transactions

**Behavior:**

**On INSERT:**
1. Gets vendor's AP account
2. Creates journal entry:
   ```
   Dr AP (vendor) amount
     Cr Cash/Bank (account_id) amount
   ```
3. Updates Payments.journal_id

**On UPDATE:**
1. If amount/account/party/description changed:
2. Deletes old journal entry
3. Creates new journal entry

**On DELETE:**
1. Deletes associated journal entry

**Example:**
```sql
INSERT INTO Payments (party_id, account_id, amount, payment_date, method)
VALUES (5, 2, 1000.00, '2024-01-25', 'Bank');

-- Trigger creates:
Dr Accounts Payable (Vendor #5)  1000.00
  Cr Bank Account #2             1000.00
```

---

### `trg_receipt_journal()`

**Trigger:** AFTER INSERT OR UPDATE OR DELETE ON Receipts  
**Purpose:** Maintains journal entries for receipt transactions

**Behavior:** Similar to `trg_payment_journal` but for receipts

**On INSERT/UPDATE:**
```
Dr Cash/Bank (account_id) amount
  Cr AR (customer) amount
```

**Example:**
```sql
INSERT INTO Receipts (party_id, account_id, amount, receipt_date, method)
VALUES (12, 1, 500.00, '2024-01-26', 'Cash');

-- Trigger creates:
Dr Cash Account #1                500.00
  Cr Accounts Receivable (Customer #12)  500.00
```

---

## 6. Data Flow & Business Processes

### 📦 Purchase Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    PURCHASE PROCESS FLOW                     │
└─────────────────────────────────────────────────────────────┘

1. CREATE PURCHASE INVOICE
   ↓
   create_purchase(vendor_id, date, items_json)
   ↓
   ┌─────────────────────────────────────┐
   │ Insert PurchaseInvoices             │
   │ purchase_invoice_id = 123           │
   └─────────────────────────────────────┘
   ↓
2. FOR EACH ITEM IN items_json
   ↓
   ┌─────────────────────────────────────┐
   │ Lookup/Create Item in Items table   │
   │ Insert PurchaseItems                │
   │ purchase_item_id = 456              │
   └─────────────────────────────────────┘
   ↓
3. FOR EACH SERIAL IN item.serials
   ↓
   ┌──────────────────────────────────────┐
   │ Insert PurchaseUnits                 │
   │ (serial_number, in_stock=TRUE)       │
   │                                      │
   │ Insert StockMovements                │
   │ (movement_type='IN')                 │
   └──────────────────────────────────────┘
   ↓
4. CALCULATE & UPDATE TOTAL
   ↓
   total_amount = SUM(qty × unit_price)
   UPDATE PurchaseInvoices SET total_amount = ...
   ↓
5. CREATE JOURNAL ENTRY
   ↓
   rebuild_purchase_journal(123)
   ↓
   ┌──────────────────────────────────────┐
   │ INSERT JournalEntries                │
   │ journal_id = 789                     │
   │                                      │
   │ INSERT JournalLines:                 │
   │   Dr Inventory    total_amount       │
   │   Cr AP (vendor)  total_amount       │
   └──────────────────────────────────────┘
   ↓
6. COMPLETE
   ↓
   Returns: purchase_invoice_id = 123
```

**Database State After Purchase:**
- PurchaseInvoices: 1 record
- PurchaseItems: N records (one per item type)
- PurchaseUnits: M records (one per serial)
- StockMovements: M records (type='IN')
- JournalEntries: 1 record
- JournalLines: 2 records (Dr + Cr)

---

### 💰 Sales Flow

```
┌─────────────────────────────────────────────────────────────┐
│                     SALES PROCESS FLOW                       │
└─────────────────────────────────────────────────────────────┘

1. CREATE SALES INVOICE
   ↓
   create_sale(customer_id, date, items_json)
   ↓
   ┌─────────────────────────────────────┐
   │ Insert SalesInvoices                │
   │ sales_invoice_id = 456              │
   └─────────────────────────────────────┘
   ↓
2. FOR EACH ITEM IN items_json
   ↓
   ┌─────────────────────────────────────┐
   │ Insert SalesItems                   │
   │ sales_item_id = 789                 │
   └─────────────────────────────────────┘
   ↓
3. FOR EACH SERIAL IN item.serials
   ↓
   ┌──────────────────────────────────────┐
   │ Lookup unit_id from PurchaseUnits    │
   │ WHERE serial_number = serial         │
   │   AND in_stock = TRUE                │
   │                                      │
   │ Insert SoldUnits                     │
   │ (unit_id, sold_price)                │
   │                                      │
   │ UPDATE PurchaseUnits                 │
   │ SET in_stock = FALSE                 │
   │                                      │
   │ Insert StockMovements                │
   │ (movement_type='OUT')                │
   └──────────────────────────────────────┘
   ↓
4. CALCULATE TOTAL
   ↓
   total_amount = SUM(qty × unit_price)
   ↓
5. CREATE JOURNAL ENTRY
   ↓
   rebuild_sales_journal(456)
   ↓
   ┌──────────────────────────────────────┐
   │ INSERT JournalEntries                │
   │                                      │
   │ INSERT JournalLines:                 │
   │   Dr AR (customer)  total_amount     │
   │   Cr Sales Revenue  total_amount     │
   └──────────────────────────────────────┘
   ↓
6. COMPLETE
   ↓
   Returns: sales_invoice_id = 456
```

**Inventory Impact:**
- PurchaseUnits: in_stock changed from TRUE → FALSE
- Profit calculable: sold_price - purchase_price

---

### 💳 Payment Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    PAYMENT PROCESS FLOW                      │
└─────────────────────────────────────────────────────────────┘

1. RECORD PAYMENT
   ↓
   make_payment(vendor_id, bank_account, amount, date, ...)
   ↓
   ┌─────────────────────────────────────┐
   │ INSERT Payments                     │
   │ payment_id = 111                    │
   └─────────────────────────────────────┘
   ↓
2. TRIGGER FIRES: trg_payment_journal()
   ↓
   ┌──────────────────────────────────────┐
   │ Get vendor's AP account              │
   │                                      │
   │ INSERT JournalEntries                │
   │ journal_id = 222                     │
   │                                      │
   │ INSERT JournalLines:                 │
   │   Dr AP (vendor)    amount           │
   │   Cr Bank           amount           │
   │                                      │
   │ UPDATE Payments                      │
   │ SET journal_id = 222                 │
   └──────────────────────────────────────┘
   ↓
3. COMPLETE
   ↓
   Returns: payment_id = 111
```

**Effect on Balances:**
- Vendor's AP balance decreases (debit reduces credit balance)
- Bank balance decreases (credit reduces debit balance)

---

### 📥 Receipt Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    RECEIPT PROCESS FLOW                      │
└─────────────────────────────────────────────────────────────┘

1. RECORD RECEIPT
   ↓
   make_receipt(customer_id, cash_account, amount, date, ...)
   ↓
   ┌─────────────────────────────────────┐
   │ INSERT Receipts                     │
   │ receipt_id = 333                    │
   └─────────────────────────────────────┘
   ↓
2. TRIGGER FIRES: trg_receipt_journal()
   ↓
   ┌──────────────────────────────────────┐
   │ Get customer's AR account            │
   │                                      │
   │ INSERT JournalEntries                │
   │ journal_id = 444                     │
   │                                      │
   │ INSERT JournalLines:                 │
   │   Dr Cash           amount           │
   │   Cr AR (customer)  amount           │
   │                                      │
   │ UPDATE Receipts                      │
   │ SET journal_id = 444                 │
   └──────────────────────────────────────┘
   ↓
3. COMPLETE
   ↓
   Returns: receipt_id = 333
```

**Effect on Balances:**
- Customer's AR balance decreases (credit reduces debit balance)
- Cash balance increases (debit increases debit balance)

---

### ↩️ Return Flow (Purchase Return)

```
┌─────────────────────────────────────────────────────────────┐
│                 PURCHASE RETURN PROCESS FLOW                 │
└─────────────────────────────────────────────────────────────┘

1. CREATE PURCHASE RETURN
   ↓
   create_purchase_return(vendor_id, date, items_json)
   ↓
   Items JSON includes serial numbers being returned
   ↓
   ┌─────────────────────────────────────┐
   │ INSERT PurchaseReturns              │
   │ purchase_return_id = 555            │
   │                                     │
   │ FOR EACH item:                      │
   │   INSERT PurchaseReturnItems        │
   │   (serial_number, unit_price)       │
   │                                     │
   │   UPDATE PurchaseUnits              │
   │   SET in_stock = FALSE              │
   │   (mark as returned)                │
   │                                     │
   │   INSERT StockMovements             │
   │   (movement_type='OUT')             │
   └─────────────────────────────────────┘
   ↓
2. CREATE JOURNAL ENTRY
   ↓
   rebuild_purchase_return_journal(555)
   ↓
   ┌──────────────────────────────────────┐
   │ INSERT JournalEntries                │
   │                                      │
   │ INSERT JournalLines:                 │
   │   Dr AP (vendor)    amount           │
   │   Cr Inventory      amount           │
   │                                      │
   │ (Reverses original purchase entry)   │
   └──────────────────────────────────────┘
   ↓
3. COMPLETE
```

**Effect:**
- Reduces AP balance (we owe vendor less)
- Reduces inventory value
- Units marked as not in stock

---

### Complete Transaction Lifecycle Example

```
DAY 1: Purchase
  create_purchase(vendor_id=5, date='2024-01-01', items=[
    {item_name: "Laptop", qty: 1, unit_price: 1000, serials: ["LAP-001"]}
  ])
  
  Result:
    PurchaseInvoices: invoice_id=1, total=1000
    PurchaseUnits: unit_id=1, serial="LAP-001", in_stock=TRUE
    Journal: Dr Inventory 1000, Cr AP (Vendor #5) 1000
  
  Balances:
    Inventory: +1000 (Dr)
    AP: +1000 (Cr)

DAY 5: Payment to Vendor
  make_payment(vendor_id=5, account=Bank, amount=600, ...)
  
  Result:
    Payments: payment_id=1, amount=600
    Journal: Dr AP (Vendor #5) 600, Cr Bank 600
  
  Balances:
    AP: 1000 - 600 = 400 (Cr) (still owe 400)
    Bank: -600 (Cr)

DAY 10: Sell the Laptop
  create_sale(customer_id=12, date='2024-01-10', items=[
    {item_name: "Laptop", qty: 1, unit_price: 1500, serials: ["LAP-001"]}
  ])
  
  Result:
    SalesInvoices: invoice_id=1, total=1500
    SoldUnits: sold_unit_id=1, unit_id=1, sold_price=1500
    PurchaseUnits: unit_id=1, in_stock=FALSE
    Journal: Dr AR (Customer #12) 1500, Cr Sales Revenue 1500
  
  Balances:
    AR: +1500 (Dr)
    Sales Revenue: +1500 (Cr)
  
  Profit: 1500 - 1000 = 500

DAY 15: Receive Payment from Customer
  make_receipt(customer_id=12, account=Cash, amount=1500, ...)
  
  Result:
    Receipts: receipt_id=1, amount=1500
    Journal: Dr Cash 1500, Cr AR (Customer #12) 1500
  
  Balances:
    Cash: +1500 (Dr)
    AR: 1500 - 1500 = 0 (settled)

FINAL POSITION:
  Assets:
    Cash: +1500
    Bank: -600
    Inventory: 0 (sold)
  Liabilities:
    AP: +400 (still owe vendor)
  Revenue:
    Sales: +1500
  Net Position: +500 profit
```

---

## 7. Key Design Principles

### 1. Double-Entry Accounting Integrity

**Principle:** Every transaction creates balanced journal entries where Debits = Credits.

**Implementation:**
- All transaction functions call `rebuild_*_journal()` functions
- JournalLines table has CHECK constraints ensuring no zero-amount lines
- Triggers auto-create journal entries for Payments/Receipts
- Functions validate balances before posting

**Example:**
```sql
-- This is enforced at database level
CHECK (debit >= 0 AND credit >= 0)
CHECK (NOT (debit = 0 AND credit = 0))
```

---

### 2. Serial Number Traceability

**Principle:** Every physical inventory unit is tracked individually from purchase through sale.

**Implementation:**
- PurchaseUnits: Each unit gets unique serial_number
- SoldUnits: Links to specific PurchaseUnit via unit_id
- StockMovements: Complete audit trail of IN/OUT
- in_stock flag: TRUE (available) / FALSE (sold or returned)

**Benefits:**
- Unit-level profit calculation
- Complete product lifecycle tracking
- Easy identification of slow-moving items
- Warranty and service history possible

---

### 3. Party-Centric Design

**Principle:** Single Parties table handles Customers, Vendors, Both, and Expense entities.

**Implementation:**
- party_type determines behavior
- ar_account_id/ap_account_id link to GL accounts
- For "Both" type, system tracks both AR and AP balances
- For "Expense" type, ap_account_id points to expense GL account

**Benefits:**
- Simplified data model
- Easy conversion (Customer → Both, Vendor → Both)
- Unified reporting
- Single party can have complex relationship

---

### 4. Automated Accounting

**Principle:** Application logic creates all journal entries; users never manually post to GL.

**Implementation:**
- Functions: create_purchase, create_sale, etc. call journal builders
- Triggers: Payments/Receipts auto-create journals
- Rebuild functions: Allow regeneration if errors occur
- Delete functions: Properly reverse accounting

**Benefits:**
- Eliminates manual posting errors
- Ensures consistency
- Audit trail maintained
- Easy to fix mistakes (delete + recreate)

---

### 5. JSONB for Flexibility

**Principle:** Use JSONB for complex input structures (invoice items, serials).

**Implementation:**
```sql
create_purchase(
  vendor_id BIGINT,
  invoice_date DATE,
  items JSONB  -- [{item_name, qty, unit_price, serials: [...]}]
)
```

**Benefits:**
- Single function call for complex operations
- Easy to pass from application layer
- PostgreSQL validates JSON structure
- Supports nested data (items → serials)

---

### 6. Referential Integrity

**Principle:** Use Foreign Keys with appropriate CASCADE/SET NULL behaviors.

**Implementation:**
```sql
-- Cascade deletes
CREATE TABLE PurchaseItems (
  purchase_invoice_id BIGINT REFERENCES PurchaseInvoices ON DELETE CASCADE
)

-- Preserve history
CREATE TABLE PurchaseInvoices (
  journal_id BIGINT REFERENCES JournalEntries ON DELETE SET NULL
)
```

**Strategy:**
- CASCADE: Detail tables (items, units) deleted with header
- SET NULL: Historical references preserved even if master deleted
- RESTRICT: Prevent deletion if dependencies exist

---

### 7. Validation Before Modification

**Principle:** Validate before allowing updates/deletes.

**Implementation:**
```sql
-- Cannot delete purchase if units have been sold
SELECT validate_purchase_delete(p_purchase_invoice_id);

-- Cannot update sales if ...
SELECT validate_sales_update(p_sales_invoice_id);
```

**Benefits:**
- Data integrity maintained
- Prevents orphaned records
- Clear error messages
- Business rule enforcement

---

### 8. Hierarchical Chart of Accounts

**Principle:** Support unlimited account hierarchy depth.

**Implementation:**
```sql
CREATE TABLE ChartOfAccounts (
  parent_account BIGINT REFERENCES ChartOfAccounts(account_id)
)
```

**Benefits:**
- Flexible account structure
- Rollup reporting possible
- Industry-standard COA structures supported

---

## 8. Database Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                       APPLICATION LAYER                      │
│                         (Django ORM)                         │
└─────────────────────────────────────────────────────────────┘
                            ↓ ↑
                    Function Calls / Result Sets
                            ↓ ↑
┌─────────────────────────────────────────────────────────────┐
│                    BUSINESS LOGIC LAYER                      │
│                    (Stored Functions)                        │
│                                                              │
│  - create_*, update_*, delete_* functions                   │
│  - Validation functions                                     │
│  - Navigation functions                                     │
│  - Reporting functions                                      │
└─────────────────────────────────────────────────────────────┘
                            ↓ ↑
                    DML Operations / Triggers
                            ↓ ↑
┌─────────────────────────────────────────────────────────────┐
│                       DATA LAYER                             │
│                    (Tables + Triggers)                       │
│                                                              │
│  Master Data:  COA, Parties, Items                          │
│  Transactions: Purchases, Sales, Payments, Receipts         │
│  Accounting:   JournalEntries, JournalLines                 │
│  Inventory:    PurchaseUnits, SoldUnits, StockMovements     │
└─────────────────────────────────────────────────────────────┘
                            ↓ ↑
                      Query / Updates
                            ↓ ↑
┌─────────────────────────────────────────────────────────────┐
│                    REPORTING LAYER                           │
│                      (Views)                                 │
│                                                              │
│  - vw_trial_balance                                         │
│  - stock_worth_report                                       │
│  - stock_report                                             │
│  - standing_company_worth_view                              │
└─────────────────────────────────────────────────────────────┘
```

---

### Data Flow Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      USER INTERFACE                          │
│                     (Django Views)                           │
└──────────────────────────────────────────────────────────────┘
                             ↓
┌──────────────────────────────────────────────────────────────┐
│                     API/SERVICE LAYER                        │
│           Calls stored functions with JSON data              │
└──────────────────────────────────────────────────────────────┘
                             ↓
            ┌────────────────┴────────────────┐
            │                                  │
     ┌──────▼──────┐                  ┌───────▼────────┐
     │  FUNCTION   │                  │    TRIGGER     │
     │   LOGIC     │                  │    LOGIC       │
     │             │                  │                │
     │ - Validate  │                  │ - Auto-journal │
     │ - Transform │                  │ - Auto-balance │
     │ - Insert    │                  │                │
     └──────┬──────┘                  └───────┬────────┘
            │                                  │
            └────────────────┬─────────────────┘
                             ↓
              ┌──────────────────────────┐
              │  DATABASE TABLES         │
              │  - Normalized storage    │
              │  - Referential integrity │
              │  - Constraints           │
              └──────────────┬───────────┘
                             ↓
              ┌──────────────────────────┐
              │  VIEWS                   │
              │  - Aggregated reports    │
              │  - Read-only access      │
              └──────────────────────────┘
```

---

### Transaction Processing Model

**Model:** ACID-compliant transactional processing

**Example:**
```sql
BEGIN;  -- Start transaction

  -- Insert invoice
  INSERT INTO PurchaseInvoices ...;
  
  -- Insert items
  INSERT INTO PurchaseItems ...;
  
  -- Insert units
  INSERT INTO PurchaseUnits ...;
  
  -- Create journal entries
  INSERT INTO JournalEntries ...;
  INSERT INTO JournalLines ...;
  
  -- Validate balances
  IF (SELECT SUM(debit) - SUM(credit) FROM JournalLines WHERE journal_id = ...)  != 0 THEN
    RAISE EXCEPTION 'Journal entries do not balance';
  END IF;

COMMIT;  -- All or nothing
```

**Error Handling:**
- Any error → ROLLBACK entire transaction
- Database remains in consistent state
- Application receives error message
- User can retry

---

### Security & Access Control

**Database Level:**
- Django auth tables (10 tables)
- User permissions managed via Django ORM
- Row-level security not implemented (handled in app layer)

**Function Access:**
- All functions PUBLIC (accessed via Django ORM)
- Django application enforces user permissions
- Audit trail in django_admin_log

**Recommended:**
- Grant SELECT only to read-only users
- Grant EXECUTE on functions to app users
- Revoke direct table access from app users

---

## 9. Summary Statistics

### Database Metrics

| Metric | Count |
|--------|-------|
| **Total Tables** | 28 |
| - Django Auth/Admin | 10 |
| - Business Tables | 18 |
| **Total Functions** | 82 |
| - Purchase | 12 |
| - Sales | 13 |
| - Payment | 10 |
| - Receipt | 10 |
| - Returns | 22 |
| - Party | 8 |
| - Item | 4 |
| - Stock | 2 |
| - Accounting | 8 |
| - Reporting | 6 |
| - Triggers | 3 |
| **Total Views** | 4 |
| **Total Triggers** | 3 |
| **Total Indexes** | ~50+ |

---

### Table Relationships

```
ChartOfAccounts (28 tables total)
     ↓
     ├─→ Parties (Customer, Vendor, Expense)
     │      ↓
     │      ├─→ PurchaseInvoices
     │      │      ├─→ PurchaseItems
     │      │      │      └─→ PurchaseUnits
     │      │      └─→ JournalEntries
     │      │
     │      ├─→ SalesInvoices
     │      │      ├─→ SalesItems
     │      │      │      └─→ SoldUnits → PurchaseUnits
     │      │      └─→ JournalEntries
     │      │
     │      ├─→ Payments → JournalEntries
     │      │
     │      ├─→ Receipts → JournalEntries
     │      │
     │      ├─→ PurchaseReturns
     │      │      └─→ PurchaseReturnItems
     │      │
     │      └─→ SalesReturns
     │             └─→ SalesReturnItems
     │
     └─→ JournalEntries
            └─→ JournalLines (links to Parties, ChartOfAccounts)
```

---

### Performance Considerations

**Indexes:**
- All primary keys indexed (automatic)
- All foreign keys indexed
- account_code, party_name indexed (UNIQUE)
- serial_number indexed (UNIQUE)
- invoice_date fields indexed

**Query Optimization:**
- Views use CTEs for complex aggregations
- JSONB fields used for flexible data structures
- Functions use efficient queries with JOINs
- Triggers minimize redundant updates

**Scalability:**
- Partitioning possible on date fields for large datasets
- Archive old data to separate tables
- Index maintenance important as data grows

---

## Conclusion

This database implements a complete, production-ready accounting + inventory management system with:

✅ **Full GAAP compliance** - Double-entry accounting  
✅ **Serial-level tracking** - Individual unit control  
✅ **Automated posting** - No manual GL entries  
✅ **Comprehensive audit trail** - Every transaction logged  
✅ **Flexible party model** - Customers, vendors, expenses in one  
✅ **Real-time reporting** - Trial balance, P&L, stock reports  
✅ **Data integrity** - Foreign keys, constraints, validation  
✅ **Complete API** - 82 functions for all operations  

**Total Lines of SQL:** ~5,000  
**Function Count:** 82  
**View Count:** 4  
**Table Count:** 28  

---

**Document Version:** 1.0  
**Last Updated:** 2024  
**Database Schema Version:** Production  

---

