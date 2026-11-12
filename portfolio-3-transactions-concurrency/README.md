# Portfolio 3 – Transactions and Concurrency

All demos run on the NairaFlow schema from Portfolio 1 (PostgreSQL 16, MVCC). Run `bash run.sh`
after Portfolios 1 and 2. Every scenario's output is in [`evidence/`](evidence/).

## 1. Single-session ACID behaviour ([`sql/01_commit_rollback_savepoint.sql`](sql/01_commit_rollback_savepoint.sql))

| Demo | What happens | ACID property |
|---|---|---|
| A. COMMIT | ₦10,000 Adaeze → Babatunde inside `BEGIN … COMMIT`; visible inside the transaction, durable after it | Atomicity, Durability |
| B. ROLLBACK | An operator debits ₦99,999 by mistake, sees the wrong balance, then runs `ROLLBACK`; the balance is restored | Atomicity |
| C. Automatic rollback | The 2nd transfer in a transaction fails (insufficient funds); PostgreSQL aborts the **whole** transaction and turns `COMMIT` into `ROLLBACK`; 0 rows from either transfer remain | Atomicity, Consistency |
| D. SAVEPOINT | Salary batch: Adaeze paid → invalid account fails → `ROLLBACK TO SAVEPOINT` → Babatunde paid → COMMIT. Two of the three salaries are posted | Partial rollback |
| E. Idempotency | The same request UUID is sent twice (simulated network retry); the second call returns the original `txn_id`; exactly one transaction exists | Consistency under retries |

After every demo Σ(all balances) is still `0.00`.

## 2. Two-session concurrency scenarios ([`sql/concurrency/`](sql/concurrency/))

