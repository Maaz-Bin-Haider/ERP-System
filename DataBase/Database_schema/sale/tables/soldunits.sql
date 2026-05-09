--
-- ============================================================
-- TABLE: soldunits
-- ============================================================
--

CREATE TABLE public.soldunits (
    sold_unit_id bigint NOT NULL,
    sales_item_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    sold_price numeric(12,2) NOT NULL,
    status character varying(20) DEFAULT 'Sold'::character varying,
    CONSTRAINT soldunits_status_check CHECK (((status)::text = ANY (ARRAY[('Sold'::character varying)::text, ('Returned'::character varying)::text, ('Damaged'::character varying)::text])))
);


ALTER TABLE public.soldunits OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: soldunits soldunits_pkey
ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_pkey PRIMARY KEY (sold_unit_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: soldunits soldunits_sales_item_id_fkey
ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_sales_item_id_fkey FOREIGN KEY (sales_item_id) REFERENCES public.salesitems(sales_item_id) ON DELETE CASCADE;

-- FK: soldunits soldunits_unit_id_fkey
ALTER TABLE ONLY public.soldunits
    ADD CONSTRAINT soldunits_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.purchaseunits(unit_id) ON DELETE CASCADE;


-- DEFAULT (sequence linkage): soldunits sold_unit_id
ALTER TABLE ONLY public.soldunits ALTER COLUMN sold_unit_id SET DEFAULT nextval('public.soldunits_sold_unit_id_seq'::regclass);
