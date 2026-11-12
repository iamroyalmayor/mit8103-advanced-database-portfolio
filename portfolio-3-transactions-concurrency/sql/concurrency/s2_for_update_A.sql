-- S2 Session A: pessimistic locking with SELECT ... FOR UPDATE
SET search_path TO nairaflow;
BEGIN;
SELECT ts('A: read + lock row (FOR UPDATE)');
SELECT balance AS bal FROM account WHERE account_number = '0123456787' FOR UPDATE \gset
\echo 'A sees balance' :bal
SELECT ts('A: app thinking (3s) while holding the row lock'), pg_sleep(3);
UPDATE account SET balance = :bal - 50000 WHERE account_number = '0123456787';
COMMIT;
SELECT ts('A: committed, lock released');
