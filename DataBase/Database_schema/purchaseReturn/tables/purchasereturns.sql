--
-- ============================================================
-- TABLE: purchasereturns
-- ============================================================
--

CREATE TABLE public.purchasereturns (
    purchase_return_id bigint NOT NULL,
    vendor_id bigint NOT NULL,
    return_date date DEFAULT CURRENT_DATE NOT NULL,
    total_amount numeric(14,2) DEFAULT 0 NOT NULL,
    journal_id bigint,
    created_by integer
);


ALTER TABLE public.purchasereturns OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: purchasereturns purchasereturns_pkey
ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_pkey PRIMARY KEY (purchase_return_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: purchasereturns purchasereturns_created_by_fkey
ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.auth_user(id) ON DELETE SET NULL;

-- FK: purchasereturns purchasereturns_journal_id_fkey
ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE SET NULL;

-- FK: purchasereturns purchasereturns_vendor_id_fkey
ALTER TABLE ONLY public.purchasereturns
    ADD CONSTRAINT purchasereturns_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.parties(party_id) ON DELETE CASCADE;


-- DEFAULT (sequence linkage): purchasereturns purchase_return_id
ALTER TABLE ONLY public.purchasereturns ALTER COLUMN purchase_return_id SET DEFAULT nextval('public.purchasereturns_purchase_return_id_seq'::regclass);
