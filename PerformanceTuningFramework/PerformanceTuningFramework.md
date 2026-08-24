# Performance Tuning Framework

SQL Server scripts and utilities for database performance analysis and tuning. Deploy scripts to a single tool database and analyze any target database on the same instance.

## Overview

This framework lives in the `PerformanceTuningFramework` folder of the DBA repository. Each script is designed to be version-aware where possible and to produce output that is easy to read in SSMS or an Azure DevOps wiki.

Procedures run from one tool database and read metadata from a target database passed as a parameter. Index usage results are stored in `IndexAnalysis` for later querying; Query Store reporting is text output only. `ShowQueryStoreWorkloadReport` scans all eligible databases on the instance. Server-side performance traces are stored in `PerformanceTraceResults` when stopped.

## Tables

### PerformanceTraceResults

File: `PerformanceTraceResults.sql`

Persistent storage for imported server-side trace events. Also creates `PerformanceTraceControl` to track running and completed traces.

- `PerformanceTraceControl` stores trace identity, file path, status, filters, and import metadata
- `PerformanceTraceResults` stores query text, reads, writes, duration, CPU, login, hostname, start time, end time, and related event data
- Trace results are imported when `StopPerformanceTrace` is executed

Deployment:

```sql
-- Run PerformanceTraceResults.sql in the tool database
```

### DatabasePerformanceRun / Metric / Finding

File: `DatabasePerformanceAnalysis.sql`

Persistent storage for database performance diagnostics captured by `ExamineDatabasePerformance`.

- `DatabasePerformanceRun` stores one row per examination with server, database, and capture parameters
- `DatabasePerformanceMetric` stores comparable scalar metrics (server CPU/memory, database settings, summary counts)
- `DatabasePerformanceFinding` stores ranked findings (fragmentation, missing indexes, stale statistics, top queries, waits, file I/O, VLF, blocking)

Deployment:

```sql
-- Run DatabasePerformanceAnalysis.sql in the tool database
```

### IndexAnalysis

File: `IndexAnalysis.sql`

Persistent storage for index usage analysis results. Deploy to the tool database before running `AnalyzeIndexes` or `ShowIndexUsageReport`.

- One row per index per execution
- Grouped by `AnalysisRunID` and `CaptureDate` for each run
- Stores target database name, schema, table, index identity, usage counts, record count, size, last-used timestamps, and run filters
- Stores index definition metadata: key columns with sort order (`KeyColumns`), included columns (`IncludedColumns`), filtered-index predicate (`FilterDefinition`), partition compression (`CompressionDesc`), and flags for unique, primary key, and fill factor
- Indexed on `AnalysisRunID` and `(DatabaseName, CaptureDate)`

Deployment:

```sql
-- Run IndexAnalysis.sql in the tool database
```

## Scripts

### ExamineDatabasePerformance

File: `ExamineDatabasePerformance.sql`

Stored procedure that examines a target database for performance issues using DMVs and stores comparable results for side-by-side analysis.

- Captures server hardware and configuration (CPU count, cores per socket, memory, MAXDOP, PLE, buffer cache hit ratio, worker threads)
- Captures database configuration (recovery model, compatibility level, auto-stats settings, RCSI, Query Store state, file sizes, VLF count, last CHECKDB)
- Reports file I/O latency from `sys.dm_io_virtual_file_stats`
- Reports index fragmentation from `sys.dm_db_index_physical_stats`
- Reports missing indexes from `sys.dm_db_missing_index_*`
- Reports unused indexes from `sys.dm_db_index_usage_stats`
- Reports stale statistics from `sys.dm_db_stats_properties`
- Reports top instance wait types from `sys.dm_os_wait_stats`
- Reports top queries by CPU, duration, and reads from `sys.dm_exec_query_stats`
- Reports blocking sessions and open transactions at capture time
- Returns three result sets (summary, metrics, findings) and optionally persists to `DatabasePerformanceRun`, `DatabasePerformanceMetric`, and `DatabasePerformanceFinding`

Deployment:

```sql
-- 1. Run DatabasePerformanceAnalysis.sql in the tool database
-- 2. Run ExamineDatabasePerformance.sql in the tool database
DECLARE @FastRun uniqueidentifier, @SlowRun uniqueidentifier
EXEC dbo.ExamineDatabasePerformance @TargetDatabase = N'FastDb', @AnalysisRunID = @FastRun OUTPUT
EXEC dbo.ExamineDatabasePerformance @TargetDatabase = N'SlowDb', @AnalysisRunID = @SlowRun OUTPUT
EXEC dbo.CompareDatabasePerformance @AnalysisRunID_A = @FastRun, @AnalysisRunID_B = @SlowRun
```

Parameters:

- `@TargetDatabase` — database to examine (default: current database)
- `@SchemaFilter` — schema name filter (default `%`)
- `@TableFilter` — table name filter (default `%`)
- `@TopN` — number of ranked rows kept per finding category (default `25`)
- `@MinFragmentationPct` — minimum fragmentation percent to include (default `10`)
- `@MinPageCount` — minimum page count for fragmentation findings (default `1000`)
- `@PersistResults` — store results in `DatabasePerformance*` tables (default `1`)
- `@ReturnResultSets` — return summary/metrics/findings result sets (default `1`)
- `@AnalysisRunID` — OUTPUT unique identifier for the capture run

Note: wait stats and plan-cache queries are instance-scoped; when comparing two databases on the same server, focus on database metrics, fragmentation, statistics, missing/unused indexes, and file I/O differences.

### CompareDatabasePerformance

File: `CompareDatabasePerformance.sql`

Stored procedure that compares two `ExamineDatabasePerformance` capture runs.

- Returns run header information (database names, capture dates, servers)
- Returns metric differences with numeric deltas
- Returns finding-count differences by category

Deployment:

```sql
-- Run after DatabasePerformanceAnalysis.sql and ExamineDatabasePerformance.sql
EXEC dbo.CompareDatabasePerformance @AnalysisRunID_A = @Run1, @AnalysisRunID_B = @Run2
```

### CheckForHeaps

File: `CheckForHeaps.sql`

Lightweight stored procedure that scans a target database for heap tables using catalog views only.

- Finds user tables without a clustered rowstore or columnstore index
- Reports row count and size from `sys.partitions` and `sys.allocation_units`
- Reports nonclustered index count and primary-key presence from `sys.indexes`
- Optionally includes heap scan/update counts from `sys.dm_db_index_usage_stats`
- Does not call `sys.dm_db_index_physical_stats` or missing-index DMVs

Deployment:

```sql
-- Run CheckForHeaps.sql in the tool database
EXEC dbo.CheckForHeaps @TargetDatabase = N'YourDatabase'
EXEC dbo.CheckForHeaps @TargetDatabase = N'YourDatabase', @MinRows = 1000, @SortBy = 'ROWS'
```

Parameters:

- `@TargetDatabase` — database to examine (default: current database)
- `@SchemaFilter` — schema name filter (default `%`)
- `@TableFilter` — table name filter (default `%`)
- `@MinRows` — minimum row count to include (default `0`)
- `@SortBy` — `SIZE`, `ROWS`, `NC`, `SCANS`, or `OBJECT` (default `SIZE`)
- `@ReturnSummary` — return one-row summary result set (default `1`)

Note: for fragmentation, missing-index signals, and clustered-index DDL recommendations, use `ShowHeaps`.

### ShowHeaps

File: `ShowHeaps.sql`

Stored procedure that finds user-table heaps in a target database, analyzes DMV usage patterns, and recommends a clustered index for each heap. Requires SQL Server 2008 (10.x) or later on the instance and compatibility level 100 or higher on the target database. A SQL Server 2022 instance examining a compatibility level 100 database is supported; catalog and index-type logic follow the target compatibility level, while `ONLINE` index DDL follows the host instance edition.

- Identifies tables without a clustered rowstore or columnstore index
- Reports heap usage from `sys.dm_db_index_usage_stats` (seeks, scans, lookups, updates)
- Reports record counts from `sys.partitions` (always populated, including under LIMITED mode)
- Reports forwarded records, fragmentation, size, and nonclustered index count from `sys.dm_db_index_physical_stats`
- Ranks missing-index signals from `sys.dm_db_missing_index_*` per heap
- Considers existing nonclustered primary keys, most-used nonclustered indexes, identity columns, and narrow-key heuristics
- Returns a recommendation score, rationale, `SuggestedClusteredDdl`, and optional `SuggestedNonClusteredDdl` when missing-index columns differ from the clustered recommendation

