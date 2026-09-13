#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FORCE_RESEED=0
DB_URL=""
BATCH_SIZE=500
TS_CREDS_FILE="$ROOT_DIR/.typesense-creds"
SIBLING_CREDS="$ROOT_DIR/../../typescript-implementations/clickhouse-dashboard/.typesense-creds"

TYPESENSE_URL=""
TYPESENSE_API_KEY=""

_usage() {
  printf 'Usage: %s [--force] [--db-url <url>] [--batch-size <n>]\n' "$0"
  printf '  --force        Drop and recreate collection even if already seeded\n'
  printf '  --db-url       Postgres connection URL (default: auto-detected)\n'
  printf '  --batch-size   Documents per Typesense import batch (default: 500)\n'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)        FORCE_RESEED=1; shift ;;
    --db-url)       DB_URL="$2"; shift 2 ;;
    --batch-size)   BATCH_SIZE="$2"; shift 2 ;;
    -h|--help)      _usage ;;
    *) printf 'Unknown argument: %s\n' "$1"; _usage ;;
  esac
done

if [[ -f "$TS_CREDS_FILE" ]]; then
  source "$TS_CREDS_FILE"
elif [[ -f "$SIBLING_CREDS" ]]; then
  source "$SIBLING_CREDS"
fi

[[ -n "${TYPESENSE_URL:-}" ]] || { printf 'TYPESENSE_URL not set — create .typesense-creds or export it\n' >&2; exit 1; }
[[ -n "${TYPESENSE_API_KEY:-}" ]] || { printf 'TYPESENSE_API_KEY not set — create .typesense-creds or export it\n' >&2; exit 1; }
[[ "$TYPESENSE_URL" == http://* || "$TYPESENSE_URL" == https://* ]] || TYPESENSE_URL="https://${TYPESENSE_URL}"

if [[ -z "$DB_URL" ]]; then
  for env_file in "$ROOT_DIR/.env.gcp.full" "$ROOT_DIR/.env.gcp.lite" "$ROOT_DIR/.env.local"; do
    if [[ -f "$env_file" ]]; then
      _neon=$(grep -E '^NEON_DATABASE_URL=' "$env_file" | cut -d= -f2- | tr -d '"' || true)
      if [[ -n "$_neon" ]]; then
        DB_URL="$_neon"
        printf 'DB URL: loaded from %s\n' "$env_file"
        break
      fi
    fi
  done
fi

if [[ -z "$DB_URL" ]]; then
  DB_URL="postgresql://$(whoami):@localhost:5432/database_flyway_orm"
  printf 'DB URL: defaulting to local — %s\n' "$DB_URL"
fi

printf 'Typesense: %s\n' "$TYPESENSE_URL"

_ts_curl() {
  curl -sf -H "X-TYPESENSE-API-KEY: ${TYPESENSE_API_KEY}" "$@"
}

REQUIRED_FIELDS='["orderId:int32","firstName:string","lastName:string","notes:string","status:string","regionCode:string","placedAt:int64","total:float"]'

_schema_check() {
  python3 - "$TYPESENSE_URL" "$TYPESENSE_API_KEY" "$REQUIRED_FIELDS" <<'PYEOF'
import sys, json, urllib.request, urllib.error

ts_url, ts_key, required_json = sys.argv[1], sys.argv[2], sys.argv[3]
required = {}
for f in json.loads(required_json):
    name, typ = f.split(":")
    required[name] = typ

req = urllib.request.Request(f"{ts_url}/collections/orders",
      headers={"X-TYPESENSE-API-KEY": ts_key})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        schema = json.load(resp)
except urllib.error.HTTPError as e:
    if e.code == 404:
        print("MISSING")
        sys.exit(0)
    print(f"ERROR:{e.code}")
    sys.exit(0)

existing = {f["name"]: f["type"] for f in schema.get("fields", [])}
doc_count = schema.get("num_documents", 0)

missing_fields  = [n for n, t in required.items() if n not in existing]
type_mismatches = [n for n, t in required.items() if n in existing and existing[n] != t]

if type_mismatches:
    print(f"MISMATCH:{','.join(type_mismatches)}")
elif missing_fields:
    print(f"INCOMPLETE:{','.join(missing_fields)}")
elif doc_count == 0:
    print("EMPTY")
else:
    print(f"OK:{doc_count}")
PYEOF
}

STATUS=$(_schema_check)
printf 'Collection status: %s\n' "$STATUS"

IMPORT_ACTION="create"

case "$STATUS" in
  MISSING)
    printf 'Collection does not exist — creating...\n'
    _ts_curl -X POST "${TYPESENSE_URL}/collections" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "orders",
        "fields": [
          {"name": "orderId",    "type": "int32"},
          {"name": "firstName",  "type": "string"},
          {"name": "lastName",   "type": "string"},
          {"name": "notes",      "type": "string", "optional": true},
          {"name": "status",     "type": "string", "facet": true},
          {"name": "regionCode", "type": "string", "facet": true},
          {"name": "placedAt",   "type": "int64",  "facet": true},
          {"name": "total",      "type": "float",  "facet": true}
        ],
        "default_sorting_field": "placedAt"
      }' | python3 -c "import sys,json; d=json.load(sys.stdin); print('Created:', d.get('name','?'))"
    ;;
  INCOMPLETE:*)
    MISSING_NAMES="${STATUS#INCOMPLETE:}"
    printf 'Schema incomplete — missing fields: %s. Patching...\n' "$MISSING_NAMES"
    python3 - "$TYPESENSE_URL" "$TYPESENSE_API_KEY" "$MISSING_NAMES" <<'PYEOF'
