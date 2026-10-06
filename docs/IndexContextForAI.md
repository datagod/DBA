# Index Context for AI Recommendations

## Purpose

This document describes the information an AI (or a human DBA) needs in order to make **sound index recommendations** against a SQL Server database. It starts from what the Performance Tuning Framework already captures in `IndexAnalysis` / `ShowIndexAnalysisGrid`, then lists the gaps that still force guesswork, and proposes how to package the richer context.

> **Guiding principle:** Usage counters alone are not enough. An AI needs the **workload** (which queries hurt), **selectivity** (whether a key is useful), **coverage window** (how long the counters have been collecting), and **dependencies** (what would break if an index were dropped).

Related scripts today:

- `PerformanceTuningFramework/IndexAnalysis.sql` — persistence table
- `PerformanceTuningFramework/AnalyzeIndexes.sql` — capture
- `PerformanceTuningFramework/ShowIndexUsageReport.sql` — fixed-width text report
- `PerformanceTuningFramework/ShowIndexAnalysisGrid.sql` — SSMS Results-grid summary + detail

A future companion procedure (working name: `ExportIndexContextForAI`) would collect the items below and return one JSON document per table (or per database) suitable for pasting into an AI prompt.

---

## What IndexAnalysis already provides

For each index in a capture run (`AnalysisRunID`), the framework already records:

| Category | Columns / facts |
|----------|-----------------|
| Identity | Server, database, schema, table, index name, ObjectID, IndexID |
| Shape | Index type, key columns, included columns, filtered flag + filter definition, unique / PK, fill factor, compression, disabled |
| Usage | User seeks / scans / lookups / updates, total reads, read/write ratio |
| Recency | Last user seek / scan / lookup / update |
| Size | Record count, SizeMB |
| Provenance | CaptureDate, HasUsageStats, SortBy used at analyze time |

`ShowIndexAnalysisGrid` surfaces this as a one-row summary plus typed detail rows (filters, `@SortBy`, `@TopN`, unused / write-heavy flags). That is excellent for **human triage in SSMS**. It is still incomplete for an AI that must **recommend create / drop / alter** decisions safely.

---

## Gaps that matter most (priority order)

### 1. How long the usage stats cover

Usage counters in `sys.dm_db_index_usage_stats` reset on every SQL Server restart (and after some failover scenarios).

**Add:**

- `sqlserver_start_time` (from `sys.dm_os_sys_info`)
- Hours (or days) of uptime at capture time
- Optional: last successful Agent job / last known good capture window if you track it

Without this, "0 reads" after two days of uptime means something very different from "0 reads" after six months. An AI will otherwise recommend dropping indexes that only run at month-end.

### 2. The workload itself (Query Store, with plan-cache fallback)

This is the single biggest improvement. Counters say *that* an index was used; the workload says *why* and *whether another shape would help more*.

**Add per table (top N by cost):**

- Query text (truncated / fingerprint + sample)
- Logical reads, CPU, duration, execution count (Query Store runtime stats preferred)
- Plan operators of interest: table/index scans, key lookups, hash/sort spills signals, implicit conversions
- Existing missing-index hints embedded in the plan (when present)

**Sources:**

- Query Store: `sys.query_store_query`, `sys.query_store_plan`, `sys.query_store_runtime_stats`, related views
- Fallback when Query Store is off: `sys.dm_exec_query_stats` + `sys.dm_exec_sql_text` + `sys.dm_exec_query_plan` (volatile; loses history on restart)

### 3. SQL Server's own missing-index suggestions

**Add from** `sys.dm_db_missing_index_details` / `groups` / `group_stats` (and on SQL Server 2019+, `sys.dm_db_missing_index_group_stats_query` when available):

- Equality columns, inequality columns, included columns
- Unique compiles / user seeks, average user impact, last user seek
- Estimated impact score
- Tied query text when the query-level DMV exists

Treat these as **hints**, not orders. They often over-include columns and ignore write cost. An AI still needs them as candidate shapes to evaluate against the real workload.

### 4. Column details for key and included columns

**Add for each listed key / include column:**

- Data type, max length / precision / scale
- Nullability
- Whether computed, identity, or sparse
- Estimated average length when available

**Derive:**

