--
-- ============================================================
-- TABLE: auth_permission
-- ============================================================
--

CREATE TABLE public.auth_permission (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    content_type_id integer NOT NULL,
    codename character varying(100) NOT NULL
);


ALTER TABLE public.auth_permission OWNER TO postgres;


-- ─────────────────────────────────────────────────
-- PRIMARY KEY & UNIQUE Constraints
-- ─────────────────────────────────────────────────

-- Constraint: auth_permission auth_permission_content_type_id_codename_01ab375a_uniq
ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_codename_01ab375a_uniq UNIQUE (content_type_id, codename);

-- Constraint: auth_permission auth_permission_pkey
ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_pkey PRIMARY KEY (id);


-- ─────────────────────────────────────────────────
-- FOREIGN KEY Constraints
-- ─────────────────────────────────────────────────

-- FK: auth_permission auth_permission_content_type_id_2f476e4b_fk_django_co
ALTER TABLE ONLY public.auth_permission
    ADD CONSTRAINT auth_permission_content_type_id_2f476e4b_fk_django_co FOREIGN KEY (content_type_id) REFERENCES public.django_content_type(id) DEFERRABLE INITIALLY DEFERRED;
