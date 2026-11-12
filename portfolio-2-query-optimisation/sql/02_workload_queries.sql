-- =====================================================================
-- NairaFlow  |  Portfolio 2
-- File: 02_workload_queries.sql
-- Seven representative queries from the NairaFlow workload. For each query
-- the script prints (a) the result and (b) EXPLAIN (ANALYZE, BUFFERS).
-- The same file is executed BEFORE and AFTER 03_create_indexes.sql so that
-- plans and timings can be compared like-for-like.
-- =====================================================================
SET search_path TO nairaflow;
SET jit = off;                         -- keep timings comparable between runs
\pset footer off

-- warm the OS / buffer cache so both runs start from a similar state
SELECT count(*) AS warm_ledger FROM ledger_entry;
SELECT count(*) AS warm_txn    FROM txn;

-- ---------------------------------------------------------------------
\echo '### Q1 Account statement: last 90 days for one account (mobile app "History" screen)'
SELECT l.created_at::timestamp(0) AS posted, t.txn_type, t.channel, l.direction, l.amount, l.balance_after
  FROM ledger_entry l
  JOIN txn t     ON t.txn_id = l.txn_id
  JOIN account a ON a.account_id = l.account_id
 WHERE a.account_number = '3000012345'
   AND l.created_at >= now() - INTERVAL '90 days'
 ORDER BY l.created_at DESC
 LIMIT 10;
EXPLAIN (ANALYZE, BUFFERS)
SELECT l.created_at, t.txn_type, t.channel, l.direction, l.amount, l.balance_after
  FROM ledger_entry l
  JOIN txn t     ON t.txn_id = l.txn_id
  JOIN account a ON a.account_id = l.account_id
 WHERE a.account_number = '3000012345'
   AND l.created_at >= now() - INTERVAL '90 days'
 ORDER BY l.created_at DESC;

-- ---------------------------------------------------------------------
\echo '### Q2 Case-insensitive customer lookup by e-mail (support desk / login)'
SELECT customer_id, first_name, last_name, email, kyc_tier
  FROM customer WHERE lower(email) = lower('USER4521@Mail.Example.NG');
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, first_name, last_name, email, kyc_tier
  FROM customer WHERE lower(email) = lower('USER4521@Mail.Example.NG');

-- ---------------------------------------------------------------------
\echo '### Q3 Failed transactions per channel in the last 30 days (operations dashboard)'
SELECT channel, count(*) AS failed, sum(amount) AS failed_value
  FROM txn
 WHERE status = 'FAILED' AND created_at >= now() - INTERVAL '30 days'
 GROUP BY channel ORDER BY failed DESC;
EXPLAIN (ANALYZE, BUFFERS)
SELECT channel, count(*) AS failed, sum(amount) AS failed_value
  FROM txn
 WHERE status = 'FAILED' AND created_at >= now() - INTERVAL '30 days'
 GROUP BY channel ORDER BY failed DESC;

-- ---------------------------------------------------------------------
\echo '### Q4 Top 10 customers by outgoing value in the last 7 days (relationship managers)'
SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer, sum(l.amount) AS sent_7d, count(*) AS n
  FROM ledger_entry l
  JOIN account a  ON a.account_id = l.account_id
  JOIN customer c ON c.customer_id = a.customer_id
 WHERE l.direction = 'D' AND a.type_code <> 'GL'
   AND l.created_at >= now() - INTERVAL '7 days'
 GROUP BY c.customer_id, customer ORDER BY sent_7d DESC LIMIT 10;
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer, sum(l.amount) AS sent_7d, count(*) AS n
  FROM ledger_entry l
  JOIN account a  ON a.account_id = l.account_id
  JOIN customer c ON c.customer_id = a.customer_id
 WHERE l.direction = 'D' AND a.type_code <> 'GL'
   AND l.created_at >= now() - INTERVAL '7 days'
 GROUP BY c.customer_id, customer ORDER BY sent_7d DESC LIMIT 10;

-- ---------------------------------------------------------------------
\echo '### Q5 Fraud velocity rule: accounts credited by >= 50 distinct senders in one hour (last 7 days)'
WITH credits AS (
    SELECT cr.account_id AS receiver, dr.account_id AS sender, cr.created_at
      FROM ledger_entry cr
      JOIN ledger_entry dr ON dr.txn_id = cr.txn_id AND dr.direction = 'D'
     WHERE cr.direction = 'C' AND cr.created_at >= now() - INTERVAL '7 days')
SELECT a.account_number, date_trunc('hour', c.created_at) AS hour_bucket,
       count(DISTINCT c.sender) AS distinct_senders
  FROM credits c JOIN account a ON a.account_id = c.receiver
 GROUP BY 1, 2 HAVING count(DISTINCT c.sender) >= 50 ORDER BY 3 DESC;
EXPLAIN (ANALYZE, BUFFERS)
WITH credits AS (
    SELECT cr.account_id AS receiver, dr.account_id AS sender, cr.created_at
      FROM ledger_entry cr
      JOIN ledger_entry dr ON dr.txn_id = cr.txn_id AND dr.direction = 'D'
     WHERE cr.direction = 'C' AND cr.created_at >= now() - INTERVAL '7 days')
SELECT a.account_number, date_trunc('hour', c.created_at) AS hour_bucket,
       count(DISTINCT c.sender) AS distinct_senders
  FROM credits c JOIN account a ON a.account_id = c.receiver
 GROUP BY 1, 2 HAVING count(DISTINCT c.sender) >= 50 ORDER BY 3 DESC;

-- ---------------------------------------------------------------------
\echo '### Q6 Reconciliation: stored balance vs latest ledger balance (sample of 50 accounts)'
SELECT count(*) AS checked,
       count(*) FILTER (WHERE last.balance_after <> a.balance) AS mismatches
  FROM account a
  CROSS JOIN LATERAL (SELECT balance_after FROM ledger_entry l
                       WHERE l.account_id = a.account_id
                       ORDER BY l.created_at DESC, l.entry_id DESC LIMIT 1) last
 WHERE a.account_number BETWEEN '3000020000' AND '3000020049';
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS checked,
       count(*) FILTER (WHERE last.balance_after <> a.balance) AS mismatches
  FROM account a
  CROSS JOIN LATERAL (SELECT balance_after FROM ledger_entry l
                       WHERE l.account_id = a.account_id
                       ORDER BY l.created_at DESC, l.entry_id DESC LIMIT 1) last
 WHERE a.account_number BETWEEN '3000020000' AND '3000020049';

-- ---------------------------------------------------------------------
\echo '### Q7 Dormant accounts: no ledger activity in the last 180 days (CBN dormancy report, anti-join)'
SELECT count(*) AS dormant_accounts
  FROM account a
 WHERE a.type_code <> 'GL'
   AND NOT EXISTS (SELECT 1 FROM ledger_entry l
                    WHERE l.account_id = a.account_id
                      AND l.created_at >= now() - INTERVAL '180 days');
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS dormant_accounts
  FROM account a
 WHERE a.type_code <> 'GL'
   AND NOT EXISTS (SELECT 1 FROM ledger_entry l
                    WHERE l.account_id = a.account_id
                      AND l.created_at >= now() - INTERVAL '180 days');
