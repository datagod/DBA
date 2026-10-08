/*
  ShowTraceProcessMap.sql
  Performance Tuning Framework

  Requires SQL Server 2012 (11.x) or later, and database compatibility level 110 or higher.

  Deploy to the tool database, then execute:
    EXEC dbo.ShowTraceProcessMap
         @TraceTable = N'TraceLab.dbo.ImportedTrace'

    EXEC dbo.ShowTraceProcessMap
         @TraceTable      = N'dbo.ImportedTrace',
         @StartTime       = '2026-10-08 01:00',
         @EndTime         = '2026-10-08 03:00',
         @ApplicationName = N'Nightly%',
         @BucketMinutes   = 5,
         @GapSeconds      = 60,
         @TopN            = 50

  Reads one imported SQL Trace table (fn_trace_gettable ... INTO, or Profiler
  Save As Table) and shows the batch-process picture: who ran, in what order,
  how long each run took, what overlapped, and where the time went.

  This is not ShowTraceInfo. ShowTraceInfo reports server-side traces stored in
  dbo.PerformanceTraceControl. This procedure reads any imported trace table.
  QueryText is accepted when TextData is absent, so dbo.PerformanceTraceResults
  can be passed as @TraceTable (filter by time if that table holds many traces).

  Queries/ShowDecodedTrace.sql is the row-level decode of the same kind of table.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowTraceProcessMap') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowTraceProcessMap'
    DROP PROCEDURE dbo.ShowTraceProcessMap
END
GO

PRINT 'Creating: ShowTraceProcessMap'
GO

CREATE PROCEDURE dbo.ShowTraceProcessMap
(
    @TraceTable          nvarchar(400) = NULL,          -- 1-, 2-, or 3-part imported trace table
    @StartTime           datetime      = NULL,          -- inclusive; filters on event StartTime
    @EndTime             datetime      = NULL,          -- inclusive; filters on event StartTime
    @DatabaseName        nvarchar(128) = NULL,          -- LIKE filter
    @ApplicationName     nvarchar(128) = NULL,          -- LIKE filter
    @LoginName           nvarchar(128) = NULL,          -- LIKE filter
    @HostName            nvarchar(128) = NULL,          -- LIKE filter
    @MinDurationMs       bigint        = NULL,          -- ignore shorter work in busy time and steps
    @BucketMinutes       int           = 5,             -- timeline bucket size
    @GapSeconds          int           = 60,            -- idle gap that splits one session into another run; 0 disables
    @TopN                int           = 50,            -- top normalized statements; 0 = all
    @ReturnOverview      bit           = 1,
    @ReturnProcesses     bit           = 1,
    @ReturnSteps         bit           = 1,
    @ReturnTimeline      bit           = 1,
    @ReturnGantt         bit           = 1,
    @ReturnTopStatements bit           = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: October 8, 2026
-- Author:       Bill McEvoy
-- Description:  Maps an imported SQL Trace into processes, ordered steps, a concurrency
--               timeline, a text Gantt, a Mermaid gantt diagram, and the top normalized
--               statements. Deploy to the tool database. The trace table may live in
--               another database on the same instance. Requires SQL Server 2012 (11.x)
--               or later and compatibility level 110 or higher (window functions, TRY_CONVERT).
--               Does not start, stop, or import a trace. Duration is microseconds and CPU
--               is milliseconds, which is how SQL Server 2005+ stores a trace; displayed
--               times are seconds.
---------------------------------------------------------------------------------------------------
-- Version:      1.0
-- Date Revised: October 8, 2026
-- Author:       Bill McEvoy
-- Reason:       Initial release.
---------------------------------------------------------------------------------------------------
-- Version:      1.1
-- Date Revised: October 8, 2026
-- Author:       William McEvoy
-- Reason:       Fix truncation on long TextData. Statement text longer than 400
--               characters was assigned to StatementKey before it was shortened,
--               which aborted the procedure under ANSI_WARNINGS ON. The full
--               statement is now kept through normalization so two long statements
--               that differ past the first 400 characters stay separate. The
--               process row still shows the first 400 characters.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion         tinyint,
    @CompatibilityLevel   int,
    @Clean                nvarchar(400),
    @Object               sysname,
    @Schema               sysname,
    @DbName               sysname,
    @FullName             nvarchar(1000),
    @Sql                  nvarchar(max),
    @Where                nvarchar(max),
    @OrderBy              nvarchar(400),
    @ColEventSequence     sysname,
    @ColEventClass        sysname,
    @ColTextData          sysname,
    @ColDatabaseName      sysname,
    @ColObjectName        sysname,
    @ColLoginName         sysname,
    @ColHostName          sysname,
    @ColApplicationName   sysname,
    @ColSPID              sysname,
    @ColDuration          sysname,
    @ColCPU               sysname,
    @ColReads             sysname,
    @ColWrites            sysname,
    @ColRowCounts         sysname,
    @ColStartTime         sysname,
    @ColEndTime           sysname,
    @TextSource           nvarchar(20),
    @HasReads             bit,
    @HasWrites            bit,
    @HasRowCounts         bit,
    @HasCpu               bit,
    @HasEventClass        bit,
    @MinDurationUs        bigint,
    @SuppressedByDuration int,
    @Pass                 int,
    @TraceStart           datetime,
    @TraceEnd             datetime,
    @AlignedStart         datetime,
    @SpanMinutes          int,
    @UsedBucketMinutes    int,
    @BucketCount          int,
    @BucketNote           nvarchar(400),
    @GanttMinutes         int,
    @GanttCount           int,
    @GanttNote            nvarchar(400),
    @EventCount           int,
    @ProcessCount         int,
    @MermaidShown         int,
    @MermaidNote          nvarchar(300),
    @MermaidBody          nvarchar(max),
    @Mermaid              nvarchar(max),
    @FilterNote           nvarchar(max),
    @EventNameSource      nvarchar(40),
    @BusyChar             nchar(1),
    @IdleChar             nchar(1),
    @EmptyChar            nchar(1),
    @StmtTop              int,
    @RequestedBucket      int

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 11
BEGIN
    RAISERROR('ShowTraceProcessMap requires SQL Server 2012 (11.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SELECT @CompatibilityLevel = compatibility_level
FROM sys.databases
WHERE name = DB_NAME()

IF @CompatibilityLevel < 110
BEGIN
    RAISERROR('ShowTraceProcessMap requires database compatibility level 110 or higher. This database is %d. Window functions and TRY_CONVERT need 110.', 16, 1, @CompatibilityLevel)
    RETURN
END

IF @TraceTable IS NULL OR LTRIM(RTRIM(@TraceTable)) = N''
BEGIN
    RAISERROR('@TraceTable is required. Pass the imported trace table as database.schema.table, schema.table, or table.', 16, 1)
    RETURN
END

IF @StartTime IS NOT NULL AND @EndTime IS NOT NULL AND @EndTime < @StartTime
BEGIN
    RAISERROR('@EndTime cannot be earlier than @StartTime.', 16, 1)
    RETURN
END

IF @MinDurationMs IS NOT NULL AND @MinDurationMs < 0
BEGIN
    RAISERROR('@MinDurationMs cannot be negative.', 16, 1)
    RETURN
END

IF @MinDurationMs > 9223372036854775
BEGIN
    RAISERROR('@MinDurationMs is too large.', 16, 1)
    RETURN
END

SET @RequestedBucket = @BucketMinutes
IF @BucketMinutes IS NULL
    SET @BucketMinutes = 5
IF @BucketMinutes < 1
BEGIN
    RAISERROR('@BucketMinutes must be 1 or greater.', 16, 1)
    RETURN
END

IF @GapSeconds IS NULL
    SET @GapSeconds = 60
IF @GapSeconds < 0
BEGIN
    RAISERROR('@GapSeconds cannot be negative. Use 0 to keep a session as one run unless Audit Login or Audit Logout splits it.', 16, 1)
    RETURN
END

IF @TopN IS NULL
    SET @TopN = 50
IF @TopN < 0
BEGIN
    RAISERROR('@TopN cannot be negative. Use 0 to return every normalized statement.', 16, 1)
    RETURN
END

IF @ReturnOverview IS NULL SET @ReturnOverview = 1
IF @ReturnProcesses IS NULL SET @ReturnProcesses = 1
IF @ReturnSteps IS NULL SET @ReturnSteps = 1
IF @ReturnTimeline IS NULL SET @ReturnTimeline = 1
IF @ReturnGantt IS NULL SET @ReturnGantt = 1
IF @ReturnTopStatements IS NULL SET @ReturnTopStatements = 1

SET @MinDurationUs = CASE WHEN @MinDurationMs IS NULL THEN NULL ELSE @MinDurationMs * CONVERT(bigint, 1000) END
SET @StmtTop = CASE WHEN @TopN = 0 THEN 2147483647 ELSE @TopN END
SET @BusyChar = NCHAR(9608)   -- full block: bucket has batch/RPC (or the fallback work grain)
SET @IdleChar = NCHAR(9617)   -- light shade: process is connected, no work event in the bucket
SET @EmptyChar = NCHAR(183)   -- middle dot: process is outside this bucket
SET @EventNameSource = N'built-in list'
SET @FilterNote = N''
SET @BucketNote = NULL
SET @GanttNote = NULL
SET @SuppressedByDuration = 0

---------------------------------------------------------------------------------------------
-- Parse and validate the trace table name.
-- PARSENAME is used for names up to 128 characters. Longer names are split from the right
-- the same way (object, schema, database) because PARSENAME returns NULL past 128 characters.
-- Brackets are removed before parsing. QUOTENAME is applied to each part before use.
---------------------------------------------------------------------------------------------
SET @Clean = LTRIM(RTRIM(@TraceTable))
SET @Clean = REPLACE(REPLACE(@Clean, N'[', N''), N']', N'')
SET @Clean = LTRIM(RTRIM(@Clean))

IF @Clean = N'' OR LEFT(@Clean, 1) = N'.' OR RIGHT(@Clean, 1) = N'.' OR CHARINDEX(N'..', @Clean) > 0
BEGIN
    RAISERROR('@TraceTable has an empty name part. Use database.schema.table, schema.table, or table.', 16, 1)
    RETURN
END

IF LEN(@Clean) <= 128
BEGIN
    IF PARSENAME(@Clean, 4) IS NOT NULL
    BEGIN
        RAISERROR('@TraceTable must be a 1-, 2-, or 3-part name (database.schema.table). Server-qualified names are not supported.', 16, 1)
        RETURN
    END

    SET @Object = PARSENAME(@Clean, 1)
    SET @Schema = PARSENAME(@Clean, 2)
    SET @DbName = PARSENAME(@Clean, 3)
END
ELSE
BEGIN
    DECLARE @Rest nvarchar(400)
    DECLARE @LastDot int

    SET @LastDot = CHARINDEX(N'.', REVERSE(@Clean))
    IF @LastDot = 0
        SET @Object = @Clean
    ELSE
    BEGIN
        SET @Object = RIGHT(@Clean, @LastDot - 1)
        SET @Rest = LEFT(@Clean, LEN(@Clean) - @LastDot)
        SET @LastDot = CHARINDEX(N'.', REVERSE(@Rest))
        IF @LastDot = 0
            SET @Schema = @Rest
        ELSE
        BEGIN
            SET @Schema = RIGHT(@Rest, @LastDot - 1)
            SET @DbName = LEFT(@Rest, LEN(@Rest) - @LastDot)
            IF CHARINDEX(N'.', @DbName) > 0
            BEGIN
                RAISERROR('@TraceTable must be a 1-, 2-, or 3-part name (database.schema.table). Server-qualified names are not supported.', 16, 1)
                RETURN
            END
        END
    END
END

IF @Object IS NULL OR @Object = N''
   OR LEN(@Object) > 128
   OR LEN(ISNULL(@Schema, N'')) > 128
   OR LEN(ISNULL(@DbName, N'')) > 128
BEGIN
    RAISERROR('@TraceTable could not be parsed. Use database.schema.table, schema.table, or table. Each part must be 128 characters or fewer.', 16, 1)
    RETURN
END

IF @Schema IS NULL OR @Schema = N''
    SET @Schema = N'dbo'
IF @DbName IS NULL OR @DbName = N''
    SET @DbName = DB_NAME()

IF DB_ID(@DbName) IS NULL
BEGIN
    RAISERROR('Database %s was not found. Pass @TraceTable as database.schema.table for a table on this instance.', 16, 1, @DbName)
    RETURN
END

SET @FullName = QUOTENAME(@DbName) + N'.' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Object)

IF OBJECT_ID(@FullName, N'U') IS NULL
BEGIN
    RAISERROR('Trace table %s was not found, or it is not a user table. Import the trace with fn_trace_gettable or Profiler Save As Table, then pass that table in @TraceTable.', 16, 1, @FullName)
    RETURN
END

---------------------------------------------------------------------------------------------
-- Temp tables are created here, in the procedure, before any dynamic SQL.
-- A #temp table created inside sp_executesql is dropped when that batch ends, so the
-- dynamic batch only inserts into tables that already exist.
---------------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Column') IS NOT NULL DROP TABLE #Column
IF OBJECT_ID('tempdb..#TraceEvent') IS NOT NULL DROP TABLE #TraceEvent
IF OBJECT_ID('tempdb..#Process') IS NOT NULL DROP TABLE #Process
IF OBJECT_ID('tempdb..#EventName') IS NOT NULL DROP TABLE #EventName
IF OBJECT_ID('tempdb..#Sweep') IS NOT NULL DROP TABLE #Sweep
IF OBJECT_ID('tempdb..#Bucket') IS NOT NULL DROP TABLE #Bucket
IF OBJECT_ID('tempdb..#BucketMetric') IS NOT NULL DROP TABLE #BucketMetric
IF OBJECT_ID('tempdb..#GanttBucket') IS NOT NULL DROP TABLE #GanttBucket
IF OBJECT_ID('tempdb..#GanttCell') IS NOT NULL DROP TABLE #GanttCell
IF OBJECT_ID('tempdb..#MermaidProcess') IS NOT NULL DROP TABLE #MermaidProcess

CREATE TABLE #Column
(
    ColumnName sysname NOT NULL PRIMARY KEY
)

SET @Sql = N'
INSERT INTO #Column (ColumnName)
SELECT c.name
FROM ' + QUOTENAME(@DbName) + N'.sys.columns AS c
WHERE c.object_id = OBJECT_ID(@FullName, N''U'')
'

EXEC sys.sp_executesql
    @Sql,
    N'@FullName nvarchar(1000)',
    @FullName = @FullName

SELECT @ColStartTime = ColumnName FROM #Column WHERE ColumnName = N'StartTime'
SELECT @ColEndTime = ColumnName FROM #Column WHERE ColumnName = N'EndTime'
SELECT @ColEventClass = ColumnName FROM #Column WHERE ColumnName = N'EventClass'
SELECT @ColEventSequence = ColumnName FROM #Column WHERE ColumnName = N'EventSequence'
SELECT @ColDuration = ColumnName FROM #Column WHERE ColumnName = N'Duration'
SELECT @ColCPU = ColumnName FROM #Column WHERE ColumnName = N'CPU'
SELECT @ColReads = ColumnName FROM #Column WHERE ColumnName = N'Reads'
SELECT @ColWrites = ColumnName FROM #Column WHERE ColumnName = N'Writes'
SELECT @ColRowCounts = ColumnName FROM #Column WHERE ColumnName = N'RowCounts'
SELECT @ColDatabaseName = ColumnName FROM #Column WHERE ColumnName = N'DatabaseName'
SELECT @ColObjectName = ColumnName FROM #Column WHERE ColumnName = N'ObjectName'
SELECT @ColLoginName = ColumnName FROM #Column WHERE ColumnName = N'LoginName'
SELECT @ColHostName = ColumnName FROM #Column WHERE ColumnName = N'HostName'
SELECT @ColApplicationName = ColumnName FROM #Column WHERE ColumnName = N'ApplicationName'
SELECT @ColSPID = ColumnName FROM #Column WHERE ColumnName = N'SPID'
SELECT @ColTextData = ColumnName FROM #Column WHERE ColumnName = N'TextData'

SET @TextSource = N'TextData'
IF @ColTextData IS NULL
BEGIN
    SELECT @ColTextData = ColumnName FROM #Column WHERE ColumnName = N'QueryText'
    IF @ColTextData IS NOT NULL
        SET @TextSource = N'QueryText'
END

IF @ColStartTime IS NULL
BEGIN
    RAISERROR('Trace table %s has no StartTime column, so the process map cannot be built. Imported SQL Trace tables include StartTime.', 16, 1, @FullName)
    RETURN
END

IF @DatabaseName IS NOT NULL AND @ColDatabaseName IS NULL
BEGIN
    RAISERROR('Filter @DatabaseName was supplied, but %s has no DatabaseName column.', 16, 1, @FullName)
    RETURN
END

IF @ApplicationName IS NOT NULL AND @ColApplicationName IS NULL
BEGIN
    RAISERROR('Filter @ApplicationName was supplied, but %s has no ApplicationName column.', 16, 1, @FullName)
    RETURN
END

IF @LoginName IS NOT NULL AND @ColLoginName IS NULL
BEGIN
    RAISERROR('Filter @LoginName was supplied, but %s has no LoginName column.', 16, 1, @FullName)
    RETURN
END

IF @HostName IS NOT NULL AND @ColHostName IS NULL
BEGIN
    RAISERROR('Filter @HostName was supplied, but %s has no HostName column.', 16, 1, @FullName)
    RETURN
END

SET @HasReads = CASE WHEN @ColReads IS NULL THEN 0 ELSE 1 END
SET @HasWrites = CASE WHEN @ColWrites IS NULL THEN 0 ELSE 1 END
SET @HasRowCounts = CASE WHEN @ColRowCounts IS NULL THEN 0 ELSE 1 END
SET @HasCpu = CASE WHEN @ColCPU IS NULL THEN 0 ELSE 1 END
SET @HasEventClass = CASE WHEN @ColEventClass IS NULL THEN 0 ELSE 1 END

CREATE TABLE #TraceEvent
(
    EventSeq         int            NOT NULL IDENTITY(1, 1),
    EventSequence    bigint         NULL,
    EventClass       int            NULL,
    SessionKey       int            NULL,
    SPID             int            NULL,
    DatabaseName     nvarchar(128)  NULL,
    ApplicationName  nvarchar(128)  NULL,
    HostName         nvarchar(128)  NULL,
    LoginName        nvarchar(128)  NULL,
    ObjectName       nvarchar(128)  NULL,
    StartTime        datetime       NOT NULL,
    EndTime          datetime       NULL,
    DurationUs       bigint         NULL,
    CpuMs            bigint         NULL,
    Reads            bigint         NULL,
    Writes           bigint         NULL,
    RowCounts        bigint         NULL,
    TextData         nvarchar(max)  NULL,
    IsBoundary       bit            NOT NULL DEFAULT 0,
    UseForBusy       bit            NOT NULL DEFAULT 0,
    UseForDetail     bit            NOT NULL DEFAULT 0,
    RunNum           int            NULL,
    ProcessId        int            NULL,
    StatementKey     nvarchar(max)  NULL,
    PRIMARY KEY CLUSTERED (EventSeq)
)

SET @Where = N' WHERE t.' + QUOTENAME(@ColStartTime) + N' IS NOT NULL'
IF @StartTime IS NOT NULL
    SET @Where = @Where + N' AND t.' + QUOTENAME(@ColStartTime) + N' >= @StartTime'
IF @EndTime IS NOT NULL
    SET @Where = @Where + N' AND t.' + QUOTENAME(@ColStartTime) + N' <= @EndTime'
IF @DatabaseName IS NOT NULL
    SET @Where = @Where + N' AND t.' + QUOTENAME(@ColDatabaseName) + N' LIKE @DatabaseName'
IF @ApplicationName IS NOT NULL
    SET @Where = @Where + N' AND t.' + QUOTENAME(@ColApplicationName) + N' LIKE @ApplicationName'
IF @LoginName IS NOT NULL
    SET @Where = @Where + N' AND t.' + QUOTENAME(@ColLoginName) + N' LIKE @LoginName'
IF @HostName IS NOT NULL
    SET @Where = @Where + N' AND t.' + QUOTENAME(@ColHostName) + N' LIKE @HostName'

SET @OrderBy = N't.' + QUOTENAME(@ColStartTime)
IF @ColEventSequence IS NOT NULL
    SET @OrderBy = @OrderBy + N', t.' + QUOTENAME(@ColEventSequence)

SET @Sql = N'
INSERT INTO #TraceEvent
(
    EventSequence, EventClass, SPID, DatabaseName, ApplicationName, HostName, LoginName,
    ObjectName, StartTime, EndTime, DurationUs, CpuMs, Reads, Writes, RowCounts, TextData
)
SELECT
    EventSequence = ' + CASE WHEN @ColEventSequence IS NULL THEN N'CONVERT(bigint, NULL)'
                             ELSE N'TRY_CONVERT(bigint, t.' + QUOTENAME(@ColEventSequence) + N')' END + N',
    EventClass = ' + CASE WHEN @ColEventClass IS NULL THEN N'CONVERT(int, NULL)'
                          ELSE N'TRY_CONVERT(int, t.' + QUOTENAME(@ColEventClass) + N')' END + N',
    SPID = ' + CASE WHEN @ColSPID IS NULL THEN N'CONVERT(int, NULL)'
                    ELSE N'TRY_CONVERT(int, t.' + QUOTENAME(@ColSPID) + N')' END + N',
    DatabaseName = ' + CASE WHEN @ColDatabaseName IS NULL THEN N'CONVERT(nvarchar(128), NULL)'
                            ELSE N'CONVERT(nvarchar(128), LEFT(CONVERT(nvarchar(max), t.' + QUOTENAME(@ColDatabaseName) + N'), 128))' END + N',
    ApplicationName = ' + CASE WHEN @ColApplicationName IS NULL THEN N'CONVERT(nvarchar(128), NULL)'
                               ELSE N'CONVERT(nvarchar(128), LEFT(CONVERT(nvarchar(max), t.' + QUOTENAME(@ColApplicationName) + N'), 128))' END + N',
    HostName = ' + CASE WHEN @ColHostName IS NULL THEN N'CONVERT(nvarchar(128), NULL)'
                        ELSE N'CONVERT(nvarchar(128), LEFT(CONVERT(nvarchar(max), t.' + QUOTENAME(@ColHostName) + N'), 128))' END + N',
    LoginName = ' + CASE WHEN @ColLoginName IS NULL THEN N'CONVERT(nvarchar(128), NULL)'
                         ELSE N'CONVERT(nvarchar(128), LEFT(CONVERT(nvarchar(max), t.' + QUOTENAME(@ColLoginName) + N'), 128))' END + N',
    ObjectName = ' + CASE WHEN @ColObjectName IS NULL THEN N'CONVERT(nvarchar(128), NULL)'
                          ELSE N'CONVERT(nvarchar(128), LEFT(CONVERT(nvarchar(max), t.' + QUOTENAME(@ColObjectName) + N'), 128))' END + N',
    StartTime = CONVERT(datetime, t.' + QUOTENAME(@ColStartTime) + N'),
    EndTime = ' + CASE WHEN @ColEndTime IS NULL THEN N'CONVERT(datetime, NULL)'
                       ELSE N'TRY_CONVERT(datetime, t.' + QUOTENAME(@ColEndTime) + N')' END + N',
    DurationUs = ' + CASE WHEN @ColDuration IS NULL THEN N'CONVERT(bigint, NULL)'
                          ELSE N'TRY_CONVERT(bigint, t.' + QUOTENAME(@ColDuration) + N')' END + N',
    CpuMs = ' + CASE WHEN @ColCPU IS NULL THEN N'CONVERT(bigint, NULL)'
                     ELSE N'TRY_CONVERT(bigint, t.' + QUOTENAME(@ColCPU) + N')' END + N',
    Reads = ' + CASE WHEN @ColReads IS NULL THEN N'CONVERT(bigint, NULL)'
                     ELSE N'TRY_CONVERT(bigint, t.' + QUOTENAME(@ColReads) + N')' END + N',
    Writes = ' + CASE WHEN @ColWrites IS NULL THEN N'CONVERT(bigint, NULL)'
                      ELSE N'TRY_CONVERT(bigint, t.' + QUOTENAME(@ColWrites) + N')' END + N',
    RowCounts = ' + CASE WHEN @ColRowCounts IS NULL THEN N'CONVERT(bigint, NULL)'
                         ELSE N'TRY_CONVERT(bigint, t.' + QUOTENAME(@ColRowCounts) + N')' END + N',
    TextData = ' + CASE WHEN @ColTextData IS NULL THEN N'CONVERT(nvarchar(max), NULL)'
                        ELSE N'CONVERT(nvarchar(max), t.' + QUOTENAME(@ColTextData) + N')' END + N'
FROM ' + @FullName + N' AS t'
+ @Where + N'
ORDER BY ' + @OrderBy + N'
OPTION (RECOMPILE)
'

EXEC sys.sp_executesql
    @Sql,
    N'@StartTime datetime, @EndTime datetime, @DatabaseName nvarchar(128), @ApplicationName nvarchar(128), @LoginName nvarchar(128), @HostName nvarchar(128)',
    @StartTime = @StartTime,
    @EndTime = @EndTime,
    @DatabaseName = @DatabaseName,
    @ApplicationName = @ApplicationName,
    @LoginName = @LoginName,
    @HostName = @HostName

---------------------------------------------------------------------------------------------
-- EndTime is trusted when the trace supplied one. Duration is not used to invent an end
-- time for Audit Login / Audit Logout / ExistingConnection: logout Duration is how long
-- the session was connected, not how long a statement ran.
---------------------------------------------------------------------------------------------
UPDATE #TraceEvent
SET DurationUs = NULL
WHERE DurationUs < 0

UPDATE #TraceEvent
SET EndTime = DATEADD(second, CONVERT(int, DurationUs / 1000000), StartTime)
WHERE ISNULL(EventClass, -1) NOT IN (14, 15, 17)
  AND DurationUs >= 1000000
  AND DurationUs / 1000000 <= 2147483647
  AND (EndTime IS NULL OR EndTime <= StartTime)

UPDATE #TraceEvent
SET EndTime = DATEADD(millisecond, 1, StartTime)
WHERE EndTime IS NULL
  AND ISNULL(EventClass, -1) NOT IN (14, 15, 17)

UPDATE #TraceEvent
SET EndTime = StartTime
WHERE EndTime IS NULL OR EndTime < StartTime

UPDATE #TraceEvent
SET IsBoundary = CASE WHEN EventClass IN (14, 15, 17) THEN 1 ELSE 0 END

;WITH Ranked AS
(
    SELECT
        EventSeq,
        SessionKey = DENSE_RANK() OVER (
            ORDER BY SPID, ApplicationName, HostName, LoginName)
    FROM #TraceEvent
)
UPDATE e
SET SessionKey = r.SessionKey
FROM #TraceEvent AS e
INNER JOIN Ranked AS r
    ON r.EventSeq = e.EventSeq

CREATE NONCLUSTERED INDEX IX_TraceEvent_Session
    ON #TraceEvent (SessionKey, StartTime, EventSequence, EventSeq)
    INCLUDE (EndTime, EventClass, DurationUs, CpuMs, Reads, Writes, RowCounts, DatabaseName, ObjectName)

---------------------------------------------------------------------------------------------
-- A process run is one SPID + application + host + login.
-- Audit Login (14) starts a run and stays with the work that follows. The event
-- after Audit Logout (15) starts the next run. Logout stays with the work that
-- just finished, even if the session sat idle before disconnecting.
-- An idle gap longer than @GapSeconds between other events also starts a run,
-- because a SPID can be reused when login events were not captured, and because
-- one connection can sit idle between two batch jobs. @GapSeconds = 0 leaves
-- that rule off. The gap rule does not peel a login or a logout off the run.
-- Database is not part of the key: a job that changes database stays one process.
-- PrimaryDatabase is the database where that run spent the most busy time.
---------------------------------------------------------------------------------------------
;WITH Sequenced AS
(
    SELECT
        EventSeq,
        EventClass,
        StartTime,
        EndTime,
        SessionKey,
        PrevSeq = LAG(EventSeq) OVER (
            PARTITION BY SessionKey
            ORDER BY StartTime, EventSequence, EventSeq),
        PrevEnd = LAG(EndTime) OVER (
            PARTITION BY SessionKey
            ORDER BY StartTime, EventSequence, EventSeq),
        PrevClass = LAG(EventClass) OVER (
            PARTITION BY SessionKey
            ORDER BY StartTime, EventSequence, EventSeq)
    FROM #TraceEvent
),
Flagged AS
(
    SELECT
        EventSeq,
        SessionKey,
        StartTime,
        NewRun = CASE
                     WHEN PrevSeq IS NULL THEN 1
                     WHEN EventClass = 14 THEN 1
                     WHEN PrevClass = 15 THEN 1
                     WHEN @GapSeconds > 0
                      AND PrevEnd IS NOT NULL
                      AND StartTime > PrevEnd
                      AND DATEDIFF(second, PrevEnd, StartTime) > @GapSeconds
                      AND ISNULL(PrevClass, -1) NOT IN (14, 17)
                      AND ISNULL(EventClass, -1) <> 15 THEN 1
                     ELSE 0
                 END
    FROM Sequenced
),
Numbered AS
(
    SELECT
        EventSeq,
        RunNum = SUM(NewRun) OVER (
            PARTITION BY SessionKey
            ORDER BY StartTime, EventSeq
            ROWS UNBOUNDED PRECEDING)
    FROM Flagged
)
UPDATE e
SET RunNum = n.RunNum
FROM #TraceEvent AS e
INNER JOIN Numbered AS n
    ON n.EventSeq = e.EventSeq

---------------------------------------------------------------------------------------------
-- Busy time prefers the outer RPC/batch event so statement rows inside it are not added
-- again. Steps prefer the finest grain that exists for that run: statements, then
-- SP:Completed, then the outer RPC/batch. Mixing those grains in one step list would
-- show the procedure total beside every statement inside it.
---------------------------------------------------------------------------------------------
;WITH Grain AS
(
    SELECT
        SessionKey,
        RunNum,
        HasBatch = MAX(CASE WHEN EventClass IN (10, 12) THEN 1 ELSE 0 END),
        HasStmt = MAX(CASE WHEN EventClass IN (41, 45) THEN 1 ELSE 0 END),
        HasProc = MAX(CASE WHEN EventClass = 43 THEN 1 ELSE 0 END)
    FROM #TraceEvent
    GROUP BY SessionKey, RunNum
)
UPDATE e
SET UseForBusy = CASE
                     WHEN g.HasBatch = 1 AND e.EventClass IN (10, 12) THEN 1
                     WHEN g.HasBatch = 0 AND g.HasStmt = 1 AND e.EventClass IN (41, 45) THEN 1
                     WHEN g.HasBatch = 0 AND g.HasStmt = 0 AND g.HasProc = 1 AND e.EventClass = 43 THEN 1
                     WHEN g.HasBatch = 0 AND g.HasStmt = 0 AND g.HasProc = 0
                      AND ISNULL(e.EventClass, -1) NOT IN (14, 15, 17)
                      AND e.DurationUs IS NOT NULL THEN 1
                     ELSE 0
                 END,
    UseForDetail = CASE
                       WHEN g.HasStmt = 1 AND e.EventClass IN (41, 45) THEN 1
                       WHEN g.HasStmt = 0 AND g.HasProc = 1 AND e.EventClass = 43 THEN 1
                       WHEN g.HasStmt = 0 AND g.HasProc = 0 AND g.HasBatch = 1 AND e.EventClass IN (10, 12) THEN 1
                       WHEN g.HasStmt = 0 AND g.HasProc = 0 AND g.HasBatch = 0
                        AND ISNULL(e.EventClass, -1) NOT IN (14, 15, 17)
                        AND e.DurationUs IS NOT NULL THEN 1
                       ELSE 0
                   END
FROM #TraceEvent AS e
INNER JOIN Grain AS g
    ON g.SessionKey = e.SessionKey
   AND g.RunNum = e.RunNum

IF @MinDurationUs IS NOT NULL
BEGIN
    SELECT @SuppressedByDuration = COUNT(*)
    FROM #TraceEvent
    WHERE (UseForBusy = 1 OR UseForDetail = 1)
      AND (DurationUs IS NULL OR DurationUs < @MinDurationUs)

    UPDATE #TraceEvent
    SET UseForBusy = 0,
        UseForDetail = 0
    WHERE (UseForBusy = 1 OR UseForDetail = 1)
      AND (DurationUs IS NULL OR DurationUs < @MinDurationUs)
END

CREATE TABLE #Process
(
    ProcessId        int            NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    SessionKey       int            NOT NULL,
    RunNum           int            NOT NULL,
    SPID             int            NULL,
    ApplicationName  nvarchar(128)  NULL,
    HostName         nvarchar(128)  NULL,
    LoginName        nvarchar(128)  NULL,
    PrimaryDatabase  nvarchar(128)  NULL,
    Databases        nvarchar(1000) NULL,
    FirstStart       datetime       NOT NULL,
    LastEnd          datetime       NOT NULL,
    DisplayEnd       datetime       NOT NULL,
    ElapsedSeconds   decimal(18, 3) NULL,
    BusySeconds      decimal(18, 3) NULL,
    BusyPercent      decimal(9, 1)  NULL,
    CpuSeconds       decimal(18, 3) NULL,
    Reads            bigint         NULL,
    Writes           bigint         NULL,
    RowCounts        bigint         NULL,
    WorkEventCount   int            NULL,
    MainObject       nvarchar(128)  NULL,
    MainStatement    nvarchar(400)  NULL,
    MaxConcurrent    int            NULL,
    ProcessLabel     nvarchar(500)  NULL
)

INSERT INTO #Process
(
    SessionKey, RunNum, SPID, ApplicationName, HostName, LoginName,
    FirstStart, LastEnd, DisplayEnd, ElapsedSeconds, BusySeconds, CpuSeconds,
    Reads, Writes, RowCounts, WorkEventCount
)
SELECT
    SessionKey,
    RunNum,
    MIN(SPID),
    MIN(ApplicationName),
    MIN(HostName),
    MIN(LoginName),
    MIN(StartTime),
    MAX(EndTime),
    MAX(EndTime),
    CONVERT(decimal(18, 3), DATEDIFF(second, MIN(StartTime), MAX(EndTime))),
    CONVERT(decimal(18, 3), SUM(CASE WHEN UseForBusy = 1 THEN ISNULL(DurationUs, 0) ELSE 0 END) / 1000000.0),
    CASE
        WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), SUM(CASE WHEN UseForBusy = 1 THEN ISNULL(CpuMs, 0) ELSE 0 END) / 1000.0)
    END,
    CASE
        WHEN @HasReads = 1 THEN SUM(CASE WHEN UseForBusy = 1 THEN ISNULL(Reads, 0) ELSE 0 END)
    END,
    CASE
        WHEN @HasWrites = 1 THEN SUM(CASE WHEN UseForBusy = 1 THEN ISNULL(Writes, 0) ELSE 0 END)
    END,
    CASE
        WHEN @HasRowCounts = 1 THEN SUM(CASE WHEN UseForBusy = 1 THEN ISNULL(RowCounts, 0) ELSE 0 END)
    END,
    SUM(CASE WHEN UseForBusy = 1 THEN 1 ELSE 0 END)
FROM #TraceEvent
GROUP BY SessionKey, RunNum
ORDER BY MIN(StartTime), MIN(EventSeq)

UPDATE #Process
SET DisplayEnd = DATEADD(millisecond, 100, FirstStart)
WHERE DisplayEnd <= FirstStart

UPDATE p
SET BusyPercent = CONVERT(decimal(9, 1), p.BusySeconds * 100.0 / p.ElapsedSeconds)
FROM #Process AS p
WHERE p.ElapsedSeconds > 0

UPDATE e
SET ProcessId = p.ProcessId
FROM #TraceEvent AS e
INNER JOIN #Process AS p
    ON p.SessionKey = e.SessionKey
   AND p.RunNum = e.RunNum

;WITH DbRank AS
(
    SELECT
        ProcessId,
        DatabaseName,
        Rn = ROW_NUMBER() OVER (
            PARTITION BY ProcessId
            ORDER BY BusyUs DESC, Cnt DESC, DatabaseName)
    FROM
    (
        SELECT
            ProcessId,
            DatabaseName,
            BusyUs = SUM(CASE WHEN UseForBusy = 1 THEN ISNULL(DurationUs, 0) ELSE 0 END),
            Cnt = COUNT(*)
        FROM #TraceEvent
        WHERE DatabaseName IS NOT NULL
          AND DatabaseName <> N''
        GROUP BY ProcessId, DatabaseName
    ) AS d
)
UPDATE p
SET PrimaryDatabase = d.DatabaseName
FROM #Process AS p
INNER JOIN DbRank AS d
    ON d.ProcessId = p.ProcessId
   AND d.Rn = 1

UPDATE p
SET Databases = CONVERT(nvarchar(1000), LEFT(x.List, 1000))
FROM #Process AS p
CROSS APPLY
(
    SELECT List = STUFF((
        SELECT N', ' + d.DatabaseName
        FROM
        (
            SELECT DISTINCT e.DatabaseName
            FROM #TraceEvent AS e
            WHERE e.ProcessId = p.ProcessId
              AND e.DatabaseName IS NOT NULL
              AND e.DatabaseName <> N''
        ) AS d
        ORDER BY d.DatabaseName
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, N'')
) AS x

---------------------------------------------------------------------------------------------
-- Normalize detail text so parameter values do not split a repeated call into many steps.
-- The full TextData value is kept (ntext and nvarchar(max) sources included). The grouping
-- key is that whole normalized value, so two statements that share a long prefix and differ
-- later stay in different groups. MainStatement on the process row is the first 400
-- characters of the key. Very large statement text uses more tempdb.
-- Limits (this is not a SQL parser):
--   * Up to 100 single-quoted literals are replaced with ?. Doubled quotes inside a
--     literal ('it''s') are not understood and can cut the literal short.
--   * Digits are replaced, including digits that are part of an object name
--     (Load_2024 and Load_2025 become the same key).
--   * Block comments (/* */) are removed. Line comments (--) are not.
--   * When TextData is empty, ObjectName is used and is not digit-stripped.
--   * Replacing whitespace, quotes, comments, and digits shortens the key or leaves
--     it the same length. It does not grow.
---------------------------------------------------------------------------------------------
UPDATE #TraceEvent
SET StatementKey = TextData
WHERE UseForDetail = 1
  AND TextData IS NOT NULL

