-- =============================================================================
-- DASHBOARD UPGRADE: PostgreSQL Functions & Views
-- System: Django Accounting + Inventory Management
-- Compatible Schema: financee project
-- Corrected: all syntax errors fixed
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. DAILY SALES & PROFIT
-- =============================================================================

-- View: Daily sales summary (simple flat aggregation, no nested subquery in SUM)
CREATE OR REPLACE VIEW public.vw_dash_daily_sales AS
SELECT
    si.invoice_date                        AS sale_date,
    COUNT(DISTINCT si.sales_invoice_id)    AS invoice_count,
    COALESCE(SUM(si.total_amount), 0)      AS total_revenue
FROM salesinvoices si
GROUP BY si.invoice_date;


-- Function: Today's KPIs — revenue, invoice count, gross profit
CREATE OR REPLACE FUNCTION public.fn_dash_sales_today_kpi()
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'sales_today',   COALESCE(SUM(si.total_amount), 0),
        'invoice_count', COUNT(DISTINCT si.sales_invoice_id),
        'profit_today',  COALESCE(SUM(su.sold_price - pi2.unit_price), 0)
    )
    INTO v_result
    FROM salesinvoices si
    LEFT JOIN salesitems    sitem  ON sitem.sales_invoice_id  = si.sales_invoice_id
    LEFT JOIN soldunits     su     ON su.sales_item_id        = sitem.sales_item_id
    LEFT JOIN purchaseunits punit  ON punit.unit_id           = su.unit_id
    LEFT JOIN purchaseitems pi2    ON pi2.purchase_item_id    = punit.purchase_item_id
    WHERE si.invoice_date = CURRENT_DATE;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;


-- Function: Last 7 days chart data (fills date gaps with zeros)
CREATE OR REPLACE FUNCTION public.fn_dash_sales_last7days()
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'date',    TO_CHAR(d.day, 'YYYY-MM-DD'),
            'label',   TO_CHAR(d.day, 'Mon DD'),
            'revenue', COALESCE(s.revenue, 0),
            'profit',  COALESCE(s.profit,  0)
        )
        ORDER BY d.day
    )
    INTO v_result
    FROM (
        SELECT gs::date AS day
        FROM generate_series(
            CURRENT_DATE - INTERVAL '6 days',
            CURRENT_DATE,
            '1 day'::interval
        ) gs
    ) d
    LEFT JOIN (
        SELECT
            si.invoice_date                                   AS sale_date,
            SUM(si.total_amount)                              AS revenue,
            COALESCE(SUM(su.sold_price - pi2.unit_price), 0) AS profit
        FROM salesinvoices si
        LEFT JOIN salesitems    sitem  ON sitem.sales_invoice_id  = si.sales_invoice_id
        LEFT JOIN soldunits     su     ON su.sales_item_id        = sitem.sales_item_id
        LEFT JOIN purchaseunits punit  ON punit.unit_id           = su.unit_id
        LEFT JOIN purchaseitems pi2    ON pi2.purchase_item_id    = punit.purchase_item_id
        WHERE si.invoice_date >= CURRENT_DATE - INTERVAL '6 days'
        GROUP BY si.invoice_date
    ) s ON s.sale_date = d.day;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- Function: Sales chart for any custom date range
CREATE OR REPLACE FUNCTION public.fn_dash_sales_range(p_from DATE, p_to DATE)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'date',    TO_CHAR(agg.invoice_date, 'YYYY-MM-DD'),
            'label',   TO_CHAR(agg.invoice_date, 'Mon DD'),
            'revenue', agg.revenue,
            'profit',  agg.profit
        )
        ORDER BY agg.invoice_date
    )
    INTO v_result
    FROM (
        SELECT
            si.invoice_date,
            SUM(si.total_amount)                              AS revenue,
            COALESCE(SUM(su.sold_price - pi2.unit_price), 0) AS profit
        FROM salesinvoices si
        LEFT JOIN salesitems    sitem  ON sitem.sales_invoice_id  = si.sales_invoice_id
        LEFT JOIN soldunits     su     ON su.sales_item_id        = sitem.sales_item_id
        LEFT JOIN purchaseunits punit  ON punit.unit_id           = su.unit_id
        LEFT JOIN purchaseitems pi2    ON pi2.purchase_item_id    = punit.purchase_item_id
        WHERE si.invoice_date BETWEEN p_from AND p_to
        GROUP BY si.invoice_date
    ) agg;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- =============================================================================
