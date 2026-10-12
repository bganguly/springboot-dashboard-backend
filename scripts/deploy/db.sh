#!/usr/bin/env bash

# ── Database setup (post-Pulumi) ──────────────────────────────────────────────

_setup_db_post_pulumi() {
  local pg_vm="${DEPLOY_MODE_PREFIX}-pg"
  if [[ "$USE_NEON" == "true" ]]; then
    return 0
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

# ── Snapshot / seed helpers ───────────────────────────────────────────────────

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

_preflight_db() {
  [[ "$USE_NEON" != "true" || "$_TARGET" != "remote" ]] && return 0
  [[ -z "${NEON_DATABASE_URL:-}" ]] && return 0
  local conn_ok
  conn_ok=$(psql "$NEON_DATABASE_URL" -t -c 'SELECT 1;' 2>/dev/null | tr -d ' \n' || printf '')
  if [[ "$conn_ok" == "1" ]]; then
    printf 'DB connection check: OK — continuing\n'
  else
    printf 'DB connection check: not OK — exiting\n'; exit 1
  fi
}

_check_db_row_count() {
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
}

_gcs_check() {
  local token="$1"
  curl -sf \
    "https://storage.googleapis.com/storage/v1/b/bikram-java-dash-snapshots/o/dash%2F${_GCS_BASENAME}" \
    -H "Authorization: Bearer ${token}" 2>/dev/null \
    | python3 -c "import sys,json;json.load(sys.stdin);print('yes')" 2>/dev/null || printf 'no'
}

_save_snapshot_via_cloud_build() {
  [[ -z "${NEON_DATABASE_URL:-}" ]] && return 0
  if gsutil -q stat "$DEMO_SNAPSHOT_GCS_URI" 2>/dev/null; then
    local snap_size
    snap_size=$(gsutil du "$DEMO_SNAPSHOT_GCS_URI" 2>/dev/null | awk '{print $1}')
    if [[ "${snap_size:-0}" -gt 0 && "${_FORCE_SNAPSHOT_UPDATE:-0}" != "1" ]]; then
      printf '  Snapshot already exists at %s — skipping Cloud Build dump.\n' "$DEMO_SNAPSHOT_GCS_URI"
      return 0
    fi
    [[ "${_FORCE_SNAPSHOT_UPDATE:-0}" == "1" ]] && gsutil rm "$DEMO_SNAPSHOT_GCS_URI" 2>/dev/null || true
    printf '  Snapshot is 0 bytes (corrupt) — deleting and re-dumping via Cloud Build...\n'
    gsutil rm "$DEMO_SNAPSHOT_GCS_URI" 2>/dev/null || true
  fi
  local direct_url
  direct_url=$(printf '%s' "$NEON_DATABASE_URL" \
    | sed 's/-pooler\././' \
    | sed 's/[&?]channel_binding=[^&]*//')
  local cb_yaml
  cb_yaml=$(mktemp /tmp/cb.XXXXXX.yaml)
  cat > "$cb_yaml" <<CBEOF
steps:
  - name: 'postgres:18'
    entrypoint: sh
    args:
      - '-c'
      - 'pg_dump --no-owner --no-privileges -Fc "\$_NEON_URL" -f /workspace/snap.dump && echo "dump size: \$(wc -c < /workspace/snap.dump) bytes"'
  - name: 'gcr.io/cloud-builders/gsutil'
    args: ['cp', '/workspace/snap.dump', '${DEMO_SNAPSHOT_GCS_URI}']
CBEOF
  printf '  Submitting Cloud Build pg_dump job (postgres:18 → GCS)...\n'
  gcloud builds submit --no-source --project="$GCP_PROJECT" --config "$cb_yaml" \
    --substitutions="_NEON_URL=${direct_url}" \
    && printf '  Cloud Build dump complete.\n' \
    || printf '  Cloud Build dump failed — snapshot not saved.\n'
  rm -f "$cb_yaml"
}

_save_snapshot_to_gcs() {
  local gcs_token gcs_exists
  gcs_token=$(gcloud auth print-access-token 2>/dev/null || true)
  gcs_exists=$(_gcs_check "$gcs_token")
  if [[ "$gcs_exists" == "yes" && "${_FORCE_SNAPSHOT_UPDATE:-0}" != "1" ]]; then return 0; fi
  printf '  Saving snapshot → GCS (%s)...\n' "$_GCS_BASENAME"
  _save_snapshot_via_cloud_build
}

_seed_db() {
  local _expected_orders
  _expected_orders=$([[ "$DEPLOY_MODE" == "lite" ]] && printf '100000' || printf '4000000')
  local _min_orders=$(( _expected_orders * 99 / 100 ))
  if [[ "${_DB_ORDERS:-0}" -ge "$_min_orders" ]]; then
    if (( _SKIP_DEFAULTS >= 1 )); then
      printf 'DB: %s orders already present. Using existing seed (defaults).\n' "$_DB_ORDERS"
      return 0
    fi
    printf 'DB: %s orders already present. Use existing seed? [Y/n]: ' "$_DB_ORDERS"
    read -r _use_existing
    if [[ "${_use_existing:-Y}" =~ ^[Nn] ]]; then
      printf '  Reseeding...\n'
      _DB_ORDERS=0
      _FORCE_SNAPSHOT_UPDATE=1
    else
      printf 'Skipping seed.\n'; return 0
    fi
  fi
  if [[ "${_DB_ORDERS:-0}" -gt 0 ]]; then
    printf 'DB: %s orders — below %s minimum, reseeding...\n' "$_DB_ORDERS" "$_min_orders"
  else
    printf 'DB empty — seeding...\n'
  fi
  if [[ "$USE_NEON" == "true" ]]; then
    _seed_neon
  else
    _seed_gce_bake
  fi
  _check_db_row_count
  printf 'DB: %s orders after seed\n' "$_DB_ORDERS"
}

_seed_neon() {
  _STEP="db seed (neon)"
  command -v pg_restore >/dev/null 2>&1 || { printf '  pg_restore not found — brew install libpq\n'; exit 1; }
  command -v psql      >/dev/null 2>&1 || { printf '  psql not found — brew install libpq\n'; exit 1; }
  local tmp gcs_token gcs_exists
  tmp=$(mktemp /tmp/bake.XXXXXX)
  gcs_token=$(gcloud auth print-access-token 2>/dev/null || true)
  gcs_exists=$(_gcs_check "$gcs_token")
  if [[ "${_FORCE_SNAPSHOT_UPDATE:-0}" == "1" ]]; then
    printf '  Force-reseed requested — skipping GCS restore, running seed-large.sql...\n'
    rm -f "$tmp"; _seed_neon_sql; return 0
  fi
  if [[ "$gcs_exists" == "yes" ]]; then
    printf '  Downloading %s from GCS...\n' "$_GCS_BASENAME"
    gsutil cp "$DEMO_SNAPSHOT_GCS_URI" "$tmp" 2>/dev/null || \
    curl -fL \
      "https://storage.googleapis.com/storage/v1/b/bikram-java-dash-snapshots/o/dash%2F${_GCS_BASENAME}?alt=media" \
      -H "Authorization: Bearer ${gcs_token}" -o "$tmp"
  else
    _download_from_s3_local "$tmp" || { rm -f "$tmp"; _seed_neon_sql; return 0; }
  fi
  if [[ -s "$tmp" ]]; then
    printf '  Running pg_restore against Neon...\n'
    if pg_restore --no-owner --no-privileges --clean --if-exists -d "$NEON_DATABASE_URL" "$tmp"; then
      rm -f "$tmp"
      printf 'Seeding complete.\n'
      return 0
    else
      printf '  pg_restore failed (incompatible format?) — deleting stale snapshot and falling back to seed-large.sql...\n'
      rm -f "$tmp"
      gsutil rm "$DEMO_SNAPSHOT_GCS_URI" 2>/dev/null || true
      _seed_neon_sql
    fi
  else
    printf '  Downloaded snapshot is empty — deleting and falling back to seed-large.sql...\n'
    rm -f "$tmp"
    gsutil rm "$DEMO_SNAPSHOT_GCS_URI" 2>/dev/null || true
    _seed_neon_sql
  fi
}

_ensure_schema_neon() {
  local t1 t2
  t1=$(psql "$NEON_DATABASE_URL" -t -c "SELECT to_regclass('public.orders');"     2>/dev/null | tr -d ' \n')
  t2=$(psql "$NEON_DATABASE_URL" -t -c "SELECT to_regclass('public.order_items');" 2>/dev/null | tr -d ' \n')
  local script_dir migration_dir
  script_dir="${ROOT_DIR}/scripts"
  migration_dir="${ROOT_DIR}/src/main/resources/db/migration"
  if [[ "$t1" != "" && "$t1" != "NULL" && "$t2" != "" && "$t2" != "NULL" ]]; then
    local mig_count expected_count
    mig_count=$(psql "$NEON_DATABASE_URL" -t -c \
      "SELECT COUNT(*) FROM flyway_schema_history WHERE success=true;" 2>/dev/null | tr -d ' \n' || printf '0')
    expected_count=$(ls "$migration_dir"/V*.sql | wc -l | tr -d ' \n')
    [[ "$mig_count" == "$expected_count" ]] && return 0
    printf '  Flyway history incomplete (%s/%s) — wiping and reapplying.\n' "$mig_count" "$expected_count"
  else
    printf '  Schema absent or incomplete — wiping and reapplying.\n'
  fi
  psql "$NEON_DATABASE_URL" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
  for f in $(ls "$migration_dir"/V*.sql | sort -V); do
    printf '    %s\n' "$(basename "$f")"
    psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  done
  printf '  Populating Flyway history so app startup does not re-apply...\n'
  python3 - "$NEON_DATABASE_URL" "$migration_dir" <<'PYEOF'
import sys, os, zlib, struct, subprocess, re, glob

db_url  = sys.argv[1]
mig_dir = sys.argv[2]

files = sorted(glob.glob(os.path.join(mig_dir, 'V*.sql')))

def flyway_crc32(path):
    with open(path, 'rb') as fh:
        data = fh.read().replace(b'\r\n', b'\n')
    crc = zlib.crc32(data) & 0xFFFFFFFF
    return struct.unpack('i', struct.pack('I', crc))[0]

def parse(fname):
    m = re.match(r'V(\d+(?:\.\d+)*)__(.+)\.sql$', fname)
    return (m.group(1), m.group(2).replace('_', ' ')) if m else (None, None)

create_sql = """
CREATE TABLE IF NOT EXISTS flyway_schema_history (
  installed_rank integer NOT NULL PRIMARY KEY,
  version        varchar(50),
  description    varchar(200) NOT NULL,
  type           varchar(20)  NOT NULL,
  script         varchar(1000) NOT NULL,
  checksum       integer,
  installed_by   varchar(100) NOT NULL,
  installed_on   timestamp(6) NOT NULL DEFAULT now(),
  execution_time integer NOT NULL,
  success        boolean NOT NULL
);
CREATE INDEX IF NOT EXISTS flyway_schema_history_s_idx ON flyway_schema_history (success);
"""
subprocess.run(['psql', db_url, '-c', create_sql], check=True, capture_output=True)

rows = []
for rank, fpath in enumerate(files, 1):
    fname = os.path.basename(fpath)
    version, description = parse(fname)
    if not version:
        continue
    rows.append(f"({rank},'{version}','{description}','SQL','{fname}',{flyway_crc32(fpath)},'deploy.sh',now(),0,true)")

if rows:
    sql = ("INSERT INTO flyway_schema_history "
           "(installed_rank,version,description,type,script,checksum,installed_by,installed_on,execution_time,success) "
           "VALUES " + ",".join(rows) + " ON CONFLICT DO NOTHING;")
    subprocess.run(['psql', db_url, '-c', sql], check=True, capture_output=True)
    print(f"  Flyway history: {len(rows)} migrations recorded.")
PYEOF
  printf '  Schema ready.\n'
}

_seed_neon_sql() {
  local orders
  orders=$([[ "$DEPLOY_MODE" == "lite" ]] && printf '100000' || printf '4000000')
  local script_dir migration_dir
  script_dir="${ROOT_DIR}/scripts"
  migration_dir="${ROOT_DIR}/src/main/resources/db/migration"
  printf '  Resetting schema before seed...\n'
  psql "$NEON_DATABASE_URL" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
  for f in $(ls "$migration_dir"/V*.sql | sort -V); do
    printf '    applying %s\n' "$(basename "$f")"
    psql "$NEON_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  done
  printf '  Populating Flyway history...\n'
  python3 - "$NEON_DATABASE_URL" "$migration_dir" <<'PYEOF'
import sys, os, zlib, struct, subprocess, re, glob

db_url  = sys.argv[1]
mig_dir = sys.argv[2]

files = sorted(glob.glob(os.path.join(mig_dir, 'V*.sql')))

def flyway_crc32(path):
    with open(path, 'rb') as fh:
        data = fh.read().replace(b'\r\n', b'\n')
    crc = zlib.crc32(data) & 0xFFFFFFFF
    return struct.unpack('i', struct.pack('I', crc))[0]

def parse(fname):
    m = re.match(r'V(\d+(?:\.\d+)*)__(.+)\.sql$', fname)
    return (m.group(1), m.group(2).replace('_', ' ')) if m else (None, None)

create_sql = """
CREATE TABLE IF NOT EXISTS flyway_schema_history (
  installed_rank integer NOT NULL PRIMARY KEY,
  version        varchar(50),
  description    varchar(200) NOT NULL,
  type           varchar(20)  NOT NULL,
  script         varchar(1000) NOT NULL,
  checksum       integer,
  installed_by   varchar(100) NOT NULL,
  installed_on   timestamp(6) NOT NULL DEFAULT now(),
  execution_time integer NOT NULL,
  success        boolean NOT NULL
);
CREATE INDEX IF NOT EXISTS flyway_schema_history_s_idx ON flyway_schema_history (success);
"""
subprocess.run(['psql', db_url, '-c', create_sql], check=True, capture_output=True)

rows = []
for rank, fpath in enumerate(files, 1):
    fname = os.path.basename(fpath)
    version, description = parse(fname)
    if not version:
        continue
    rows.append(f"({rank},'{version}','{description}','SQL','{fname}',{flyway_crc32(fpath)},'deploy.sh',now(),0,true)")

if rows:
    sql = ("INSERT INTO flyway_schema_history "
           "(installed_rank,version,description,type,script,checksum,installed_by,installed_on,execution_time,success) "
           "VALUES " + ",".join(rows) + " ON CONFLICT DO NOTHING;")
    subprocess.run(['psql', db_url, '-c', sql], check=True, capture_output=True)
    print(f"  Flyway history: {len(rows)} migrations recorded.")
PYEOF
  # V9 runs during the migration loop with empty tables (0 rows inserted).
  # Remove it from history so _neon_premigrate_heavy re-runs it after the seed
  # populates orders/order_items with actual data.
  psql "$NEON_DATABASE_URL" -c "DELETE FROM flyway_schema_history WHERE version = '9';" 2>/dev/null || true
  printf '  Schema reset complete.\n'
  printf '  No GCS/S3 snapshot — seeding %s orders via seed-large.sql (this takes several minutes)...\n' "$orders"
  # Use the direct (non-pooler) Neon URL: seeding 4M rows takes ~30 min and
  # PgBouncer in transaction mode drops silent connections after ~11 min.
  local direct_url seed_sql
  direct_url=$(printf '%s' "$NEON_DATABASE_URL" \
    | sed 's/-pooler\././' \
    | sed 's/[&?]channel_binding=[^&]*//')
  rm -f /tmp/seed.XXXXXX.sql
  seed_sql=$(mktemp /tmp/seed.XXXXXX)
  sed \
    -e "s|:'first_names_file'|'${script_dir}/data/first_names.txt'|g" \
    -e "s|:'last_names_file'|'${script_dir}/data/last_names.txt'|g" \
    -e "s|:'notes_file'|'${script_dir}/data/notes.txt'|g" \
    "${script_dir}/seed-large.sql" > "$seed_sql"
  psql "$direct_url" \
    -v "orders=${orders}" \
    -f "$seed_sql"
  rm -f "$seed_sql"
  printf '  Running ANALYZE to update planner statistics...\n'
  psql "$direct_url" -c "ANALYZE orders, customers;"
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
  local sql='INSERT INTO daily_order_count (date, "totalOrders") SELECT "placedAt"::date, COUNT(*) FROM orders GROUP BY "placedAt"::date ON CONFLICT (date) DO UPDATE SET "totalOrders" = EXCLUDED."totalOrders";'
  if [[ "$USE_NEON" == "true" ]]; then
    psql "$NEON_DATABASE_URL" -c "$sql" 2>/dev/null || true
  else
    gcloud compute ssh "${DEPLOY_MODE_PREFIX}-pg" \
      --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" \
      --tunnel-through-iap --ssh-flag="-o ConnectTimeout=10" \
      --command "sudo -u postgres psql -d app -c \"${sql}\"" 2>/dev/null || true
  fi
}

# ── Neon-specific migration helpers ──────────────────────────────────────────
# (called from infra.sh _deploy_pulumi before pulumi up)

_flyway_repair_neon() {
  [[ "$USE_NEON" != "true" || -z "${NEON_DATABASE_URL:-}" ]] && return 0
  local failed
  failed=$(psql "$NEON_DATABASE_URL" -Atqc \
    "SELECT version FROM flyway_schema_history WHERE success = false;" 2>/dev/null | tr -d ' \n' || printf '')
  [[ -z "$failed" ]] && return 0
  printf '  Flyway repair: removing failed migration(s): %s\n' "$failed"
  psql "$NEON_DATABASE_URL" -c \
    "DELETE FROM flyway_schema_history WHERE success = false;" 2>/dev/null || true
}

_neon_premigrate_heavy() {
  [[ "$USE_NEON" != "true" || -z "${NEON_DATABASE_URL:-}" ]] && return 0

  local v9_done v10_done
  v9_done=$(psql "$NEON_DATABASE_URL" -Atqc \
    "SELECT count(*) FROM flyway_schema_history WHERE version = '9' AND success = true;" 2>/dev/null | tr -d ' \n' || printf '0')
  v10_done=$(psql "$NEON_DATABASE_URL" -Atqc \
    "SELECT count(*) FROM flyway_schema_history WHERE version = '10' AND success = true;" 2>/dev/null | tr -d ' \n' || printf '0')
  [[ "$v9_done" == "1" && "$v10_done" == "1" ]] && return 0

  printf '\n  WARNING: V9/V10 migrations not yet applied.\n'
  printf '  This will run heavy psql backfills directly against Neon before deploying.\n'
  printf '  Expect ~60 min of wait time (4 large INSERTs + index builds).\n'
  printf '  Keep this terminal open and on a stable network connection.\n\n'

  # Use the direct (non-pooler) URL: the pooler runs PgBouncer in transaction
  # mode, which silently drops the TCP connection after ~11 min of query
  # silence. The heavy V9 INSERTs take 10-15 min each with no data flowing
  # back to the client, so PgBouncer kills the connection mid-query. The
  # direct endpoint has no intermediary and holds the connection for the
  # full duration. Derive it by stripping -pooler from the hostname and
  # channel_binding (not supported on the direct endpoint) from the URL.
  local direct_url
  direct_url=$(printf '%s' "$NEON_DATABASE_URL" \
    | sed 's/-pooler\././' \
    | sed 's/[&?]channel_binding=[^&]*//')
  local conn_test
  conn_test=$(psql "$direct_url" -Atqc "SELECT 1;" 2>/dev/null | tr -d ' \n' || printf '')
  if [[ "$conn_test" != "1" ]]; then
    printf '  ERROR: cannot connect via direct Neon URL — aborting pre-migration\n'; return 1
  fi
  printf '  Using direct Neon URL (bypasses PgBouncer TCP timeout)\n'

  if [[ "$v9_done" != "1" ]]; then
    printf '  Pre-migrating V9 (batched backfill — 400K orders per batch)...\n'
    local t0 t1 max_id batch_size batch_start batch_end batch_num total_batches
    batch_size=400000
    max_id=$(psql "$direct_url" -Atqc "SELECT COALESCE(MAX(id),0) FROM orders;" | tr -d ' \n')
    total_batches=$(( (max_id + batch_size - 1) / batch_size ))
    printf '    max order id: %s  batches: %s\n' "$max_id" "$total_batches"
    if [[ "$max_id" -eq 0 ]]; then
      printf '  Orders table empty — deferring V9 backfill until after seed.\n'
      return 0
    fi

    printf '    1/4 order_category_facts\n'; t0=$(date +%s)
    batch_num=1; batch_start=1
    while (( batch_start <= max_id )); do
      batch_end=$(( batch_start + batch_size - 1 ))
      printf '      batch %s/%s (ids %s-%s)...\n' "$batch_num" "$total_batches" "$batch_start" "$batch_end"
      psql "$direct_url" -c "SET statement_timeout = 0; SET idle_in_transaction_session_timeout = 0; INSERT INTO order_category_facts (\"orderId\", \"placedAt\", date, \"regionId\", \"regionCode\", status, \"orderTotal\", \"categoryId\", \"categoryName\", \"totalItems\", \"totalRevenue\") SELECT o.id, o.\"placedAt\", o.\"placedAt\"::date, o.\"regionId\", r.code, o.status, o.total, cat.id, cat.name, coalesce(sum(oi.quantity), 0)::int, coalesce(sum(oi.quantity * oi.\"unitPrice\" * (1 - oi.discount)), 0) FROM orders o JOIN order_items oi ON oi.\"orderId\" = o.id JOIN products p ON p.id = oi.\"productId\" JOIN categories cat ON cat.id = p.\"categoryId\" JOIN regions r ON r.id = o.\"regionId\" WHERE o.id BETWEEN ${batch_start} AND ${batch_end} GROUP BY o.id, o.\"placedAt\", o.\"regionId\", r.code, o.status, o.total, cat.id, cat.name ON CONFLICT (\"orderId\", \"categoryId\") DO NOTHING;" \
        || { printf '      FAILED (batch %s)\n' "$batch_num"; return 1; }
      batch_start=$(( batch_end + 1 ))
      batch_num=$(( batch_num + 1 ))
    done
    t1=$(date +%s); printf '    1/4 done (%ds)\n' $(( t1 - t0 ))

    printf '    2/4 daily_customer_category_summary\n'; t0=$(date +%s)
    batch_num=1; batch_start=1
    while (( batch_start <= max_id )); do
      batch_end=$(( batch_start + batch_size - 1 ))
      printf '      batch %s/%s (ids %s-%s)...\n' "$batch_num" "$total_batches" "$batch_start" "$batch_end"
      psql "$direct_url" -c "SET statement_timeout = 0; SET idle_in_transaction_session_timeout = 0; INSERT INTO daily_customer_category_summary (date, \"customerId\", \"regionId\", \"regionCode\", status, \"categoryId\", \"categoryName\", \"totalOrders\", \"totalRevenue\", \"totalItems\", \"createdAt\", \"updatedAt\") SELECT o.\"placedAt\"::date, o.\"customerId\", o.\"regionId\", r.code, o.status, cat.id, cat.name, count(DISTINCT o.id)::int, coalesce(sum(oi.quantity * oi.\"unitPrice\" * (1 - oi.discount)), 0), coalesce(sum(oi.quantity), 0)::int, now(), now() FROM orders o JOIN order_items oi ON oi.\"orderId\" = o.id JOIN products p ON p.id = oi.\"productId\" JOIN categories cat ON cat.id = p.\"categoryId\" JOIN regions r ON r.id = o.\"regionId\" WHERE o.id BETWEEN ${batch_start} AND ${batch_end} GROUP BY o.\"placedAt\"::date, o.\"customerId\", o.\"regionId\", r.code, o.status, cat.id, cat.name ON CONFLICT (\"date\", \"customerId\", \"regionId\", \"status\", \"categoryId\") DO NOTHING;" \
        || { printf '      FAILED (batch %s)\n' "$batch_num"; return 1; }
      batch_start=$(( batch_end + 1 ))
      batch_num=$(( batch_num + 1 ))
    done
    t1=$(date +%s); printf '    2/4 done (%ds)\n' $(( t1 - t0 ))

    printf '    3/4 daily_filter_category_summary\n'; t0=$(date +%s)
    psql "$direct_url" -c "SET statement_timeout = 0; SET idle_in_transaction_session_timeout = 0; INSERT INTO daily_filter_category_summary (date, \"regionId\", \"regionCode\", status, \"categoryId\", \"categoryName\", \"totalOrders\", \"totalRevenue\", \"totalItems\", \"createdAt\", \"updatedAt\") SELECT date, \"regionId\", \"regionCode\", status, \"categoryId\", \"categoryName\", sum(\"totalOrders\")::int, sum(\"totalRevenue\"), sum(\"totalItems\")::int, now(), now() FROM daily_customer_category_summary GROUP BY date, \"regionId\", \"regionCode\", status, \"categoryId\", \"categoryName\" ON CONFLICT (\"date\", \"regionId\", \"status\", \"categoryId\") DO UPDATE SET \"regionCode\" = EXCLUDED.\"regionCode\", \"categoryName\" = EXCLUDED.\"categoryName\", \"totalOrders\" = EXCLUDED.\"totalOrders\", \"totalRevenue\" = EXCLUDED.\"totalRevenue\", \"totalItems\" = EXCLUDED.\"totalItems\", \"updatedAt\" = CURRENT_TIMESTAMP;" \
      || { printf '    FAILED\n'; return 1; }
    t1=$(date +%s); printf '    done (%ds)\n' $(( t1 - t0 ))

    printf '    4/4 daily_status_category_summary\n'; t0=$(date +%s)
    psql "$direct_url" -c "SET statement_timeout = 0; SET idle_in_transaction_session_timeout = 0; INSERT INTO daily_status_category_summary (date, status, \"categoryId\", \"categoryName\", \"totalOrders\", \"totalRevenue\", \"totalItems\", \"createdAt\", \"updatedAt\") SELECT date, status, \"categoryId\", \"categoryName\", sum(\"totalOrders\")::int, sum(\"totalRevenue\"), sum(\"totalItems\")::int, now(), now() FROM daily_filter_category_summary GROUP BY date, status, \"categoryId\", \"categoryName\" ON CONFLICT (\"date\", \"status\", \"categoryId\") DO UPDATE SET \"categoryName\" = EXCLUDED.\"categoryName\", \"totalOrders\" = EXCLUDED.\"totalOrders\", \"totalRevenue\" = EXCLUDED.\"totalRevenue\", \"totalItems\" = EXCLUDED.\"totalItems\", \"updatedAt\" = CURRENT_TIMESTAMP;" \
      || { printf '    FAILED\n'; return 1; }
    t1=$(date +%s); printf '    done (%ds)\n' $(( t1 - t0 ))

    local v9_checksum
    v9_checksum=$(python3 -c "
import binascii, ctypes
data = open('${ROOT_DIR}/src/main/resources/db/migration/V9__backfill_summary_tables.sql', 'rb').read()
print(ctypes.c_int32(binascii.crc32(data)).value)
" 2>/dev/null) || v9_checksum=-1898932707
    psql "$NEON_DATABASE_URL" -c "
INSERT INTO flyway_schema_history (installed_rank, version, description, type, script, checksum, installed_by, installed_on, execution_time, success)
SELECT COALESCE(MAX(installed_rank), 0) + 1, '9', 'backfill summary tables', 'SQL', 'V9__backfill_summary_tables.sql', ${v9_checksum}, 'neondb_owner', now(), 0, true
FROM flyway_schema_history
WHERE NOT EXISTS (SELECT 1 FROM flyway_schema_history WHERE version = '9');" \
      || { printf '    V9 history record insert failed\n'; return 1; }
    printf '  V9 pre-migration complete.\n'
  fi

  if [[ "$v10_done" != "1" ]]; then
    printf '  Pre-migrating V10 (index rename via psql)...\n'
    psql "$direct_url" -c "DROP INDEX IF EXISTS \"idx_orders_search_text_bigm\"; CREATE INDEX IF NOT EXISTS \"idx_orders_search_text_trgm\" ON orders USING gin (search_text gin_trgm_ops);" \
      || { printf '    V10 index 1/3 failed\n'; return 1; }
    psql "$direct_url" -c "DROP INDEX IF EXISTS \"idx_orders_notes_bigm\"; CREATE INDEX IF NOT EXISTS \"idx_orders_notes_trgm\" ON orders USING gin (notes gin_trgm_ops);" \
      || { printf '    V10 index 2/3 failed\n'; return 1; }
    psql "$direct_url" -c "DROP INDEX IF EXISTS \"idx_customers_bigm\"; CREATE INDEX IF NOT EXISTS \"idx_customers_trgm\" ON customers USING gin ((\"firstName\"||' '||\"lastName\"||' '||email) gin_trgm_ops);" \
      || { printf '    V10 index 3/3 failed\n'; return 1; }
    psql "$NEON_DATABASE_URL" -c "INSERT INTO flyway_schema_history (installed_rank, version, description, type, script, checksum, installed_by, execution_time, success) VALUES (10, '10', 'rename trgm indexes', 'SQL', 'V10__rename_trgm_indexes.sql', 877711082, 'neondb_owner', 0, true) ON CONFLICT (installed_rank) DO NOTHING;" \
      || { printf '    V10 history record insert failed\n'; return 1; }
    printf '  V10 pre-migration complete.\n'
  fi
}

_dump_neon_to_gcs() {
  [[ "$USE_NEON" != "true" || -z "${NEON_DATABASE_URL:-}" ]] && return 0
  [[ -z "${DEMO_SNAPSHOT_GCS_URI:-}" ]] && return 0
  command -v pg_dump >/dev/null 2>&1 || { printf '  pg_dump not found — skipping snapshot\n'; return 0; }
  local direct_url
  direct_url=$(printf '%s' "$NEON_DATABASE_URL" \
    | sed 's/-pooler\././' \
    | sed 's/[&?]channel_binding=[^&]*//')
  printf '\n  Streaming pg_dump → GCS (%s)...\n' "$DEMO_SNAPSHOT_GCS_URI"
  pg_dump --no-owner --no-privileges -Fc "$direct_url" \
    | gsutil cp - "$DEMO_SNAPSHOT_GCS_URI" \
    && printf '  GCS snapshot updated — next build restores from this dump (fast path).\n' \
    || printf '  pg_dump/upload failed — next build will re-seed from SQL.\n'
}
