-- Backfill the three summary tables that were empty after V3.
-- V3 created daily_customer_category_summary with no INSERT, so the two
-- derived tables (daily_filter_category_summary, daily_status_category_summary)
-- that SELECT FROM it ended up empty as well.

INSERT INTO daily_customer_category_summary (
  date, "customerId", "regionId", "regionCode", status,
  "categoryId", "categoryName",
  "totalOrders", "totalRevenue", "totalItems", "createdAt", "updatedAt"
)
SELECT
  o."placedAt"::date,
  o."customerId",
  o."regionId",
  r.code,
  o.status,
  cat.id,
  cat.name,
  count(DISTINCT o.id)::int,
  coalesce(sum(oi.quantity * oi."unitPrice" * (1 - oi.discount)), 0),
  coalesce(sum(oi.quantity), 0)::int,
  now(),
  now()
FROM orders o
JOIN order_items oi ON oi."orderId" = o.id
JOIN products p     ON p.id         = oi."productId"
JOIN categories cat ON cat.id       = p."categoryId"
JOIN regions r      ON r.id         = o."regionId"
GROUP BY o."placedAt"::date, o."customerId", o."regionId", r.code, o.status, cat.id, cat.name
ON CONFLICT ("date", "customerId", "regionId", "status", "categoryId") DO NOTHING;

INSERT INTO daily_filter_category_summary (
  date, "regionId", "regionCode", status,
  "categoryId", "categoryName",
  "totalOrders", "totalRevenue", "totalItems", "createdAt", "updatedAt"
)
SELECT
  date, "regionId", "regionCode", status,
  "categoryId", "categoryName",
  sum("totalOrders")::int,
  sum("totalRevenue"),
  sum("totalItems")::int,
  now(), now()
FROM daily_customer_category_summary
GROUP BY date, "regionId", "regionCode", status, "categoryId", "categoryName"
ON CONFLICT ("date", "regionId", "status", "categoryId") DO UPDATE SET
  "regionCode"   = EXCLUDED."regionCode",
  "categoryName" = EXCLUDED."categoryName",
  "totalOrders"  = EXCLUDED."totalOrders",
  "totalRevenue" = EXCLUDED."totalRevenue",
  "totalItems"   = EXCLUDED."totalItems",
  "updatedAt"    = CURRENT_TIMESTAMP;

INSERT INTO daily_status_category_summary (
  date, status, "categoryId", "categoryName",
  "totalOrders", "totalRevenue", "totalItems", "createdAt", "updatedAt"
)
SELECT
  date, status, "categoryId", "categoryName",
  sum("totalOrders")::int,
  sum("totalRevenue"),
  sum("totalItems")::int,
  now(), now()
FROM daily_filter_category_summary
GROUP BY date, status, "categoryId", "categoryName"
ON CONFLICT ("date", "status", "categoryId") DO UPDATE SET
  "categoryName" = EXCLUDED."categoryName",
  "totalOrders"  = EXCLUDED."totalOrders",
  "totalRevenue" = EXCLUDED."totalRevenue",
  "totalItems"   = EXCLUDED."totalItems",
  "updatedAt"    = CURRENT_TIMESTAMP;