Deployment:

```sql
-- Run ShowHeaps.sql in the tool database
EXEC dbo.ShowHeaps @TargetDatabase = N'YourDatabase'
EXEC dbo.ShowHeaps @TargetDatabase = N'YourDatabase', @SortBy = 'SCANS', @MinPageCount = 1000
EXEC dbo.ShowHeaps @TargetDatabase = N'YourDatabase', @ScanMode = 'SAMPLED'
```

Parameters:

- `@TargetDatabase` — database to examine (default: current database)
- `@SchemaFilter` — schema name filter (default `%`)
- `@TableFilter` — table name filter (default `%`)
- `@MinPageCount` — minimum heap page count to include (default `100`)
- `@TopN` — maximum heap rows returned in the detail result set (default `100`)
- `@SortBy` — `SCORE`, `SIZE`, `ROWS`, `SCANS`, `UPDATES`, `IMPACT`, or `OBJECT` (default `SCORE`)
- `@ScanMode` — `LIMITED`, `SAMPLED`, or `DETAILED` for `sys.dm_db_index_physical_stats` (default `LIMITED`)
- `@ReturnResultSets` — return summary and detail result sets (default `1`)

Recommendation priority:

1. Nonclustered primary key columns (cluster the PK)
2. High-impact missing-index equality/inequality columns
3. Key columns from the most-used nonclustered index
4. Lower-impact missing-index columns
5. Identity column
6. Heuristic narrow key column

Note: `LIMITED` does not scan heap data pages, so forwarded-record and fragmentation numbers stay empty unless `@ScanMode` is `SAMPLED` or `DETAILED`. Record counts always come from `sys.partitions`. Usage statistics reset when the SQL Server instance restarts. When the host instance is newer than the target compatibility level (for example SQL Server 2022 with compatibility level 100), heap detection and recommendations honor the target database mode. `ONLINE = ON` appears in suggested DDL only on Enterprise/Developer host editions. Test generated DDL in a non-production window; existing nonclustered indexes are rebuilt when a clustered index is created.


### ShowTableInfo

File: `ShowTableInfo.sql`

Stored procedure that examines one user table in a target database and returns detailed catalog and DMV information. Requires SQL Server 2008 (10.x) or later on the instance and compatibility level 100 or higher on the target database.

- Reports table identity (create/modify dates, lock escalation, filegroups, temporal and memory-optimized flags when the instance supports them)
- Reports row count, reserved/used/data/index/unused space, pages, and partition count
- Identifies HEAP vs CLUSTERED vs CLUSTERED COLUMNSTORE and clustered key columns
- Lists every index with keys, includes, filter, fill factor, compression, size, usage, and LIMITED-mode fragmentation
- Lists columns, constraints, statistics, triggers, and missing-index suggestions for that table only
- Does not persist results to a table

Deployment:

```sql
-- Run ShowTableInfo.sql in the tool database
EXEC dbo.ShowTableInfo @TargetDatabase = N'YourDatabase', @TableName = N'YourTable'
EXEC dbo.ShowTableInfo @TargetDatabase = N'YourDatabase', @TableName = N'Sales.Orders'
```

Parameters:

- `@TargetDatabase` — database to examine (default: current database)
- `@TableName` — table name, or `schema.table`
- `@SchemaName` — schema when `@TableName` has no qualifier (default `dbo`)

Note: fragmentation is collected with `sys.dm_db_index_physical_stats` in LIMITED mode for the specified table only.

### AnalyzeIndexes

File: `AnalyzeIndexes.sql`

Stored procedure that captures index usage statistics from a target database and writes the results to `IndexAnalysis`.

- Reads catalog metadata from the target database via three-part names
- Joins instance-wide `sys.dm_db_index_usage_stats` filtered to the target database
- Captures key and included column lists, ASC/DESC sort order, filter definitions, compression, uniqueness, primary-key status, and fill factor from target-database catalog views
- Inserts one row per index into `IndexAnalysis`
- Returns a single-row summary with `AnalysisRunID`, counts, and run parameters

Deployment:

