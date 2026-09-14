#!/usr/bin/env bash
set -euo pipefail

TIER="${TIER:-full}"
PROJECT="bikram-java"
LOCATION="us-central1"
ZONE="${LOCATION}-a"
PREFIX="dash-${TIER}"
CLUSTER="${PREFIX}-cluster"
CMD="${1:-}"

_is_gke() {
  gcloud container clusters describe "$CLUSTER" \
    --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1
}

_gke_nodes() {
  gcloud container clusters describe "$CLUSTER" \
    --zone "$ZONE" --project "$PROJECT" \
    --format="value(currentNodeCount)" 2>/dev/null || echo "0"
}

_cr_min() {
  gcloud run services describe "${PREFIX}-backend" \
    --region "$LOCATION" --project "$PROJECT" \
    --format="value(spec.template.metadata.annotations['autoscaling.knative.dev/minScale'])" \
    2>/dev/null || echo "?"
}

_do_scale() {
  local cmd="$1"
  case "$cmd" in
    up)
      if _is_gke; then
        printf 'GKE — scaling node pool to 1...\n'
        gcloud container clusters resize "$CLUSTER" \
          --node-pool default-pool --num-nodes 1 \
          --zone "$ZONE" --project "$PROJECT" --quiet
        printf 'Node coming up; Spring Boot will be ready in ~2-3 min.\n'
      else
        gcloud run services update "${PREFIX}-backend" \
          --min-instances 1 --region "$LOCATION" --project "$PROJECT" --quiet
        printf 'Cloud Run min-instances set to 1.\n'
      fi
      ;;
    down)
      if _is_gke; then
        printf 'GKE — scaling node pool to 0...\n'
        gcloud container clusters resize "$CLUSTER" \
          --node-pool default-pool --num-nodes 0 \
          --zone "$ZONE" --project "$PROJECT" --quiet
        printf 'Node pool at 0. No node charges until next scale-up.\n'
      else
        gcloud run services update "${PREFIX}-backend" \
          --min-instances 0 --region "$LOCATION" --project "$PROJECT" --quiet
        printf 'Cloud Run min-instances set to 0.\n'
      fi
      ;;
  esac
}

_menu() {
  printf '\n=== scale.sh — %s (%s) ===\n' "$PREFIX" "$(if _is_gke; then printf 'GKE · nodes=%s' "$(_gke_nodes)"; else printf 'Cloud Run · min=%s' "$(_cr_min)"; fi)"
  printf '  Wake-on-demand: scale up before a demo, down when done.\n\n'
  printf '  [1] Start — bring backend online (min-instances=1)\n'
  printf '  [2] Stop  — scale to zero (no charges)\n'
  printf '  [enter] Do nothing\n'
  printf '\nChoice [1/2]: '
  read -r _CHOICE
  case "${_CHOICE:-}" in
    1) _do_scale up   ;;
    2) _do_scale down ;;
    *) printf 'No change.\n' ;;
  esac
}

if [[ -z "$CMD" ]]; then
  _menu
else
  _do_scale "$CMD"
fi
