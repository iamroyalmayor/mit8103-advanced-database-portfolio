#!/usr/bin/env bash
# Rebuilds the PostgreSQL evidence for Portfolios 1-3 from a clean container.
# Total runtime ~12-15 minutes (the 2.1M-row data load dominates).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/start_postgres.sh"
echo "== Portfolio 1 =="; bash "$ROOT/portfolio-1-database-design/run.sh"
echo "== Portfolio 2 =="; bash "$ROOT/portfolio-2-query-optimisation/run.sh"
echo "== Portfolio 3 =="; bash "$ROOT/portfolio-3-transactions-concurrency/run.sh"
echo "All PostgreSQL evidence regenerated."