UPDATE #TraceEvent
SET StatementKey = REPLACE(REPLACE(REPLACE(REPLACE(StatementKey, CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' '), NCHAR(160), N' ')
WHERE UseForDetail = 1
  AND StatementKey IS NOT NULL

SET @Pass = 0
WHILE @Pass < 100
BEGIN
    UPDATE e
    SET StatementKey = STUFF(e.StatementKey, s.StartPos, q.EndPos - s.StartPos + 1, N'?')
    FROM #TraceEvent AS e
    CROSS APPLY (SELECT StartPos = CHARINDEX(N'''', e.StatementKey)) AS s
    CROSS APPLY (SELECT EndPos = CASE WHEN s.StartPos > 0 THEN CHARINDEX(N'''', e.StatementKey, s.StartPos + 1) ELSE 0 END) AS q
    WHERE e.UseForDetail = 1
      AND s.StartPos > 0
      AND q.EndPos > s.StartPos

    IF @@ROWCOUNT = 0
        BREAK
    SET @Pass = @Pass + 1
END

SET @Pass = 0
WHILE @Pass < 20
BEGIN
    UPDATE e
    SET StatementKey = STUFF(e.StatementKey, s.StartPos, q.EndPos - s.StartPos + 2, N' ')
    FROM #TraceEvent AS e
    CROSS APPLY (SELECT StartPos = CHARINDEX(N'/*', e.StatementKey)) AS s
    CROSS APPLY (SELECT EndPos = CASE WHEN s.StartPos > 0 THEN CHARINDEX(N'*/', e.StatementKey, s.StartPos + 2) ELSE 0 END) AS q
    WHERE e.UseForDetail = 1
      AND s.StartPos > 0
      AND q.EndPos > s.StartPos

    IF @@ROWCOUNT = 0
        BREAK
    SET @Pass = @Pass + 1
END

UPDATE #TraceEvent
SET StatementKey = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                   REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(StatementKey,
                   N'0', N'#'), N'1', N'#'), N'2', N'#'), N'3', N'#'), N'4', N'#'),
                   N'5', N'#'), N'6', N'#'), N'7', N'#'), N'8', N'#'), N'9', N'#')
