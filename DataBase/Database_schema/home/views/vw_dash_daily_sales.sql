--
-- ============================================================
-- VIEW: vw_dash_daily_sales
-- ============================================================
--

CREATE VIEW public.vw_dash_daily_sales AS
 SELECT invoice_date AS sale_date,
    count(DISTINCT sales_invoice_id) AS invoice_count,
    COALESCE(sum(total_amount), (0)::numeric) AS total_revenue
   FROM public.salesinvoices si
  GROUP BY invoice_date;


ALTER VIEW public.vw_dash_daily_sales OWNER TO postgres;