import sys, json, urllib.request

ts_url, ts_key, missing_csv = sys.argv[1], sys.argv[2], sys.argv[3]
type_map = {
    "orderId": "int32", "firstName": "string", "lastName": "string",
    "notes": "string",  "status": "string",    "regionCode": "string",
    "placedAt": "int64","total": "float"
}
facet_fields = {"status", "regionCode", "placedAt", "total"}
fields = []
for name in missing_csv.split(","):
    name = name.strip()
    entry = {"name": name, "type": type_map[name]}
    if name in facet_fields:
        entry["facet"] = True
    if name == "notes":
        entry["optional"] = True
    fields.append(entry)

body = json.dumps({"fields": fields}).encode()
req = urllib.request.Request(f"{ts_url}/collections/orders",
      data=body, method="PATCH",
      headers={"X-TYPESENSE-API-KEY": ts_key, "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=10) as resp:
    print("Patched schema:", json.load(resp).get("name"))
PYEOF
    IMPORT_ACTION="upsert"
    ;;
  MISMATCH:*)
    MISMATCH_NAMES="${STATUS#MISMATCH:}"
    printf 'Type mismatch on fields: %s — dropping and recreating collection...\n' "$MISMATCH_NAMES"
    _ts_curl -X DELETE "${TYPESENSE_URL}/collections/orders" >/dev/null
    _ts_curl -X POST "${TYPESENSE_URL}/collections" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "orders",
        "fields": [
          {"name": "orderId",    "type": "int32"},
          {"name": "firstName",  "type": "string"},
          {"name": "lastName",   "type": "string"},
          {"name": "notes",      "type": "string", "optional": true},
          {"name": "status",     "type": "string", "facet": true},
          {"name": "regionCode", "type": "string", "facet": true},
          {"name": "placedAt",   "type": "int64",  "facet": true},
          {"name": "total",      "type": "float",  "facet": true}
        ],
        "default_sorting_field": "placedAt"
      }' | python3 -c "import sys,json; d=json.load(sys.stdin); print('Recreated:', d.get('name','?'))"
    ;;
  OK:*)
    DOC_COUNT="${STATUS#OK:}"
    if [[ "$FORCE_RESEED" == "1" ]]; then
      printf 'Collection has %s docs — --force set, dropping and reseeding...\n' "$DOC_COUNT"
      _ts_curl -X DELETE "${TYPESENSE_URL}/collections/orders" >/dev/null
      _ts_curl -X POST "${TYPESENSE_URL}/collections" \
        -H "Content-Type: application/json" \
        -d '{
          "name": "orders",
          "fields": [
            {"name": "orderId",    "type": "int32"},
            {"name": "firstName",  "type": "string"},
            {"name": "lastName",   "type": "string"},
            {"name": "notes",      "type": "string", "optional": true},
            {"name": "status",     "type": "string", "facet": true},
            {"name": "regionCode", "type": "string", "facet": true},
            {"name": "placedAt",   "type": "int64",  "facet": true},
            {"name": "total",      "type": "float",  "facet": true}
          ],
          "default_sorting_field": "placedAt"
        }' | python3 -c "import sys,json; d=json.load(sys.stdin); print('Recreated:', d.get('name','?'))"
    else
      printf 'Collection already has %s documents — skipping seed. Use --force to reseed.\n' "$DOC_COUNT"
      exit 0
    fi
    ;;
  EMPTY)
    printf 'Collection exists but is empty — seeding...\n'
    ;;
  ERROR:*)
    printf 'Typesense health check failed: %s\n' "$STATUS" >&2; exit 1
    ;;
