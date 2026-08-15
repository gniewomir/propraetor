# Lightweight relational databases for Propraetor Workloads

**Researched:** 2026-07-28  
**Question:** Which relational database choices best minimize idle and low-load RAM, CPU, and disk footprint for small Workloads on Propraetor?  
**Scope:** Self-managed databases on the existing Host. Embedded/in-process engines and standalone networked database containers are evaluated separately because removing a database container changes the architecture. Managed services and performance optimization are not the focus.  
**Method:** Primary sources only: official product documentation, language references, source repositories, and first-party container images. Existing repo context comes from [`CONTEXT.md`](../../CONTEXT.md), [ADR-0004](../adr/0004-ubuntu-podman-initial-host-provisioning.md), [ADR-0007](../adr/0007-edge-service-network-and-routes.md), [ADR-0009](../adr/0009-host-volume.md), [ADR-0010](../adr/0010-component-setup-and-host-volume-layout.md), and [ADR-0018](../adr/0018-no-backwards-compat-during-development.md).

---

## Verdict

There is no trustworthy primary-source, apples-to-apples container benchmark covering these engines. Configuration minima are not observed idle use, and image size is not runtime RSS. This note therefore does **not** invent a RAM ranking among server containers; it narrows the field and specifies a reproducible Propraetor-specific experiment.

