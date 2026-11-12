-- S3 Session A: optimistic concurrency with REPEATABLE READ (snapshot isolation)
SET search_path TO nairaflow;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT ts('A: snapshot taken, read balance');
SELECT balance AS bal FROM account WHERE account_number = '0123456787' \gset
\echo 'A sees balance' :bal
SELECT ts('A: app thinking (3s)...'), pg_sleep(3);
SELECT ts('A: try to write');
UPDATE account SET balance = :bal - 50000 WHERE account_number = '0123456787';
COMMIT;
SELECT ts('A: transaction ended (application would now RETRY)');
