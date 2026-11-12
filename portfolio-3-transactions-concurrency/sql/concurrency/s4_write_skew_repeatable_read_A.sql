-- S4 Session A at REPEATABLE READ: premium-tier rule "Adaeze's combined balance must stay >= :floor"
-- Session A debits account 0123456781; the other session debits her OTHER account (disjoint rows).
SET search_path TO nairaflow;
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT ts('A: check combined balance');
SELECT sum(balance) AS combined FROM account WHERE customer_id = 2 \gset
\echo 'A sees combined balance' :combined ' floor' :floor
SELECT ts('A: rule OK -> debit 400,000 from 0123456781'), pg_sleep(3)
 WHERE :combined - 400000 >= :floor;
UPDATE account SET balance = balance - 400000
 WHERE account_number = '0123456781' AND :combined - 400000 >= :floor;   -- only if the rule check passed
COMMIT;
SELECT ts('A: end of transaction');
