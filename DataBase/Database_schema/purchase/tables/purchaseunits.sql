--
-- ============================================================
-- TABLE: purchaseunits
-- ============================================================
--

CREATE TABLE public.purchaseunits (
    unit_id bigint NOT NULL,
    purchase_item_id bigint NOT NULL,
    serial_number character varying(100) NOT NULL,
    in_stock boolean DEFAULT true,
    serial_comment text
);


ALTER TABLE public.purchaseunits OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: purchaseunits purchaseunits_pkey
ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_pkey PRIMARY KEY (unit_id);

-- Constraint: purchaseunits purchaseunits_serial_number_key
ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_serial_number_key UNIQUE (serial_number);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: purchaseunits purchaseunits_purchase_item_id_fkey
ALTER TABLE ONLY public.purchaseunits
    ADD CONSTRAINT purchaseunits_purchase_item_id_fkey FOREIGN KEY (purchase_item_id) REFERENCES public.purchaseitems(purchase_item_id) ON DELETE CASCADE;


-- DEFAULT (sequence linkage): purchaseunits unit_id
ALTER TABLE ONLY public.purchaseunits ALTER COLUMN unit_id SET DEFAULT nextval('public.purchaseunits_unit_id_seq'::regclass);
