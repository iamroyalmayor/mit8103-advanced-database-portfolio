-- SAFE transfer: the transfer_funds() stored function (ordered FOR UPDATE locks,
-- balance check, double-entry ledger) on the same 50 hot accounts.
\set f random(3000000001, 3000000050)
\set d random(1, 49)
\set t 3000000001 + ((:f - 3000000001 + :d) % 50)
\set amt random(1, 100)
SELECT nairaflow.transfer_funds(:f::char(10), :t::char(10), :amt, 'MOBILE', 'pgbench');