esac

printf 'Streaming from Postgres → Typesense (batch=%s)...\n' "$BATCH_SIZE"

psql "$DB_URL" -Atq -c "
SELECT
  o.id                                          AS order_id,
  c.\"firstName\"                               AS first_name,
  c.\"lastName\"                                AS last_name,
  COALESCE(o.notes, '')                         AS notes,
  o.status                                      AS status,
  r.code                                        AS region_code,
  EXTRACT(EPOCH FROM o.\"placedAt\")::bigint    AS placed_at,
  o.total                                       AS total
FROM orders o
JOIN customers c ON c.id = o.\"customerId\"
JOIN regions   r ON r.id = o.\"regionId\"
ORDER BY o.id
" 2>/dev/null | python3 - <<PYEOF
import sys, json, urllib.request, urllib.error, os

ts_url      = "${TYPESENSE_URL}"
ts_key      = "${TYPESENSE_API_KEY}"
batch_size  = int("${BATCH_SIZE}")
action      = "${IMPORT_ACTION}"
endpoint    = f"{ts_url}/collections/orders/documents/import?action={action}"

def post_batch(lines):
    body = "\n".join(lines).encode("utf-8")
    req  = urllib.request.Request(endpoint, data=body,
           headers={"X-TYPESENSE-API-KEY": ts_key,
                    "Content-Type": "application/x-ndjson"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            results = resp.read().decode("utf-8").strip().split("\n")
            errors  = [r for r in results if '"success":false' in r]
            if errors:
                print(f"  WARN: {len(errors)} failed in batch", file=sys.stderr)
    except urllib.error.HTTPError as e:
        print(f"  ERROR: HTTP {e.code}: {e.read().decode()}", file=sys.stderr)

batch = []
total = 0

for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 8:
        continue
    try:
        doc = {
            "id":         str(parts[0]),
            "orderId":    int(parts[0]),
            "firstName":  parts[1],
            "lastName":   parts[2],
            "notes":      parts[3],
            "status":     parts[4],
            "regionCode": parts[5],
            "placedAt":   int(parts[6]),
            "total":      float(parts[7]),
        }
        batch.append(json.dumps(doc))
        total += 1
        if len(batch) >= batch_size:
            post_batch(batch)
            batch = []
            if total % 50000 == 0:
                print(f"  indexed {total:,}...")
    except (ValueError, IndexError) as e:
        print(f"  skip row: {e}", file=sys.stderr)

if batch:
    post_batch(batch)

print(f"Done — {total:,} documents indexed.")
PYEOF