WHERE UseForDetail = 1
  AND StatementKey LIKE N'%[0-9]%'

SET @Pass = 0
WHILE @Pass < 20
BEGIN
    UPDATE #TraceEvent
    SET StatementKey = REPLACE(StatementKey, N'##', N'#')
    WHERE UseForDetail = 1
      AND StatementKey LIKE N'%##%'

    IF @@ROWCOUNT = 0
        BREAK
    SET @Pass = @Pass + 1
END

UPDATE #TraceEvent
SET StatementKey = REPLACE(REPLACE(StatementKey, N'#', N'?'), N'N?', N'?')
WHERE UseForDetail = 1
  AND (StatementKey LIKE N'%#%' OR StatementKey LIKE N'%N?%')

SET @Pass = 0
WHILE @Pass < 30
BEGIN
    UPDATE #TraceEvent
    SET StatementKey = REPLACE(StatementKey, N'  ', N' ')
    WHERE UseForDetail = 1
      AND StatementKey LIKE N'%  %'

    IF @@ROWCOUNT = 0
        BREAK
    SET @Pass = @Pass + 1
END

UPDATE #TraceEvent
SET StatementKey = LTRIM(RTRIM(StatementKey))
WHERE UseForDetail = 1
  AND StatementKey IS NOT NULL

