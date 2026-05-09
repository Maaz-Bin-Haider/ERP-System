--
-- ============================================================
-- TABLE: journalentries
-- ============================================================
--

CREATE TABLE public.journalentries (
    journal_id bigint NOT NULL,
    entry_date date DEFAULT CURRENT_DATE NOT NULL,
    description text,
    date_created timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.journalentries OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: journalentries journalentries_pkey
ALTER TABLE ONLY public.journalentries
    ADD CONSTRAINT journalentries_pkey PRIMARY KEY (journal_id);


-- DEFAULT (sequence linkage): journalentries journal_id
ALTER TABLE ONLY public.journalentries ALTER COLUMN journal_id SET DEFAULT nextval('public.journalentries_journal_id_seq'::regclass);
