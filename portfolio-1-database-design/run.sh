#!/usr/bin/env bash
# Portfolio 1 runner: builds the schema, loads seed data, runs validation tests.
# Requires the container started by ../scripts/start_postgres.sh
set -eu
cd "$(dirname "$0")"
RUN=../scripts/psql_run.sh
mkdir -p evidence
bash $RUN sql/01_schema.sql           evidence/01_schema_output.txt
bash $RUN sql/02_seed_data.sql        evidence/02_seed_output.txt
bash $RUN sql/03_validation_tests.sql evidence/03_validation_tests_output.txt
MSYS_NO_PATHCONV=1 docker exec -t nf-pg psql -U postgres -d nairaflow -X -P pager=off \
  -c '\d+ nairaflow.account' -c '\d nairaflow.ledger_entry' -c '\d nairaflow.txn' \
  | tr -d '\r' > evidence/04_table_definitions.txt
echo "  -> evidence/04_table_definitions.txt"
