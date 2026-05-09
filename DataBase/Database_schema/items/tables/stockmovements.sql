--
-- ============================================================
-- TABLE: stockmovements
-- ============================================================
--

CREATE TABLE public.stockmovements (
    movement_id bigint NOT NULL,
    item_id bigint NOT NULL,
    serial_number text,
    movement_type character varying(20) NOT NULL,
    reference_type character varying(50),
    reference_id bigint,
    movement_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    quantity integer NOT NULL,
    CONSTRAINT stockmovements_movement_type_check CHECK (((movement_type)::text = ANY (ARRAY[('IN'::character varying)::text, ('OUT'::character varying)::text])))
);


ALTER TABLE public.stockmovements OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: stockmovements stockmovements_pkey
ALTER TABLE ONLY public.stockmovements
    ADD CONSTRAINT stockmovements_pkey PRIMARY KEY (movement_id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: stockmovements stockmovements_item_id_fkey
ALTER TABLE ONLY public.stockmovements
    ADD CONSTRAINT stockmovements_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(item_id);


--
-- PostgreSQL database dump complete
--

\unrestrict qZR7GopBRfZiHHhak9tOaLeN4k9xOyoH1ONaKWoWUTQtBBtbNWTA5HdPk4VTP3O


-- DEFAULT (sequence linkage): stockmovements movement_id
ALTER TABLE ONLY public.stockmovements ALTER COLUMN movement_id SET DEFAULT nextval('public.stockmovements_movement_id_seq'::regclass);