-- 2. STOCK OVERVIEW
-- =============================================================================

-- View: in-stock units per item with last sold/purchased dates
CREATE OR REPLACE VIEW public.vw_dash_stock_overview AS
SELECT
    i.item_id,
    i.item_name,
    i.category,
    i.brand,
    i.sale_price,
    COUNT(pu.unit_id)    FILTER (WHERE pu.in_stock = TRUE)             AS units_in_stock,
    COALESCE(AVG(pi2.unit_price) FILTER (WHERE pu.in_stock = TRUE), 0) AS avg_cost_price,
    MAX(pinv.invoice_date) FILTER (WHERE pu.in_stock = TRUE)           AS last_purchased,
    (
        SELECT MAX(sinv.invoice_date)
        FROM salesitems    sitem
        JOIN soldunits     su2   ON su2.sales_item_id     = sitem.sales_item_id
        JOIN salesinvoices sinv  ON sinv.sales_invoice_id = sitem.sales_invoice_id
        WHERE sitem.item_id = i.item_id
    ) AS last_sold_date
FROM items i
LEFT JOIN purchaseitems    pi2   ON pi2.item_id              = i.item_id
LEFT JOIN purchaseunits    pu    ON pu.purchase_item_id      = pi2.purchase_item_id
LEFT JOIN purchaseinvoices pinv  ON pinv.purchase_invoice_id = pi2.purchase_invoice_id
GROUP BY i.item_id, i.item_name, i.category, i.brand, i.sale_price;


-- Function: Stock summary KPIs
CREATE OR REPLACE FUNCTION public.fn_dash_stock_kpi()
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'total_units',     COALESCE(SUM(units_in_stock), 0),
        'low_stock_count', COUNT(*) FILTER (WHERE units_in_stock > 0 AND units_in_stock < 5),
        'out_of_stock',    COUNT(*) FILTER (WHERE units_in_stock = 0),
        'total_items',     COUNT(*)
    )
    INTO v_result
    FROM vw_dash_stock_overview;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;


-- Function: Items below configurable threshold
CREATE OR REPLACE FUNCTION public.fn_dash_low_stock_items(p_threshold INT DEFAULT 5)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'item_id',        item_id,
            'item_name',      item_name,
            'category',       COALESCE(category, 'N/A'),
            'units_in_stock', units_in_stock,
            'sale_price',     sale_price
        )
        ORDER BY units_in_stock ASC
    )
    INTO v_result
    FROM vw_dash_stock_overview
    WHERE units_in_stock < p_threshold;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- Function: Fast-moving items by units sold in last N days
CREATE OR REPLACE FUNCTION public.fn_dash_fast_moving_items(
    p_days  INT DEFAULT 30,
    p_limit INT DEFAULT 10
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'item_id',    item_id,
            'item_name',  item_name,
            'category',   category,
            'units_sold', units_sold,
            'revenue',    revenue
        )
        ORDER BY units_sold DESC
    )
    INTO v_result
    FROM (
        SELECT
            i.item_id,
            i.item_name,
            COALESCE(i.category, 'N/A')        AS category,
            COUNT(su.sold_unit_id)              AS units_sold,
            COALESCE(SUM(su.sold_price), 0)    AS revenue
        FROM items i
        JOIN salesitems    sitem  ON sitem.item_id       = i.item_id
        JOIN soldunits     su     ON su.sales_item_id    = sitem.sales_item_id
        JOIN salesinvoices si     ON si.sales_invoice_id = sitem.sales_invoice_id
        WHERE si.invoice_date >= CURRENT_DATE - (p_days || ' days')::INTERVAL
        GROUP BY i.item_id, i.item_name, i.category
        ORDER BY COUNT(su.sold_unit_id) DESC
        LIMIT p_limit
    ) ranked;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- Function: Items in stock but not sold in X+ days
