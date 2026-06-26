![DBA Toolkit](docs/dba-header.jpg)

# DBA — SQL Server Administration Toolkit

A collection of T-SQL scripts, stored procedures, functions, and utilities for **Microsoft SQL Server** database administration, monitoring, alerting, and performance tuning. Scripts are designed for practical day-to-day DBA work in SSMS and can be deployed to a dedicated **tool database** on each instance.

**Repository:** [github.com/datagod/DBA](https://github.com/datagod/DBA)

---

## Table of Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Repository Layout](#repository-layout)
- [Performance Tuning Framework](#performance-tuning-framework)
- [General Procedures](#general-procedures)
- [Functions](#functions)
- [Tables](#tables)
- [Ad-Hoc Queries](#ad-hoc-queries)
- [PowerShell Utilities](#powershell-utilities)
- [Deployment Notes](#deployment-notes)
- [Version Awareness](#version-awareness)
- [Contributing](#contributing)

---

## Overview

This repository provides reusable SQL Server tooling in four broad areas:

| Area | Purpose |
|------|---------|
| **Performance Tuning Framework** | DMV-driven diagnostics, index analysis, heap detection, Query Store reporting, and server-side performance traces |
| **Monitoring & diagnostics** | Waits, blocking, who-is-active style snapshots, backups, space, VLFs, SSIS history |
| **Alerting & email** | Job failure alerts, blocked-process alerts, email queue processing |
| **Utilities** | Event logging, configuration tables, metadata extraction, ad-hoc diagnostic queries |

Most procedures follow a consistent pattern:

1. Deploy to a **tool database** (for example `dba`) on the SQL Server instance.
2. Pass `@TargetDatabase` (or equivalent) to analyze any user database on that instance.
3. Use three-part names (`[TargetDb].sys.*`) and instance-scoped DMVs where appropriate.

Detailed documentation for the performance suite lives in [PerformanceTuningFramework/PerformanceTuningFramework.md](PerformanceTuningFramework/PerformanceTuningFramework.md).

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| **SQL Server** | Most scripts target SQL Server 2008 (10.x) or later; some features require 2016+ (Query Store) or 2022 permissions |
| **Tool database** | Create a database (for example `dba`) and deploy scripts there |
| **Permissions** | Typical needs: `VIEW SERVER STATE`, `VIEW DATABASE STATE`, `ALTER TRACE` (for traces), `db_owner` on tool DB |
| **SSMS** | Scripts use `GO` batches; run in SQL Server Management Studio or `sqlcmd` |

Individual procedures document additional version and compatibility requirements in their file headers.

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/datagod/DBA.git
cd DBA
```

### 2. Create a tool database

```sql
CREATE DATABASE dba;
GO
USE dba;
GO
```

### 3. Deploy core performance objects (recommended first)

Run these scripts in order against the tool database:

```sql
USE dba;
GO
-- Tables
:r PerformanceTuningFramework\IndexAnalysis.sql
:r PerformanceTuningFramework\DatabasePerformanceAnalysis.sql
:r PerformanceTuningFramework\PerformanceTraceResults.sql

-- Procedures (examples)
:r PerformanceTuningFramework\AnalyzeIndexes.sql
:r PerformanceTuningFramework\ExamineDatabasePerformance.sql
:r PerformanceTuningFramework\CheckForHeaps.sql
:r PerformanceTuningFramework\ShowHeaps.sql
:r PerformanceTuningFramework\RecommendClusteredIndex.sql
```

In SSMS, open each `.sql` file and execute it against `dba` instead of using `:r` if you prefer.

### 4. Run a quick health check

```sql
-- Index usage snapshot
DECLARE @RunID uniqueidentifier;
EXEC dbo.AnalyzeIndexes @TargetDatabase = N'YourDatabase', @AnalysisRunID = @RunID OUTPUT;
EXEC dbo.ShowIndexUsageReport @TargetDatabase = N'YourDatabase';

-- Heap scan (lightweight)
EXEC dbo.CheckForHeaps @TargetDatabase = N'YourDatabase';

-- Single-table clustered index recommendation
EXEC dbo.RecommendClusteredIndex
     @TargetDatabase = N'YourDatabase',
     @SchemaName     = N'dbo',
     @TableName      = N'YourTable';
```

---

## Repository Layout

```
DBA/
├── docs/                          # Documentation assets (README header image)
├── PerformanceTuningFramework/    # Performance diagnostics suite
├── Procedures/                    # General-purpose stored procedures
├── Functions/                     # User-defined functions
├── Table/                         # Table DDL scripts
├── Queries/                       # Standalone diagnostic queries
└── powershell/                    # Supporting PowerShell scripts
```

---

## Performance Tuning Framework

The `PerformanceTuningFramework` folder is the most actively developed area. It uses a **deploy-to-tool-DB, analyze-target-DB** model and supports mixed-version hosts (for example SQL Server 2022 examining a compatibility level 100 database).

### Persistent tables

| Script | Objects | Purpose |
|--------|---------|---------|
| `IndexAnalysis.sql` | `IndexAnalysis` | Stores per-index usage captures |
| `DatabasePerformanceAnalysis.sql` | `DatabasePerformanceRun`, `DatabasePerformanceMetric`, `DatabasePerformanceFinding` | Stores broad performance exam results |
| `PerformanceTraceResults.sql` | `PerformanceTraceControl`, `PerformanceTraceResults` | Stores server-side trace metadata and events |

### Stored procedures

| Procedure | File | Summary |
|-----------|------|---------|
| `AnalyzeIndexes` | `AnalyzeIndexes.sql` | Capture index usage into `IndexAnalysis` |
| `ShowIndexUsageReport` | `ShowIndexUsageReport.sql` | Fixed-width text report from `IndexAnalysis` |
| `ExamineDatabasePerformance` | `ExamineDatabasePerformance.sql` | Broad DMV-based database health exam |
| `CompareDatabasePerformance` | `CompareDatabasePerformance.sql` | Compare two exam runs side-by-side |
| `CheckForHeaps` | `CheckForHeaps.sql` | Fast catalog-only heap scan |
| `ShowHeaps` | `ShowHeaps.sql` | Full heap DMV analysis with clustered-index DDL |
| `RecommendClusteredIndex` | `RecommendClusteredIndex.sql` | Single-table clustered index recommendation (identity-first) |
| `ShowQueryStoreReport` | `ShowQueryStoreReport.sql` | Query Store report for one database |
| `ShowQueryStoreWorkloadReport` | `ShowQueryStoreWorkloadReport.sql` | Instance-wide Query Store workload scan |
| `StartPerformanceTrace` | `StartPerformanceTrace.sql` | Start a filtered server-side trace |
| `StopPerformanceTrace` | `StopPerformanceTrace.sql` | Stop trace and import results |
| `ShowTraceInfo` | `ShowTraceInfo.sql` | Trace status and imported event stats |
| `ShowTraceWritablePaths` | `ShowTraceWritablePaths.sql` | Valid paths for trace file output |

### Common workflows

**Index tuning**

```sql
EXEC dbo.AnalyzeIndexes @TargetDatabase = N'YourDatabase';
EXEC dbo.ShowIndexUsageReport @TargetDatabase = N'YourDatabase', @SortBy = 'READS';
```

**Heap remediation**

```sql
-- Quick inventory
EXEC dbo.CheckForHeaps @TargetDatabase = N'YourDatabase', @SortBy = 'ROWS';

-- Full analysis with DDL suggestions
EXEC dbo.ShowHeaps @TargetDatabase = N'YourDatabase', @SortBy = 'SCORE';

-- One table — prefer single ascending identity clustering key
EXEC dbo.RecommendClusteredIndex
     @TargetDatabase = N'YourDatabase',
     @SchemaName     = N'dbo',
     @TableName      = N'YourTable';
```

**Database comparison**

```sql
DECLARE @RunA uniqueidentifier, @RunB uniqueidentifier;
EXEC dbo.ExamineDatabasePerformance @TargetDatabase = N'DatabaseA', @AnalysisRunID = @RunA OUTPUT;
EXEC dbo.ExamineDatabasePerformance @TargetDatabase = N'DatabaseB', @AnalysisRunID = @RunB OUTPUT;
EXEC dbo.CompareDatabasePerformance @AnalysisRunID_A = @RunA, @AnalysisRunID_B = @RunB;
```

**Performance trace**

```sql
DECLARE @TraceID int;
EXEC dbo.StartPerformanceTrace
     @TraceName    = N'HeavyReads',
     @DatabaseName = N'YourDatabase',
     @MinReads     = 10000,
     @TraceControlID = @TraceID OUTPUT;

-- ... later ...
EXEC dbo.StopPerformanceTrace @TraceControlID = @TraceID;
```

See [PerformanceTuningFramework.md](PerformanceTuningFramework/PerformanceTuningFramework.md) for full parameter lists, deployment order, and version notes.

---

## General Procedures

Scripts in `Procedures/` cover monitoring, maintenance visibility, SSIS, and alerting. Deploy individually to the tool database (or another database of your choice).

### Monitoring and diagnostics

| Procedure | File | Description |
|-----------|------|-------------|
| `Who` | `Who.sql` | Active session snapshot |
| `Waits` | `Waits.sql` | Wait statistics |
| `Blocks` | `Blocks.sql` | Blocking chain information |
| `WaitingTasks` | `WaitingTasks.sql` | Tasks waiting on resources |
| `OpenTransactions` | `OpenTransactions.sql` | Open transaction report |
| `ShowCompatabilityLevels` | `ShowCompatabilityLevels.sql` | Compatibility level for all user databases |
| `ShowDatabaseSizes` | `ShowDatabaseSizes.sql` | Database size summary |
| `ShowDBSpace` | `ShowDBSpace.sql` | Database file space usage |
| `ShowBackups` | `ShowBackups.sql` | Backup history |
| `ShowVLFCount` | `ShowVLFCount.sql` | Virtual log file counts |
| `ShowUnusedIndexes` | `ShowUnusedIndexes.sql` | Indexes with low usage signals |
| `ShowJobHistory` | `ShowJobHistory.sql` | SQL Agent job history |
| `ShowJobSchedules` | `ShowJobSchedules.sql` | SQL Agent job schedules |
| `MeasureIOLatency` | `MeasureIOLatency (1).sql` | I/O latency measurement |
| `ExamineStoredProcedure` | `ExamineStoredProcedure.sql` | Stored procedure metadata and definition review |
| `GenerateIndexesForTable` | `GenerateIndexesForTable.sql` | Index DDL suggestions for a table |
| `Version` | `Version.sql` | SQL Server version information |
| `Now` / `Now2` | `Now.sql`, `Now2.sql` | Current date/time helpers |

### SSIS

| Procedure | File |
|-----------|------|
| `ShowSSISExecutions` | `ShowSSISExecutions.sql` |
| `ShowSSISMessages` | `ShowSSISMessages.sql` |
| `SSISReport` | `SSISReport.sql` |

### Alerting and email

| Procedure | File |
|-----------|------|
| `SendJobFailureAlerts` | `SendJobFailureAlerts.sql` |
| `SendBlockedProcessAlert` | `SendBlockedProcessAlert` |
| `SendLongRunningJobAlert` | `SendLongRunningJobAlert` |
| `SendEmail` / `SendEmailAlert` | `SendEmail`, `SendEmailAlert` |
| `SendEmailQuery` | `SendEmailQuery.sql` |
| `ProcessEmailQueue` | `ProcessEmailQueue` |
| `ResendFailedEmails` | `ResendFailedEmails` |

### Utilities

| Procedure | File |
|-----------|------|
| `LogEvent` / `EL` | `LogEvent.sql`, `EL.sql` |
| `TrimEventLog` | `TrimEventLog` |
| `sp_Query2Grid` | `sp_Query2Grid.sql` |
| `GetTableMetadataXML` | `GetTableMetadataXML` |
| `ReplaceTextInStoredProcedures` | `ReplaceTextInStoredProcedures` |
| `ShowBlackBoxTraces` | `ShowBlackBoxTraces.sql` |

---

## Functions

| Function | File | Description |
|----------|------|-------------|
| `fn_SecondsToTime` | `fn_SecondsToTime.sql` | Format seconds as time string |
| `fn_ScrapeText` | `fn_ScrapeText.sql` | Text extraction helper |
| `fn_Random` | `fn_Random.sql` | Random number helper |
| `GetErrorInfo` | `GetErrorInfo.sql` | Error message formatting |
| `fn_WaitTypeExplanation` | `fn_WaitTypeExplanation` | Wait type descriptions |
| `fn_GetJobFromProgramName` | `fn_GetJobFromProgramName` | Parse job name from program name |

---

## Tables

| Script | Object(s) | Purpose |
|--------|-----------|---------|
| `Configuration.sql` | `Configuration` | Key/value configuration storage |
| `EventLog.sql` | `EventLog` | Application event logging |
| `EmailList` / `EmailQueue` | Email tables | Email alerting infrastructure |
| `IndexFragmentation.sql` | `IndexFragmentation` | Index fragmentation capture storage |

Deploy table scripts before procedures that reference them.

---

## Ad-Hoc Queries

Standalone scripts in `Queries/` for one-off investigation (not wrapped as procedures):

| Query | File |
|-------|------|
| Recent poor-performing queries | `RecentPoorPerformingQueries.sql` |
| Linked server tables | `ShowLinkedServerTables` |
| Recovery model stats | `RecoveryStats` |
| Linked server view | `vLinks` |

---

## PowerShell Utilities

| Script | Description |
|--------|-------------|
| `powershell/ExtractDocuments.ps1` | Extract document content from SQL Server (uses integrated security connection pattern) |

---

## Deployment Notes

### Tool database pattern

The Performance Tuning Framework expects a single **tool database** per instance. Procedures accept `@TargetDatabase` and read the target's catalog via three-part names while joining instance-scoped DMVs (`sys.dm_db_index_usage_stats`, `sys.dm_os_wait_stats`, etc.) filtered by `database_id`.

### Script execution

- Each `.sql` file uses `DROP`/`CREATE` or `IF NOT EXISTS` patterns where appropriate.
- Look for `Procedure created successfully.` (or similar) at the end of each script.
- If creation fails, fix errors in that script before deploying dependent objects.

### DMV usage statistics

`sys.dm_db_index_usage_stats` and related DMVs reset when the SQL Server **instance restarts**. Interpret "unused" indexes in that context.

### Generated DDL

Procedures such as `ShowHeaps` and `RecommendClusteredIndex` emit **suggested DDL only**. Review and test in a non-production window before applying. `ONLINE = ON` appears in suggestions only when the host edition supports it (Enterprise/Developer).

---

## Version Awareness

Many scripts validate:

- **Instance major version** (for example 10 = SQL 2008, 11 = 2012, 16 = 2022)
- **Target database compatibility level** (for example 100 = SQL 2008 mode, 130 = 2016, 160 = 2022)

When a newer instance hosts an older-compat database, catalog and index-type logic follow the **target compatibility level**, while features like `ONLINE` index builds follow the **host instance edition**.

Use `ShowCompatabilityLevels` to list compatibility levels across user databases:

```sql
EXEC dbo.ShowCompatabilityLevels;
```

---

## Contributing

1. Fork the repository and create a feature branch.
2. Follow existing script conventions: file header comment, `SET ANSI_NULLS ON`, `DROP`/`CREATE` for procedures, `PRINT` on deploy.
3. Document new procedures in `PerformanceTuningFramework.md` (for framework scripts) or in this README.
4. Test against SQL Server 2008+ where compatibility is claimed.
5. Submit a pull request with a clear description of the change.

---

## Author

**Bill McEvoy** — [datagod](https://github.com/datagod)

Scripts in this repository reflect practical SQL Server DBA patterns developed for production administration and performance troubleshooting.