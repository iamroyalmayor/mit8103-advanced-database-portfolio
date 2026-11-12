-- =====================================================================
-- NairaFlow  |  Portfolio 2
-- File: 03_create_indexes.sql  -- indexes chosen from the BEFORE plans
-- =====================================================================
SET search_path TO nairaflow;
\timing on

-- Q1, Q6, Q7: composite B-tree; equality column first, range/sort column second.
-- Supports "WHERE account_id = ? AND created_at >= ? ORDER BY created_at DESC"
-- and the LATERAL "latest row per account" lookup without a sort.
CREATE INDEX ix_ledger_account_time ON ledger_entry (account_id, created_at DESC, entry_id DESC);

-- Q2: expression index - a plain index on email cannot serve lower(email).
CREATE INDEX ix_customer_email_lower ON customer (lower(email));

-- Q3: partial index - only ~5% of txn rows are FAILED, so the index is tiny
-- and always matches the dashboard predicate.
CREATE INDEX ix_txn_failed_created ON txn (created_at) WHERE status = 'FAILED';

-- Q4, Q5: covering index on time with INCLUDE columns -> index-only scans
-- over the recent slice of the ledger without visiting the heap.
CREATE INDEX ix_ledger_time_covering ON ledger_entry (created_at)
       INCLUDE (account_id, direction, amount, txn_id);

VACUUM ANALYZE ledger_entry;   -- refresh visibility map so index-only scans are possible
ANALYZE customer; ANALYZE txn;

SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_index
 WHERE indrelid IN ('ledger_entry'::regclass, 'customer'::regclass, 'txn'::regclass)
 ORDER BY pg_relation_size(indexrelid) DESC;
