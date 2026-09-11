#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── Globals ───────────────────────────────────────────────────────────────────
_STEP="startup"
_on_exit() { local c=$?; [[ $c -ne 0 ]] && printf '\n[deploy.sh] ABORTED (exit %d) at step: %s\n' "$c" "$_STEP" >&2; }
trap _on_exit EXIT

_TARGET=""
DEPLOY_MODE=""
DEPLOY_MODE_PREFIX=""
BACKEND_RUNTIME="cr"
USE_NEON="true"
NEON_DATABASE_URL=""
GCP_PROJECT=""
GCP_REGION="us-central1"
IMAGE=""
BACKEND_URL=""
ACTIVE_ACCOUNT=""
BACKEND_PID=""
_GKE_NS=""
_DB_ORDERS="0"
_CP=0
_CF=0
_local_running=0
_lite_count=0
_full_count=0
DEMO_SNAPSHOT_GCS_URI=""
BAKE_VM_NAME=""
BAKE_VM_NETWORK=""
BAKE_VM_SUBNET=""
BAKE_SECRET_NAME=""
S3_SOURCE_URI=""
_GCS_BASENAME=""

# ── Utility ───────────────────────────────────────────────────────────────────

_pulumi_stack_count() {
  local stack="$1"
  ( cd "$ROOT_DIR/infra" 2>/dev/null && \
    pulumi stack ls --json 2>/dev/null | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
    for s in data:
        if s.get('name')=='$stack':
            print(s.get('resourceCount',0))
            sys.exit(0)
    print(0)
except Exception:
    print(0)
" 2>/dev/null ) || printf '0'
}

_shasum() { shasum -a 256 "$@" 2>/dev/null || sha256sum "$@" 2>/dev/null; }

_chk() {
  local n="$1" label="$2" ok="$3" detail="${4:-}"
  if [[ "$ok" == "1" ]]; then
    printf '  [%s] PASS  %s%s\n' "$n" "$label" "${detail:+  ($detail)}"
    _CP=$(( _CP + 1 ))
  else
    printf '  [%s] FAIL  %s%s\n' "$n" "$label" "${detail:+  — $detail}"
    _CF=$(( _CF + 1 ))
  fi
}

# ── Preflight ─────────────────────────────────────────────────────────────────

_run_preflight() {
  lsof -ti:8080 >/dev/null 2>&1 && _local_running=1 || true
  if command -v pulumi >/dev/null 2>&1 && pulumi whoami >/dev/null 2>&1; then
    _lite_count=$(_pulumi_stack_count lite)
    _full_count=$(_pulumi_stack_count full)
  fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────

_prompt_menu() {
  printf '\n=== springboot-dashboard-backend-gcp ===\n\n'
  printf '  [1] Local  — Spring Boot on localhost + local Postgres (no GCP cost)'
  (( _local_running )) && printf ' [running]' || printf ' [not detected]'
  printf '\n'
  printf '  [2] Lite   — GCP: 100k-row dataset · Cloud Run backend · Neon or GCE Postgres'
  (( _lite_count > 0 )) && printf ' [%s resources active]' "$_lite_count" || printf ' [not deployed]'
  printf '\n'
  printf '  [3] Full   — GCP: 4M-row dataset  · Cloud Run backend · Neon or GCE Postgres'
  (( _full_count > 0 )) && printf ' [%s resources active]' "$_full_count" || printf ' [not deployed]'
  printf '\n'
  printf '               Neon recommended for DB (~$0/mo free tier, prompted after selection).\n'
  printf '\nChoice [1/2/3, default 2]: '
  read -r _MODE
  case "${_MODE:-2}" in
    2) _TARGET="remote"; DEPLOY_MODE="lite" ;;
    3) _TARGET="remote"; DEPLOY_MODE="full" ;;
    *) _TARGET="local";  DEPLOY_MODE=""    ;;
  esac
}

_prompt_backend_runtime() {
  [[ "$_TARGET" != "remote" ]] && return 0
  local existing
  existing=$(python3 -c "
import re, sys
try:
    content = open('$ROOT_DIR/infra/Pulumi.${DEPLOY_MODE}.yaml').read()
    m = re.search(r'backendRuntime:\s*(\S+)', content)
    print(m.group(1) if m else 'cr')
except Exception:
    print('cr')
" 2>/dev/null || echo "cr")
  if [[ "$existing" == "gke" ]]; then
    printf '\n  Backend: currently GKE (~$22/mo). Switch to Cloud Run (scales to zero)? [y/N]: '
    read -r _BR
    case "${_BR:-N}" in
      [Yy]*) BACKEND_RUNTIME="cr"  ;;
      *)     BACKEND_RUNTIME="gke" ;;
    esac
  else
    printf '\n  Backend: Cloud Run (serverless, scales to zero). Use GKE instead (~$22/mo)? [y/N]: '
    read -r _BR
    case "${_BR:-N}" in
      [Yy]*) BACKEND_RUNTIME="gke" ;;
      *)     BACKEND_RUNTIME="cr"  ;;
    esac
  fi
}

_prompt_database_backend() {
  [[ "$_TARGET" != "remote" ]] && return 0

  local env_file="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  local saved_neon_url="" saved_use_neon=""
  if [[ -f "$env_file" ]]; then
    saved_use_neon=$(grep -E '^USE_NEON=' "$env_file" | cut -d= -f2- | tr -d '"' || true)
    saved_neon_url=$(grep -E '^NEON_DATABASE_URL=' "$env_file" | cut -d= -f2- | tr -d '"' || true)
  fi

  if [[ -n "$saved_use_neon" ]]; then
    USE_NEON="$saved_use_neon"
    NEON_DATABASE_URL="$saved_neon_url"
    local db_label
    if [[ "$USE_NEON" == "true" ]]; then
      db_label="Neon (${NEON_DATABASE_URL:0:40}...)"
    else
      db_label="GCE Postgres VM"
    fi
    printf '\n  Database: %s  [cached — using saved URL]\n' "$db_label"
    printf '  Replace? [y/N]: '
    read -r _REPLACE
    case "${_REPLACE:-N}" in
      [Yy]*)
        printf '  Enter new Neon DATABASE_URL\n  > '
        read -r _NEW_URL
        if [[ -n "$_NEW_URL" ]]; then
          NEON_DATABASE_URL="$_NEW_URL"
          USE_NEON="true"
        fi
        ;;
    esac
    return 0
  fi

  printf '\n  Database backend:\n'
  printf '  [Y] Neon serverless Postgres  — free tier, auto-suspends when idle (~$0/mo)\n'
  printf '  [N] GCE Postgres VM           — always-on, ~$52/mo at current GCP rates\n'
  printf '\nUse Neon? [Y/n]: '
  read -r _NEON
  case "${_NEON:-Y}" in
    [Nn]*) USE_NEON="false" ;;
    *)     USE_NEON="true"  ;;
  esac
  if [[ "$USE_NEON" == "true" ]]; then
    printf '  Enter your Neon DATABASE_URL\n'
    printf '  (postgresql://user:pass@ep-xxx.neon.tech/dbname?sslmode=require):\n  > '
    read -r NEON_DATABASE_URL
    [[ -n "$NEON_DATABASE_URL" ]] || { printf 'Neon URL is required.\n'; exit 1; }
  fi
}

