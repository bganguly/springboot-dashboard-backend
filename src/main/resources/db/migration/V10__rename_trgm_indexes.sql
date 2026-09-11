-- Rename indexes: original names ended in _bigm but they use gin_trgm_ops (pg_trgm).
-- pg_bigm is not available on Neon; the implementation was always trgm.

DROP INDEX IF EXISTS "idx_orders_search_text_bigm";
CREATE INDEX IF NOT EXISTS "idx_orders_search_text_trgm"
  ON orders USING gin (search_text gin_trgm_ops);

DROP INDEX IF EXISTS "idx_orders_notes_bigm";
CREATE INDEX IF NOT EXISTS "idx_orders_notes_trgm"
  ON orders USING gin (notes gin_trgm_ops);

DROP INDEX IF EXISTS "idx_customers_bigm";
CREATE INDEX IF NOT EXISTS "idx_customers_trgm"
  ON customers
  USING gin (("firstName"||' '||"lastName"||' '||email) gin_trgm_ops);
