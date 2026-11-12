#!/bin/bash
# Runs once on first start of the primary: replication role + pg_hba rule.
set -e
psql -v ON_ERROR_STOP=1 -U postgres -d nairaflow <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator-secret';
SQL
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
