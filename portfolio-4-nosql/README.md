# Portfolio 4 – NoSQL and Advanced Data Models

The same NairaFlow bank, modelled in two NoSQL stores, each used where it fits better than the
relational core:

| Store | Model | NairaFlow use |
|---|---|---|
| **MongoDB 7** | Document | Customer profiles (KYC, devices, beneficiaries), transaction documents with flexible channel metadata, and pre-built monthly statements for the mobile app |
| **Redis 7** | Key-value (plus sorted set and HyperLogLog) | Sessions, OTP rate limiting, idempotency keys, balance cache, real-time leaderboards and fraud counters |
| *Neo4j (design only)* | Graph | Money-mule ring detection (see §5) |

## 1. Document model design

```text
customers     { _id:"CUS-000002", bvn, name:{first,last}, phone, email,
                kyc:{tier, verified, documents:[...]},           <- embedded (1:few, read together)
                address:{state, city}, devices:[...≤5], beneficiaries:[...≤50],
                business:{rcNumber, sector}  <- present only for SME customers (polymorphism) }
accounts      { _id:"4000001234" (NUBAN), customerId, holderName (denormalised),
                type, currency, balance: Decimal128, status }    <- referenced (hot, updated on every txn)
transactions  { _id:<reference>, type, status, amount: Decimal128, channel, createdAt,
                legs:[{account, dir:"D"|"C", amount}],           <- embedded ledger legs
                meta:{device, terminal?, failureReason?} }       <- flexible, channel-specific
statements    { _id:"4000001234:2026-11", account, month, count, credits, debits,
                entries:[{txn, at, dir, amount, channel}, ...] } <- BUCKET pattern
```

**Embed or reference: the reasoning**

| Relationship | Decision | Reason |
|---|---|---|
| customer → KYC docs, devices, beneficiaries | **Embed** | Bounded (`maxItems` in the validator), always read with the profile at login, rarely changed |
| customer → accounts | **Reference** | An account balance changes on every transaction; embedding it would rewrite the whole customer document and cause write contention on one document |
| transaction → ledger legs | **Embed** | Legs never exist without their transaction and are written atomically with it. A single-document write is atomic in MongoDB, so most postings need **no** multi-document transaction |
| account → statement lines | **Bucket** (one document per account per month) | The app's History screen becomes one `_id` lookup instead of scanning N rows; bucket size is bounded by month |
| account.holderName | **Denormalised copy** | Receipts and statements never need a `$lookup`; the name rarely changes |

Money is stored as **Decimal128**, never as a double. `$jsonSchema` validators enforce the BVN and
phone patterns, enums, KYC tier range and array bounds, so "schemaless" does not mean "unvalidated" (query M7).

## 2. Implementation and results

Run with `bash run.sh` (starts `mongo:7` as a single-node replica set, which multi-document
transactions require, plus `redis:7-alpine`).

Data loaded: 5,000 customers, 8,001 accounts, 157,973 transactions and 96,721 statement buckets
(built server-side with `$group` + `$merge`). The sum of all balances is exactly `0.00`.

| Query | Before index | After index | Index type |
|---|---|---|---|
| M1 account history via `legs.account` (90 days) | COLLSCAN, 157,974 docs examined, ~330–420 ms | IXSCAN, 13 docs, 4–7 ms | **Multikey** compound `{legs.account:1, createdAt:-1}` |
| M2 same need via bucket document | – | IDHACK, 1 doc, 0 ms | `_id` |
| M3 login lookup by phone | COLLSCAN, 5,000 docs | IXSCAN, 1 doc | Unique `{phone:1}` |
| M4 failed transactions dashboard (aggregation) | COLLSCAN, 157,974 docs, ~300–420 ms | IXSCAN, 630 docs, 12–14 ms | **Partial** index `{createdAt:-1}` where `status:"FAILED"` |

(Exact timings vary slightly between runs; the docs-examined counts are deterministic.)

M5 shows the cost side of the document model: a cross-collection report (balances by state) needs
`$lookup`, which is MongoDB's equivalent of a join, and this is exactly the kind of query where the
relational model is stronger.

### Multi-document ACID transaction (`04_multi_document_transaction.js`)

`session.withTransaction()` with `readConcern: snapshot` and `writeConcern: majority` debits one
account, credits another and inserts the transaction document as **one** atomic unit:

