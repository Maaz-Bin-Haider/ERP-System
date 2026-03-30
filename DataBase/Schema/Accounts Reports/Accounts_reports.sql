--===============================================================================================
--                                       Accounts Reports START
--===============================================================================================
--
-- Name: detailed_ledger(text, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.detailed_ledger(p_party_name text, p_start_date date, p_end_date date) RETURNS TABLE(entry_date date, journal_id bigint, description text, party_name text, account_type text, debit numeric, credit numeric, running_balance numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH party_ledger AS (
        SELECT 
            je.entry_date AS entry_date,
            je.journal_id AS journal_id,
            je.description::TEXT AS description,
            p.party_name::TEXT AS party_name,                
            a.account_name::TEXT AS account_name,               
            jl.debit AS debit,
            jl.credit AS credit,
            (jl.debit - jl.credit) AS amount
        FROM JournalLines jl
        JOIN JournalEntries je ON jl.journal_id = je.journal_id
        JOIN ChartOfAccounts a ON jl.account_id = a.account_id
        LEFT JOIN Parties p ON jl.party_id = p.party_id   
        WHERE 
            p.party_name = p_party_name
            AND je.entry_date BETWEEN p_start_date AND p_end_date
    )
    SELECT 
        pl.entry_date,
        pl.journal_id,
        pl.description,
        pl.party_name,
        pl.account_name AS account_type,
        pl.debit,
        pl.credit,
        SUM(pl.amount) OVER (ORDER BY pl.entry_date, pl.journal_id ROWS UNBOUNDED PRECEDING) AS running_balance
    FROM party_ledger pl
    ORDER BY pl.entry_date, pl.journal_id;
END;
$$;

--====================================================================================
-- Full ledger for any party (purchases, sales, payments, receipts)
-- CREATE OR REPLACE FUNCTION public.detailed_ledger2(
--     p_party_name TEXT,
--     p_start_date DATE,
--     p_end_date   DATE
-- )
-- RETURNS TABLE(
--     entry_date      DATE,
--     journal_id      BIGINT,
--     description     TEXT,
--     party_name      TEXT,
--     account_type    TEXT,
--     debit           NUMERIC,
--     credit          NUMERIC,
--     running_balance NUMERIC,
--     invoice_details JSONB
-- )
-- LANGUAGE plpgsql AS $$
-- BEGIN
--     RETURN QUERY
--     WITH party_ledger AS (
--         SELECT
--             je.entry_date                   AS entry_date,
--             je.journal_id                   AS journal_id,
--             je.description::TEXT            AS description,
--             p.party_name::TEXT              AS party_name,
--             a.account_name::TEXT            AS account_name,
--             jl.debit                        AS debit,
--             jl.credit                       AS credit,
--             (jl.debit - jl.credit)          AS amount
--         FROM journallines jl
--         JOIN journalentries je  ON jl.journal_id   = je.journal_id
--         JOIN chartofaccounts a  ON jl.account_id   = a.account_id
--         LEFT JOIN parties p     ON jl.party_id     = p.party_id
--         WHERE p.party_name = p_party_name
--           AND je.entry_date BETWEEN p_start_date AND p_end_date
--     ),

--     -- -------------------------------------------------------
--     -- Resolve which document each journal_id belongs to
--     -- -------------------------------------------------------
--     journal_source AS (
--         -- Purchase Invoice
--         SELECT
--             pi.journal_id,
--             'purchase'::TEXT        AS source_type,
--             pi.purchase_invoice_id  AS source_id
--         FROM purchaseinvoices pi
--         WHERE pi.journal_id IS NOT NULL

--         UNION ALL

--         -- Purchase Return
--         SELECT
--             pr.journal_id,
--             'purchase_return'::TEXT     AS source_type,
--             pr.purchase_return_id       AS source_id
--         FROM purchasereturns pr
--         WHERE pr.journal_id IS NOT NULL

--         UNION ALL

--         -- Sale Invoice
--         SELECT
--             si.journal_id,
--             'sale'::TEXT            AS source_type,
--             si.sales_invoice_id     AS source_id
--         FROM salesinvoices si
--         WHERE si.journal_id IS NOT NULL

--         UNION ALL

--         -- Sales Return
--         SELECT
--             sr.journal_id,
--             'sale_return'::TEXT     AS source_type,
--             sr.sales_return_id      AS source_id
--         FROM salesreturns sr
--         WHERE sr.journal_id IS NOT NULL

--         UNION ALL

--         -- Receipt
--         SELECT
--             r.journal_id,
--             'receipt'::TEXT         AS source_type,
--             r.receipt_id            AS source_id
--         FROM receipts r
--         WHERE r.journal_id IS NOT NULL

--         UNION ALL

--         -- Payment
--         SELECT
--             py.journal_id,
--             'payment'::TEXT         AS source_type,
--             py.payment_id           AS source_id
--         FROM payments py
--         WHERE py.journal_id IS NOT NULL
--     )

--     SELECT
--         pl.entry_date,
--         pl.journal_id,
--         pl.description,
--         pl.party_name,
--         pl.account_name                 AS account_type,
--         pl.debit,
--         pl.credit,
--         SUM(pl.amount) OVER (
--             ORDER BY pl.entry_date, pl.journal_id
--             ROWS UNBOUNDED PRECEDING
--         )                               AS running_balance,

--         -- -------------------------------------------------------
--         -- Build invoice_details JSON based on source type
--         -- -------------------------------------------------------
--         CASE js.source_type

--             -- ===================================================
--             -- PURCHASE INVOICE
--             -- ===================================================
--             WHEN 'purchase' THEN (
--                 SELECT to_jsonb(d) FROM (
--                     SELECT
--                         'Purchase Invoice'              AS type,
--                         pi.purchase_invoice_id,
--                         pa.party_name                   AS vendor,
--                         pi.invoice_date,
--                         pi.total_amount,
--                         (
--                             SELECT json_agg(
--                                 json_build_object(
--                                     'item_name',    i.item_name,
--                                     'qty',          pit.quantity,
--                                     'unit_price',   pit.unit_price,
--                                     'line_total',   pit.quantity * pit.unit_price,
--                                     'serials', (
--                                         SELECT json_agg(
--                                             json_build_object(
--                                                 'serial',  pu.serial_number,
--                                                 'comment', pu.serial_comment
--                                             )
--                                         )
--                                         FROM purchaseunits pu
--                                         WHERE pu.purchase_item_id = pit.purchase_item_id
--                                     )
--                                 )
--                             )
--                             FROM purchaseitems pit
--                             JOIN items i ON i.item_id = pit.item_id
--                             WHERE pit.purchase_invoice_id = pi.purchase_invoice_id
--                         )                               AS items
--                     FROM purchaseinvoices pi
--                     JOIN parties pa ON pa.party_id = pi.vendor_id
--                     WHERE pi.purchase_invoice_id = js.source_id
--                 ) d
--             )

--             -- ===================================================
--             -- PURCHASE RETURN
--             -- ===================================================
--             WHEN 'purchase_return' THEN (
--                 SELECT to_jsonb(d) FROM (
--                     SELECT
--                         'Purchase Return'               AS type,
--                         pr.purchase_return_id,
--                         pa.party_name                   AS vendor,
--                         pr.return_date,
--                         pr.total_amount,
--                         (
--                             SELECT json_agg(
--                                 json_build_object(
--                                     'item_name',    i.item_name,
--                                     'unit_price',   pri.unit_price,
--                                     'serial_number', pri.serial_number
--                                 )
--                             )
--                             FROM purchasereturnitems pri
--                             JOIN items i ON i.item_id = pri.item_id
--                             WHERE pri.purchase_return_id = pr.purchase_return_id
--                         )                               AS items
--                     FROM purchasereturns pr
--                     JOIN parties pa ON pa.party_id = pr.vendor_id
--                     WHERE pr.purchase_return_id = js.source_id
--                 ) d
--             )

--             -- ===================================================
--             -- SALE INVOICE
--             -- ===================================================
--             WHEN 'sale' THEN (
--                 SELECT to_jsonb(d) FROM (
--                     SELECT
--                         'Sale Invoice'                  AS type,
--                         si.sales_invoice_id,
--                         pa.party_name                   AS customer,
--                         si.invoice_date,
--                         si.total_amount,
--                         (
--                             SELECT json_agg(
--                                 json_build_object(
--                                     'item_name',    i.item_name,
--                                     'qty',          sitm.quantity,
--                                     'unit_price',   sitm.unit_price,
--                                     'line_total',   sitm.quantity * sitm.unit_price,
--                                     'serials', (
--                                         SELECT json_agg(
--                                             json_build_object(
--                                                 'serial',       pu.serial_number,
--                                                 'comment',      pu.serial_comment,
--                                                 'sold_price',   su.sold_price
--                                             )
--                                         )
--                                         FROM soldunits su
--                                         JOIN purchaseunits pu ON su.unit_id = pu.unit_id
--                                         WHERE su.sales_item_id = sitm.sales_item_id
--                                     )
--                                 )
--                             )
--                             FROM salesitems sitm
--                             JOIN items i ON i.item_id = sitm.item_id
--                             WHERE sitm.sales_invoice_id = si.sales_invoice_id
--                         )                               AS items
--                     FROM salesinvoices si
--                     JOIN parties pa ON pa.party_id = si.customer_id
--                     WHERE si.sales_invoice_id = js.source_id
--                 ) d
--             )

--             -- ===================================================
--             -- SALE RETURN
--             -- ===================================================
--             WHEN 'sale_return' THEN (
--                 SELECT to_jsonb(d) FROM (
--                     SELECT
--                         'Sale Return'                   AS type,
--                         sr.sales_return_id,
--                         pa.party_name                   AS customer,
--                         sr.return_date,
--                         sr.total_amount,
--                         (
--                             SELECT json_agg(
--                                 json_build_object(
--                                     'item_name',        i.item_name,
--                                     'sold_price',       sri.sold_price,
--                                     'cost_price',       sri.cost_price,
--                                     'serial_number',    sri.serial_number
--                                 )
--                             )
--                             FROM salesreturnitems sri
--                             JOIN items i ON i.item_id = sri.item_id
--                             WHERE sri.sales_return_id = sr.sales_return_id
--                         )                               AS items
--                     FROM salesreturns sr
--                     JOIN parties pa ON pa.party_id = sr.customer_id
--                     WHERE sr.sales_return_id = js.source_id
--                 ) d
--             )

--             -- ===================================================
--             -- RECEIPT
--             -- ===================================================
--             WHEN 'receipt' THEN (
--                 SELECT to_jsonb(d) FROM (
--                     SELECT
--                         'Receipt'                       AS type,
--                         r.receipt_id,
--                         pa.party_name                   AS party,
--                         r.receipt_date,
--                         r.amount,
--                         r.method,
--                         r.reference_no,
--                         r.notes,
--                         r.description
--                     FROM receipts r
--                     JOIN parties pa ON pa.party_id = r.party_id
--                     WHERE r.receipt_id = js.source_id
--                 ) d
--             )

--             -- ===================================================
--             -- PAYMENT
--             -- ===================================================
--             WHEN 'payment' THEN (
--                 SELECT to_jsonb(d) FROM (
--                     SELECT
--                         'Payment'                       AS type,
--                         py.payment_id,
--                         pa.party_name                   AS party,
--                         py.payment_date,
--                         py.amount,
--                         py.method,
--                         py.reference_no,
--                         py.notes,
--                         py.description
--                     FROM payments py
--                     JOIN parties pa ON pa.party_id = py.party_id
--                     WHERE py.payment_id = js.source_id
--                 ) d
--             )

--             ELSE NULL

--         END                             AS invoice_details

--     FROM party_ledger pl
--     LEFT JOIN journal_source js ON js.journal_id = pl.journal_id
--     ORDER BY pl.entry_date, pl.journal_id;
-- END;
-- $$;
-- ================================================================
--  detailed_ledger2  —  with correct opening balance
--  Opening balance = net of ALL journal lines for this party
--  that fall BEFORE p_start_date.
-- ================================================================
CREATE OR REPLACE FUNCTION public.detailed_ledger2(
    p_party_name TEXT,
    p_start_date DATE,
    p_end_date   DATE
)
RETURNS TABLE(
    entry_date      DATE,
    journal_id      BIGINT,
    description     TEXT,
    party_name      TEXT,
    account_type    TEXT,
    debit           NUMERIC,
    credit          NUMERIC,
    running_balance NUMERIC,
    invoice_details JSONB
)
LANGUAGE plpgsql AS $$
DECLARE
    v_opening_balance NUMERIC;
BEGIN

    -- ============================================================
    -- STEP 1: Calculate opening balance
    --         Sum of (debit - credit) for this party on ALL journal
    --         lines whose entry_date is strictly BEFORE p_start_date.
    -- ============================================================
    SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
    INTO   v_opening_balance
    FROM   journallines jl
    JOIN   journalentries je ON jl.journal_id = je.journal_id
    JOIN   parties p         ON jl.party_id   = p.party_id
    WHERE  p.party_name = p_party_name
      AND  je.entry_date < p_start_date;

    -- ============================================================
    -- STEP 2: Return ledger rows for the requested date range,
    --         seeding the running balance with v_opening_balance.
    -- ============================================================
    RETURN QUERY
    WITH party_ledger AS (
        SELECT
            je.entry_date                   AS entry_date,
            je.journal_id                   AS journal_id,
            je.description::TEXT            AS description,
            p.party_name::TEXT              AS party_name,
            a.account_name::TEXT            AS account_name,
            jl.debit                        AS debit,
            jl.credit                       AS credit,
            (jl.debit - jl.credit)          AS amount
        FROM journallines jl
        JOIN journalentries je  ON jl.journal_id   = je.journal_id
        JOIN chartofaccounts a  ON jl.account_id   = a.account_id
        LEFT JOIN parties p     ON jl.party_id     = p.party_id
        WHERE p.party_name = p_party_name
          AND je.entry_date BETWEEN p_start_date AND p_end_date
    ),

    journal_source AS (
        SELECT pi.journal_id, 'purchase'::TEXT        AS source_type, pi.purchase_invoice_id  AS source_id FROM purchaseinvoices pi  WHERE pi.journal_id IS NOT NULL
        UNION ALL
        SELECT pr.journal_id, 'purchase_return'::TEXT AS source_type, pr.purchase_return_id   AS source_id FROM purchasereturns pr   WHERE pr.journal_id IS NOT NULL
        UNION ALL
        SELECT si.journal_id, 'sale'::TEXT            AS source_type, si.sales_invoice_id     AS source_id FROM salesinvoices si     WHERE si.journal_id IS NOT NULL
        UNION ALL
        SELECT sr.journal_id, 'sale_return'::TEXT     AS source_type, sr.sales_return_id      AS source_id FROM salesreturns sr      WHERE sr.journal_id IS NOT NULL
        UNION ALL
        SELECT r.journal_id,  'receipt'::TEXT         AS source_type, r.receipt_id            AS source_id FROM receipts r           WHERE r.journal_id  IS NOT NULL
        UNION ALL
        SELECT py.journal_id, 'payment'::TEXT         AS source_type, py.payment_id           AS source_id FROM payments py          WHERE py.journal_id IS NOT NULL
    )

    SELECT
        pl.entry_date,
        pl.journal_id,
        pl.description,
        pl.party_name,
        pl.account_name                                     AS account_type,
        pl.debit,
        pl.credit,

        -- Seed the window sum with the pre-period opening balance
        v_opening_balance + SUM(pl.amount) OVER (
            ORDER BY pl.entry_date, pl.journal_id
            ROWS UNBOUNDED PRECEDING
        )                                                   AS running_balance,

        -- -------------------------------------------------------
        -- invoice_details  (unchanged from original)
        -- -------------------------------------------------------
        CASE js.source_type

            WHEN 'purchase' THEN (
                SELECT to_jsonb(d) FROM (
                    SELECT
                        'Purchase Invoice'          AS type,
                        pi.purchase_invoice_id,
                        pa.party_name               AS vendor,
                        pi.invoice_date,
                        pi.total_amount,
                        (
                            SELECT json_agg(json_build_object(
                                'item_name',  i.item_name,
                                'qty',        pit.quantity,
                                'unit_price', pit.unit_price,
                                'line_total', pit.quantity * pit.unit_price,
                                'serials', (
                                    SELECT json_agg(json_build_object(
                                        'serial',  pu.serial_number,
                                        'comment', pu.serial_comment
                                    ))
                                    FROM purchaseunits pu
                                    WHERE pu.purchase_item_id = pit.purchase_item_id
                                )
                            ))
                            FROM purchaseitems pit
                            JOIN items i ON i.item_id = pit.item_id
                            WHERE pit.purchase_invoice_id = pi.purchase_invoice_id
                        ) AS items
                    FROM purchaseinvoices pi
                    JOIN parties pa ON pa.party_id = pi.vendor_id
                    WHERE pi.purchase_invoice_id = js.source_id
                ) d
            )

            WHEN 'purchase_return' THEN (
                SELECT to_jsonb(d) FROM (
                    SELECT
                        'Purchase Return'           AS type,
                        pr.purchase_return_id,
                        pa.party_name               AS vendor,
                        pr.return_date,
                        pr.total_amount,
                        (
                            SELECT json_agg(json_build_object(
                                'item_name',     i.item_name,
                                'unit_price',    pri.unit_price,
                                'serial_number', pri.serial_number
                            ))
                            FROM purchasereturnitems pri
                            JOIN items i ON i.item_id = pri.item_id
                            WHERE pri.purchase_return_id = pr.purchase_return_id
                        ) AS items
                    FROM purchasereturns pr
                    JOIN parties pa ON pa.party_id = pr.vendor_id
                    WHERE pr.purchase_return_id = js.source_id
                ) d
            )

            WHEN 'sale' THEN (
                SELECT to_jsonb(d) FROM (
                    SELECT
                        'Sale Invoice'              AS type,
                        si.sales_invoice_id,
                        pa.party_name               AS customer,
                        si.invoice_date,
                        si.total_amount,
                        (
                            SELECT json_agg(json_build_object(
                                'item_name',  i.item_name,
                                'qty',        sitm.quantity,
                                'unit_price', sitm.unit_price,
                                'line_total', sitm.quantity * sitm.unit_price,
                                'serials', (
                                    SELECT json_agg(json_build_object(
                                        'serial',     pu.serial_number,
                                        'comment',    pu.serial_comment,
                                        'sold_price', su.sold_price
                                    ))
                                    FROM soldunits su
                                    JOIN purchaseunits pu ON su.unit_id = pu.unit_id
                                    WHERE su.sales_item_id = sitm.sales_item_id
                                )
                            ))
                            FROM salesitems sitm
                            JOIN items i ON i.item_id = sitm.item_id
                            WHERE sitm.sales_invoice_id = si.sales_invoice_id
                        ) AS items
                    FROM salesinvoices si
                    JOIN parties pa ON pa.party_id = si.customer_id
                    WHERE si.sales_invoice_id = js.source_id
                ) d
            )

            WHEN 'sale_return' THEN (
                SELECT to_jsonb(d) FROM (
                    SELECT
                        'Sale Return'               AS type,
                        sr.sales_return_id,
                        pa.party_name               AS customer,
                        sr.return_date,
                        sr.total_amount,
                        (
                            SELECT json_agg(json_build_object(
                                'item_name',     i.item_name,
                                'sold_price',    sri.sold_price,
                                'cost_price',    sri.cost_price,
                                'serial_number', sri.serial_number
                            ))
                            FROM salesreturnitems sri
                            JOIN items i ON i.item_id = sri.item_id
                            WHERE sri.sales_return_id = sr.sales_return_id
                        ) AS items
                    FROM salesreturns sr
                    JOIN parties pa ON pa.party_id = sr.customer_id
                    WHERE sr.sales_return_id = js.source_id
                ) d
            )

            WHEN 'receipt' THEN (
                SELECT to_jsonb(d) FROM (
                    SELECT
                        'Receipt'        AS type,
                        r.receipt_id,
                        pa.party_name    AS party,
                        r.receipt_date,
                        r.amount,
                        r.method,
                        r.reference_no,
                        r.notes,
                        r.description
                    FROM receipts r
                    JOIN parties pa ON pa.party_id = r.party_id
                    WHERE r.receipt_id = js.source_id
                ) d
            )

            WHEN 'payment' THEN (
                SELECT to_jsonb(d) FROM (
                    SELECT
                        'Payment'        AS type,
                        py.payment_id,
                        pa.party_name    AS party,
                        py.payment_date,
                        py.amount,
                        py.method,
                        py.reference_no,
                        py.notes,
                        py.description
                    FROM payments py
                    JOIN parties pa ON pa.party_id = py.party_id
                    WHERE py.payment_id = js.source_id
                ) d
            )

            ELSE NULL

        END AS invoice_details

    FROM party_ledger pl
    LEFT JOIN journal_source js ON js.journal_id = pl.journal_id
    ORDER BY pl.entry_date, pl.journal_id;

END;
$$;

--
-- Name: vw_trial_balance; Type: VIEW; Schema: public; Owner: -
--

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


---------------- get cash Ledger----------------------------------------------------


CREATE OR REPLACE FUNCTION public.get_cash_ledger_with_party(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
) RETURNS TABLE (
    entry_date DATE,
    journal_id BIGINT,
    party_name VARCHAR(150),
    description TEXT,
    debit NUMERIC(14,4),
    credit NUMERIC(14,4),
    balance NUMERIC(14,4)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cash_account_id BIGINT;
    v_opening_balance NUMERIC(14,4) := 0;
BEGIN
    -- Get Cash account ID
    SELECT account_id INTO v_cash_account_id
    FROM ChartOfAccounts
    WHERE account_name = 'Cash'
    LIMIT 1;

    IF v_cash_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account not found in Chart of Accounts';
    END IF;

    -- Set default dates if not provided
    p_start_date := COALESCE(p_start_date, '1900-01-01'::DATE);
    p_end_date := COALESCE(p_end_date, CURRENT_DATE);

    -- Calculate opening balance
    SELECT COALESCE(SUM(jl.debit) - SUM(jl.credit), 0)
    INTO v_opening_balance
    FROM JournalLines jl
    JOIN JournalEntries je ON jl.journal_id = je.journal_id
    WHERE jl.account_id = v_cash_account_id
      AND je.entry_date < p_start_date;

    -- Return opening balance if there are prior transactions
    IF v_opening_balance <> 0 THEN
        RETURN QUERY
        SELECT 
            p_start_date AS entry_date,
            NULL::BIGINT AS journal_id,
            NULL::VARCHAR(150) AS party_name,
            'Opening Balance'::TEXT AS description,
            CASE WHEN v_opening_balance > 0 THEN v_opening_balance ELSE 0 END AS debit,
            CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END AS credit,
            v_opening_balance AS balance;
    END IF;

    -- Return all cash transactions with party information
    RETURN QUERY
    WITH cash_transactions AS (
        SELECT 
            je.entry_date,
            je.journal_id,
            -- Get party name from the OTHER journal line in the same journal entry
            (SELECT p.party_name 
             FROM JournalLines jl2
             LEFT JOIN Parties p ON jl2.party_id = p.party_id
             WHERE jl2.journal_id = je.journal_id 
               AND jl2.account_id != v_cash_account_id
               AND jl2.party_id IS NOT NULL
             LIMIT 1) AS party_name,
            je.description,
            jl.debit,
            jl.credit,
            (jl.debit - jl.credit) AS net_amount
        FROM JournalLines jl
        JOIN JournalEntries je ON jl.journal_id = je.journal_id
        WHERE jl.account_id = v_cash_account_id
          AND je.entry_date >= p_start_date
          AND je.entry_date <= p_end_date
        ORDER BY je.entry_date, je.journal_id
    )
    SELECT 
        ct.entry_date,
        ct.journal_id,
        ct.party_name,
        ct.description,
        ct.debit,
        ct.credit,
        v_opening_balance + SUM(ct.net_amount) OVER (ORDER BY ct.entry_date, ct.journal_id) AS balance
    FROM cash_transactions ct;

END;
$$;



--===============================================================================================
--                                       Accounts Reports END
--===============================================================================================
