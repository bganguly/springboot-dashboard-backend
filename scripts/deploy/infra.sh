#!/usr/bin/env bash

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
  local cache_tag tmpyaml
  cache_tag="${tag%:*}:cache"
  tmpyaml=$(mktemp /tmp/cloudbuild.XXXXXX)
  cat > "$tmpyaml" <<YAML
steps:
- name: 'gcr.io/cloud-builders/docker'
  entrypoint: bash
  args:
  - -c
  - |
    docker pull '${cache_tag}' 2>/dev/null || true
    docker build --cache-from '${cache_tag}' -t '${tag}' -t '${cache_tag}' .
- name: 'gcr.io/cloud-builders/docker'
  args: [push, '${tag}']
- name: 'gcr.io/cloud-builders/docker'
  args: [push, '${cache_tag}']
images:
- '${tag}'
- '${cache_tag}'
YAML
  local attempt=0 rc
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    set +e; gcloud builds submit --config "$tmpyaml" --project "$project" "$srcdir"; rc=$?; set -e
    [[ "$rc" == "0" ]] && { rm -f "$tmpyaml"; return 0; }
    [[ "$rc" == "130" ]] && { printf '\n[deploy] Build cancelled.\n'; rm -f "$tmpyaml"; exit 130; }
    (( attempt < 3 )) && { printf '  Cloud Build failed (attempt %d/3) — waiting 20s...\n' "$attempt"; sleep 20; }
  done
  rm -f "$tmpyaml"
  printf '[deploy] Cloud Build failed after 3 attempts.\n' >&2; return 1
}

_resolve_image() {
  local ar_state
  ar_state=$(gcloud services list --project="$GCP_PROJECT" \
    --filter="name:artifactregistry.googleapis.com" --format="value(state)" 2>/dev/null || true)
  [[ "$ar_state" != "ENABLED" ]] && gcloud services enable artifactregistry.googleapis.com --project="$GCP_PROJECT"

  local _prefix; _prefix=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash-full')
  local registry="${_prefix}-repo"

  if ! gcloud artifacts repositories describe "$registry" \
      --project="$GCP_PROJECT" --location="$GCP_REGION" >/dev/null 2>&1; then
    printf '  Creating repo "%s"...\n' "$registry"
    gcloud artifacts repositories create "$registry" \
      --repository-format=docker --location="$GCP_REGION" --project="$GCP_PROJECT"
  fi

  local tag
  tag=$(find "$ROOT_DIR/src" "$ROOT_DIR/Dockerfile" \
      "$ROOT_DIR/docker-entrypoint.sh" \
      "$ROOT_DIR/build.gradle.kts" "$ROOT_DIR/settings.gradle.kts" \
      -type f 2>/dev/null | sort | xargs cat 2>/dev/null \
    | _shasum | cut -c1-16 || true)
  tag="${tag:-$(date +%Y%m%d%H%M%S)}"
  IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${registry}/backend:${tag}"

  local exists
  exists=$(gcloud artifacts docker tags list \
    "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${registry}/backend" \
    --filter="tag=${tag}" --format="value(tag)" \
    --project "$GCP_PROJECT" 2>/dev/null | head -1 || true)

  if [[ -n "$exists" ]]; then
    printf '  Image %s exists — skipping build.\n' "$tag"
    _IMG_EXISTED=1; return 0
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
  gcloud auth application-default print-access-token >/dev/null 2>&1 && return 0
  printf '  Setting up ADC (required by Pulumi)...\n'
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
  dashboard:typesenseEnabled: ${USE_TYPESENSE}
  dashboard:typesenseUrl: ${TYPESENSE_URL}
  dashboard:fulltextEnabled: ${USE_FULLTEXT}
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
  dashboard:typesenseEnabled: ${USE_TYPESENSE}
  dashboard:typesenseUrl: ${TYPESENSE_URL}
  dashboard:fulltextEnabled: ${USE_FULLTEXT}
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

  local existing
  existing=$(gcloud secrets versions access latest \
    --secret="$secret_name" --project="$GCP_PROJECT" 2>/dev/null || true)

  if [[ -n "$existing" && "$existing" == "$NEON_DATABASE_URL" ]]; then
    printf '  Neon secret already up to date.\n'
    return 0
  fi

  if [[ -n "$existing" ]]; then
    printf '  Neon secret URL changed — adding new version...\n'
  else
    printf '  Secret has no versions (state drift) — adding Neon URL now...\n'
  fi

  printf '%s' "$NEON_DATABASE_URL" | gcloud secrets versions add "$secret_name" \
    --data-file=- --project="$GCP_PROJECT"

  local sv_urn
  sv_urn=$(pulumi stack export 2>/dev/null | python3 -c "
import sys, json
for r in json.load(sys.stdin).get('deployment',{}).get('resources',[]):
    urn = r.get('urn','')
    if 'SecretVersion' in urn and 'database-url-v1' in urn:
        print(urn); break
" 2>/dev/null || true)
  [[ -n "$sv_urn" ]] && pulumi state delete "$sv_urn" --yes 2>/dev/null || true
  printf '  Secret version updated — pulumi up will re-import.\n'
}

_deploy_pulumi() {
  printf '\n=== deploying via Pulumi ===\n'
  cd "$ROOT_DIR/infra"
  [[ -d node_modules ]] || npm install --prefer-offline 2>/dev/null || npm install
  pulumi stack select "$DEPLOY_MODE" 2>/dev/null || pulumi stack init "$DEPLOY_MODE"
  DEPLOY_MODE_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash-full')
  _write_pulumi_yaml
  if [[ "$USE_NEON" == "true" ]]; then
    pulumi config set --secret dashboard:neonDatabaseUrl "$NEON_DATABASE_URL" --stack "$DEPLOY_MODE"
  fi
  if [[ "$USE_TYPESENSE" == "true" && -n "${TYPESENSE_API_KEY:-}" ]]; then
    pulumi config set --secret dashboard:typesenseApiKey "$TYPESENSE_API_KEY" --stack "$DEPLOY_MODE"
    pulumi config set --secret dashboard:typesenseSearchKey "${TYPESENSE_SEARCH_KEY:-${TYPESENSE_API_KEY}}" --stack "$DEPLOY_MODE"
  fi
  _ensure_neon_secret_version
  _flyway_repair_neon
  _neon_premigrate_heavy
  _STEP="pulumi up"
  _pulumi_up_robust
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
