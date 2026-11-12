#!/usr/bin/env bash
# Portfolio 5 runner: starts the distributed topology, runs the demos, tears it down.
set -u
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
mkdir -p evidence
docker compose down -v >/dev/null 2>&1
docker compose up -d 2>&1 | tail -3
for i in $(seq 1 120); do docker exec p5-pg-replica pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec p5-pg-replica pg_isready -U postgres >/dev/null 2>&1 || { echo "replica did not start"; docker logs --tail 20 p5-pg-replica; exit 1; }
docker compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}' > evidence/00_topology.txt

bash postgres-replication/replication_demo.sh 2>&1 | tr -d '\r' > evidence/01_postgres_replication_failover.txt
echo "  -> evidence/01_postgres_replication_failover.txt"

# shard-key simulation runs on the promoted replica (now the writable primary)
docker cp sharding/shard_key_simulation.sql p5-pg-replica:/tmp/ >/dev/null
docker exec p5-pg-replica psql -U postgres -d nairaflow -X -e -P pager=off -f /tmp/shard_key_simulation.sql \
  2>&1 | tr -d '\r' > evidence/02_shard_key_simulation.txt
echo "  -> evidence/02_shard_key_simulation.txt"

bash mongodb-replica-set/replica_set_demo.sh 2>&1 | tr -d '\r' > evidence/03_mongodb_replica_set_failover.txt
echo "  -> evidence/03_mongodb_replica_set_failover.txt"

[ "${KEEP_UP:-0}" = "1" ] || docker compose down -v >/dev/null 2>&1