```sql
-- 1. Run IndexAnalysis.sql in the tool database
-- 2. Run AnalyzeIndexes.sql in the tool database
DECLARE @RunID uniqueidentifier
EXEC dbo.AnalyzeIndexes @TargetDatabase = N'YourDatabase', @AnalysisRunID = @RunID OUTPUT
```

Parameters:

- `@TargetDatabase` — database to analyze (default: current database)
- `@SchemaFilter` — schema name filter (default `%`)
- `@TableFilter` — table name filter (default `%`)
- `@SortBy` — `READS`, `WRITES`, `SIZE`, `OBJECT`, or `LAST_USE` (default `READS`)
- `@AnalysisRunID` — OUTPUT unique identifier for the capture run

### ShowIndexUsageReport

File: `ShowIndexUsageReport.sql`

Stored procedure that reads captured data from `IndexAnalysis` and returns a fixed-width, text-based report suitable for on-screen review.

- Does not capture new data; run `AnalyzeIndexes` first
- Defaults to the latest `AnalysisRunID` for the target database
- Reports seeks, scans, lookups, updates, read/write ratio, size in MB, and last-used date per index
- Includes a summary of unused indexes, write-heavy indexes, disabled indexes, and indexes not yet present in the usage cache since the last instance restart
- Report layout is fixed at 120 characters wide
- Version-aware behavior:
  - SQL Server 2005: basic usage stats; instance restart time not available
  - SQL Server 2008 and later: displays stats accumulated since instance restart
  - SQL Server 2012 and later: identifies columnstore indexes

Deployment:

```sql
-- 1. Run IndexAnalysis.sql in the tool database
-- 2. Run AnalyzeIndexes.sql in the tool database
-- 3. Run ShowIndexUsageReport.sql in the tool database
EXEC dbo.AnalyzeIndexes @TargetDatabase = N'YourDatabase'
EXEC dbo.ShowIndexUsageReport @TargetDatabase = N'YourDatabase'
```

Parameters:

- `@TargetDatabase` — database to report on (default: current database)
- `@AnalysisRunID` — specific capture run (default: latest for the target database)
- `@SchemaFilter` — schema name filter (default `%`)
- `@TableFilter` — table name filter (default `%`)
- `@ReportWidth` — kept for backward compatibility; layout is fixed at 120 characters
- `@SortBy` — `READS`, `WRITES`, `SIZE`, `OBJECT`, or `LAST_USE` (default `READS`)

Querying stored results:

```sql
-- Latest run for a database
SELECT *
  FROM dbo.IndexAnalysis
 WHERE DatabaseName = N'YourDatabase'
   AND AnalysisRunID = (
       SELECT TOP 1 AnalysisRunID
         FROM dbo.IndexAnalysis
        WHERE DatabaseName = N'YourDatabase'
        ORDER BY CaptureDate DESC)

-- Unused indexes (0 reads, has writes)
SELECT SchemaName, TableName, IndexName, UserUpdates, SizeMB
  FROM dbo.IndexAnalysis
 WHERE TotalReads = 0
   AND UserUpdates > 0
 ORDER BY UserUpdates DESC

-- Index definitions for the latest run (use vIndexAnalysis after deploying Views/vIndexAnalysis.sql)
SELECT ObjectName, DisplayIndexName, IndexTypeDesc, KeyColumns, IncludedColumns, FilterDefinition,
       CompressionDesc, TotalReads, UserUpdates, SizeMB, UsageCategory
  FROM dbo.vIndexAnalysis
 ORDER BY SchemaName, TableName, DisplayIndexName
```

Note: usage statistics reset when the SQL Server instance restarts. Indexes with no row in `sys.dm_db_index_usage_stats` have had no recorded activity since the restart.

### ExamineQueryStore

File: `ExamineQueryStore.sql`

Stored procedure that performs a **deep Query Store analysis** of a target database and returns prioritized findings (health issues, expensive queries, plan instability, failures, waits, and missing-index opportunities). Complements the text-oriented `ShowQueryStoreReport` and the regression-focused `QueryStorePerformanceAnalysis`.

