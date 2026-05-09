--
-- ============================================================
-- VIEW: vw_dash_party_ar_balance
-- ============================================================
--

CREATE VIEW public.vw_dash_party_ar_balance AS
 SELECT p.party_id,
    p.party_name,
    p.party_type,
    p.contact_info,
    COALESCE((sum(jl.debit) - sum(jl.credit)), (0)::numeric) AS ar_balance,
    max(je.entry_date) AS last_transaction_date
   FROM ((public.parties p
     JOIN public.journallines jl ON ((jl.party_id = p.party_id)))
     JOIN public.journalentries je ON ((je.journal_id = jl.journal_id)))
  WHERE (p.ar_account_id IS NOT NULL)
  GROUP BY p.party_id, p.party_name, p.party_type, p.contact_info
 HAVING (COALESCE((sum(jl.debit) - sum(jl.credit)), (0)::numeric) > (0)::numeric);


ALTER VIEW public.vw_dash_party_ar_balance OWNER TO postgres;
