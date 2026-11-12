#!/usr/bin/env bash
# Portfolio 3 runner. Prerequisites: Portfolios 1 and 2 have been run.
# Runs single-session ACID demos, six two-session concurrency scenarios and
# two pgbench stress tests. Every output is saved under evidence/.
set -u
cd "$(dirname "$0")"
RUN=../scripts/psql_run.sh
EV=evidence; mkdir -p $EV
export MSYS_NO_PATHCONV=1

q() { docker exec nf-pg psql -U postgres -d nairaflow -X -P pager=off -qAt -c "SET search_path TO nairaflow; $1"; }

# Run one session file inside the container; prefix every line with [A] / [B]
session() {  # session <label> <sql-file> [psql -v args...]   (file already copied to /tmp)
  local label=$1 file=$2; shift 2
  docker exec -t nf-pg psql -U postgres -d nairaflow -X -e -P pager=off "$@" \
         -f "/tmp/$(basename "$file")" 2>&1 | tr -d '\r' | sed "s/^/[$label] /"
}

# Run session A; as soon as A is inside its transaction (sleeping in pg_sleep),
# start session B; wait for both; write one evidence file.
two_sessions() {  # two_sessions <evidence-file> <title> <fileA> <fileB> [psql -v args...]
  local out=$1 title=$2 fa=$3 fb=$4; shift 4
  docker cp "$fa" "nf-pg:/tmp/$(basename "$fa")" >/dev/null
  docker cp "$fb" "nf-pg:/tmp/$(basename "$fb")" >/dev/null
  {
    echo "==================================================================="
    echo "$title"
    echo "==================================================================="
    session A "$fa" "$@" > /tmp/nf_a.log &
    # poll from INSIDE the container (one docker exec, ~20 ms per check, gives up after ~10 s)
    docker exec nf-pg sh -c 'for i in $(seq 1 100); do
        n=$(psql -U postgres -d nairaflow -XqAt -c "SELECT count(*) FROM pg_stat_activity
             WHERE query LIKE '"'"'%pg_sleep(%'"'"' AND state = '"'"'active'"'"' AND pid <> pg_backend_pid()");
        [ "$n" -gt 0 ] && exit 0; sleep 0.1; done; exit 1'
    session B "$fb" "$@" > /tmp/nf_b.log &
    wait
    echo "------------------------- Session A -------------------------------"; cat /tmp/nf_a.log
    echo "------------------------- Session B -------------------------------"; cat /tmp/nf_b.log
  } > "$out"
  echo "  -> $out"
}

bash $RUN sql/00_setup_helpers.sql $EV/00_setup_helpers_output.txt
bash $RUN sql/01_commit_rollback_savepoint.sql $EV/01_commit_rollback_savepoint.txt

C=sql/concurrency
ACC=0123456787

# ---- S1 lost update -------------------------------------------------------
START=$(q "SELECT resync_balance('$ACC')")
two_sessions $EV/02_s1_lost_update.txt "S1 LOST UPDATE at READ COMMITTED (A debits 50,000, B debits 30,000)" \
             $C/s1_lost_update_A.sql $C/s1_lost_update_B.sql
END=$(q "SELECT balance FROM account WHERE account_number='$ACC'")
{ echo; echo "RESULT: start=$START  final=$END  expected=$(q "SELECT $START - 80000")  -> B's 30,000 debit was LOST"; } >> $EV/02_s1_lost_update.txt

# ---- S2 FOR UPDATE --------------------------------------------------------
START=$(q "SELECT resync_balance('$ACC')")
two_sessions $EV/03_s2_select_for_update.txt "S2 FIX 1: pessimistic row lock (SELECT ... FOR UPDATE)" \
             $C/s2_for_update_A.sql $C/s2_for_update_B.sql
END=$(q "SELECT balance FROM account WHERE account_number='$ACC'")
{ echo; echo "RESULT: start=$START  final=$END  expected=$(q "SELECT $START - 80000")  -> both debits applied, B waited for A"; } >> $EV/03_s2_select_for_update.txt

# ---- S3 REPEATABLE READ ---------------------------------------------------
START=$(q "SELECT resync_balance('$ACC')")
two_sessions $EV/04_s3_repeatable_read.txt "S3 FIX 2: optimistic - REPEATABLE READ aborts the second writer" \
             $C/s3_repeatable_read_A.sql $C/s3_repeatable_read_B.sql
END=$(q "SELECT balance FROM account WHERE account_number='$ACC'")
{ echo; echo "RESULT: start=$START  final=$END  -> only B applied; A got a serialization failure and must retry (no silent loss)"; } >> $EV/04_s3_repeatable_read.txt
q "SELECT resync_balance('$ACC')" >/dev/null

# ---- S4 write skew --------------------------------------------------------
for LVL in repeatable_read serializable; do
  q "SELECT resync_balance('0123456781'), resync_balance('0123456782')" >/dev/null
  COMB=$(q "SELECT sum(balance) FROM account WHERE customer_id = 2")
  FLOOR=$(q "SELECT $COMB - 500000")
  two_sessions $EV/05_s4_write_skew_$LVL.txt "S4 WRITE SKEW at ${LVL^^}: combined balance must stay >= $FLOOR; each session debits 400,000 from a different account" \
               $C/s4_write_skew_${LVL}_A.sql $C/s4_write_skew_${LVL}_B.sql -v floor=$FLOOR
  AFTER=$(q "SELECT sum(balance) FROM account WHERE customer_id = 2")
  if [ "$(q "SELECT $AFTER < $FLOOR")" = "t" ]; then V="RULE VIOLATED"; else V="rule preserved"; fi
  { echo; echo "RESULT: combined before=$COMB  after=$AFTER  floor=$FLOOR  -> $V"; } >> $EV/05_s4_write_skew_$LVL.txt
done
q "SELECT resync_balance('0123456781'), resync_balance('0123456782')" >/dev/null

# ---- S5 deadlock and S6 ordered locking -----------------------------------
two_sessions $EV/06_s5_deadlock.txt "S5 DEADLOCK: opposite-direction transfers lock rows in opposite order" \
             $C/s5_deadlock_A.sql $C/s5_deadlock_B.sql
two_sessions $EV/07_s6_ordered_locking.txt "S6 FIX: both sessions lock rows in account_number order (as transfer_funds does)" \
             $C/s6_ordered_locks_A.sql $C/s6_ordered_locks_B.sql
q "SELECT resync_balance('0123456781'), resync_balance('0123456783')" >/dev/null
docker logs nf-pg 2>&1 | grep -A3 "deadlock detected" | tail -8 > $EV/06b_server_log_deadlock.txt

bash stress_test.sh
