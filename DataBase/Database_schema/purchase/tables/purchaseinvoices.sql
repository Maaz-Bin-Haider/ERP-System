--
-- ============================================================
-- TABLE: purchaseinvoices
-- ============================================================
--

CREATE TABLE public.purchaseinvoices (
    purchase_invoice_id bigint NOT NULL,
    vendor_id bigint NOT NULL,
    invoice_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) NOT NULL,
    journal_id bigint,
    created_by integer
);


ALTER TABLE public.purchaseinvoices OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: purchaseinvoices purchaseinvoices_pkey
ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_pkey PRIMARY KEY (purchase_invoice_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: purchaseinvoices purchaseinvoices_created_by_fkey
ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.auth_user(id) ON DELETE SET NULL;

-- FK: purchaseinvoices purchaseinvoices_journal_id_fkey
ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;

-- FK: purchaseinvoices purchaseinvoices_vendor_id_fkey
ALTER TABLE ONLY public.purchaseinvoices
    ADD CONSTRAINT purchaseinvoices_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


-- DEFAULT (sequence linkage): purchaseinvoices purchase_invoice_id
ALTER TABLE ONLY public.purchaseinvoices ALTER COLUMN purchase_invoice_id SET DEFAULT nextval('public.purchaseinvoices_purchase_invoice_id_seq'::regclass);
