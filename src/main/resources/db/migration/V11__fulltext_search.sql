-- Postgres full-text search column on orders using the 'simple' dictionary
-- (lowercases only; no English stemming so proper names are preserved).
-- Covers the same fields as search_text: customer name, notes, region name.
-- Controlled by search.fulltext.enabled at runtime; ILIKE remains the default.

ALTER TABLE orders ADD COLUMN IF NOT EXISTS search_tsv tsvector;

UPDATE orders o
SET search_tsv = to_tsvector('simple',
  c."firstName" || ' ' || c."lastName" || ' ' ||
  COALESCE(o.notes, '') || ' ' ||
  r.name
)
FROM customers c, regions r
WHERE c.id = o."customerId"
  AND r.id = o."regionId";

CREATE INDEX IF NOT EXISTS idx_orders_search_tsv
  ON orders USING gin (search_tsv);

CREATE OR REPLACE FUNCTION fn_order_search_tsv() RETURNS TRIGGER AS $$
DECLARE
  v_first text; v_last text; v_rname text;
BEGIN
  SELECT "firstName", "lastName" INTO v_first, v_last
    FROM customers WHERE id = NEW."customerId";
  SELECT name INTO v_rname
    FROM regions WHERE id = NEW."regionId";
  NEW.search_tsv := to_tsvector('simple',
    v_first || ' ' || v_last || ' ' ||
    COALESCE(NEW.notes, '') || ' ' ||
    v_rname
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trgr_order_search_tsv
  BEFORE INSERT OR UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION fn_order_search_tsv();

CREATE OR REPLACE FUNCTION fn_customer_name_to_orders_tsv() RETURNS TRIGGER AS $$
BEGIN
  IF OLD."firstName" IS DISTINCT FROM NEW."firstName" OR
     OLD."lastName"  IS DISTINCT FROM NEW."lastName" THEN
    UPDATE orders o
    SET search_tsv = to_tsvector('simple',
      NEW."firstName" || ' ' || NEW."lastName" || ' ' ||
      COALESCE(o.notes, '') || ' ' ||
      r.name
    )
    FROM regions r
    WHERE o."customerId" = NEW.id AND r.id = o."regionId";
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trgr_customer_name_to_orders_tsv
  AFTER UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION fn_customer_name_to_orders_tsv();
