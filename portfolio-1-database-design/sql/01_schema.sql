-- =====================================================================
-- NairaFlow Digital Bank  |  MIT 8103 Portfolio 1: Database Design
-- File: 01_schema.sql  -- DDL for the normalised (3NF/BCNF) relational schema
-- Target DBMS: PostgreSQL 16
-- =====================================================================

DROP SCHEMA IF EXISTS nairaflow CASCADE;
CREATE SCHEMA nairaflow;
SET search_path TO nairaflow;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- ---------------------------------------------------------------------
-- 1. Reference / lookup tables (remove transitive dependencies -> 3NF)
-- ---------------------------------------------------------------------
CREATE TABLE state (
    state_code   CHAR(2)      PRIMARY KEY,                 -- e.g. 'LA' Lagos
    state_name   VARCHAR(40)  NOT NULL UNIQUE,
    geo_zone     VARCHAR(20)  NOT NULL
                 CHECK (geo_zone IN ('North Central','North East','North West',
                                     'South East','South South','South West'))
);

CREATE TABLE account_type (
    type_code      VARCHAR(10)    PRIMARY KEY,             -- SAVINGS, CURRENT, GL
    description    VARCHAR(60)    NOT NULL,
    daily_limit    NUMERIC(18,2)  NOT NULL CHECK (daily_limit > 0),
    interest_rate  NUMERIC(5,2)   NOT NULL DEFAULT 0 CHECK (interest_rate BETWEEN 0 AND 100),
    is_internal    BOOLEAN        NOT NULL DEFAULT FALSE   -- internal GL accounts
);

