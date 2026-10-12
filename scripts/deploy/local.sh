#!/usr/bin/env bash

# ── Local deploy ──────────────────────────────────────────────────────────────

_deploy_local() {
  local ORDERS="${ORDERS:-100000}"
  local DB="database_flyway_orm"
  local DB_URL="postgresql://$(whoami):@localhost:5432/${DB}"

  fail() { printf '\nERROR: %s\n\n' "$*" >&2; exit 1; }
  ok()   { printf '  %-18s %s\n' "$1" "$2"; }

  printf '\n=== prerequisites ===\n'
  command -v java >/dev/null 2>&1 || fail "Java 21 not found.
  Install via SDKMAN:
    curl -s https://get.sdkman.io | bash && source ~/.sdkman/bin/sdkman-init.sh
    sdk install java 21-tem"
  JAVA_VER=$(java -version 2>&1 | head -1)
  [[ "$JAVA_VER" =~ 21 ]] || fail "Java 21 required. Found: $JAVA_VER"
  ok "java" "$JAVA_VER"

  command -v gradle >/dev/null 2>&1 || fail "Gradle not found.  sdk install gradle"
  ok "gradle" "$(gradle --version 2>/dev/null | grep '^Gradle ' | head -1)"

  command -v psql >/dev/null 2>&1 || fail "psql not found — brew install postgresql@16"
  ok "psql" "$(psql --version)"

  if ! pg_isready >/dev/null 2>&1; then
    printf '  postgres not running — starting...\n'
    command -v brew >/dev/null 2>&1 && \
      { brew services start postgresql@16 2>/dev/null || brew services start postgresql 2>/dev/null || true; sleep 2; }
    pg_isready >/dev/null 2>&1 || fail "Postgres did not start. brew install postgresql@16"
  fi
  ok "postgres" "ready"

  _local_ensure_pg_bigm "$DB"
  _local_ensure_gradlew
  _local_ensure_db "$DB" "$ORDERS"
  _local_ensure_bigm_indexes "$DB"
  _seed_typesense

  printf '\n=== diagnostics ===\n'
  DATABASE_URL="$DB_URL" ./scripts/diagnose.sh

  _local_start_backend "$DB_URL"
  _local_start_frontend
  exit 0
}

_local_ensure_pg_bigm() {
  local db="$1"
  psql -Atqc "SELECT 1 FROM pg_available_extensions WHERE name='pg_bigm'" 2>/dev/null | grep -q 1 && return 0
  printf '  pg_bigm not found — building from source...\n'
  local pg_cfg tmp
  pg_cfg=$(brew --prefix postgresql@16)/bin/pg_config
  tmp=$(mktemp -d)
  git clone --depth 1 https://github.com/pgbigm/pg_bigm.git "$tmp/pg_bigm"
  make -C "$tmp/pg_bigm" USE_PGXS=1 PG_CONFIG="$pg_cfg"
  make -C "$tmp/pg_bigm" USE_PGXS=1 PG_CONFIG="$pg_cfg" install
  rm -rf "$tmp"
  printf '  pg_bigm installed — restarting postgresql@16...\n'
  brew services restart postgresql@16
  for _i in $(seq 1 10); do pg_isready -q 2>/dev/null && break; sleep 1; done
}

_local_ensure_gradlew() {
  [[ -f "$ROOT_DIR/gradlew" ]] && return 0
  printf '\ngradlew not found — generating...\n'
  gradle wrapper
}