- Requires SQL Server 2016 or later on the instance; target database compatibility may be below 130 (for example 100–120) when Query Store is enabled
- Reads Query Store catalog views from the target database via three-part names
- Evaluates Query Store configuration (READ_ONLY, storage pressure, capture/cleanup modes, wait-stats capture)
- Emits an informational finding when target compatibility is below 130 (analysis still runs)
- Ranks expensive queries by total CPU, duration, logical reads, and physical I/O within a lookback window
- Detects multi-plan instability (avg-duration variance across plans), duration outliers, forced-plan failures, and failed/aborted executions
- Surfaces Query Store wait categories when wait-stats capture is available (SQL Server 2017+)
- Includes missing-index DMV recommendations with suggested `CREATE INDEX` DDL (validate before applying)
- Returns three result sets: `SUMMARY`, `FINDINGS`, and `TOP_QUERIES`
- Does not persist results to a table

Deployment:

```sql
-- Run ExamineQueryStore.sql in the tool database
EXEC dbo.ExamineQueryStore @TargetDatabase = N'YourDatabase'
EXEC dbo.ExamineQueryStore
     @TargetDatabase = N'YourDatabase',
     @DaysBack = 14,
     @TopN = 50,
     @MinExecutions = 10
```

Parameters:

- `@TargetDatabase` — database to analyze (default: current database)
- `@DaysBack` — lookback window on `last_execution_time` (default `7`)
- `@TopN` — maximum findings per category and top-query rows (default `25`)
- `@MinExecutions` — minimum executions to include a query (default `5`)
- `@PlanVarianceFactor` — multi-plan avg-duration ratio that triggers a plan-instability finding (default `2.0`)
- `@OutlierFactor` — max/avg duration ratio that triggers an outlier finding (default `10.0`)
- `@MinMissingIndexImpact` — minimum missing-index impact score to report (default `10000`)
- `@IncludeMissingIndexes` — include live missing-index DMV findings (default `1`)
- `@IncludeQueryText` — include short query text in findings and top queries (default `1`)
- `@ReturnResultSets` — return summary/findings/top-query result sets (default `1`)

Finding categories (examples):

| Category | Meaning |
|----------|---------|
| `QS_CONFIG` | Query Store disabled, READ_ONLY, storage pressure, capture/cleanup issues |
| `HIGH_CPU` / `HIGH_DURATION` / `HIGH_READS` / `PHYSICAL_IO` | Expensive workload contributors |
| `PLAN_INSTABILITY` | Multiple plans with large avg-duration variance |
| `DURATION_OUTLIER` | Max duration much higher than average |
| `FORCED_PLAN` / `FORCED_PLAN_FAILURE` | Plan forcing inventory and failures |
| `FAILED_EXECUTION` | Aborted/exception execution_type activity |
| `ADHOC_BLOAT` | High share of ad-hoc queries |
| `WAIT_CATEGORY` | Dominant Query Store wait categories |
| `MISSING_INDEX` | High-impact missing-index DMV recommendations |

Note: Missing-index suggestions come from `sys.dm_db_missing_index_*`, not from Query Store plan XML. Test generated DDL in a non-production window. For a compact on-screen text report, use `ShowQueryStoreReport`. For recent-vs-baseline regressions in the current database, use `QueryStorePerformanceAnalysis`.

### ShowQueryStoreReport

File: `ShowQueryStoreReport.sql`

Stored procedure that examines Query Store data on a target database and returns a fixed-width, text-based report in the same style as `ShowIndexUsageReport`. Does not persist results to a table.

- Requires SQL Server 2016 or later and compatibility level 130 or higher on the target database
- Reads Query Store catalog views from the target database via three-part names
- Reports configuration, summary metrics, and top queries by duration, CPU, reads, or executions
- Report layout is fixed at 120 characters wide

Deployment:

```sql
-- Run ShowQueryStoreReport.sql in the tool database
EXEC dbo.ShowQueryStoreReport @TargetDatabase = N'YourDatabase'
```

Parameters:

- `@TargetDatabase` — database to analyze (default: current database)
- `@TopN` — number of queries shown in the report detail (default `25`)
- `@MinExecutions` — minimum executions required to include a query (default `5`)
- `@SortBy` — `DURATION`, `TOTAL`, `CPU`, `READS`, or `EXECUTIONS` (default `DURATION`)
- `@ReportWidth` — kept for backward compatibility; layout is fixed at 120 characters