UPDATE #TraceEvent
SET StatementKey = CONVERT(nvarchar(max), LEFT(ObjectName, 400))
WHERE UseForDetail = 1
  AND (StatementKey IS NULL OR StatementKey = N'')
  AND ObjectName IS NOT NULL
  AND ObjectName <> N''

UPDATE #TraceEvent
SET StatementKey = N'(no text)'
WHERE UseForDetail = 1
  AND (StatementKey IS NULL OR StatementKey = N'')

;WITH Ranked AS
(
    SELECT
        ProcessId,
        StatementKey,
        Rn = ROW_NUMBER() OVER (
            PARTITION BY ProcessId
            ORDER BY BusyUs DESC, StatementKey)
    FROM
    (
        SELECT
            ProcessId,
            StatementKey,
            BusyUs = SUM(ISNULL(DurationUs, 0))
        FROM #TraceEvent
        WHERE UseForDetail = 1
        GROUP BY ProcessId, StatementKey
    ) AS s
)
UPDATE p
SET MainStatement = CONVERT(nvarchar(400), LEFT(r.StatementKey, 400))
FROM #Process AS p
INNER JOIN Ranked AS r
    ON r.ProcessId = p.ProcessId
   AND r.Rn = 1

;WITH Ranked AS
(
    SELECT
        ProcessId,
        ObjectName,
        Rn = ROW_NUMBER() OVER (
            PARTITION BY ProcessId
            ORDER BY BusyUs DESC, Cnt DESC, ObjectName)
    FROM
    (
        SELECT
            ProcessId,
            ObjectName,
            BusyUs = SUM(CASE WHEN UseForBusy = 1 THEN ISNULL(DurationUs, 0) ELSE 0 END),
            Cnt = COUNT(*)
        FROM #TraceEvent
        WHERE ObjectName IS NOT NULL
          AND ObjectName <> N''
        GROUP BY ProcessId, ObjectName
    ) AS s
)
UPDATE p
SET MainObject = r.ObjectName
FROM #Process AS p
INNER JOIN Ranked AS r
    ON r.ProcessId = p.ProcessId
   AND r.Rn = 1