_print_cost_summary() {
  [[ "$_TARGET" != "remote" ]] && return 0
  if [[ "$DEPLOY_MODE" == "lite" ]]; then
    printf '\n--- Lite GCP summary ---\n'
    if [[ "$USE_NEON" == "true" ]]; then
      printf '  Backend:    Cloud Run · scale-to-zero\n'
      printf '  DB:         Neon serverless Postgres (~$0/mo)\n'
      printf '  Cost est:   ~$0-2/mo\n'
    elif [[ "$BACKEND_RUNTIME" == "gke" ]]; then
      printf '  Backend:    GKE (e2-standard-2 node, always-on)\n'
      printf '  DB:         e2-standard-2 Postgres VM, 20 GB SSD (~$52/mo)\n'
      printf '  Cost est:   ~$66/mo\n'
    else
      printf '  Backend:    Cloud Run · scale-to-zero\n'
      printf '  DB:         e2-standard-2 Postgres VM, 20 GB SSD (~$52/mo)\n'
      printf '  Cost est:   ~$52/mo\n'
    fi
  else
    printf '\n'
    printf '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    printf '  !!                                                        !!\n'
    if [[ "$USE_NEON" == "true" ]]; then
      printf '  !!   FULL MODE — 4M rows, Cloud Run + Neon               !!\n'
      printf '  !!                                                        !!\n'
      printf '  !!   Backend:  Cloud Run (min-instances: 0)              !!\n'
      printf '  !!   DB:       Neon serverless Postgres (~$0/mo)         !!\n'
      printf '  !!   Cost est: ~$1-3/mo (Cloud Run only, Neon free tier) !!\n'
    elif [[ "$BACKEND_RUNTIME" == "gke" ]]; then
      printf '  !!   FULL MODE — EXPENSIVE, TEAR DOWN WHEN DONE          !!\n'
      printf '  !!                                                        !!\n'
      printf '  !!   Backend:  GKE (e2-standard-2 node, always-on)       !!\n'
      printf '  !!   DB:       n2-standard-4 Postgres VM (4 vCPU, 16 GB) !!\n'
      printf '  !!   Cost est: ~$200-300/mo                              !!\n'
    else
      printf '  !!   FULL MODE — EXPENSIVE, TEAR DOWN WHEN DONE          !!\n'
      printf '  !!                                                        !!\n'
      printf '  !!   Backend:  Cloud Run (min-instances: 0)              !!\n'
      printf '  !!   DB:       n2-standard-4 Postgres VM (4 vCPU, 16 GB) !!\n'
      printf '  !!   Cost est: ~$52/mo (GCE VM always-on)               !!\n'
    fi
    printf '  !!                                                        !!\n'
    printf '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    if [[ "$USE_NEON" != "true" ]]; then
      printf '\n  Type YES to continue with full deploy: '
      read -r _FULL_CONFIRM
      [[ "$_FULL_CONFIRM" == "YES" ]] || { printf 'Aborted.\n'; exit 0; }
    fi
  fi
}

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
  psql -d "$db" -v orders="$orders" -f scripts/seed-large.sql
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
  DATABASE_URL="$db_url" ./gradlew bootRun > "$log" 2>&1 &
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

# ── GCP auth / config ─────────────────────────────────────────────────────────

_check_gcloud() {
  if ! command -v gcloud >/dev/null 2>&1; then
    printf '\ngcloud CLI not found.\n'
    if command -v brew >/dev/null 2>&1; then
      brew install --cask google-cloud-sdk
      source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" 2>/dev/null || true
    else
      printf 'Install: https://cloud.google.com/sdk/docs/install\n'; exit 1
    fi
  fi
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
  if [[ -z "$ACTIVE_ACCOUNT" ]]; then
    printf '\nNot authenticated — logging in...\n'
    gcloud auth login
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
    [[ -n "$ACTIVE_ACCOUNT" ]] || { printf 'Login failed.\n' >&2; exit 1; }
  fi
  printf '\nAuthenticated as: %s\n' "$ACTIVE_ACCOUNT"
}

_resolve_gcp_config() {
  local env_file="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  [[ -f "$env_file" ]] && source "$env_file"
  local cfg_project cfg_region
  cfg_project=$(gcloud config get-value project 2>/dev/null || true)
  GCP_PROJECT="${cfg_project:-${GCP_PROJECT:-}}"
  [[ -n "$GCP_PROJECT" ]] || {
    printf '\nNo GCP project detected.\n' >&2
    printf 'Run: gcloud config set project <id>  (or set GCP_PROJECT in %s)\n' "$env_file" >&2
    exit 1
  }
  cfg_region=$(gcloud config get-value compute/region 2>/dev/null || true)
  GCP_REGION="${cfg_region:-${GCP_REGION:-us-central1}}"
  printf '\n=== deployment config ===\n'
  printf '  Project: %s\n  Region:  %s\n' "$GCP_PROJECT" "$GCP_REGION"
}

# ── Image build ───────────────────────────────────────────────────────────────

_cloudbuild_submit() {
  local tag="$1" project="$2" srcdir="$3"
  gcloud services enable cloudbuild.googleapis.com --project "$project"
  local role
  role=$(gcloud projects get-iam-policy "$project" \
    --flatten="bindings[].members" \
    --filter="bindings.members:user:${ACTIVE_ACCOUNT} AND (bindings.role:roles/cloudbuild OR bindings.role:roles/owner OR bindings.role:roles/editor)" \
    --format="value(bindings.role)" 2>/dev/null | head -1 || true)
  if [[ -z "$role" ]]; then
    printf '  Granting Cloud Build Editor to %s...\n' "$ACTIVE_ACCOUNT"
    gcloud projects add-iam-policy-binding "$project" \
      --member="user:${ACTIVE_ACCOUNT}" --role="roles/cloudbuild.builds.editor" --quiet
  fi
  local attempt=0 rc
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    set +e; gcloud builds submit --tag "$tag" --project "$project" "$srcdir"; rc=$?; set -e
    [[ "$rc" == "0" ]] && return 0
    [[ "$rc" == "130" ]] && { printf '\n[deploy] Build cancelled.\n'; exit 130; }
    (( attempt < 3 )) && { printf '  Cloud Build failed (attempt %d/3) — waiting 20s...\n' "$attempt"; sleep 20; }
  done
  printf '[deploy] Cloud Build failed after 3 attempts.\n' >&2; return 1
}

_resolve_image() {
  printf '  Checking Artifact Registry API...\n'
  local ar_state
  ar_state=$(gcloud services list --project="$GCP_PROJECT" \
    --filter="name:artifactregistry.googleapis.com" --format="value(state)" 2>/dev/null || true)
  [[ "$ar_state" != "ENABLED" ]] && gcloud services enable artifactregistry.googleapis.com --project="$GCP_PROJECT"

  printf '  Resolving Artifact Registry repo...\n'
  local listed registry
  listed=$(gcloud artifacts repositories list --project="$GCP_PROJECT" \
    --location="$GCP_REGION" --format="value(name)" 2>/dev/null | head -1 || true)
  listed="${listed##*/}"
  registry="${listed:-${ARTIFACT_REGISTRY:-${GCP_PROJECT}-gradle}}"

  if ! gcloud artifacts repositories describe "$registry" \
      --project="$GCP_PROJECT" --location="$GCP_REGION" >/dev/null 2>&1; then
    printf '  Creating repo "%s"...\n' "$registry"
    gcloud artifacts repositories create "$registry" \
      --repository-format=docker --location="$GCP_REGION" --project="$GCP_PROJECT"
  fi

  local tag
  tag=$(find "$ROOT_DIR/src" "$ROOT_DIR/Dockerfile" \
      "$ROOT_DIR/build.gradle.kts" "$ROOT_DIR/settings.gradle.kts" \
      -type f 2>/dev/null | sort | xargs cat 2>/dev/null \
    | _shasum | cut -c1-16 || true)
  tag="${tag:-$(date +%Y%m%d%H%M%S)}"
  IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${registry}/backend:${tag}"

  printf '  Checking if image %s exists...\n' "$tag"
  local exists
  exists=$(gcloud artifacts docker tags list \
    "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${registry}/backend" \
    --filter="tag=${tag}" --format="value(tag)" \
    --project "$GCP_PROJECT" 2>/dev/null | head -1 || true)

  if [[ -n "$exists" ]]; then
    printf '  Image already exists — skipping build.\n'; return 0
  fi

  printf '\nBuilding and pushing:\n  %s\n' "$IMAGE"
  if docker info >/dev/null 2>&1; then
    printf '[1/3] configuring docker auth...\n'
    gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
    printf '[2/3] building image...\n'
    docker build --platform linux/amd64 -t "$IMAGE" "$ROOT_DIR"
    printf '[3/3] pushing image...\n'
    docker push "$IMAGE"
  else
    printf 'Docker not available — building via Cloud Build...\n'
    _cloudbuild_submit "$IMAGE" "$GCP_PROJECT" "$ROOT_DIR"
  fi
}

