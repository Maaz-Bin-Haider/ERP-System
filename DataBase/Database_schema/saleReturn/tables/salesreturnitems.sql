--
-- ============================================================
-- TABLE: salesreturnitems
-- ============================================================
--

CREATE TABLE public.salesreturnitems (
    return_item_id bigint NOT NULL,
    sales_return_id bigint NOT NULL,
    item_id bigint NOT NULL,
    sold_price numeric(12,2) NOT NULL,
    cost_price numeric(12,2) NOT NULL,
    serial_number character varying(100) NOT NULL
);


ALTER TABLE public.salesreturnitems OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: salesreturnitems salesreturnitems_pkey
ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_pkey PRIMARY KEY (return_item_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: salesreturnitems salesreturnitems_item_id_fkey
ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);

-- FK: salesreturnitems salesreturnitems_sales_return_id_fkey
ALTER TABLE ONLY public.salesreturnitems
    ADD CONSTRAINT salesreturnitems_sales_return_id_fkey FOREIGN KEY (sales_return_id) REFERENCES public.salesreturns(sales_return_id) ON DELETE CASCADE;


-- DEFAULT (sequence linkage): salesreturnitems return_item_id
ALTER TABLE ONLY public.salesreturnitems ALTER COLUMN return_item_id SET DEFAULT nextval('public.salesreturnitems_return_item_id_seq'::regclass);