CREATE OR REPLACE FUNCTION public.fn_dash_stale_stock(p_days INT DEFAULT 30)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'item_id',        item_id,
            'item_name',      item_name,
            'category',       COALESCE(category, 'N/A'),
            'units_in_stock', units_in_stock,
            'last_sold_date', TO_CHAR(last_sold_date, 'YYYY-MM-DD'),
            'days_stale',     CASE
                                  WHEN last_sold_date IS NULL THEN NULL
                                  ELSE (CURRENT_DATE - last_sold_date)
                              END
        )
        ORDER BY last_sold_date ASC NULLS FIRST
    )
    INTO v_result
    FROM vw_dash_stock_overview
    WHERE
        units_in_stock > 0
        AND (
            last_sold_date IS NULL
            OR last_sold_date < CURRENT_DATE - (p_days || ' days')::INTERVAL
        );

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- =============================================================================
-- 3. TOP CUSTOMERS & VENDORS
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_dash_top_customers(
    p_limit INT  DEFAULT 5,
    p_from  DATE DEFAULT NULL,
    p_to    DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
    v_from   DATE := COALESCE(p_from, '2000-01-01'::date);
    v_to     DATE := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    SELECT json_agg(
        json_build_object(
            'party_id',        party_id,
            'party_name',      party_name,
            'contact',         contact,
            'invoice_count',   invoice_count,
            'total_purchases', total_purchases,
            'last_purchase',   last_purchase
        )
        ORDER BY total_purchases DESC
    )
    INTO v_result
    FROM (
        SELECT
            p.party_id,
            p.party_name,
            COALESCE(p.contact_info, 'N/A')              AS contact,
            COUNT(DISTINCT si.sales_invoice_id)           AS invoice_count,
            COALESCE(SUM(si.total_amount), 0)             AS total_purchases,
            TO_CHAR(MAX(si.invoice_date), 'YYYY-MM-DD')  AS last_purchase
        FROM parties p
        JOIN salesinvoices si ON si.customer_id = p.party_id
        WHERE si.invoice_date BETWEEN v_from AND v_to
        GROUP BY p.party_id, p.party_name, p.contact_info
        ORDER BY SUM(si.total_amount) DESC
        LIMIT p_limit
    ) subq;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


CREATE OR REPLACE FUNCTION public.fn_dash_top_vendors(
    p_limit INT  DEFAULT 5,
    p_from  DATE DEFAULT NULL,
    p_to    DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
    v_from   DATE := COALESCE(p_from, '2000-01-01'::date);
    v_to     DATE := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    SELECT json_agg(
        json_build_object(
            'party_id',       party_id,
            'party_name',     party_name,
            'contact',        contact,
            'invoice_count',  invoice_count,
            'total_purchased',total_purchased,
            'last_purchase',  last_purchase
        )
        ORDER BY total_purchased DESC
    )
    INTO v_result
    FROM (
        SELECT
            p.party_id,
            p.party_name,
            COALESCE(p.contact_info, 'N/A')              AS contact,
            COUNT(DISTINCT pi.purchase_invoice_id)        AS invoice_count,
            COALESCE(SUM(pi.total_amount), 0)             AS total_purchased,
            TO_CHAR(MAX(pi.invoice_date), 'YYYY-MM-DD')  AS last_purchase
        FROM parties p
        JOIN purchaseinvoices pi ON pi.vendor_id = p.party_id
        WHERE pi.invoice_date BETWEEN v_from AND v_to
        GROUP BY p.party_id, p.party_name, p.contact_info
        ORDER BY SUM(pi.total_amount) DESC
        LIMIT p_limit
    ) subq;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- =============================================================================
-- 4. RECEIVABLES AGING
-- =============================================================================

-- View: Net AR balance per party
CREATE OR REPLACE VIEW public.vw_dash_party_ar_balance AS
SELECT
    p.party_id,
    p.party_name,
    p.party_type,
    p.contact_info,
    COALESCE(SUM(jl.debit) - SUM(jl.credit), 0) AS ar_balance,
    MAX(je.entry_date)                            AS last_transaction_date
FROM parties p
JOIN journallines   jl ON jl.party_id   = p.party_id
JOIN journalentries je ON je.journal_id = jl.journal_id
WHERE p.ar_account_id IS NOT NULL
GROUP BY p.party_id, p.party_name, p.party_type, p.contact_info
HAVING COALESCE(SUM(jl.debit) - SUM(jl.credit), 0) > 0;


-- Function: Receivables aged into three buckets
-- Uses separate scalar subqueries per bucket to avoid FILTER-on-json_agg issues
CREATE OR REPLACE FUNCTION public.fn_dash_receivables_aging()
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'overdue', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'party_id',    party_id,
                    'party_name',  party_name,
                    'balance',     ar_balance,
                    'last_txn',    TO_CHAR(last_transaction_date, 'YYYY-MM-DD'),
                    'days_overdue',(CURRENT_DATE - last_transaction_date)
                )
                ORDER BY ar_balance DESC
            ), '[]'::json)
            FROM vw_dash_party_ar_balance
            WHERE (CURRENT_DATE - last_transaction_date) > 60
        ),
        'medium_risk', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'party_id',    party_id,
                    'party_name',  party_name,
                    'balance',     ar_balance,
                    'last_txn',    TO_CHAR(last_transaction_date, 'YYYY-MM-DD'),
                    'days_overdue',(CURRENT_DATE - last_transaction_date)
                )
                ORDER BY ar_balance DESC
            ), '[]'::json)
            FROM vw_dash_party_ar_balance
            WHERE (CURRENT_DATE - last_transaction_date) BETWEEN 30 AND 60
        ),
        'fresh', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'party_id',    party_id,
                    'party_name',  party_name,
                    'balance',     ar_balance,
                    'last_txn',    TO_CHAR(last_transaction_date, 'YYYY-MM-DD'),
                    'days_overdue',(CURRENT_DATE - last_transaction_date)
                )
                ORDER BY ar_balance DESC
            ), '[]'::json)
            FROM vw_dash_party_ar_balance
            WHERE (CURRENT_DATE - last_transaction_date) < 30
        ),
        'total_overdue_amount', (
            SELECT COALESCE(SUM(ar_balance), 0)
            FROM vw_dash_party_ar_balance
            WHERE (CURRENT_DATE - last_transaction_date) > 60
        ),
        'total_medium_amount', (
            SELECT COALESCE(SUM(ar_balance), 0)
            FROM vw_dash_party_ar_balance
            WHERE (CURRENT_DATE - last_transaction_date) BETWEEN 30 AND 60
        ),
        'total_fresh_amount', (
            SELECT COALESCE(SUM(ar_balance), 0)
            FROM vw_dash_party_ar_balance
            WHERE (CURRENT_DATE - last_transaction_date) < 30
        )
    )
    INTO v_result;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;