_check_adc() {
  printf '  Checking Application Default Credentials...\n'
  gcloud auth application-default print-access-token >/dev/null 2>&1 && return 0
  printf '  Setting up ADC (required by Pulumi GCP provider)...\n'
  gcloud auth application-default login
}

# ── Pulumi deploy ─────────────────────────────────────────────────────────────

_pulumi_up_robust() {
  local log_file attempt=0 rc
  log_file="$(mktemp)"

  while (( attempt < 5 )); do
    attempt=$(( attempt + 1 ))
    set +e; pulumi up --yes 2>&1 | tee "$log_file"; rc="${PIPESTATUS[0]}"; set -e
    [[ "$rc" == "0" ]] && { rm -f "$log_file"; return 0; }

    local conflicts
    conflicts=$(python3 - "${log_file}" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
lines = content.split('\n')
seen = set()
for i, line in enumerate(lines):
    m = re.match(r'\s+(gcp:[^(]+)\(([^)]+)\):', line)
    if m:
        type_display = m.group(1).strip()
        logical_name = m.group(2).strip()
        for j in range(i, min(i+8, len(lines))):
            id_m = re.search(r"'([^']+)' already exists", lines[j])
            if not id_m:
                cm = re.search(r'failed to create \w+ ([^:\s]+):', lines[j])
                if cm and re.search(r'already exists|instanceAlreadyExists', lines[j]):
                    id_m = cm
            if id_m:
                key = f'{type_display}|{logical_name}|{id_m.group(1)}'
                if key not in seen:
                    seen.add(key)
                    print(key)
                break
PYEOF
2>/dev/null || true)

    if [[ -z "$conflicts" ]]; then
      _pulumi_handle_errors "$log_file" && continue || break
    fi

    printf '[deploy] Auto-importing conflicting resources (attempt %d)...\n' "$attempt"
    _pulumi_import_conflicts "$conflicts"
  done

  rm -f "$log_file"
  printf '[deploy] pulumi up failed after %d attempts.\n' "$attempt" >&2
  return 1
}

