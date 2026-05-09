--
-- ============================================================
-- INDEX: django_session_session_key_c0390e0f_like
-- ============================================================
--

CREATE INDEX django_session_session_key_c0390e0f_like ON public.django_session USING btree (session_key varchar_pattern_ops);
