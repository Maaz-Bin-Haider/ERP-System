--
-- ============================================================
-- TABLE: purchasereturnitems
-- ============================================================
--

CREATE TABLE public.purchasereturnitems (
    return_item_id bigint NOT NULL,
    purchase_return_id bigint NOT NULL,
    item_id bigint NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    serial_number character varying(100) NOT NULL
);


ALTER TABLE public.purchasereturnitems OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: purchasereturnitems purchasereturnitems_pkey
ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_pkey PRIMARY KEY (return_item_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: purchasereturnitems purchasereturnitems_item_id_fkey
ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);

-- FK: purchasereturnitems purchasereturnitems_purchase_return_id_fkey
ALTER TABLE ONLY public.purchasereturnitems
    ADD CONSTRAINT purchasereturnitems_purchase_return_id_fkey FOREIGN KEY (purchase_return_id) REFERENCES public.purchasereturns(purchase_return_id) ON DELETE CASCADE;


-- DEFAULT (sequence linkage): purchasereturnitems return_item_id
ALTER TABLE ONLY public.purchasereturnitems ALTER COLUMN return_item_id SET DEFAULT nextval('public.purchasereturnitems_return_item_id_seq'::regclass);
