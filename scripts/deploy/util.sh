#!/usr/bin/env bash

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
  printf 'Auth: %s  Project: %s  Region: %s\n' "$ACTIVE_ACCOUNT" "$GCP_PROJECT" "$GCP_REGION"
}

# ── Save helpers ──────────────────────────────────────────────────────────────

_save_user_inputs() {
  [[ "$_TARGET" != "remote" ]] && return 0
  local env_file="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  local existing_db_vm_ip="" existing_artifact_registry="" existing_cloud_run_url=""
  local existing_gcp_project="" existing_gcp_region=""
  if [[ -f "$env_file" ]]; then
    _raw_ip=$(grep -E '^DB_VM_IP=' "$env_file" | cut -d= -f2- || true)
    [[ "$_raw_ip" =~ ^[0-9]+\. ]] && existing_db_vm_ip="$_raw_ip" || existing_db_vm_ip=""
    existing_artifact_registry=$(grep -E '^ARTIFACT_REGISTRY=' "$env_file" | cut -d= -f2- || true)
    existing_cloud_run_url=$(grep -E '^CLOUD_RUN_URL=' "$env_file" | cut -d= -f2- || true)
    existing_gcp_project=$(grep -E '^GCP_PROJECT=' "$env_file" | cut -d= -f2- || true)
    existing_gcp_region=$(grep -E '^GCP_REGION=' "$env_file" | cut -d= -f2- || true)
  fi
  cat > "$env_file" <<EOF
DB_VM_IP=${existing_db_vm_ip}
ARTIFACT_REGISTRY=${existing_artifact_registry}
CLOUD_RUN_URL=${existing_cloud_run_url}
GCP_PROJECT=${existing_gcp_project:-${GCP_PROJECT}}
GCP_REGION=${existing_gcp_region:-${GCP_REGION}}
USE_NEON=${USE_NEON}
NEON_DATABASE_URL=${NEON_DATABASE_URL}
USE_TYPESENSE=${USE_TYPESENSE}
USE_FULLTEXT=${USE_FULLTEXT}
EOF
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
USE_TYPESENSE=${USE_TYPESENSE}
USE_FULLTEXT=${USE_FULLTEXT}
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
