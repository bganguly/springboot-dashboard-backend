#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"

# ── Globals ───────────────────────────────────────────────────────────────────
_local_running=0
_lite_count=0
_full_count=0

# ── Utilities ─────────────────────────────────────────────────────────────────

_pulumi_stack_count() {
  local stack="$1"
  ( cd "$INFRA_DIR" 2>/dev/null && \
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

_pulumi_destroy_robust() {
  local log_file
  log_file="$(mktemp)"
  local attempt=0 rc stale_urns

  while true; do
    attempt=$(( attempt + 1 ))
    set +e
    pulumi destroy --yes 2>&1 | tee "$log_file"
    rc="${PIPESTATUS[0]}"
    set -e

    if [[ "$rc" == "0" ]]; then
      rm -f "$log_file"
      return 0
    fi

    stale_urns=$(grep -oE 'error: deleting urn:pulumi:[^ ]+' "$log_file" \
      | sed 's/^error: deleting //; s/:$//' | sort -u || true)

    if [[ -z "$stale_urns" ]]; then
      rm -f "$log_file"
      printf '[infra-down] pulumi destroy failed with no extractable URNs — cannot auto-recover.\n' >&2
      return 1
    fi

    printf '[infra-down] Auto-purging stale state entries (attempt %d)...\n' "$attempt"
    while IFS= read -r urn; do
      [[ -z "$urn" ]] && continue
      printf '  purging: %s\n' "$urn"
      pulumi state delete "$urn" --yes 2>/dev/null || true
    done <<< "$stale_urns"
  done
}

# ── Preflight ─────────────────────────────────────────────────────────────────

_run_preflight() {
  lsof -ti:8080 >/dev/null 2>&1 && _local_running=1 || true
  if command -v pulumi >/dev/null 2>&1 && pulumi whoami >/dev/null 2>&1; then
    _lite_count=$(_pulumi_stack_count lite)
    _full_count=$(_pulumi_stack_count full)
  fi
}

# ── Remote teardown ───────────────────────────────────────────────────────────

_teardown_remote() {
  local _GKE_PREFIX _GKE_CLUSTER _GKE_ZONE
  _GKE_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash-full')
  _GKE_CLUSTER="${_GKE_PREFIX}-cluster"
  _GKE_ZONE="${GCP_REGION}-a"

  if gcloud container clusters describe "$_GKE_CLUSTER" \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    printf '[infra-down] Deleting GKE cluster %s (zero ongoing cost)...\n' "$_GKE_CLUSTER"
    gcloud container clusters delete "$_GKE_CLUSTER" \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" --quiet
    printf '[infra-down] GKE cluster deleted.\n'
  fi

  printf '[infra-down] Destroying Cloud Run, Postgres VM, VPC, Secret Manager, Artifact Registry...\n'

  cd "$INFRA_DIR"
  npm install --prefer-offline 2>/dev/null || npm install

  pulumi stack select "$DEPLOY_MODE"
  pulumi config set gcp:project "$GCP_PROJECT"
  pulumi config set gcp:region  "$GCP_REGION"

  local _EXPECTED_PREFIX _STACK_PREFIX
  _EXPECTED_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash')
  _STACK_PREFIX=$(pulumi config get namePrefix 2>/dev/null || true)
  if [[ -n "$_STACK_PREFIX" && "$_STACK_PREFIX" != "$_EXPECTED_PREFIX" ]]; then
    printf '\n[infra-down] WARNING: %s stack has namePrefix=%s but expected %s.\n' "$DEPLOY_MODE" "$_STACK_PREFIX" "$_EXPECTED_PREFIX" >&2
    printf '  This stack may contain resources from a different mode — destroying may affect other environments.\n' >&2
    printf 'Proceed anyway? [y/N] '
    read -r _SAFEGUARD
    [[ "$_SAFEGUARD" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }
  fi
  printf '\n[infra-down] Targeting namePrefix=%s (only %s-* GCP resources will be deleted).\n' "$_EXPECTED_PREFIX" "$_EXPECTED_PREFIX"

  _pulumi_destroy_robust

  rm -f "$ENV_FILE"
  printf '\n[infra-down] done — GCP %s resources destroyed, project %s preserved.\n' "$DEPLOY_MODE" "$GCP_PROJECT"
  printf '[infra-down] NOTE: gs://bikram-java-dash-snapshots/ is intentionally preserved (not managed by Pulumi).\n'

  local FRONTEND_DOWN
  FRONTEND_DOWN="$(cd "$ROOT_DIR/../dashboard-frontend-gcp/scripts" 2>/dev/null && pwd || true)/infra-down.sh"
  if [[ -f "$FRONTEND_DOWN" ]]; then
    printf '\n  Chaining frontend (%s) teardown...\n' "$DEPLOY_MODE"
    DEPLOY_MODE="$DEPLOY_MODE" bash "$FRONTEND_DOWN"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

_run_preflight

printf '\n=== springboot-dashboard-backend-gcp teardown ===\n\n'
printf '  [1] Local  — stop local backend (port 8080)'
(( _local_running )) && printf ' [running]' || printf ' [not detected]'
printf '\n'
printf '  [2] Lite   — destroy GCP lite (e2-medium backend VM + e2-standard-2 Postgres VM, dash-lite-*)'
(( _lite_count > 0 )) && printf ' [%s resources active]' "$_lite_count" || printf ' [not deployed]'
printf '\n'
printf '  [3] Full   — destroy GCP full (e2-standard-2 backend VM + n2-standard-4 Postgres VM, dash-*)'
(( _full_count > 0 )) && printf ' [%s resources active]' "$_full_count" || printf ' [not deployed]'
printf '\n'
printf '\nChoice [1/2/3]: '
read -r _MODE
case "$_MODE" in
  2) _TARGET="remote"; DEPLOY_MODE="lite" ;;
  3) _TARGET="remote"; DEPLOY_MODE="full" ;;
  *)  _TARGET="local";  DEPLOY_MODE=""    ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# LOCAL
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$_TARGET" == "local" ]]; then
  printf '\nStopping local backend (port 8080)...\n'
  "$ROOT_DIR/scripts/free-port.sh" 8080

  printf '\nDrop local database (database_flyway_orm)? [y/N] '
  read -r drop_db
  if [[ "$drop_db" =~ ^[Yy]$ ]]; then
    dropdb database_flyway_orm 2>/dev/null && printf 'Database dropped.\n' || printf 'Database not found — skipping.\n'
  fi

  printf 'Local infrastructure torn down.\n'
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# REMOTE (GCP)
# ══════════════════════════════════════════════════════════════════════════════

ENV_FILE="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"

PULUMI_USER=$(pulumi whoami 2>/dev/null || true)
[[ -n "$PULUMI_USER" ]] || { printf 'Not logged in to Pulumi. Run: pulumi login\n' >&2; exit 1; }

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
GCP_PROJECT="${GCP_PROJECT:-bikram-java}"
GCP_REGION="${GCP_REGION:-$(gcloud config get-value compute/region 2>/dev/null || true)}"
GCP_REGION="${GCP_REGION:-us-central1}"

[[ -n "$GCP_PROJECT" ]] || { printf 'GCP project could not be detected. Set GCP_PROJECT or run: gcloud config set project <id>\n' >&2; exit 1; }

printf '\n[infra-down] project: %s  region: %s\n' "$GCP_PROJECT" "$GCP_REGION"

_P_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash-full')
_P_CLUSTER="${_P_PREFIX}-cluster"
_P_ZONE="${GCP_REGION}-a"
_P_IS_GKE=0
gcloud container clusters describe "$_P_CLUSTER" \
  --zone "$_P_ZONE" --project "$GCP_PROJECT" >/dev/null 2>&1 && _P_IS_GKE=1 || true

if (( _P_IS_GKE )); then
  _P_NODES=$(gcloud container clusters describe "$_P_CLUSTER" \
    --zone "$_P_ZONE" --project "$GCP_PROJECT" \
    --format="value(currentNodeCount)" 2>/dev/null || echo "?")
  printf '  Current: GKE · nodes=%s\n' "$_P_NODES"
else
  _P_CR_MIN=$(gcloud run services describe "${_P_PREFIX}-backend" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])" \
    2>/dev/null || echo "?")
  printf '  Current: Cloud Run · min-instances=%s\n' "${_P_CR_MIN:-0}"
