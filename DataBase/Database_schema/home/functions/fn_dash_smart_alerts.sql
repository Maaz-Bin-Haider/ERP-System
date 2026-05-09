--
-- ============================================================
-- FUNCTION: fn_dash_smart_alerts()
-- ============================================================
--

CREATE FUNCTION public.fn_dash_smart_alerts() RETURNS json
    LANGUAGE plpgsql STABLE
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


ALTER FUNCTION public.fn_dash_smart_alerts() OWNER TO postgres;
