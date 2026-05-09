--
-- ============================================================
-- TABLE: purchaseitems
-- ============================================================
--

CREATE TABLE public.purchaseitems (
    purchase_item_id bigint NOT NULL,
    purchase_invoice_id bigint NOT NULL,
    item_id bigint NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    CONSTRAINT purchaseitems_quantity_check CHECK ((quantity > 0))
);


ALTER TABLE public.purchaseitems OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: purchaseitems purchaseitems_pkey
ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_pkey PRIMARY KEY (purchase_item_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: purchaseitems purchaseitems_item_id_fkey
ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);

-- FK: purchaseitems purchaseitems_purchase_invoice_id_fkey
ALTER TABLE ONLY public.purchaseitems
    ADD CONSTRAINT purchaseitems_purchase_invoice_id_fkey FOREIGN KEY (purchase_invoice_id) REFERENCES public.purchaseinvoices(purchase_invoice_id) ON DELETE CASCADE;


-- DEFAULT (sequence linkage): purchaseitems purchase_item_id
ALTER TABLE ONLY public.purchaseitems ALTER COLUMN purchase_item_id SET DEFAULT nextval('public.purchaseitems_purchase_item_id_seq'::regclass);
