--
-- ============================================================
-- INDEX: auth_permission_content_type_id_2f476e4b
-- ============================================================
--

CREATE INDEX auth_permission_content_type_id_2f476e4b ON public.auth_permission USING btree (content_type_id);
