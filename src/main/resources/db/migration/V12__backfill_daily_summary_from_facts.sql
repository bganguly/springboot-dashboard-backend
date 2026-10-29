-- daily_summary was seeded by seed-large.sql with only 30 synthetic rows
-- (summary_days = 30). order_category_facts was correctly backfilled in V9
-- from the full 4M-order dataset spanning ~730 days. This migration replaces
-- the 30 synthetic rows with real aggregates derived from order_category_facts,
-- giving the /api/aggregates chart accurate data across the full date range.
--
-- Neon enforces idle_in_transaction_session_timeout (default 5 min).
-- Disable for this session so the GROUP BY across order_category_facts can complete.
SET idle_in_transaction_session_timeout = 0;
SET statement_timeout = 0;

TRUNCATE daily_summary;

INSERT INTO daily_summary (
  date, "categoryId", "categoryName", "regionId", "regionCode",
  "totalOrders", "totalRevenue", "totalItems", "avgOrderValue",
  "createdAt", "updatedAt"
)
SELECT
  f.date,
  f."categoryId",
  f."categoryName",
  f."regionId",
  f."regionCode",
  COUNT(DISTINCT f."orderId")::int,
  COALESCE(SUM(f."totalRevenue"), 0),
  COALESCE(SUM(f."totalItems"), 0)::int,
  CASE WHEN COUNT(DISTINCT f."orderId") > 0
       THEN COALESCE(SUM(f."totalRevenue"), 0) / COUNT(DISTINCT f."orderId")
       ELSE 0 END,
  now(),
  now()
FROM order_category_facts f
GROUP BY f.date, f."categoryId", f."categoryName", f."regionId", f."regionCode"
ORDER BY f.date;