Note: Query Store must be in `READ_WRITE` or `READ_ONLY` state on the target database to return query data.

### ShowQueryStoreWorkloadReport

File: `ShowQueryStoreWorkloadReport.sql`

Stored procedure that scans Query Store on every eligible database on the server and returns a fixed-width, text-based workload report. Classifies recent activity into stored procedures, SQL Agent jobs, maintenance tasks, application queries, and related workload types. Does not persist results to a table.

- Requires SQL Server 2016 or later
- Scans online, read/write databases where Query Store is enabled and readable
- Filters activity by Query Store `last_execution_time` over the last X days
- Groups stored procedures by `object_id` and ad hoc queries by `query_hash`
- Report layout width is controlled by `@ReportWidth` (default 120, range 80-200)

Deployment:

```sql
-- Run ShowQueryStoreWorkloadReport.sql in the tool database
EXEC dbo.ShowQueryStoreWorkloadReport @DaysBack = 7
```

Parameters:

- `@DaysBack` — lookback window in days (default `7`)
- `@MinExecutions` — minimum executions in the window to include a workload (default `1`)
- `@DatabaseFilter` — database name filter, supports LIKE patterns (default `%`)
- `@IncludeSystemDatabases` — include `master`, `model`, `msdb`, and `tempdb` (default `0`)
- `@TopN` — number of workload rows in the detail section (default `100`)
- `@SortBy` — `EXECUTIONS`, `LAST_EXEC`, `DURATION`, or `DATABASE` (default `EXECUTIONS`)
- `@ReportWidth` — report line width in characters (default `120`, range `80`-`200`)

Workload types reported:

- Stored Procedure, Function, Trigger, View
- Procedure Call (adhoc `EXEC`)
- SQL Agent / Job
- Maintenance
- DDL / Admin
- Application Query

Note: Query Store does not store `program_name`, so SQL Agent jobs are inferred from query text patterns rather than from the calling application or job name.

### StartPerformanceTrace

File: `StartPerformanceTrace.sql`

Starts a server-side SQL Trace and records control metadata in `PerformanceTraceControl`. Trace data is written to a server-side `.trc` file and imported into `PerformanceTraceResults` when the trace is stopped.

- Captures `RPC:Completed`, `SQL:BatchCompleted`, and `SP:StmtCompleted` events
- Optional filters: database name, minimum reads, minimum writes, minimum duration, login name, hostname
- NULL filter parameters mean no filter is applied for that column
- When a filter is populated, rows with NULL values in that column are excluded during import

Deployment:

```sql
-- Requires ALTER TRACE permission
-- Create {InstanceDefaultDataPath}\PerformanceTraces\ on the SQL Server host first
DECLARE @TraceControlID int
EXEC dbo.StartPerformanceTrace
    @TraceName = N'MyTrace',
    @DatabaseName = N'YourDatabase',
    @MinReads = 1000,
    @MinDuration = 500000,
    @TraceControlID = @TraceControlID OUTPUT
```

Parameters:

