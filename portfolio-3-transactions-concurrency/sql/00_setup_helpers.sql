-- Helper objects for the two-session concurrency demos.
SET search_path TO nairaflow;

-- ts('label') -> "HH:MI:SS.mmm  label" so each session's log shows WHEN each step happened
CREATE OR REPLACE FUNCTION ts(label TEXT) RETURNS TEXT
LANGUAGE sql VOLATILE AS $$ SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') || '  ' || label $$;

-- The ledger is the system of record. The demo scenarios S1-S4 deliberately
-- update account.balance directly (to isolate the concurrency behaviour), so
-- afterwards each touched balance is re-synchronised from its latest ledger leg.
CREATE OR REPLACE FUNCTION resync_balance(p_account CHAR(10)) RETURNS NUMERIC
LANGUAGE sql AS $$
    UPDATE account a
       SET balance = (SELECT l.balance_after FROM ledger_entry l
                       WHERE l.account_id = a.account_id
                       ORDER BY l.created_at DESC, l.entry_id DESC LIMIT 1)
     WHERE a.account_number = p_account
    RETURNING balance;
$$;
