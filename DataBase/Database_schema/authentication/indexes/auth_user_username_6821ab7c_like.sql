--
-- ============================================================
-- INDEX: auth_user_username_6821ab7c_like
-- ============================================================
--

CREATE INDEX auth_user_username_6821ab7c_like ON public.auth_user USING btree (username varchar_pattern_ops);