-- ---------------------------------------------------------------------
-- 2. Core entities
-- ---------------------------------------------------------------------
CREATE TABLE customer (
    customer_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- surrogate key
    bvn            CHAR(11)     NOT NULL UNIQUE                        -- natural/candidate key
                   CHECK (bvn ~ '^[0-9]{11}$'),
    first_name     VARCHAR(50)  NOT NULL,
    last_name      VARCHAR(50)  NOT NULL,
    email          VARCHAR(120) NOT NULL UNIQUE CHECK (position('@' IN email) > 1),
    phone          VARCHAR(14)  NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    date_of_birth  DATE         NOT NULL CHECK (date_of_birth <= CURRENT_DATE - INTERVAL '18 years'),
    kyc_tier       SMALLINT     NOT NULL DEFAULT 1 CHECK (kyc_tier BETWEEN 1 AND 3),
    state_code     CHAR(2)      NOT NULL REFERENCES state(state_code),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE account (
    account_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number  CHAR(10)      NOT NULL UNIQUE CHECK (account_number ~ '^[0-9]{10}$'), -- NUBAN
    customer_id     BIGINT        NOT NULL REFERENCES customer(customer_id) ON DELETE RESTRICT,
    type_code       VARCHAR(10)   NOT NULL REFERENCES account_type(type_code),
    currency        CHAR(3)       NOT NULL DEFAULT 'NGN' CHECK (currency IN ('NGN','USD')),
    balance         NUMERIC(18,2) NOT NULL DEFAULT 0,
    status          VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    opened_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- customer accounts may never go negative; internal GL accounts may
    CONSTRAINT chk_no_overdraft CHECK (balance >= 0 OR type_code = 'GL')
);

CREATE TABLE staff (
    staff_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    role        VARCHAR(20)  NOT NULL CHECK (role IN ('TELLER','AUDITOR','SUPPORT','ADMIN')),
    email       VARCHAR(120) NOT NULL UNIQUE
);

-- Transaction header: one row per business transaction
CREATE TABLE txn (
    txn_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference        UUID          NOT NULL UNIQUE DEFAULT gen_random_uuid(), -- idempotency key
    txn_type         VARCHAR(12)   NOT NULL
                     CHECK (txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER','REVERSAL','FEE')),
    status           VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','COMPLETED','FAILED','REVERSED')),
    amount           NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    channel          VARCHAR(6)    NOT NULL CHECK (channel IN ('MOBILE','USSD','WEB','POS','ATM','BRANCH')),
    narration        VARCHAR(140),
    reverses_txn_id  BIGINT        REFERENCES txn(txn_id),               -- recursive relationship
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    completed_at     TIMESTAMPTZ,
    CONSTRAINT chk_reversal_link CHECK ((txn_type = 'REVERSAL') = (reverses_txn_id IS NOT NULL)),
    CONSTRAINT chk_completed_time CHECK (completed_at IS NULL OR completed_at >= created_at)
);

-- Double-entry ledger: every COMPLETED txn has >= 2 legs whose debits = credits
CREATE TABLE ledger_entry (
    entry_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id         BIGINT        NOT NULL REFERENCES txn(txn_id),
    account_id     BIGINT        NOT NULL REFERENCES account(account_id),
    direction      CHAR(1)       NOT NULL CHECK (direction IN ('D','C')),  -- debit / credit
    amount         NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    balance_after  NUMERIC(18,2) NOT NULL,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_leg UNIQUE (txn_id, account_id, direction)
);

-- M:N  customer <-> account  (saved beneficiaries)
CREATE TABLE beneficiary (
    customer_id   BIGINT       NOT NULL REFERENCES customer(customer_id) ON DELETE CASCADE,
    account_id    BIGINT       NOT NULL REFERENCES account(account_id)  ON DELETE CASCADE,
    nickname      VARCHAR(40),
    added_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, account_id)                       -- composite key
);

-- Audit trail (semi-structured old/new images stored as JSONB)
CREATE TABLE audit_log (
    audit_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name   VARCHAR(40)  NOT NULL,
    record_id    BIGINT       NOT NULL,
    action       VARCHAR(6)   NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    old_data     JSONB,
    new_data     JSONB,
    changed_by   TEXT         NOT NULL DEFAULT current_user,
    changed_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- FK indexes that every OLTP path needs (PostgreSQL does not create them automatically)
CREATE INDEX ix_account_customer ON account(customer_id);
CREATE INDEX ix_ledger_txn       ON ledger_entry(txn_id);

-- ---------------------------------------------------------------------
-- 3. Integrity triggers
-- ---------------------------------------------------------------------

-- 3a. Double-entry rule, checked at COMMIT (deferred) so legs can be inserted one by one
CREATE OR REPLACE FUNCTION trg_check_balanced_txn() RETURNS trigger
LANGUAGE plpgsql
SET search_path = nairaflow, pg_catalog   -- pinned: callers with any search_path (and no hijacking)
AS $$
DECLARE v_debits NUMERIC; v_credits NUMERIC;
BEGIN
    SELECT COALESCE(SUM(amount) FILTER (WHERE direction='D'),0),
           COALESCE(SUM(amount) FILTER (WHERE direction='C'),0)
      INTO v_debits, v_credits
      FROM ledger_entry WHERE txn_id = NEW.txn_id;
    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'Unbalanced transaction %: debits % <> credits %',
                        NEW.txn_id, v_debits, v_credits;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_balanced
    AFTER INSERT ON ledger_entry
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_balanced_txn();

-- 3b. Generic audit trigger for sensitive tables
CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql
SET search_path = nairaflow, pg_catalog   -- pinned: callers with any search_path (and no hijacking)
AS $$
BEGIN
    INSERT INTO audit_log(table_name, record_id, action, old_data, new_data)
    VALUES (TG_TABLE_NAME,
            CASE WHEN TG_OP = 'DELETE' THEN (to_jsonb(OLD)->>TG_ARGV[0])::BIGINT
                 ELSE (to_jsonb(NEW)->>TG_ARGV[0])::BIGINT END,
            TG_OP,
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$;

CREATE TRIGGER audit_account_status
    AFTER UPDATE OF status ON account
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION trg_audit('account_id');

CREATE TRIGGER audit_customer
    AFTER UPDATE OR DELETE ON customer
    FOR EACH ROW EXECUTE FUNCTION trg_audit('customer_id');

-- ---------------------------------------------------------------------
-- 4. Business logic: atomic funds transfer and reversal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_funds(
    p_from_account  CHAR(10),
    p_to_account    CHAR(10),
    p_amount        NUMERIC,
    p_channel       VARCHAR DEFAULT 'MOBILE',
    p_narration     VARCHAR DEFAULT NULL,
    p_reference     UUID    DEFAULT gen_random_uuid(),
    p_txn_type      VARCHAR DEFAULT 'TRANSFER'          -- DEPOSIT / WITHDRAWAL use a GL account as one side
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = nairaflow, pg_catalog   -- pinned: callers with any search_path (and no hijacking)
AS $$
DECLARE
    v_from  account%ROWTYPE;
    v_to    account%ROWTYPE;
    v_txn   BIGINT;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive';
    END IF;
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- Idempotency: a retried request with the same reference returns the original txn
    SELECT txn_id INTO v_txn FROM txn WHERE reference = p_reference;
    IF FOUND THEN RETURN v_txn; END IF;

    -- Lock BOTH rows in a deterministic order (lowest account_number first)
    -- to prevent deadlocks between opposite-direction transfers.
    PERFORM 1 FROM account
     WHERE account_number IN (p_from_account, p_to_account)
     ORDER BY account_number
     FOR UPDATE;

    SELECT * INTO v_from FROM account WHERE account_number = p_from_account;
    SELECT * INTO v_to   FROM account WHERE account_number = p_to_account;

    IF v_from.account_id IS NULL OR v_to.account_id IS NULL THEN
        RAISE EXCEPTION 'Unknown account';
    END IF;
    IF v_from.status <> 'ACTIVE' OR v_to.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account not active (from=%, to=%)', v_from.status, v_to.status;
    END IF;
    IF v_from.balance < p_amount AND v_from.type_code <> 'GL' THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, requested %', v_from.balance, p_amount
              USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO txn(reference, txn_type, status, amount, channel, narration, completed_at)
    VALUES (p_reference, p_txn_type, 'COMPLETED', p_amount, p_channel, p_narration, clock_timestamp())
    RETURNING txn_id INTO v_txn;

    UPDATE account SET balance = balance - p_amount WHERE account_id = v_from.account_id;
    UPDATE account SET balance = balance + p_amount WHERE account_id = v_to.account_id;

    -- created_at = clock_timestamp() (taken while the row locks are held), NOT now():
    -- now() is the transaction START time, so a transfer that waited for a lock could
    -- otherwise get an earlier timestamp than the posting it queued behind.
    INSERT INTO ledger_entry(txn_id, account_id, direction, amount, balance_after, created_at)
    VALUES (v_txn, v_from.account_id, 'D', p_amount, v_from.balance - p_amount, clock_timestamp()),
           (v_txn, v_to.account_id,   'C', p_amount, v_to.balance   + p_amount, clock_timestamp());

    RETURN v_txn;
END $$;

-- Reverse a completed transfer by posting the mirror-image legs
CREATE OR REPLACE FUNCTION reverse_transaction(p_txn_id BIGINT, p_reason VARCHAR)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = nairaflow, pg_catalog   -- pinned: callers with any search_path (and no hijacking)
AS $$
DECLARE
    v_orig txn%ROWTYPE;
    v_rev  BIGINT;
    leg    RECORD;
BEGIN
    SELECT * INTO v_orig FROM txn WHERE txn_id = p_txn_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transaction % not found', p_txn_id; END IF;
    IF v_orig.status <> 'COMPLETED' THEN
        RAISE EXCEPTION 'Only COMPLETED transactions can be reversed (status=%)', v_orig.status;
    END IF;

    PERFORM 1 FROM account a JOIN ledger_entry l ON l.account_id = a.account_id
     WHERE l.txn_id = p_txn_id ORDER BY a.account_number FOR UPDATE OF a;

    INSERT INTO txn(txn_type, status, amount, channel, narration, reverses_txn_id, completed_at)
    VALUES ('REVERSAL', 'COMPLETED', v_orig.amount, v_orig.channel, p_reason, p_txn_id, clock_timestamp())
    RETURNING txn_id INTO v_rev;

    FOR leg IN SELECT * FROM ledger_entry WHERE txn_id = p_txn_id LOOP
        UPDATE account
           SET balance = balance + CASE leg.direction WHEN 'D' THEN leg.amount ELSE -leg.amount END
         WHERE account_id = leg.account_id;
        INSERT INTO ledger_entry(txn_id, account_id, direction, amount, balance_after, created_at)
        SELECT v_rev, leg.account_id,
               CASE leg.direction WHEN 'D' THEN 'C' ELSE 'D' END,
               leg.amount, a.balance, clock_timestamp()
          FROM account a WHERE a.account_id = leg.account_id;
    END LOOP;

    UPDATE txn SET status = 'REVERSED' WHERE txn_id = p_txn_id;
    RETURN v_rev;
END $$;

-- Convenience view: customer-facing account summary
CREATE VIEW v_account_summary AS
SELECT a.account_number, c.first_name || ' ' || c.last_name AS customer_name,
       t.description AS account_type, a.currency, a.balance, a.status, s.state_name
  FROM account a
  JOIN customer c     ON c.customer_id = a.customer_id
  JOIN account_type t ON t.type_code   = a.type_code
  JOIN state s        ON s.state_code  = c.state_code;
