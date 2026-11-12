-- S1 Session A: naive read-modify-write at READ COMMITTED (the default)
SET search_path TO nairaflow;
BEGIN;  -- READ COMMITTED
SELECT ts('A: read balance');
SELECT balance AS bal FROM account WHERE account_number = '0123456787' \gset
\echo 'A sees balance' :bal
SELECT ts('A: app thinking (3s)...'), pg_sleep(3);
UPDATE account SET balance = :bal - 50000 WHERE account_number = '0123456787';
SELECT ts('A: wrote balance = old - 50000');
COMMIT;
SELECT ts('A: committed');
