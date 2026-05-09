--
-- ============================================================
-- INDEX: auth_group_name_a6ea08ec_like
-- ============================================================
--

CREATE INDEX auth_group_name_a6ea08ec_like ON public.auth_group USING btree (name varchar_pattern_ops);
