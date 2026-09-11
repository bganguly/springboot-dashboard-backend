#!/bin/sh
set -eu

if [ -n "${DATABASE_URL:-}" ]; then
  _CONN="${DATABASE_URL#*://}"
  _HOST_PORT="${_CONN#*@}"
  _HOST_PORT="${_HOST_PORT%%/*}"
  DB_HOST="${_HOST_PORT%:*}"
  DB_PORT="${_HOST_PORT##*:}"
  [ "$DB_PORT" = "$_HOST_PORT" ] && DB_PORT="5432"
  printf '[entrypoint] Waiting for Postgres at %s:%s...\n' "$DB_HOST" "$DB_PORT"
  i=0
  until nc -z -w2 "$DB_HOST" "$DB_PORT" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 72 ]; then
      printf '[entrypoint] Timed out after 12 min — Postgres still unreachable\n' >&2
      exit 1
    fi
    printf '[entrypoint]   not ready (attempt %d/72) — retrying in 10s\n' "$i"
    sleep 10
  done
  printf '[entrypoint] Postgres is up.\n'
fi

exec java -jar app.jar
