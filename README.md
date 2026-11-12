<div align="center">

<h1>NairaFlow Digital Bank</h1>

<p><strong>Advanced Database Systems Portfolio</strong></p>

<p>A five-part database portfolio covering design, query optimisation, concurrency, NoSQL, and distributed systems.</p>

<p>
  <a href="#case-study">Case study</a> ·
  <a href="#portfolio-roadmap">Portfolio roadmap</a> ·
  <a href="#technology-stack">Technology</a> ·
  <a href="#reproduce-the-work">Reproduce the work</a>
</p>

</div>

| 5 portfolio projects | 3 database technologies | PostgreSQL 16 | Synthetic data |
|:---:|:---:|:---:|:---:|
| Design through distributed systems | PostgreSQL, MongoDB, Redis | Reproducible Docker environments | No real customer information |

## Course and author

| | |
|---|---|
| Course | MIT 8103 Advanced Database Systems, MIVA Open University |
| Semester | 2026/2027 First Semester CA |
| Student | Ilesanmi Sulaimon |
| Email | i.sulaimon9160@miva.edu.ng |
| Matric No. | 2026/A/MIT/0472 |
| Student ID | 301869160 |
| Repository | [iamroyalmayor/mit8103-advanced-database-portfolio](https://github.com/iamroyalmayor/mit8103-advanced-database-portfolio)  |

## Case study

NairaFlow Digital Bank is a simulated Nigerian mobile-first fintech licensed to hold customer deposits and move money across mobile app, USSD, web, POS, ATM, and branch channels.

| Area | Scenario |
|---|---|
| Business operations | Customers open savings or current accounts after BVN-based KYC (tiers 1–3), receive deposits and salaries, transfer money, withdraw cash, and pay fees. Every movement must be exact, auditable, and reversible when a transfer fails or is disputed. |
| Database users | Retail and SME customers, tellers, customer-support staff, auditors and compliance, operations, and regulatory reporting (CBN). |
| Data model | Customers, accounts, transactions, a double-entry ledger with running balances, saved beneficiaries, staff, and an audit trail. |
| Key workflows | Open accounts · deposit and withdraw · transfer funds atomically · reverse failed or disputed transactions · produce statements · reconcile balances · detect suspicious inflows · report failed transactions and dormant accounts |

> All data is synthetic. No real customer data is used.

## Portfolio roadmap

| Portfolio | Focus | Highlights |
|:---:|---|---|
| [01 · Database design](portfolio-1-database-design/) | Design and modelling | ER diagram, 9-table BCNF schema, double-entry ledger, 13 constraint tests |
| [02 · Query optimisation](portfolio-2-query-optimisation/) | Query processing and optimisation | 2.1M ledger rows, 7 workload queries, `EXPLAIN ANALYZE` comparisons, composite/expression/partial/covering indexes, partition pruning |
| [03 · Transactions](portfolio-3-transactions-concurrency/) | Transactions and concurrency | COMMIT, ROLLBACK, SAVEPOINT, idempotency, lost updates, row locks, isolation levels, write skew, deadlocks, and pgbench stress tests |
| [04 · NoSQL](portfolio-4-nosql/) | NoSQL and advanced models | MongoDB document modelling, validation, indexes and transactions; Redis key-value patterns; graph design |
| [05 · Distributed systems](portfolio-5-distributed-cloud/) | Distributed and cloud databases | PostgreSQL replication and failover, MongoDB replica set and elections, shard-key analysis, AWS deployment architecture |
| [Documentation](docs/) | Final submission | LMS summary, reflection, and references |
| [Shared scripts](scripts/) | Reproducibility | Start PostgreSQL, run SQL with ordered logs, and rebuild environments |

Each portfolio folder includes its own README, implementation, tests, results, and an `evidence/` folder containing captured script output.

## Technology stack

| Component | Version | Used for |
|---|---:|---|
| PostgreSQL | 16 (`postgres:16`) | Portfolios 1, 2, 3, and 5 |
| pgbench | 16 | Portfolio 3 concurrency stress tests |
| MongoDB | 7.0 (`mongo:7`) | Portfolios 4 and 5 |
| Redis | 7.4 (`redis:7-alpine`) | Portfolio 4 |
| Docker Desktop / Compose | 29.x | Reproducible environments |
| Mermaid CLI | 11.4 | ER diagram rendering |

## Reproduce the work

Requirements: Docker Desktop and a Bash shell (Git Bash on Windows). No database installation is required locally.

```bash
# Portfolios 1–3 (~15 minutes; data loading dominates)
bash scripts/run_all_postgres.sh

# Portfolio 4 (~5 minutes)
bash portfolio-4-nosql/run.sh

# Portfolio 5 (~2 minutes; starts and stops its own cluster)
bash portfolio-5-distributed-cloud/run.sh
```

Each script writes its output to that portfolio's `evidence/` folder, so rerunning a script regenerates the submitted evidence.

## Further reading
See the [final documentation](docs/FINAL_DOCUMENTATION.md) for the portfolio summary, technical reflection, and references.
