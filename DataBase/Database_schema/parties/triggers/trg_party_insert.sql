--
-- ============================================================
-- TRIGGER: parties trg_party_insert
-- ============================================================
--

CREATE TRIGGER trg_party_insert AFTER INSERT ON public.parties FOR EACH ROW EXECUTE FUNCTION public.trg_party_opening_balance();
