-- =====================================================================
-- NairaFlow  |  Portfolio 2
-- File: 04_partitioning.sql
-- Range-partitions the ledger by month and demonstrates partition pruning.
-- Motivation: the ledger only grows; most queries touch recent months, and
-- regulators require 5+ years of retention, so old months must be cheap to
-- archive (DETACH PARTITION) instead of slow DELETEs.
-- =====================================================================
SET search_path TO nairaflow;
SET jit = off;
\pset footer off
\timing on

DROP TABLE IF EXISTS ledger_entry_part CASCADE;
DO $$                                   -- also drop archives detached by a previous run
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables
            WHERE schemaname = 'nairaflow' AND tablename LIKE 'ledger\_entry\_p%' LOOP
    EXECUTE format('DROP TABLE nairaflow.%I', r.tablename);
  END LOOP;
END $$;
CREATE TABLE ledger_entry_part (
    entry_id      BIGINT        NOT NULL,
    txn_id        BIGINT        NOT NULL,
    account_id    BIGINT        NOT NULL,
    direction     CHAR(1)       NOT NULL CHECK (direction IN ('D','C')),
    amount        NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    balance_after NUMERIC(18,2) NOT NULL,
    created_at    TIMESTAMPTZ   NOT NULL,
    PRIMARY KEY (entry_id, created_at)          -- partition key must be part of the PK
) PARTITION BY RANGE (created_at);

-- one partition per month covering the generated history + a default partition
DO $$
DECLARE m DATE := date_trunc('month', now() - INTERVAL '13 months')::date;
BEGIN
  WHILE m <= date_trunc('month', now())::date LOOP
    EXECUTE format('CREATE TABLE ledger_entry_p%s PARTITION OF ledger_entry_part
                    FOR VALUES FROM (%L) TO (%L)',
                   to_char(m,'YYYYMM'), m, (m + INTERVAL '1 month')::date);
    m := (m + INTERVAL '1 month')::date;
  END LOOP;
END $$;
CREATE TABLE ledger_entry_pdefault PARTITION OF ledger_entry_part DEFAULT;

INSERT INTO ledger_entry_part
SELECT entry_id, txn_id, account_id, direction, amount, balance_after, created_at FROM ledger_entry;

CREATE INDEX ON ledger_entry_part (account_id, created_at DESC);   -- propagated to every partition
ANALYZE ledger_entry_part;

\echo '=== Rows per partition ==='
SELECT tableoid::regclass AS partition, count(*) AS rows
  FROM ledger_entry_part GROUP BY 1 ORDER BY 1;

\echo '--- Index scans are switched off for P1/P2 so both sides use the same access method'
\echo '--- (sequential scan). This isolates the effect of partition pruning alone.'
SET enable_indexscan = off; SET enable_indexonlyscan = off; SET enable_bitmapscan = off;

\echo '### P1 Monthly volume report for last month - NON-partitioned table'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT direction, count(*), sum(amount)
  FROM ledger_entry
 WHERE created_at >= date_trunc('month', now()) - INTERVAL '1 month'
   AND created_at <  date_trunc('month', now())
 GROUP BY direction;

\echo '### P2 Same report - partitioned table (planner prunes to ONE partition)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT direction, count(*), sum(amount)
  FROM ledger_entry_part
 WHERE created_at >= date_trunc('month', now()) - INTERVAL '1 month'
   AND created_at <  date_trunc('month', now())
 GROUP BY direction;

RESET enable_indexscan; RESET enable_indexonlyscan; RESET enable_bitmapscan;

\echo '=== Archiving the oldest month is a metadata operation, not a DELETE ==='
SELECT 'ledger_entry_p' || to_char(date_trunc('month', now() - INTERVAL '13 months'),'YYYYMM') AS oldest \gset
ALTER TABLE ledger_entry_part DETACH PARTITION :oldest;
SELECT count(*) AS rows_still_in_partitioned_table FROM ledger_entry_part;
SELECT count(*) AS rows_in_detached_archive FROM :oldest;
