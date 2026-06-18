# Performance Tuning Framework

SQL Server scripts and utilities for database performance analysis and tuning. Deploy scripts to a single tool database and analyze any target database on the same instance.

## Overview

This framework lives in the `PerformanceTuningFramework` folder of the DBA repository. Each script is designed to be version-aware where possible and to produce output that is easy to read in SSMS or an Azure DevOps wiki.

Procedures run from one tool database and read metadata from a target database passed as a parameter. Index usage results are stored in `IndexAnalysis` for later querying; Query Store reporting is text output only.

## Tables

### IndexAnalysis

File: `IndexAnalysis.sql`

Persistent storage for index usage analysis results. Deploy to the tool database before running `AnalyzeIndexes` or `ShowIndexUsageReport`.

- One row per index per execution
- Grouped by `AnalysisRunID` and `CaptureDate` for each run
- Stores target database name, schema, table, index identity, usage counts, size, last-used timestamps, and run filters
- Indexed on `AnalysisRunID` and `(DatabaseName, CaptureDate)`

Deployment:

```sql
-- Run IndexAnalysis.sql in the tool database
```

## Scripts

### AnalyzeIndexes

File: `AnalyzeIndexes.sql`

Stored procedure that captures index usage statistics from a target database and writes the results to `IndexAnalysis`.

- Reads catalog metadata from the target database via three-part names
- Joins instance-wide `sys.dm_db_index_usage_stats` filtered to the target database
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

Stored procedure that calls `AnalyzeIndexes` to capture data, then returns a fixed-width, text-based report suitable for on-screen review.

- Delegates data capture to `AnalyzeIndexes`
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
EXEC dbo.ShowIndexUsageReport @TargetDatabase = N'YourDatabase'
```

Parameters:

- `@TargetDatabase` — database to analyze (default: current database)
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
```

Note: usage statistics reset when the SQL Server instance restarts. Indexes with no row in `sys.dm_db_index_usage_stats` have had no recorded activity since the restart.

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