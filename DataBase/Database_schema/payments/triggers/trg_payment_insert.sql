--
-- ============================================================
-- TRIGGER: payments trg_payment_insert
-- ============================================================
--

CREATE TRIGGER trg_payment_insert AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();
