-- Integrity checks run before/after each pgbench stress test (hot set of 50 accounts)
SET search_path TO nairaflow;
\pset footer off
SELECT count(*)                         AS hot_accounts,
       sum(balance)                     AS hot_set_total,
       (SELECT sum(balance) FROM account) AS all_accounts_total_must_be_zero,
       count(*) FILTER (WHERE balance < 0) AS negative_balances
  FROM account WHERE account_number BETWEEN '3000000001' AND '3000000050';
SELECT count(*) AS hot_accounts_where_balance_differs_from_ledger
  FROM account a
  CROSS JOIN LATERAL (SELECT balance_after FROM ledger_entry l WHERE l.account_id = a.account_id
                       ORDER BY created_at DESC, entry_id DESC LIMIT 1) last
 WHERE a.account_number BETWEEN '3000000001' AND '3000000050'
   AND last.balance_after <> a.balance;
SELECT count(*) AS pgbench_txns,
       count(*) FILTER (WHERE x.unbalanced) AS unbalanced_pgbench_txns
  FROM (SELECT t.txn_id,
               SUM(CASE l.direction WHEN 'D' THEN l.amount ELSE -l.amount END) <> 0 AS unbalanced
          FROM txn t JOIN ledger_entry l USING (txn_id)
         WHERE t.narration = 'pgbench' GROUP BY t.txn_id) x;