-- =============================================================================
-- 5. RECENT TRANSACTIONS FEED
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_dash_recent_transactions(p_limit INT DEFAULT 10)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    -- The UNION ALL subquery is wrapped so ORDER BY + LIMIT apply to the whole set
    SELECT json_agg(
        json_build_object(
            'type',       row_data.txn_type,
            'icon',       row_data.txn_icon,
            'ref_id',     row_data.ref_id,
            'party_name', row_data.party_name,
            'amount',     row_data.amount,
            'txn_date',   row_data.txn_date
        )
        ORDER BY row_data.txn_date DESC, row_data.ref_id DESC
    )
    INTO v_result
    FROM (
        SELECT
            'Sale'                                    AS txn_type,
            'sale'                                    AS txn_icon,
            si.sales_invoice_id                       AS ref_id,
            p.party_name                              AS party_name,
            si.total_amount                           AS amount,
            TO_CHAR(si.invoice_date, 'YYYY-MM-DD')   AS txn_date
        FROM salesinvoices si
        JOIN parties p ON p.party_id = si.customer_id

        UNION ALL

        SELECT
            'Purchase',
            'purchase',
            pi.purchase_invoice_id,
            p.party_name,
            pi.total_amount,
            TO_CHAR(pi.invoice_date, 'YYYY-MM-DD')
        FROM purchaseinvoices pi
        JOIN parties p ON p.party_id = pi.vendor_id

        UNION ALL

        SELECT
            'Receipt',
            'receipt',
            r.receipt_id,
            p.party_name,
            r.amount,
            TO_CHAR(r.receipt_date, 'YYYY-MM-DD')
        FROM receipts r
        JOIN parties p ON p.party_id = r.party_id

        UNION ALL

        SELECT
            'Payment',
            'payment',
            pay.payment_id,
            p.party_name,
            pay.amount,
            TO_CHAR(pay.payment_date, 'YYYY-MM-DD')
        FROM payments pay
        JOIN parties p ON p.party_id = pay.party_id

        ORDER BY txn_date DESC, ref_id DESC
        LIMIT p_limit
    ) row_data;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- =============================================================================
