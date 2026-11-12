-- =====================================================================
-- NairaFlow | Portfolio 5 - Sharding design, simulated with hash partitions
-- Each hash partition stands in for one shard (one physical node in Citus,
-- Aurora Limitless or a MongoDB sharded cluster). We compare two candidate
-- shard keys for the ledger: customer_id (hashed) vs created_at (ranged).
-- =====================================================================
SET search_path TO nairaflow;
\pset footer off

-- Candidate A: HASH(customer_id) -> 4 shards
DROP TABLE IF EXISTS ledger_by_customer CASCADE;
CREATE TABLE ledger_by_customer (
    entry_id BIGINT, customer_id BIGINT NOT NULL, account_id BIGINT, direction CHAR(1),
    amount NUMERIC(18,2), created_at TIMESTAMPTZ
) PARTITION BY HASH (customer_id);
CREATE TABLE ledger_shard_0 PARTITION OF ledger_by_customer FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE ledger_shard_1 PARTITION OF ledger_by_customer FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE ledger_shard_2 PARTITION OF ledger_by_customer FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE ledger_shard_3 PARTITION OF ledger_by_customer FOR VALUES WITH (MODULUS 4, REMAINDER 3);

-- synthetic workload: 10,000 customers, 200,000 ledger legs over 30 days
INSERT INTO ledger_by_customer
SELECT g, 1 + (g * 7919) % 10000, g % 20000, CASE WHEN g % 2 = 0 THEN 'D' ELSE 'C' END,
       (g % 5000) + 100, now() - ((g % 30) || ' days')::interval
  FROM generate_series(1, 200000) g;
ANALYZE ledger_by_customer;

\echo '=== A. Data distribution with HASH(customer_id): even spread, no hot shard ==='
SELECT tableoid::regclass AS shard, count(*) AS rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
  FROM ledger_by_customer GROUP BY 1 ORDER BY 1;

\echo '=== A. A single customer''s statement touches exactly ONE shard (shard pruning) ==='
EXPLAIN (COSTS OFF) SELECT * FROM ledger_by_customer WHERE customer_id = 4521;

\echo '=== A. ...but a bank-wide "today" report must fan out to ALL shards (scatter-gather) ==='
EXPLAIN (COSTS OFF) SELECT sum(amount) FROM ledger_by_customer WHERE created_at >= now() - interval '1 day';

-- Candidate B: RANGE(created_at) -> every new write lands on the newest shard
\echo '=== B. With RANGE(created_at) as the shard key, 100% of today''s writes hit ONE shard (write hotspot) ==='
SELECT CASE WHEN created_at >= now() - interval '7 days'  THEN 'shard_week_0 (current)'
            WHEN created_at >= now() - interval '14 days' THEN 'shard_week_1'
            WHEN created_at >= now() - interval '21 days' THEN 'shard_week_2'
            ELSE 'shard_week_3' END AS shard,
       count(*) FILTER (WHERE created_at >= now() - interval '1 day') AS writes_in_last_24h
  FROM ledger_by_customer GROUP BY 1 ORDER BY 1;
