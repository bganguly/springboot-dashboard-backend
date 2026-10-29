#!/usr/bin/env bash

# ── Defaults check ────────────────────────────────────────────────────────────

_prompt_defaults_check() {
  local _db_label
  local _saved_neon
  _saved_neon=$(grep -E '^USE_NEON=' "$ROOT_DIR/.env.gcp.full" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  if [[ "$_saved_neon" == "true" ]]; then
    _db_label="Neon serverless Postgres (using saved creds)"
  else
    _db_label="Neon serverless Postgres (free tier, prompted next)"
  fi
  printf '\n=== springboot-dashboard-backend-gcp deploy ===\n\n'
  printf '  Defaults:\n'
  printf '    Target:   Full remote (GCP, 4M-row dataset)\n'
  printf '    Backend:  Cloud Run  (serverless, scales to zero)\n'
  printf '    Database: %s\n' "$_db_label"
  printf '    Search:   Postgres ILIKE trigram  (no Typesense)\n'
  printf '    Fulltext: Disabled  (instead see ILIKE trigram above)\n'
  printf '    Seed:     Use existing (if 4M orders present)\n'
  printf '\nContinue with defaults? [Y/n]: '
  read -r _DFLT
  case "${_DFLT:-Y}" in
    [Nn]*) _SKIP_DEFAULTS=0 ;;
    *)     _SKIP_DEFAULTS=1; _TARGET="remote"; DEPLOY_MODE="full"; BACKEND_RUNTIME="cr"
           USE_TYPESENSE="false"; USE_FULLTEXT="false"
           if [[ "$_saved_neon" == "true" ]]; then
             USE_NEON=$(grep -E '^USE_NEON=' "$ROOT_DIR/.env.gcp.full" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
             NEON_DATABASE_URL=$(grep -E '^NEON_DATABASE_URL=' "$ROOT_DIR/.env.gcp.full" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
             _SKIP_DEFAULTS=2
           fi
           ;;
  esac
}

# ── Menu ──────────────────────────────────────────────────────────────────────

_prompt_menu() {
  printf '\n=== springboot-dashboard-backend-gcp ===\n\n'
  printf '  [1] Local  — Spring Boot on localhost + local Postgres (no GCP cost)'
  (( _local_running )) && printf ' [running]' || printf ' [not detected]'
  printf '\n'
  printf '  [2] Full   — GCP: 4M-row dataset  · Cloud Run backend · Neon or GCE Postgres'
  (( _full_count > 0 )) && printf ' [%s resources active]' "$_full_count" || printf ' [not deployed]'
  printf '\n'
  printf '\nChoice [1/2, default 2]: '
  read -r _MODE
  case "${_MODE:-2}" in
    1) _TARGET="local";  DEPLOY_MODE=""    ;;
    *) _TARGET="remote"; DEPLOY_MODE="full" ;;
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
    printf '\n  Backend: Cloud Run (serverless, scales to zero). Keep Cloud Run? [Y/n]: '
    read -r _BR
    case "${_BR:-Y}" in
      [Nn]*) BACKEND_RUNTIME="gke" ;;
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
    printf '  Continue with saved? [Y/n]: '
    read -r _REPLACE
    case "${_REPLACE:-Y}" in
      [Nn]*)
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

