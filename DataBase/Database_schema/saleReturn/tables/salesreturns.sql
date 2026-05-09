--
-- ============================================================
-- TABLE: salesreturns
-- ============================================================
--

CREATE TABLE public.salesreturns (
    sales_return_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    return_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) DEFAULT 0 NOT NULL,
    journal_id bigint,
    created_by integer
);


ALTER TABLE public.salesreturns OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: salesreturns salesreturns_pkey
ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_pkey PRIMARY KEY (sales_return_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: salesreturns salesreturns_created_by_fkey
ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.auth_user(id) ON DELETE SET NULL;

-- FK: salesreturns salesreturns_customer_id_fkey
ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;

-- FK: salesreturns salesreturns_journal_id_fkey
ALTER TABLE ONLY public.salesreturns
    ADD CONSTRAINT salesreturns_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


-- DEFAULT (sequence linkage): salesreturns sales_return_id
ALTER TABLE ONLY public.salesreturns ALTER COLUMN sales_return_id SET DEFAULT nextval('public.salesreturns_sales_return_id_seq'::regclass);