| Case | Outcome |
|---|---|
| Valid transfer of ₦25,000 | COMMITTED |
| Insufficient funds (conditional `$gte` debit matches 0 docs) | ABORTED, nothing written |
| Unknown beneficiary (debit already applied inside the transaction) | ABORTED, **debit rolled back** |
| Duplicate reference (`_id` clash, E11000) | ABORTED: idempotency enforced by the primary key |

Afterwards account A is exactly ₦25,000 lower, B is ₦25,000 higher, one transaction document
exists and Σ balances = 0.

## 3. Key-value model (Redis, `redis/redis_keyvalue_demo.sh`)

| Pattern | Redis feature | Why not PostgreSQL |
|---|---|---|
| K1 Session tokens | `SET … EX 900` | Automatic expiry, sub-millisecond reads on every API call |
| K2 OTP brute-force limit (3 tries per 5 min) | `INCR` + `EXPIRE` | Atomic counter with TTL and no table bloat; the 4th attempt is **BLOCKED** in the evidence |
| K3 Idempotency key | `SET … NX EX` | Atomic "first writer wins"; the 2nd call returns nil, so the duplicate is detected |
| K4 Balance cache | Hash + TTL, deleted after posting | Takes the read load of the balance screen off the primary DB |
| K5 Top senders today | Sorted set `ZINCRBY` / `ZREVRANGE` | O(log N) live ranking |
| K6 Distinct senders into an account per hour | HyperLogLog `PFADD` / `PFCOUNT` | About 12 KB per key whatever the cardinality; feeds the same mule rule as the SQL query Q5 |

Redis is **not** the system of record. Everything in it can be lost and rebuilt, which is why
balances live in PostgreSQL and MongoDB.

## 4. Suitability: which model for which job

| Concern | Relational (PostgreSQL) | Document (MongoDB) | Key-value (Redis) |
|---|---|---|---|
| Core ledger, multi-row ACID, constraints | **Best**: FKs, CHECKs, deferred triggers, SERIALIZABLE | Possible (embedded legs, transactions) but constraints live in application code | Unsuitable |
| Evolving customer and KYC profiles, channel-specific metadata | ALTER TABLE or JSONB | **Best**: flexible schema with validation | – |
| Read-optimised app views (statements) | Needs indexes and a sort | **Best**: one bucket document | – |
| Ephemeral, high-rate, TTL data | Poor (vacuum and bloat) | OK | **Best** |
| Ad-hoc analytics across entities | **Best** (joins, planner) | `$lookup` is costly | – |

**Conclusion:** NairaFlow uses **polyglot persistence**. PostgreSQL stays the system of record for
money; MongoDB serves customer-facing reads and flexible profiles (fed from the ledger by change
data capture); Redis handles sessions, rate limits and real-time counters.

## 5. Graph model (design only, not executed)

Money-mule rings are a path problem ("money that leaves account X reaches account Y within 3 hops
in 1 hour"), which is awkward as recursive SQL but natural in a graph:

```cypher
// (:Customer)-[:OWNS]->(:Account)-[:SENT {amount, at}]->(:Account), (:Customer)-[:USES]->(:Device)
MATCH path = (src:Account)-[:SENT*2..4]->(dst:Account)
WHERE all(r IN relationships(path) WHERE r.at > datetime() - duration('PT1H'))
WITH dst, count(DISTINCT src) AS feeders WHERE feeders >= 50
MATCH (c:Customer)-[:OWNS]->(dst), (c)-[:USES]->(d:Device)<-[:USES]-(other:Customer)
RETURN dst.number, feeders, collect(DISTINCT other.id) AS customers_sharing_device;
```

Portfolio 2 Q5 implements the one-hop version of this rule in SQL. Going to multi-hop with shared
devices is where a graph database would justify itself.

## 6. Evidence

| File | Content |
|---|---|
| [`evidence/00_versions.txt`](evidence/00_versions.txt) | MongoDB 7.0 and Redis 7.4 versions |
| [`evidence/01_collections_output.txt`](evidence/01_collections_output.txt) | Collections and validator |
| [`evidence/02_load_data_output.txt`](evidence/02_load_data_output.txt) | Counts, Σ = 0, sample customer, transaction and bucket documents |
| [`evidence/03_queries_and_indexes_output.txt`](evidence/03_queries_and_indexes_output.txt) | M1–M7 results with explain statistics before and after |
| [`evidence/04_transaction_output.txt`](evidence/04_transaction_output.txt) | Commit and the three abort cases |
| [`evidence/05_redis_output.txt`](evidence/05_redis_output.txt) | K1–K6 |
