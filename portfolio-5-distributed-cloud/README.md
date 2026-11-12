# Portfolio 5 – Distributed and Cloud Database Exercise

A working distributed setup for NairaFlow on one machine ([`docker-compose.yml`](docker-compose.yml)),
plus a production cloud design ([`cloud-architecture.md`](cloud-architecture.md)).

```text
 p5-pg-primary  --WAL stream (slot replica1_slot)-->  p5-pg-replica   (PostgreSQL 16 hot standby)
 p5-mongo1 (priority 2)  <-->  p5-mongo2  <-->  p5-mongo3             (MongoDB 7 replica set rs5)
```

Run: `bash run.sh` starts the cluster, runs every experiment, saves the evidence and tears the
cluster down (`KEEP_UP=1` keeps it running).

## 1. PostgreSQL streaming replication ([`postgres-replication/`](postgres-replication/))

Set-up: the primary runs with `wal_level=replica`; an init script creates a `REPLICATION` role and
a `pg_hba` rule. The replica clones the primary with `pg_basebackup -R -C -S replica1_slot`, which
writes `standby.signal` and `primary_conninfo` and creates a **replication slot**, so the primary
keeps the WAL the replica still needs even while it is offline.

| # | Experiment | Observed (see [evidence](evidence/01_postgres_replication_failover.txt)) |
|---|---|---|
| R1 | Topology | `pg_stat_replication`: `replica1 · streaming · async`; replica `pg_is_in_recovery() = t` |
| R2 | Schema and seed loaded on the primary only | Same account count and Σ balance (0.00) read from the replica |
| R3 | Write on the replica | `ERROR: cannot execute … in a read-only transaction` |
| R4 | 200 k-row write burst | The replica kept up: replay lag 0 bytes, `replay_lag` between ≈ 6 ms and ≈ 190 ms across runs, straight after the burst, and all 200 k rows were readable on the replica. On one laptop with no network latency, async lag is tiny, but it is never guaranteed to be 0 (**eventual consistency**) |
| R5 | `synchronous_standby_names='replica1'` | `sync_state = sync`; COMMIT now waits for the standby's flush, so **RPO = 0** |
| R6 | Stop the replica while synchronous | The transfer **hangs** (its backend shows `wait_event = SyncRep`) (`wait_event = SyncRep`); the client times out after 8 s. This is CAP in practice: during a partition the system chose **consistency over availability**. The operator degraded to async, the blocked transaction then completed. Note that it was already durable in the primary's local WAL and only its *acknowledgement* waited. The restarted replica caught up through its slot and shows all three P5 transactions |
| R7 | **Failover**: `docker kill` the primary, `pg_promote()` on the replica | The replica becomes writable, still holds the last transfer committed before the crash, accepts new transfers, and Σ balances = 0.00 |

## 2. Sharding analysis ([`sharding/shard_key_simulation.sql`](sharding/shard_key_simulation.sql))

Hash partitions stand in for shards ([evidence](evidence/02_shard_key_simulation.txt)):

- **HASH(customer_id), 4 shards:** each shard holds 24.5–25.3% of 200 k ledger rows (no hot shard).
  A single customer's statement is pruned to **one** shard. A bank-wide "today" report must
  **scatter-gather** across all four.
- **RANGE(created_at):** 100% of the last 24 hours of writes land on the newest shard, a write
  **hot spot**. Rejected as a shard key; it is still the right *partition* key for archiving
  inside one node (Portfolio 2).
- Cross-shard transfers need two-phase commit or a saga with compensating reversals
  (`reverse_transaction()`), covered in the cloud design.

## 3. MongoDB replica set ([`mongodb-replica-set/`](mongodb-replica-set/))

| # | Experiment | Observed (see [evidence](evidence/03_mongodb_replica_set_failover.txt)) |
|---|---|---|
| M1 | `rs.initiate` with 3 members (mongo1 priority 2) | 1 PRIMARY, 2 SECONDARY |
| M2 | Insert with `w:"majority"`, read from a secondary with `readConcern:"majority"` | The document is visible on the secondary |
| M3 | `w:5` on a 3-member set | Returns `UnsatisfiableWriteConcern`, **but the document was still written on the primary** (M5 counts 3 documents, not 2). A write-concern error means "the durability guarantee could not be confirmed", not "rolled back", so the application must treat it as an *unknown outcome* and reconcile with the idempotency key |
| M4 | `docker kill` the primary | A surviving member was elected **PRIMARY** in **≈ 11.5–12 s** across runs (≈ 10 s default `electionTimeoutMillis` plus heartbeat detection); the killed node shows `(not reachable/healthy)` |
| M5 | Write after the failover | `w:"majority"` insert acknowledged by the new primary |
| M6 | Restart the old primary | It rejoins as SECONDARY, catches up, and the priority-2 member later becomes primary again |

## 4. Consistency and availability: what this shows

| Property | PostgreSQL (primary/standby) | MongoDB (replica set) |
|---|---|---|
| Failover | Manual here (`pg_promote`); automated in production with Patroni or managed RDS/Aurora | **Automatic** election (Raft-like protocol); needs a majority (2 of 3) |
| Durability of acknowledged writes | Async: may lose the last few ms of commits on failover. Sync: RPO 0 | `w:majority`: acknowledged writes survive any single-node failure |
| Read scaling | Hot-standby reads, possibly stale | `readPreference: secondary`, possibly stale; `majority` avoids reading rolled-back data |
| Behaviour during a partition | Sync mode: writes block (CP) | The minority side cannot accept writes (CP for majority writes) |

## 5. Cloud deployment design

See [`cloud-architecture.md`](cloud-architecture.md): a Multi-AZ PostgreSQL system of record
with a synchronous standby, read replicas and cross-region DR; Redis and MongoDB replica sets; CDC
to read models and the warehouse; a hashed `customer_id` shard key; RPO and RTO targets;
backup/PITR and WORM archiving; and how the Nigeria Data Protection Act 2023 shapes region
choice.
