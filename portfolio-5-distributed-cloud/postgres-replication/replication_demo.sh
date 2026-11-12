#!/usr/bin/env bash
# NairaFlow | Portfolio 5 - PostgreSQL streaming replication, synchronous commit and failover
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
P()  { echo "primary> $1"; docker exec p5-pg-primary psql -U postgres -d nairaflow -X -P pager=off -c "$1" 2>&1; }
R()  { echo "replica> $1"; docker exec p5-pg-replica psql -U postgres -d nairaflow -X -P pager=off -c "$1" 2>&1; }
hdr(){ echo; echo "=================================================================="; echo "$1"; echo "=================================================================="; }

hdr "R1 Topology: primary streams WAL to the hot-standby replica"
P "SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"
P "SELECT slot_name, active FROM pg_replication_slots;"
R "SELECT pg_is_in_recovery() AS is_replica, pg_last_wal_receive_lsn() AS received_lsn;"

hdr "R2 Load the Portfolio-1 NairaFlow schema on the PRIMARY only"
docker cp ../portfolio-1-database-design/sql/01_schema.sql    p5-pg-primary:/tmp/ >/dev/null
docker cp ../portfolio-1-database-design/sql/02_seed_data.sql p5-pg-primary:/tmp/ >/dev/null
docker exec p5-pg-primary psql -U postgres -d nairaflow -qX -f /tmp/01_schema.sql  >/dev/null 2>&1
docker exec p5-pg-primary psql -U postgres -d nairaflow -qX -f /tmp/02_seed_data.sql >/dev/null 2>&1
P "SELECT count(*) AS accounts_on_primary, sum(balance) AS total FROM nairaflow.account;"
sleep 1
R "SELECT count(*) AS accounts_on_replica, sum(balance) AS total FROM nairaflow.account;"

hdr "R3 The replica is read-only (writes must go to the primary)"
R "SELECT nairaflow.transfer_funds('0123456781','0123456783', 100);"
R "UPDATE nairaflow.account SET status='FROZEN' WHERE account_number='0123456781';"

hdr "R4 Read-your-writes and replication lag under a write burst (asynchronous mode)"
P "SELECT nairaflow.transfer_funds('0123456781','0123456783', 1000.00, 'MOBILE', 'P5 replicated txn');"
R "SELECT txn_id, narration, amount FROM nairaflow.txn WHERE narration = 'P5 replicated txn';"
P "INSERT INTO nairaflow.audit_log(table_name, record_id, action, new_data)
   SELECT 'load_test', g, 'INSERT', jsonb_build_object('n', g, 'pad', repeat('x', 200)) FROM generate_series(1, 200000) g;"
P "SELECT application_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
          write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
sleep 2
P "SELECT application_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes FROM pg_stat_replication;"
R "SELECT count(*) AS audit_rows_on_replica FROM nairaflow.audit_log WHERE table_name='load_test';"

hdr "R5 Synchronous replication: COMMIT waits until the standby confirms (RPO = 0)"
P "ALTER SYSTEM SET synchronous_standby_names = 'replica1';"
P "SELECT pg_reload_conf();"
sleep 1
P "SELECT application_name, sync_state FROM pg_stat_replication;"
P "SELECT nairaflow.transfer_funds('0123456786','0123456785', 5000.00, 'WEB', 'P5 sync commit');"

hdr "R6 CAP trade-off: replica down + synchronous commit = primary BLOCKS writes (consistency over availability)"
docker stop p5-pg-replica >/dev/null && echo "(replica container stopped)"
echo "primary> transfer with an 8 s client timeout ..."
START=$(date +%s)
timeout 8 docker exec p5-pg-primary psql -U postgres -d nairaflow -X -c \
  "SELECT nairaflow.transfer_funds('0123456786','0123456785', 7000.00, 'WEB', 'P5 blocked commit');" 2>&1
echo "client gave up after $(( $(date +%s) - START )) s: COMMIT was still waiting for a synchronous standby"
P "SELECT pid, wait_event, state, left(query, 60) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
echo "-- operator decision: degrade to asynchronous to restore availability"
P "ALTER SYSTEM SET synchronous_standby_names = '';"
P "SELECT pg_reload_conf();"
sleep 1
P "SELECT narration, status FROM nairaflow.txn WHERE narration LIKE 'P5 %' ORDER BY txn_id;"
docker start p5-pg-replica >/dev/null && echo "(replica restarted; it resumes from its replication slot)"
for i in $(seq 1 60); do docker exec p5-pg-replica pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 5
P "SELECT application_name, state, sync_state FROM pg_stat_replication;"
R "SELECT narration FROM nairaflow.txn WHERE narration LIKE 'P5 %' ORDER BY txn_id;"

hdr "R7 Failover: primary crashes, replica is promoted"
P "SELECT nairaflow.transfer_funds('0123456790','0123456787', 2500.00, 'MOBILE', 'P5 last txn before crash');"
sleep 1
docker kill p5-pg-primary >/dev/null && echo "(primary container KILLED at $(date +%T))"
R "SELECT pg_is_in_recovery() AS still_replica;"
R "SELECT pg_promote(wait => true) AS promoted;"
R "SELECT pg_is_in_recovery() AS still_replica;"
R "SELECT narration FROM nairaflow.txn WHERE narration = 'P5 last txn before crash';"
R "SELECT nairaflow.transfer_funds('0123456790','0123456787', 1500.00, 'MOBILE', 'P5 first txn on new primary') AS txn_id;"
R "SELECT sum(balance) AS total_must_be_zero FROM nairaflow.account;"
echo "(failover completed at $(date +%T))"
