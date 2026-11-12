-- S5 Session A: naive transfer locks FROM first, then TO  (Adaeze -> Babatunde)
SET search_path TO nairaflow;
BEGIN;
SELECT ts('A: lock 0123456781');
UPDATE account SET balance = balance - 100 WHERE account_number = '0123456781';
SELECT ts('A: waiting 3s'), pg_sleep(3);
SELECT ts('A: lock 0123456783');
UPDATE account SET balance = balance + 100 WHERE account_number = '0123456783';
COMMIT;
SELECT ts('A: end');
