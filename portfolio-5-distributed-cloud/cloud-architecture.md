# NairaFlow – Target Cloud Deployment Architecture (design)

This is the production design that the local Docker experiments in this folder imitate. It is a
design document: nothing here was deployed to a paid cloud account.

## 1. Constraints

| Constraint | Source | Impact |
|---|---|---|
| Customer data on Nigerian residents must be protected; cross-border transfer needs adequate safeguards | Nigeria Data Protection Act 2023 (NDPA) | Primary data stays in-country, or in a region covered by an approved transfer mechanism; encryption at rest and in transit |
| Banks must keep transaction records for at least 5 years and support audit | CBN guidelines / AML-CFT regulations | Ledger is append-only; old partitions are detached and archived to cheaper storage (Portfolio 2) |
| Money must never be lost (RPO = 0 for committed transfers); app downtime costs revenue and trust (RTO ≤ 1 min) | Business | Synchronous replication across availability zones and automatic failover |
| Read traffic (balance checks, statement views) is about 20× write traffic | Workload | Read replicas, Redis cache, MongoDB read models |

## 2. Architecture

```text
                    Mobile app / USSD gateway / Web / POS switch
                                     |
                         API gateway + transfer service
                     (idempotency key in Redis, retries)
                                     |
        +----------------------------+-----------------------------+
        |                            |                             |
 PostgreSQL cluster (system of   Redis (ElastiCache /          MongoDB replica set
 record: ledger, accounts)       Memorystore), Multi-AZ        (Atlas or self-managed),
  - Primary   AZ-a               sessions, OTP limits,         3 members across 3 AZs:
  - Sync standby AZ-b  <- RPO 0  balance cache, leaderboards   customer profiles, statement
  - Async read replica AZ-c                                    buckets, transaction documents
  - Cross-region async DR replica                                     ^
        |                                                             |
        +------ CDC (logical replication / Debezium -> Kafka) --------+
                       ledger events -> MongoDB read models, fraud engine, data warehouse
```

**Possible managed-service mapping:**
- *AWS:* Aurora PostgreSQL or RDS PostgreSQL Multi-AZ DB cluster (one writer and two readable
  standbys with semi-synchronous replication); ElastiCache for Redis; MongoDB Atlas on AWS;
  MSK (Kafka) for CDC.
- *Azure:* Azure Database for PostgreSQL Flexible Server with zone-redundant HA; Azure Cache for
  Redis; Cosmos DB for MongoDB vCore or Atlas.

The hyperscalers' nearest regions are South Africa (AWS `af-south-1` Cape Town, Azure South Africa
North) and Europe. Under the NDPA this means either (a) a documented cross-border transfer basis, or
(b) a Nigerian cloud or colocation provider (e.g. Lagos data centres) running the same open-source
stack, PostgreSQL + Patroni + MongoDB, which is exactly what the Docker topology here models.

## 3. Replication and consistency decisions

| Decision | Choice | Trade-off (CAP / PACELC) |
|---|---|---|
| Ledger writes | PostgreSQL **synchronous** commit to one standby in another AZ | **PC/EC**: the bank prefers consistency. Experiment R6 shows the cost: if the only sync standby is down, commits block until an operator (or Patroni) switches to async |
| Balance and statement reads | Async read replicas and MongoDB secondaries with `readConcern: majority` | **EL**: low latency, may be milliseconds stale. Fine for viewing history, never used for balance checks before debiting |
| Debit authorisation | Always on the **primary**, inside `transfer_funds()` | Read-your-writes and no overdrafts from stale reads |
| MongoDB writes | `w: "majority"` | Survives the loss of any one node without rollback of acknowledged writes (experiment M4/M5) |
| Redis | Cache and ephemeral data only, never the source of truth | Can be lost and rebuilt; an AP system is acceptable here |

## 4. Sharding plan (when one primary is no longer enough)

- **Shard key: `customer_id` (hashed).** One customer's accounts, ledger legs and statements land on
  the same shard, so a statement is a single-shard query, and hashing spreads load evenly
  (shard simulation: 24.5–25.3% of rows per shard).
- **Rejected: `created_at` (range).** Every new write would go to the newest shard, a hot spot
  (shard simulation, case B).
- **Cross-shard transfers** (customer A on shard 1 → customer B on shard 3) need a distributed
  commit protocol (two-phase commit in Citus or Aurora Limitless) or a saga: debit, then credit,
  with a compensating reversal using `reverse_transaction()` if the credit fails. Idempotency keys
  make the saga's retries safe.
- Bank-wide analytics (e.g. "today's volume") fan out to all shards, so they run on the data
  warehouse fed by CDC, not on the OLTP cluster.

## 5. Availability, backup and DR

| Metric | Target | Mechanism |
|---|---|---|
| RPO (AZ failure) | 0 | Synchronous standby |
| RTO (AZ failure) | < 60 s | Managed failover or Patroni (PostgreSQL; experiment R7: `pg_promote()` made the replica writable within seconds of the decision, with no committed transfer lost); MongoDB elected a new primary automatically in about 11.5–12 s in experiment M4 |
| RPO (region failure) | < 5 min | Async cross-region replica plus continuous WAL archiving (PITR) |
| Backups | Daily snapshot plus WAL archive, 35-day PITR; monthly ledger partitions archived to object storage with object lock (WORM) | Meets the 5-year retention |
| Security | TLS everywhere; KMS encryption at rest; IAM database auth; no public endpoints; column-level encryption or tokenisation of BVN | NDPA, PCI-DSS for card data |
