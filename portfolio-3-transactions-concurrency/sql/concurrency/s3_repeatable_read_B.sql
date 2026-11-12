-- S3 Session B
SET search_path TO nairaflow;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT ts('B: read balance');
SELECT balance AS bal FROM account WHERE account_number = '0123456787' \gset
\echo 'B sees balance' :bal
UPDATE account SET balance = :bal - 30000 WHERE account_number = '0123456787';
COMMIT;
SELECT ts('B: committed first');
