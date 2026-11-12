-- S5 Session B: opposite direction (Babatunde -> Adaeze) locks in the opposite order
SET search_path TO nairaflow;
BEGIN;
SELECT ts('B: lock 0123456783');
UPDATE account SET balance = balance - 100 WHERE account_number = '0123456783';
SELECT ts('B: waiting 1s'), pg_sleep(1);
SELECT ts('B: lock 0123456781');
UPDATE account SET balance = balance + 100 WHERE account_number = '0123456781';
COMMIT;
SELECT ts('B: end');
