--
-- ============================================================
-- TRIGGER: receipts trg_receipt_insert
-- ============================================================
--

CREATE TRIGGER trg_receipt_insert AFTER INSERT ON public.receipts FOR EACH ROW EXECUTE FUNCTION public.trg_receipt_journal();
