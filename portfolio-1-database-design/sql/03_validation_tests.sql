-- =====================================================================
-- NairaFlow  |  Portfolio 1
-- File: 03_validation_tests.sql
-- Proves that keys and constraints reject bad data. psql runs in autocommit
-- mode with ON_ERROR_STOP off, so one failing test does not stop the script.
-- Expected result for each test: an ERROR line naming the constraint.
-- =====================================================================
SET search_path TO nairaflow;
\set ON_ERROR_STOP off
\echo '=== Row counts after seeding ==='
SELECT 'state' tbl, count(*) FROM state UNION ALL
SELECT 'account_type', count(*) FROM account_type UNION ALL
SELECT 'customer', count(*) FROM customer UNION ALL
SELECT 'account', count(*) FROM account UNION ALL
SELECT 'txn', count(*) FROM txn UNION ALL
SELECT 'ledger_entry', count(*) FROM ledger_entry UNION ALL
SELECT 'beneficiary', count(*) FROM beneficiary;

\echo '=== Account summary view ==='
SELECT * FROM v_account_summary ORDER BY account_number;

\echo '=== Ledger is balanced: sum of debits = sum of credits for every txn ==='
SELECT txn_id,
       SUM(amount) FILTER (WHERE direction='D') AS debits,
       SUM(amount) FILTER (WHERE direction='C') AS credits
  FROM ledger_entry GROUP BY txn_id ORDER BY txn_id LIMIT 5;
SELECT count(*) AS unbalanced_txns FROM (
  SELECT txn_id FROM ledger_entry GROUP BY txn_id
  HAVING SUM(CASE direction WHEN 'D' THEN amount ELSE -amount END) <> 0) x;

\echo '=== Sum of all balances is zero (money is only moved, never created) ==='
SELECT SUM(balance) AS total_of_all_balances FROM account;

\echo '--- T1 PRIMARY KEY / UNIQUE: duplicate BVN (expect uniqueness violation)'
INSERT INTO customer(bvn, first_name, last_name, email, phone, date_of_birth, state_code)
VALUES ('22145678901','Dup','Bvn','dup@example.ng','+2348099999999','1990-01-01','LA');

\echo '--- T2 CHECK: phone not in +234 format'
INSERT INTO customer(bvn, first_name, last_name, email, phone, date_of_birth, state_code)
VALUES ('22199999999','Bad','Phone','bad.phone@example.ng','08031234567','1990-01-01','LA');

\echo '--- T3 CHECK: customer under 18'
INSERT INTO customer(bvn, first_name, last_name, email, phone, date_of_birth, state_code)
VALUES ('22199999998','Too','Young','young@example.ng','+2348099999998', CURRENT_DATE - 365*10,'LA');

\echo '--- T4 FOREIGN KEY: unknown state code'
INSERT INTO customer(bvn, first_name, last_name, email, phone, date_of_birth, state_code)
VALUES ('22199999997','No','State','nostate@example.ng','+2348099999997','1990-01-01','ZZ');

\echo '--- T5 CHECK chk_no_overdraft: customer balance below zero'
UPDATE account SET balance = -1 WHERE account_number = '0123456788';

\echo '--- T6 CHECK: negative transaction amount'
INSERT INTO txn(txn_type, amount, channel) VALUES ('TRANSFER', -500, 'WEB');

\echo '--- T7 CHECK chk_reversal_link: REVERSAL without the txn it reverses'
INSERT INTO txn(txn_type, amount, channel) VALUES ('REVERSAL', 500, 'WEB');

\echo '--- T8 Deferred double-entry trigger: one-legged posting rejected at COMMIT'
BEGIN;
INSERT INTO txn(txn_type, status, amount, channel) VALUES ('DEPOSIT','COMPLETED',1000,'BRANCH');
INSERT INTO ledger_entry(txn_id, account_id, direction, amount, balance_after)
SELECT max(txn_id), 3, 'C', 1000, 0 FROM txn;
COMMIT;

\echo '--- T9 FK ON DELETE RESTRICT: cannot delete a customer who owns accounts'
DELETE FROM customer WHERE bvn = '22145678901';

\echo '--- T10 Business rule in transfer_funds(): insufficient funds'
SELECT transfer_funds('0123456788','0123456781', 1000000.00);

\echo '--- T11 Business rule: frozen account cannot transact (and freeze is audited)'
UPDATE account SET status = 'FROZEN' WHERE account_number = '0123456789';
SELECT transfer_funds('0123456789','0123456781', 100.00);
SELECT audit_id, table_name, record_id, action,
       old_data->>'status' AS old_status, new_data->>'status' AS new_status
  FROM audit_log ORDER BY audit_id DESC LIMIT 1;
UPDATE account SET status = 'ACTIVE' WHERE account_number = '0123456789';

\echo '--- T12 Reversal of a completed transfer'
SELECT txn_id, txn_type, status, amount FROM txn WHERE narration = 'Airtime refund';
SELECT reverse_transaction((SELECT txn_id FROM txn WHERE narration='Airtime refund'), 'Customer dispute #4471');
SELECT txn_id, txn_type, status, amount, reverses_txn_id FROM txn
 WHERE narration IN ('Airtime refund','Customer dispute #4471') ORDER BY txn_id;
SELECT account_number, balance FROM account WHERE account_number IN ('0123456783','0123456784');

\echo '--- T13 Reversing the same transaction twice is rejected'
SELECT reverse_transaction((SELECT txn_id FROM txn WHERE narration='Airtime refund'), 'again');

\echo '=== Final integrity check ==='
SELECT SUM(balance) AS total_of_all_balances FROM account;