_prompt_typesense() {
  local TS_CREDS_FILE="$ROOT_DIR/.typesense-creds"
  local SIBLING_CREDS="$ROOT_DIR/../../typescript-implementations/clickhouse-dashboard/.typesense-creds"

  local env_file
  if [[ "$_TARGET" == "remote" ]]; then
    env_file="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  else
    env_file="$ROOT_DIR/.env.local"
  fi

  local saved_enabled=""
  if [[ -f "$env_file" ]]; then
    saved_enabled=$(grep -E '^USE_TYPESENSE=' "$env_file" | cut -d= -f2- | tr -d '"' || true)
  fi

  if [[ -n "$saved_enabled" && "$saved_enabled" == "false" ]]; then
    printf '\n  Search: Postgres ILIKE (saved setting). Re-enable Typesense? [y/N]: '
    read -r _TS_RECHECK
    case "${_TS_RECHECK:-N}" in
      [Yy]*) saved_enabled="" ;;
      *)     USE_TYPESENSE="false"
             printf '# Typesense disabled: collection/URL may have been deleted — re-create before re-enabling\n' > "${TS_CREDS_FILE}.disabled"
             return 0 ;;
    esac
  fi

  if [[ -f "$TS_CREDS_FILE" ]]; then
    source "$TS_CREDS_FILE"
  elif [[ -f "$SIBLING_CREDS" ]]; then
    source "$SIBLING_CREDS"
    cp "$SIBLING_CREDS" "$TS_CREDS_FILE"
    chmod 600 "$TS_CREDS_FILE"
    printf '\n  Loaded Typesense creds from clickhouse-dashboard, copied to .typesense-creds\n'
  fi

  if [[ -n "${TYPESENSE_URL:-}" && -n "${TYPESENSE_API_KEY:-}" ]]; then
    printf '\n  Typesense creds found: %s\n' "$TYPESENSE_URL"
    printf '  Use Typesense for search? [Y/n]: '
    read -r _TS
    case "${_TS:-Y}" in
      [Nn]*) USE_TYPESENSE="false"
             printf '# Typesense disabled: collection/URL may have been deleted — re-create before re-enabling\n' > "${TS_CREDS_FILE}.disabled"
             return 0 ;;
      *)     USE_TYPESENSE="true"
             rm -f "${TS_CREDS_FILE}.disabled"
             ;;
    esac
    printf '  Override URL/key? [y/N]: '
    read -r _TS_OVERRIDE
    case "${_TS_OVERRIDE:-N}" in
      [Yy]*)
        printf '  Typesense URL:\n  > '
        read -r TYPESENSE_URL
        [[ -n "$TYPESENSE_URL" ]] || { printf 'Typesense URL is required.\n'; exit 1; }
        [[ "$TYPESENSE_URL" == http://* || "$TYPESENSE_URL" == https://* ]] || TYPESENSE_URL="https://${TYPESENSE_URL}"
        printf '  Admin API key:\n  > '
        read -rs TYPESENSE_API_KEY; printf '\n'
        [[ -n "$TYPESENSE_API_KEY" ]] || { printf 'Admin API key is required.\n'; exit 1; }
        printf '  Search-only key:\n  > '
        read -rs TYPESENSE_SEARCH_KEY; printf '\n'
        [[ -n "$TYPESENSE_SEARCH_KEY" ]] || { printf 'Search-only key is required.\n'; exit 1; }
        printf 'TYPESENSE_URL=%s\nTYPESENSE_API_KEY=%s\nTYPESENSE_SEARCH_KEY=%s\n' "$TYPESENSE_URL" "$TYPESENSE_API_KEY" "$TYPESENSE_SEARCH_KEY" > "$TS_CREDS_FILE"
        chmod 600 "$TS_CREDS_FILE"
        printf '  Saved to .typesense-creds\n'
        ;;
    esac
    return 0
  fi

  printf '\n  Search backend:\n'
  printf '  [Y] Typesense  — sub-5ms name+notes search (requires a running Typesense instance with orders indexed)\n'
  printf '  [N] Postgres ILIKE via GIN trigram index (current default)\n'
  printf '\nUse Typesense? [y/N]: '
  read -r _TS
  case "${_TS:-N}" in
    [Yy]*) USE_TYPESENSE="true"
           rm -f "${TS_CREDS_FILE}.disabled"
           ;;
    *)     USE_TYPESENSE="false"
           printf '# Typesense disabled: collection/URL may have been deleted — re-create before re-enabling\n' > "${TS_CREDS_FILE}.disabled"
           return 0 ;;
  esac

  printf '  Typesense URL (e.g. https://your-cluster.a1.typesense.net):\n  > '
  read -r TYPESENSE_URL
  [[ -n "$TYPESENSE_URL" ]] || { printf 'Typesense URL is required.\n'; exit 1; }
  [[ "$TYPESENSE_URL" == http://* || "$TYPESENSE_URL" == https://* ]] || TYPESENSE_URL="https://${TYPESENSE_URL}"

  printf '  Admin API key:\n  > '
  read -rs TYPESENSE_API_KEY; printf '\n'
  [[ -n "$TYPESENSE_API_KEY" ]] || { printf 'Admin API key is required.\n'; exit 1; }

  printf '  Search-only key:\n  > '
  read -rs TYPESENSE_SEARCH_KEY; printf '\n'
  [[ -n "$TYPESENSE_SEARCH_KEY" ]] || { printf 'Search-only key is required.\n'; exit 1; }

  printf 'TYPESENSE_URL=%s\nTYPESENSE_API_KEY=%s\nTYPESENSE_SEARCH_KEY=%s\n' "$TYPESENSE_URL" "$TYPESENSE_API_KEY" "$TYPESENSE_SEARCH_KEY" > "$TS_CREDS_FILE"
  chmod 600 "$TS_CREDS_FILE"
  printf '  Saved to .typesense-creds\n'
}

_prompt_fulltext() {
  local env_file
  if [[ "$_TARGET" == "remote" ]]; then
    env_file="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  else
    env_file="$ROOT_DIR/.env.local"
  fi

  local saved=""
  if [[ -f "$env_file" ]]; then
    saved=$(grep -E '^USE_FULLTEXT=' "$env_file" | cut -d= -f2- | tr -d '"' || true)
  fi

  if [[ -n "$saved" ]]; then
    if [[ "$saved" == "true" ]]; then
      printf '\n  Search: Postgres full-text (saved). Keep? [Y/n]: '
    else
      printf '\n  Search: Postgres ILIKE (saved). Enable full-text search? [y/N]: '
    fi
    read -r _FT_RECHECK
    case "${_FT_RECHECK:-}" in
      [Yy]*) USE_FULLTEXT="true"; return 0 ;;
      [Nn]*) USE_FULLTEXT="false"; return 0 ;;
      *)     USE_FULLTEXT="$saved"; return 0 ;;
    esac
  fi

  printf '\n  Postgres search mode:\n'
  printf '  [Y] Full-text search (tsvector/GIN — whole-word, ranking-ready, websearch syntax)\n'
  printf '  [N] ILIKE trigram (substring match, current default)\n'
  printf '\nEnable Postgres full-text search? [y/N]: '
  read -r _FT
  case "${_FT:-N}" in
    [Yy]*) USE_FULLTEXT="true" ;;
    *)     USE_FULLTEXT="false" ;;
  esac
}

