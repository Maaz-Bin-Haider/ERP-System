<div align="center">

# 🗄️ ERP System — Database & Architecture
### *PostgreSQL Schema, Stored Functions, Triggers & System Design*

![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14+-336791?style=for-the-badge&logo=postgresql&logoColor=white)
![SQL](https://img.shields.io/badge/SQL-Stored%20Procedures-CC2927?style=for-the-badge&logo=databricks&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-ERP%20System-0078D4?style=for-the-badge&logo=diagram&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-EC2%20Deployed-FF9900?style=for-the-badge&logo=amazon-aws&logoColor=white)

> Complete database design and architectural documentation for the **Accounting Plus Inventory Management ERP System**. Includes 18 production tables, 40+ stored functions, automated triggers, ER diagrams, deployment architecture, and execution flow diagrams.

</div>

---

## 📑 Table of Contents

- [Repository Contents](#-repository-contents)
- [System Overview](#-system-overview)
- [Database Architecture](#️-database-architecture)
- [Core Tables](#-core-tables)
- [Stored Functions by Module](#-stored-functions-by-module)
- [Trigger Functions](#-trigger-functions)
- [Database Views](#-database-views)
- [ER Diagrams](#-er-diagrams)
- [Deployment Architecture](#-deployment-architecture)
- [Execution Flow](#-execution-flow)
- [Schema Setup](#-schema-setup)
- [Backups](#-database-backups)

---

## 📂 Repository Contents

```
ERP-System/
│
├── DataBase/
│   ├── Schema/
│   │   ├── Tables/
│   │   │   ├── tables.sql                          # Core table definitions
│   │   │   └── tables_from_backup_12_02_2026.sql   # Latest backup schema
│   │   ├── Sale Functions/           sales.sql
│   │   ├── Purchase Function/        purchase.sql
│   │   ├── Sale Return Functions/    sale_return.sql
│   │   ├── Purchase Return Functions/ purchase_return.sql
│   │   ├── Payments Functions/       payments.sql
│   │   ├── Receipts Functions/       receipts.sql
│   │   ├── Parties Functions/        parties.sql
│   │   ├── Items Functions/          items.sql
│   │   ├── Trigger Functions/        triggers.sql
│   │   ├── Accounts Reports/         Accounts_reports.sql
│   │   ├── Stock Reports/            stock_reports.sql
│   │   └── Profit Reports/           profit_reports.sql
│   │
│   ├── Complete Schema Diagram/
│   │   ├── DB Complete Schema.png
│   │   ├── DB Complete Schema.svg
│   │   └── Schema.sql                              # Full combined schema
│   │
│   ├── ER Diagrams/
│   │   ├── Complete_ERD.png                        # Dark theme ERD
│   │   └── CompleteERD_light.png                   # Light theme ERD
│   │
│   ├── Backups/                                    # Timestamped DB backups
│   │   ├── db_backup_20260212_1546.sql             # Latest
│   │   ├── db_backup_20260129_1429.sql
│   │   └── ...
│   │
│   └── DataBase Documentation/
│       ├── Database_Documentation.md
│       ├── Complete ERP Documentation/
│       │   └── COMPLETE_ERP_DATABASE_DOCUMENTATION.md
│       └── ERP Documentation Module Wise/
│           ├── 01_TABLES.md
│           ├── Sale Functions_sales.md
│           ├── Purchase Function_purchase.md
│           └── ...  (one .md per module)
│
├── Deployment Architecture Diagram/
│   └── Deployment Architecture Diagram.png
│
└── System Execution Flow/
    └── System Execution Flow Diagram.png
```

---

## 🌟 System Overview

This ERP system implements a **database-centric architecture** where all critical business logic resides in PostgreSQL stored functions and triggers — not in the application layer. This design ensures:

- ⚡ **Performance** — Complex operations execute within a single database call
- 🔒 **Data Integrity** — Constraints, triggers, and atomic transactions prevent inconsistencies
- 🔁 **Reusability** — Any frontend or backend can call the same stored functions
- 📊 **Auditability** — Every financial transaction creates immutable journal entries

---

## 🏗️ Database Architecture

### Design Philosophy

```
┌──────────────────────────────────────────────────────────────┐
│                    APPLICATION LAYER                         │
│              (Django calls stored functions)                 │
└───────────────────────────┬──────────────────────────────────┘
                            │  cursor.execute("SELECT create_sale_invoice(...)")
                            ▼
┌──────────────────────────────────────────────────────────────┐
│               POSTGRESQL DATABASE ENGINE                     │
│                                                              │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │   TABLES    │  │   STORED     │  │     TRIGGERS       │  │
│  │  (18 core)  │  │  FUNCTIONS   │  │  (Auto accounting) │  │
│  │             │  │   (40+)      │  │                    │  │
│  └─────────────┘  └──────────────┘  └────────────────────┘  │
│                                                              │
│  ┌─────────────┐  ┌──────────────┐                          │
│  │    VIEWS    │  │  CONSTRAINTS │                          │
│  │  (Reports)  │  │  (Integrity) │                          │
│  └─────────────┘  └──────────────┘                          │
└──────────────────────────────────────────────────────────────┘
```

### Accounting Model: Double-Entry Bookkeeping

Every financial transaction automatically generates **journal entries** via triggers:

```
SALE INVOICE CREATED
      │
      ├──► Debit:  Accounts Receivable (Asset ↑)
      └──► Credit: Sales Revenue (Revenue ↑)
           Credit: Inventory (Asset ↓)  ← COGS entry
           Debit:  Cost of Goods Sold (Expense ↑)
```

---

## 🗃️ Core Tables

### Table Summary

| # | Table Name | Category | Description |
|---|-----------|----------|-------------|
| 1 | `ChartOfAccounts` | Master | Hierarchical GL account structure |
| 2 | `Parties` | Master | Customers, vendors, expense categories |
| 3 | `Items` | Master | Inventory items and pricing |
| 4 | `StockMovements` | Inventory | Serial-number-wise stock tracking |
| 5 | `PurchaseInvoice` | Transaction | Purchase invoice headers |
| 6 | `PurchaseInvoiceDetails` | Transaction | Purchase line items |
| 7 | `SaleInvoice` | Transaction | Sale invoice headers |
| 8 | `SaleInvoiceDetails` | Transaction | Sale line items |
| 9 | `PurchaseReturn` | Transaction | Purchase return headers |
| 10 | `PurchaseReturnDetails` | Transaction | Purchase return line items |
| 11 | `SaleReturn` | Transaction | Sale return headers |
| 12 | `SaleReturnDetails` | Transaction | Sale return line items |
| 13 | `Payments` | Finance | Outgoing payments to vendors |
| 14 | `Receipts` | Finance | Incoming receipts from customers |
| 15 | `JournalEntries` | Accounting | Journal entry headers |
| 16 | `JournalLines` | Accounting | Debit/credit lines per journal |
| 17 | `SerialNumbers` | Inventory | Item serial number registry |
| 18 | `AccountBalances` | Accounting | Running balance ledger |

### Key Table: ChartOfAccounts

```sql
ChartOfAccounts
├── account_id    BIGSERIAL PRIMARY KEY
├── account_code  VARCHAR(20) UNIQUE       -- "1000", "2000"
├── account_name  VARCHAR(150)             -- "Cash", "Inventory"
├── account_type  VARCHAR(20)              -- Asset/Liability/Equity/Revenue/Expense
├── parent_account BIGINT → ChartOfAccounts  -- Hierarchical structure
└── date_created  TIMESTAMP
```

**Sample Chart of Accounts:**
```
1000 - Cash                    (Asset)
1100 - Accounts Receivable     (Asset)
1200 - Inventory               (Asset)
2000 - Accounts Payable        (Liability)
3000 - Capital                 (Equity)
4000 - Sales Revenue           (Revenue)
5000 - Cost of Goods Sold      (Expense)
6000 - Expenses                (Expense)
  ├── 6100 - Rent Expense
  └── 6200 - Utilities
```

---

## ⚙️ Stored Functions by Module

### 🛒 Sale Functions (`sales.sql`)
| Function | Description |
|----------|-------------|
| `create_sale_invoice(party, date, items[])` | Creates full sale invoice with line items |
| `get_sale_invoice(sale_id)` | Retrieves invoice with all details |
| `get_sale_summary(from_date, to_date)` | Date-range sales summary |
| `delete_sale_invoice(sale_id)` | Reverses sale with accounting entries |
| `update_sale_invoice(sale_id, ...)` | Modifies invoice details |

### 🏭 Purchase Functions (`purchase.sql`)
| Function | Description |
|----------|-------------|
| `create_purchase_invoice(party, date, items[])` | Records purchase with stock update |
| `get_purchase_invoice(purchase_id)` | Retrieves purchase details |
| `delete_purchase_invoice(purchase_id)` | Reverses purchase entry |

### 🔄 Sale Return Functions (`sale_return.sql`)
| Function | Description |
|----------|-------------|
| `process_sale_return(sale_id, items[])` | Creates return against original sale |
| `reverse_sale_return_accounting(return_id)` | Reverses journal entries for return |

### 🔄 Purchase Return Functions (`purchase_return.sql`)
| Function | Description |
|----------|-------------|
| `process_purchase_return(purchase_id, items[])` | Creates return against original purchase |

### 💵 Payment Functions (`payments.sql`)
| Function | Description |
|----------|-------------|
| `record_payment(party, amount, date, note)` | Records outgoing payment |
| `get_payment_history(party_id)` | Retrieves all payments for a party |
| `get_payments_date_wise(from_date, to_date)` | Date-filtered payment report |

### 🧾 Receipt Functions (`receipts.sql`)
| Function | Description |
|----------|-------------|
| `record_receipt(party, amount, date, note)` | Records incoming receipt |
| `get_receipt_history(party_id)` | Retrieves all receipts for a party |

### 👥 Parties Functions (`parties.sql`)
| Function | Description |
|----------|-------------|
| `create_party(name, type, opening_balance)` | Adds new customer/vendor |
| `update_party(party_id, ...)` | Updates party details |
| `get_party_balance(party_id)` | Current receivable/payable balance |
| `get_all_party_balances()` | All party balances for dashboard |

### 📦 Items Functions (`items.sql`)
| Function | Description |
|----------|-------------|
| `create_item(name, unit, purchase_price, sale_price)` | Adds inventory item |
| `update_item(item_id, ...)` | Updates item details |
| `get_item_stock(item_id)` | Current stock quantity and value |
| `autocomplete_items(query)` | Search items by partial name |

### 📊 Report Functions

**Accounts Reports** (`Accounts_reports.sql`)
- Party ledger with running balance
- Balance sheet extraction
- Trial balance generation

**Stock Reports** (`stock_reports.sql`)
- Current stock levels per item
- Stock valuation (FIFO)
- Movement history

**Profit Reports** (`profit_reports.sql`)
- Gross profit calculation (Revenue − COGS)
- Net profit (Gross Profit − Expenses)
- Date-range P&L statements

---

## ⚡ Trigger Functions (`triggers.sql`)

Triggers automate accounting entries — no manual journal posting required:

| Trigger | Fires On | Action |
|---------|----------|--------|
| `after_sale_invoice_insert` | `INSERT` on SaleInvoice | Creates AR debit, Revenue credit, COGS entry |
| `after_purchase_invoice_insert` | `INSERT` on PurchaseInvoice | Creates Inventory debit, AP credit |
| `after_payment_insert` | `INSERT` on Payments | Creates AP debit, Cash credit |
| `after_receipt_insert` | `INSERT` on Receipts | Creates Cash debit, AR credit |
| `after_sale_return_insert` | `INSERT` on SaleReturn | Reverses sale journal entries |
| `after_purchase_return_insert` | `INSERT` on PurchaseReturn | Reverses purchase journal entries |
| `update_stock_on_sale` | `INSERT` on SaleInvoiceDetails | Decrements stock, records serial numbers |
| `update_stock_on_purchase` | `INSERT` on PurchaseInvoiceDetails | Increments stock with FIFO cost |
| `restore_stock_on_sale_return` | `INSERT` on SaleReturnDetails | Restores stock on return |
| `restore_stock_on_purchase_return` | `INSERT` on PurchaseReturnDetails | Removes stock on purchase return |

---

## 👁️ Database Views

| View | Description |
|------|-------------|
| `v_current_stock` | Live stock levels and FIFO valuation per item |
| `v_party_balances` | Net receivable/payable per party |
| `v_account_balances` | Current balance per GL account |
| `v_profit_summary` | Revenue, COGS, Gross/Net profit |
| `v_stock_movements` | Complete stock movement history |

---

## 📐 ER Diagrams

The complete Entity Relationship Diagram shows all 18 tables and their relationships:

> 📄 `DataBase/ER Diagrams/Complete_ERD.png` — Dark theme  
> 📄 `DataBase/ER Diagrams/CompleteERD_light.png` — Light theme  
> 📄 `DataBase/Complete Schema Diagram/DB Complete Schema.png` — Full schema view

**Key Relationships:**
```
ChartOfAccounts ──────────── JournalLines
                                    │
Parties ─────┬──── SaleInvoice ─────┤
             │         │            │
             │    SaleInvoiceDetails│
             │         │            │
             └──── PurchaseInvoice  │
                        │           │
                   PurchaseInvoice  │
                        Details     │
                                    │
Items ──────────── StockMovements ──┘
         │
    SerialNumbers
```

---

## ☁️ Deployment Architecture

> 📄 `Deployment Architecture Diagram/Deployment Architecture Diagram.png`

```
Internet
    │
    ▼
AWS Security Group (Port 80/443 open)
    │
    ▼
AWS EC2 Instance (Ubuntu)
    │
    ├── Nginx (Port 80/443)
    │   ├── SSL Termination
    │   ├── Static file serving (/static/)
    │   └── Proxy → Gunicorn (Unix Socket)
    │
    ├── Gunicorn
    │   └── Runs Django WSGI application
    │
    ├── Django Application
    │   └── Calls PostgreSQL stored functions
    │
    └── PostgreSQL
        ├── Business logic (stored functions)
        ├── Data integrity (triggers)
        └── Reporting (views)
```

---

## 🔄 Execution Flow

> 📄 `System Execution Flow/System Execution Flow Diagram.png`

### Sale Transaction Flow (Example)

```
User submits Sale Form
        │
        ▼
Django View validates input
(party exists? date valid? items provided?)
        │
        ▼
cursor.execute("SELECT create_sale_invoice(%s, %s, %s)")
        │
        ▼
PostgreSQL: create_sale_invoice()
        ├── INSERT into SaleInvoice  (header)
        ├── INSERT into SaleInvoiceDetails  (line items)
        │
        ▼
Trigger: after_sale_invoice_insert fires
        ├── INSERT JournalEntry (header)
        ├── INSERT JournalLine: DEBIT  Accounts Receivable
        ├── INSERT JournalLine: CREDIT Sales Revenue
        ├── INSERT JournalLine: DEBIT  Cost of Goods Sold
        └── INSERT JournalLine: CREDIT Inventory
        │
        ▼
Trigger: update_stock_on_sale fires
        ├── UPDATE StockMovements (decrement)
        └── UPDATE SerialNumbers (mark as sold)
        │
        ▼
JSON Response → Browser
```

---

## 🚀 Schema Setup

```bash
# 1. Create PostgreSQL database
createdb erp_db

# 2. Run core tables first
psql -d erp_db -f "DataBase/Schema/Tables/tables.sql"

# 3. Run stored functions (order matters)
psql -d erp_db -f "DataBase/Schema/Parties Functions/parties.sql"
psql -d erp_db -f "DataBase/Schema/Items Functions/items.sql"
psql -d erp_db -f "DataBase/Schema/Purchase Function/purchase.sql"
psql -d erp_db -f "DataBase/Schema/Sale Functions/sales.sql"
psql -d erp_db -f "DataBase/Schema/Sale Return Functions/sale_return.sql"
psql -d erp_db -f "DataBase/Schema/Purchase Return Functions/purchase_return.sql"
psql -d erp_db -f "DataBase/Schema/Payments Functions/payments.sql"
psql -d erp_db -f "DataBase/Schema/Receipts Functions/receipts.sql"
psql -d erp_db -f "DataBase/Schema/Trigger Functions/triggers.sql"
psql -d erp_db -f "DataBase/Schema/Accounts Reports/Accounts_reports.sql"
psql -d erp_db -f "DataBase/Schema/Stock Reports/stock_reports.sql"
psql -d erp_db -f "DataBase/Schema/Profit Reports/profit_reports.sql"

# OR — use the complete combined schema
psql -d erp_db -f "DataBase/Complete Schema Diagram/Schema.sql"
```

---

## 💾 Database Backups

Production backups are stored in `DataBase/Backups/` with timestamp naming:

| Backup File | Date |
|------------|------|
| `db_backup_20260212_1546.sql` | Feb 12, 2026 (Latest) |
| `db_backup_20260129_1429.sql` | Jan 29, 2026 |
| `db_backup_20260128_1429.sql` | Jan 28, 2026 |
| `db_backup_20260123_1500.sql` | Jan 23, 2026 |
| `db_backup_20260119_1327.sql` | Jan 19, 2026 |
| `db_backup_20260108_1111.sql` | Jan 08, 2026 |
| `db_backup_20251219_1445.sql` | Dec 19, 2025 |

**Restore from backup:**
```bash
psql -d erp_db -f "DataBase/Backups/db_backup_20260212_1546.sql"
```

---

## 📖 Documentation

Full module-wise documentation is available in `DataBase/DataBase Documentation/`:

- `COMPLETE_ERP_DATABASE_DOCUMENTATION.md` — Single comprehensive document
- `01_TABLES.md` — All table definitions and field descriptions
- `Sale Functions_sales.md` — Sales module function reference
- `Purchase Function_purchase.md` — Purchase module function reference
- `Payments Functions_payments.md` — Payment function reference
- `Receipts Functions_receipts.md` — Receipt function reference
- `Parties Functions_parties.md` — Party management functions
- `Items Functions_items.md` — Item/inventory functions
- `Sale Return Functions_sale_return.md` — Sale return functions
- `Purchase Return Functions_purchase_return.md` — Purchase return functions
- `Trigger Functions_triggers.md` — All trigger documentation
- `Stock Reports_stock_reports.md` — Stock reporting functions
- `Accounts Reports_Accounts_reports.md` — Accounting report functions
- `Profit Reports_profit_reports.md` — Profit report functions
- `Views.md` — All database views documentation

---

## 🔗 Related Repository

> 🌐 **[Accounting Plus Inventory System (Django)](../Accounting-Plus-Inventory-System)** — The Django backend application that consumes this database schema.

---

<div align="center">

**Designed with ❤️ — PostgreSQL at its core**

</div>
