--
-- ============================================================
-- TABLE: journallines
-- ============================================================
--

CREATE TABLE public.journallines (
    line_id bigint NOT NULL,
    journal_id bigint NOT NULL,
    account_id bigint NOT NULL,
    party_id bigint,
    debit numeric(14,2) DEFAULT 0,
    credit numeric(14,2) DEFAULT 0,
    CONSTRAINT journallines_check CHECK (((debit >= (0)::numeric) AND (credit >= (0)::numeric))),
    CONSTRAINT journallines_check1 CHECK ((NOT ((debit = (0)::numeric) AND (credit = (0)::numeric))))
);


ALTER TABLE public.journallines OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: journallines journallines_pkey
ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_pkey PRIMARY KEY (line_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: journallines journallines_account_id_fkey
ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chartofaccounts(account_id);

-- FK: journallines journallines_journal_id_fkey
ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES public.journalentries(journal_id) ON DELETE CASCADE;

-- FK: journallines journallines_party_id_fkey
ALTER TABLE ONLY public.journallines
    ADD CONSTRAINT journallines_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.parties(party_id) ON DELETE SET NULL;


-- DEFAULT (sequence linkage): journallines line_id
ALTER TABLE ONLY public.journallines ALTER COLUMN line_id SET DEFAULT nextval('public.journallines_line_id_seq'::regclass);
