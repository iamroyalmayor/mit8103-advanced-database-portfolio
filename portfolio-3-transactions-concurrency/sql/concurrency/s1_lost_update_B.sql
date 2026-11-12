-- S1 Session B: starts 0.5s after A, same naive logic, debits 30,000
SET search_path TO nairaflow;
BEGIN;
SELECT ts('B: read balance');
SELECT balance AS bal FROM account WHERE account_number = '0123456787' \gset
\echo 'B sees balance' :bal
UPDATE account SET balance = :bal - 30000 WHERE account_number = '0123456787';
SELECT ts('B: wrote balance = old - 30000');
COMMIT;
SELECT ts('B: committed');
