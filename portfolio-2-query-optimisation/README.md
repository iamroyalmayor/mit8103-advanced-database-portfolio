# Portfolio 2 – Query Processing and Optimisation

## 1. Dataset ([`sql/01_generate_data.sql`](sql/01_generate_data.sql))

Built on the Portfolio 1 schema with `generate_series` and a fixed `setseed()`, so it is reproducible:

| Table | Rows | Notes |
|---|---:|---|
| customer | 60,011 | 40% Lagos (deliberate skew so the planner's statistics matter) |
| account | 100,013 | 75% savings / 25% current |
| txn | 1,100,379 | 1 M transfers (5% FAILED), 100 k opening deposits, 360 injected "money-mule" transfers |
| ledger_entry | 2,100,668 | Running `balance_after` computed with a window function |

The per-row deferred double-entry trigger is disabled during the bulk load (2 million trigger calls
would dominate the load time) and the rule is then verified with one set-based query: **0
unbalanced transactions, 0 negative customer balances, Σ balances = 0.00**
([evidence](evidence/01_generate_data_output.txt)). Database size is about 750 MB.

## 2. Method

1. [`02_workload_queries.sql`](sql/02_workload_queries.sql) runs seven real NairaFlow queries. For
   each it prints the **result** and the **`EXPLAIN (ANALYZE, BUFFERS)`** plan. Run 1 is
   *before* tuning ([evidence](evidence/02_before_indexes.txt)).
2. Indexes were chosen by reading those plans ([`03_create_indexes.sql`](sql/03_create_indexes.sql)).
3. The identical file is re-run *after* ([evidence](evidence/04_after_indexes.txt)).
4. `run.sh` extracts `Execution Time` from both logs into
   [`evidence/06_performance_summary.md`](evidence/06_performance_summary.md).

JIT is disabled and the cache is warmed before each run so the two runs are comparable. Timings
are single runs on a laptop (Docker Desktop, PostgreSQL 16, `shared_buffers=256MB`); the
**plan shapes and buffer counts** matter more than the exact milliseconds.

## 3. Results

| Query | Purpose | Before (ms) | After (ms) | Speed-up | Plan change |
|---|---|---:|---:|---:|---|
| Q1 | Account statement, 90 days | 333.6 | 0.23 | ~1,400× | Parallel Seq Scan + Sort → Index Scan (pre-sorted) |
| Q2 | Case-insensitive e-mail lookup | 74.7 | 0.04 | ~1,700× | Seq Scan → Index Scan on expression index |
| Q3 | Failed transactions per channel, 30 days | 181.7 | 13.71 | ~13× | Seq Scan → Bitmap Index Scan on partial index |
| Q4 | Top-10 senders, 7 days | 529.2 | 173.32 | ~3× | Seq Scan → Index Only Scan (covering index) |
| Q5 | Fraud velocity rule (mule detection) | 503.3 | 196.52 | ~2.6× | Two Seq Scans → Index Only Scans + nested loop |
| Q6 | Balance vs ledger reconciliation (50 accounts) | 11,101.5 | 0.62 | ~17,800× | 50 × Seq Scan + Sort → 50 × Index Scan `LIMIT 1` |
| Q7 | Dormant accounts, anti-join | 575.3 | 436.44 | ~1.3× | Hash Anti Join → Nested Loop Anti Join (100 k index probes) |

Source: [`evidence/06_performance_summary.md`](evidence/06_performance_summary.md), extracted automatically from the two EXPLAIN logs.

## 4. Analysis per query

| Query | Before: plan and bottleneck | Index added | After: plan | Why it works |
|---|---|---|---|---|
| **Q1** Account statement (90 days) | Parallel **Seq Scan** of 2.1 M ledger rows, filtered to about 10 rows | `ix_ledger_account_time (account_id, created_at DESC, entry_id DESC)` | **Index Scan**, already in the requested order, so **no Sort node** | Equality column first, range and sort column second: the B-tree delivers exactly the qualifying rows, pre-sorted |
| **Q2** `lower(email) = …` | Seq Scan of 60 k customers; the UNIQUE index on `email` **cannot** be used because the predicate applies a function | `ix_customer_email_lower` on `(lower(email))` | Index Scan, 1 row | An **expression index** stores the function result, so the predicate matches it |
| **Q3** Failed transactions, last 30 days | Seq Scan of 1.1 M `txn` rows | **Partial** `ix_txn_failed_created (created_at) WHERE status='FAILED'` | Bitmap or Index Scan on a tiny index | It indexes only the 5% of rows the dashboard ever asks for, so it is small, cheap to maintain and always matches the predicate |
| **Q4** Top customers (7 days) | Parallel Seq Scan of the ledger | **Covering** `ix_ledger_time_covering (created_at) INCLUDE (account_id, direction, amount, txn_id)` | **Index Only Scan** (`Heap Fetches` ≈ 0 after VACUUM) then hash joins | The heap is never read for the recent slice. What remains is hashing 100 k accounts for the join, which is why the gain is smaller (about 3×) |
| **Q5** Fraud velocity (self-join on ledger) | Two full ledger scans joined by hash | Same covering index plus the existing `uq_leg (txn_id, account_id, direction)` | Index Only Scan for credits plus a nested loop using an Index Only Scan on `uq_leg` for each debit leg | The planner reused a UNIQUE constraint's index as an access path. It correctly flags the 3 injected mule accounts (≈100 distinct senders per hour) |
| **Q6** Reconciliation, LATERAL "latest leg per account" | **50 × full Seq Scan + Sort** (a correlated subquery run once per outer row): the slowest query | Same `ix_ledger_account_time` | 50 × Index Scan with `LIMIT 1` | Each probe reads the first entry of a B-tree range: O(log n) instead of O(n). This is the largest speed-up |
| **Q7** Dormant accounts (NOT EXISTS) | Parallel Hash **Anti Join** over the full ledger | none dedicated (reuses `ix_ledger_account_time`) | **Nested Loop Anti Join**: one Index Only Scan probe per account (100,011 probes) | Only ~1.3× faster. `NOT EXISTS` lets the planner choose an anti-join (`NOT IN` would behave badly with NULLs), but it still has to visit every account. The real fix is a *design* change, not an index: keep `account.last_activity_at` updated by `transfer_funds()` and index it, or run this report on a read replica (Portfolio 5) |

### Cost of the indexes

[`evidence/03_create_indexes_output.txt`](evidence/03_create_indexes_output.txt) lists index sizes.
The two new ledger indexes (116 MB + 81 MB) are larger than the ledger heap itself, and every posting now
maintains 5 indexes on `ledger_entry` instead of 3. For an OLTP ledger this is an acceptable
trade, because statement reads far outnumber writes, but it is the reason the failed-transaction
index is **partial** and that no index was added for Q7 alone.

### Estimates vs actuals

In the "before" plans, estimates are close to actuals, for example Q1's seq-scan row estimates.
The statistics come from `ANALYZE` after loading. The Lagos skew is captured in `pg_stats`'
most-common-values list, so state-level aggregates get realistic group counts.

## 5. Partitioning experiment ([`sql/04_partitioning.sql`](sql/04_partitioning.sql))

The ledger was copied into `ledger_entry_part`, **RANGE-partitioned by month** (14 monthly
partitions plus a default partition).

| Query: last month's volume | Plan | Execution time |
|---|---|---|
| Non-partitioned ledger (index scans switched off for a fair comparison) | Parallel Seq Scan of **all** 2.1 M rows | 672.4 ms |
| Partitioned ledger | `Subplans Removed: 14`: scans **one** partition (~160 k rows) | 101.3 ms (≈ 6.6× faster) |

The bigger operational win is lifecycle management. `ALTER TABLE … DETACH PARTITION` archives the
oldest month as a metadata operation (no `DELETE` of 134 k rows, no table bloat), which matters for a
bank that must retain records for years but query mostly recent data. Trade-off: the primary key
must include the partition key `(entry_id, created_at)`, and queries without a date predicate must
visit every partition.

## 6. How to run

```bash
bash run.sh                    # needs Portfolio 1 loaded; ~6-8 min including the data load
SKIP_GENERATE=1 bash run.sh    # re-run only the experiments
```
