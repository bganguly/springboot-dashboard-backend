DROP INDEX IF EXISTS "idx_customers_trgm";
DROP INDEX IF EXISTS "idx_orders_notes_trgm";
DROP INDEX IF EXISTS "idx_orders_search_text_trgm";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS "idx_orders_search_text_bigm"
  ON orders USING gin (search_text gin_trgm_ops);
CREATE INDEX IF NOT EXISTS "idx_orders_notes_bigm"
  ON orders USING gin (notes gin_trgm_ops);
CREATE INDEX IF NOT EXISTS "idx_customers_bigm"
  ON customers
  USING gin (("firstName"||' '||"lastName"||' '||email) gin_trgm_ops);
DROP TABLE IF EXISTS daily_customer_token_order_summary CASCADE;
DROP TABLE IF EXISTS daily_customer_token_category_rollup CASCADE;
DROP TABLE IF EXISTS daily_customer_token_category_summary CASCADE;
