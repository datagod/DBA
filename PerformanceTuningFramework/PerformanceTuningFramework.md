# Performance Tuning Framework

SQL Server scripts and utilities for database performance analysis and tuning. Deploy scripts to the database you wish to analyze unless noted otherwise.

## Overview

This framework lives in the `PerformanceTuningFramework` folder of the DBA repository. Each script is designed to be version-aware where possible and to produce output that is easy to read in SSMS or an Azure DevOps wiki.

## Scripts

### ShowIndexUsageReport

File: `ShowIndexUsageReport.sql`

Stored procedure that examines index usage statistics on the current database and returns a fixed-width, text-based report suitable for on-screen review.

- Source: `sys.dm_db_index_usage_stats` joined with index and size metadata
- Reports seeks, scans, lookups, updates, read/write ratio, size in MB, and last-used date per index
- Includes a summary of unused indexes, write-heavy indexes, disabled indexes, and indexes not yet present in the usage cache since the last instance restart
- Default report width is 100 characters; adjustable from 80 to 120
- Version-aware behavior:
  - SQL Server 2005: basic usage stats; instance restart time not available
  - SQL Server 2008 and later: displays stats accumulated since instance restart
  - SQL Server 2012 and later: identifies columnstore indexes

Deployment:

```sql
-- Run ShowIndexUsageReport.sql in the target database to create the procedure
EXEC dbo.ShowIndexUsageReport
```

Optional parameters:

- `@SchemaFilter` — schema name filter (default `%`)
- `@TableFilter` — table name filter (default `%`)
- `@ReportWidth` — line width in characters (default `100`)
- `@SortBy` — `READS`, `WRITES`, `SIZE`, `OBJECT`, or `LAST_USE` (default `READS`)

Note: usage statistics reset when the SQL Server instance restarts. Indexes with no row in `sys.dm_db_index_usage_stats` have had no recorded activity since the restart.