1. **Choose embedded SQLite by default** when one Workload owns the database and its write concurrency is modest. It uniquely removes the database server process, network hop, database Quadlet, and separate container image. SQLite officially describes itself as serverless and zero-configuration; the application reads and writes the file directly ([SQLite serverless](https://sqlite.org/serverless.html)). This is the strongest architectural route to the lowest total footprint, not merely a tuning exercise.
2. **Choose tuned PostgreSQL when a network database, concurrent writers, PostgreSQL tooling, or PostgreSQL semantics matter.** Its defaults are not a low-memory configuration: `shared_buffers` is typically 128 MB, `work_mem` is 4 MB per query operation, and `max_connections` is typically 100; PostgreSQL explicitly documents lowering memory settings and connection count when memory is constrained ([resource settings](https://www.postgresql.org/docs/current/runtime-config-resource.html), [connections](https://www.postgresql.org/docs/current/runtime-config-connection.html), [kernel resources](https://www.postgresql.org/docs/current/kernel-resources.html)). It is the baseline to beat experimentally.
3. **Benchmark Firebird and standalone `sqld` only if their trade-offs are acceptable.** Firebird is a credible compact client/server RDBMS with an official image and online backup tools, but it uses its own SQL dialect and ecosystem ([official image](https://firebirdsql.org/en/docker), [language reference](https://firebirdsql.org/file/documentation/chunk/en/refdocs/fblangref50/firebird-50-language-reference.html), [`gbak`](https://www.firebirdsql.org/file/documentation/html/en/firebirddocs/gbak/firebird-gbak.html)). `sqld` provides a network server around libSQL/SQLite and an official image, but keeps SQLite's fundamental single-writer model and adds a less conventional HTTP/WebSocket client surface ([libSQL README](https://github.com/tursodatabase/libsql/blob/main/README.md), [`sqld` build/run](https://github.com/tursodatabase/libsql/blob/main/docs/BUILD-RUN.md)).
4. **Use PGlite only for a JavaScript/TypeScript Workload that explicitly accepts single-process ownership.** It is real PostgreSQL compiled to WebAssembly and runs in-process, but uses PostgreSQL single-user mode rather than the normal multi-process server model ([PGlite README](https://github.com/electric-sql/pglite/), [implementation start parameters](https://github.com/electric-sql/pglite/blob/main/packages/pglite/src/pglite.ts)).
5. **Do not choose DuckDB for a normal transactional application database.** DuckDB explicitly says it is optimized for bulk operations, that many small transactions are not a primary design goal, and that automatic multi-process writing is unsupported ([DuckDB concurrency](https://duckdb.org/docs/stable/connect/concurrency)).
6. **MariaDB/MySQL are valid network RDBMSs but not leading footprint candidates without measurements.** Both default to a 128 MB InnoDB buffer pool before other global, connection, and engine memory; current MySQL has no embedded server library ([MariaDB settings](https://mariadb.com/docs/server/server-usage/storage-engines/innodb/innodb-system-variables), [MySQL settings](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html), [removed `libmysqld`](https://dev.mysql.com/doc/relnotes/mysql/8.0/en/news-8-0-1.html)).

---

## Decision criteria

Ordered for this repository:

1. **Total idle and low-load Host footprint:** cgroup anonymous memory, file cache attributable to the unit, CPU time while idle, writable data bytes, WAL/journal growth, and pulled image bytes.
2. **No standing database container where possible:** embedded engines inherit the application container's lifecycle and eliminate one Quadlet/container, but also couple data access, upgrades, and failure recovery to that Workload.
3. **Correctness for the likely workload:** ACID durability, crash recovery, expected writer concurrency, constraints, and transaction semantics take precedence over saving a small amount of memory.
4. **Operational fit:** rootless Podman, native Quadlets, Service Network only when needed, durable bytes on the Host Volume, deterministic backup and restore, and clean Park → Apply recovery.
5. **SQL and application fit:** standard SQL first; PostgreSQL dialect, wire protocol, drivers, and migration tooling are bonuses. Wire compatibility alone does not imply PostgreSQL SQL or transaction compatibility.
6. **Maturity and maintenance:** official releases/images, documented backup path, stable file format or dump path, and a credible upstream.
7. **Clean adoption:** Propraetor is pre-stability, so select one interface and update callers directly; do not add dual-database adapters or compatibility shims solely to preserve an early choice ([ADR-0018](../adr/0018-no-backwards-compat-during-development.md)).

### Resource evidence policy

- A documented cache default or minimum is **not** the process's RSS.
- A container image's compressed transfer size is **not** its writable disk footprint or resident memory.
- A vendor's production hardware recommendation is **not** observed idle use.
- Only the validation experiment below should produce comparative resource numbers for this Host, rootless Podman version, architecture, filesystem, image tags, and schema.

---

## Shortlist

| Tier | Candidate | Shape | PostgreSQL compatibility | Why it remains |
| --- | --- | --- | --- | --- |
| A | SQLite | Embedded in application | Low: its own mostly-standard SQL dialect | Only mature option here that completely removes the DB server/container |
| A | Tuned PostgreSQL | Network container | Native | Safest semantic/tooling choice; benchmark target and fallback |
| B | PGlite | Embedded in JS/TS application | High SQL-engine lineage; not normal server concurrency | Removes DB container while retaining actual PostgreSQL code |
| B | Firebird 5 | Network container or embedded library | Low; some familiar features, own dialect/protocol | Mature transactional alternative with official image and backup tools |
| B | libSQL / `sqld` | Embedded or network container | Low; SQLite-compatible, not PostgreSQL | SQLite lineage plus a first-party server mode |
| C | H2 / HSQLDB | Embedded or network JVM | H2 has partial PostgreSQL mode and PG server | Relevant only when the Workload already runs a JVM |
| C | MariaDB / MySQL | Network container | Low | Mature OLTP fallback, but no evidence it beats tuned PostgreSQL on this priority |
| Reject for OLTP | DuckDB | Embedded | Some surface resemblance, not compatibility | Excellent analytical engine, mismatched concurrency/transaction shape |

---

## Embedded / in-process options

### SQLite — default for one small Workload

**Resource and deployment shape.** SQLite has no server process: the application process accesses the database file directly, eliminating a database container and its image, network socket, and idle background process ([serverless architecture](https://sqlite.org/serverless.html)). The application image still contains a SQLite library or runtime binding, and its cgroup accounts for database heap and page cache, so "no DB container" does not mean zero database memory.

For Propraetor, put the database file in the owning Workload's durable tree on the Host Volume and bind-mount only that directory into its application container. Do not place it in an image layer or ephemeral container filesystem. This follows the repo's existing ownership model: durable Workload bytes belong under the Workload tree, while the rootless Workload joins the Service Network only for application traffic. Keep SQLite and its file on this same Host: SQLite warns that network-filesystem locking and sync behavior can corrupt remotely opened databases and recommends client/server when application and data are separated by a network ([SQLite over a network](https://www.sqlite.org/useovernet.html)).

**Concurrency and durability.** SQLite permits many simultaneous readers but only one writer per database file; writers queue, and the official guidance says to choose client/server when writers cannot take turns ([appropriate uses](https://sqlite.org/whentouse.html)). WAL mode lets readers and a writer proceed concurrently, but checkpoint behavior and the `-wal`/`-shm` files become part of operations ([WAL](https://sqlite.org/wal.html)). Use the Online Backup API (or a binding that exposes it) for a consistent live copy; it can copy incrementally while briefly holding read locks rather than locking the source for the whole backup ([Backup API](https://sqlite.org/backup.html)).

**SQL compatibility.** SQLite supports most standard SQL but intentionally omits features and adds its own; verify migrations against SQLite rather than treating it as PostgreSQL ([SQL language](https://www.sqlite.org/lang.html)). PostgreSQL-oriented ORMs often need a different driver, type mapping, DDL, and migration output.

**Fit.** Best for a single application process/container, low write contention, small operational surface, and backups that can be owned by that Workload. Avoid when several Workloads need direct database access, when many processes write concurrently, or when PostgreSQL-specific extensions/types/locking semantics are requirements.

### libSQL embedded — use only for a libSQL-specific need

libSQL is a fork of SQLite that remains embeddable, preserves SQLite file-format/API compatibility when extensions do not alter the format, and inherits SQLite's fundamental single-writer model ([official README](https://github.com/tursodatabase/libsql/blob/main/README.md)). Embedded replicas add local reads while writes normally go to a remote primary, which introduces a remote service rather than simplifying this Host-only architecture ([embedded replicas](https://docs.turso.tech/features/embedded-replicas/introduction)).

For a purely local Propraetor Workload, standard SQLite has the smaller conceptual and dependency surface. Choose embedded libSQL only when a supported libSQL client, replication feature, or planned Turso integration is itself a requirement; do not adopt it merely because it sounds like "SQLite plus server."

### PGlite — PostgreSQL semantics in one JS/TS process

PGlite packages PostgreSQL compiled to WebAssembly for browsers, Node.js, Bun, and Deno, with filesystem persistence available in server-side runtimes ([official README](https://github.com/electric-sql/pglite/), [API](https://github.com/electric-sql/pglite/blob/main/docs/docs/api.md)). It runs PostgreSQL in single-user mode because the normal PostgreSQL model forks a process per client and WebAssembly cannot provide that model ([official README](https://github.com/electric-sql/pglite/)).

That makes it attractive when a Node/Bun/Deno Workload wants PostgreSQL syntax without a database container, but it is not a drop-in network PostgreSQL server. A project maintainer states that concurrent PGlite instances over the same data directory are unsupported and can corrupt it; a single instance must own the directory ([upstream consistency issue](https://github.com/electric-sql/pglite/issues/323)). Treat third-party PG-wire wrappers as experimental integration components, not as equivalent to PostgreSQL's postmaster.

Before production use, validate crash durability carefully: the current implementation's default start parameters include PostgreSQL single-user mode and `-F`; PostgreSQL defines `-F` as disabling `fsync` ([PGlite source](https://github.com/electric-sql/pglite/blob/main/packages/pglite/src/pglite.ts), [`postgres` options](https://www.postgresql.org/docs/current/app-postgres.html)). That is a material durability difference from stock PostgreSQL and prevents an unconditional recommendation for durable server OLTP.

### DuckDB — analytical sidecar/library, not primary OLTP store

DuckDB supports ACID transactions and snapshot isolation ([transactions](https://duckdb.org/docs/stable/sql/statements/transactions)), but its own concurrency guide says it is optimized for bulk operations, many small transactions are not a primary design goal, and writing from multiple processes is not automatically supported ([concurrency](https://duckdb.org/docs/stable/connect/concurrency)). DuckDB itself recommends MySQL, PostgreSQL, or SQLite for multi-process transactions and using DuckDB extensions to query that data analytically ([concurrency](https://duckdb.org/docs/stable/connect/concurrency)).

Use it only if the Workload is fundamentally analytical and has one writer process, or as an in-process analytical engine reading exported/attached OLTP data. Its lack of a DB container is real, but does not make it a sound transactional default.

### H2 and HSQLDB — only when a JVM already exists

H2 is a Java database supporting embedded, server, and mixed modes. Embedded mode limits a database to one JVM/classloader at a time; server mode allows multiple applications and internally opens the database in embedded mode ([H2 features](https://www.h2database.com/html/features.html)). H2 offers a PostgreSQL compatibility mode and a PG-protocol server, but the mode changes selected syntax/behavior; it is not PostgreSQL itself ([compatibility mode](https://www.h2database.com/html/features.html), [server tools](https://www.h2database.com/html/tutorial.html)).

HSQLDB likewise supports in-process and server deployment. Its default `MEMORY` tables are loaded into memory, while `CACHED` tables keep only part of their data in memory and have configurable cache size ([system management](https://www.hsqldb.org/doc/guide/management-chapt.html), [deployment](https://www.hsqldb.org/doc/guide/deployment-chapt.html)).

Both can eliminate a separate DB container when embedded in an existing JVM Workload. For a non-JVM Workload, adding a JVM or a JVM database container is unlikely to minimize total Host footprint; this is an architectural inference to verify, not a claimed RAM measurement. Neither project publishes a first-party OCI image that fits this repo as cleanly as the PostgreSQL, MariaDB, or Firebird official images, so a Propraetor-owned image would add maintenance.

### Firebird embedded

Firebird supports local in-process attachment as well as network server architectures; on Linux, local access through the embedded library occurs inside the user application process and requires filesystem access to the database ([architecture](https://firebirdsql.org/manual/qsg25-appx-architectures.html), [embedded usage](https://www.firebirdsql.org/file/documentation/html/en/firebirddocs/ufb/using-firebird.html)). This can remove the DB container, but language bindings and packaging are less ubiquitous than SQLite, and its own SQL dialect still requires application-specific migrations.

Prefer SQLite for a new, single-owner embedded store unless a Firebird feature or existing Firebird application justifies the additional integration.

---

## Standalone networked containers

### Tuned PostgreSQL — baseline and likely network winner

**Why baseline.** PostgreSQL supplies the full desired dialect, mature drivers, concurrent client/server transactions, and official backup paths. The official container image documents durable `PGDATA` mounts and a shared-memory allocation for container deployments ([official image](https://hub.docker.com/_/postgres)).

**Memory knobs, not RAM claims.**

- `shared_buffers` is typically 128 MB by default and can be set as low as 128 kB, though PostgreSQL says values significantly above the minimum are usually needed for good performance ([resource settings](https://www.postgresql.org/docs/current/runtime-config-resource.html)).
- `work_mem` defaults to 4 MB **per sort/hash operation**, and concurrent sessions or complex queries can consume multiples of it ([resource settings](https://www.postgresql.org/docs/current/runtime-config-resource.html)).
- `max_connections` is typically 100; PostgreSQL sizes some shared resources from it and documents that increasing it raises allocation ([connections](https://www.postgresql.org/docs/current/runtime-config-connection.html)).
- PostgreSQL recommends lowering `shared_buffers`, `work_mem`, and connection count when PostgreSQL itself causes memory pressure, and suggests a connection pool rather than excessive server connections ([kernel resources](https://www.postgresql.org/docs/current/kernel-resources.html)).

A validation candidate should therefore use a deliberately small connection cap and conservative per-operation memory, while leaving `fsync`, `full_page_writes`, and `synchronous_commit` at durable settings. Do **not** trade correctness for a superficially low benchmark: PostgreSQL warns that disabling `fsync` can result in unrecoverable corruption after a crash ([WAL reliability](https://www.postgresql.org/docs/current/wal-reliability.html), [`fsync`](https://www.postgresql.org/docs/current/runtime-config-wal.html)).

**Backups.** PostgreSQL documents SQL dumps, filesystem-level backup, and continuous archiving as distinct approaches ([backup chapter](https://www.postgresql.org/docs/current/backup.html)). `pg_dump` makes a consistent export without blocking readers or writers, but the docs caution that it is generally not the sole regular production-backup method except in simple cases ([`pg_dump`](https://www.postgresql.org/docs/current/app-pgdump.html)). The existing Propraetor-specific storage analysis is in [`droplet-volume-small-postgres.md`](droplet-volume-small-postgres.md).

**Propraetor implications.** Run the DB as a rootless Quadlet on the Service Network with no Host-published port. Bind its data directory into Workload **Persist** on the Host Volume (`Volume=../persist/…`). If the DB belongs to one Workload, keep app and DB units in that Workload's authored `systemd/` bag; if several Workloads share it, define explicit ownership and backup before implementation — Host destroy is Orphan Reap (Environment absence), not a per-Intent wipe.

### Firebird 5 — credible lightweight server candidate

Firebird's Superserver architecture uses one process with threads for client connections; other architectures trade process and cache shape differently ([server architectures](https://firebirdsql.org/manual/qsg25-appx-architectures.html)). Its default page cache is 2,048 pages per database in Superserver, versus 256 pages per connection in SuperClassic/Classic; the documented cache calculation is page count × page size for Superserver and additionally × connection count for the other two modes ([configuration reference](https://www.firebirdsql.org/docs/chunk/en/refdocs/fbconf/fbconf-firebird-cfg.html)). This makes Superserver the correct Firebird mode to test for this footprint-first case, while still measuring the whole process rather than equating page-cache configuration with RSS. The project publishes an official `firebirdsql/firebird` image, exposes port 3050, and persists databases under `/var/lib/firebird/data` ([official image page](https://firebirdsql.org/en/docker), [image repository](https://github.com/FirebirdSQL/firebird-docker/blob/master/README.md)).

It is a transactional RDBMS with its own language and protocol, not a PostgreSQL-compatible server. Firebird 5 has modern SQL features such as Boolean values, identity columns, and `RETURNING`, but exact syntax and behavior come from its own language reference ([language reference](https://firebirdsql.org/file/documentation/chunk/en/refdocs/fblangref50/firebird-50-language-reference.html), [`INSERT ... RETURNING`](https://firebirdsql.org/file/documentation/chunk/en/refdocs/fblangref50/fblangref50-dml-insert.html)).

Firebird provides logical `gbak` and physical/incremental `nbackup`; both can operate on an active database and capture the state at the beginning of the operation ([`gbak`](https://www.firebirdsql.org/file/documentation/html/en/firebirddocs/gbak/firebird-gbak.html), [`nbackup`](https://www.firebirdsql.org/file/documentation/html/en/firebirddocs/nbackup/firebird-nbackup.html)). It deserves a benchmark slot because its one-process Superserver model is plausible for low idle overhead, but no first-party comparable RSS evidence establishes that it beats tuned PostgreSQL.

### libSQL `sqld` — SQLite as a network service

`sqld` is the official server mode for libSQL. The project publishes an OCI image, listens for HTTP/WebSocket queries on port 8080 by default, and stores persistent data under `/var/lib/sqld` ([build/run guide](https://github.com/tursodatabase/libsql/blob/main/docs/BUILD-RUN.md), [Docker guide](https://github.com/tursodatabase/libsql/blob/main/docs/DOCKER.md)). The server supports standalone, primary, and replica modes in the image configuration ([Docker guide](https://github.com/tursodatabase/libsql/blob/main/docs/DOCKER.md)).

It solves "several containers need a network database" while retaining SQLite/libSQL semantics, not PostgreSQL semantics. The upstream explicitly states that libSQL inherits SQLite's single-writer limitation and that new feature development is focused on the separate beta Turso database ([libSQL README](https://github.com/tursodatabase/libsql/blob/main/README.md)). The latest published `libsql-server` release visible in the first-party release feed is `v0.24.32` from 2025-02-14, although the repository continues to receive updates ([release](https://github.com/tursodatabase/libsql/releases/tag/libsql-server-v0.24.32), [repository](https://github.com/tursodatabase/libsql)).

That makes `sqld` a benchmark candidate, not the default: it adds a standing container and network API while preserving the main concurrency caveat that motivates moving away from embedded SQLite. Validate driver/ORM support, authentication, backup/restore, and release cadence before adoption.

### MariaDB / MySQL — mature but not evidenced as smaller

MariaDB and MySQL are conventional client/server OLTP databases with broad driver support. Their default InnoDB buffer pool is 128 MB; both permit substantially smaller configured values, but that minimum does not establish whole-process idle RSS ([MariaDB variable](https://mariadb.com/docs/server/server-usage/storage-engines/innodb/innodb-system-variables), [MySQL variable](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html)). MySQL also documents per-connection and dynamically growing Performance Schema memory, reinforcing that one cache setting is not a total-memory figure ([memory use](https://dev.mysql.com/doc/refman/8.4/en/memory-use.html), [Performance Schema model](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-memory-model.html)).

Current MySQL cannot be considered an embedded alternative because `libmysqld` was removed in MySQL 8.0 ([8.0.1 release notes](https://dev.mysql.com/doc/relnotes/mysql/8.0/en/news-8-0-1.html)). MariaDB's official container includes `mariadb-backup`; physical backups require a prepare step before restore and an empty target data directory ([container backup](https://mariadb.com/docs/server/server-management/automated-mariadb-deployment-and-administration/docker-and-mariadb/container-backup-and-restoration)).

Include MariaDB, not both engines, in the initial benchmark to represent the MySQL family. Keep it only if measurement shows a material footprint win or a Workload specifically requires the MySQL dialect/ecosystem.

### H2/HSQLDB server mode — niche

H2 can expose a TCP/JDBC service and a PostgreSQL-wire server, while HSQLDB can run a network listener ([H2 tutorial](https://www.h2database.com/html/tutorial.html), [HSQLDB deployment](https://www.hsqldb.org/doc/guide/deployment-chapt.html)). Their server mode necessarily adds a JVM process. Without an already-running JVM and a first-party OCI image, they are poor default container candidates for a rootless Podman Host whose top criterion is total idle resources.

H2's PG wire support is useful for selected PostgreSQL clients, but compatibility mode is a documented set of behavior changes, not a promise that arbitrary PostgreSQL applications work unchanged ([H2 features](https://www.h2database.com/html/features.html)). Benchmark only if the target Workload is already Java/JDBC and can embed the engine instead.

---

## Attractive names that are mismatched or heavier

### Experimental lightweight PostgreSQL-subset servers

No verified standalone project currently combines meaningful PostgreSQL compatibility, production credibility, and a demonstrated tiny footprint. PGlite is the credible embedded option, but its single-user execution model is not a normal network PostgreSQL server. H2 exposes a PG server and PostgreSQL compatibility mode, but remains a Java/H2 engine with selected compatibility behavior rather than PostgreSQL ([H2 server tools](https://www.h2database.com/html/tutorial.html), [compatibility mode](https://www.h2database.com/html/features.html)).

`pgmicro` is a particularly relevant emerging example: it parses PostgreSQL syntax into a SQLite-compatible Turso storage engine and includes a PG-wire server, but its own README calls the project heavily experimental, makes no stability/compatibility/completeness guarantees, and describes the server as “very simple” ([official repository](https://github.com/rstkit/pgmicro)). It belongs on the watch list or in a throwaway prototype, not in the production benchmark shortlist.

### PostgreSQL-wire analytical/time-series systems

QuestDB accepts PostgreSQL-wire clients, but its SQL omits `DELETE`, `HAVING`, `OFFSET`, `DISTINCT ON`, `ON CONFLICT`, and other features because of its column-oriented, time-ordered model; its docs recommend PGWire primarily for queries and a separate protocol for ingestion ([PGWire overview](https://questdb.com/docs/query/pgwire/overview)). It is not a general OLTP PostgreSQL substitute.

Materialize, RisingWave, GreptimeDB, and similar systems may expose PostgreSQL wire protocols or SQL subsets, but their product purpose is streaming, analytical, or distributed data processing rather than minimizing a tiny single-Host OLTP store. Wire protocol support should not put them on the footprint shortlist without a matching workload.

### Distributed PostgreSQL-compatible systems

CockroachDB and YugabyteDB sound attractive because they speak PostgreSQL-like SQL, but their first-party production guidance is decisively outside this Host's small-footprint goal:

- CockroachDB strongly recommends at least 4 vCPUs per node, recommends 4 GiB RAM per vCPU, and calls 2 GiB per vCPU suitable only for testing ([production settings](https://www.cockroachlabs.com/docs/stable/recommended-production-settings)).
- YugabyteDB's deployment checklist lists 16+ cores and 64 GB+ RAM for typical YSQL production sizing; even its Kubernetes prerequisites list 15 GB RAM and 100 GB SSD minimum per node ([deployment checklist](https://docs.yugabyte.com/stable/deploy/checklist/), [hardware requirements](https://docs.yugabyte.com/stable/yugabyte-platform/prepare/server-nodes-hardware/)).

These are production recommendations, not idle measurements, but they are enough to reject both for a single small Propraetor Host: their distribution, replication, sharding, and background maintenance solve a different problem.

### New SQLite-compatible Turso engine

The Turso team distinguishes its newer Rust rewrite from libSQL and labels it beta while recommending that new projects evaluate it ([libSQL README](https://github.com/tursodatabase/libsql/blob/main/README.md)). Its MVCC mode supports optimistic `BEGIN CONCURRENT`, where conflicting commits must be retried ([transaction docs](https://docs.turso.tech/sql-reference/statements/transactions), [concurrent writes](https://docs.turso.tech/tursodb/concurrent-writes)). It is promising, but beta status and a changing interface make it a watch-list item rather than the durable default. Propraetor's pre-stability permits a later clean switch without carrying compatibility shims.

---

## Deployment, durability, and lifecycle implications

### Embedded database

- One application container owns the database file and is the only component allowed to open it directly.
- The file, journal/WAL, and temporary files must reside in a Workload-owned Host Volume directory writable by the Platform User.
- Backup is a Workload operation: use the engine's online backup API/tool or stop the application before a filesystem copy. A raw copy of only the main file while it is live is not a generic backup strategy.
- Application restart also restarts the database engine. There is no independent DB health unit, network policy, or rolling restart.
- Horizontal application replication cannot share a local embedded file safely by assumption; move to a network server or engine-specific replication design first.

### Network database container

- Keep the port private on the Propraetor Service Network; do not publish it on the Host.
- Persist the official image's data directory under one clearly owned Workload directory on the Host Volume.
- Add explicit readiness ordering between application and DB Quadlets; do not treat container start as database readiness.
- Define backup artifacts outside the live data directory and test restoration onto an empty directory.
- A database shared by multiple Workloads needs an owner and lifecycle rule: removing one Workload from the Environment (Orphan Reap) must not delete another Workload's database. The current Workload-owned model should not silently create shared mutable infrastructure.
- Park preserves the Host Volume but removes the Host. Apply must remount the volume before Workload Setup; database crash recovery must tolerate the prior Host disappearing without a clean shutdown.

The Host Volume is currently 1 GiB and also carries Propraetor/Workload durable bytes ([ADR-0009](../adr/0009-host-volume.md)). Measure initial database files, WAL/journal steady-state, backup duplication, and restore scratch space; resize before relying on backups that cannot coexist with live data.

---

## Recommendation tiers by likely workload

### Tier 1 — one small web Workload, one process, modest writes

Use **SQLite in WAL mode**, embedded in the application. Keep transactions short, configure a busy timeout/retry policy, explicitly enable foreign-key enforcement for each connection as SQLite requires, and back up through the Online Backup API ([foreign keys](https://sqlite.org/foreignkeys.html), [Backup API](https://sqlite.org/backup.html)). This gives the cleanest likely minimum-footprint architecture.

### Tier 2 — JavaScript/TypeScript application needs PostgreSQL SQL locally

Prototype **PGlite** only if one process owns the database and its `fsync`-off durability posture is acceptable or can be changed and verified. If committed-data survival across abrupt Host loss matters, prefer tuned PostgreSQL until a crash test proves the exact PGlite configuration.

### Tier 3 — several application processes/Workloads or meaningful concurrent writes

Use **tuned PostgreSQL**. Cap connections to demonstrated need, keep per-operation memory conservative, and retain durable WAL settings. It maximizes correctness/tooling and avoids spending engineering time adapting to a niche dialect merely to chase an unmeasured resource saving.

### Tier 4 — network SQL required, PostgreSQL semantics not required, footprint experiment justified

Benchmark **Firebird Superserver**, **`sqld` standalone**, **MariaDB**, and tuned PostgreSQL. Firebird is the strongest alternate conventional RDBMS; `sqld` is the strongest SQLite-lineage network option. Select only after schema, concurrency, backup, and driver acceptance tests pass.

### Tier 5 — analytical, append/bulk-oriented local data

Use **DuckDB** as an embedded analytical engine, not as the application's general OLTP source of truth.

---

## Concrete validation experiment

### Goal

Measure the same durable schema and low-load behavior on the actual Ubuntu 26.04 Host, rootless Podman, ext4 Host Volume, CPU architecture, and cgroup v2 environment. Compare architectures, not marketing:

1. SQLite embedded in a minimal representative application.
2. Tuned PostgreSQL official image.
3. Firebird official Superserver image.
4. libSQL `sqld` official image in standalone mode.
5. MariaDB official image with conservative InnoDB settings.
6. Optional: PGlite inside the same representative JS application, if JS is a likely Workload runtime.

DuckDB gets a separate analytical experiment, not an OLTP score.

### Pin and record

- Exact image digest or package/library version, architecture, Podman version, kernel, filesystem/mount options, and Host size.
- Complete engine configuration and cgroup limits.
- Pulled image compressed and unpacked size; initialized data-directory size.
- Schema and driver commit, random seed, and timestamps.

Do not use `latest` in recorded results.

### Shared schema and workload

Use a deliberately ordinary relational schema supported by all candidates: accounts/users, projects, tasks, tags, and a join table; primary/foreign keys, unique constraints, one secondary index, timestamps, short text, Boolean, and integer IDs. Maintain engine-specific DDL files rather than a compatibility abstraction.

Run five phases, with five fresh repetitions per candidate:

1. **Cold initialized:** start, pass a real SQL readiness query, then wait 10 minutes with no clients.
2. **Seed:** insert 10,000 parent rows and 100,000 child rows in fixed-size transactions.
3. **Low load:** for 15 minutes, issue 1 request/second with a fixed mix: 70% indexed reads, 20% inserts, 8% updates, 2% deletes; use 4 client connections/threads.
4. **Quiescent after load:** disconnect clients and observe 15 minutes to expose retained caches and background work.
5. **Crash/restore:** kill the application/DB unit without graceful shutdown during writes, restart, run integrity/constraint checks, then restore the latest backup into a fresh empty directory and compare row counts plus deterministic checksums.

Add a second concurrency case with 16 clients only if a real likely Workload needs it. The purpose is fit at low load, not peak TPS.

### Measurements

Collect at 1-second intervals and report median plus p95 across repetitions:

- cgroup v2 `memory.current`, `memory.peak`, and `memory.stat` split into anonymous/file cache where available;
- cgroup `cpu.stat` usage deltas and throttling, including the idle/quiescent phases;
- process count, threads, and open file descriptors;
- data directory, journal/WAL, logs, and backup bytes separately;
- image store bytes by digest;
- startup-to-ready time and first-query latency after start;
- transaction errors/retries, lock waits/busy errors, and background writes while nominally idle;
- integrity result, acknowledged-transaction loss after forced crash, backup duration, restore duration, and restored checksum.

For embedded engines, measure the **whole application cgroup** and subtract the same application built with a no-database stub only as a secondary diagnostic. The primary comparison remains total deployable Workload footprint; otherwise embedded memory would be hidden inside the app.

### Acceptance gates

A candidate advances only if:

1. all required schema and transactions work without semantic emulation;
2. forced-crash restart passes integrity checks and meets the chosen acknowledged-write durability policy;
3. backup restores successfully in an automated clean-room test;
4. low-load lock/retry behavior is acceptable;
5. its total footprint is materially lower than tuned PostgreSQL **or** it removes enough operational surface to justify a smaller numerical win.

Publish raw samples and the benchmark harness beside the eventual decision. Until those measurements exist, describe SQLite as the architectural footprint leader and PostgreSQL as the network correctness baseline—not as quantified RAM winners.

---

## Primary sources

- PostgreSQL: [resource consumption](https://www.postgresql.org/docs/current/runtime-config-resource.html), [connections](https://www.postgresql.org/docs/current/runtime-config-connection.html), [kernel resources](https://www.postgresql.org/docs/current/kernel-resources.html), [WAL reliability](https://www.postgresql.org/docs/current/wal-reliability.html), [backup](https://www.postgresql.org/docs/current/backup.html), [`pg_dump`](https://www.postgresql.org/docs/current/app-pgdump.html), [official image](https://hub.docker.com/_/postgres)
- SQLite: [serverless](https://sqlite.org/serverless.html), [appropriate uses](https://sqlite.org/whentouse.html), [WAL](https://sqlite.org/wal.html), [Backup API](https://sqlite.org/backup.html), [SQL language](https://www.sqlite.org/lang.html), [network-filesystem caveats](https://www.sqlite.org/useovernet.html)
- libSQL / `sqld`: [repository README](https://github.com/tursodatabase/libsql/blob/main/README.md), [`sqld` README](https://github.com/tursodatabase/libsql/blob/main/libsql-server/README.md), [build/run](https://github.com/tursodatabase/libsql/blob/main/docs/BUILD-RUN.md), [Docker](https://github.com/tursodatabase/libsql/blob/main/docs/DOCKER.md), [releases](https://github.com/tursodatabase/libsql/releases)
- PGlite: [repository](https://github.com/electric-sql/pglite/), [API](https://github.com/electric-sql/pglite/blob/main/docs/docs/api.md), [single-user implementation](https://github.com/electric-sql/pglite/blob/main/packages/pglite/src/pglite.ts), [consistency issue](https://github.com/electric-sql/pglite/issues/323)
- DuckDB: [concurrency](https://duckdb.org/docs/stable/connect/concurrency), [transactions](https://duckdb.org/docs/stable/sql/statements/transactions)
- Firebird: [official image](https://firebirdsql.org/en/docker), [image source](https://github.com/FirebirdSQL/firebird-docker), [architectures](https://firebirdsql.org/manual/qsg25-appx-architectures.html), [cache configuration](https://www.firebirdsql.org/docs/chunk/en/refdocs/fbconf/fbconf-firebird-cfg.html), [language reference](https://firebirdsql.org/file/documentation/chunk/en/refdocs/fblangref50/firebird-50-language-reference.html), [`gbak`](https://www.firebirdsql.org/file/documentation/html/en/firebirddocs/gbak/firebird-gbak.html), [`nbackup`](https://www.firebirdsql.org/file/documentation/html/en/firebirddocs/nbackup/firebird-nbackup.html)
- MariaDB: [memory allocation](https://mariadb.com/docs/server/ha-and-performance/mariadb-memory-allocation), [InnoDB variables](https://mariadb.com/docs/server/server-usage/storage-engines/innodb/innodb-system-variables), [containers](https://mariadb.com/docs/server/server-management/automated-mariadb-deployment-and-administration/docker-and-mariadb), [container backup](https://mariadb.com/docs/server/server-management/automated-mariadb-deployment-and-administration/docker-and-mariadb/container-backup-and-restoration)
- MySQL: [memory use](https://dev.mysql.com/doc/refman/8.4/en/memory-use.html), [InnoDB variables](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html), [`libmysqld` removal](https://dev.mysql.com/doc/relnotes/mysql/8.0/en/news-8-0-1.html)
- H2: [features and deployment modes](https://www.h2database.com/html/features.html), [tutorial/server tools](https://www.h2database.com/html/tutorial.html)
- pgmicro: [official repository and status](https://github.com/rstkit/pgmicro)
- HSQLDB: [system management](https://www.hsqldb.org/doc/guide/management-chapt.html), [deployment](https://www.hsqldb.org/doc/guide/deployment-chapt.html)
- QuestDB: [PGWire and SQL differences](https://questdb.com/docs/query/pgwire/overview)
- CockroachDB: [production settings](https://www.cockroachlabs.com/docs/stable/recommended-production-settings)
- YugabyteDB: [deployment checklist](https://docs.yugabyte.com/stable/deploy/checklist/), [hardware requirements](https://docs.yugabyte.com/stable/yugabyte-platform/prepare/server-nodes-hardware/)
- Turso database: [transactions](https://docs.turso.tech/sql-reference/statements/transactions), [concurrent writes](https://docs.turso.tech/tursodb/concurrent-writes)
