

/*
  ShowQueryStoreReport.sql
  Performance Tuning Framework

  Deploy to the tool database, create QueryStoreAnalysis first, then execute:
    EXEC dbo.ShowQueryStoreReport @TargetDatabase = N'YourDatabase'

  Optional parameters:
    @TargetDatabase - database to analyze (default: current database)
    @TopN           - number of queries to include in the report detail (default 25)
    @MinExecutions  - minimum executions required to include a query (default 5)
    @SortBy         - DURATION | TOTAL | CPU | READS | EXECUTIONS
    @ReportWidth    - kept for backward compatibility; report layout is fixed at 120 characters
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ShowQueryStoreReport
(
    @TargetDatabase sysname      = NULL,
    @TopN           int          = 25,
    @MinExecutions  bigint       = 5,
    @SortBy         varchar(10)  = 'DURATION',
    @ReportWidth    tinyint      = 120
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Version-aware Query Store diagnostic report for a target database. Reads Query
--               Store catalog views from the target database, stores results in QueryStoreAnalysis,
--               and returns a fixed-width, screen-friendly text report.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion           tinyint,
    @ProductVersion         varchar(30),
    @ProductLevel           varchar(30),
    @Edition                varchar(64),
    @ServerName             sysname,
    @DatabaseName           sysname,
    @CompatibilityLevel       int,
    @TargetDatabaseId       int,
    @ReportTime             varchar(19),
    @Divider                varchar(120),
    @HeaderRule             varchar(120),
    @BlankLine              varchar(120),
    @QueryIdWidth           tinyint,
    @ExecWidth              tinyint,
    @AvgMsWidth             tinyint,
    @CpuMsWidth             tinyint,
    @ReadsWidth             tinyint,
    @PlanWidth              tinyint,
    @DateWidth              tinyint,
    @TextWidth              tinyint,
    @LineNo                 int,
    @SortByUpper            varchar(10),
    @AnalysisRunID          uniqueidentifier,
    @CaptureDate            datetime,
    @Sql                    nvarchar(max),
    @ActualState            nvarchar(60),
    @DesiredState           nvarchar(60),
    @CurrentStorageSizeMB   decimal(12, 2),
    @MaxStorageSizeMB       decimal(12, 2),
    @FlushIntervalSeconds   int,
    @IntervalLengthMinutes  int,
    @StaleQueryThreshold    int,
    @MaxPlansPerQuery       int,
    @CaptureMode            nvarchar(60),
    @CleanupMode            nvarchar(60),
    @TotalQueries           int,
    @TotalPlans             int,
    @ForcedPlans            int,
    @MultiPlanQueries       int,
    @CapturedQueries        int,
    @TotalExecutions        bigint,
    @QueryStoreReadable     bit

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

IF OBJECT_ID('dbo.QueryStoreAnalysis') IS NULL
BEGIN
    RAISERROR('Table dbo.QueryStoreAnalysis does not exist. Run QueryStoreAnalysis.sql in this database first.', 16, 1)
    RETURN
END

SET @ReportWidth = 120

IF @TopN < 1
    SET @TopN = 25

IF @MinExecutions < 1
    SET @MinExecutions = 1

SET @SortByUpper = UPPER(ISNULL(@SortBy, 'DURATION'))
IF @SortByUpper NOT IN ('DURATION', 'TOTAL', 'CPU', 'READS', 'EXECUTIONS')
    SET @SortByUpper = 'DURATION'

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 13
BEGIN
    RAISERROR('Query Store requires SQL Server 2016 (13.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SELECT @CompatibilityLevel = compatibility_level
  FROM sys.databases
 WHERE name = @TargetDatabase

IF @CompatibilityLevel < 130
BEGIN
    RAISERROR('Target database ''%s'' compatibility level %d is below 130. Query Store requires compatibility level 130 or higher.', 16, 1, @TargetDatabase, @CompatibilityLevel)
    RETURN
END

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ProductLevel   = CAST(SERVERPROPERTY('ProductLevel') AS varchar(30))
SET @Edition        = CAST(SERVERPROPERTY('Edition') AS varchar(64))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @DatabaseName   = @TargetDatabase
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @Divider        = REPLICATE('-', @ReportWidth)
SET @HeaderRule     = REPLICATE('=', @ReportWidth)
SET @BlankLine      = REPLICATE(' ', @ReportWidth)
SET @AnalysisRunID  = NEWID()
SET @CaptureDate    = GETDATE()

SET @QueryIdWidth = 9
SET @ExecWidth    = 8
SET @AvgMsWidth   = 7
SET @CpuMsWidth   = 7
SET @ReadsWidth   = 8
SET @PlanWidth    = 4
SET @DateWidth    = 5
SET @TextWidth    = 64

IF OBJECT_ID('tempdb..#QueryStats') IS NOT NULL
    DROP TABLE #QueryStats

CREATE TABLE #QueryStats
(
    SortKey             bigint          NOT NULL,
    QueryID             bigint          NOT NULL,
    QueryText           nvarchar(max)   NOT NULL,
    QueryTextShort      varchar(200)    NOT NULL,
    PlanCount           int             NOT NULL,
    IsForcedPlan        bit             NOT NULL,
    Executions          bigint          NOT NULL,
    AvgDurationUs       bigint          NOT NULL,
    AvgCpuUs            bigint          NOT NULL,
    AvgLogicalReads     bigint          NOT NULL,
    TotalDurationUs     bigint          NOT NULL,
    LastExecutionTime   datetime        NULL,
    LastUseDate         char(5)         NOT NULL
)

IF OBJECT_ID('tempdb..#Report') IS NOT NULL
    DROP TABLE #Report

CREATE TABLE #Report
(
    [LineNo]     int          NOT NULL,
    ReportLine   varchar(200) NOT NULL
)

SET @ActualState           = 'UNKNOWN'
SET @DesiredState          = 'UNKNOWN'
SET @CurrentStorageSizeMB  = 0
SET @MaxStorageSizeMB      = 0
SET @FlushIntervalSeconds  = 0
SET @IntervalLengthMinutes = 0
SET @StaleQueryThreshold   = 0
SET @MaxPlansPerQuery      = 0
SET @CaptureMode           = 'n/a'
SET @CleanupMode           = 'n/a'
SET @QueryStoreReadable    = 0

SET @Sql = N'
SELECT
    @ActualState           = actual_state_desc,
    @DesiredState          = desired_state_desc,
    @CurrentStorageSizeMB  = current_storage_size_mb,
    @MaxStorageSizeMB      = max_storage_size_mb,
    @FlushIntervalSeconds  = flush_interval_seconds,
    @IntervalLengthMinutes = interval_length_minutes,
    @StaleQueryThreshold   = stale_query_threshold_days,
    @MaxPlansPerQuery      = max_plans_per_query,
    @CaptureMode           = query_capture_mode_desc,
    @CleanupMode           = ' + CASE WHEN @MajorVersion >= 14
                                      THEN N'size_based_cleanup_mode_desc'
                                      ELSE N'''n/a'''
                                 END + N'
FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.database_query_store_options'

BEGIN TRY
    EXEC sys.sp_executesql
        @Sql,
        N'@ActualState nvarchar(60) OUTPUT,
          @DesiredState nvarchar(60) OUTPUT,
          @CurrentStorageSizeMB decimal(12, 2) OUTPUT,
          @MaxStorageSizeMB decimal(12, 2) OUTPUT,
          @FlushIntervalSeconds int OUTPUT,
          @IntervalLengthMinutes int OUTPUT,
          @StaleQueryThreshold int OUTPUT,
          @MaxPlansPerQuery int OUTPUT,
          @CaptureMode nvarchar(60) OUTPUT,
          @CleanupMode nvarchar(60) OUTPUT',
        @ActualState = @ActualState OUTPUT,
        @DesiredState = @DesiredState OUTPUT,
        @CurrentStorageSizeMB = @CurrentStorageSizeMB OUTPUT,
        @MaxStorageSizeMB = @MaxStorageSizeMB OUTPUT,
        @FlushIntervalSeconds = @FlushIntervalSeconds OUTPUT,
        @IntervalLengthMinutes = @IntervalLengthMinutes OUTPUT,
        @StaleQueryThreshold = @StaleQueryThreshold OUTPUT,
        @MaxPlansPerQuery = @MaxPlansPerQuery OUTPUT,
        @CaptureMode = @CaptureMode OUTPUT,
        @CleanupMode = @CleanupMode OUTPUT

    SET @QueryStoreReadable = CASE
                                  WHEN @ActualState IN ('READ_WRITE', 'READ_ONLY') THEN 1
                                  ELSE 0
                              END
END TRY
BEGIN CATCH
    SET @ActualState = 'UNAVAILABLE'
    SET @DesiredState = 'UNAVAILABLE'
    SET @QueryStoreReadable = 0
END CATCH

IF @QueryStoreReadable = 1
BEGIN
    SET @Sql = N'
    ;WITH QueryAgg AS
    (
        SELECT
            q.query_id,
            qt.query_sql_text,
            PlanCount = COUNT(DISTINCT p.plan_id),
            IsForcedPlan = MAX(CASE WHEN p.is_forced_plan = 1 THEN 1 ELSE 0 END),
            Executions = SUM(rs.count_executions),
            AvgDurationUs = CAST(SUM(rs.count_executions * rs.avg_duration)
                / NULLIF(SUM(rs.count_executions), 0) AS bigint),
            AvgCpuUs = CAST(SUM(rs.count_executions * rs.avg_cpu_time)
                / NULLIF(SUM(rs.count_executions), 0) AS bigint),
            AvgLogicalReads = CAST(SUM(rs.count_executions * rs.avg_logical_io_reads)
                / NULLIF(SUM(rs.count_executions), 0) AS bigint),
            TotalDurationUs = CAST(SUM(rs.count_executions * rs.avg_duration) AS bigint),
            LastExecutionTime = MAX(rs.last_execution_time)
        FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_query AS q
        INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_query_text AS qt
            ON q.query_text_id = qt.query_text_id
        INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_plan AS p
            ON q.query_id = p.query_id
        INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_runtime_stats AS rs
            ON p.plan_id = rs.plan_id
        WHERE q.is_internal_query = 0
        GROUP BY q.query_id, qt.query_sql_text
        HAVING SUM(rs.count_executions) >= @MinExecutions
    )
    INSERT INTO #QueryStats
    (
        SortKey,
        QueryID,
        QueryText,
        QueryTextShort,
        PlanCount,
        IsForcedPlan,
        Executions,
        AvgDurationUs,
        AvgCpuUs,
        AvgLogicalReads,
        TotalDurationUs,
        LastExecutionTime,
        LastUseDate
    )
    SELECT
        SortKey = CASE @SortByUpper
                      WHEN ''TOTAL''       THEN TotalDurationUs
                      WHEN ''CPU''         THEN AvgCpuUs
                      WHEN ''READS''       THEN AvgLogicalReads
                      WHEN ''EXECUTIONS''  THEN Executions
                      ELSE AvgDurationUs
                  END,
        QueryID,
        QueryText = query_sql_text,
        QueryTextShort = LEFT(
            REPLACE(REPLACE(REPLACE(query_sql_text, CHAR(13), '' ''), CHAR(10), '' ''), ''  '', '' ''),
            200),
        PlanCount,
        IsForcedPlan,
        Executions,
        AvgDurationUs,
        AvgCpuUs,
        AvgLogicalReads,
        TotalDurationUs,
        LastExecutionTime,
        LastUseDate = CASE
                          WHEN LastExecutionTime IS NULL THEN ''     ''
                          ELSE RIGHT(''0'' + CAST(MONTH(LastExecutionTime) AS varchar(2)), 2)
                               + ''-''
                               + RIGHT(''0'' + CAST(DAY(LastExecutionTime) AS varchar(2)), 2)
                      END
    FROM QueryAgg'

    EXEC sys.sp_executesql
        @Sql,
        N'@MinExecutions bigint, @SortByUpper varchar(10)',
        @MinExecutions = @MinExecutions,
        @SortByUpper = @SortByUpper

    SET @Sql = N'
    SELECT
        @TotalQueries = COUNT(DISTINCT q.query_id),
        @TotalPlans = COUNT(DISTINCT p.plan_id),
        @ForcedPlans = COUNT(DISTINCT CASE WHEN p.is_forced_plan = 1 THEN p.plan_id END),
        @TotalExecutions = ISNULL(SUM(rs.count_executions), 0)
    FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_query AS q
    INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_plan AS p
        ON q.query_id = p.query_id
    INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_runtime_stats AS rs
        ON p.plan_id = rs.plan_id
    WHERE q.is_internal_query = 0'

    EXEC sys.sp_executesql
        @Sql,
        N'@TotalQueries int OUTPUT,
          @TotalPlans int OUTPUT,
          @ForcedPlans int OUTPUT,
          @TotalExecutions bigint OUTPUT',
        @TotalQueries = @TotalQueries OUTPUT,
        @TotalPlans = @TotalPlans OUTPUT,
        @ForcedPlans = @ForcedPlans OUTPUT,
        @TotalExecutions = @TotalExecutions OUTPUT

    SELECT @MultiPlanQueries = COUNT(*)
      FROM #QueryStats
     WHERE PlanCount > 1

    SET @CapturedQueries = (SELECT COUNT(*) FROM #QueryStats)

    INSERT INTO dbo.QueryStoreAnalysis
    (
        AnalysisRunID,
        CaptureDate,
        ServerName,
        DatabaseName,
        ActualState,
        DesiredState,
        CurrentStorageSizeMB,
        MaxStorageSizeMB,
        QueryID,
        QueryText,
        PlanCount,
        IsForcedPlan,
        Executions,
        AvgDurationUs,
        AvgCpuUs,
        AvgLogicalReads,
        TotalDurationUs,
        LastExecutionTime,
        SortBy,
        TopN,
        MinExecutions
    )
    SELECT
        @AnalysisRunID,
        @CaptureDate,
        @ServerName,
        @TargetDatabase,
        @ActualState,
        @DesiredState,
        @CurrentStorageSizeMB,
        @MaxStorageSizeMB,
        q.QueryID,
        q.QueryText,
        q.PlanCount,
        q.IsForcedPlan,
        q.Executions,
        q.AvgDurationUs,
        q.AvgCpuUs,
        q.AvgLogicalReads,
        q.TotalDurationUs,
        q.LastExecutionTime,
        @SortByUpper,
        @TopN,
        @MinExecutions
    FROM #QueryStats AS q
END
ELSE
BEGIN
    SET @TotalQueries     = 0
    SET @TotalPlans       = 0
    SET @ForcedPlans      = 0
    SET @MultiPlanQueries = 0
    SET @CapturedQueries  = 0
    SET @TotalExecutions  = 0
END

SET @LineNo = 0

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(' QUERY STORE REPORT' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2,
       LEFT(' Database: ' + @DatabaseName
            + REPLICATE(' ', 2)
            + 'Server: ' + @ServerName
            + '  ' + @ReportTime + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 3,
       LEFT(' SQL Server ' + @ProductVersion + ' ' + @ProductLevel
            + '  |  compat: ' + CAST(@CompatibilityLevel AS varchar(10))
            + '  |  ' + LEFT(@Edition, 18) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 5, LEFT(' QUERY STORE CONFIGURATION' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 6, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 7,
       LEFT(' Actual state: ' + @ActualState
            + '  |  Desired: ' + @DesiredState + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 8,
       LEFT(' Storage: ' + CAST(@CurrentStorageSizeMB AS varchar(12)) + ' MB'
            + ' / ' + CAST(@MaxStorageSizeMB AS varchar(12)) + ' MB max'
            + '  |  Capture: ' + @CaptureMode + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 9,
       LEFT(' Flush: ' + CAST(@FlushIntervalSeconds AS varchar(10)) + ' sec'
            + '  |  Interval: ' + CAST(@IntervalLengthMinutes AS varchar(10)) + ' min'
            + '  |  Stale: ' + CAST(@StaleQueryThreshold AS varchar(10)) + ' days' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 10,
       LEFT(' Max plans/query: ' + CAST(@MaxPlansPerQuery AS varchar(10))
            + '  |  Cleanup: ' + @CleanupMode + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 11, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 12, LEFT(' SUMMARY' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 13,
       LEFT(' Queries: ' + CAST(@TotalQueries AS varchar(10))
            + '  |  Plans: ' + CAST(@TotalPlans AS varchar(10))
            + '  |  Forced plans: ' + CAST(@ForcedPlans AS varchar(10))
            + '  |  Multi-plan: ' + CAST(@MultiPlanQueries AS varchar(10)) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 14,
       LEFT(' Captured (>= ' + CAST(@MinExecutions AS varchar(12)) + ' execs): '
            + CAST(@CapturedQueries AS varchar(10))
            + '  |  Total executions: ' + CAST(@TotalExecutions AS varchar(15))
            + '  |  sort: ' + @SortByUpper + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 15, LEFT(@Divider, @ReportWidth)

IF @QueryStoreReadable = 0
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT @LineNo + 16,
           LEFT(' Query Store is not readable in the target database. Enable READ_WRITE or READ_ONLY state.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 17, LEFT(@HeaderRule, @ReportWidth)
END
ELSE IF NOT EXISTS (SELECT 1 FROM #QueryStats)
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT @LineNo + 16,
           LEFT(' No queries met the minimum execution threshold for this report.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 17, LEFT(@HeaderRule, @ReportWidth)
END
ELSE
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT @LineNo + 16,
           LEFT(' TOP ' + CAST(@TopN AS varchar(10)) + ' QUERIES' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 17, LEFT(@Divider, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 18,
           LEFT(
                  LEFT('QUERY_ID', @QueryIdWidth)
                + ' ' + LEFT('EXECS', @ExecWidth)
                + ' ' + LEFT('AVGMS', @AvgMsWidth)
                + ' ' + LEFT('CPUMS', @CpuMsWidth)
                + ' ' + LEFT('READS', @ReadsWidth)
                + ' ' + LEFT('PLN', @PlanWidth)
                + ' ' + LEFT('USED', @DateWidth)
                + ' ' + LEFT('QUERY_TEXT', @TextWidth),
                @ReportWidth)
    UNION ALL
    SELECT @LineNo + 19, LEFT(@Divider, @ReportWidth)

    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT
        ROW_NUMBER() OVER (ORDER BY q.SortKey DESC, q.QueryID) + 19,
        LEFT(
              LEFT(CAST(q.QueryID AS varchar(20)) + @BlankLine, @QueryIdWidth)
            + ' ' + RIGHT(REPLICATE(' ', @ExecWidth) + CASE
                    WHEN q.Executions >= 1000000000 THEN CAST(q.Executions / 1000000000 AS varchar(10)) + 'B'
                    WHEN q.Executions >= 1000000 THEN LTRIM(STR(q.Executions / 1000000.0, 4, 1)) + 'M'
                    WHEN q.Executions >= 10000 THEN CAST(q.Executions / 1000 AS varchar(10)) + 'K'
                    WHEN q.Executions >= 1000 THEN LTRIM(STR(q.Executions / 1000.0, 4, 1)) + 'K'
                    ELSE CAST(q.Executions AS varchar(10))
                END, @ExecWidth)
            + ' ' + RIGHT(REPLICATE(' ', @AvgMsWidth) + CASE
                    WHEN (q.AvgDurationUs / 1000.0) >= 10000 THEN CAST(CAST(q.AvgDurationUs / 1000000 AS bigint) AS varchar(10)) + 'K'
                    WHEN (q.AvgDurationUs / 1000.0) >= 1000 THEN LTRIM(STR(q.AvgDurationUs / 1000000.0, 4, 1)) + 'K'
                    ELSE LTRIM(STR(q.AvgDurationUs / 1000.0, 6, 1))
                END, @AvgMsWidth)
            + ' ' + RIGHT(REPLICATE(' ', @CpuMsWidth) + CASE
                    WHEN (q.AvgCpuUs / 1000.0) >= 10000 THEN CAST(CAST(q.AvgCpuUs / 1000000 AS bigint) AS varchar(10)) + 'K'
                    WHEN (q.AvgCpuUs / 1000.0) >= 1000 THEN LTRIM(STR(q.AvgCpuUs / 1000000.0, 4, 1)) + 'K'
                    ELSE LTRIM(STR(q.AvgCpuUs / 1000.0, 6, 1))
                END, @CpuMsWidth)
            + ' ' + RIGHT(REPLICATE(' ', @ReadsWidth) + CASE
                    WHEN q.AvgLogicalReads >= 1000000000 THEN CAST(q.AvgLogicalReads / 1000000000 AS varchar(10)) + 'B'
                    WHEN q.AvgLogicalReads >= 1000000 THEN LTRIM(STR(q.AvgLogicalReads / 1000000.0, 4, 1)) + 'M'
                    WHEN q.AvgLogicalReads >= 10000 THEN CAST(q.AvgLogicalReads / 1000 AS varchar(10)) + 'K'
                    WHEN q.AvgLogicalReads >= 1000 THEN LTRIM(STR(q.AvgLogicalReads / 1000.0, 4, 1)) + 'K'
                    ELSE CAST(q.AvgLogicalReads AS varchar(10))
                END, @ReadsWidth)
            + ' ' + RIGHT(REPLICATE(' ', @PlanWidth) + CAST(q.PlanCount AS varchar(10))
                + CASE WHEN q.IsForcedPlan = 1 THEN '*' ELSE '' END, @PlanWidth)
            + ' ' + LEFT(q.LastUseDate + @BlankLine, @DateWidth)
            + ' ' + LEFT(q.QueryTextShort + @BlankLine, @TextWidth),
            @ReportWidth)
      FROM (
          SELECT TOP (@TopN) *
            FROM #QueryStats
           ORDER BY SortKey DESC, QueryID
      ) AS q

    SELECT @LineNo = ISNULL(MAX([LineNo]), 19)
      FROM #Report

    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT @LineNo + 1, LEFT(@Divider, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 2, LEFT(' Legend: AVGMS/CPUMS in milliseconds. PLN=plan count. *=forced plan in store.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 3, LEFT(' Full query text and all captured queries are stored in QueryStoreAnalysis.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 4, LEFT(' Stored in QueryStoreAnalysis run: ' + CAST(@AnalysisRunID AS varchar(36)) + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 5, LEFT(@HeaderRule, @ReportWidth)
END

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

GO