- `@TraceName` — trace name (default auto-generated)
- `@DatabaseName` — database filter (default none)
- `@MinReads` — minimum reads filter (default none)
- `@MinWrites` — minimum writes filter (default none)
- `@MinDuration` — minimum duration in microseconds (default none)
- `@LoginName` — login filter, supports LIKE patterns (default none)
- `@HostName` — hostname filter, supports LIKE patterns (default none)
- `@TraceFilePath` — optional base path for the trace file (default `{InstanceDefaultDataPath}\PerformanceTraces\`)
- `@MaxFileSizeMB` — rollover size in MB (default `100`)
- `@TraceControlID` — OUTPUT control row identifier

### ShowBackupHealth

File: `ShowBackupHealth.sql`

Stored procedure that examines **instance backup health** and returns ranked problems with suggested actions. Complements `Procedures/ShowBackups.sql` (history report) and `Procedures/ShowBackupsInProgress` (raw `dm_exec_requests` dump). Requires SQL Server 2012 (11.x) or later. Does not persist results to a table.

- Reports every in-progress request whose command contains `BACKUP`, including elapsed time, `percent_complete`, waits, SQL Agent job name (from `program_name` hex), and command text
- Reports last non-copy-only FULL, last DIFF, last LOG, and last copy-only FULL per filtered database from `msdb.dbo.backupset` / `backupmediafamily`
- Lists Agent jobs whose step command contains `BACKUP`, with last run, current run, and next run
- Ranks findings: long-running or stalled backups, stale differential bases, missing FULL/DIFF/LOG coverage, copy-only-only fulls, slow throughput, and backup-job failures
- Interprets waits (`BACKUPIO` / `ASYNC_IO_COMPLETION` = destination; `BACKUPBUFFER` / `BACKUPTHREAD` = buffers/CPU; `LCK_*` = blocking; `PREEMPTIVE_OS_*` = OS/network)
- Does not recommend `KILL` while `percent_complete` is advancing; a stalled 0% backup can be killed and replaced with a FULL (the in-flight backup is not usable)

Deployment:

```sql
-- Run ShowBackupHealth.sql in the tool database
EXEC dbo.ShowBackupHealth
EXEC dbo.ShowBackupHealth @LongRunningMinutes = 30, @FullMaxHours = 24
EXEC dbo.ShowBackupHealth @DatabaseFilter = N'YourDatabase%', @IncludeSystem = 0
```

Parameters:

- `@DatabaseFilter` — database name filter, supports LIKE patterns (default `%`)
- `@FullMaxHours` — maximum age of a non-copy-only FULL before it is stale (default `36`)
- `@DiffMaxHours` — maximum age of a DIFF when the database actually uses differentials (default `36`)
- `@LogMaxMinutes` — maximum age of a LOG backup for FULL/BULK_LOGGED databases (default `60`)
- `@LongRunningMinutes` — in-progress backup or backup job duration that is considered long (default `60`)
- `@HistoryDays` — lookback for job failures, DIFF usage, and instance throughput averages (default `14`)
- `@IncludeSystem` — `1` = include `master`/`model`/`msdb` (`tempdb` is always skipped) (default `0`)
- `@ReturnResultSets` — return the five result sets (default `1`)

Result sets:

1. Summary (capture time, server, running backup count, high-priority finding count, parameters)
2. InProgress
3. LastBackupByDatabase
4. BackupJobs
5. Findings

Finding types:

| Type | Meaning |
|------|---------|
| `BACKUP_RUNNING_LONG` | In-progress backup older than `@LongRunningMinutes` (severity 3 if >= 4 hours or 3x historical average) |
| `BACKUP_STALLED` | In-progress backup at 0% for 30+ minutes, or destination/OS wait with almost no progress |
| `DIFF_BASE_STALE` | A DIFF is running or exists, but the last real FULL is older than `@FullMaxHours` |
| `DIFF_SLOWER_THAN_FULL` | Last completed DIFF took longer than the last completed FULL |
| `NO_RECENT_FULL` | Online database has no non-copy-only FULL within `@FullMaxHours` |
| `NO_RECENT_DIFF` | Database has DIFF history in `@HistoryDays` but the last DIFF is older than `@DiffMaxHours` |
| `NO_RECENT_LOG` | FULL/BULK_LOGGED online database has no LOG backup within `@LogMaxMinutes` (skipped when there is no real FULL / log chain) |
| `BACKUP_JOB_RUNNING_LONG` | Backup-related Agent job running longer than `@LongRunningMinutes` |
| `BACKUP_JOB_FAILED` | Last backup-job outcome failed within `@HistoryDays` |
| `SLOW_THROUGHPUT` | Last completed backup of a type is under 25% of the instance average and lasted over 15 minutes |
| `COPY_ONLY_ONLY` | Latest FULL is copy-only and there is no recent real FULL |

Note: Last-backup times use a 400-day `backupset` lookback so an old FULL still appears as a date rather than as missing. Negative thresholds are converted with `ABS` (zero falls back to the default). Review Findings first; compression, striping, `BUFFERCOUNT`, and `MAXTRANSFERSIZE` are next-run tuning, not the first step on a 24-hour DIFF.

### ShowAgentJobReport

File: `ShowAgentJobReport.sql`

Inventory of SQL Agent jobs on the instance: job metadata, attached schedules, and step definitions. **Default output is Markdown** (wiki-ready). Use `@OutputFormat = 'TEXT'` for the classic fixed-width layout.

- Reads `msdb` catalog views (`sysjobs`, `sysjobsteps`, `sysschedules`, `sysjobschedules`, recent `sysjobhistory`, current `sysjobactivity`)
- Summary counts: enabled/disabled, scheduled/unscheduled, running now, last-run failures
- Job inventory table plus per-job sections (Markdown headings/tables, or fixed-width TEXT)
- Per schedule: frequency, day interval, time window, next run, enabled flag
- Per step: subsystem, database, success/fail flow, retry/proxy/run-as, optional command text (fenced `sql` blocks in Markdown)
- Does not persist results to a table

Deployment:

```sql
-- Run ShowAgentJobReport.sql in the tool database
EXEC dbo.ShowAgentJobReport
EXEC dbo.ShowAgentJobReport @JobFilter = N'%Backup%', @EnabledOnly = 1
EXEC dbo.ShowAgentJobReport @OutputFormat = 'TEXT', @IncludeCommandText = 0, @SortBy = 'CATEGORY'
```

Parameters:

- `@JobFilter` — LIKE filter for job name (default `%`)
- `@CategoryFilter` — LIKE filter for category name (default `%`)
- `@EnabledOnly` — `1` = enabled jobs only (default `0`)
- `@IncludeSchedules` — include schedule detail (default `1`)
- `@IncludeSteps` — include job step detail (default `1`)
- `@IncludeCommandText` — include truncated step command text (default `1`)
- `@MaxCommandLength` — max command characters shown per step (default `2000`; line breaks preserved)
- `@SortBy` — `NAME`, `CATEGORY`, `OWNER`, or `ENABLED` (default `NAME`)
- `@OutputFormat` — `MARKDOWN` (default, wiki-friendly) or `TEXT` (fixed-width)
- `@ReportWidth` — TEXT mode only; layout is fixed at 120 characters

Note: Requires permission to read SQL Agent job metadata in `msdb` (for example `SQLAgentReaderRole` or higher). For Markdown, copy the `ReportLine` result column (Results to Text / grid) into the wiki. Complements `ShowJobHistory` / `ShowRunningJobs` in `Procedures/` which cover execution history and currently running jobs.

### ShowTraceWritablePaths

File: `ShowTraceWritablePaths.sql`

Lists local server paths where SQL Server can typically write server-side trace files, including free space and whether the path fits the SQL Trace path length limit.

```sql
EXEC dbo.ShowTraceWritablePaths
```

Returns:

- recommended default trace folder used by `StartPerformanceTrace`
- instance data and log paths
- folders already used by database files
- folders currently used by active traces
- SQL Server service account and an example `StartPerformanceTrace` command

### ShowTraceInfo

File: `ShowTraceInfo.sql`

Reports what is going on with performance traces by querying `PerformanceTraceControl` and `PerformanceTraceResults`, correlated with active server-side traces.

```sql
EXEC dbo.ShowTraceInfo
EXEC dbo.ShowTraceInfo @Status = 'Running'
EXEC dbo.ShowTraceInfo @TraceControlID = 1
```

Returns:

- summary counts for running, stopped, and error traces plus total imported events
- per-trace control metadata, server trace status, filters, and a plain-language `TraceStateSummary`
- imported event statistics such as event count, max/avg duration, max reads/writes, and first/last event times
- ready-to-run `StopPerformanceTrace` command for each trace

### StopPerformanceTrace

File: `StopPerformanceTrace.sql`

Stops a running trace, imports the trace file into `PerformanceTraceResults`, and updates `PerformanceTraceControl`.

```sql
EXEC dbo.StopPerformanceTrace @TraceControlID = 1
-- or
EXEC dbo.StopPerformanceTrace @TraceName = N'MyTrace'
```

Parameters:

- `@TraceControlID` — preferred identifier from `ShowTraceInfo`
- `@TraceID` — SQL Server trace ID
- `@TraceName` — trace name

Querying stored trace results:

```sql
SELECT DatabaseName, Duration, Reads, Writes, LoginName, HostName, StartTime, QueryText
  FROM dbo.PerformanceTraceResults
 WHERE TraceControlID = 1
 ORDER BY Duration DESC
```