- Total index key width in bytes (SQL Server limits: 900 bytes clustered key historically; 1,700 bytes for nonclustered keys on modern versions — document the instance's limit)
- Whether a proposed key would exceed the limit

### 5. Statistics and selectivity

**Add for each index's supporting statistics** (`sys.stats`, `sys.dm_db_stats_properties`, histogram when cheap):

- Last updated, rows sampled vs rows in table, modification counter since last update
- Density / distinct-count signal for the **leading** key column (and optionally the next key)
- Stale-stats flag (heuristic: high modifications relative to row count, or never updated)

This is how an AI distinguishes a selective ID from a low-cardinality `province_id`-style column — the same lesson already encoded in `RecommendClusteredIndex`.

### 6. Lower-level operational counters

From `sys.dm_db_index_operational_stats`:

- Leaf-level inserts / updates / deletes
- Range scans vs singleton lookups
- Row and page lock waits (count + time)
- Page latch waits
- Lock escalations
- Forwarded fetches (heaps)

These expose **write and contention cost** that usage stats hide. An index with modest seeks but huge update + lock-wait cost is a poor create/survive candidate.

### 7. Physical shape (LIMITED mode)

From `sys.dm_db_index_physical_stats` (`LIMITED` by default — avoid `DETAILED` on large DBs unless requested):

- Page count, avg fragmentation, index depth / level count
- Forwarded record count on heaps
- Optional: ghost record count

Useful for rebuild/reorganize advice and for explaining why a "good" index still scans slowly (deep / fragmented).

### 8. Constraints and dependencies (do-not-drop signals)

**Add:**

- Whether the index backs a primary key, unique constraint, or unique index enforcing uniqueness
- Foreign keys **on** the table and **referencing** the table; which FK columns lack a supporting index
- Objects with an explicit index hint (`WITH (INDEX(...))`) that name this index (scan modules / plans carefully; imperfect but valuable)
- Query Store forced plans or plan guides that reference the index / plan shape

Dropping a dependency-backed index breaks integrity or code. The AI must see those flags before any DROP recommendation.

### 9. Table-level context

**Add per table:**

- Clustered index (or heap) definition — nonclustered indexes include the clustering key
- Count of indexes and total index size vs table size
- Partitioning scheme / function (if any)
- Compression per partition
- Special features: memory-optimized, temporal, CDC, replication article, columnstore present

### 10. Server / database context

**Add once per export:**

- Edition, product version, compatibility level
- Max server memory, Cost Threshold for Parallelism, MaxDOP (instance and database scoped where relevant)
- Whether online rebuilds / compression / columnar features are even available on this edition

### 11. Trends across capture runs

Keep multiple `AnalysisRunID` snapshots and compute:

- Reads / writes **per day** (or per hour of uptime) between captures
- Indexes that flipped from unused → used (or the reverse)
- Size growth

Running totals since restart are noisy; rates across comparable windows are what an AI should rank on.

---

## Recommended packaging for an AI

Prefer **one JSON document per table** (nested), not a single wide grid of all indexes in the database. Models handle nested context more reliably when related facts stay together.

Suggested top-level shape:

```json
{
  "server": { "name": "", "edition": "", "version": "", "startTime": "", "uptimeHours": 0 },
  "database": { "name": "", "compatibilityLevel": 0, "queryStoreOn": true },
  "table": {
    "schema": "",
    "name": "",
    "rowCount": 0,
    "sizeMB": 0,
    "isHeap": false,
    "clusteredKey": "",
    "indexCount": 0,
    "features": []
  },
  "indexes": [
    {
      "name": "",
      "type": "",
      "keys": [],
      "includes": [],
      "usage": {},
      "operational": {},
      "physical": {},
      "stats": {},
      "dependencies": {}
    }
  ],
  "missingIndexSuggestions": [],
  "topQueries": []
}
```

Also emit a short **human summary block** (markdown) above the JSON for DBA review: uptime caveat, top unused write-heavy indexes, top missing-index impact, and Query Store coverage status.

### Practical defaults for the exporter

| Parameter idea | Default intent |
|----------------|----------------|
| `@TargetDatabase` | Required |
| `@SchemaFilter` / `@TableFilter` | Optional; support focusing one hot table |
| `@TopQueriesPerTable` | Small (e.g. 10–20) to keep tokens under control |
| `@IncludePhysicalStats` | Off or `LIMITED` only |
| `@IncludeQueryStore` | On when QS is enabled; else plan-cache fallback with a loud warning |
| `@AnalysisRunID` | Latest IndexAnalysis run, or null to live-query DMVs only |
| Output | `nvarchar(max)` JSON, or write to a table / file for large DBs |

### Safety rules the AI prompt should state

Bake these into any prompt that consumes the export:

1. Never recommend dropping an index that enforces a PK/unique constraint or that FK/hint/forced-plan dependencies reference, unless the recommendation also remediates that dependency.
2. Treat missing-index DMVs as candidates; prefer shapes proven by Query Store queries.
3. If uptime is short (e.g. under 7 days), say so and bias toward **observe / re-capture**, not DROP.
4. Prefer consolidating overlapping indexes over adding a near-duplicate for every missing-index row.
5. Account for write cost (updates, operational waits) not only read seeks.
6. Respect key-width and edition limits.

---

## Suggested build order

1. **Docs only (this file)** — shared vocabulary for humans and for the future proc.
2. **`ExportIndexContextForAI` v1** — items 1–5 (uptime, Query Store / plan cache top queries, missing indexes, column metadata, stats/selectivity) + existing IndexAnalysis fields, JSON per table.
3. **v2** — operational stats, LIMITED physical stats, constraint/FK/hint dependency flags.
4. **v3** — multi-run trends and richer plan-operator extraction.

Until the exporter exists, a practical workflow is:

1. `EXEC dbo.AnalyzeIndexes @TargetDatabase = N'YourDatabase';`
2. `EXEC dbo.ShowIndexAnalysisGrid ...` for triage.
3. Manually gather Query Store top queries and missing-index DMVs for the hot tables.
4. Feed table-scoped JSON (even hand-built) into the AI with the safety rules above.

---

## Related reading in this repo

- [Performance Tuning Framework](../PerformanceTuningFramework/PerformanceTuningFramework.md)
- [SQL Server multi-workload performance strategy](sql_server_multi_workload_performance_strategy.md)
- [`RecommendClusteredIndex.sql`](../PerformanceTuningFramework/RecommendClusteredIndex.sql) — uniqueness, justification, reject low-cardinality keys
- [`RecommendIndexes.sql`](../PerformanceTuningFramework/RecommendIndexes.sql) — duplicate / redundant index logic
