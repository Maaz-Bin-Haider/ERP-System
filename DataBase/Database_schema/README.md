# Financee — PostgreSQL Database Schema Documentation

> **Project:** Financee — Django-based Accounting & Inventory Management System  
> **Database:** PostgreSQL (public schema)  
> **Owner:** postgres  
> **Total Modules:** 12 | **Total Tables:** 25 | **Total Sequences:** 25+

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Folder Structure](#folder-structure)
3. [Module Summary](#module-summary)
4. [Database Architecture Overview](#database-architecture-overview)
5. [Cross-Module Relationships](#cross-module-relationships)
6. [Shared Infrastructure](#shared-infrastructure)
7. [Module Detail Files](#module-detail-files)

---

## Project Overview

**Financee** is a full-featured Django accounting and inventory system backed by a PostgreSQL database. It handles:

- Double-entry bookkeeping via a Chart of Accounts and Journal system
- Inventory tracking at the serial-number level (individual unit tracking)
- Purchase and Sales invoice management with automatic journal posting
- Purchase and Sales returns with stock reversal
- Customer receipts and vendor payments with auto journal triggers
- Party (Customer/Vendor) management with opening balance journaling
- Dashboard KPIs and reporting via PostgreSQL functions and views
- Django authentication and admin integration

The system uses **triggers** to automatically create double-entry journal entries on every financial transaction, ensuring the ledger is always consistent without application-level journaling logic.

---

## Folder Structure

```
Database_schema/
│
├── _master_schema.sql                  ← Full combined schema (all tables)
│
├── _shared/
│   └── sequences.sql                  ← All auto-increment sequences (25 sequences)
│
├── accounting_core/                   ← Core double-entry bookkeeping tables
│   └── tables/
│       ├── chartofaccounts.sql        ← Chart of Accounts (hierarchical, 5 types)
│       ├── journalentries.sql         ← Journal Entry headers
│       └── journallines.sql           ← Journal Line items (debit/credit rows)
│
├── authentication/                    ← Django auth system (users, groups, permissions)
│   ├── indexes/                       ← 13 index definitions for auth tables
│   └── tables/                        ← 10 Django auth/session/admin tables
│
├── home/                              ← Dashboard KPI functions and views
│   ├── functions/                     ← 15 dashboard functions (fn_dash_*)
│   └── views/                         ← 4 dashboard views (vw_dash_*)
│
├── items/                             ← Inventory item master and stock movements
│   ├── functions/                     ← 6 CRUD and lookup functions
│   └── tables/                        ← items, stockmovements
│
├── parties/                           ← Customers, vendors, expense parties
│   ├── functions/                     ← 7 CRUD and query functions
│   ├── tables/                        ← parties table
│   ├── triggers/                      ← trg_party_insert
│   └── trigger_functions/             ← trg_party_opening_balance
│
├── payments/                          ← Vendor payments with auto-journaling
│   ├── functions/                     ← 9 CRUD/navigation functions
│   ├── tables/                        ← payments table
│   ├── triggers/                      ← INSERT / UPDATE / DELETE triggers
│   └── trigger_functions/             ← trg_payment_journal
│
├── receipts/                          ← Customer receipts with auto-journaling
│   ├── functions/                     ← 9 CRUD/navigation functions
│   ├── tables/                        ← receipts table
│   ├── triggers/                      ← INSERT / UPDATE / DELETE triggers
│   └── trigger_functions/             ← trg_receipt_journal
│
├── purchase/                          ← Vendor purchase invoices and items
│   ├── functions/                     ← 14 CRUD/validation/navigation functions
│   └── tables/                        ← purchaseinvoices, purchaseitems, purchaseunits
│
├── purchaseReturn/                    ← Purchase return (debit notes) management
│   ├── functions/                     ← 12 CRUD/navigation/validation functions
│   └── tables/                        ← purchasereturns, purchasereturnitems
│
├── sale/                              ← Customer sales invoices and items
│   ├── functions/                     ← 12 CRUD/validation/navigation functions
│   └── tables/                        ← salesinvoices, salesitems, soldunits
│
├── saleReturn/                        ← Sales return (credit notes) management
│   ├── functions/                     ← 12 CRUD/navigation/rebuild functions
│   └── tables/                        ← salesreturns, salesreturnitems
│
├── stockReports/                      ← Inventory reporting functions and views
│   ├── functions/                     ← 7 stock reporting functions
│   └── views/                         ← 4 stock report views
│
└── accountsReports/                   ← Financial reporting functions and views
    ├── functions/                     ← 8 financial report functions
    └── views/                         ← 2 financial report views
```

---

## Module Summary

| Module | Type | Tables | Functions | Views | Triggers | Purpose |
|--------|------|--------|-----------|-------|----------|---------|
| `accounting_core` | Core | 3 | — | — | — | Double-entry ledger backbone |
| `authentication` | System | 10 | — | — | — | Django users, groups, permissions |
| `items` | Operational | 2 | 6 | — | — | Product/inventory master data |
| `parties` | Operational | 1 | 7 | — | 1 | Customers, vendors, expense parties |
| `payments` | Transactional | 1 | 9 | — | 3 | Vendor payments + auto journal |
| `receipts` | Transactional | 1 | 9 | — | 3 | Customer receipts + auto journal |
| `purchase` | Transactional | 3 | 14 | — | — | Purchase invoices (serial-tracked) |
| `purchaseReturn` | Transactional | 2 | 12 | — | — | Purchase returns / debit notes |
| `sale` | Transactional | 3 | 12 | — | — | Sales invoices (serial-tracked) |
| `saleReturn` | Transactional | 2 | 12 | — | — | Sales returns / credit notes |
| `home` | Reporting | — | 15 | 4 | — | Dashboard KPIs and smart alerts |
| `stockReports` | Reporting | — | 7 | 4 | — | Inventory and serial ledger reports |
| `accountsReports` | Reporting | — | 8 | 2 | — | Financial statements and ledgers |
| `_shared` | Infrastructure | — | — | — | — | Sequences for all PKs |

---

## Database Architecture Overview

### Double-Entry Accounting Engine

Every financial transaction in the system (purchase, sale, payment, receipt, return) automatically creates a balanced journal entry via **PostgreSQL triggers**. No application code is responsible for bookkeeping — the database guarantees double-entry integrity.

```
Transaction Recorded
        ↓
   Trigger Fires
        ↓
  JournalEntries row created (header)
        ↓
  JournalLines rows inserted (debit + credit)
        ↓
  journallines.journal_id linked back to transaction
```

### Serial Number Tracking

Every purchased unit is tracked individually via `purchaseunits` (assigned a unique `serial_number`). When sold, a `soldunits` row links the sold item back to its specific purchase unit. This enables:
- Per-unit profit calculation (`sale_wise_profit`)
- Full serial ledger history (`get_serial_ledger`)
- Accurate COGS based on actual purchase price

### Party System

The `parties` table is a unified master for all external entities:

| `party_type` | Description | AR Account | AP Account |
|---|---|---|---|
| `Customer` | Buyers | ✅ Required | — |
| `Vendor` | Suppliers | — | ✅ Required |
| `Both` | Acts as both | ✅ | ✅ |
| `Expense` | Recurring expenses (rent, etc.) | — | ✅ (Expense A/C) |

---

## Cross-Module Relationships

```
auth_user ──────────────────────────── created_by on all tables
     │
chartofaccounts ◄──────┬──────────────── journallines.account_id
     │                 │                 parties.ar_account_id
     │                 │                 parties.ap_account_id
     │                 │                 payments.account_id
     │                 │                 receipts.account_id
     │
journalentries ◄───────┴──────────────── journallines.journal_id
     │                                   purchaseinvoices.journal_id
     │                                   purchasereturns.journal_id
     │                                   salesinvoices.journal_id
     │                                   salesreturns.journal_id
     │                                   payments.journal_id
     │                                   receipts.journal_id
     │
parties ──────────────────────────────── journallines.party_id
     │                                   purchaseinvoices.vendor_id
     │                                   purchasereturns.vendor_id
     │                                   salesinvoices.customer_id
     │                                   salesreturns.customer_id
     │                                   payments.party_id
     │                                   receipts.party_id
     │
items ─────────────────────────────────► purchaseitems.item_id
     │                                   salesitems.item_id
     │                                   purchasereturnitems.item_id
     │                                   salesreturnitems.item_id
     │                                   stockmovements.item_id
     │
purchaseunits ─────────────────────────► soldunits.unit_id
                                         purchasereturnitems.serial_number
                                         salesreturnitems.serial_number
```

---

## Shared Infrastructure

### `_shared/sequences.sql`

Defines **25 auto-increment sequences** covering all primary key columns across every table. Uses two styles:

- **PostgreSQL identity columns** (Django-managed tables like `auth_*`, `django_*`): `GENERATED BY DEFAULT AS IDENTITY`
- **Classic CREATE SEQUENCE** (custom tables): separate `CREATE SEQUENCE` + `ALTER TABLE ... SET DEFAULT nextval(...)`

Sequences defined for: `chartofaccounts`, `journalentries`, `journallines`, `items`, `stockmovements`, `parties`, `payments`, `receipts`, `purchaseinvoices`, `purchaseitems`, `purchaseunits`, `purchasereturns`, `purchasereturnitems`, `salesinvoices`, `salesitems`, `soldunits`, `salesreturns`, `salesreturnitems`, plus all Django auth tables.

**Special sequences:**
- `payments_ref_seq` — used to auto-generate payment reference numbers
- `receipts_ref_seq` — used to auto-generate receipt reference numbers

---

## Module Detail Files

Each module has its own detailed documentation file:

| File | Module |
|------|--------|
| [accounting_core.md](./accounting_core.md) | Chart of Accounts & Journal Engine |
| [authentication.md](./authentication.md) | Django Auth, Groups, Permissions |
| [items.md](./items.md) | Inventory Item Master & Stock Movements |
| [parties.md](./parties.md) | Customers, Vendors, Expense Parties |
| [payments.md](./payments.md) | Vendor Payments |
| [receipts.md](./receipts.md) | Customer Receipts |
| [purchase.md](./purchase.md) | Purchase Invoices (Serial-Tracked) |
| [purchaseReturn.md](./purchaseReturn.md) | Purchase Returns / Debit Notes |
| [sale.md](./sale.md) | Sales Invoices (Serial-Tracked) |
| [saleReturn.md](./saleReturn.md) | Sales Returns / Credit Notes |
| [home.md](./home.md) | Dashboard KPIs & Smart Alerts |
| [stockReports.md](./stockReports.md) | Stock & Serial Ledger Reports |
| [accountsReports.md](./accountsReports.md) | Financial Statements & Ledgers |
