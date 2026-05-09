--
-- ============================================================
-- INDEX: django_session_expire_date_a5c62663
-- ============================================================
--

CREATE INDEX django_session_expire_date_a5c62663 ON public.django_session USING btree (expire_date);
