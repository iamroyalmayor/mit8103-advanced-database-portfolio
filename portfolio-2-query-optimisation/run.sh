#!/usr/bin/env bash
# Portfolio 2 runner.  Prerequisite: Portfolio 1 has been run (schema + seed).
#   1. generate ~2.1M ledger rows      2. run workload BEFORE indexes
#   3. create indexes                   4. run workload AFTER indexes
#   5. partitioning experiment          6. build a before/after timing table
set -eu
cd "$(dirname "$0")"
RUN=../scripts/psql_run.sh
mkdir -p evidence
if [ "${SKIP_GENERATE:-0}" != "1" ]; then
  bash $RUN sql/01_generate_data.sql evidence/01_generate_data_output.txt
fi
# make sure the "before" run really has no tuning indexes
docker exec nf-pg psql -U postgres -d nairaflow -qXc "SET search_path TO nairaflow;
  DROP INDEX IF EXISTS ix_ledger_account_time, ix_customer_email_lower,
                       ix_txn_failed_created, ix_ledger_time_covering;"
bash $RUN sql/02_workload_queries.sql evidence/02_before_indexes.txt
bash $RUN sql/03_create_indexes.sql   evidence/03_create_indexes_output.txt
bash $RUN sql/02_workload_queries.sql evidence/04_after_indexes.txt
bash $RUN sql/04_partitioning.sql     evidence/05_partitioning_output.txt

# ---- timing summary -------------------------------------------------------
extract() {  # prints "Qn<TAB>ms" for each query block in a log
  awk '/^### Q[0-9]/ {q=$2} /Execution Time:/ {print q "\t" $(NF-1)}' "$1"
}
{
  echo "| Query | Before indexes (ms) | After indexes (ms) | Speed-up |"
  echo "|---|---:|---:|---:|"
  join -t $'\t' <(extract evidence/02_before_indexes.txt) <(extract evidence/04_after_indexes.txt) |
    awk -F'\t' '{ printf "| %s | %.1f | %.2f | %.0fx |\n", $1, $2, $3, ($3>0? $2/$3 : 0) }'
} > evidence/06_performance_summary.md
cat evidence/06_performance_summary.md