_local_ensure_db() {
  local db="$1" orders="$2"
  local exists
  exists=$(psql -lqt 2>/dev/null | cut -d'|' -f1 | tr -d ' ' | grep -x "$db" || true)
  if [[ -n "$exists" ]]; then
    printf '  %-18s %s\n' "database" "$db (exists — skipping setup)"
    return 0
  fi
  printf '\n=== first-time database setup ===\n'
  printf '  1. createdb %s\n  2. V1-V7 migrations\n  3. seed %s orders\n  4. read model rollups\n' "$db" "$orders"
  printf '\nProceed? [Y/n] '; read -r yn
  [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

  printf '\n[1/4] creating database...\n'; createdb "$db"
  printf '[2/4] applying migrations...\n'
  for v in V1__initial_schema V2__daily_summary V3__indexes_and_read_models \
            V4__search_text V5__customer_sort_index V6__count_cache V7__daily_order_count; do
    psql -d "$db" -f "src/main/resources/db/migration/${v}.sql"
  done
  printf '[3/4] seeding %s orders...\n' "$orders"
  psql -d "$db" -v orders="$orders" -v first_names_file=scripts/data/first_names.txt -v last_names_file=scripts/data/last_names.txt -v notes_file=scripts/data/notes.txt -f scripts/seed-large.sql
  printf '[4/4] rebuilding read model rollups...\n'
  psql -d "$db" -f scripts/rebuild-dashboard-read-models.sql
  printf '\nSetup complete.\n'
}

_bigm_index() {
  local db="$1" label="$2" sql="$3"
  printf '  [bigm] %s ... ' "$label"
  psql -d "$db" -c "$sql" &
  local bg=$! dots=0 pct
  while kill -0 "$bg" 2>/dev/null; do
    sleep 3
    pct=$(psql -d "$db" -Atqc \
      "SELECT COALESCE(ROUND(100*blocks_done::numeric/NULLIF(blocks_total,0)),0) FROM pg_stat_progress_create_index WHERE relid=(SELECT oid FROM pg_class WHERE relname IN ('orders','customers') LIMIT 1) LIMIT 1" \
      2>/dev/null || true)
    if [[ -n "$pct" && "$pct" != "0" ]]; then
      printf '\r  [bigm] %s ... %s%%   ' "$label" "$pct"
    else
      dots=$(( (dots+1) % 4 ))
      printf '\r  [bigm] %s ... %s   ' "$label" "$(printf '%0.s.' $(seq 1 $((dots+1))))"
    fi
  done
  wait "$bg" && printf '\r  [bigm] %s ... done        \n' "$label" \
    || { printf '\r  [bigm] %s ... FAILED\n' "$label"; return 1; }
}

_local_ensure_bigm_indexes() {
  local db="$1"
  psql -d "$db" -Atqc "SELECT 1 FROM pg_available_extensions WHERE name='pg_bigm'" 2>/dev/null | grep -q 1 || return 0
  local count
  count=$(psql -d "$db" -Atqc \
    "SELECT COUNT(*) FROM pg_indexes WHERE indexname IN ('idx_orders_search_text_bigm','idx_orders_notes_bigm','idx_customers_bigm')" \
    2>/dev/null || echo 0)
  [[ "$count" -ge 3 ]] && { printf '  %-18s %s\n' "pg_bigm indexes" "already in place"; return 0; }
  printf '\n=== building pg_bigm indexes (one-time) ===\n'
  psql -d "$db" -c "CREATE EXTENSION IF NOT EXISTS pg_bigm;" 2>/dev/null
  _bigm_index "$db" "idx_orders_search_text_bigm" \
    "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_search_text_bigm ON orders USING gin (search_text gin_bigm_ops);"
  _bigm_index "$db" "idx_orders_notes_bigm" \
    "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_notes_bigm ON orders USING gin (notes gin_bigm_ops);"
  _bigm_index "$db" "idx_customers_bigm" \
    "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_customers_bigm ON customers USING gin ((\"firstName\"||' '||\"lastName\"||' '||email) gin_bigm_ops);"
  psql -d "$db" -c "DROP INDEX IF EXISTS idx_orders_search_text_trgm;" 2>/dev/null
  psql -d "$db" -c "DROP INDEX IF EXISTS idx_orders_notes_trgm;" 2>/dev/null
  psql -d "$db" -c "DROP INDEX IF EXISTS idx_customers_trgm;" 2>/dev/null
  printf '  pg_bigm indexes ready.\n'
}

_local_start_backend() {
  local db_url="$1" log="$ROOT_DIR/backend.log"
  printf '\n=== starting backend :8080 ===\n'
  "$ROOT_DIR/scripts/free-port.sh" 8080
  DATABASE_URL="$db_url" \
    TYPESENSE_ENABLED="${USE_TYPESENSE}" \
    TYPESENSE_URL="${TYPESENSE_URL}" \
    TYPESENSE_API_KEY="${TYPESENSE_API_KEY}" \
    TYPESENSE_SEARCH_KEY="${TYPESENSE_SEARCH_KEY:-${TYPESENSE_API_KEY}}" \
    FULLTEXT_SEARCH_ENABLED="${USE_FULLTEXT}" \
    ./gradlew bootRun > "$log" 2>&1 &
  BACKEND_PID=$!
  printf '  PID %s — log: %s\n' "$BACKEND_PID" "$log"
  for _i in $(seq 1 60); do
    sleep 2
    lsof -ti:8080 >/dev/null 2>&1 && break
    kill -0 "$BACKEND_PID" 2>/dev/null || { printf '\n  backend exited — check %s\n' "$log"; tail -30 "$log"; exit 1; }
  done
  printf '  backend ready\n'
}

_local_start_frontend() {
  local fe_dir="$ROOT_DIR/../dashboard-frontend"
  if [[ ! -d "$fe_dir" ]]; then
    printf '\n  dashboard-frontend not found — backend only\n'
    wait "$BACKEND_PID"
    return
  fi
  printf '\n=== starting frontend :3006 ===\n'
  cd "$fe_dir"
  npm install --prefer-offline 2>/dev/null || npm install
  "$fe_dir/scripts/free-port.sh" 3006
  printf '  http://localhost:3006\n'
  BACKEND_URL="http://localhost:8080" npm run dev
}
