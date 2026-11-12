#!/usr/bin/env bash
# Starts the single PostgreSQL 16 instance used by Portfolios 1-3.
set -eu
docker rm -f nf-pg >/dev/null 2>&1 || true
docker run -d --name nf-pg \
  -e POSTGRES_PASSWORD=nairaflow -e POSTGRES_DB=nairaflow \
  --shm-size=512m postgres:16 \
  -c shared_buffers=256MB -c work_mem=16MB -c log_lock_waits=on -c deadlock_timeout=1s
until docker exec nf-pg pg_isready -U postgres -d nairaflow >/dev/null 2>&1; do sleep 1; done
sleep 2
docker exec nf-pg psql -U postgres -d nairaflow -c "select version();"