UPDATE p
SET ProcessLabel = CONVERT(nvarchar(500), LEFT(
        N'SPID ' + ISNULL(CONVERT(nvarchar(11), p.SPID), N'?')
        + N' | ' + ISNULL(NULLIF(p.ApplicationName, N''), N'(no app)')
        + N' | ' + ISNULL(NULLIF(p.HostName, N''), N'(no host)')
        + N' | ' + ISNULL(NULLIF(p.LoginName, N''), N'(no login)')
        + CASE
              WHEN x.SessionRuns > 1 THEN N' | run ' + CONVERT(nvarchar(11), p.RunNum)
              ELSE N''
          END, 500))
FROM #Process AS p
INNER JOIN
(
    SELECT
        ProcessId,
        SessionRuns = COUNT(*) OVER (PARTITION BY SessionKey)
    FROM #Process
) AS x
    ON x.ProcessId = p.ProcessId

CREATE TABLE #Sweep
(
    SweepId  int      NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    SortTime datetime NOT NULL,
    Delta    int      NOT NULL,
    ActiveAt int      NULL
)

INSERT INTO #Sweep (SortTime, Delta)
SELECT FirstStart, 1 FROM #Process
UNION ALL
SELECT DisplayEnd, -1 FROM #Process

;WITH Ordered AS
(
    SELECT
        SweepId,
        ActiveAt = SUM(Delta) OVER (
            ORDER BY SortTime, Delta, SweepId
            ROWS UNBOUNDED PRECEDING)
    FROM #Sweep
)
UPDATE s
SET ActiveAt = o.ActiveAt
FROM #Sweep AS s
INNER JOIN Ordered AS o
    ON o.SweepId = s.SweepId

UPDATE p
SET MaxConcurrent = ISNULL(x.Mx, 1)
FROM #Process AS p
CROSS APPLY
(
    SELECT Mx = MAX(s.ActiveAt)
    FROM #Sweep AS s
    WHERE s.SortTime >= p.FirstStart
      AND s.SortTime < p.DisplayEnd
) AS x

CREATE NONCLUSTERED INDEX IX_TraceEvent_Busy
    ON #TraceEvent (UseForBusy, ProcessId, StartTime)
    INCLUDE (EndTime, DurationUs, CpuMs, Reads, Writes)

CREATE NONCLUSTERED INDEX IX_TraceEvent_Detail
    ON #TraceEvent (UseForDetail, ProcessId, StartTime, EventSequence, EventSeq)
    INCLUDE (EndTime, DurationUs, CpuMs, Reads, Writes, RowCounts, EventClass, ObjectName)

---------------------------------------------------------------------------------------------
-- Timeline buckets. Clock-aligned. Widened automatically past 2000 buckets.
-- CPU, reads, and writes are charged to the bucket where the work event started
-- so a long batch is not added again in every bucket it spans. BusyProcesses still
-- counts a process in every bucket its work overlaps.
---------------------------------------------------------------------------------------------
SELECT
    @TraceStart = MIN(StartTime),
    @TraceEnd = MAX(EndTime),
    @EventCount = COUNT(*)
FROM #TraceEvent

SELECT @ProcessCount = COUNT(*) FROM #Process

IF @TraceStart IS NOT NULL
BEGIN
    SET @AlignedStart = DATEADD(minute, (DATEDIFF(minute, 0, @TraceStart) / @BucketMinutes) * @BucketMinutes, 0)
    SET @SpanMinutes = DATEDIFF(minute, @AlignedStart, @TraceEnd)
    IF @SpanMinutes < 0
        SET @SpanMinutes = 0

    SET @UsedBucketMinutes = @BucketMinutes
    SET @BucketCount = (@SpanMinutes / @UsedBucketMinutes) + 1

    IF @BucketCount > 2000
    BEGIN
        SET @UsedBucketMinutes = (@SpanMinutes / 2000) + 1
        IF @UsedBucketMinutes < 1
            SET @UsedBucketMinutes = 1
        SET @AlignedStart = DATEADD(minute, (DATEDIFF(minute, 0, @TraceStart) / @UsedBucketMinutes) * @UsedBucketMinutes, 0)
        SET @SpanMinutes = DATEDIFF(minute, @AlignedStart, @TraceEnd)
        IF @SpanMinutes < 0
            SET @SpanMinutes = 0
        SET @BucketCount = (@SpanMinutes / @UsedBucketMinutes) + 1
        SET @BucketNote = N'Timeline bucket was widened from '
            + CONVERT(nvarchar(11), @BucketMinutes)
            + N' to '
            + CONVERT(nvarchar(11), @UsedBucketMinutes)
            + N' minutes so the timeline stays within 2000 buckets.'
    END
