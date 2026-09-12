-- Efficient bulk seed via generate_series (loads millions of rows in minutes).
-- Usage: psql "$DATABASE_URL" -v orders=4000000 -v first_names_file=scripts/data/first_names.txt -v last_names_file=scripts/data/last_names.txt -f scripts/seed-large.sql
-- `orders`, `first_names_file`, and `last_names_file` MUST be passed with -v.
\set ON_ERROR_STOP on
\set customers 200000
\set products 5000
\set categories 200
\set regions 50
\set batch_size 500000
\set summary_days 30
\set summary_cats 200
\set summary_regions 50

-- Load 3186 first names and 473 last names (same pool as clickhouse-dashboard)
CREATE TEMP TABLE _first_names (id serial, name text);
\copy _first_names (name) FROM :'first_names_file'

CREATE TEMP TABLE _last_names (id serial, name text);
\copy _last_names (name) FROM :'last_names_file'

\echo Truncating existing data...
TRUNCATE order_items, orders, daily_summary, products, customers, categories, regions RESTART IDENTITY CASCADE;

\echo Seeding regions / categories / products / customers...
INSERT INTO regions (code, name, country, timezone)
SELECT 'R' || g, 'Region ' || g, 'US', 'America/New_York'
FROM generate_series(1, :regions) g;

INSERT INTO categories (name, slug, "createdAt", "updatedAt")
SELECT 'Category ' || g, 'category-' || g, now(), now()
FROM generate_series(1, :categories) g;

INSERT INTO products (sku, name, price, cost, stock, "categoryId", "createdAt", "updatedAt")
SELECT 'SKU-' || g, 'Product ' || g,
       round((random() * 100 + 5)::numeric, 2),
       round((random() * 50 + 2)::numeric, 2),
       (random() * 500)::int,
       1 + floor(random() * :categories)::int, now(), now()
FROM generate_series(1, :products) g;

INSERT INTO customers (email, "firstName", "lastName", "regionId", "createdAt", "updatedAt")
SELECT 'customer' || g || '@example.com',
       fn.name,
       ln.name,
       1 + floor(random() * :regions)::int, now(), now()
FROM generate_series(1, :customers) g
JOIN _first_names fn ON fn.id = 1 + ((g - 1) % 3186)
JOIN _last_names  ln ON ln.id = 1 + ((g - 1) % 473);

\echo Seeding :orders orders in batches of :batch_size...
-- Disable per-row trigger during bulk insert; search_text is populated in a
-- single batch UPDATE below (avoids 2 SELECT lookups per row × 4M rows).
ALTER TABLE orders DISABLE TRIGGER ALL;
SET seed.orders = :'orders';
SET seed.batch_size = :'batch_size';
SET seed.customers = :'customers';
SET seed.regions = :'regions';
SET seed.products = :'products';
DO $$
DECLARE
  total_orders integer := current_setting('seed.orders')::integer;
  batch_size integer := current_setting('seed.batch_size')::integer;
  customer_count integer := current_setting('seed.customers')::integer;
  region_count integer := current_setting('seed.regions')::integer;
  start_id integer := 1;
  end_id integer;
  batch_started timestamptz;
BEGIN
  WHILE start_id <= total_orders LOOP
    end_id := LEAST(start_id + batch_size - 1, total_orders);
    batch_started := clock_timestamp();

    INSERT INTO orders ("customerId", "regionId", status, total, currency, notes, "placedAt", "updatedAt")
    SELECT 1 + floor(random() * customer_count)::int,
           1 + floor(random() * region_count)::int,
           (ARRAY['PENDING','CONFIRMED','PROCESSING','SHIPPED','DELIVERED','CANCELLED','REFUNDED'])[1 + floor(random() * 7)]::"OrderStatus",
           round((random() * 500 + 10)::numeric, 2),
           'USD',
           'order ' || g,
           now() - (random() * 730) * interval '1 day',
           now()
    FROM generate_series(start_id, end_id) g;

    RAISE NOTICE 'orders loaded through % / % in %',
      end_id,
      total_orders,
      clock_timestamp() - batch_started;

    start_id := end_id + 1;
  END LOOP;
END $$;

\echo Populating search_text (bulk JOIN — triggers still disabled)...
UPDATE orders o
SET search_text =
  c."firstName" || ' ' || c."lastName" || ' ' ||
  COALESCE(o.notes, '') || ' ' ||
  o.total::text || ' ' ||
  o.id::text || ' ' ||
  o.status::text || ' ' ||
  r.code || ' ' || r.name || ' ' ||
  o."placedAt"::date::text
FROM customers c, regions r
WHERE c.id = o."customerId"
  AND r.id = o."regionId";

ALTER TABLE orders ENABLE TRIGGER ALL;

\echo Seeding order_items in batches of :batch_size...
DO $$
DECLARE
  total_orders integer := current_setting('seed.orders')::integer;
  batch_size integer := current_setting('seed.batch_size')::integer;
  product_count integer := current_setting('seed.products')::integer;
  start_id integer := 1;
  end_id integer;
  batch_started timestamptz;
BEGIN
  WHILE start_id <= total_orders LOOP
    end_id := LEAST(start_id + batch_size - 1, total_orders);
    batch_started := clock_timestamp();

    INSERT INTO order_items ("orderId", "productId", quantity, "unitPrice", discount)
    SELECT g, 1 + floor(random() * product_count)::int,
           1 + floor(random() * 3)::int,
           round((random() * 100 + 5)::numeric, 2), 0
    FROM generate_series(start_id, end_id) g;

    RAISE NOTICE 'order_items loaded through % / % in %',
      end_id,
      total_orders,
      clock_timestamp() - batch_started;

    start_id := end_id + 1;
  END LOOP;
END $$;

\echo Seeding daily_summary (for the chart)...
INSERT INTO daily_summary (date, "categoryId", "categoryName", "regionId", "regionCode",
                           "totalOrders", "totalRevenue", "totalItems", "avgOrderValue", "createdAt", "updatedAt")
SELECT (current_date - d), c, 'Category ' || c, r, 'R' || r,
       (50 + random() * 200)::int,
       round((random() * 10000 + 500)::numeric, 2),
       (100 + random() * 400)::int,
       round((random() * 200 + 30)::numeric, 2),
       now(), now()
FROM generate_series(0, :summary_days - 1) d,
     generate_series(1, :summary_cats) c,
     generate_series(1, :summary_regions) r;

\echo Final counts:
SELECT 'orders' AS tbl, count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'customers', count(*) FROM customers
UNION ALL SELECT 'daily_summary', count(*) FROM daily_summary;
