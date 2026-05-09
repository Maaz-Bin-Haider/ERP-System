--
-- ============================================================
-- TABLE: salesinvoices
-- ============================================================
--

CREATE TABLE public.salesinvoices (
    sales_invoice_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    invoice_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) NOT NULL,
    journal_id bigint,
    created_by integer
);


ALTER TABLE public.salesinvoices OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: salesinvoices salesinvoices_pkey
ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_pkey PRIMARY KEY (sales_invoice_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: salesinvoices salesinvoices_created_by_fkey
ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.auth_user(id) ON DELETE SET NULL;

-- FK: salesinvoices salesinvoices_customer_id_fkey
ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;

-- FK: salesinvoices salesinvoices_journal_id_fkey
ALTER TABLE ONLY public.salesinvoices
    ADD CONSTRAINT salesinvoices_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;


-- DEFAULT (sequence linkage): salesinvoices sales_invoice_id
ALTER TABLE ONLY public.salesinvoices ALTER COLUMN sales_invoice_id SET DEFAULT nextval('public.salesinvoices_sales_invoice_id_seq'::regclass);