END
ELSE
BEGIN
    SET @UsedBucketMinutes = @BucketMinutes
    SET @BucketCount = 0
    SET @GanttMinutes = @BucketMinutes
    SET @GanttCount = 0
END

CREATE TABLE #Bucket
(
    BucketId    int      NOT NULL PRIMARY KEY,
    BucketStart datetime NOT NULL,
    BucketEnd   datetime NOT NULL
)

CREATE TABLE #BucketMetric
(
    BucketId         int            NOT NULL PRIMARY KEY,
    ActiveProcesses  int            NOT NULL,
    BusyProcesses    int            NOT NULL,
    CpuMs            bigint         NULL,
    Reads            bigint         NULL,
    Writes           bigint         NULL,
    ActiveList       nvarchar(max)  NULL
)

CREATE TABLE #GanttBucket
(
    BucketId    int      NOT NULL PRIMARY KEY,
    BucketStart datetime NOT NULL,
    BucketEnd   datetime NOT NULL
)

CREATE TABLE #GanttCell
(
    ProcessId int NOT NULL,
    BucketId  int NOT NULL,
    IsBusy    bit NOT NULL,
    PRIMARY KEY (ProcessId, BucketId)
)

IF @BucketCount > 0
BEGIN
    ;WITH
    d AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n)),
    nums AS
    (
        SELECT TOP (@BucketCount)
               rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
        FROM d AS a
        CROSS JOIN d AS b
        CROSS JOIN d AS c
        CROSS JOIN d AS e
    )
    INSERT INTO #Bucket (BucketId, BucketStart, BucketEnd)
    SELECT
        rn,
        DATEADD(minute, rn * @UsedBucketMinutes, @AlignedStart),
        DATEADD(minute, (rn + 1) * @UsedBucketMinutes, @AlignedStart)
    FROM nums
    ORDER BY rn

    INSERT INTO #BucketMetric (BucketId, ActiveProcesses, BusyProcesses, CpuMs, Reads, Writes)
    SELECT
        b.BucketId,
        ISNULL(a.ActiveProcesses, 0),
        ISNULL(u.BusyProcesses, 0),
        m.CpuMs,
        m.Reads,
        m.Writes
    FROM #Bucket AS b
    LEFT JOIN
    (
        SELECT
            b2.BucketId,
            ActiveProcesses = COUNT(*)
        FROM #Bucket AS b2
        INNER JOIN #Process AS p
            ON p.FirstStart < b2.BucketEnd
           AND p.DisplayEnd > b2.BucketStart
        GROUP BY b2.BucketId
    ) AS a
        ON a.BucketId = b.BucketId
    LEFT JOIN
    (
        SELECT
            b2.BucketId,
            BusyProcesses = COUNT(DISTINCT e.ProcessId)
        FROM #Bucket AS b2
        INNER JOIN #TraceEvent AS e
            ON e.UseForBusy = 1
           AND e.StartTime < b2.BucketEnd
           AND e.EndTime > b2.BucketStart
        GROUP BY b2.BucketId
    ) AS u
        ON u.BucketId = b.BucketId
    LEFT JOIN
    (
        SELECT
            b2.BucketId,
            CpuMs = SUM(ISNULL(e.CpuMs, 0)),
            Reads = SUM(ISNULL(e.Reads, 0)),
            Writes = SUM(ISNULL(e.Writes, 0))
        FROM #Bucket AS b2
        INNER JOIN #TraceEvent AS e
            ON e.UseForBusy = 1
           AND e.StartTime >= b2.BucketStart
           AND e.StartTime < b2.BucketEnd
        GROUP BY b2.BucketId
    ) AS m
        ON m.BucketId = b.BucketId

    UPDATE bm
    SET ActiveList = CASE
                         WHEN x.List IS NULL THEN NULL
                         WHEN LEN(x.List) > 2000 THEN CONVERT(nvarchar(max), LEFT(x.List, 2000)) + N'...'
                         ELSE x.List
                     END
    FROM #BucketMetric AS bm
    INNER JOIN #Bucket AS b
        ON b.BucketId = bm.BucketId
    CROSS APPLY
    (
        SELECT List = STUFF((
            SELECT N', ' + p.ProcessLabel
            FROM #Process AS p
            WHERE p.FirstStart < b.BucketEnd
              AND p.DisplayEnd > b.BucketStart
            ORDER BY p.FirstStart, p.ProcessId
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N'')
    ) AS x

    SET @GanttMinutes = @UsedBucketMinutes
    SET @GanttCount = @BucketCount

    IF @BucketCount > 100
    BEGIN
        SET @GanttMinutes = (@SpanMinutes / 100) + 1
        IF @GanttMinutes < 1
            SET @GanttMinutes = 1
        SET @GanttCount = (@SpanMinutes / @GanttMinutes) + 1
        WHILE @GanttCount > 100
        BEGIN
            SET @GanttMinutes = @GanttMinutes + 1
            SET @GanttCount = (@SpanMinutes / @GanttMinutes) + 1
        END
        SET @GanttNote = N'Gantt bars use '
            + CONVERT(nvarchar(11), @GanttMinutes)
            + N'-minute buckets so each bar stays within 100 characters. The timeline uses '
            + CONVERT(nvarchar(11), @UsedBucketMinutes)
            + N'-minute buckets.'
    END

    IF @GanttMinutes = @UsedBucketMinutes AND @GanttCount = @BucketCount
    BEGIN
        INSERT INTO #GanttBucket (BucketId, BucketStart, BucketEnd)
        SELECT BucketId, BucketStart, BucketEnd
        FROM #Bucket
    END
    ELSE
    BEGIN
        ;WITH
        d AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n)),
        nums AS
        (
            SELECT TOP (@GanttCount)
                   rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
            FROM d AS a
            CROSS JOIN d AS b
            CROSS JOIN d AS c
            CROSS JOIN d AS e
        )
        INSERT INTO #GanttBucket (BucketId, BucketStart, BucketEnd)
        SELECT
            rn,
            DATEADD(minute, rn * @GanttMinutes, @AlignedStart),
            DATEADD(minute, (rn + 1) * @GanttMinutes, @AlignedStart)
        FROM nums
        ORDER BY rn
    END

    INSERT INTO #GanttCell (ProcessId, BucketId, IsBusy)
    SELECT
        p.ProcessId,
        b.BucketId,
        IsBusy = CASE
                     WHEN EXISTS (
                         SELECT 1
                         FROM #TraceEvent AS e
                         WHERE e.ProcessId = p.ProcessId
                           AND e.UseForBusy = 1
                           AND e.StartTime < b.BucketEnd
                           AND e.EndTime > b.BucketStart
                     ) THEN 1
                     ELSE 0
                 END
    FROM #Process AS p
    INNER JOIN #GanttBucket AS b
        ON p.FirstStart < b.BucketEnd
       AND p.DisplayEnd > b.BucketStart
END

CREATE TABLE #EventName
(
    EventClass int            NOT NULL PRIMARY KEY,
    EventName  nvarchar(128)  NOT NULL
)

INSERT INTO #EventName (EventClass, EventName)
SELECT v.EventClass, v.EventName
FROM (VALUES
    (10,  N'RPC:Completed'),
    (11,  N'RPC:Starting'),
    (12,  N'SQL:BatchCompleted'),
    (13,  N'SQL:BatchStarting'),
    (14,  N'Audit Login'),
    (15,  N'Audit Logout'),
    (16,  N'Attention'),
    (17,  N'ExistingConnection'),
    (21,  N'ErrorLog'),
    (22,  N'ErrorLog'),
    (25,  N'Deadlock graph'),
    (33,  N'Exception'),
    (41,  N'SQL:StmtCompleted'),
    (42,  N'SQL:StmtStarting'),
    (43,  N'SP:Completed'),
    (44,  N'SP:Starting'),
    (45,  N'SP:StmtCompleted'),
    (46,  N'SP:StmtStarting'),
    (50,  N'SQLTransaction'),
    (137, N'Blocked process report'),
    (148, N'Deadlock graph'),
    (166, N'Hash warning')
) AS v(EventClass, EventName)
WHERE EXISTS (
    SELECT 1 FROM #TraceEvent AS e WHERE e.EventClass = v.EventClass
)

