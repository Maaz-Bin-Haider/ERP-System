--
-- ============================================================
-- TRIGGER: payments trg_payment_update
-- ============================================================
--

CREATE TRIGGER trg_payment_update AFTER UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.trg_payment_journal();
