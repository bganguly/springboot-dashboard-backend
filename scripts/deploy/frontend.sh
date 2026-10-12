#!/usr/bin/env bash

# ── Frontend URL patch ────────────────────────────────────────────────────────

_patch_frontend_backend_url() {
  [[ "$BACKEND_RUNTIME" == "gke" ]] && return 0
  [[ -z "$BACKEND_URL" ]] && return 0
  local fe_svc="${DEPLOY_MODE_PREFIX}-frontend"
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
    printf '  Patching frontend BACKEND_URL: %s\n' "$BACKEND_URL"
    gcloud run services update "$fe_svc" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" \
      --update-env-vars "BACKEND_URL=${BACKEND_URL}" --quiet 2>/dev/null || true
  fi
}

_deploy_frontend_inline() {
  local fe_deploy="${ROOT_DIR}/../dashboard-frontend/scripts/deploy.sh"
  [[ -f "$fe_deploy" ]] || return 0
  printf '\nDeploy frontend (java-implementations/dashboard-frontend)? [y/N]: '
  read -r _FE_CONTINUE
  case "${_FE_CONTINUE:-N}" in
    [Yy]*) ;;
    *) printf '  Skipping frontend deploy.\n'; return 0 ;;
  esac
  _STEP="frontend deploy"
  printf '\n  Deploying frontend inline...\n'
  DEPLOY_MODE="$DEPLOY_MODE" BACKEND_URL="$BACKEND_URL" bash "$fe_deploy"
}

# ── Typesense seed ────────────────────────────────────────────────────────────

_seed_typesense() {
  [[ "$USE_TYPESENSE" != "true" ]] && return 0
  [[ -z "${TYPESENSE_URL:-}" || -z "${TYPESENSE_API_KEY:-}" ]] && return 0
  printf '\n=== Typesense collection ===\n'
  local db_arg=""
  if [[ "${_TARGET:-remote}" == "local" ]]; then
    db_arg="--db-url postgresql://$(whoami):@localhost:5432/database_flyway_orm"
  elif [[ "$USE_NEON" == "true" && -n "${NEON_DATABASE_URL:-}" ]]; then
    db_arg="--db-url ${NEON_DATABASE_URL}"
  else
    printf '  GCE-backed DB — cannot reach Postgres from here. Seed manually:\n'
    printf '    ./scripts/seed-typesense.sh --db-url <internal-pg-url>\n'
    return 0
  fi
  TYPESENSE_URL="$TYPESENSE_URL" TYPESENSE_API_KEY="$TYPESENSE_API_KEY" \
    "$ROOT_DIR/scripts/seed-typesense.sh" $db_arg
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

  local health=""
  local _attempt
  for _attempt in 1 2 3 4 5; do
    health=$(curl -sf "${BACKEND_URL}/actuator/health" --max-time 8 2>/dev/null \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    [[ "$health" == "UP" ]] && break
    printf '  [4] waiting for /actuator/health (attempt %s/5)...\n' "$_attempt"
    sleep $(( _attempt * 5 ))
  done
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

  local http6="000"
  for _attempt in 1 2 3 4 5; do
    http6=$(curl -sf -o /dev/null -w "%{http_code}" "${BACKEND_URL}/api/customers" --max-time 8 2>/dev/null || echo "000")
    [[ "$http6" == "200" ]] && break
    printf '  [6] waiting for /api/customers (attempt %s/5)...\n' "$_attempt"
    sleep $(( _attempt * 5 ))
  done
  [[ "$http6" == "200" ]] && _chk 6 "GET /api/customers → 200" 1 || _chk 6 "GET /api/customers → 200" 0 "HTTP $http6"

  [[ "${_DB_ORDERS:-0}" -gt 0 ]] \
    && _chk 7 "Database has data" 1 "${_DB_ORDERS} orders" \
    || _chk 7 "Database has data" 0 "0 orders — seed may have failed"

  local _FE_SVC
  _FE_SVC=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-react-lite-frontend' || printf 'dash-react-frontend')
  local fe_url
  fe_url=$(gcloud run services describe "$_FE_SVC" \
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
  if (( _CF > 0 )); then printf '\n  !! %d CHECK(S) FAILED — review above before presenting\n' "$_CF"; fi
  if [[ "$DEPLOY_MODE" == "full" && "$USE_NEON" != "true" ]]; then
    printf '\n  !! REMINDER: FULL MODE WITH GCE VM (~$52/mo+) — run infra-down.sh when done\n'
  fi
  return 0
}

_warn_neon_storage() { :; }
