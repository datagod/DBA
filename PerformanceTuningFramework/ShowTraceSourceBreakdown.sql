/*
  ShowTraceSourceBreakdown.sql
  Performance Tuning Framework

  Requires SQL Server 2012 (11.x) or later, and database compatibility level 110 or higher.

  Deploy to the tool database, then execute:
    EXEC dbo.ShowTraceSourceBreakdown
         @TraceTable = N'TraceLab.dbo.ImportedTrace'

    EXEC dbo.ShowTraceSourceBreakdown
         @TraceTable      = N'dbo.ImportedTrace',
         @StartTime       = '2026-10-08 01:00',
         @EndTime         = '2026-10-08 03:00',
         @ApplicationName = N'Nightly%',
         @GroupBy         = N'Application,Host',
         @BucketMinutes   = 15,
         @TopN            = 50

  Breaks an imported SQL Trace down by where the work came from: application,
  host, login, database, object, and the combination of those, plus which
  source dominates each time bucket.

  This is the companion to dbo.ShowTraceProcessMap. The process map shows
  runs, order, and overlap. This procedure shows who produced the busy time.
  Both use the same busy-event rule so a batch and the statements inside it
  are not added together. Queries/ShowDecodedTrace.sql is the row-level decode
  of the same kind of table.

  QueryText is accepted when TextData is absent, so dbo.PerformanceTraceResults
  can be passed as @TraceTable (filter by time if that table holds many traces).
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowTraceSourceBreakdown') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowTraceSourceBreakdown'
    DROP PROCEDURE dbo.ShowTraceSourceBreakdown
END
GO

PRINT 'Creating: ShowTraceSourceBreakdown'
GO

CREATE PROCEDURE dbo.ShowTraceSourceBreakdown
(
    @TraceTable          nvarchar(400) = NULL,          -- 1-, 2-, or 3-part imported trace table
    @StartTime           datetime      = NULL,          -- inclusive; filters on event StartTime
    @EndTime             datetime      = NULL,          -- inclusive; filters on event StartTime
    @DatabaseName        nvarchar(128) = NULL,          -- LIKE filter
    @ApplicationName     nvarchar(128) = NULL,          -- LIKE filter
    @LoginName           nvarchar(128) = NULL,          -- LIKE filter
    @HostName            nvarchar(128) = NULL,          -- LIKE filter
    @MinDurationMs       bigint        = NULL,          -- ignore shorter work
    @BucketMinutes       int           = 15,            -- source-by-time bucket size
    @TopN                int           = 50,            -- rows per breakdown; 0 = all
    @GroupBy             nvarchar(200) = NULL,          -- NULL or All, or a comma list of result sets
    @ReturnOverview      bit           = 1,
    @ReturnApplication   bit           = 1,
    @ReturnHost          bit           = 1,
    @ReturnLogin         bit           = 1,
    @ReturnDatabase      bit           = 1,
    @ReturnObject        bit           = 1,
    @ReturnCombined      bit           = 1,
    @ReturnBucket        bit           = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: October 8, 2026
-- Author:       William McEvoy
-- Description:  Breaks an imported SQL Trace down by application, host, login, database,
--               and object. Deploy to the tool database. The trace table may live in
--               another database on the same instance. Requires SQL Server 2012 (11.x)
--               or later and compatibility level 110 or higher (window functions, TRY_CONVERT).
--               Does not start, stop, or import a trace. Duration is microseconds and CPU
--               is milliseconds, which is how SQL Server 2005+ stores a trace; displayed
--               times are seconds. Does not draw the process map; use dbo.ShowTraceProcessMap
--               for runs, overlap, and the Gantt.
---------------------------------------------------------------------------------------------------
-- Version:      1.0
-- Date Revised: October 8, 2026
-- Author:       William McEvoy
-- Reason:       Initial release.
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
    @TextSource           nvarchar(20),
    @HasApplication       bit,
    @HasHost              bit,
    @HasLogin             bit,
    @HasDatabase          bit,
    @HasObject            bit,
    @HasSpid              bit,
    @HasReads             bit,
    @HasWrites            bit,
    @HasRowCounts         bit,
    @HasCpu               bit,
    @HasDuration          bit,
    @HasEventClass        bit,
    @HasText              bit,
    @MinDurationUs        bigint,
    @SuppressedByDuration int,
    @Pass                 int,
    @TraceStart           datetime,
    @TraceEnd             datetime,
    @AlignedStart         datetime,
    @BusyCount            int,
    @EventCount           int,
    @BusyUs               bigint,
    @BusyCpuMs            bigint,
    @StmtTop              int,
    @FilterNote           nvarchar(max),
    @BusyRule             nvarchar(max),
    @GroupWork            nvarchar(400),
    @Tok                  nvarchar(40),
    @Comma                int,
    @Err                  nvarchar(400),
    @UseGroupList         bit,
    @ListOverview         bit,
    @ListApplication      bit,
    @ListHost             bit,
    @ListLogin            bit,
    @ListDatabase         bit,
    @ListObject           bit,
    @ListCombined         bit,
    @ListBucket           bit,
    @ShowOverview         bit,
    @ShowApplication      bit,
    @ShowHost             bit,
    @ShowLogin            bit,
    @ShowDatabase         bit,
    @ShowObject           bit,
    @ShowCombined         bit,
    @ShowBucket           bit

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 11
BEGIN
    RAISERROR('ShowTraceSourceBreakdown requires SQL Server 2012 (11.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SELECT @CompatibilityLevel = compatibility_level
FROM sys.databases
WHERE name = DB_NAME()

IF @CompatibilityLevel < 110
BEGIN
    RAISERROR('ShowTraceSourceBreakdown requires database compatibility level 110 or higher. This database is %d. Window functions and TRY_CONVERT need 110.', 16, 1, @CompatibilityLevel)
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

IF @BucketMinutes IS NULL
    SET @BucketMinutes = 15
IF @BucketMinutes < 1
BEGIN
    RAISERROR('@BucketMinutes must be 1 or greater.', 16, 1)
    RETURN
END

IF @TopN IS NULL
    SET @TopN = 50
IF @TopN < 0
BEGIN
    RAISERROR('@TopN cannot be negative. Use 0 to return every source row.', 16, 1)
    RETURN
END

IF @ReturnOverview IS NULL SET @ReturnOverview = 1
IF @ReturnApplication IS NULL SET @ReturnApplication = 1
IF @ReturnHost IS NULL SET @ReturnHost = 1
IF @ReturnLogin IS NULL SET @ReturnLogin = 1
IF @ReturnDatabase IS NULL SET @ReturnDatabase = 1
IF @ReturnObject IS NULL SET @ReturnObject = 1
IF @ReturnCombined IS NULL SET @ReturnCombined = 1
IF @ReturnBucket IS NULL SET @ReturnBucket = 1

SET @UseGroupList = 0
SET @ListOverview = 0
SET @ListApplication = 0
SET @ListHost = 0
SET @ListLogin = 0
SET @ListDatabase = 0
SET @ListObject = 0
SET @ListCombined = 0
SET @ListBucket = 0

IF @GroupBy IS NOT NULL AND LTRIM(RTRIM(@GroupBy)) <> N'' AND UPPER(LTRIM(RTRIM(@GroupBy))) <> N'ALL'
BEGIN
    SET @GroupWork = REPLACE(REPLACE(REPLACE(UPPER(LTRIM(RTRIM(@GroupBy))), N' ', N''), NCHAR(9), N''), N';', N',') + N','
    WHILE @GroupWork <> N''
    BEGIN
        SET @Comma = CHARINDEX(N',', @GroupWork)
        SET @Tok = LEFT(@GroupWork, @Comma - 1)
        SET @GroupWork = SUBSTRING(@GroupWork, @Comma + 1, 400)

        IF @Tok = N''
            CONTINUE

        SET @Tok = CASE @Tok
                       WHEN N'APP' THEN N'APPLICATION'
                       WHEN N'APPLICATIONNAME' THEN N'APPLICATION'
                       WHEN N'HOSTNAME' THEN N'HOST'
                       WHEN N'LOGINNAME' THEN N'LOGIN'
                       WHEN N'DB' THEN N'DATABASE'
                       WHEN N'DATABASENAME' THEN N'DATABASE'
                       WHEN N'OBJECTNAME' THEN N'OBJECT'
                       WHEN N'TIME' THEN N'BUCKET'
                       WHEN N'TIMELINE' THEN N'BUCKET'
                       ELSE @Tok
                   END

        IF @Tok = N'ALL'
        BEGIN
            SET @UseGroupList = 0
            BREAK
        END

        IF @Tok NOT IN (N'OVERVIEW', N'APPLICATION', N'HOST', N'LOGIN', N'DATABASE', N'OBJECT', N'COMBINED', N'BUCKET')
        BEGIN
            SET @Err = N'Unknown @GroupBy value "' + @Tok + N'". Use Application, Host, Login, Database, Object, Combined, Bucket, Overview, or All.'
            RAISERROR(@Err, 16, 1)
            RETURN
        END

        SET @UseGroupList = 1
        IF @Tok = N'OVERVIEW' SET @ListOverview = 1
        IF @Tok = N'APPLICATION' SET @ListApplication = 1
        IF @Tok = N'HOST' SET @ListHost = 1
        IF @Tok = N'LOGIN' SET @ListLogin = 1
        IF @Tok = N'DATABASE' SET @ListDatabase = 1
        IF @Tok = N'OBJECT' SET @ListObject = 1
        IF @Tok = N'COMBINED' SET @ListCombined = 1
        IF @Tok = N'BUCKET' SET @ListBucket = 1
    END
END

SET @ShowOverview = CASE WHEN @ReturnOverview = 1 AND (@UseGroupList = 0 OR @ListOverview = 1) THEN 1 ELSE 0 END
SET @ShowApplication = CASE WHEN @ReturnApplication = 1 AND (@UseGroupList = 0 OR @ListApplication = 1) THEN 1 ELSE 0 END
SET @ShowHost = CASE WHEN @ReturnHost = 1 AND (@UseGroupList = 0 OR @ListHost = 1) THEN 1 ELSE 0 END
SET @ShowLogin = CASE WHEN @ReturnLogin = 1 AND (@UseGroupList = 0 OR @ListLogin = 1) THEN 1 ELSE 0 END
SET @ShowDatabase = CASE WHEN @ReturnDatabase = 1 AND (@UseGroupList = 0 OR @ListDatabase = 1) THEN 1 ELSE 0 END
SET @ShowObject = CASE WHEN @ReturnObject = 1 AND (@UseGroupList = 0 OR @ListObject = 1) THEN 1 ELSE 0 END
SET @ShowCombined = CASE WHEN @ReturnCombined = 1 AND (@UseGroupList = 0 OR @ListCombined = 1) THEN 1 ELSE 0 END
SET @ShowBucket = CASE WHEN @ReturnBucket = 1 AND (@UseGroupList = 0 OR @ListBucket = 1) THEN 1 ELSE 0 END

IF @ShowOverview = 0 AND @ShowApplication = 0 AND @ShowHost = 0 AND @ShowLogin = 0
   AND @ShowDatabase = 0 AND @ShowObject = 0 AND @ShowCombined = 0 AND @ShowBucket = 0
BEGIN
    RAISERROR('No result set is selected. @GroupBy and the @Return flags turned every output off.', 16, 1)
    RETURN
END

SET @MinDurationUs = CASE WHEN @MinDurationMs IS NULL THEN NULL ELSE @MinDurationMs * CONVERT(bigint, 1000) END
SET @StmtTop = CASE WHEN @TopN = 0 THEN 2147483647 ELSE @TopN END
SET @FilterNote = N''
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
    RAISERROR('Trace table %s has no StartTime column, so the source breakdown cannot be built. Imported SQL Trace tables include StartTime.', 16, 1, @FullName)
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

SET @HasApplication = CASE WHEN @ColApplicationName IS NULL THEN 0 ELSE 1 END
SET @HasHost = CASE WHEN @ColHostName IS NULL THEN 0 ELSE 1 END
SET @HasLogin = CASE WHEN @ColLoginName IS NULL THEN 0 ELSE 1 END
SET @HasDatabase = CASE WHEN @ColDatabaseName IS NULL THEN 0 ELSE 1 END
SET @HasObject = CASE WHEN @ColObjectName IS NULL THEN 0 ELSE 1 END
SET @HasSpid = CASE WHEN @ColSPID IS NULL THEN 0 ELSE 1 END
SET @HasReads = CASE WHEN @ColReads IS NULL THEN 0 ELSE 1 END
SET @HasWrites = CASE WHEN @ColWrites IS NULL THEN 0 ELSE 1 END
SET @HasRowCounts = CASE WHEN @ColRowCounts IS NULL THEN 0 ELSE 1 END
SET @HasCpu = CASE WHEN @ColCPU IS NULL THEN 0 ELSE 1 END
SET @HasDuration = CASE WHEN @ColDuration IS NULL THEN 0 ELSE 1 END
SET @HasEventClass = CASE WHEN @ColEventClass IS NULL THEN 0 ELSE 1 END
SET @HasText = CASE WHEN @ColTextData IS NULL THEN 0 ELSE 1 END

CREATE TABLE #TraceEvent
(
    EventSeq           int            NOT NULL IDENTITY(1, 1),
    EventSequence      bigint         NULL,
    EventClass         int            NULL,
    SessionKey         int            NULL,
    RunNum             int            NULL,
    SPID               int            NULL,
    DatabaseName       nvarchar(128)  NULL,
    ApplicationName    nvarchar(128)  NULL,
    HostName           nvarchar(128)  NULL,
    LoginName          nvarchar(128)  NULL,
    ObjectName         nvarchar(128)  NULL,
    DatabaseLabel      nvarchar(128)  NULL,
    ApplicationLabel   nvarchar(128)  NULL,
    HostLabel          nvarchar(128)  NULL,
    LoginLabel         nvarchar(128)  NULL,
    ObjectLabel        nvarchar(128)  NULL,
    StartTime          datetime       NOT NULL,
    DurationUs         bigint         NULL,
    CpuMs              bigint         NULL,
    Reads              bigint         NULL,
    Writes             bigint         NULL,
    RowCounts          bigint         NULL,
    TextData           nvarchar(max)  NULL,
    UseForBusy         bit            NOT NULL DEFAULT 0,
    StatementKey       nvarchar(max)  NULL,
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
    ObjectName, StartTime, DurationUs, CpuMs, Reads, Writes, RowCounts, TextData
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

UPDATE #TraceEvent
SET DurationUs = NULL
WHERE DurationUs < 0

UPDATE #TraceEvent
SET
    ApplicationLabel = CONVERT(nvarchar(128),
        CASE
            WHEN @HasApplication = 0 THEN N'(not in trace)'
            WHEN ApplicationName IS NULL OR ApplicationName = N'' THEN N'(blank)'
            ELSE ApplicationName
        END),
    HostLabel = CONVERT(nvarchar(128),
        CASE
            WHEN @HasHost = 0 THEN N'(not in trace)'
            WHEN HostName IS NULL OR HostName = N'' THEN N'(blank)'
            ELSE HostName
        END),
    LoginLabel = CONVERT(nvarchar(128),
        CASE
            WHEN @HasLogin = 0 THEN N'(not in trace)'
            WHEN LoginName IS NULL OR LoginName = N'' THEN N'(blank)'
            ELSE LoginName
        END),
    DatabaseLabel = CONVERT(nvarchar(128),
        CASE
            WHEN @HasDatabase = 0 THEN N'(not in trace)'
            WHEN DatabaseName IS NULL OR DatabaseName = N'' THEN N'(blank)'
            ELSE DatabaseName
        END),
    ObjectLabel = CONVERT(nvarchar(128),
        CASE
            WHEN @HasObject = 0 THEN N'(not in trace)'
            WHEN ObjectName IS NULL OR ObjectName = N'' THEN N'(no object)'
            ELSE ObjectName
        END)

---------------------------------------------------------------------------------------------
-- A session run is one SPID + application + host + login.
-- Audit Login (14) starts a run and stays with the work that follows. The event
-- after Audit Logout (15) starts the next run, so a reused SPID does not keep the
-- previous run's event grain. Idle-gap splitting is left to ShowTraceProcessMap.
-- Database is not part of the session: one connection can touch several databases.
---------------------------------------------------------------------------------------------
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

;WITH Sequenced AS
(
    SELECT
        EventSeq,
        EventClass,
        StartTime,
        SessionKey,
        PrevSeq = LAG(EventSeq) OVER (
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
-- Same busy-event rule as ShowTraceProcessMap. For each session run, count
-- RPC:Completed and SQL:BatchCompleted (10, 12) when that run has them; otherwise
-- statement events (41, 45); otherwise SP:Completed (43). Statement rows inside a
-- batch are not added again. Audit Logout duration is connection time, not work.
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
                 END
FROM #TraceEvent AS e
INNER JOIN Grain AS g
    ON g.SessionKey = e.SessionKey
   AND g.RunNum = e.RunNum

IF @MinDurationUs IS NOT NULL
BEGIN
    SELECT @SuppressedByDuration = COUNT(*)
    FROM #TraceEvent
    WHERE UseForBusy = 1
      AND (DurationUs IS NULL OR DurationUs < @MinDurationUs)

    UPDATE #TraceEvent
    SET UseForBusy = 0
    WHERE UseForBusy = 1
      AND (DurationUs IS NULL OR DurationUs < @MinDurationUs)
END

---------------------------------------------------------------------------------------------
-- Normalize busy text so the object breakdown can name an empty ObjectName by statement.
-- The full text is kept. Two statements that share a long prefix and differ later stay
-- apart. Replacing whitespace, quotes, comments, and digits shortens the key or leaves
-- it the same length. This is not a SQL parser.
---------------------------------------------------------------------------------------------
UPDATE #TraceEvent
SET StatementKey = TextData
WHERE UseForBusy = 1
  AND TextData IS NOT NULL

UPDATE #TraceEvent
SET StatementKey = REPLACE(REPLACE(REPLACE(REPLACE(StatementKey, CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' '), NCHAR(160), N' ')
WHERE UseForBusy = 1
  AND StatementKey IS NOT NULL

SET @Pass = 0
WHILE @Pass < 100
BEGIN
    UPDATE e
    SET StatementKey = STUFF(e.StatementKey, s.StartPos, q.EndPos - s.StartPos + 1, N'?')
    FROM #TraceEvent AS e
    CROSS APPLY (SELECT StartPos = CHARINDEX(N'''', e.StatementKey)) AS s
    CROSS APPLY (SELECT EndPos = CASE WHEN s.StartPos > 0 THEN CHARINDEX(N'''', e.StatementKey, s.StartPos + 1) ELSE 0 END) AS q
    WHERE e.UseForBusy = 1
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
    WHERE e.UseForBusy = 1
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
WHERE UseForBusy = 1
  AND StatementKey LIKE N'%[0-9]%'

SET @Pass = 0
WHILE @Pass < 20
BEGIN
    UPDATE #TraceEvent
    SET StatementKey = REPLACE(StatementKey, N'##', N'#')
    WHERE UseForBusy = 1
      AND StatementKey LIKE N'%##%'

    IF @@ROWCOUNT = 0
        BREAK
    SET @Pass = @Pass + 1
END

UPDATE #TraceEvent
SET StatementKey = REPLACE(REPLACE(StatementKey, N'#', N'?'), N'N?', N'?')
WHERE UseForBusy = 1
  AND (StatementKey LIKE N'%#%' OR StatementKey LIKE N'%N?%')

SET @Pass = 0
WHILE @Pass < 30
BEGIN
    UPDATE #TraceEvent
    SET StatementKey = REPLACE(StatementKey, N'  ', N' ')
    WHERE UseForBusy = 1
      AND StatementKey LIKE N'%  %'

    IF @@ROWCOUNT = 0
        BREAK
    SET @Pass = @Pass + 1
END

UPDATE #TraceEvent
SET StatementKey = LTRIM(RTRIM(StatementKey))
WHERE UseForBusy = 1
  AND StatementKey IS NOT NULL

UPDATE #TraceEvent
SET StatementKey = CONVERT(nvarchar(max), ObjectName)
WHERE UseForBusy = 1
  AND (StatementKey IS NULL OR StatementKey = N'')
  AND ObjectName IS NOT NULL
  AND ObjectName <> N''

UPDATE #TraceEvent
SET StatementKey = N'(no text)'
WHERE UseForBusy = 1
  AND (StatementKey IS NULL OR StatementKey = N'')

SELECT
    @TraceStart = MIN(StartTime),
    @TraceEnd = MAX(StartTime),
    @EventCount = COUNT(*)
FROM #TraceEvent

SELECT
    @BusyCount = COUNT(*),
    @BusyUs = SUM(ISNULL(DurationUs, 0)),
    @BusyCpuMs = SUM(ISNULL(CpuMs, 0))
FROM #TraceEvent
WHERE UseForBusy = 1

IF @TraceStart IS NOT NULL
    SET @AlignedStart = DATEADD(minute, (DATEDIFF(minute, 0, @TraceStart) / @BucketMinutes) * @BucketMinutes, 0)

IF @HasEventClass = 1
    SET @BusyRule = N'Per session run (SPID + application + host + login; Audit Login starts a run, and the event after Audit Logout starts the next), busy time is RPC:Completed and SQL:BatchCompleted (10, 12) when that run has them; otherwise statement events (41, 45); otherwise SP:Completed (43). Audit Login, Audit Logout, and ExistingConnection are never busy time. Logout duration is connection time, not work. Statement rows inside a batch are not added again.'
ELSE
    SET @BusyRule = N'EventClass column not in the trace table; each row with a duration is treated as work, so a batch and the statements inside it would both count.'

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
        + N' ms is left out (' + CONVERT(nvarchar(11), @SuppressedByDuration) + N' events). '
IF @HasDuration = 0
    SET @FilterNote = @FilterNote + N'Duration column not in the trace table; duration is 0. '
IF @HasCpu = 0
    SET @FilterNote = @FilterNote + N'CPU column not in the trace table. '
IF @HasReads = 0
    SET @FilterNote = @FilterNote + N'Reads column not in the trace table. '
IF @HasWrites = 0
    SET @FilterNote = @FilterNote + N'Writes column not in the trace table. '
IF @HasRowCounts = 0
    SET @FilterNote = @FilterNote + N'RowCounts column not in the trace table. '
IF @HasSpid = 0
    SET @FilterNote = @FilterNote + N'SPID column not in the trace table. '
IF @HasApplication = 0
    SET @FilterNote = @FilterNote + N'ApplicationName column not in the trace table. '
IF @HasHost = 0
    SET @FilterNote = @FilterNote + N'HostName column not in the trace table. '
IF @HasLogin = 0
    SET @FilterNote = @FilterNote + N'LoginName column not in the trace table. '
IF @HasDatabase = 0
    SET @FilterNote = @FilterNote + N'DatabaseName column not in the trace table. '
IF @HasObject = 0
    SET @FilterNote = @FilterNote + N'ObjectName column not in the trace table. '
IF @TextSource = N'QueryText'
    SET @FilterNote = @FilterNote + N'Text taken from QueryText because TextData is not present. '
IF @HasText = 0
    SET @FilterNote = @FilterNote + N'No TextData or QueryText column. '
IF @FilterNote = N''
    SET @FilterNote = N'No row filters.'

---------------------------------------------------------------------------------------------
-- Result sets. Percents use the busy total, so a breakdown sums to about 100 when @TopN
-- does not cut it. Times are seconds.
---------------------------------------------------------------------------------------------
IF @ShowOverview = 1
BEGIN
    SELECT
        TraceTable            = @FullName,
        CapturedFrom          = @TraceStart,
        CapturedTo            = @TraceEnd,
        ElapsedSeconds        = CONVERT(decimal(18, 3), DATEDIFF(second, @TraceStart, @TraceEnd)),
        EventCount            = @EventCount,
        BusyEventCount        = @BusyCount,
        BusySeconds           = CONVERT(decimal(18, 3), ISNULL(@BusyUs, 0) / 1000000.0),
        BusyCpuSeconds        = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), ISNULL(@BusyCpuMs, 0) / 1000.0) END,
        BusyReads             = CASE WHEN @HasReads = 1 THEN (SELECT SUM(ISNULL(Reads, 0)) FROM #TraceEvent WHERE UseForBusy = 1) END,
        BusyWrites            = CASE WHEN @HasWrites = 1 THEN (SELECT SUM(ISNULL(Writes, 0)) FROM #TraceEvent WHERE UseForBusy = 1) END,
        BusyRowCounts         = CASE WHEN @HasRowCounts = 1 THEN (SELECT SUM(ISNULL(RowCounts, 0)) FROM #TraceEvent WHERE UseForBusy = 1) END,
        DistinctSpids         = CASE WHEN @HasSpid = 1 THEN (SELECT COUNT(DISTINCT SPID) FROM #TraceEvent WHERE UseForBusy = 1) END,
        DistinctApplications  = CASE WHEN @HasApplication = 1 THEN (SELECT COUNT(DISTINCT ApplicationLabel) FROM #TraceEvent WHERE UseForBusy = 1) END,
        DistinctHosts         = CASE WHEN @HasHost = 1 THEN (SELECT COUNT(DISTINCT HostLabel) FROM #TraceEvent WHERE UseForBusy = 1) END,
        DistinctLogins        = CASE WHEN @HasLogin = 1 THEN (SELECT COUNT(DISTINCT LoginLabel) FROM #TraceEvent WHERE UseForBusy = 1) END,
        DistinctDatabases     = CASE WHEN @HasDatabase = 1 THEN (SELECT COUNT(DISTINCT DatabaseLabel) FROM #TraceEvent WHERE UseForBusy = 1) END,
        DistinctObjects       = CASE WHEN @HasObject = 1 THEN (SELECT COUNT(DISTINCT ObjectLabel) FROM #TraceEvent WHERE UseForBusy = 1) END,
        HasApplicationName    = @HasApplication,
        HasHostName           = @HasHost,
        HasLoginName          = @HasLogin,
        HasDatabaseName       = @HasDatabase,
        HasObjectName         = @HasObject,
        HasSPID               = @HasSpid,
        HasDuration           = @HasDuration,
        HasCPU                = @HasCpu,
        HasReads              = @HasReads,
        HasWrites             = @HasWrites,
        HasRowCounts          = @HasRowCounts,
        HasEventClass         = @HasEventClass,
        HasText               = @HasText,
        TopN                  = @TopN,
        BucketMinutes         = @BucketMinutes,
        TextSource            = @TextSource,
        DurationNote          = N'Duration in the trace is microseconds (SQL Server 2005 and later). CPU is milliseconds. This report shows both in seconds.',
        BusyRule              = @BusyRule,
        FilterNote            = @FilterNote
END

IF @ShowApplication = 1
BEGIN
    ;WITH Agg AS
    (
        SELECT
            ApplicationName = ApplicationLabel,
            EventCount      = COUNT(*),
            TotalUs         = SUM(ISNULL(DurationUs, 0)),
            MaxUs           = MAX(DurationUs),
            TotalCpuMs      = SUM(ISNULL(CpuMs, 0)),
            TotalReads      = SUM(ISNULL(Reads, 0)),
            TotalWrites     = SUM(ISNULL(Writes, 0)),
            TotalRowCounts  = SUM(ISNULL(RowCounts, 0)),
            FirstSeen       = MIN(StartTime),
            LastSeen        = MAX(StartTime),
            DistinctSpids   = COUNT(DISTINCT SPID)
        FROM #TraceEvent
        WHERE UseForBusy = 1
        GROUP BY ApplicationLabel
    ),
    Ranked AS
    (
        SELECT
            *,
            Rn = ROW_NUMBER() OVER (ORDER BY TotalUs DESC, EventCount DESC, ApplicationName)
        FROM Agg
    )
    SELECT
        ApplicationName,
        EventCount,
        TotalSeconds       = CONVERT(decimal(18, 3), TotalUs / 1000000.0),
        AvgSeconds         = CONVERT(decimal(18, 3), (TotalUs / 1000000.0) / NULLIF(EventCount, 0)),
        MaxSeconds         = CONVERT(decimal(18, 3), MaxUs / 1000000.0),
        CpuSeconds         = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), TotalCpuMs / 1000.0) END,
        Reads              = CASE WHEN @HasReads = 1 THEN TotalReads END,
        Writes             = CASE WHEN @HasWrites = 1 THEN TotalWrites END,
        RowCounts          = CASE WHEN @HasRowCounts = 1 THEN TotalRowCounts END,
        PercentOfDuration  = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(@BusyUs, 0)),
        PercentOfCpu       = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalCpuMs) / NULLIF(@BusyCpuMs, 0)) END,
        FirstSeen,
        LastSeen,
        DistinctSpids      = CASE WHEN @HasSpid = 1 THEN DistinctSpids END
    FROM Ranked
    WHERE Rn <= @StmtTop
    ORDER BY TotalUs DESC, EventCount DESC, ApplicationName
END

IF @ShowHost = 1
BEGIN
    ;WITH Agg AS
    (
        SELECT
            HostName       = HostLabel,
            EventCount     = COUNT(*),
            TotalUs        = SUM(ISNULL(DurationUs, 0)),
            MaxUs          = MAX(DurationUs),
            TotalCpuMs     = SUM(ISNULL(CpuMs, 0)),
            TotalReads     = SUM(ISNULL(Reads, 0)),
            TotalWrites    = SUM(ISNULL(Writes, 0)),
            TotalRowCounts = SUM(ISNULL(RowCounts, 0)),
            FirstSeen      = MIN(StartTime),
            LastSeen       = MAX(StartTime),
            DistinctSpids  = COUNT(DISTINCT SPID)
        FROM #TraceEvent
        WHERE UseForBusy = 1
        GROUP BY HostLabel
    ),
    Ranked AS
    (
        SELECT *, Rn = ROW_NUMBER() OVER (ORDER BY TotalUs DESC, EventCount DESC, HostName)
        FROM Agg
    )
    SELECT
        HostName,
        EventCount,
        TotalSeconds       = CONVERT(decimal(18, 3), TotalUs / 1000000.0),
        AvgSeconds         = CONVERT(decimal(18, 3), (TotalUs / 1000000.0) / NULLIF(EventCount, 0)),
        MaxSeconds         = CONVERT(decimal(18, 3), MaxUs / 1000000.0),
        CpuSeconds         = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), TotalCpuMs / 1000.0) END,
        Reads              = CASE WHEN @HasReads = 1 THEN TotalReads END,
        Writes             = CASE WHEN @HasWrites = 1 THEN TotalWrites END,
        RowCounts          = CASE WHEN @HasRowCounts = 1 THEN TotalRowCounts END,
        PercentOfDuration  = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(@BusyUs, 0)),
        PercentOfCpu       = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalCpuMs) / NULLIF(@BusyCpuMs, 0)) END,
        FirstSeen,
        LastSeen,
        DistinctSpids      = CASE WHEN @HasSpid = 1 THEN DistinctSpids END
    FROM Ranked
    WHERE Rn <= @StmtTop
    ORDER BY TotalUs DESC, EventCount DESC, HostName
END

IF @ShowLogin = 1
BEGIN
    ;WITH Agg AS
    (
        SELECT
            LoginName      = LoginLabel,
            EventCount     = COUNT(*),
            TotalUs        = SUM(ISNULL(DurationUs, 0)),
            MaxUs          = MAX(DurationUs),
            TotalCpuMs     = SUM(ISNULL(CpuMs, 0)),
            TotalReads     = SUM(ISNULL(Reads, 0)),
            TotalWrites    = SUM(ISNULL(Writes, 0)),
            TotalRowCounts = SUM(ISNULL(RowCounts, 0)),
            FirstSeen      = MIN(StartTime),
            LastSeen       = MAX(StartTime),
            DistinctSpids  = COUNT(DISTINCT SPID)
        FROM #TraceEvent
        WHERE UseForBusy = 1
        GROUP BY LoginLabel
    ),
    Ranked AS
    (
        SELECT *, Rn = ROW_NUMBER() OVER (ORDER BY TotalUs DESC, EventCount DESC, LoginName)
        FROM Agg
    )
    SELECT
        LoginName,
        EventCount,
        TotalSeconds       = CONVERT(decimal(18, 3), TotalUs / 1000000.0),
        AvgSeconds         = CONVERT(decimal(18, 3), (TotalUs / 1000000.0) / NULLIF(EventCount, 0)),
        MaxSeconds         = CONVERT(decimal(18, 3), MaxUs / 1000000.0),
        CpuSeconds         = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), TotalCpuMs / 1000.0) END,
        Reads              = CASE WHEN @HasReads = 1 THEN TotalReads END,
        Writes             = CASE WHEN @HasWrites = 1 THEN TotalWrites END,
        RowCounts          = CASE WHEN @HasRowCounts = 1 THEN TotalRowCounts END,
        PercentOfDuration  = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(@BusyUs, 0)),
        PercentOfCpu       = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalCpuMs) / NULLIF(@BusyCpuMs, 0)) END,
        FirstSeen,
        LastSeen,
        DistinctSpids      = CASE WHEN @HasSpid = 1 THEN DistinctSpids END
    FROM Ranked
    WHERE Rn <= @StmtTop
    ORDER BY TotalUs DESC, EventCount DESC, LoginName
END

IF @ShowDatabase = 1
BEGIN
    ;WITH Agg AS
    (
        SELECT
            DatabaseName   = DatabaseLabel,
            EventCount     = COUNT(*),
            TotalUs        = SUM(ISNULL(DurationUs, 0)),
            MaxUs          = MAX(DurationUs),
            TotalCpuMs     = SUM(ISNULL(CpuMs, 0)),
            TotalReads     = SUM(ISNULL(Reads, 0)),
            TotalWrites    = SUM(ISNULL(Writes, 0)),
            TotalRowCounts = SUM(ISNULL(RowCounts, 0)),
            FirstSeen      = MIN(StartTime),
            LastSeen       = MAX(StartTime),
            DistinctSpids  = COUNT(DISTINCT SPID)
        FROM #TraceEvent
        WHERE UseForBusy = 1
        GROUP BY DatabaseLabel
    ),
    Ranked AS
    (
        SELECT *, Rn = ROW_NUMBER() OVER (ORDER BY TotalUs DESC, EventCount DESC, DatabaseName)
        FROM Agg
    )
    SELECT
        DatabaseName,
        EventCount,
        TotalSeconds       = CONVERT(decimal(18, 3), TotalUs / 1000000.0),
        AvgSeconds         = CONVERT(decimal(18, 3), (TotalUs / 1000000.0) / NULLIF(EventCount, 0)),
        MaxSeconds         = CONVERT(decimal(18, 3), MaxUs / 1000000.0),
        CpuSeconds         = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), TotalCpuMs / 1000.0) END,
        Reads              = CASE WHEN @HasReads = 1 THEN TotalReads END,
        Writes             = CASE WHEN @HasWrites = 1 THEN TotalWrites END,
        RowCounts          = CASE WHEN @HasRowCounts = 1 THEN TotalRowCounts END,
        PercentOfDuration  = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(@BusyUs, 0)),
        PercentOfCpu       = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalCpuMs) / NULLIF(@BusyCpuMs, 0)) END,
        FirstSeen,
        LastSeen,
        DistinctSpids      = CASE WHEN @HasSpid = 1 THEN DistinctSpids END
    FROM Ranked
    WHERE Rn <= @StmtTop
    ORDER BY TotalUs DESC, EventCount DESC, DatabaseName
END

IF @ShowObject = 1
BEGIN
    ;WITH Base AS
    (
        SELECT
            ObjectLabel,
            GroupKey = CASE
                           WHEN @HasObject = 0 OR ObjectName IS NULL OR ObjectName = N''
                           THEN N'S|' + ISNULL(StatementKey, N'(no text)')
                           ELSE N'O|' + ObjectLabel
                       END,
            StatementKey = ISNULL(StatementKey, N'(no text)'),
            DurationUs,
            CpuMs,
            Reads,
            Writes,
            RowCounts,
            SPID,
            StartTime
        FROM #TraceEvent
        WHERE UseForBusy = 1
    ),
    Agg AS
    (
        SELECT
            GroupKey,
            ObjectName     = MAX(ObjectLabel),
            EventCount     = COUNT(*),
            TotalUs        = SUM(ISNULL(DurationUs, 0)),
            MaxUs          = MAX(DurationUs),
            TotalCpuMs     = SUM(ISNULL(CpuMs, 0)),
            TotalReads     = SUM(ISNULL(Reads, 0)),
            TotalWrites    = SUM(ISNULL(Writes, 0)),
            TotalRowCounts = SUM(ISNULL(RowCounts, 0)),
            FirstSeen      = MIN(StartTime),
            LastSeen       = MAX(StartTime),
            DistinctSpids  = COUNT(DISTINCT SPID)
        FROM Base
        GROUP BY GroupKey
    ),
    TopStmt AS
    (
        SELECT
            GroupKey,
            StatementKey,
            Rn = ROW_NUMBER() OVER (
                PARTITION BY GroupKey
                ORDER BY SUM(ISNULL(DurationUs, 0)) DESC, StatementKey)
        FROM Base
        GROUP BY GroupKey, StatementKey
    ),
    Ranked AS
    (
        SELECT
            a.ObjectName,
            StatementText = s.StatementKey,
            a.EventCount,
            a.TotalUs,
            a.MaxUs,
            a.TotalCpuMs,
            a.TotalReads,
            a.TotalWrites,
            a.TotalRowCounts,
            a.FirstSeen,
            a.LastSeen,
            a.DistinctSpids,
            Rn = ROW_NUMBER() OVER (ORDER BY a.TotalUs DESC, a.EventCount DESC, a.ObjectName, s.StatementKey)
        FROM Agg AS a
        INNER JOIN TopStmt AS s
            ON s.GroupKey = a.GroupKey
           AND s.Rn = 1
    )
    SELECT
        ObjectName,
        StatementText,
        EventCount,
        TotalSeconds       = CONVERT(decimal(18, 3), TotalUs / 1000000.0),
        AvgSeconds         = CONVERT(decimal(18, 3), (TotalUs / 1000000.0) / NULLIF(EventCount, 0)),
        MaxSeconds         = CONVERT(decimal(18, 3), MaxUs / 1000000.0),
        CpuSeconds         = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), TotalCpuMs / 1000.0) END,
        Reads              = CASE WHEN @HasReads = 1 THEN TotalReads END,
        Writes             = CASE WHEN @HasWrites = 1 THEN TotalWrites END,
        RowCounts          = CASE WHEN @HasRowCounts = 1 THEN TotalRowCounts END,
        PercentOfDuration  = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(@BusyUs, 0)),
        PercentOfCpu       = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalCpuMs) / NULLIF(@BusyCpuMs, 0)) END,
        FirstSeen,
        LastSeen,
        DistinctSpids      = CASE WHEN @HasSpid = 1 THEN DistinctSpids END
    FROM Ranked
    WHERE Rn <= @StmtTop
    ORDER BY TotalUs DESC, EventCount DESC, ObjectName, StatementText
END

IF @ShowCombined = 1
BEGIN
    ;WITH Agg AS
    (
        SELECT
            ApplicationName = ApplicationLabel,
            HostName        = HostLabel,
            LoginName       = LoginLabel,
            DatabaseName    = DatabaseLabel,
            EventCount      = COUNT(*),
            TotalUs         = SUM(ISNULL(DurationUs, 0)),
            MaxUs           = MAX(DurationUs),
            TotalCpuMs      = SUM(ISNULL(CpuMs, 0)),
            TotalReads      = SUM(ISNULL(Reads, 0)),
            TotalWrites     = SUM(ISNULL(Writes, 0)),
            TotalRowCounts  = SUM(ISNULL(RowCounts, 0)),
            FirstSeen       = MIN(StartTime),
            LastSeen        = MAX(StartTime),
            DistinctSpids   = COUNT(DISTINCT SPID)
        FROM #TraceEvent
        WHERE UseForBusy = 1
        GROUP BY ApplicationLabel, HostLabel, LoginLabel, DatabaseLabel
    ),
    Ranked AS
    (
        SELECT
            *,
            Rn = ROW_NUMBER() OVER (
                ORDER BY TotalUs DESC, EventCount DESC, ApplicationName, HostName, LoginName, DatabaseName)
        FROM Agg
    )
    SELECT
        ApplicationName,
        HostName,
        LoginName,
        DatabaseName,
        EventCount,
        TotalSeconds       = CONVERT(decimal(18, 3), TotalUs / 1000000.0),
        AvgSeconds         = CONVERT(decimal(18, 3), (TotalUs / 1000000.0) / NULLIF(EventCount, 0)),
        MaxSeconds         = CONVERT(decimal(18, 3), MaxUs / 1000000.0),
        CpuSeconds         = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), TotalCpuMs / 1000.0) END,
        Reads              = CASE WHEN @HasReads = 1 THEN TotalReads END,
        Writes             = CASE WHEN @HasWrites = 1 THEN TotalWrites END,
        RowCounts          = CASE WHEN @HasRowCounts = 1 THEN TotalRowCounts END,
        PercentOfDuration  = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(@BusyUs, 0)),
        PercentOfCpu       = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalCpuMs) / NULLIF(@BusyCpuMs, 0)) END,
        FirstSeen,
        LastSeen,
        DistinctSpids      = CASE WHEN @HasSpid = 1 THEN DistinctSpids END
    FROM Ranked
    WHERE Rn <= @StmtTop
    ORDER BY TotalUs DESC, EventCount DESC, ApplicationName, HostName, LoginName, DatabaseName
END

IF @ShowBucket = 1
BEGIN
    IF @TraceStart IS NULL
    BEGIN
        SELECT
            BucketStart            = CONVERT(datetime, NULL),
            BucketEnd              = CONVERT(datetime, NULL),
            RankInBucket           = CONVERT(int, NULL),
            ApplicationName        = CONVERT(nvarchar(128), NULL),
            EventCount             = CONVERT(int, NULL),
            TotalSeconds           = CONVERT(decimal(18, 3), NULL),
            AvgSeconds             = CONVERT(decimal(18, 3), NULL),
            MaxSeconds             = CONVERT(decimal(18, 3), NULL),
            CpuSeconds             = CONVERT(decimal(18, 3), NULL),
            Reads                  = CONVERT(bigint, NULL),
            Writes                 = CONVERT(bigint, NULL),
            RowCounts              = CONVERT(bigint, NULL),
            PercentOfBucketDuration = CONVERT(decimal(9, 1), NULL),
            PercentOfDuration      = CONVERT(decimal(9, 1), NULL),
            PercentOfCpu           = CONVERT(decimal(9, 1), NULL),
            FirstSeen              = CONVERT(datetime, NULL),
            LastSeen               = CONVERT(datetime, NULL),
            DistinctSpids          = CONVERT(int, NULL)
        WHERE 1 = 0
    END
    ELSE
    BEGIN
        ;WITH Base AS
        (
            SELECT
                BucketStart = DATEADD(
                    minute,
                    (DATEDIFF(minute, @AlignedStart, StartTime) / @BucketMinutes) * @BucketMinutes,
                    @AlignedStart),
                ApplicationName = ApplicationLabel,
                DurationUs,
                CpuMs,
                Reads,
                Writes,
                RowCounts,
                SPID,
                StartTime
            FROM #TraceEvent
            WHERE UseForBusy = 1
        ),
        Agg AS
        (
            SELECT
                BucketStart,
                ApplicationName,
                EventCount     = COUNT(*),
                TotalUs        = SUM(ISNULL(DurationUs, 0)),
                MaxUs          = MAX(DurationUs),
                TotalCpuMs     = SUM(ISNULL(CpuMs, 0)),
                TotalReads     = SUM(ISNULL(Reads, 0)),
                TotalWrites    = SUM(ISNULL(Writes, 0)),
                TotalRowCounts = SUM(ISNULL(RowCounts, 0)),
                FirstSeen      = MIN(StartTime),
                LastSeen       = MAX(StartTime),
                DistinctSpids  = COUNT(DISTINCT SPID)
            FROM Base
            GROUP BY BucketStart, ApplicationName
        ),
        Ranked AS
        (
            SELECT
                *,
                BucketUs = SUM(TotalUs) OVER (PARTITION BY BucketStart),
                RankInBucket = ROW_NUMBER() OVER (
                    PARTITION BY BucketStart
                    ORDER BY TotalUs DESC, EventCount DESC, ApplicationName)
            FROM Agg
        )
        SELECT
            BucketStart,
            BucketEnd              = DATEADD(minute, @BucketMinutes, BucketStart),
            RankInBucket,
            ApplicationName,
            EventCount,
            TotalSeconds           = CONVERT(decimal(18, 3), TotalUs / 1000000.0),
            AvgSeconds             = CONVERT(decimal(18, 3), (TotalUs / 1000000.0) / NULLIF(EventCount, 0)),
            MaxSeconds             = CONVERT(decimal(18, 3), MaxUs / 1000000.0),
            CpuSeconds             = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(18, 3), TotalCpuMs / 1000.0) END,
            Reads                  = CASE WHEN @HasReads = 1 THEN TotalReads END,
            Writes                 = CASE WHEN @HasWrites = 1 THEN TotalWrites END,
            RowCounts              = CASE WHEN @HasRowCounts = 1 THEN TotalRowCounts END,
            PercentOfBucketDuration = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(BucketUs, 0)),
            PercentOfDuration      = CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalUs) / NULLIF(@BusyUs, 0)),
            PercentOfCpu           = CASE WHEN @HasCpu = 1 THEN CONVERT(decimal(9, 1), 100.0 * CONVERT(decimal(38, 6), TotalCpuMs) / NULLIF(@BusyCpuMs, 0)) END,
            FirstSeen,
            LastSeen,
            DistinctSpids          = CASE WHEN @HasSpid = 1 THEN DistinctSpids END
        FROM Ranked
        WHERE RankInBucket <= @StmtTop
        ORDER BY BucketStart, RankInBucket
    END
END

GO

PRINT 'Procedure created successfully.'
GO
