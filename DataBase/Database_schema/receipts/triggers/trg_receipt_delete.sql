--
-- ============================================================
-- TRIGGER: receipts trg_receipt_delete
-- ============================================================
--

CREATE TRIGGER trg_receipt_delete AFTER DELETE ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();
