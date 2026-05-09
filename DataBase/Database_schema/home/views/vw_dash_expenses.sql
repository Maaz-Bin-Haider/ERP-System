--
-- ============================================================
-- VIEW: vw_dash_expenses
-- ============================================================
--

CREATE VIEW public.vw_dash_expenses AS
 SELECT je.entry_date,
    je.description AS expense_note,
    coa.account_name AS expense_category,
    coa.account_id,
    COALESCE(jl.debit, (0)::numeric) AS amount,
    p.party_name
   FROM (((public.journalentries je
     JOIN public.journallines jl ON ((jl.journal_id = je.journal_id)))
     JOIN public.chartofaccounts coa ON ((coa.account_id = jl.account_id)))
     LEFT JOIN public.parties p ON ((p.party_id = jl.party_id)))
  WHERE (((coa.account_type)::text ~~* '%expense%'::text) AND (jl.debit > (0)::numeric));


ALTER VIEW public.vw_dash_expenses OWNER TO postgres;