fi

_SCHED_UP_STATE=$(gcloud scheduler jobs describe "${_P_PREFIX}-gke-scale-up" \
  --location "$GCP_REGION" --project "$GCP_PROJECT" \
  --format="value(state)" 2>/dev/null || echo "NOT_CREATED")
printf '  Auto-schedule: starts 8am · stops 5pm · weekdays Pacific · state=%s\n' "$_SCHED_UP_STATE"
printf '  [1] Start now  [2] Stop now  [3] Suspend schedule  [4] Resume schedule  [enter] Tear down: '
read -r _PRE_ACTION
case "${_PRE_ACTION:-}" in
  1)
    if (( _P_IS_GKE )); then
      _SCHED_SA="${_P_PREFIX}-gke-sched-sa@${GCP_PROJECT}.iam.gserviceaccount.com"
      _PROJ_NUM=$(gcloud projects describe "$GCP_PROJECT" --format="value(projectNumber)" 2>/dev/null || true)
      _CS_AGENT="serviceAccount:service-${_PROJ_NUM}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
      _BOUND=$(gcloud iam service-accounts get-iam-policy "$_SCHED_SA" \
        --project "$GCP_PROJECT" --format=json 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print('yes' if any('serviceAccountTokenCreator' in b.get('role','') and any('cloudscheduler' in m for m in b.get('members',[])) for b in d.get('bindings',[])) else 'no')" 2>/dev/null || echo "no")
      if [[ "$_BOUND" != "yes" ]]; then
        printf '  Fixing scheduler IAM (missing token-creator binding)...\n'
        gcloud iam service-accounts add-iam-policy-binding "$_SCHED_SA" \
          --member="$_CS_AGENT" \
          --role="roles/iam.serviceAccountTokenCreator" \
          --project="$GCP_PROJECT" --quiet
        printf '  IAM binding applied — scheduler will work at next 8am run.\n'
      fi
      printf '  Starting — GKE node pool → 1...\n'
      gcloud container clusters resize "$_P_CLUSTER" \
        --node-pool default-pool --num-nodes 1 \
        --zone "$_P_ZONE" --project "$GCP_PROJECT" --quiet
      printf '  Node coming up — Spring Boot ready in ~2-3 min.\n'
    else
      gcloud scheduler jobs run "${_P_PREFIX}-scale-up-backend" \
        --location "$GCP_REGION" --project "$GCP_PROJECT" 2>/dev/null \
        && printf '  Started — Cloud Run min-instances now 1.\n' \
        || printf '  (scheduler job not yet created — will exist after first deploy)\n'
    fi
    exit 0
    ;;
  2)
    if (( _P_IS_GKE )); then
      printf '  Stopping — GKE node pool → 0...\n'
      gcloud container clusters resize "$_P_CLUSTER" \
        --node-pool default-pool --num-nodes 0 \
        --zone "$_P_ZONE" --project "$GCP_PROJECT" --quiet
      printf '  Stopped — no node charges until next start.\n'
    else
      gcloud scheduler jobs run "${_P_PREFIX}-scale-down-backend" \
        --location "$GCP_REGION" --project "$GCP_PROJECT" 2>/dev/null \
        && printf '  Stopped — Cloud Run min-instances now 0.\n' \
        || printf '  (scheduler job not yet created — will exist after first deploy)\n'
    fi
    exit 0
    ;;
  3)
    if [[ "$_SCHED_UP_STATE" == "PAUSED" ]]; then
      printf '  Schedule is already PAUSED — nothing to do.\n'
      exit 0
    fi
    if [[ "$_SCHED_UP_STATE" == "NOT_CREATED" ]]; then
      printf '  Scheduler jobs not yet created — run a full deploy first.\n'
      exit 1
    fi
    if (( _P_IS_GKE )) && [[ "${_P_NODES:-0}" != "0" ]]; then
      printf '  WARNING: nodes are still running (%s). They will not auto-stop at 5pm while suspended.\n' "$_P_NODES"
      printf '  Stop nodes too? [y/N] '
      read -r _STOP_NODES
      if [[ "$_STOP_NODES" =~ ^[Yy]$ ]]; then
        printf '  Stopping — GKE node pool → 0...\n'
        gcloud container clusters resize "$_P_CLUSTER" \
          --node-pool default-pool --num-nodes 0 \
          --zone "$_P_ZONE" --project "$GCP_PROJECT" --quiet
        printf '  Nodes stopped.\n'
      fi
    fi
    if (( _P_IS_GKE )); then
      gcloud scheduler jobs pause "${_P_PREFIX}-gke-scale-up"   --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      gcloud scheduler jobs pause "${_P_PREFIX}-gke-scale-down" --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      printf '  Schedule suspended.\n' || printf '  ERROR: failed to suspend one or both scheduler jobs.\n'
    else
      gcloud scheduler jobs pause "${_P_PREFIX}-scale-up-backend"   --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      gcloud scheduler jobs pause "${_P_PREFIX}-scale-down-backend" --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      printf '  Schedule suspended.\n' || printf '  ERROR: failed to suspend one or both scheduler jobs.\n'
    fi
    exit 0
    ;;
  4)
    if [[ "$_SCHED_UP_STATE" == "ENABLED" ]]; then
      printf '  Schedule is already ENABLED — nothing to do.\n'
      exit 0
    fi
    if [[ "$_SCHED_UP_STATE" == "NOT_CREATED" ]]; then
      printf '  Scheduler jobs not yet created — run a full deploy first.\n'
      exit 1
    fi
    if (( _P_IS_GKE )); then
      _SCHED_SA="${_P_PREFIX}-gke-sched-sa@${GCP_PROJECT}.iam.gserviceaccount.com"
      _PROJ_NUM=$(gcloud projects describe "$GCP_PROJECT" --format="value(projectNumber)" 2>/dev/null || true)
      _CS_AGENT="serviceAccount:service-${_PROJ_NUM}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
      _BOUND=$(gcloud iam service-accounts get-iam-policy "$_SCHED_SA" \
        --project "$GCP_PROJECT" --format=json 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print('yes' if any('serviceAccountTokenCreator' in b.get('role','') and any('cloudscheduler' in m for m in b.get('members',[])) for b in d.get('bindings',[])) else 'no')" 2>/dev/null || echo "no")
      if [[ "$_BOUND" != "yes" ]]; then
        printf '  Fixing scheduler IAM (missing token-creator binding)...\n'
        gcloud iam service-accounts add-iam-policy-binding "$_SCHED_SA" \
          --member="$_CS_AGENT" \
          --role="roles/iam.serviceAccountTokenCreator" \
          --project="$GCP_PROJECT" --quiet
        printf '  IAM binding applied.\n'
      fi
      gcloud scheduler jobs resume "${_P_PREFIX}-gke-scale-up"   --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      gcloud scheduler jobs resume "${_P_PREFIX}-gke-scale-down" --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      printf '  Schedule resumed — nodes will start at next 8am weekday run.\n' || printf '  ERROR: failed to resume one or both scheduler jobs.\n'
    else
      gcloud scheduler jobs resume "${_P_PREFIX}-scale-up-backend"   --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      gcloud scheduler jobs resume "${_P_PREFIX}-scale-down-backend" --location "$GCP_REGION" --project "$GCP_PROJECT" && \
      printf '  Schedule resumed.\n' || printf '  ERROR: failed to resume one or both scheduler jobs.\n'
    fi
    exit 0
    ;;
esac

_teardown_remote
