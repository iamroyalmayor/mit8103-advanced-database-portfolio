#!/usr/bin/env bash
# Portfolio 4 runner: MongoDB 7 (single-node replica set, needed for
# multi-document transactions) + Redis 7. Evidence is written to evidence/.
set -eu
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
mkdir -p evidence

docker rm -f nf-mongo nf-redis >/dev/null 2>&1 || true
docker run -d --name nf-mongo mongo:7 --replSet rs0 --bind_ip_all >/dev/null
docker run -d --name nf-redis redis:7-alpine >/dev/null
until docker exec nf-mongo mongosh --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; do sleep 1; done
docker exec nf-mongo mongosh --quiet --eval \
  "rs.initiate({_id:'rs0',members:[{_id:0,host:'localhost:27017'}]})" >/dev/null
until [ "$(docker exec nf-mongo mongosh --quiet --eval 'db.hello().isWritablePrimary')" = "true" ]; do sleep 1; done
docker exec nf-mongo mongosh --quiet --eval 'db.version()' | sed 's/^/MongoDB version: /' > evidence/00_versions.txt
docker exec nf-redis redis-server --version >> evidence/00_versions.txt

# remove terminal colour codes and window-title escapes that mongosh emits on a TTY
strip_ansi() { sed -r 's/\x1b\[[0-9;]*m//g; s/\x1b\]0;[^\x07]*\x07//g'; }

mongo() {  # mongo <script> <evidence>
  docker cp "mongodb/$1" "nf-mongo:/tmp/$1" >/dev/null
  docker exec -t nf-mongo mongosh --quiet "mongodb://localhost:27017/nairaflow?replicaSet=rs0" "/tmp/$1" \
    2>&1 | tr -d '\r' | strip_ansi > "evidence/$2"
  echo "  -> evidence/$2"
}
mongo 01_collections_and_validation.js  01_collections_output.txt
mongo 02_load_data.js                   02_load_data_output.txt
mongo 03_queries_and_indexes.js         03_queries_and_indexes_output.txt
mongo 04_multi_document_transaction.js  04_transaction_output.txt
bash redis/redis_keyvalue_demo.sh 2>&1 | tr -d '\r' > evidence/05_redis_output.txt
echo "  -> evidence/05_redis_output.txt"