`run.sh` starts session **A**, waits until A is inside its transaction (it polls
`pg_stat_activity` for A's `pg_sleep`), then starts session **B**. Each step prints a
millisecond timestamp through `ts()`, so the interleaving can be read from the logs. Scenarios S1–S4
update `account.balance` directly to isolate the concurrency effect, then re-synchronise it from
the ledger (`resync_balance()`), because the ledger is the system of record.

| # | Scenario | Isolation / mechanism | Observed result (evidence) |
|---|---|---|---|
| S1 | **Lost update**: A and B both read ₦682,000; B writes −30,000 and commits; A writes −50,000 based on its stale read | READ COMMITTED, no locks | Final ₦632,000 instead of ₦602,000. **B's ₦30,000 debit vanished** ([02](evidence/02_s1_lost_update.txt)) |
| S2 | Same logic with `SELECT … FOR UPDATE` | Pessimistic row lock | B **blocks** about 3 s until A commits, then reads ₦632,000; final ₦602,000 is correct ([03](evidence/03_s2_select_for_update.txt)) |
| S3 | Same naive logic at REPEATABLE READ | Snapshot isolation (optimistic) | B commits first; A's UPDATE fails with `could not serialize access due to concurrent update`; the application must retry. No silent loss ([04](evidence/04_s3_repeatable_read.txt)) |
| S4a | **Write skew**: rule "Adaeze's combined balance ≥ floor". A debits her savings account and B her current account; both checked the rule against the same snapshot | REPEATABLE READ | Both commit (they wrote **different rows**, so there was no write–write conflict). **Rule violated** ([05 RR](evidence/05_s4_write_skew_repeatable_read.txt)) |
| S4b | Same at SERIALIZABLE | SSI (predicate/SIRead locks) | The second committer gets `could not serialize access due to read/write dependencies among transactions`; **rule preserved** ([05 SER](evidence/05_s4_write_skew_serializable.txt)) |
| S5 | **Deadlock**: A locks 0123456781 then 0123456783; B locks them in the opposite order | Row locks | After `deadlock_timeout` (1 s) PostgreSQL's detector aborts one victim (`deadlock detected`, server log in [06b](evidence/06b_server_log_deadlock.txt)) |
| S6 | **Fix**: both sessions lock in `ORDER BY account_number` (the rule built into `transfer_funds()`) | Global lock ordering | B simply waits for A; no deadlock ([07](evidence/07_s6_ordered_locking.txt)) |

### Stress test: 16 concurrent clients on 50 "hot" accounts ([`pgbench/`](pgbench/), [`stress_test.sh`](stress_test.sh))

| Run | Script | Result |
|---|---|---|
| Unsafe | Read balance, then write the absolute value back, with no locks | 4,051 transfers (≈ 264 tps), but Σ(all balances) went from 0.00 to **₦17,741.00**: lost updates **created money**, and **all 50** hot accounts no longer matched their ledger. 21 transactions (0.5%) also failed; pgbench counts only deadlock and serialization errors as failures, and the server log confirms deadlocks, because lock order was random ([08](evidence/08_s7_pgbench_unsafe.txt)) |
| Repair | `resync_balance()` rebuilds each balance from the latest ledger leg | Σ back to 0.00: the ledger made recovery possible |
| Safe | `transfer_funds()`: ordered `FOR UPDATE`, balance check, double-entry legs | **21,864 transfers (≈ 1,450 tps), 0 failed transactions, 0 deadlocks**, Σ = 0.00, 0 unbalanced transactions, 0 hot accounts out of line with their ledger ([09](evidence/09_s7_pgbench_safe.txt)) |

The safe version is also about **5.5× faster**. The unsafe script makes four round trips per transfer
and deadlocks, while the stored function makes one round trip and never waits in a cycle.

> Two real bugs were found by this stress test and fixed in `01_schema.sql`: (1) the functions
> resolved table names through the *caller's* `search_path` (now pinned with `SET search_path`);
> (2) ledger rows were stamped with `now()` (the transaction **start** time), so a transfer that
> waited for a lock could get an earlier timestamp than the posting it queued behind. They now use
> `clock_timestamp()`, taken after the locks are acquired.

## 3. How PostgreSQL implements what we observed

- **MVCC:** each row version carries `xmin`/`xmax`; readers see a snapshot and never block writers,
  which is why A and B in S1 and S3 could both read ₦682,000.
- **READ COMMITTED** takes a new snapshot per statement and, on an UPDATE conflict, re-reads the
  latest row version, but it cannot know the *application* computed its value from an old read
  (S1). The fixes are atomic SQL (`balance = balance - x`), `FOR UPDATE` (S2), or a higher isolation
  level (S3).
- **REPEATABLE READ** = snapshot isolation. It prevents lost updates via the "first updater wins"
  rule, but not write skew (S4a), because the two transactions write disjoint rows.
- **SERIALIZABLE** = Serializable Snapshot Isolation (Cahill et al., 2008). It tracks rw-antidependencies
  with SIRead locks and aborts a transaction that would close a dangerous cycle (S4b). This
  costs retries, not blocking.
- **Deadlocks** are detected by a wait-for graph check after `deadlock_timeout`. Prevention via a
  global lock order (S6) is cheaper than detection.

**Design choice for NairaFlow:** `transfer_funds()` runs at READ COMMITTED with **explicit
ordered row locks**. Every rule it checks (status, balance) is about the two rows it locks, so
locking gives correctness without SERIALIZABLE retry storms on hot accounts. Rules that span
rows it does not lock (customer-level daily limits, like S4) must use SERIALIZABLE with a retry
loop, or lock a customer-level row.

## 4. Evidence index

| File | Content |
|---|---|
| `00_setup_helpers_output.txt` | Helper functions `ts()`, `resync_balance()` |
| `01_commit_rollback_savepoint.txt` | Demos A–E |
| `02`–`07` | S1–S6, both sessions with timestamps plus a RESULT line |
| `06b_server_log_deadlock.txt` | PostgreSQL server log: the wait-for cycle between the two processes |
| `08_s7_pgbench_unsafe.txt`, `09_s7_pgbench_safe.txt` | pgbench reports with integrity checks before and after |
