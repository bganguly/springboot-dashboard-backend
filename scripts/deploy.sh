#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── Globals ───────────────────────────────────────────────────────────────────
_STEP="startup"
_on_exit() { local c=$?; [[ $c -ne 0 ]] && printf '\n[deploy.sh] ABORTED (exit %d) at step: %s\n' "$c" "$_STEP" >&2; }
trap _on_exit EXIT

_SKIP_DEFAULTS=0
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
_IMG_EXISTED=0
_local_running=0
_full_count=0
DEMO_SNAPSHOT_GCS_URI=""
BAKE_VM_NAME=""
BAKE_VM_NETWORK=""
BAKE_VM_SUBNET=""
BAKE_SECRET_NAME=""
S3_SOURCE_URI=""
_GCS_BASENAME=""
USE_TYPESENSE="false"
TYPESENSE_URL=""
TYPESENSE_API_KEY=""
TYPESENSE_SEARCH_KEY=""
USE_FULLTEXT="false"

# ── Load modules ──────────────────────────────────────────────────────────────
source "$ROOT_DIR/scripts/deploy/util.sh"
source "$ROOT_DIR/scripts/deploy/prompts.sh"
source "$ROOT_DIR/scripts/deploy/local.sh"
source "$ROOT_DIR/scripts/deploy/db.sh"
source "$ROOT_DIR/scripts/deploy/infra.sh"
source "$ROOT_DIR/scripts/deploy/frontend.sh"

# ── Remote orchestrator ───────────────────────────────────────────────────────

_deploy_remote() {
  _check_adc
  _deploy_pulumi
  _setup_db_post_pulumi

  _resolve_snapshot_vars
  _check_db_row_count
  _seed_db
  [[ "$USE_NEON" == "true" ]] && _neon_premigrate_heavy
  [[ "$USE_NEON" == "true" && "${_DB_ORDERS:-0}" -gt 0 ]] && _save_snapshot_to_gcs
  _sync_daily_order_count
  _seed_typesense

  _scale_down_gke_if_switching

  if [[ "$BACKEND_RUNTIME" == "gke" ]]; then
    _deploy_gke
  else
    BACKEND_URL=$(cd "$ROOT_DIR/infra" && pulumi stack output backendUrl 2>/dev/null || true)
  fi

  _STEP="post-deploy"
  _patch_frontend_backend_url
  _save_env_file

  printf '\nBackend URL: %s\n' "$BACKEND_URL"

  _update_readme
  _deploy_frontend_inline

  printf '\nRemember to tear down when finished:\n  ./scripts/infra-down.sh\n'

  _post_deploy_checks
  _warn_neon_storage
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

_run_preflight
_prompt_defaults_check

if (( _SKIP_DEFAULTS == 2 )); then
  :
elif (( _SKIP_DEFAULTS == 1 )); then
  _prompt_database_backend
else
  _prompt_menu
  _prompt_backend_runtime
  _prompt_database_backend
  _prompt_typesense
  _prompt_fulltext
fi

_save_user_inputs
_print_cost_summary

[[ "$_TARGET" == "local" ]] && _deploy_local

_check_gcloud
_resolve_gcp_config
_preflight_db
_resolve_image

if [[ "$_IMG_EXISTED" == "1" && "$BACKEND_RUNTIME" == "cr" && "$USE_NEON" == "true" ]]; then
  DEPLOY_MODE_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash-full')
  _be_svc="${DEPLOY_MODE_PREFIX}-backend"
  _deployed_img=$(gcloud run services describe "$_be_svc" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(spec.template.spec.containers[0].image)" 2>/dev/null || true)
  if [[ "$_deployed_img" == "$IMAGE" ]]; then
    _check_db_row_count
    if [[ "${_DB_ORDERS:-0}" -eq 0 ]]; then
      printf '  Image unchanged but DB empty — continuing to seed.\n'
    else
      printf '  Cloud Run already serving %s — skipping Pulumi + seed.\n' "${IMAGE##*:}"
      BACKEND_URL=$(gcloud run services describe "$_be_svc" \
        --region "$GCP_REGION" --project "$GCP_PROJECT" \
        --format="value(status.url)" 2>/dev/null || true)
      _patch_frontend_backend_url
      cd "$ROOT_DIR/infra"
      _save_env_file
      _seed_typesense
      printf '\nBackend URL: %s\n' "$BACKEND_URL"
      _update_readme
      _deploy_frontend_inline
      _post_deploy_checks
      _warn_neon_storage
      exit 0
    fi
  fi
fi

_deploy_remote
