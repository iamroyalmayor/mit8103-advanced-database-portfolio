-- =====================================================================
-- NairaFlow  |  Portfolio 3: Transactions and Concurrency
-- File: 01_commit_rollback_savepoint.sql   (single session, ACID basics)
-- Uses Portfolio-1 accounts: 0123456781 Adaeze Okafor, 0123456783 Babatunde Adeyemi
-- =====================================================================
SET search_path TO nairaflow;
\pset footer off
CREATE OR REPLACE VIEW demo_bal AS
SELECT account_number, balance FROM account
 WHERE account_number IN ('0123456781','0123456783') ORDER BY account_number;

\echo '=== Starting balances ==='
SELECT * FROM demo_bal;

\echo '=== A. COMMIT: transfer N10,000 Adaeze -> Babatunde inside an explicit transaction ==='
BEGIN;
SELECT transfer_funds('0123456781','0123456783', 10000.00, 'MOBILE', 'P3 commit demo') AS txn_id;
SELECT * FROM demo_bal;                -- visible inside the transaction
COMMIT;
SELECT * FROM demo_bal;                -- durable after COMMIT
SELECT txn_id, txn_type, status, amount FROM txn WHERE narration = 'P3 commit demo';

\echo '=== B. ROLLBACK: operator debits an account by mistake and cancels ==='
BEGIN;
UPDATE account SET balance = balance - 99999 WHERE account_number = '0123456781';
SELECT * FROM demo_bal;                -- shows the wrong, uncommitted value
ROLLBACK;
SELECT * FROM demo_bal;                -- original value restored (Atomicity)

\echo '=== C. Automatic rollback: an error inside the transaction aborts ALL its work ==='
BEGIN;
SELECT transfer_funds('0123456781','0123456783', 1000.00, 'MOBILE', 'P3 auto-rollback part 1');
SELECT transfer_funds('0123456781','0123456783', 99999999.00, 'MOBILE', 'P3 auto-rollback part 2'); -- fails
SELECT 1;                              -- rejected: transaction is aborted
COMMIT;                                -- PostgreSQL turns this into ROLLBACK
SELECT count(*) AS rows_from_failed_txn FROM txn WHERE narration LIKE 'P3 auto-rollback%';
SELECT * FROM demo_bal;

\echo '=== D. SAVEPOINT: bulk salary run where one beneficiary is invalid ==='
BEGIN;
SELECT transfer_funds('0123456786','0123456781', 150000.00, 'WEB', 'Salary Nov - Adaeze');
SAVEPOINT before_bad_row;
SELECT transfer_funds('0123456786','9999999999', 150000.00, 'WEB', 'Salary Nov - unknown');  -- fails
ROLLBACK TO SAVEPOINT before_bad_row;  -- undo only the failed step
SELECT transfer_funds('0123456786','0123456783', 150000.00, 'WEB', 'Salary Nov - Babatunde');
COMMIT;
SELECT narration, status, amount FROM txn WHERE narration LIKE 'Salary Nov%' ORDER BY txn_id;
SELECT * FROM demo_bal;

\echo '=== E. Idempotency: the same request reference submitted twice creates ONE transaction ==='
SELECT transfer_funds('0123456781','0123456783', 500.00, 'MOBILE', 'P3 idempotent',
                      'a1b2c3d4-0000-4000-8000-000000008103') AS first_call;
SELECT transfer_funds('0123456781','0123456783', 500.00, 'MOBILE', 'P3 idempotent',
                      'a1b2c3d4-0000-4000-8000-000000008103') AS retry_after_timeout;
SELECT count(*) AS txns_created FROM txn WHERE narration = 'P3 idempotent';

\echo '=== Consistency check: all balances still sum to zero ==='
SELECT SUM(balance) AS total_of_all_balances FROM account;
