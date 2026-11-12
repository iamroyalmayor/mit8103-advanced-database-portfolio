-- UNSAFE transfer: application reads balances, then writes absolute values back.
-- No row locks, READ COMMITTED. Hot set = 50 accounts -> heavy contention.
\set f random(3000000001, 3000000050)
\set d random(1, 49)
\set t 3000000001 + ((:f - 3000000001 + :d) % 50)
\set amt random(1, 100)
BEGIN;
SELECT balance AS fb FROM nairaflow.account WHERE account_number = :f::char(10) \gset
UPDATE nairaflow.account SET balance = :fb - :amt WHERE account_number = :f::char(10);
SELECT balance AS tb FROM nairaflow.account WHERE account_number = :t::char(10) \gset
UPDATE nairaflow.account SET balance = :tb + :amt WHERE account_number = :t::char(10);
END;