IF HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') = 1
BEGIN
    SET @EventNameSource = N'sys.trace_events'

    UPDATE n
    SET EventName = te.name
    FROM #EventName AS n
    INNER JOIN sys.trace_events AS te
        ON te.trace_event_id = n.EventClass

    INSERT INTO #EventName (EventClass, EventName)
    SELECT te.trace_event_id, te.name
    FROM sys.trace_events AS te
    WHERE EXISTS (SELECT 1 FROM #TraceEvent AS e WHERE e.EventClass = te.trace_event_id)
      AND NOT EXISTS (SELECT 1 FROM #EventName AS n WHERE n.EventClass = te.trace_event_id)
END

IF @StartTime IS NOT NULL
    SET @FilterNote = @FilterNote + N'StartTime >= ' + CONVERT(nvarchar(19), @StartTime, 120) + N'. '
IF @EndTime IS NOT NULL
    SET @FilterNote = @FilterNote + N'EndTime <= ' + CONVERT(nvarchar(19), @EndTime, 120) + N'. '
IF @DatabaseName IS NOT NULL
    SET @FilterNote = @FilterNote + N'DatabaseName LIKE ''' + REPLACE(@DatabaseName, N'''', N'''''') + N'''. '
IF @ApplicationName IS NOT NULL
    SET @FilterNote = @FilterNote + N'ApplicationName LIKE ''' + REPLACE(@ApplicationName, N'''', N'''''') + N'''. '
IF @LoginName IS NOT NULL
    SET @FilterNote = @FilterNote + N'LoginName LIKE ''' + REPLACE(@LoginName, N'''', N'''''') + N'''. '
IF @HostName IS NOT NULL
    SET @FilterNote = @FilterNote + N'HostName LIKE ''' + REPLACE(@HostName, N'''', N'''''') + N'''. '
IF @MinDurationUs IS NOT NULL
    SET @FilterNote = @FilterNote + N'Work shorter than ' + CONVERT(nvarchar(30), @MinDurationMs)
        + N' ms is left out of busy time and steps (' + CONVERT(nvarchar(11), @SuppressedByDuration) + N' events). '

IF @ColDuration IS NULL
    SET @FilterNote = @FilterNote + N'Duration column not in the trace table; busy time is 0. '
IF @HasEventClass = 0
    SET @FilterNote = @FilterNote + N'EventClass column not in the trace table; each non-empty duration is treated as work, so batch and statement rows would both count. '
IF @ColSPID IS NULL
    SET @FilterNote = @FilterNote + N'SPID column not in the trace table; sessions are grouped by application, host, and login only. '
IF @HasReads = 0
    SET @FilterNote = @FilterNote + N'Reads column not in the trace table. '
IF @HasWrites = 0
    SET @FilterNote = @FilterNote + N'Writes column not in the trace table. '
IF @HasCpu = 0
    SET @FilterNote = @FilterNote + N'CPU column not in the trace table. '
IF @HasRowCounts = 0
    SET @FilterNote = @FilterNote + N'RowCounts column not in the trace table. '
IF @TextSource = N'QueryText'
    SET @FilterNote = @FilterNote + N'Text taken from QueryText because TextData is not present. '
IF @ColTextData IS NULL
    SET @FilterNote = @FilterNote + N'No TextData or QueryText column; steps use ObjectName when it exists. '
IF @FilterNote = N''
    SET @FilterNote = N'No row filters.'

---------------------------------------------------------------------------------------------
-- Result sets
---------------------------------------------------------------------------------------------
IF @ReturnOverview = 1
BEGIN
    SELECT
        TraceTable            = @FullName,
        CapturedFrom          = @TraceStart,
        CapturedTo            = @TraceEnd,
        ElapsedSeconds        = CONVERT(decimal(18, 3), DATEDIFF(second, @TraceStart, @TraceEnd)),
        EventCount            = @EventCount,
        ProcessCount          = @ProcessCount,
        DistinctSpids         = (SELECT COUNT(DISTINCT SPID) FROM #TraceEvent),
        DistinctApplications  = (SELECT COUNT(DISTINCT ApplicationName) FROM #TraceEvent),
        DistinctHosts         = (SELECT COUNT(DISTINCT HostName) FROM #TraceEvent),
        DistinctLogins        = (SELECT COUNT(DISTINCT LoginName) FROM #TraceEvent),
        DistinctDatabases     = (SELECT COUNT(DISTINCT DatabaseName) FROM #TraceEvent),
        BusySeconds           = (SELECT CONVERT(decimal(18, 3), SUM(BusySeconds)) FROM #Process),
        BusyCpuSeconds        = CASE WHEN @HasCpu = 1 THEN (SELECT CONVERT(decimal(18, 3), SUM(CpuSeconds)) FROM #Process) END,
        BusyReads             = CASE WHEN @HasReads = 1 THEN (SELECT SUM(Reads) FROM #Process) END,
        BusyWrites            = CASE WHEN @HasWrites = 1 THEN (SELECT SUM(Writes) FROM #Process) END,
        BusyRowCounts         = CASE WHEN @HasRowCounts = 1 THEN (SELECT SUM(RowCounts) FROM #Process) END,
        BusyEventCount        = (SELECT SUM(WorkEventCount) FROM #Process),
        RequestedBucketMinutes = @RequestedBucket,
        BucketMinutes         = @UsedBucketMinutes,
        GanttBucketMinutes    = @GanttMinutes,
        GapSeconds            = @GapSeconds,
        TopN                  = @TopN,
        EventNameSource       = @EventNameSource,
        DurationNote          = N'Duration in the trace is microseconds (SQL Server 2005 and later). CPU is milliseconds. This report shows both in seconds.',
        BusyRule              = N'Per process, busy time is RPC:Completed and SQL:BatchCompleted (10, 12) when that run has them; otherwise statement events (41, 45); otherwise SP:Completed (43). Audit Login, Audit Logout, and ExistingConnection are never busy time. Logout duration is connection time, not work.',
        StepRule              = N'Per process, steps are statement events (41, 45) when that run has them; otherwise SP:Completed (43); otherwise the batch/RPC events. Consecutive identical normalized text is one step.',
        NormalizationNote     = N'Literals in quotes become ?. Digits become ?, including digits inside object names. The grouping key is the full statement text. The process MainStatement column shows the first 400 characters. Not a SQL parser.',
        ConcurrencyNote       = N'MaxConcurrent is the peak number of processes running at the same time during that run, including itself. 1 means nothing else overlapped. Timeline CPU/reads/writes are charged to the bucket where the work started.',
        BucketNote            = @BucketNote,
        GanttNote             = @GanttNote,
        FilterNote            = @FilterNote

    SELECT
        e.EventClass,
        EventName           = ISNULL(n.EventName, N'(unknown)'),
        EventCount          = COUNT(*),
        RawDurationSeconds  = CONVERT(decimal(18, 3), SUM(ISNULL(e.DurationUs, 0)) / 1000000.0),
        RawCpuSeconds       = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), SUM(ISNULL(e.CpuMs, 0)) / 1000.0) END,
        CountedInBusy       = MAX(CASE WHEN e.UseForBusy = 1 THEN 1 ELSE 0 END),
        CountedInSteps      = MAX(CASE WHEN e.UseForDetail = 1 THEN 1 ELSE 0 END)
    FROM #TraceEvent AS e
    LEFT JOIN #EventName AS n
        ON n.EventClass = e.EventClass
    GROUP BY e.EventClass, n.EventName
    ORDER BY COUNT(*) DESC, e.EventClass
END

IF @ReturnProcesses = 1
BEGIN
    SELECT
        p.ProcessId,
        p.FirstStart,
        p.LastEnd,
        p.ElapsedSeconds,
        p.BusySeconds,
        p.BusyPercent,
        p.CpuSeconds,
        p.Reads,
        p.Writes,
        p.RowCounts,
        p.WorkEventCount,
        p.MaxConcurrent,
        p.SPID,
        p.ApplicationName,
        p.HostName,
        p.LoginName,
        p.PrimaryDatabase,
        p.Databases,
        p.RunNum,
        p.MainObject,
        p.MainStatement,
        p.ProcessLabel
    FROM #Process AS p
    ORDER BY p.FirstStart, p.ProcessId
END

IF @ReturnSteps = 1
BEGIN
    ;WITH Detail AS
    (
        SELECT
            ProcessId,
            EventSeq,
            EventSequence,
            EventClass,
            StartTime,
            EndTime,
            DurationUs,
            CpuMs,
            Reads,
            Writes,
            RowCounts,
            StatementKey,
            TextData,
            ObjectName,
            PrevSeq = LAG(EventSeq) OVER (
                PARTITION BY ProcessId
                ORDER BY StartTime, EventSequence, EventSeq),
            PrevKey = LAG(StatementKey) OVER (
                PARTITION BY ProcessId
                ORDER BY StartTime, EventSequence, EventSeq)
        FROM #TraceEvent
        WHERE UseForDetail = 1
          AND ProcessId IS NOT NULL
    ),
    Marked AS
    (
        SELECT
            *,
            NewStep = CASE
                          WHEN PrevSeq IS NULL THEN 1
                          WHEN ISNULL(StatementKey, N'') <> ISNULL(PrevKey, N'') THEN 1
                          ELSE 0
                      END
        FROM Detail
    ),
    Numbered AS
    (
        SELECT
            *,
            StepNum = SUM(NewStep) OVER (
                PARTITION BY ProcessId
                ORDER BY StartTime, EventSequence, EventSeq
                ROWS UNBOUNDED PRECEDING)
        FROM Marked
    ),
    Stepped AS
    (
        SELECT
            *,
            SampleText = FIRST_VALUE(TextData) OVER (
                PARTITION BY ProcessId, StepNum
                ORDER BY StartTime, EventSequence, EventSeq),
            SampleObject = FIRST_VALUE(ObjectName) OVER (
                PARTITION BY ProcessId, StepNum
                ORDER BY StartTime, EventSequence, EventSeq),
            SampleClass = FIRST_VALUE(EventClass) OVER (
                PARTITION BY ProcessId, StepNum
                ORDER BY StartTime, EventSequence, EventSeq)
        FROM Numbered
    )
    SELECT
        p.ProcessId,
        s.StepNum,
        p.ProcessLabel,
        p.SPID,
        p.ApplicationName,
        FirstStart     = MIN(s.StartTime),
        LastEnd        = MAX(s.EndTime),
        Executions     = COUNT(*),
        BusySeconds    = CONVERT(decimal(18, 3), SUM(ISNULL(s.DurationUs, 0)) / 1000000.0),
        CpuSeconds     = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), SUM(ISNULL(s.CpuMs, 0)) / 1000.0) END,
        Reads          = CASE WHEN @HasReads = 1 THEN SUM(ISNULL(s.Reads, 0)) END,
        Writes         = CASE WHEN @HasWrites = 1 THEN SUM(ISNULL(s.Writes, 0)) END,
        RowCounts      = CASE WHEN @HasRowCounts = 1 THEN SUM(ISNULL(s.RowCounts, 0)) END,
        EventClass     = MAX(s.SampleClass),
        EventName      = MAX(n.EventName),
        StatementText  = MAX(s.StatementKey),
        SampleText     = MAX(s.SampleText),
        ObjectName     = MAX(s.SampleObject)
    FROM Stepped AS s
    INNER JOIN #Process AS p
        ON p.ProcessId = s.ProcessId
    LEFT JOIN #EventName AS n
        ON n.EventClass = s.SampleClass
    GROUP BY
        p.ProcessId, s.StepNum, p.ProcessLabel, p.SPID, p.ApplicationName, p.FirstStart
    ORDER BY p.FirstStart, p.ProcessId, s.StepNum
END

IF @ReturnTimeline = 1
BEGIN
    SELECT
        b.BucketStart,
        b.BucketEnd,
        BucketMinutes   = @UsedBucketMinutes,
        ActiveProcesses = ISNULL(m.ActiveProcesses, 0),
        BusyProcesses   = ISNULL(m.BusyProcesses, 0),
        CpuSeconds      = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), ISNULL(m.CpuMs, 0) / 1000.0) END,
        Reads           = CASE WHEN @HasReads = 1 THEN ISNULL(m.Reads, 0) END,
        Writes          = CASE WHEN @HasWrites = 1 THEN ISNULL(m.Writes, 0) END,
        ActiveProcessesList = ISNULL(m.ActiveList, N'')
    FROM #Bucket AS b
    LEFT JOIN #BucketMetric AS m
        ON m.BucketId = b.BucketId
    ORDER BY b.BucketStart
END

IF @ReturnGantt = 1
BEGIN
    SELECT
        p.ProcessId,
        p.ProcessLabel,
        p.FirstStart,
        p.LastEnd,
        p.BusySeconds,
        GanttBucketMinutes = @GanttMinutes,
        BarStartsAt        = (SELECT MIN(BucketStart) FROM #GanttBucket),
        BarBusyBuckets     = (SELECT COUNT(*) FROM #GanttCell AS c WHERE c.ProcessId = p.ProcessId AND c.IsBusy = 1),
        BarIdleBuckets     = (SELECT COUNT(*) FROM #GanttCell AS c WHERE c.ProcessId = p.ProcessId AND c.IsBusy = 0),
        Legend             = @BusyChar + N' busy   ' + @IdleChar + N' connected but idle   ' + @EmptyChar + N' outside the process',
        Bar                = (
            SELECT CASE
                       WHEN c.IsBusy = 1 THEN @BusyChar
                       WHEN c.ProcessId IS NOT NULL THEN @IdleChar
                       ELSE @EmptyChar
                   END
            FROM #GanttBucket AS b
            LEFT JOIN #GanttCell AS c
                ON c.BucketId = b.BucketId
               AND c.ProcessId = p.ProcessId
            ORDER BY b.BucketId
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)')
    FROM #Process AS p
    ORDER BY p.FirstStart, p.ProcessId

    SELECT @MermaidShown = COUNT(*) FROM #Process
    SET @MermaidNote = CASE
                           WHEN @ProcessCount = 0 THEN N'No processes to chart.'
                           ELSE N'Showing all ' + CONVERT(nvarchar(11), @ProcessCount) + N' processes.'
                       END

    IF @ProcessCount > 50
    BEGIN
        SELECT @MermaidShown = 50
        SET @MermaidNote = N'Showing top 50 of ' + CONVERT(nvarchar(11), @ProcessCount) + N' processes by busy time.'
    END

    CREATE TABLE #MermaidProcess
    (
        ProcessId int NOT NULL PRIMARY KEY
    )

    INSERT INTO #MermaidProcess (ProcessId)
    SELECT TOP (CASE WHEN @ProcessCount > 50 THEN 50 ELSE CASE WHEN @ProcessCount = 0 THEN 0 ELSE @ProcessCount END END) ProcessId
    FROM #Process
    ORDER BY BusySeconds DESC, FirstStart, ProcessId

    SELECT @MermaidShown = COUNT(*) FROM #MermaidProcess

    SELECT @MermaidBody = (
        SELECT
            NCHAR(10) + N'    ' + LEFT(lbl.TaskName, 120)
            + N' :p' + CONVERT(nvarchar(11), p.ProcessId)
            + N', ' + CONVERT(nvarchar(19), p.FirstStart, 120)
            + N', ' + CONVERT(nvarchar(19),
                CASE
                    WHEN p.DisplayEnd > p.FirstStart THEN p.DisplayEnd
                    ELSE DATEADD(second, 1, p.FirstStart)
                END, 120)
        FROM #MermaidProcess AS mp
        INNER JOIN #Process AS p
            ON p.ProcessId = mp.ProcessId
        CROSS APPLY
        (
            SELECT TaskName =
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    ISNULL(p.ProcessLabel, N'process'),
                    N':', N' -'), N'#', N''), N';', N','), N'"', N''), N'''', N''),
                    N',', N' '), N'|', N'/'), N'<', N''), N'>', N''), CHAR(10), N' ')
        ) AS lbl
        ORDER BY p.FirstStart, p.ProcessId
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)')

    SET @Mermaid =
        N'gantt' + NCHAR(10)
        + N'    title Trace process map - ' + REPLACE(ISNULL(@MermaidNote, N''), N':', N' -') + NCHAR(10)
        + N'    dateFormat YYYY-MM-DD HH:mm:ss' + NCHAR(10)
        + N'    axisFormat %H:%M' + NCHAR(10)
        + N'    section Processes'
        + ISNULL(@MermaidBody, N'')

    SELECT
        ProcessesInTrace    = @ProcessCount,
        ProcessesInDiagram  = @MermaidShown,
        MermaidNote         = @MermaidNote,
        GanttBucketMinutes  = @GanttMinutes,
        GanttNote           = @GanttNote,
        Legend              = @BusyChar + N' busy   ' + @IdleChar + N' connected but idle   ' + @EmptyChar + N' outside the process',
        MermaidGantt        = CASE WHEN @ProcessCount = 0 THEN NULL ELSE @Mermaid END
END

IF @ReturnTopStatements = 1
BEGIN
    ;WITH Agg AS
    (
        SELECT
            StatementKey,
            Executions       = COUNT(*),
            TotalDurationUs  = SUM(ISNULL(DurationUs, 0)),
            TotalCpuMs       = SUM(ISNULL(CpuMs, 0)),
            TotalReads       = SUM(ISNULL(Reads, 0)),
            TotalWrites      = SUM(ISNULL(Writes, 0)),
            TotalRowCounts   = SUM(ISNULL(RowCounts, 0)),
            FirstSeen        = MIN(StartTime),
            LastSeen         = MAX(StartTime),
            SampleText       = MAX(TextData),
            ObjectName       = MAX(ObjectName)
        FROM #TraceEvent
        WHERE UseForDetail = 1
        GROUP BY StatementKey
    ),
    TopAgg AS
    (
        SELECT TOP (@StmtTop) *
        FROM Agg
        ORDER BY TotalDurationUs DESC, Executions DESC, StatementKey
    )
    SELECT
        a.StatementText,
        a.SampleText,
        a.ObjectName,
        a.Executions,
        TotalSeconds    = CONVERT(decimal(18, 3), a.TotalDurationUs / 1000000.0),
        AvgSeconds      = CONVERT(decimal(18, 3), (a.TotalDurationUs / 1000000.0) / NULLIF(a.Executions, 0)),
        TotalCpuSeconds = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), a.TotalCpuMs / 1000.0) END,
        AvgCpuSeconds   = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), (a.TotalCpuMs / 1000.0) / NULLIF(a.Executions, 0)) END,
        TotalReads      = CASE WHEN @HasReads = 1 THEN a.TotalReads END,
        TotalWrites     = CASE WHEN @HasWrites = 1 THEN a.TotalWrites END,
        TotalRowCounts  = CASE WHEN @HasRowCounts = 1 THEN a.TotalRowCounts END,
        a.FirstSeen,
        a.LastSeen,
        ProcessCount    = (
            SELECT COUNT(DISTINCT e.ProcessId)
            FROM #TraceEvent AS e
            WHERE e.UseForDetail = 1
              AND ISNULL(e.StatementKey, N'') = ISNULL(a.StatementKey, N'')
        ),
        Processes       = LEFT(ISNULL(x.List, N''), 2000)
    FROM
    (
        SELECT
            StatementText = StatementKey,
            SampleText,
            ObjectName,
            Executions,
            TotalDurationUs,
            TotalCpuMs,
            TotalReads,
            TotalWrites,
            TotalRowCounts,
            FirstSeen,
            LastSeen,
            StatementKey
        FROM TopAgg
    ) AS a
    CROSS APPLY
    (
        SELECT List = STUFF((
            SELECT N', ' + p.ProcessLabel
            FROM
            (
                SELECT DISTINCT pr.ProcessLabel
                FROM #TraceEvent AS e
                INNER JOIN #Process AS pr
                    ON pr.ProcessId = e.ProcessId
                WHERE e.UseForDetail = 1
                  AND ISNULL(e.StatementKey, N'') = ISNULL(a.StatementKey, N'')
            ) AS p
            ORDER BY p.ProcessLabel
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N'')
    ) AS x
    ORDER BY a.TotalDurationUs DESC, a.Executions DESC, a.StatementText
END

GO

PRINT 'Procedure created successfully.'
GO
