-- S4 Session B at REPEATABLE READ: premium-tier rule "Adaeze's combined balance must stay >= :floor"
-- Session B debits account 0123456782; the other session debits her OTHER account (disjoint rows).
SET search_path TO nairaflow;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT ts('B: check combined balance');
SELECT sum(balance) AS combined FROM account WHERE customer_id = 2 \gset
\echo 'B sees combined balance' :combined ' floor' :floor
SELECT ts('B: rule OK -> debit 400,000 from 0123456782'), pg_sleep(1)
 WHERE :combined - 400000 >= :floor;
UPDATE account SET balance = balance - 400000
 WHERE account_number = '0123456782' AND :combined - 400000 >= :floor;   -- only if the rule check passed
COMMIT;
SELECT ts('B: end of transaction');
