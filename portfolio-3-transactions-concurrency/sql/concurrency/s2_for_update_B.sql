-- S2 Session B: same pattern; its FOR UPDATE must WAIT for A
SET search_path TO nairaflow;
BEGIN;
SELECT ts('B: request row lock (FOR UPDATE)');
SELECT balance AS bal FROM account WHERE account_number = '0123456787' FOR UPDATE \gset
SELECT ts('B: lock granted after A committed');
\echo 'B sees balance' :bal
UPDATE account SET balance = :bal - 30000 WHERE account_number = '0123456787';
COMMIT;
SELECT ts('B: committed');
