-- S6 Session A: the FIX used inside transfer_funds(): lock both rows in account_number order
SET search_path TO nairaflow;
BEGIN;
SELECT ts('A: lock both accounts in a fixed order');
SELECT account_number FROM account WHERE account_number IN ('0123456781','0123456783')
 ORDER BY account_number FOR UPDATE;
SELECT ts('A: both locks held'), pg_sleep(3);
UPDATE account SET balance = balance - 100 WHERE account_number = '0123456781';
UPDATE account SET balance = balance + 100 WHERE account_number = '0123456783';
COMMIT;
SELECT ts('A: committed (no deadlock)');
