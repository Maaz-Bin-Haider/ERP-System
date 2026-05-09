--
-- ============================================================
-- FUNCTION: fn_dash_receivables_aging()
-- ============================================================
--

CREATE FUNCTION public.fn_dash_receivables_aging() RETURNS json
    LANGUAGE plpgsql STABLE
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


ALTER FUNCTION public.fn_dash_receivables_aging() OWNER TO postgres;
