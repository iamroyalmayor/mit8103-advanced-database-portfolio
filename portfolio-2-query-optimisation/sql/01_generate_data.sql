-- =====================================================================
-- NairaFlow  |  Portfolio 2: Query Processing and Optimisation
-- File: 01_generate_data.sql
-- Generates a realistic volume of synthetic data on top of the Portfolio 1
-- schema so that execution plans are meaningful:
--     60,000 customers, 100,000 accounts,
--  1,000,000 transfers (~5% FAILED), 100,000 opening deposits
--  ~2.1 million ledger legs, plus an injected "money-mule" fraud pattern.
-- Runtime: roughly 1-3 minutes on a laptop.
-- =====================================================================
SET search_path TO nairaflow;
\timing on
SELECT setseed(0.8103);                       -- reproducible random data

-- The per-row deferred balance trigger would run 2 million times; disable it
-- for the bulk load and verify the double-entry rule with one query afterwards.
ALTER TABLE ledger_entry DISABLE TRIGGER ledger_balanced;

-- ---------------- customers ----------------
INSERT INTO customer(bvn, first_name, last_name, email, phone, date_of_birth, kyc_tier, state_code, created_at)
SELECT (22200000000 + g)::text,
       (ARRAY['Adaeze','Tunde','Chinedu','Fatima','Emeka','Halima','Seun','Ibrahim','Ngozi','Osagie',
              'Aisha','Kelechi','Bola','Musa','Ifeoma','Yemi','Zainab','Obinna','Funke','Usman'])[1 + floor(random()*20)::int],
       (ARRAY['Okafor','Adeyemi','Eze','Bello','Nwosu','Yusuf','Balogun','Musa','Obi','Igbinedion',
              'Abubakar','Okonkwo','Adebayo','Lawal','Chukwu','Ogunleye','Danjuma','Okeke','Salami','Ibe'])[1 + floor(random()*20)::int],
       'user' || g || '@mail.example.ng',
       '+234' || (7000000000 + g)::text,
       DATE '1960-01-01' + floor(random()*14000)::int,
       1 + floor(random()*3)::int,
       -- Lagos-heavy distribution (skew matters for the optimiser's statistics)
       CASE WHEN random() < 0.40 THEN 'LA'
            ELSE (ARRAY['OY','OG','FC','KN','KD','RI','ED','EN','AN','BO','PL'])[1 + floor(random()*11)::int] END,
       now() - (random() * INTERVAL '730 days')
  FROM generate_series(1, 60000) g;

-- ---------------- accounts ----------------
INSERT INTO account(account_number, customer_id, type_code, opened_at)
SELECT lpad((3000000000 + g)::text, 10, '0'),
       c0.first_id + ((g - 1) % 60000),
       CASE WHEN random() < 0.75 THEN 'SAVINGS' ELSE 'CURRENT' END,
       now() - INTERVAL '400 days' - (random() * INTERVAL '300 days')
  FROM generate_series(1, 100000) g,
       (SELECT min(customer_id) AS first_id FROM customer WHERE bvn LIKE '222%') c0;

-- ---------------- staging table of synthetic transactions ----------------
DROP TABLE IF EXISTS pg_temp.stage;
CREATE TEMP TABLE stage AS
WITH bounds AS (
    SELECT min(account_id) AS lo, count(*) AS n
      FROM account WHERE account_number LIKE '3%'
), base AS (SELECT COALESCE(max(txn_id), 0) AS off FROM txn),
raw AS (
    SELECT g,
           floor(random() * b.n)::bigint             AS f,
           1 + floor(random() * (b.n - 1))::bigint   AS d,
           b.lo, b.n
      FROM generate_series(1, 1000000) g, bounds b
)
SELECT base.off + g                                        AS txn_id,
       'TRANSFER'::varchar(12)                             AS txn_type,
       raw.lo + raw.f                                      AS from_acc,
       raw.lo + ((raw.f + raw.d) % raw.n)                  AS to_acc,
       round((100 + random() * 19900)::numeric, 2)         AS amount,
       CASE WHEN random() < 0.05 THEN 'FAILED' ELSE 'COMPLETED' END::varchar(10) AS status,
       (ARRAY['MOBILE','MOBILE','MOBILE','USSD','WEB','POS','ATM'])[1 + floor(random()*7)::int]::varchar(6) AS channel,
       now() - (random() * INTERVAL '365 days')           AS ts
  FROM raw, base;

-- Opening deposits (cash GL -> each account) dated before any transfer
INSERT INTO stage
SELECT (SELECT max(txn_id) FROM stage) + row_number() OVER (ORDER BY a.account_id),
       'DEPOSIT', gl.account_id, a.account_id, 500000.00, 'COMPLETED', 'BRANCH',
       now() - INTERVAL '366 days' - (random() * INTERVAL '30 days')
  FROM account a, (SELECT account_id FROM account WHERE account_number = '9000000001') gl
 WHERE a.account_number LIKE '3%';

-- Injected fraud pattern: 3 "mule" accounts each receive from 120 distinct
-- senders within one hour (used by the velocity query Q6).
INSERT INTO stage
SELECT (SELECT max(txn_id) FROM stage) + row_number() OVER (),
       'TRANSFER', s.sender, m.account_id, 9500.00, 'COMPLETED', 'MOBILE',
       now() - INTERVAL '3 days' + (random() * INTERVAL '55 minutes')
  FROM (VALUES (3000050001::bigint), (3000060002), (3000070003)) mv(acct)
  JOIN account m ON m.account_number = mv.acct::text
  CROSS JOIN LATERAL (
        SELECT account_id AS sender FROM account
         WHERE account_number LIKE '3%' AND account_id <> m.account_id
         ORDER BY random() LIMIT 120) s;

-- ---------------- transaction headers ----------------
INSERT INTO txn(txn_id, reference, txn_type, status, amount, channel, narration, created_at, completed_at)
OVERRIDING SYSTEM VALUE
SELECT txn_id, gen_random_uuid(), txn_type, status, amount, channel,
       CASE txn_type WHEN 'DEPOSIT' THEN 'Opening deposit' ELSE 'Transfer' END,
       ts, CASE WHEN status = 'COMPLETED' THEN ts + INTERVAL '2 seconds' END
  FROM stage;
SELECT setval(pg_get_serial_sequence('nairaflow.txn', 'txn_id'), (SELECT max(txn_id) FROM txn));

-- ---------------- ledger legs with running balances ----------------
-- balance_after is a running sum per account (window function), offset by
-- the balance the account already had from Portfolio 1 seed data.
INSERT INTO ledger_entry(txn_id, account_id, direction, amount, balance_after, created_at)
SELECT l.txn_id, l.account_id, l.direction, l.amount,
       a.balance + SUM(CASE l.direction WHEN 'C' THEN l.amount ELSE -l.amount END)
                   OVER (PARTITION BY l.account_id ORDER BY l.ts, l.txn_id, l.direction DESC),
       l.ts
  FROM (SELECT txn_id, from_acc AS account_id, 'D' AS direction, amount, ts FROM stage WHERE status = 'COMPLETED'
        UNION ALL
        SELECT txn_id, to_acc,              'C',              amount, ts FROM stage WHERE status = 'COMPLETED') l
  JOIN account a ON a.account_id = l.account_id;

-- Materialise balances from the ledger (balance = credits - debits)
UPDATE account a
   SET balance = a.balance + x.net
  FROM (SELECT account_id, SUM(CASE direction WHEN 'C' THEN amount ELSE -amount END) AS net
          FROM ledger_entry l
         WHERE l.txn_id IN (SELECT txn_id FROM stage)
         GROUP BY account_id) x
 WHERE a.account_id = x.account_id;

ALTER TABLE ledger_entry ENABLE TRIGGER ledger_balanced;
VACUUM ANALYZE;

-- ---------------- verification ----------------
SELECT 'customer' AS tbl, count(*) FROM customer UNION ALL
SELECT 'account', count(*) FROM account UNION ALL
SELECT 'txn', count(*) FROM txn UNION ALL
SELECT 'ledger_entry', count(*) FROM ledger_entry;

SELECT count(*) AS unbalanced_txns FROM (
  SELECT txn_id FROM ledger_entry GROUP BY txn_id
  HAVING SUM(CASE direction WHEN 'D' THEN amount ELSE -amount END) <> 0) x;
SELECT count(*) AS negative_customer_balances FROM account WHERE balance < 0 AND type_code <> 'GL';
SELECT SUM(balance) AS total_of_all_balances FROM account;   -- must be 0.00

SELECT pg_size_pretty(pg_total_relation_size('ledger_entry')) AS ledger_size,
       pg_size_pretty(pg_total_relation_size('txn'))          AS txn_size,
       pg_size_pretty(pg_database_size(current_database()))   AS database_size;
