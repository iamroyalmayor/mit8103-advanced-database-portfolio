#!/usr/bin/env bash
# S7: pgbench stress tests (unsafe read-modify-write vs transfer_funds) on 50 hot accounts.
set -u
cd "$(dirname "$0")"
EV=evidence
export MSYS_NO_PATHCONV=1
q() { docker exec nf-pg psql -U postgres -d nairaflow -X -P pager=off -qAt -c "SET search_path TO nairaflow; $1"; }
# ---- S7 pgbench stress tests ---------------------------------------------
docker cp pgbench/unsafe_transfer.sql nf-pg:/tmp/ >/dev/null
docker cp pgbench/safe_transfer.sql   nf-pg:/tmp/ >/dev/null
{
  echo "=== BEFORE unsafe run ==="; docker exec -i nf-pg psql -U postgres -d nairaflow -X -P pager=off -f /dev/stdin < sql/02_stress_checks.sql
  echo "=== pgbench: UNSAFE read-modify-write, 16 clients, 15 s ==="
  docker exec nf-pg pgbench -U postgres -n -c 16 -j 4 -T 15 -f /tmp/unsafe_transfer.sql nairaflow 2>&1
  echo "=== AFTER unsafe run (money created/destroyed by lost updates) ==="
  docker exec -i nf-pg psql -U postgres -d nairaflow -X -P pager=off -f /dev/stdin < sql/02_stress_checks.sql
} > $EV/08_s7_pgbench_unsafe.txt 2>&1
echo "  -> $EV/08_s7_pgbench_unsafe.txt"
# repair: the ledger is the source of truth
q "SELECT count(resync_balance(account_number)) FROM account WHERE account_number BETWEEN '3000000001' AND '3000000050'" >/dev/null
q "SELECT 1" >/dev/null
{
  echo "=== Balances re-synchronised from the ledger after the unsafe run ==="
  docker exec -i nf-pg psql -U postgres -d nairaflow -X -P pager=off -f /dev/stdin < sql/02_stress_checks.sql
  echo "=== pgbench: SAFE transfer_funds(), 16 clients, 15 s ==="
  docker exec nf-pg pgbench -U postgres -n -c 16 -j 4 -T 15 -f /tmp/safe_transfer.sql nairaflow 2>&1
  echo "=== AFTER safe run ==="
  docker exec -i nf-pg psql -U postgres -d nairaflow -X -P pager=off -f /dev/stdin < sql/02_stress_checks.sql
} > $EV/09_s7_pgbench_safe.txt 2>&1
echo "  -> $EV/09_s7_pgbench_safe.txt"
