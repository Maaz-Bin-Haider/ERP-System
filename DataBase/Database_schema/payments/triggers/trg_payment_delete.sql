--
-- ============================================================
-- TRIGGER: payments trg_payment_delete
-- ============================================================
--

CREATE TRIGGER trg_payment_delete AFTER DELETE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();