-- 6. EXPENSE TRACKING
-- =============================================================================

-- View: Expense journal lines (account_type contains 'Expense', debit side only)
CREATE OR REPLACE VIEW public.vw_dash_expenses AS
SELECT
    je.entry_date,
    je.description                    AS expense_note,
    coa.account_name                  AS expense_category,
    coa.account_id,
    COALESCE(jl.debit, 0)             AS amount,
    p.party_name
FROM journalentries  je
JOIN journallines    jl  ON jl.journal_id  = je.journal_id
JOIN chartofaccounts coa ON coa.account_id = jl.account_id
LEFT JOIN parties    p   ON p.party_id     = jl.party_id
WHERE coa.account_type ILIKE '%expense%'
  AND jl.debit > 0;


-- Function: Expense KPIs — today / this month / this year
CREATE OR REPLACE FUNCTION public.fn_dash_expense_kpi()
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'today',      COALESCE(SUM(amount) FILTER (
                          WHERE entry_date = CURRENT_DATE
                      ), 0),
        'this_month', COALESCE(SUM(amount) FILTER (
                          WHERE DATE_TRUNC('month', entry_date) = DATE_TRUNC('month', CURRENT_DATE)
                      ), 0),
        'this_year',  COALESCE(SUM(amount) FILTER (
                          WHERE DATE_PART('year', entry_date) = DATE_PART('year', CURRENT_DATE)
                      ), 0)
    )
    INTO v_result
    FROM vw_dash_expenses;

    RETURN COALESCE(v_result, '{}'::json);
END;
$$;


