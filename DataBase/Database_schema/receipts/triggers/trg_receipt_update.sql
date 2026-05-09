--
-- ============================================================
-- TRIGGER: receipts trg_receipt_update
-- ============================================================
--

CREATE TRIGGER trg_receipt_update AFTER UPDATE ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();
