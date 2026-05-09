--
-- ============================================================
-- FUNCTION: get_accounts_receivable_json_excluding(text[])
-- ============================================================
--

CREATE FUNCTION public.get_accounts_receivable_json_excluding(p_exclude_names text[] DEFAULT ARRAY[]::text[]) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'name', name,
                   'balance', balance
               )
           )
    INTO result
    FROM vw_trial_balance
    WHERE code IS NULL
      AND type NOT ILIKE '%Expense%'
      AND balance > 0   -- Positive = customer owes us (Accounts Receivable)
      AND (
          p_exclude_names IS NULL
          OR array_length(p_exclude_names, 1) IS NULL
          OR NOT (name = ANY(p_exclude_names))
      );

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;


ALTER FUNCTION public.get_accounts_receivable_json_excluding(p_exclude_names text[]) OWNER TO postgres;