_pulumi_handle_errors() {
  local log_file="$1"

  local drift_names
  drift_names=$(python3 - "${log_file}" <<'PYEOF'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
seen = set()
for i, line in enumerate(lines):
    if re.search(r'(Error 404|does not exist)', line) and \
       re.search(r'(Error updating|updating failed)', line):
        for j in range(max(0, i - 5), i + 1):
            m = re.match(r'\s+~\s+\S+\s+(\S+)\s+updating\b', lines[j])
            if m and m.group(1) not in seen:
                seen.add(m.group(1)); print(m.group(1)); break
PYEOF
2>/dev/null || true)
  if [[ -n "$drift_names" ]]; then
    printf '[deploy] State drift — removing stale entries...\n'
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local urn
      urn=$(pulumi stack export 2>/dev/null | python3 -c "
import sys, json
name = sys.argv[1]
for r in json.load(sys.stdin).get('deployment',{}).get('resources',[]):
    urn = r.get('urn','')
    if urn.split('::')[-1] == name: print(urn); break
" "$name" 2>/dev/null || true)
      [[ -n "$urn" ]] && pulumi state delete "$urn" --yes --target-dependents 2>/dev/null || true
    done <<< "$drift_names"
    return 0
  fi

  local del_urns
  del_urns=$(grep -oE 'error: deleting urn:pulumi:[^ ]+' "$log_file" \
    | sed 's/^error: deleting //; s/:$//' | sort -u || true)
  if [[ -n "$del_urns" ]]; then
    printf '[deploy] Purging stale state entries...\n'
    while IFS= read -r urn; do
      [[ -z "$urn" ]] && continue
      pulumi state delete "$urn" --yes 2>/dev/null || true
    done <<< "$del_urns"
    return 0
  fi

  local prot_urns
  prot_urns=$(grep -oE "urn:pulumi:[^ \"']+" "$log_file" | tr -d '"' | grep -v '^$' | sort -u || true)
  if grep -q 'cannot be deleted' "$log_file" 2>/dev/null && [[ -n "$prot_urns" ]]; then
    printf '[deploy] Unprotecting stale protected resources...\n'
    while IFS= read -r urn; do
      [[ -z "$urn" ]] && continue
      pulumi state unprotect "$urn" --yes 2>/dev/null || true
      pulumi state delete "$urn" --yes 2>/dev/null || true
    done <<< "$prot_urns"
    return 0
  fi

  if grep -qE 'Error waiting for Create Instance' "$log_file" 2>/dev/null; then
    local pending
    pending=$(gcloud sql instances list --project "$GCP_PROJECT" \
      --filter="state=PENDING_CREATE" --format="value(name)" 2>/dev/null || true)
    if [[ -n "$pending" ]]; then
      printf '[deploy] GCE instance creating (%s) — waiting...\n' "$pending"
      local w=0
      while (( w < 30 )); do
        w=$(( w + 1 )); sleep 30
        pending=$(gcloud sql instances list --project "$GCP_PROJECT" \
          --filter="state=PENDING_CREATE" --format="value(name)" 2>/dev/null || true)
        [[ -z "$pending" ]] && break
        printf '  still creating... (%d/30)\n' "$w"
      done
      return 0
    fi
  fi

  if grep -qE "secrets/[^/]+/versions/latest was not found" "$log_file" 2>/dev/null; then
    local missing_secret
    missing_secret=$(grep -oE "secrets/[^/]+/versions/latest" "$log_file" \
      | head -1 | cut -d/ -f2)
    if [[ -n "$missing_secret" && -n "${NEON_DATABASE_URL:-}" ]]; then
      printf '[deploy] Secret %s has no live version — adding Neon URL and retrying...\n' "$missing_secret" >&2
      printf '%s' "$NEON_DATABASE_URL" | gcloud secrets versions add "$missing_secret" \
        --data-file=- --project="$GCP_PROJECT"
      return 0
    fi
  fi

  printf '\n[deploy] pulumi up failed — actual errors:\n' >&2
  grep -E 'error:|Error|failed|FAIL' "$log_file" | head -20 >&2 || true
  if grep -q 'cloudrunv2\|Cloud Run\|container failed to start' "$log_file" 2>/dev/null; then
    local svc="${DEPLOY_MODE_PREFIX:-dash-lite}-backend"
    printf '\n[deploy] Cloud Run failure — fetching container logs for %s:\n' "$svc" >&2
    gcloud run services logs read "$svc" \
      --region "${GCP_REGION:-us-central1}" --project "${GCP_PROJECT}" --limit 60 2>/dev/null \
      | grep -v '^WARNING' \
      | grep -E 'ERROR|WARN|Exception|Caused by|Error|FATAL|started|Failed|refused|denied' \
      | tail -40 >&2 || true
    printf '\n[deploy] Full logs: gcloud run services logs read %s --region %s --project %s --limit 100\n' \
      "$svc" "${GCP_REGION:-us-central1}" "${GCP_PROJECT}" >&2
  fi
  return 1
}

_pulumi_import_conflicts() {
  local conflicts="$1"
  while IFS='|' read -r type_display logical_name gcp_id; do
    [[ -z "$type_display" ]] && continue
    local module type_name import_type import_id
    module=$(printf '%s' "$type_display" | cut -d: -f2)
    type_name=$(printf '%s' "$type_display" | cut -d: -f3)
    import_type="gcp:${module}/${type_name,}:${type_name}"
    import_id="$gcp_id"
    if [[ "$module" == "cloudrunv2" && "${type_name,,}" == "service" && "$import_id" != projects/* ]]; then
      import_id="projects/${GCP_PROJECT}/locations/${GCP_REGION}/services/${import_id}"
    fi
    printf '  importing: %s %s = %s\n' "$import_type" "$logical_name" "$import_id"
    pulumi import "$import_type" "$logical_name" "$import_id" --yes 2>/dev/null || true
  done <<< "$conflicts"
}

_write_pulumi_yaml() {
  if [[ "$DEPLOY_MODE" == "lite" ]]; then
    cat > "Pulumi.${DEPLOY_MODE}.yaml" <<PYAML
config:
  gcp:project: ${GCP_PROJECT}
  gcp:region: ${GCP_REGION}
  dashboard:namePrefix: dash-lite
  dashboard:dbVmType: e2-standard-2
  dashboard:dbDiskGb: "20"
  dashboard:backendImage: ${IMAGE}
  dashboard:backendRuntime: ${BACKEND_RUNTIME}
  dashboard:useNeon: ${USE_NEON}
PYAML
  else
    cat > "Pulumi.${DEPLOY_MODE}.yaml" <<PYAML
config:
  gcp:project: ${GCP_PROJECT}
  gcp:region: ${GCP_REGION}
  dashboard:namePrefix: dash-full
  dashboard:dbVmType: n2-standard-4
  dashboard:dbDiskGb: "35"
  dashboard:backendImage: ${IMAGE}
  dashboard:backendRuntime: ${BACKEND_RUNTIME}
  dashboard:useNeon: ${USE_NEON}
PYAML
  fi
}

_ensure_neon_secret_version() {
  [[ "$USE_NEON" != "true" ]] && return 0
  local secret_name="${DEPLOY_MODE_PREFIX}-database-url"

  # Secret may not exist yet on first deploy — pulumi up will create it with the version
  gcloud secrets describe "$secret_name" --project="$GCP_PROJECT" >/dev/null 2>&1 || {
    printf '  Neon secret not yet created — pulumi up will provision it.\n'; return 0
  }

  # If latest version already exists, Cloud Run can mount it — nothing to do
  local existing
  if existing=$(gcloud secrets versions access latest \
    --secret="$secret_name" --project="$GCP_PROJECT" 2>/dev/null) && [[ -n "$existing" ]]; then
    printf '  Neon secret version present.\n'; return 0
  fi

  # Secret exists but has no versions (state drift from GCE→Neon switch or failed prior run)
  # Add the version directly so Cloud Run can mount it before pulumi up touches the service
  printf '  Secret has no versions (state drift) — adding Neon URL now...\n'
  printf '%s' "$NEON_DATABASE_URL" | gcloud secrets versions add "$secret_name" \
    --data-file=- --project="$GCP_PROJECT"

  # Remove stale SecretVersion from Pulumi state so it gets cleanly re-imported on this run
  local sv_urn
  sv_urn=$(pulumi stack export 2>/dev/null | python3 -c "
import sys, json
for r in json.load(sys.stdin).get('deployment',{}).get('resources',[]):
    urn = r.get('urn','')
    if 'SecretVersion' in urn and 'database-url-v1' in urn:
        print(urn); break
" 2>/dev/null || true)
  [[ -n "$sv_urn" ]] && pulumi state delete "$sv_urn" --yes 2>/dev/null || true
  printf '  Secret version restored — pulumi up will re-import.\n'
}

_deploy_pulumi() {
  printf '\n=== deploying via Pulumi ===\n'
  cd "$ROOT_DIR/infra"
  [[ -d node_modules ]] || npm install --prefer-offline 2>/dev/null || npm install
  pulumi stack select "$DEPLOY_MODE" 2>/dev/null || pulumi stack init "$DEPLOY_MODE"
  DEPLOY_MODE_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash-full')
  _write_pulumi_yaml
  if [[ "$USE_NEON" == "true" ]]; then
    printf '  Storing Neon DATABASE_URL as Pulumi config secret...\n'
    pulumi config set --secret dashboard:neonDatabaseUrl "$NEON_DATABASE_URL" --stack "$DEPLOY_MODE"
  fi
  _ensure_neon_secret_version
  _STEP="pulumi up"
  _pulumi_up_robust
}

# ── Database setup ────────────────────────────────────────────────────────────

_setup_db_post_pulumi() {
  local pg_vm="${DEPLOY_MODE_PREFIX}-pg"
  if [[ "$USE_NEON" == "true" ]]; then
    printf '\n  Neon DATABASE_URL stored in Secret Manager by Pulumi.\n'; return 0
  fi
  _STEP="db vm setup"
  printf '\n  Resetting DB VM...\n'
  gcloud compute instances reset "$pg_vm" \
    --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" --quiet || true
  printf '  DB VM reset — Postgres init takes ~3-5 min on first boot.\n'
  _wait_for_vm_ssh "$pg_vm"
  _configure_pg_network "$pg_vm"
  _sync_pg_password "$pg_vm"
}

_wait_for_vm_ssh() {
  local vm="$1"
  printf '\n  Waiting for DB VM SSH...\n'
  for _i in $(seq 1 24); do
    gcloud compute ssh "$vm" \
      --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" \
      --tunnel-through-iap --ssh-flag="-o ConnectTimeout=5" \
      --command "exit 0" >/dev/null 2>&1 && return 0
    printf '  waiting (%d/24)...\n' "$_i"; sleep 5
  done
}

_configure_pg_network() {
  local vm="$1"
  printf '  Ensuring Postgres listens on VPC...\n'
  gcloud compute ssh "$vm" \
    --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" \
    --tunnel-through-iap --ssh-flag="-o ConnectTimeout=10" \
    --command "
      PG_CONF=/etc/postgresql/16/main/postgresql.conf
      PG_HBA=/etc/postgresql/16/main/pg_hba.conf
      CHANGED=0
      if ! sudo grep -q '^listen_addresses' \"\$PG_CONF\" 2>/dev/null; then
        sudo sed -i \"s/#listen_addresses = 'localhost'/listen_addresses = '*'/\" \"\$PG_CONF\"
        CHANGED=1
      fi
      if ! sudo grep -q '10.0.0.0/8' \"\$PG_HBA\" 2>/dev/null; then
        printf 'host all all 10.0.0.0/8 scram-sha-256\n' | sudo tee -a \"\$PG_HBA\" >/dev/null
        CHANGED=1
      fi
      if [[ \"\$CHANGED\" == '1' ]]; then
        sudo systemctl restart postgresql@16-main
        printf '  pg config fixed and restarted.\n'
      else
        printf '  pg config already correct.\n'
      fi
    " 2>/dev/null || printf '  (pg config check skipped — SSH unavailable)\n'
}

_sync_pg_password() {
  local vm="$1"
  printf '  Syncing Postgres password with Secret Manager...\n'
  local db_url user pass_b64
  db_url=$(gcloud secrets versions access latest \
    --secret="${DEPLOY_MODE_PREFIX}-database-url" --project="$GCP_PROJECT" 2>/dev/null || true)
  [[ -z "$db_url" ]] && { printf '  (secret not found — skipping)\n'; return 0; }
  user=$(printf '%s' "$db_url" | sed 's|.*://\([^:]*\):.*|\1|')
  pass_b64=$(printf '%s' "$db_url" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|' | base64)
  gcloud compute ssh "$vm" \
    --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" \
    --tunnel-through-iap --ssh-flag="-o ConnectTimeout=10" \
    --command "
      _P=\$(printf '%s' '${pass_b64}' | base64 -d)
      sudo -u postgres psql -c \"ALTER USER ${user} WITH PASSWORD '\$_P';\" >/dev/null 2>&1
      sudo -u postgres psql -d app -c 'CREATE EXTENSION IF NOT EXISTS pg_bigm;' >/dev/null 2>&1 || true
      printf '  password synced.\n'
    " 2>/dev/null || printf '  (password sync SSH failed)\n'
}

# ── Seed / bake ───────────────────────────────────────────────────────────────

_resolve_snapshot_vars() {
  if [[ "$DEPLOY_MODE" == "lite" ]]; then
    DEMO_SNAPSHOT_GCS_URI="gs://bikram-java-dash-snapshots/dash/demo-lite.dump"
    BAKE_VM_NAME="dash-bake-vm"
    BAKE_VM_NETWORK="dash-lite-vpc"
    BAKE_VM_SUBNET="dash-lite-subnet"
    BAKE_SECRET_NAME="dash-lite-database-url"
    S3_SOURCE_URI="s3://bikram-nextjs-subsecond-fetch-with-websockets/nextjs-dash/demo-lite.dump"
  else
    DEMO_SNAPSHOT_GCS_URI="gs://bikram-java-dash-snapshots/dash/demo.dump"
    BAKE_VM_NAME="${DEPLOY_MODE_PREFIX}-bake-vm"
    BAKE_VM_NETWORK="${DEPLOY_MODE_PREFIX}-vpc"
    BAKE_VM_SUBNET="${DEPLOY_MODE_PREFIX}-subnet"
    BAKE_SECRET_NAME="${DEPLOY_MODE_PREFIX}-database-url"
    S3_SOURCE_URI="s3://bikram-nextjs-subsecond-fetch-with-websockets/nextjs-dash/demo.dump"
  fi
  _GCS_BASENAME=$(basename "$DEMO_SNAPSHOT_GCS_URI")
}

_check_db_row_count() {
  printf '\nChecking database...\n'
  if [[ "$USE_NEON" == "true" ]]; then
    _DB_ORDERS=$(psql "$NEON_DATABASE_URL" -t -c 'SELECT COUNT(*) FROM orders;' 2>/dev/null | tr -d ' \n' || echo "0")
  else
    _DB_ORDERS=$(gcloud compute ssh "${DEPLOY_MODE_PREFIX}-pg" \
      --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" \
      --tunnel-through-iap --ssh-flag="-o ConnectTimeout=10" \
      --command "sudo -u postgres psql -d app -t -c 'SELECT COUNT(*) FROM orders;' 2>/dev/null || echo 0" \
      2>/dev/null | tr -d ' \n' || echo "0")
  fi
  [[ "${_DB_ORDERS:-0}" =~ ^[0-9]+$ ]] || _DB_ORDERS="0"
  printf '  DB row count: %s\n' "$_DB_ORDERS"
}

_seed_db() {
  [[ "${_DB_ORDERS:-0}" -gt 0 ]] && { printf 'Database has %s orders — skipping seed.\n' "$_DB_ORDERS"; return 0; }
  printf 'Database empty — seeding...\n'
  if [[ "$USE_NEON" == "true" ]]; then
    _seed_neon
  else
    _seed_gce_bake
  fi
}

_gcs_check() {
  local token="$1"
  curl -sf \
    "https://storage.googleapis.com/storage/v1/b/bikram-java-dash-snapshots/o/dash%2F${_GCS_BASENAME}" \
    -H "Authorization: Bearer ${token}" 2>/dev/null \
    | python3 -c "import sys,json;json.load(sys.stdin);print('yes')" 2>/dev/null || printf 'no'
}

_seed_neon() {
  _STEP="db seed (neon)"
  command -v pg_restore >/dev/null 2>&1 || { printf '  pg_restore not found — brew install libpq\n'; exit 1; }
  command -v psql      >/dev/null 2>&1 || { printf '  psql not found — brew install libpq\n'; exit 1; }
  local tmp gcs_token gcs_exists
  tmp=$(mktemp /tmp/bake.XXXXXX.dump)
  gcs_token=$(gcloud auth print-access-token 2>/dev/null || true)
  gcs_exists=$(_gcs_check "$gcs_token")
  if [[ "$gcs_exists" == "yes" ]]; then
    printf '  Downloading %s from GCS...\n' "$_GCS_BASENAME"
    gsutil cp "$DEMO_SNAPSHOT_GCS_URI" "$tmp" 2>/dev/null || \
    curl -fL \
      "https://storage.googleapis.com/storage/v1/b/bikram-java-dash-snapshots/o/dash%2F${_GCS_BASENAME}?alt=media" \
      -H "Authorization: Bearer ${gcs_token}" -o "$tmp"
  else
    _download_from_s3_local "$tmp" || { rm -f "$tmp"; return 0; }
  fi
  if [[ -s "$tmp" ]]; then
    printf '  Running pg_restore against Neon...\n'
    pg_restore --no-owner --no-privileges --clean --if-exists -d "$NEON_DATABASE_URL" "$tmp" || true
    rm -f "$tmp"
    printf 'Seeding complete.\n'
  fi
}

_download_from_s3_local() {
  local tmp="$1"
  printf '  GCS snapshot not found — checking AWS credentials...\n'
  local aws_ok
  aws_ok=$(gcloud secrets versions access latest \
    --secret="dash-aws-credentials" --project="$GCP_PROJECT" >/dev/null 2>&1 && printf 'yes' || printf '')
  [[ -z "$aws_ok" ]] && { printf 'WARNING: No GCS snapshot and no AWS creds — DB will be empty.\n'; return 1; }
  local creds
  creds=$(gcloud secrets versions access latest --secret="dash-aws-credentials" --project="$GCP_PROJECT" 2>/dev/null)
  export $(printf '%s' "$creds" | grep -E '^AWS_' | xargs)
  printf '  Downloading from S3...\n'
  aws s3 cp "$S3_SOURCE_URI" "$tmp"
  printf '  Caching to GCS...\n'
  gsutil cp "$tmp" "$DEMO_SNAPSHOT_GCS_URI" 2>/dev/null || true
}

_seed_gce_bake() {
  local gcs_token gcs_exists skip=0
  gcs_token=$(gcloud auth print-access-token 2>/dev/null || true)
  gcs_exists=$(_gcs_check "$gcs_token")
  if [[ "$gcs_exists" != "yes" ]]; then
    local aws_ok
    aws_ok=$(gcloud secrets versions access latest \
      --secret="dash-aws-credentials" --project="$GCP_PROJECT" >/dev/null 2>&1 && printf 'yes' || printf '')
    if [[ -z "$aws_ok" ]]; then
      printf 'WARNING: No seed source — DB will be empty.\n'
      printf '  Add AWS creds: printf "AWS_ACCESS_KEY_ID=...\\nAWS_SECRET_ACCESS_KEY=...\\nAWS_DEFAULT_REGION=us-east-1" \\\n'
      printf '    | gcloud secrets create dash-aws-credentials --data-file=- --project=%s\n' "$GCP_PROJECT"
      skip=1
    fi
  fi
  (( skip == 1 )) && return 0
  _STEP="db bake"
  _run_bake_vm
}

_run_bake_vm() {
  printf 'Starting VM bake...\n'
  _ensure_iap_firewall
  gcloud compute networks subnets update "$BAKE_VM_SUBNET" \
    --project="$GCP_PROJECT" --region="$GCP_REGION" \
    --enable-private-ip-google-access --quiet 2>/dev/null || true
  _ensure_bake_vm
  _install_bake_vm_deps
  _exec_bake_script
  printf '  Deleting bake VM...\n'
  gcloud compute instances delete "$BAKE_VM_NAME" \
    --zone="${GCP_REGION}-a" --project="$GCP_PROJECT" --quiet
  printf 'Seeding complete.\n'
}

_ensure_iap_firewall() {
  gcloud compute firewall-rules describe "${BAKE_VM_NETWORK}-allow-iap-ssh" \
    --project="$GCP_PROJECT" >/dev/null 2>&1 && return 0
  gcloud compute firewall-rules create "${BAKE_VM_NETWORK}-allow-iap-ssh" \
    --project="$GCP_PROJECT" --network="$BAKE_VM_NETWORK" \
    --direction=INGRESS --source-ranges=35.235.240.0/20 --allow=tcp:22 --quiet
}

_ensure_bake_vm() {
  if gcloud compute instances describe "$BAKE_VM_NAME" \
      --zone="${GCP_REGION}-a" --project="$GCP_PROJECT" --format="value(name)" >/dev/null 2>&1; then
    local scopes
    scopes=$(gcloud compute instances describe "$BAKE_VM_NAME" \
      --zone="${GCP_REGION}-a" --project="$GCP_PROJECT" \
      --format="value(serviceAccounts[0].scopes)" 2>/dev/null || echo "")
    if [[ "$scopes" == *"cloud-platform"* ]]; then
      printf '  Bake VM already exists.\n'; return 0
    fi
    printf '  Bake VM missing cloud-platform scope — recreating...\n'
    gcloud compute instances delete "$BAKE_VM_NAME" \
      --zone="${GCP_REGION}-a" --project="$GCP_PROJECT" --quiet 2>/dev/null || true
  fi
  printf '  Creating bake VM...\n'
  gcloud compute instances create "$BAKE_VM_NAME" \
    --project="$GCP_PROJECT" --zone="${GCP_REGION}-a" \
    --machine-type=n2-standard-8 \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=50GB \
    --network="$BAKE_VM_NETWORK" --subnet="$BAKE_VM_SUBNET" \
    --no-address --scopes=cloud-platform --quiet
  printf '  Waiting for VM startup...\n'; sleep 30
}

_install_bake_vm_deps() {
  gcloud compute ssh "$BAKE_VM_NAME" \
    --project="$GCP_PROJECT" --zone="${GCP_REGION}-a" \
    --tunnel-through-iap --ssh-flag="-o ConnectTimeout=30" \
    --command='command -v pg_restore >/dev/null 2>&1 || (
      echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        | sudo tee /etc/apt/sources.list.d/pgdg.list &&
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg &&
      sudo apt-get update -qq &&
      sudo apt-get install -y postgresql-client-16 awscli
    )' 2>/dev/null
}

_exec_bake_script() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" << BAKE_EOF
#!/bin/bash
set -euo pipefail
PROJECT="${GCP_PROJECT}"
SECRET="${BAKE_SECRET_NAME}"
GCS_BASENAME="${_GCS_BASENAME}"
S3_URI="${S3_SOURCE_URI}"

echo "=== fetching DB URL ==="
TOKEN=\$(curl -sf http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  -H Metadata-Flavor:Google | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
DB_URL=\$(curl -sf \
  "https://secretmanager.googleapis.com/v1/projects/\${PROJECT}/secrets/\${SECRET}/versions/latest:access" \
  -H "Authorization: Bearer \${TOKEN}" \
  | python3 -c "import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)['payload']['data']).decode())")
echo "DB URL resolved."

GCS_URI="gs://bikram-java-dash-snapshots/dash/\${GCS_BASENAME}"
if gsutil -q stat "\${GCS_URI}" 2>/dev/null; then
  echo "=== restoring from GCS ==="
  gsutil cp "\${GCS_URI}" /tmp/bake.dump
else
  GCS_EXISTS=\$(curl -sf \
    "https://storage.googleapis.com/storage/v1/b/bikram-java-dash-snapshots/o/dash%2F\${GCS_BASENAME}" \
    -H "Authorization: Bearer \${TOKEN}" 2>/dev/null | python3 -c "import sys,json;print('yes')" 2>/dev/null || echo "no")
  if [[ "\$GCS_EXISTS" == "yes" ]]; then
    curl -fL \
      "https://storage.googleapis.com/storage/v1/b/bikram-java-dash-snapshots/o/dash%2F\${GCS_BASENAME}?alt=media" \
      -H "Authorization: Bearer \${TOKEN}" -o /tmp/bake.dump
  else
    AWS_CREDS=\$(curl -sf \
      "https://secretmanager.googleapis.com/v1/projects/\${PROJECT}/secrets/dash-aws-credentials/versions/latest:access" \
      -H "Authorization: Bearer \${TOKEN}" \
      | python3 -c "import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)['payload']['data']).decode())" \
      2>/dev/null || echo "")
    [[ -z "\$AWS_CREDS" ]] && { echo "=== no seed source — skipping ==="; exit 0; }
    export \$(echo "\$AWS_CREDS" | grep -E '^AWS_' | xargs)
    aws s3 cp "\$S3_URI" /tmp/bake.dump
    SAVE_TO_GCS="yes"
  fi
fi

pg_restore --no-owner --no-privileges --clean --if-exists -d "\$DB_URL" /tmp/bake.dump || true
[[ "\${SAVE_TO_GCS:-no}" == "yes" ]] && gsutil cp /tmp/bake.dump "\${GCS_URI}"
rm -f /tmp/bake.dump
echo "=== done ==="
BAKE_EOF

  gcloud compute scp "$tmp" "${BAKE_VM_NAME}:/tmp/bake.sh" \
    --project="$GCP_PROJECT" --zone="${GCP_REGION}-a" --tunnel-through-iap --quiet
  rm -f "$tmp"
  printf '  Running restore on VM...\n'
  gcloud compute ssh "$BAKE_VM_NAME" \
    --project="$GCP_PROJECT" --zone="${GCP_REGION}-a" \
    --tunnel-through-iap --ssh-flag="-o ConnectTimeout=30" \
    --command='bash /tmp/bake.sh' || \
    printf '  [WARN] Bake exited with errors — deploy continues but DB may be empty.\n'
}

# ── Post-seed tasks ───────────────────────────────────────────────────────────

_sync_daily_order_count() {
  printf '\n  Syncing daily_order_count...\n'
  local sql='INSERT INTO daily_order_count (date, "totalOrders") SELECT "placedAt"::date, COUNT(*) FROM orders GROUP BY "placedAt"::date ON CONFLICT (date) DO UPDATE SET "totalOrders" = EXCLUDED."totalOrders";'
  if [[ "$USE_NEON" == "true" ]]; then
    psql "$NEON_DATABASE_URL" -c "$sql" 2>/dev/null \
      && printf '  daily_order_count synced.\n' || printf '  (sync skipped)\n'
  else
    gcloud compute ssh "${DEPLOY_MODE_PREFIX}-pg" \
      --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" \
      --tunnel-through-iap --ssh-flag="-o ConnectTimeout=10" \
      --command "sudo -u postgres psql -d app -c \"${sql}\"" 2>/dev/null \
      && printf '  daily_order_count synced.\n' || printf '  (sync skipped — SSH unavailable)\n'
  fi
}

# ── GKE management ────────────────────────────────────────────────────────────

_scale_down_gke_if_switching() {
  [[ "$BACKEND_RUNTIME" == "gke" ]] && return 0
  local cluster="${DEPLOY_MODE_PREFIX}-cluster" zone="${GCP_REGION}-a"
  gcloud container clusters describe "$cluster" \
    --zone "$zone" --project "$GCP_PROJECT" >/dev/null 2>&1 || return 0
  printf '  Switched to Cloud Run — scaling GKE cluster %s to 0 nodes...\n' "$cluster"
  gcloud container clusters resize "$cluster" \
    --node-pool default-pool --num-nodes 0 \
    --zone "$zone" --project "$GCP_PROJECT" --quiet
  printf '  GKE preserved at 0 nodes (no node charges until next GKE deploy).\n'
}

_deploy_gke() {
  local cluster="${DEPLOY_MODE_PREFIX}-cluster" zone="${GCP_REGION}-a"
  local machine_type
  machine_type=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'e2-standard-2' || printf 'e2-standard-4')
  _GKE_NS="${DEPLOY_MODE_PREFIX}"
  gcloud services enable container.googleapis.com --project "$GCP_PROJECT" 2>/dev/null || true

  if gcloud container clusters describe "$cluster" --zone "$zone" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    local existing_type
    existing_type=$(gcloud container clusters describe "$cluster" \
      --zone "$zone" --project "$GCP_PROJECT" \
      --format="value(nodePools[0].config.machineType)" 2>/dev/null || true)
    if [[ "$existing_type" != "$machine_type" ]]; then
      printf '  GKE machine type mismatch (%s vs %s) — recreating...\n' "$existing_type" "$machine_type"
      gcloud container clusters delete "$cluster" --zone "$zone" --project "$GCP_PROJECT" --quiet
    else
      printf '  GKE cluster %s exists (%s).\n' "$cluster" "$machine_type"
      gcloud container clusters get-credentials "$cluster" --zone "$zone" --project "$GCP_PROJECT" --quiet
      local nodes
      nodes=$(gcloud container clusters describe "$cluster" --zone "$zone" --project "$GCP_PROJECT" \
        --format="value(currentNodeCount)" 2>/dev/null || echo "0")
      if [[ "${nodes:-0}" == "0" ]]; then
        printf '  Scaling up to 1 node...\n'
        gcloud container clusters resize "$cluster" \
          --node-pool default-pool --num-nodes 1 --zone "$zone" --project "$GCP_PROJECT" --quiet
        printf '  Waiting ~60s for readiness...\n'; sleep 60
      fi
    fi
  fi

  if ! gcloud container clusters describe "$cluster" --zone "$zone" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    printf '\n  Creating GKE cluster %s (%s)...\n' "$cluster" "$machine_type"
    gcloud container clusters create "$cluster" \
      --zone "$zone" --project "$GCP_PROJECT" \
      --machine-type "$machine_type" --num-nodes 1 \
      --network "${DEPLOY_MODE_PREFIX}-vpc" --subnetwork "${DEPLOY_MODE_PREFIX}-subnet" --quiet
  fi

  _STEP="gke deploy"
  local threshold=60; [[ "$DEPLOY_MODE" == "full" ]] && threshold=200
  printf '\n  Deploying to GKE via Cloud Build...\n'
  printf '  Tail logs: kubectl logs -n %s -l app=%s-backend -f --tail=50\n\n' "$_GKE_NS" "$_GKE_NS"
  gcloud builds submit --config "${ROOT_DIR}/cloudbuild-gke.yaml" \
    --project "$GCP_PROJECT" \
    --substitutions "_IMAGE=${IMAGE},_CLUSTER=${cluster},_ZONE=${zone},_NAMESPACE=${_GKE_NS},_STARTUP_THRESHOLD=${threshold}" \
    "${ROOT_DIR}/k8s"

  printf '  Waiting for LoadBalancer IP...\n'
  gcloud container clusters get-credentials "$cluster" --zone "$zone" --project "$GCP_PROJECT" --quiet
  BACKEND_URL=""
  for _i in $(seq 1 60); do
    local ip
    ip=$(kubectl get svc "${_GKE_NS}-backend" -n "$_GKE_NS" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$ip" ]] && { BACKEND_URL="http://${ip}"; break; }
    printf '  waiting for LoadBalancer (%d/60)...\n' "$_i"; sleep 10
  done
}

# ── Post-deploy wiring ────────────────────────────────────────────────────────

_patch_frontend_backend_url() {
  [[ "$BACKEND_RUNTIME" == "gke" ]] && return 0
  [[ -z "$BACKEND_URL" ]] && return 0
  local fe_svc="${DEPLOY_MODE_PREFIX}-frontend"
  printf '  Checking frontend BACKEND_URL env...\n'
  local current
  current=$(gcloud run services describe "$fe_svc" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" --format="json" 2>/dev/null \
    | python3 -c "
import sys,json
try:
  svc=json.load(sys.stdin)
  for e in svc.get('template',{}).get('containers',[{}])[0].get('env',[]):
    if e.get('name')=='BACKEND_URL': print(e.get('value','')); break
except Exception: pass
" 2>/dev/null || true)
  if [[ -n "$current" && "$current" != "$BACKEND_URL" ]]; then
    printf '  Stale BACKEND_URL (%s) — patching to %s\n' "$current" "$BACKEND_URL"
    gcloud run services update "$fe_svc" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" \
      --update-env-vars "BACKEND_URL=${BACKEND_URL}" --quiet 2>/dev/null || true
  else
    printf '  Frontend BACKEND_URL OK (%s).\n' "${current:-not yet deployed}"
  fi
}

_save_env_file() {
  local env_file="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  cat > "$env_file" <<EOF
DB_VM_IP=$(pulumi stack output dbVmInternalIp 2>/dev/null || true)
ARTIFACT_REGISTRY=$(pulumi stack output artifactRegistry 2>/dev/null || true)
CLOUD_RUN_URL=${BACKEND_URL}
GCP_PROJECT=${GCP_PROJECT}
GCP_REGION=${GCP_REGION}
USE_NEON=${USE_NEON}
NEON_DATABASE_URL=${NEON_DATABASE_URL}
EOF
}

_update_readme() {
  local fe_url
  fe_url=$(gcloud run services describe "${DEPLOY_MODE_PREFIX}-frontend" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(status.url)" 2>/dev/null || true)
  [[ -z "$BACKEND_URL" && -z "$fe_url" ]] && return 0
  python3 - "${ROOT_DIR}/README.md" "${BACKEND_URL:-}" "${fe_url:-}" <<'PYEOF'
import re, sys
path, backend, frontend = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()
if backend:
    content = re.sub(r'(\| \*\*Backend API[^|]*\| )https?://\S+( \|)', rf'\g<1>{backend}\g<2>', content)
if frontend:
    content = re.sub(r'(\| \*\*App\*\* \| )https?://\S+( \|)', rf'\g<1>{frontend}\g<2>', content)
    content = re.sub(r'^(BASE=https?://\S+)', f'BASE={frontend}', content, flags=re.MULTILINE)
open(path, 'w').write(content)
PYEOF
  if ! git -C "$ROOT_DIR" diff --quiet README.md 2>/dev/null; then
    git -C "$ROOT_DIR" add README.md
    git -C "$ROOT_DIR" commit -m "update live URLs: backend=${BACKEND_URL} frontend=${fe_url}"
    git -C "$ROOT_DIR" push origin main
  fi
}

_deploy_frontend_inline() {
  local fe_deploy="${ROOT_DIR}/../dashboard-frontend/scripts/deploy.sh"
  [[ -f "$fe_deploy" ]] || return 0
  _STEP="frontend deploy"
  printf '\n  Deploying frontend inline...\n'
  DEPLOY_MODE="$DEPLOY_MODE" bash "$fe_deploy"
}

# ── Post-deploy checks ────────────────────────────────────────────────────────

_post_deploy_checks() {
  [[ "$_TARGET" != "remote" ]] && return 0
  printf '\n=== post-deploy checks ===\n'
  _CP=0; _CF=0

  if [[ "$USE_NEON" == "true" ]]; then
    local neon_ok
    neon_ok=$(psql "$NEON_DATABASE_URL" -t -c 'SELECT 1;' 2>/dev/null | tr -d ' \n' || echo "0")
    [[ "$neon_ok" == "1" ]] && _chk 1 "Neon Postgres reachable" 1 || _chk 1 "Neon Postgres reachable" 0 "psql failed"
    _chk 2 "Neon URL in Secret Manager" 1 "written by Pulumi"
  else
    local pg_listen
    pg_listen=$(gcloud compute ssh "${DEPLOY_MODE_PREFIX}-pg" \
      --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" \
      --tunnel-through-iap --ssh-flag="-o ConnectTimeout=5" \
      --command "sudo ss -tlnp 2>/dev/null | grep -c '0\.0\.0\.0:5432'" \
      2>/dev/null || echo "0")
    [[ "${pg_listen:-0}" -ge 1 ]] \
      && _chk 1 "Postgres listening on VPC (0.0.0.0:5432)" 1 \
      || _chk 1 "Postgres listening on VPC (0.0.0.0:5432)" 0 "stuck on localhost"
    _chk 2 "Postgres password synced with Secret Manager" 1 "ran during deploy"
  fi

  if [[ "$BACKEND_RUNTIME" == "gke" ]]; then
    local ns="${_GKE_NS:-${DEPLOY_MODE_PREFIX}}"
    local ready
    ready=$(kubectl get deployment "${ns}-backend" -n "$ns" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [[ "${ready:-0}" -ge 1 ]] && _chk 3 "GKE deployment ready" 1 "${ready} replica(s)" \
      || _chk 3 "GKE deployment ready" 0 "readyReplicas=${ready:-0}"
  else
    local cr_status
    cr_status=$(gcloud run services describe "${DEPLOY_MODE_PREFIX}-backend" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" \
      --format="value(status.conditions[0].status)" 2>/dev/null || echo "unknown")
    [[ "$cr_status" == "True" ]] && _chk 3 "Cloud Run service ready" 1 \
      || _chk 3 "Cloud Run service ready" 0 "status: ${cr_status}"
  fi

  local health
  health=$(curl -sf "${BACKEND_URL}/actuator/health" --max-time 8 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  [[ "$health" == "UP" ]] && _chk 4 "GET /actuator/health → UP" 1 \
    || _chk 4 "GET /actuator/health → UP" 0 "status=${health:-unreachable}"

  if [[ "$BACKEND_RUNTIME" == "gke" ]]; then
    [[ -n "$BACKEND_URL" && "$BACKEND_URL" != "http://" ]] \
      && _chk 5 "GKE LoadBalancer URL" 1 "$BACKEND_URL" \
      || _chk 5 "GKE LoadBalancer URL" 0 "IP not yet assigned"
  else
    local cr_url
    cr_url=$(gcloud run services describe "${DEPLOY_MODE_PREFIX}-backend" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" \
      --format="value(status.url)" 2>/dev/null || true)
    [[ -n "$cr_url" ]] && _chk 5 "Cloud Run URL assigned" 1 "$cr_url" \
      || _chk 5 "Cloud Run URL assigned" 0 "not yet assigned"
  fi

  local http6
  http6=$(curl -sf -o /dev/null -w "%{http_code}" "${BACKEND_URL}/api/customers" --max-time 8 2>/dev/null || echo "000")
  [[ "$http6" == "200" ]] && _chk 6 "GET /api/customers → 200" 1 || _chk 6 "GET /api/customers → 200" 0 "HTTP $http6"

  [[ "${_DB_ORDERS:-0}" -gt 0 ]] \
    && _chk 7 "Database has data" 1 "${_DB_ORDERS} orders" \
    || _chk 7 "Database has data" 0 "0 orders — seed may have failed"

  local fe_url
  fe_url=$(gcloud run services describe "${DEPLOY_MODE_PREFIX}-frontend" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(status.url)" 2>/dev/null || true)
  if [[ -n "$fe_url" ]]; then
    local http8 http9
    http8=$(curl -sf -o /dev/null -w "%{http_code}" "$fe_url" --max-time 10 2>/dev/null || echo "000")
    [[ "$http8" == "200" ]] && _chk 8 "Cloud Run frontend → 200" 1 "$fe_url" \
      || _chk 8 "Cloud Run frontend → 200" 0 "HTTP $http8"
    http9=$(curl -sf -o /dev/null -w "%{http_code}" "${fe_url}/api/customers" --max-time 10 2>/dev/null || echo "000")
    [[ "$http9" == "200" ]] && _chk 9 "End-to-end: frontend → backend /api/customers" 1 \
      || _chk 9 "End-to-end: frontend → backend /api/customers" 0 "HTTP $http9"
  else
    printf '  [8] SKIP  Cloud Run frontend not yet deployed\n'
    printf '  [9] SKIP  End-to-end check — frontend not deployed\n'
  fi

  printf '\n  Results: %d passed, %d failed\n' "$_CP" "$_CF"
  (( _CF > 0 )) && printf '\n  !! %d CHECK(S) FAILED — review above before presenting\n' "$_CF"
  [[ "$DEPLOY_MODE" == "full" && "$USE_NEON" != "true" ]] && \
    printf '\n  !! REMINDER: FULL MODE WITH GCE VM (~$52/mo+) — run infra-down.sh when done\n'
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

_run_preflight
_prompt_menu
_prompt_backend_runtime
_prompt_database_backend
_print_cost_summary

[[ "$_TARGET" == "local" ]] && _deploy_local

_check_gcloud
_resolve_gcp_config
_resolve_image
_check_adc
_deploy_pulumi
_setup_db_post_pulumi

_resolve_snapshot_vars
_check_db_row_count
_seed_db
_sync_daily_order_count

_scale_down_gke_if_switching

if [[ "$BACKEND_RUNTIME" == "gke" ]]; then
  _deploy_gke
else
  BACKEND_URL=$(cd "$ROOT_DIR/infra" && pulumi stack output backendUrl 2>/dev/null || true)
fi

_patch_frontend_backend_url
_save_env_file

printf '\nBackend URL: %s\n' "$BACKEND_URL"

_update_readme
_deploy_frontend_inline

printf '\nRemember to tear down when finished:\n  ./scripts/infra-down.sh\n'

_post_deploy_checks