_print_cost_summary() {
  [[ "$_TARGET" != "remote" ]] && return 0
  if [[ "$DEPLOY_MODE" == "lite" ]]; then
    [[ "$USE_NEON" == "true" ]] && printf '  Cost: ~$0-2/mo (Cloud Run + Neon free tier)\n' \
    || { [[ "$BACKEND_RUNTIME" == "gke" ]] \
      && printf '  Cost: ~$66/mo (GKE + VM)\n' \
      || printf '  Cost: ~$52/mo (Cloud Run + VM)\n'; }
  else
    if [[ "$USE_NEON" == "true" ]]; then
      printf '  Cost: ~$1-3/mo (Full · Cloud Run + Neon free tier)\n'
    elif [[ "$BACKEND_RUNTIME" == "gke" ]]; then
      printf '\n!! FULL + GKE + VM — ~$200-300/mo — tear down when done !!\n'
      printf '  Type YES to continue: '; read -r _FULL_CONFIRM
      [[ "$_FULL_CONFIRM" == "YES" ]] || { printf 'Aborted.\n'; exit 0; }
    else
      printf '\n!! FULL + Cloud Run + VM — ~$52/mo — tear down when done !!\n'
      printf '  Type YES to continue: '; read -r _FULL_CONFIRM
      [[ "$_FULL_CONFIRM" == "YES" ]] || { printf 'Aborted.\n'; exit 0; }
    fi
  fi
}