-- Function: Top expense account categories in a date range
CREATE OR REPLACE FUNCTION public.fn_dash_top_expense_categories(
    p_limit INT  DEFAULT 5,
    p_from  DATE DEFAULT NULL,
    p_to    DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
    v_from   DATE := COALESCE(p_from, DATE_TRUNC('month', CURRENT_DATE)::DATE);
    v_to     DATE := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    SELECT json_agg(
        json_build_object(
            'category', expense_category,
            'total',    cat_total,
            'count',    cat_count
        )
        ORDER BY cat_total DESC
    )
    INTO v_result
    FROM (
        SELECT
            expense_category,
            COALESCE(SUM(amount), 0) AS cat_total,
            COUNT(*)                  AS cat_count
        FROM vw_dash_expenses
        WHERE entry_date BETWEEN v_from AND v_to
        GROUP BY expense_category
        ORDER BY SUM(amount) DESC
        LIMIT p_limit
    ) cats;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- Function: Top expenses grouped by description / comment text
CREATE OR REPLACE FUNCTION public.fn_dash_top_expense_descriptions(
    p_limit INT  DEFAULT 5,
    p_from  DATE DEFAULT NULL,
    p_to    DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result JSON;
    v_from   DATE := COALESCE(p_from, DATE_TRUNC('month', CURRENT_DATE)::DATE);
    v_to     DATE := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    SELECT json_agg(
        json_build_object(
            'description', description,
            'category',    expense_category,
            'total',       desc_total,
            'count',       desc_count
        )
        ORDER BY desc_total DESC
    )
    INTO v_result
    FROM (
        SELECT
            COALESCE(NULLIF(TRIM(expense_note), ''), 'No Description') AS description,
            expense_category,
            COALESCE(SUM(amount), 0) AS desc_total,
            COUNT(*)                  AS desc_count
        FROM vw_dash_expenses
        WHERE entry_date BETWEEN v_from AND v_to
          AND expense_note IS NOT NULL
          AND TRIM(expense_note) <> ''
        GROUP BY expense_note, expense_category
        ORDER BY SUM(amount) DESC
        LIMIT p_limit
    ) descs;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;


-- =============================================================================
-- 7. SMART ALERTS
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_dash_smart_alerts()
RETURNS JSON
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    -- rec must be declared explicitly for FOR loops in plpgsql
    rec           RECORD;
    v_alerts      JSON[]  := ARRAY[]::JSON[];
    v_cash        NUMERIC;
    v_sales_today NUMERIC;
    v_result      JSON;
BEGIN

    -- ── Alert 1: Negative Cash ──────────────────────────────────────────
    SELECT COALESCE(balance, 0)
    INTO   v_cash
    FROM   vw_trial_balance
    WHERE  name ILIKE '%cash%'
    LIMIT  1;

    IF v_cash IS NOT NULL AND v_cash < 0 THEN
        v_alerts := v_alerts || ARRAY[json_build_object(
            'type',    'danger',
            'icon',    'fa-triangle-exclamation',
            'title',   'Negative Cash Balance',
            'message', 'Cash balance is PKR ' || v_cash::TEXT || '. Immediate action required.'
        )];
    END IF;

    -- ── Alert 2: No Sales Today ─────────────────────────────────────────
    SELECT COALESCE(SUM(total_amount), 0)
    INTO   v_sales_today
    FROM   salesinvoices
    WHERE  invoice_date = CURRENT_DATE;

    IF v_sales_today = 0 THEN
        v_alerts := v_alerts || ARRAY[json_build_object(
            'type',    'warning',
            'icon',    'fa-store-slash',
            'title',   'No Sales Today',
            'message', 'No sales invoices have been recorded for today yet.'
        )];
    END IF;

    -- ── Alert 3: Stale Receivables (30+ days no activity, outstanding AR) ─
    FOR rec IN
        SELECT party_name, ar_balance, last_transaction_date
        FROM   vw_dash_party_ar_balance
        WHERE  (CURRENT_DATE - last_transaction_date) >= 30
        ORDER  BY ar_balance DESC
        LIMIT  5
    LOOP
        v_alerts := v_alerts || ARRAY[json_build_object(
            'type',    'warning',
            'icon',    'fa-clock-rotate-left',
            'title',   'Stale Receivable: ' || rec.party_name,
            'message', 'Balance PKR ' || rec.ar_balance::TEXT
                       || ' — last activity '
                       || (CURRENT_DATE - rec.last_transaction_date)::TEXT
                       || ' days ago.'
        )];
    END LOOP;

    -- ── Alert 4: Risky Customers (high AR + no receipt in 45 days) ──────
    FOR rec IN
        SELECT v.party_name, v.ar_balance, v.last_transaction_date
        FROM   vw_dash_party_ar_balance v
        WHERE  v.ar_balance > 50000
          AND  NOT EXISTS (
                   SELECT 1
                   FROM   receipts r
                   WHERE  r.party_id     = v.party_id
                     AND  r.receipt_date >= CURRENT_DATE - INTERVAL '45 days'
               )
        ORDER  BY v.ar_balance DESC
        LIMIT  3
    LOOP
        v_alerts := v_alerts || ARRAY[json_build_object(
            'type',    'danger',
            'icon',    'fa-user-slash',
            'title',   'Risky Customer: ' || rec.party_name,
            'message', 'High receivable PKR ' || rec.ar_balance::TEXT
                       || ' with no payment received in the last 45 days.'
        )];
    END LOOP;

    -- ── Flatten array to JSON ────────────────────────────────────────────
    SELECT json_agg(a) INTO v_result FROM UNNEST(v_alerts) a;
    RETURN COALESCE(v_result, '[]'::json);
END;
$$;

COMMIT;
