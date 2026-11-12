#!/usr/bin/env bash
# Usage: psql_run.sh <sql-file> <output-file> [container] [database]
# Copies a SQL file into the container and runs it with echo of every statement (-e).
# A pseudo-TTY (-t) keeps stdout and stderr (ERROR lines) in the correct order in the log.
set -u
SQL="$1"; OUT="$2"; CTR="${3:-nf-pg}"; DB="${4:-nairaflow}"
NAME="$(basename "$SQL")"
MSYS_NO_PATHCONV=1 docker cp "$SQL" "$CTR:/tmp/$NAME" >/dev/null
MSYS_NO_PATHCONV=1 docker exec -t "$CTR" psql -U postgres -d "$DB" -X -e -P pager=off -f "/tmp/$NAME" 2>&1 \
  | tr -d '\r' > "$OUT"
echo "  -> $OUT"
