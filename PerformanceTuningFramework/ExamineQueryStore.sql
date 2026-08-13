/*
  ExamineQueryStore.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.ExamineQueryStore @TargetDatabase = N'YourDatabase'

  Performs a deep Query Store analysis of a target database and returns:
    1) Summary         - configuration, volume, and finding counts
    2) Findings        - prioritized problems and opportunities
    3) TopQueries      - supporting workload detail for expensive queries

  Optional parameters:
    @TargetDatabase          - database to analyze (default: current database)
    @DaysBack                - lookback window on last_execution_time (default 7)
    @TopN                    - max findings per category and top-query rows (default 25)
    @MinExecutions           - minimum executions to include a query (default 5)
    @PlanVarianceFactor      - multi-plan avg-duration ratio that triggers a finding (default 2.0)
    @OutlierFactor           - max/avg duration ratio that triggers an outlier finding (default 10.0)
    @MinMissingIndexImpact   - minimum missing-index impact score to report (default 10000)
    @IncludeMissingIndexes   - include live missing-index DMV findings (default 1)
    @IncludeQueryText        - include short query text in findings and top queries (default 1)
    @ReturnResultSets        - return summary/findings/top-query result sets (default 1)

  Notes:
    - Requires SQL Server 2016 (13.x)+ and target compatibility level 130+.
    - Reads Query Store catalog views from the target via three-part names.
    - Missing-index recommendations come from sys.dm_db_missing_index_* (instance DMVs for the
      target database), not from Query Store plan XML; validate before creating indexes.
    - Procedure deployment is compatibility level 100 safe (no CREATE OR ALTER).
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
  Compatibility-safe replacement pattern.

  CREATE OR ALTER is intentionally not used so this script can deploy to a tool
  database running at compatibility level 100.
*/
IF OBJECT_ID(N'dbo.ExamineQueryStore', N'P') IS NULL
BEGIN
    EXEC
    (
        N'CREATE PROCEDURE dbo.ExamineQueryStore
          AS
          BEGIN
              SET NOCOUNT ON;
              RETURN 0;
          END;'
    );
END
GO

ALTER PROCEDURE dbo.ExamineQueryStore
(
    @TargetDatabase        sysname          = NULL,
    @DaysBack              int              = 7,
    @TopN                  int              = 25,
    @MinExecutions         bigint           = 5,
    @PlanVarianceFactor    decimal(9, 2)    = 2.00,
    @OutlierFactor         decimal(9, 2)    = 10.00,
    @MinMissingIndexImpact decimal(18, 2)   = 10000.00,
    @IncludeMissingIndexes bit              = 1,
    @IncludeQueryText      bit              = 1,
    @ReturnResultSets      bit              = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: August 13, 2026
-- Author:       Bill McEvoy
-- Description:  Deep Query Store analysis for a target database. Produces prioritized findings
--               for Query Store health, expensive queries, plan instability, failed executions,
--               forced-plan problems, wait categories, and missing-index opportunities.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion           tinyint,
    @ProductVersion         varchar(30),
    @Edition                varchar(64),
    @ServerName             sysname,
    @TargetDatabaseId       int,
    @QuotedDatabase         nvarchar(260),
    @CompatibilityLevel     int,
    @IsQueryStoreOn         bit,
    @CaptureDate            datetime,
    @CutoffTime             datetimeoffset(7),
    @Sql                    nvarchar(max),
    @ActualState            nvarchar(60),
    @DesiredState           nvarchar(60),
    @ReadonlyReason         int,
    @CurrentStorageSizeMB   decimal(12, 2),
    @MaxStorageSizeMB       decimal(12, 2),
    @StorageUsedPct         decimal(9, 2),
    @FlushIntervalSeconds   int,
    @IntervalLengthMinutes  int,
    @StaleQueryThreshold    int,
    @MaxPlansPerQuery       int,
    @CaptureMode            nvarchar(60),
    @CleanupMode            nvarchar(60),
    @WaitStatsCaptureMode   nvarchar(60),
    @QueryStoreReadable     bit,
    @TotalQueries           int,
    @TotalPlans             int,
    @ForcedPlans            int,
    @MultiPlanQueries       int,
    @CapturedQueries        int,
    @TotalExecutions        bigint,
    @FailedExecutions       bigint,
    @FindingCount           int,
    @CriticalCount          int,
    @WarningCount           int,
    @InfoCount              int,
    @Note                   nvarchar(400)

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)
SET @QuotedDatabase   = QUOTENAME(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

IF @DaysBack IS NULL OR @DaysBack < 1
    SET @DaysBack = 7

IF @DaysBack > 3650
    SET @DaysBack = 3650

IF @TopN IS NULL OR @TopN < 1
    SET @TopN = 25

IF @TopN > 500
    SET @TopN = 500

IF @MinExecutions IS NULL OR @MinExecutions < 1
    SET @MinExecutions = 1

IF @PlanVarianceFactor IS NULL OR @PlanVarianceFactor < 1.0
    SET @PlanVarianceFactor = 2.00

IF @OutlierFactor IS NULL OR @OutlierFactor < 2.0
    SET @OutlierFactor = 10.00

IF @MinMissingIndexImpact IS NULL OR @MinMissingIndexImpact < 0
    SET @MinMissingIndexImpact = 10000.00

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 13
BEGIN
    RAISERROR('Query Store requires SQL Server 2016 (13.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SELECT
    @CompatibilityLevel = d.compatibility_level,
    @IsQueryStoreOn     = d.is_query_store_on
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId

IF @CompatibilityLevel < 130
BEGIN
    RAISERROR(
        'Target database ''%s'' compatibility level %d is below 130. Query Store requires compatibility level 130 or higher.',
        16, 1, @TargetDatabase, @CompatibilityLevel)
    RETURN
END

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @Edition        = CAST(SERVERPROPERTY('Edition') AS varchar(64))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @CaptureDate    = GETDATE()
SET @CutoffTime     = DATEADD(day, -@DaysBack, SYSDATETIMEOFFSET())

---------------------------------------------------------------------------------------------------
-- Working tables
---------------------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Findings') IS NOT NULL
    DROP TABLE #Findings

CREATE TABLE #Findings
(
    FindingID        int             NOT NULL IDENTITY(1, 1),
    PriorityScore    int             NOT NULL,
    Severity         tinyint         NOT NULL,  -- 3 = Critical, 2 = Warning, 1 = Info
    SeverityLabel    varchar(10)     NOT NULL,
    Category         varchar(40)     NOT NULL,
    ObjectName       nvarchar(500)   NULL,
    QueryID          bigint          NULL,
    PlanID           bigint          NULL,
    FindingDetail    nvarchar(max)   NOT NULL,
    SuggestedAction  nvarchar(max)   NULL,
    MetricNumeric    decimal(28, 4)  NULL,
    MetricLabel      varchar(60)     NULL,
    QueryTextShort   nvarchar(400)   NULL
)

IF OBJECT_ID('tempdb..#QueryAgg') IS NOT NULL
    DROP TABLE #QueryAgg

CREATE TABLE #QueryAgg
(
    QueryID             bigint          NOT NULL PRIMARY KEY,
    QueryTextID         bigint          NULL,
    ObjectID            bigint          NULL,
    ObjectName          nvarchar(500)   NULL,
    QueryHash           varbinary(8)    NULL,
    PlanCount           int             NOT NULL,
    ForcedPlanCount     int             NOT NULL,
    ForceFailureCount   bigint          NOT NULL,
    LastForceFailure    nvarchar(128)   NULL,
    Executions          bigint          NOT NULL,
    FailedExecutions    bigint          NOT NULL,
    TotalDurationUs     float           NOT NULL,
    TotalCpuUs          float           NOT NULL,
    TotalLogicalReads   float           NOT NULL,
    TotalLogicalWrites  float           NOT NULL,
    TotalPhysicalReads  float           NOT NULL,
    AvgDurationUs       float           NOT NULL,
    AvgCpuUs            float           NOT NULL,
    AvgLogicalReads     float           NOT NULL,
    AvgPhysicalReads    float           NOT NULL,
    MaxDurationUs       float           NOT NULL,
    MaxCpuUs            float           NOT NULL,
    FirstExecutionTime  datetimeoffset(7) NULL,
    LastExecutionTime   datetimeoffset(7) NULL,
    QueryTextShort      nvarchar(400)   NULL
)

IF OBJECT_ID('tempdb..#PlanAgg') IS NOT NULL
    DROP TABLE #PlanAgg

CREATE TABLE #PlanAgg
(
    QueryID         bigint NOT NULL,
    PlanID          bigint NOT NULL,
    IsForcedPlan    bit    NOT NULL,
    Executions      bigint NOT NULL,
    AvgDurationUs   float  NOT NULL,
    AvgCpuUs        float  NOT NULL,
    AvgLogicalReads float  NOT NULL,
    MaxDurationUs   float  NOT NULL,
    PRIMARY KEY (QueryID, PlanID)
)

IF OBJECT_ID('tempdb..#WaitAgg') IS NOT NULL
    DROP TABLE #WaitAgg

CREATE TABLE #WaitAgg
(
    WaitCategory        nvarchar(60)  NOT NULL,
    TotalQueryWaitMs    float         NOT NULL,
    TotalExecutionCount bigint        NOT NULL,
    AvgQueryWaitMs      float         NOT NULL
)

---------------------------------------------------------------------------------------------------
-- Query Store configuration
---------------------------------------------------------------------------------------------------
SET @ActualState           = N'UNKNOWN'
SET @DesiredState          = N'UNKNOWN'
SET @ReadonlyReason        = NULL
SET @CurrentStorageSizeMB  = 0
SET @MaxStorageSizeMB      = 0
SET @StorageUsedPct        = NULL
SET @FlushIntervalSeconds  = 0
SET @IntervalLengthMinutes = 0
SET @StaleQueryThreshold   = 0
SET @MaxPlansPerQuery      = 0
SET @CaptureMode           = N'n/a'
SET @CleanupMode           = N'n/a'
SET @WaitStatsCaptureMode  = N'n/a'
SET @QueryStoreReadable    = 0
SET @Note                  = NULL

IF ISNULL(@IsQueryStoreOn, 0) = 0
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        1000, 3, 'Critical', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Query Store is not enabled (sys.databases.is_query_store_on = 0). No runtime history is available for deep analysis.',
        N'ALTER DATABASE ' + @QuotedDatabase + N' SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);'
        + N' Then configure MAX_STORAGE_SIZE_MB, INTERVAL_LENGTH_MINUTES, and QUERY_CAPTURE_MODE for the workload.',
        0, 'QueryStoreEnabled', NULL
    )
    GOTO ReturnResults
END

SET @Sql = N'
SELECT
    @ActualState           = qso.actual_state_desc,
    @DesiredState          = qso.desired_state_desc,
    @ReadonlyReason        = qso.readonly_reason,
    @CurrentStorageSizeMB  = qso.current_storage_size_mb,
    @MaxStorageSizeMB      = qso.max_storage_size_mb,
    @FlushIntervalSeconds  = qso.flush_interval_seconds,
    @IntervalLengthMinutes = qso.interval_length_minutes,
    @StaleQueryThreshold   = qso.stale_query_threshold_days,
    @MaxPlansPerQuery      = qso.max_plans_per_query,
    @CaptureMode           = qso.query_capture_mode_desc,
    @CleanupMode           = ' + CASE WHEN @MajorVersion >= 14
                                      THEN N'qso.size_based_cleanup_mode_desc'
                                      ELSE N'''n/a'''
                                 END + N',
    @WaitStatsCaptureMode  = ' + CASE WHEN @MajorVersion >= 14
                                      THEN N'qso.wait_stats_capture_mode_desc'
                                      ELSE N'''n/a'''
                                 END + N'
FROM ' + @QuotedDatabase + N'.sys.database_query_store_options AS qso'

BEGIN TRY
    EXEC sys.sp_executesql
        @Sql,
        N'@ActualState nvarchar(60) OUTPUT,
          @DesiredState nvarchar(60) OUTPUT,
          @ReadonlyReason int OUTPUT,
          @CurrentStorageSizeMB decimal(12, 2) OUTPUT,
          @MaxStorageSizeMB decimal(12, 2) OUTPUT,
          @FlushIntervalSeconds int OUTPUT,
          @IntervalLengthMinutes int OUTPUT,
          @StaleQueryThreshold int OUTPUT,
          @MaxPlansPerQuery int OUTPUT,
          @CaptureMode nvarchar(60) OUTPUT,
          @CleanupMode nvarchar(60) OUTPUT,
          @WaitStatsCaptureMode nvarchar(60) OUTPUT',
        @ActualState = @ActualState OUTPUT,
        @DesiredState = @DesiredState OUTPUT,
        @ReadonlyReason = @ReadonlyReason OUTPUT,
        @CurrentStorageSizeMB = @CurrentStorageSizeMB OUTPUT,
        @MaxStorageSizeMB = @MaxStorageSizeMB OUTPUT,
        @FlushIntervalSeconds = @FlushIntervalSeconds OUTPUT,
        @IntervalLengthMinutes = @IntervalLengthMinutes OUTPUT,
        @StaleQueryThreshold = @StaleQueryThreshold OUTPUT,
        @MaxPlansPerQuery = @MaxPlansPerQuery OUTPUT,
        @CaptureMode = @CaptureMode OUTPUT,
        @CleanupMode = @CleanupMode OUTPUT,
        @WaitStatsCaptureMode = @WaitStatsCaptureMode OUTPUT

    SET @QueryStoreReadable = CASE
                                  WHEN @ActualState IN (N'READ_WRITE', N'READ_ONLY') THEN 1
                                  ELSE 0
                              END
END TRY
BEGIN CATCH
    SET @ActualState = N'UNAVAILABLE'
    SET @DesiredState = N'UNAVAILABLE'
    SET @QueryStoreReadable = 0
    SET @Note = ERROR_MESSAGE()
END CATCH

IF @MaxStorageSizeMB > 0
    SET @StorageUsedPct = CONVERT(decimal(9, 2), @CurrentStorageSizeMB * 100.0 / @MaxStorageSizeMB)

---------------------------------------------------------------------------------------------------
-- Configuration / health findings
---------------------------------------------------------------------------------------------------
IF @QueryStoreReadable = 0
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        990, 3, 'Critical', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Query Store is not readable. ActualState=' + ISNULL(@ActualState, N'?')
        + N', DesiredState=' + ISNULL(@DesiredState, N'?')
        + CASE WHEN @Note IS NOT NULL THEN N'. Error: ' + @Note ELSE N'' END,
        N'Investigate Query Store state. Typical fix: ALTER DATABASE ' + @QuotedDatabase
        + N' SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);',
        NULL, 'ActualState', NULL
    )
    GOTO ReturnResults
END

IF @ActualState = N'READ_ONLY'
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        950, 3, 'Critical', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Query Store is READ_ONLY. New runtime stats are not being captured.'
        + N' ReadonlyReason=' + ISNULL(CAST(@ReadonlyReason AS nvarchar(20)), N'n/a')
        + N' (1=db read-only, 2=db single-user, 65536=size limit, others=see docs).'
        + N' Storage=' + CAST(@CurrentStorageSizeMB AS nvarchar(20)) + N'/'
        + CAST(@MaxStorageSizeMB AS nvarchar(20)) + N' MB'
        + CASE WHEN @StorageUsedPct IS NOT NULL
               THEN N' (' + CAST(@StorageUsedPct AS nvarchar(20)) + N'%)'
               ELSE N''
          END + N'.',
        N'If size-limited: increase MAX_STORAGE_SIZE_MB and/or enable size-based cleanup, then set OPERATION_MODE = READ_WRITE.'
        + N' Example: ALTER DATABASE ' + @QuotedDatabase
        + N' SET QUERY_STORE (OPERATION_MODE = READ_WRITE, MAX_STORAGE_SIZE_MB = 2000, SIZE_BASED_CLEANUP_MODE = AUTO);',
        @StorageUsedPct, 'StorageUsedPct', NULL
    )
END

IF @StorageUsedPct IS NOT NULL AND @StorageUsedPct >= 90
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        CASE WHEN @StorageUsedPct >= 95 THEN 920 ELSE 820 END,
        CASE WHEN @StorageUsedPct >= 95 THEN 3 ELSE 2 END,
        CASE WHEN @StorageUsedPct >= 95 THEN 'Critical' ELSE 'Warning' END,
        'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Query Store storage is ' + CAST(@StorageUsedPct AS nvarchar(20)) + N'% full ('
        + CAST(@CurrentStorageSizeMB AS nvarchar(20)) + N' of ' + CAST(@MaxStorageSizeMB AS nvarchar(20))
        + N' MB). Risk of automatic transition to READ_ONLY and loss of new captures.',
        N'Increase MAX_STORAGE_SIZE_MB, enable SIZE_BASED_CLEANUP_MODE = AUTO, reduce QUERY_CAPTURE_MODE if ad-hoc bloat is high, or purge stale data with sp_query_store_remove_query / cleanup.',
        @StorageUsedPct, 'StorageUsedPct', NULL
    )
END
ELSE IF @StorageUsedPct IS NOT NULL AND @StorageUsedPct >= 75
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        700, 2, 'Warning', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Query Store storage is ' + CAST(@StorageUsedPct AS nvarchar(20)) + N'% full ('
        + CAST(@CurrentStorageSizeMB AS nvarchar(20)) + N' of ' + CAST(@MaxStorageSizeMB AS nvarchar(20))
        + N' MB). Plan capacity headroom before READ_ONLY risk.',
        N'Review MAX_STORAGE_SIZE_MB and cleanup settings before the store fills.',
        @StorageUsedPct, 'StorageUsedPct', NULL
    )
END

IF @MaxStorageSizeMB IS NOT NULL AND @MaxStorageSizeMB > 0 AND @MaxStorageSizeMB < 500
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        650, 2, 'Warning', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'MAX_STORAGE_SIZE_MB is only ' + CAST(@MaxStorageSizeMB AS nvarchar(20))
        + N' MB. Small budgets fill quickly on active OLTP systems and force READ_ONLY mode.',
        N'Raise MAX_STORAGE_SIZE_MB (often 1024–4096+ MB depending on workload) and ensure size-based cleanup is AUTO.',
        @MaxStorageSizeMB, 'MaxStorageSizeMB', NULL
    )
END

IF @CleanupMode = N'OFF'
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        680, 2, 'Warning', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Size-based cleanup mode is OFF. Query Store will not automatically reclaim space as it approaches capacity.',
        N'ALTER DATABASE ' + @QuotedDatabase + N' SET QUERY_STORE (SIZE_BASED_CLEANUP_MODE = AUTO);',
        NULL, 'SizeBasedCleanupMode', NULL
    )
END

IF @CaptureMode = N'NONE'
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        900, 3, 'Critical', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'QUERY_CAPTURE_MODE is NONE. Query Store retains configuration but does not capture new queries.',
        N'Set QUERY_CAPTURE_MODE to AUTO (recommended) or ALL for temporary deep captures.',
        NULL, 'QueryCaptureMode', NULL
    )
END
ELSE IF @CaptureMode = N'ALL'
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        520, 1, 'Info', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'QUERY_CAPTURE_MODE is ALL. Every query is captured, which can bloat storage and drown important plans in ad-hoc noise.',
        N'Prefer AUTO (or CUSTOM on newer versions) for production. Use ALL only for short diagnostic windows.',
        NULL, 'QueryCaptureMode', NULL
    )
END

IF @IntervalLengthMinutes IS NOT NULL AND @IntervalLengthMinutes > 60
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        400, 1, 'Info', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Runtime stats interval is ' + CAST(@IntervalLengthMinutes AS nvarchar(20))
        + N' minutes. Coarse intervals reduce regression resolution for short incidents.',
        N'Consider INTERVAL_LENGTH_MINUTES = 15 or 30 for operational diagnostics (trade-off: more storage).',
        @IntervalLengthMinutes, 'IntervalLengthMinutes', NULL
    )
END

IF @MajorVersion >= 14 AND @WaitStatsCaptureMode = N'OFF'
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        430, 1, 'Info', 'QS_CONFIG', @TargetDatabase, NULL, NULL,
        N'Query Store wait-stats capture is OFF. Category wait breakdowns are unavailable.',
        N'ALTER DATABASE ' + @QuotedDatabase + N' SET QUERY_STORE (WAIT_STATS_CAPTURE_MODE = ON);',
        NULL, 'WaitStatsCaptureMode', NULL
    )
END

---------------------------------------------------------------------------------------------------
-- Collect query aggregates (successful + failed execution types)
---------------------------------------------------------------------------------------------------
SET @Sql = N'
;WITH Runtime AS
(
    SELECT
        q.query_id,
        q.query_text_id,
        q.object_id,
        q.query_hash,
        p.plan_id,
        p.is_forced_plan,
        ForceFailureCount = ISNULL(p.force_failure_count, 0),
        LastForceFailure = p.last_force_failure_reason_desc,
        rs.count_executions,
        rs.execution_type,
        rs.avg_duration,
        rs.avg_cpu_time,
        rs.avg_logical_io_reads,
        rs.avg_logical_io_writes,
        rs.avg_physical_io_reads,
        rs.max_duration,
        rs.max_cpu_time,
        rs.first_execution_time,
        rs.last_execution_time,
        qt.query_sql_text
    FROM ' + @QuotedDatabase + N'.sys.query_store_query AS q
    INNER JOIN ' + @QuotedDatabase + N'.sys.query_store_query_text AS qt
        ON qt.query_text_id = q.query_text_id
    INNER JOIN ' + @QuotedDatabase + N'.sys.query_store_plan AS p
        ON p.query_id = q.query_id
    INNER JOIN ' + @QuotedDatabase + N'.sys.query_store_runtime_stats AS rs
        ON rs.plan_id = p.plan_id
    WHERE ISNULL(q.is_internal_query, 0) = 0
      AND rs.last_execution_time >= @CutoffTime
)
INSERT INTO #QueryAgg
(
    QueryID, QueryTextID, ObjectID, ObjectName, QueryHash,
    PlanCount, ForcedPlanCount, ForceFailureCount, LastForceFailure,
    Executions, FailedExecutions,
    TotalDurationUs, TotalCpuUs, TotalLogicalReads, TotalLogicalWrites, TotalPhysicalReads,
    AvgDurationUs, AvgCpuUs, AvgLogicalReads, AvgPhysicalReads,
    MaxDurationUs, MaxCpuUs, FirstExecutionTime, LastExecutionTime, QueryTextShort
)
SELECT
    r.query_id,
    MAX(r.query_text_id),
    MAX(r.object_id),
    ObjectName = CASE
                     WHEN ISNULL(MAX(r.object_id), 0) = 0 THEN N''<ad hoc>''
                     ELSE COALESCE(
                            OBJECT_SCHEMA_NAME(CONVERT(int, MAX(r.object_id)), DB_ID(@TargetDatabase))
                            + N''.''
                            + OBJECT_NAME(CONVERT(int, MAX(r.object_id)), DB_ID(@TargetDatabase)),
                            N''<object_id='' + CAST(MAX(r.object_id) AS nvarchar(20)) + N''>'')
                 END,
    MAX(r.query_hash),
    PlanCount = COUNT(DISTINCT r.plan_id),
    ForcedPlanCount = COUNT(DISTINCT CASE WHEN r.is_forced_plan = 1 THEN r.plan_id END),
    ForceFailureCount = MAX(r.ForceFailureCount),
    LastForceFailure = MAX(r.LastForceFailure),
    Executions = SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(bigint, r.count_executions) ELSE CONVERT(bigint, 0) END),
    FailedExecutions = SUM(CASE WHEN r.execution_type <> 0 THEN CONVERT(bigint, r.count_executions) ELSE CONVERT(bigint, 0) END),
    TotalDurationUs = SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_duration) ELSE 0 END),
    TotalCpuUs = SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_cpu_time) ELSE 0 END),
    TotalLogicalReads = SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_logical_io_reads) ELSE 0 END),
    TotalLogicalWrites = SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_logical_io_writes) ELSE 0 END),
    TotalPhysicalReads = SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_physical_io_reads) ELSE 0 END),
    AvgDurationUs = CASE
                        WHEN SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END) = 0 THEN 0
                        ELSE SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_duration) ELSE 0 END)
                             / NULLIF(SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END), 0)
                    END,
    AvgCpuUs = CASE
                   WHEN SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END) = 0 THEN 0
                   ELSE SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_cpu_time) ELSE 0 END)
                        / NULLIF(SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END), 0)
               END,
    AvgLogicalReads = CASE
                          WHEN SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END) = 0 THEN 0
                          ELSE SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_logical_io_reads) ELSE 0 END)
                               / NULLIF(SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END), 0)
                      END,
    AvgPhysicalReads = CASE
                           WHEN SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END) = 0 THEN 0
                           ELSE SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) * CONVERT(float, r.avg_physical_io_reads) ELSE 0 END)
                                / NULLIF(SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.count_executions) ELSE 0 END), 0)
                       END,
    MaxDurationUs = MAX(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.max_duration) ELSE NULL END),
    MaxCpuUs = MAX(CASE WHEN r.execution_type = 0 THEN CONVERT(float, r.max_cpu_time) ELSE NULL END),
    FirstExecutionTime = MIN(r.first_execution_time),
    LastExecutionTime = MAX(r.last_execution_time),
    QueryTextShort = LEFT(
        REPLACE(REPLACE(REPLACE(REPLACE(MAX(r.query_sql_text), CHAR(13), N'' ''), CHAR(10), N'' ''), CHAR(9), N'' ''), N''  '', N'' ''),
        400)
FROM Runtime AS r
GROUP BY r.query_id
HAVING SUM(CASE WHEN r.execution_type = 0 THEN CONVERT(bigint, r.count_executions) ELSE CONVERT(bigint, 0) END) >= @MinExecutions
    OR SUM(CASE WHEN r.execution_type <> 0 THEN CONVERT(bigint, r.count_executions) ELSE CONVERT(bigint, 0) END) >= @MinExecutions
OPTION (RECOMPILE)'

EXEC sys.sp_executesql
    @Sql,
    N'@CutoffTime datetimeoffset(7), @MinExecutions bigint, @TargetDatabase sysname',
    @CutoffTime = @CutoffTime,
    @MinExecutions = @MinExecutions,
    @TargetDatabase = @TargetDatabase

/* Per-plan aggregates for multi-plan / regression analysis */
SET @Sql = N'
;WITH Runtime AS
(
    SELECT
        q.query_id,
        p.plan_id,
        p.is_forced_plan,
        rs.count_executions,
        rs.avg_duration,
        rs.avg_cpu_time,
        rs.avg_logical_io_reads,
        rs.max_duration
    FROM ' + @QuotedDatabase + N'.sys.query_store_query AS q
    INNER JOIN ' + @QuotedDatabase + N'.sys.query_store_plan AS p
        ON p.query_id = q.query_id
    INNER JOIN ' + @QuotedDatabase + N'.sys.query_store_runtime_stats AS rs
        ON rs.plan_id = p.plan_id
    WHERE ISNULL(q.is_internal_query, 0) = 0
      AND rs.execution_type = 0
      AND rs.last_execution_time >= @CutoffTime
)
INSERT INTO #PlanAgg
(
    QueryID, PlanID, IsForcedPlan, Executions, AvgDurationUs, AvgCpuUs, AvgLogicalReads, MaxDurationUs
)
SELECT
    r.query_id,
    r.plan_id,
    IsForcedPlan = MAX(CASE WHEN r.is_forced_plan = 1 THEN 1 ELSE 0 END),
    Executions = SUM(CONVERT(bigint, r.count_executions)),
    AvgDurationUs = SUM(CONVERT(float, r.count_executions) * CONVERT(float, r.avg_duration))
                    / NULLIF(SUM(CONVERT(float, r.count_executions)), 0),
    AvgCpuUs = SUM(CONVERT(float, r.count_executions) * CONVERT(float, r.avg_cpu_time))
               / NULLIF(SUM(CONVERT(float, r.count_executions)), 0),
    AvgLogicalReads = SUM(CONVERT(float, r.count_executions) * CONVERT(float, r.avg_logical_io_reads))
                      / NULLIF(SUM(CONVERT(float, r.count_executions)), 0),
    MaxDurationUs = MAX(CONVERT(float, r.max_duration))
FROM Runtime AS r
GROUP BY r.query_id, r.plan_id
HAVING SUM(CONVERT(bigint, r.count_executions)) >= 1
OPTION (RECOMPILE)'

EXEC sys.sp_executesql
    @Sql,
    N'@CutoffTime datetimeoffset(7)',
    @CutoffTime = @CutoffTime

/* Optional Query Store wait categories (SQL 2017+) */
IF @MajorVersion >= 14 AND ISNULL(@WaitStatsCaptureMode, N'') <> N'OFF'
BEGIN
    SET @Sql = N'
    INSERT INTO #WaitAgg (WaitCategory, TotalQueryWaitMs, TotalExecutionCount, AvgQueryWaitMs)
    SELECT
        WaitCategory = ws.wait_category_desc,
        TotalQueryWaitMs = SUM(CONVERT(float, ws.total_query_wait_time_ms)),
        TotalExecutionCount = COUNT_BIG(*),
        AvgQueryWaitMs = AVG(CONVERT(float, ws.avg_query_wait_time_ms))
    FROM ' + @QuotedDatabase + N'.sys.query_store_wait_stats AS ws
    INNER JOIN ' + @QuotedDatabase + N'.sys.query_store_runtime_stats_interval AS rsi
        ON rsi.runtime_stats_interval_id = ws.runtime_stats_interval_id
    WHERE rsi.end_time >= @CutoffTime
      AND ws.wait_category_desc NOT IN (N''Unknown'')
    GROUP BY ws.wait_category_desc
    OPTION (RECOMPILE)'

    BEGIN TRY
        EXEC sys.sp_executesql
            @Sql,
            N'@CutoffTime datetimeoffset(7)',
            @CutoffTime = @CutoffTime
    END TRY
    BEGIN CATCH
        /* Wait stats optional; do not fail the whole analysis */
        SET @Note = ISNULL(@Note + N'; ', N'') + N'Wait stats collection skipped: ' + ERROR_MESSAGE()
    END CATCH
END

SELECT
    @TotalQueries     = COUNT(*),
    @TotalPlans       = SUM(PlanCount),
    @ForcedPlans      = SUM(CASE WHEN ForcedPlanCount > 0 THEN 1 ELSE 0 END),
    @MultiPlanQueries = SUM(CASE WHEN PlanCount > 1 THEN 1 ELSE 0 END),
    @CapturedQueries  = COUNT(*),
    @TotalExecutions  = SUM(Executions),
    @FailedExecutions = SUM(FailedExecutions)
  FROM #QueryAgg

SET @TotalQueries     = ISNULL(@TotalQueries, 0)
SET @TotalPlans       = ISNULL(@TotalPlans, 0)
SET @ForcedPlans      = ISNULL(@ForcedPlans, 0)
SET @MultiPlanQueries = ISNULL(@MultiPlanQueries, 0)
SET @CapturedQueries  = ISNULL(@CapturedQueries, 0)
SET @TotalExecutions  = ISNULL(@TotalExecutions, 0)
SET @FailedExecutions = ISNULL(@FailedExecutions, 0)

IF @CapturedQueries = 0
BEGIN
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    VALUES
    (
        500, 2, 'Warning', 'QS_DATA', @TargetDatabase, NULL, NULL,
        N'No Query Store queries met the filters (DaysBack=' + CAST(@DaysBack AS nvarchar(10))
        + N', MinExecutions=' + CAST(@MinExecutions AS nvarchar(20))
        + N'). Capture mode=' + ISNULL(@CaptureMode, N'?') + N'.',
        N'Widen @DaysBack, lower @MinExecutions, confirm workload activity, and verify QUERY_CAPTURE_MODE is not NONE.',
        NULL, 'CapturedQueries', NULL
    )
    GOTO ReturnResults
END

---------------------------------------------------------------------------------------------------
-- Expensive query findings (CPU / duration / reads / physical IO)
---------------------------------------------------------------------------------------------------
;WITH Totals AS
(
    SELECT
        SUM(TotalCpuUs) AS SumCpu,
        SUM(TotalDurationUs) AS SumDuration,
        SUM(TotalLogicalReads) AS SumReads
      FROM #QueryAgg
     WHERE Executions >= @MinExecutions
)
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 800
        + CASE WHEN t.SumCpu > 0 AND q.TotalCpuUs * 100.0 / t.SumCpu >= 20 THEN 80
               WHEN t.SumCpu > 0 AND q.TotalCpuUs * 100.0 / t.SumCpu >= 10 THEN 50
               WHEN t.SumCpu > 0 AND q.TotalCpuUs * 100.0 / t.SumCpu >= 5 THEN 30
               ELSE 10 END
        + CASE WHEN q.AvgCpuUs >= 1000000 THEN 40 WHEN q.AvgCpuUs >= 100000 THEN 20 ELSE 0 END,
    Severity = CASE
                   WHEN t.SumCpu > 0 AND q.TotalCpuUs * 100.0 / t.SumCpu >= 15 THEN 3
                   WHEN t.SumCpu > 0 AND q.TotalCpuUs * 100.0 / t.SumCpu >= 5 THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN t.SumCpu > 0 AND q.TotalCpuUs * 100.0 / t.SumCpu >= 15 THEN 'Critical'
                        WHEN t.SumCpu > 0 AND q.TotalCpuUs * 100.0 / t.SumCpu >= 5 THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'HIGH_CPU',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'Total CPU share≈'
        + CASE WHEN t.SumCpu > 0
               THEN CAST(CAST(q.TotalCpuUs * 100.0 / t.SumCpu AS decimal(9, 2)) AS nvarchar(20))
               ELSE N'0'
          END
        + N'%. Execs=' + CAST(q.Executions AS nvarchar(20))
        + N', AvgCPU=' + CAST(CAST(q.AvgCpuUs / 1000.0 AS decimal(18, 2)) AS nvarchar(20)) + N' ms'
        + N', MaxCPU=' + CAST(CAST(ISNULL(q.MaxCpuUs, 0) / 1000.0 AS decimal(18, 2)) AS nvarchar(20)) + N' ms'
        + N', Plans=' + CAST(q.PlanCount AS nvarchar(10))
        + N', LastExec=' + ISNULL(CONVERT(nvarchar(19), q.LastExecutionTime, 120), N'n/a') + N'.',
    SuggestedAction = N'Review plan(s) for query_id=' + CAST(q.QueryID AS nvarchar(20))
        + N'. Check for missing indexes, implicit conversions, large scans, and parameter sniffing. Use SET STATISTICS IO/TIME or actual plans in a non-prod window.',
    MetricNumeric = CAST(q.TotalCpuUs / 1000.0 AS decimal(28, 4)),
    MetricLabel = 'TotalCpuMs',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 CROSS JOIN Totals AS t
 WHERE q.Executions >= @MinExecutions
   AND q.TotalCpuUs > 0
 ORDER BY q.TotalCpuUs DESC

;WITH Totals AS
(
    SELECT SUM(TotalDurationUs) AS SumDuration
      FROM #QueryAgg
     WHERE Executions >= @MinExecutions
)
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 780
        + CASE WHEN t.SumDuration > 0 AND q.TotalDurationUs * 100.0 / t.SumDuration >= 20 THEN 80
               WHEN t.SumDuration > 0 AND q.TotalDurationUs * 100.0 / t.SumDuration >= 10 THEN 50
               ELSE 15 END
        + CASE WHEN q.AvgDurationUs >= 5000000 THEN 40 WHEN q.AvgDurationUs >= 1000000 THEN 20 ELSE 0 END,
    Severity = CASE
                   WHEN t.SumDuration > 0 AND q.TotalDurationUs * 100.0 / t.SumDuration >= 15 THEN 3
                   WHEN q.AvgDurationUs >= 2000000 OR (t.SumDuration > 0 AND q.TotalDurationUs * 100.0 / t.SumDuration >= 5) THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN t.SumDuration > 0 AND q.TotalDurationUs * 100.0 / t.SumDuration >= 15 THEN 'Critical'
                        WHEN q.AvgDurationUs >= 2000000 OR (t.SumDuration > 0 AND q.TotalDurationUs * 100.0 / t.SumDuration >= 5) THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'HIGH_DURATION',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'Total duration share≈'
        + CASE WHEN t.SumDuration > 0
               THEN CAST(CAST(q.TotalDurationUs * 100.0 / t.SumDuration AS decimal(9, 2)) AS nvarchar(20))
               ELSE N'0'
          END
        + N'%. Execs=' + CAST(q.Executions AS nvarchar(20))
        + N', AvgDuration=' + CAST(CAST(q.AvgDurationUs / 1000.0 AS decimal(18, 2)) AS nvarchar(20)) + N' ms'
        + N', MaxDuration=' + CAST(CAST(ISNULL(q.MaxDurationUs, 0) / 1000.0 AS decimal(18, 2)) AS nvarchar(20)) + N' ms'
        + N', AvgReads=' + CAST(CAST(q.AvgLogicalReads AS decimal(18, 1)) AS nvarchar(20)) + N'.',
    SuggestedAction = N'Investigate blocking, waits, and plan quality for query_id=' + CAST(q.QueryID AS nvarchar(20))
        + N'. Compare Avg vs Max duration for intermittent regressions.',
    MetricNumeric = CAST(q.TotalDurationUs / 1000.0 AS decimal(28, 4)),
    MetricLabel = 'TotalDurationMs',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 CROSS JOIN Totals AS t
 WHERE q.Executions >= @MinExecutions
   AND q.TotalDurationUs > 0
 ORDER BY q.TotalDurationUs DESC

;WITH Totals AS
(
    SELECT SUM(TotalLogicalReads) AS SumReads
      FROM #QueryAgg
     WHERE Executions >= @MinExecutions
)
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 760
        + CASE WHEN t.SumReads > 0 AND q.TotalLogicalReads * 100.0 / t.SumReads >= 20 THEN 70
               WHEN t.SumReads > 0 AND q.TotalLogicalReads * 100.0 / t.SumReads >= 10 THEN 40
               ELSE 10 END
        + CASE WHEN q.AvgLogicalReads >= 100000 THEN 40 WHEN q.AvgLogicalReads >= 10000 THEN 20 ELSE 0 END,
    Severity = CASE
                   WHEN q.AvgLogicalReads >= 100000 OR (t.SumReads > 0 AND q.TotalLogicalReads * 100.0 / t.SumReads >= 15) THEN 3
                   WHEN q.AvgLogicalReads >= 10000 OR (t.SumReads > 0 AND q.TotalLogicalReads * 100.0 / t.SumReads >= 5) THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN q.AvgLogicalReads >= 100000 OR (t.SumReads > 0 AND q.TotalLogicalReads * 100.0 / t.SumReads >= 15) THEN 'Critical'
                        WHEN q.AvgLogicalReads >= 10000 OR (t.SumReads > 0 AND q.TotalLogicalReads * 100.0 / t.SumReads >= 5) THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'HIGH_READS',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'Total logical-read share≈'
        + CASE WHEN t.SumReads > 0
               THEN CAST(CAST(q.TotalLogicalReads * 100.0 / t.SumReads AS decimal(9, 2)) AS nvarchar(20))
               ELSE N'0'
          END
        + N'%. Execs=' + CAST(q.Executions AS nvarchar(20))
        + N', AvgLogicalReads=' + CAST(CAST(q.AvgLogicalReads AS decimal(18, 1)) AS nvarchar(20))
        + N', AvgPhysicalReads=' + CAST(CAST(q.AvgPhysicalReads AS decimal(18, 1)) AS nvarchar(20))
        + N', Plans=' + CAST(q.PlanCount AS nvarchar(10)) + N'.',
    SuggestedAction = N'High logical reads often indicate scans or poorly selective seeks. Correlate with missing-index findings and verify predicates/SARGability for query_id='
        + CAST(q.QueryID AS nvarchar(20)) + N'.',
    MetricNumeric = CAST(q.TotalLogicalReads AS decimal(28, 4)),
    MetricLabel = 'TotalLogicalReads',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 CROSS JOIN Totals AS t
 WHERE q.Executions >= @MinExecutions
   AND q.TotalLogicalReads > 0
 ORDER BY q.TotalLogicalReads DESC

INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 740
        + CASE WHEN q.AvgPhysicalReads >= 10000 THEN 50 WHEN q.AvgPhysicalReads >= 1000 THEN 25 ELSE 10 END,
    Severity = CASE
                   WHEN q.AvgPhysicalReads >= 10000 THEN 3
                   WHEN q.AvgPhysicalReads >= 1000 THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN q.AvgPhysicalReads >= 10000 THEN 'Critical'
                        WHEN q.AvgPhysicalReads >= 1000 THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'PHYSICAL_IO',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'AvgPhysicalReads=' + CAST(CAST(q.AvgPhysicalReads AS decimal(18, 1)) AS nvarchar(20))
        + N', TotalPhysicalReads=' + CAST(CAST(q.TotalPhysicalReads AS decimal(18, 0)) AS nvarchar(20))
        + N', Execs=' + CAST(q.Executions AS nvarchar(20))
        + N', AvgLogicalReads=' + CAST(CAST(q.AvgLogicalReads AS decimal(18, 1)) AS nvarchar(20)) + N'.',
    SuggestedAction = N'Physical reads point to buffer-pool pressure or cold cache large scans. Improve indexing/filtering and check memory/PLO on the host for query_id='
        + CAST(q.QueryID AS nvarchar(20)) + N'.',
    MetricNumeric = CAST(q.TotalPhysicalReads AS decimal(28, 4)),
    MetricLabel = 'TotalPhysicalReads',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 WHERE q.Executions >= @MinExecutions
   AND q.AvgPhysicalReads >= 100
 ORDER BY q.TotalPhysicalReads DESC

---------------------------------------------------------------------------------------------------
-- Plan instability / multi-plan variance (parameter sniffing / regression candidates)
---------------------------------------------------------------------------------------------------
;WITH PlanRange AS
(
    SELECT
        p.QueryID,
        PlanCount = COUNT(*),
        BestPlanID = MIN(CASE WHEN p.AvgDurationUs = x.MinAvg THEN p.PlanID END),
        WorstPlanID = MIN(CASE WHEN p.AvgDurationUs = x.MaxAvg THEN p.PlanID END),
        MinAvgDurationUs = x.MinAvg,
        MaxAvgDurationUs = x.MaxAvg,
        VarianceFactor = CASE WHEN x.MinAvg > 0 THEN x.MaxAvg / x.MinAvg ELSE NULL END,
        TotalExecutions = SUM(p.Executions)
      FROM #PlanAgg AS p
     INNER JOIN (
            SELECT
                QueryID,
                MinAvg = MIN(AvgDurationUs),
                MaxAvg = MAX(AvgDurationUs)
              FROM #PlanAgg
             WHERE Executions >= @MinExecutions
             GROUP BY QueryID
            HAVING COUNT(*) >= 2
         ) AS x
        ON x.QueryID = p.QueryID
     WHERE p.Executions >= @MinExecutions
     GROUP BY p.QueryID, x.MinAvg, x.MaxAvg
)
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 850
        + CASE WHEN pr.VarianceFactor >= 10 THEN 80 WHEN pr.VarianceFactor >= 5 THEN 50 WHEN pr.VarianceFactor >= @PlanVarianceFactor THEN 25 ELSE 0 END
        + CASE WHEN q.TotalDurationUs >= 100000000 THEN 30 ELSE 10 END,
    Severity = CASE
                   WHEN pr.VarianceFactor >= 10 THEN 3
                   WHEN pr.VarianceFactor >= @PlanVarianceFactor THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN pr.VarianceFactor >= 10 THEN 'Critical'
                        WHEN pr.VarianceFactor >= @PlanVarianceFactor THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'PLAN_INSTABILITY',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = pr.WorstPlanID,
    FindingDetail = N'Query has ' + CAST(pr.PlanCount AS nvarchar(10)) + N' plans in the window with avg-duration ratio '
        + CAST(CAST(pr.VarianceFactor AS decimal(18, 2)) AS nvarchar(20))
        + N'x (best plan_id=' + CAST(pr.BestPlanID AS nvarchar(20))
        + N' @ ' + CAST(CAST(pr.MinAvgDurationUs / 1000.0 AS decimal(18, 2)) AS nvarchar(20)) + N' ms avg; worst plan_id='
        + CAST(pr.WorstPlanID AS nvarchar(20))
        + N' @ ' + CAST(CAST(pr.MaxAvgDurationUs / 1000.0 AS decimal(18, 2)) AS nvarchar(20)) + N' ms avg). Execs='
        + CAST(pr.TotalExecutions AS nvarchar(20)) + N'.',
    SuggestedAction = N'Suspect parameter sniffing or schema/stats change. Compare plans, consider Query Store plan forcing of the good plan after validation, OPTIMIZE FOR / recompile strategies, or stats/index fixes for query_id='
        + CAST(q.QueryID AS nvarchar(20)) + N'.',
    MetricNumeric = CAST(pr.VarianceFactor AS decimal(28, 4)),
    MetricLabel = 'PlanAvgDurationRatio',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM PlanRange AS pr
 INNER JOIN #QueryAgg AS q
    ON q.QueryID = pr.QueryID
 WHERE pr.VarianceFactor >= @PlanVarianceFactor
 ORDER BY pr.VarianceFactor DESC, q.TotalDurationUs DESC

/* Outliers: max duration much higher than average */
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 720
        + CASE WHEN q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) >= 50 THEN 60
               WHEN q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) >= 20 THEN 35
               ELSE 15 END,
    Severity = CASE
                   WHEN q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) >= 50 THEN 3
                   WHEN q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) >= @OutlierFactor THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) >= 50 THEN 'Critical'
                        WHEN q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) >= @OutlierFactor THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'DURATION_OUTLIER',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'Max/Avg duration ratio='
        + CAST(CAST(q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) AS decimal(18, 2)) AS nvarchar(20))
        + N'x. Avg=' + CAST(CAST(q.AvgDurationUs / 1000.0 AS decimal(18, 2)) AS nvarchar(20))
        + N' ms, Max=' + CAST(CAST(q.MaxDurationUs / 1000.0 AS decimal(18, 2)) AS nvarchar(20))
        + N' ms, Execs=' + CAST(q.Executions AS nvarchar(20))
        + N', Plans=' + CAST(q.PlanCount AS nvarchar(10)) + N'.',
    SuggestedAction = N'Intermittent spikes can be blocking, resource contention, or a rare bad plan. Inspect runtime intervals and waits around last_execution_time for query_id='
        + CAST(q.QueryID AS nvarchar(20)) + N'.',
    MetricNumeric = CAST(q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) AS decimal(28, 4)),
    MetricLabel = 'MaxToAvgDurationRatio',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 WHERE q.Executions >= @MinExecutions
   AND q.AvgDurationUs > 0
   AND q.MaxDurationUs >= q.AvgDurationUs * @OutlierFactor
   AND q.MaxDurationUs >= 500000  -- at least 500 ms max to avoid noise
 ORDER BY q.MaxDurationUs / NULLIF(q.AvgDurationUs, 0) DESC

---------------------------------------------------------------------------------------------------
-- Forced plan problems
---------------------------------------------------------------------------------------------------
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 880
        + CASE WHEN q.ForceFailureCount >= 100 THEN 50 WHEN q.ForceFailureCount >= 10 THEN 25 ELSE 10 END,
    Severity = CASE WHEN q.ForceFailureCount >= 10 THEN 3 ELSE 2 END,
    SeverityLabel = CASE WHEN q.ForceFailureCount >= 10 THEN 'Critical' ELSE 'Warning' END,
    Category = 'FORCED_PLAN_FAILURE',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'Plan forcing has failed ' + CAST(q.ForceFailureCount AS nvarchar(20))
        + N' time(s). Last reason=' + ISNULL(q.LastForceFailure, N'n/a')
        + N'. ForcedPlanCount=' + CAST(q.ForcedPlanCount AS nvarchar(10))
        + N', current plans=' + CAST(q.PlanCount AS nvarchar(10)) + N'.',
    SuggestedAction = N'Re-evaluate forced plan for query_id=' + CAST(q.QueryID AS nvarchar(20))
        + N'. Unforce if invalid, refresh stats, or force a current valid plan after testing.',
    MetricNumeric = CAST(q.ForceFailureCount AS decimal(28, 4)),
    MetricLabel = 'ForceFailureCount',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 WHERE q.ForceFailureCount > 0
 ORDER BY q.ForceFailureCount DESC, q.TotalDurationUs DESC

INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 300,
    Severity = 1,
    SeverityLabel = 'Info',
    Category = 'FORCED_PLAN',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'Query currently has a forced plan (ForcedPlanCount='
        + CAST(q.ForcedPlanCount AS nvarchar(10)) + N'). Execs=' + CAST(q.Executions AS nvarchar(20))
        + N', AvgDuration=' + CAST(CAST(q.AvgDurationUs / 1000.0 AS decimal(18, 2)) AS nvarchar(20)) + N' ms.',
    SuggestedAction = N'Keep forced plans under change control. Periodically re-validate that the forced plan remains optimal after schema/stats changes.',
    MetricNumeric = CAST(q.ForcedPlanCount AS decimal(28, 4)),
    MetricLabel = 'ForcedPlanCount',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 WHERE q.ForcedPlanCount > 0
   AND q.ForceFailureCount = 0
 ORDER BY q.TotalDurationUs DESC

---------------------------------------------------------------------------------------------------
-- Failed / aborted executions
---------------------------------------------------------------------------------------------------
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 830
        + CASE WHEN q.FailedExecutions >= 1000 THEN 60 WHEN q.FailedExecutions >= 100 THEN 30 ELSE 10 END,
    Severity = CASE
                   WHEN q.FailedExecutions >= 100 THEN 3
                   WHEN q.FailedExecutions >= 10 THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN q.FailedExecutions >= 100 THEN 'Critical'
                        WHEN q.FailedExecutions >= 10 THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'FAILED_EXECUTION',
    ObjectName = q.ObjectName,
    QueryID = q.QueryID,
    PlanID = NULL,
    FindingDetail = N'Non-regular execution_type rows in window: FailedExecs='
        + CAST(q.FailedExecutions AS nvarchar(20))
        + N', SuccessfulExecs=' + CAST(q.Executions AS nvarchar(20))
        + N' (timeouts/aborts/exceptions depending on execution_type).',
    SuggestedAction = N'Inspect error logs / application timeouts for query_id=' + CAST(q.QueryID AS nvarchar(20))
        + N'. Tune duration, reduce blocking, or fix runtime errors.',
    MetricNumeric = CAST(q.FailedExecutions AS decimal(28, 4)),
    MetricLabel = 'FailedExecutions',
    QueryTextShort = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
  FROM #QueryAgg AS q
 WHERE q.FailedExecutions >= @MinExecutions
 ORDER BY q.FailedExecutions DESC

---------------------------------------------------------------------------------------------------
-- Ad-hoc bloat signal
---------------------------------------------------------------------------------------------------
;WITH Adhoc AS
(
    SELECT
        AdhocQueries = SUM(CASE WHEN ISNULL(ObjectID, 0) = 0 THEN 1 ELSE 0 END),
        TotalQueries = COUNT(*),
        SingleUseAdhoc = SUM(CASE WHEN ISNULL(ObjectID, 0) = 0 AND Executions = 1 THEN 1 ELSE 0 END),
        AdhocExecutions = SUM(CASE WHEN ISNULL(ObjectID, 0) = 0 THEN Executions ELSE 0 END)
      FROM #QueryAgg
)
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT
    PriorityScore = 560
        + CASE WHEN a.TotalQueries > 0 AND a.AdhocQueries * 100.0 / a.TotalQueries >= 80 THEN 40
               WHEN a.TotalQueries > 0 AND a.AdhocQueries * 100.0 / a.TotalQueries >= 50 THEN 20
               ELSE 0 END,
    Severity = CASE
                   WHEN a.TotalQueries > 0 AND a.AdhocQueries * 100.0 / a.TotalQueries >= 80 THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN a.TotalQueries > 0 AND a.AdhocQueries * 100.0 / a.TotalQueries >= 80 THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'ADHOC_BLOAT',
    ObjectName = @TargetDatabase,
    QueryID = NULL,
    PlanID = NULL,
    FindingDetail = N'Ad-hoc queries=' + CAST(a.AdhocQueries AS nvarchar(20))
        + N' of ' + CAST(a.TotalQueries AS nvarchar(20))
        + N' (' + CASE WHEN a.TotalQueries > 0
                       THEN CAST(CAST(a.AdhocQueries * 100.0 / a.TotalQueries AS decimal(9, 1)) AS nvarchar(20))
                       ELSE N'0'
                  END
        + N'%). Single-execution ad-hoc=' + CAST(a.SingleUseAdhoc AS nvarchar(20))
        + N'. CaptureMode=' + ISNULL(@CaptureMode, N'?') + N'.',
    SuggestedAction = N'Prefer parameterized queries / stored procedures. Consider QUERY_CAPTURE_MODE = AUTO, optimize for ad hoc workloads at the instance level, and raise Query Store size if ALL capture is intentional.',
    MetricNumeric = CAST(a.AdhocQueries AS decimal(28, 4)),
    MetricLabel = 'AdhocQueryCount',
    QueryTextShort = NULL
  FROM Adhoc AS a
 WHERE a.AdhocQueries >= 20
   AND a.TotalQueries > 0
   AND a.AdhocQueries * 100.0 / a.TotalQueries >= 40

---------------------------------------------------------------------------------------------------
-- Query Store wait category findings
---------------------------------------------------------------------------------------------------
INSERT INTO #Findings
(
    PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
    FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
)
SELECT TOP (@TopN)
    PriorityScore = 600
        + CASE WHEN w.TotalQueryWaitMs >= 600000 THEN 50 WHEN w.TotalQueryWaitMs >= 60000 THEN 25 ELSE 5 END,
    Severity = CASE
                   WHEN w.WaitCategory IN (N'Lock', N'Latch', N'Buffer IO', N'Buffer Latch', N'Parallelism')
                        AND w.TotalQueryWaitMs >= 60000 THEN 2
                   WHEN w.TotalQueryWaitMs >= 600000 THEN 2
                   ELSE 1
               END,
    SeverityLabel = CASE
                        WHEN w.WaitCategory IN (N'Lock', N'Latch', N'Buffer IO', N'Buffer Latch', N'Parallelism')
                             AND w.TotalQueryWaitMs >= 60000 THEN 'Warning'
                        WHEN w.TotalQueryWaitMs >= 600000 THEN 'Warning'
                        ELSE 'Info'
                    END,
    Category = 'WAIT_CATEGORY',
    ObjectName = w.WaitCategory,
    QueryID = NULL,
    PlanID = NULL,
    FindingDetail = N'Query Store wait category ''' + w.WaitCategory + N''' total_wait≈'
        + CAST(CAST(w.TotalQueryWaitMs AS decimal(18, 1)) AS nvarchar(20)) + N' ms'
        + N', avg_wait≈' + CAST(CAST(w.AvgQueryWaitMs AS decimal(18, 2)) AS nvarchar(20)) + N' ms'
        + N' across ' + CAST(w.TotalExecutionCount AS nvarchar(20)) + N' wait-stat rows in the window.',
    SuggestedAction = CASE w.WaitCategory
                          WHEN N'Lock' THEN N'Investigate blocking chains, long transactions, and missing indexes that extend lock duration.'
                          WHEN N'Buffer IO' THEN N'Review physical IO, storage latency, and large scans; correlate with PHYSICAL_IO query findings.'
                          WHEN N'Buffer Latch' THEN N'Check tempdb/hot pages and allocation contention patterns.'
                          WHEN N'CPU' THEN N'Focus on HIGH_CPU queries and parallelism settings (MAXDOP/cost threshold).'
                          WHEN N'Parallelism' THEN N'Review CXPACKET/CXCONSUMER style issues, skewed parallel plans, and MAXDOP.'
                          WHEN N'Network IO' THEN N'Large result sets or slow clients; consider filtering/pagination.'
                          ELSE N'Review top queries and plans contributing to this wait category.'
                      END,
    MetricNumeric = CAST(w.TotalQueryWaitMs AS decimal(28, 4)),
    MetricLabel = 'TotalQueryWaitMs',
    QueryTextShort = NULL
  FROM #WaitAgg AS w
 WHERE w.TotalQueryWaitMs >= 1000
 ORDER BY w.TotalQueryWaitMs DESC

---------------------------------------------------------------------------------------------------
-- Missing indexes (DMV) with suggested DDL
---------------------------------------------------------------------------------------------------
IF @IncludeMissingIndexes = 1
BEGIN
    SET @Sql = N'
    ;WITH Missing AS
    (
        SELECT
            ImpactScore = CAST(migs.avg_user_impact * (migs.user_seeks + migs.user_scans) AS decimal(18, 2)),
            SchemaName = s.name,
            TableName = o.name,
            mid.equality_columns,
            mid.inequality_columns,
            mid.included_columns,
            migs.user_seeks,
            migs.user_scans,
            migs.avg_user_impact,
            migs.avg_total_user_cost,
            migs.last_user_seek,
            mid.statement
        FROM ' + @QuotedDatabase + N'.sys.dm_db_missing_index_group_stats AS migs
        INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_groups AS mig
            ON mig.index_group_handle = migs.group_handle
        INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_details AS mid
            ON mid.index_handle = mig.index_handle
        INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
            ON o.object_id = mid.object_id
        INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
            ON s.schema_id = o.schema_id
        WHERE o.type = ''U''
          AND migs.avg_user_impact * (migs.user_seeks + migs.user_scans) >= @MinMissingIndexImpact
    )
    INSERT INTO #Findings
    (
        PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
        FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
    )
    SELECT TOP (@TopN)
        PriorityScore = 770
            + CASE WHEN m.ImpactScore >= 1000000 THEN 90
                   WHEN m.ImpactScore >= 100000 THEN 50
                   WHEN m.ImpactScore >= 10000 THEN 25
                   ELSE 5 END,
        Severity = CASE
                       WHEN m.ImpactScore >= 1000000 THEN 3
                       WHEN m.ImpactScore >= 100000 THEN 2
                       ELSE 1
                   END,
        SeverityLabel = CASE
                            WHEN m.ImpactScore >= 1000000 THEN ''Critical''
                            WHEN m.ImpactScore >= 100000 THEN ''Warning''
                            ELSE ''Info''
                        END,
        Category = ''MISSING_INDEX'',
        ObjectName = m.SchemaName + N''.'' + m.TableName,
        QueryID = NULL,
        PlanID = NULL,
        FindingDetail = N''ImpactScore='' + CAST(m.ImpactScore AS nvarchar(30))
            + N'', AvgImpactPct='' + CAST(CAST(m.avg_user_impact AS decimal(9, 2)) AS nvarchar(20))
            + N'', Seeks='' + CAST(m.user_seeks AS nvarchar(20))
            + N'', Scans='' + CAST(m.user_scans AS nvarchar(20))
            + N'', Equality='' + ISNULL(m.equality_columns, N''(none)'')
            + N'', Inequality='' + ISNULL(m.inequality_columns, N''(none)'')
            + N'', Include='' + ISNULL(m.included_columns, N''(none)'')
            + N'', LastSeek='' + ISNULL(CONVERT(nvarchar(19), m.last_user_seek, 120), N''n/a'') + N''.'',
        SuggestedAction = N''-- Validate against Query Store HIGH_READS/HIGH_DURATION queries before deploying'' + CHAR(13) + CHAR(10)
            + N''CREATE NONCLUSTERED INDEX [IX_'' + m.TableName + N''_QS_''
            + CAST(ROW_NUMBER() OVER (ORDER BY m.ImpactScore DESC) AS nvarchar(10)) + N'']'' + CHAR(13) + CHAR(10)
            + N''    ON '' + QUOTENAME(m.SchemaName) + N''.'' + QUOTENAME(m.TableName) + N'' (''
            + CASE
                  WHEN m.equality_columns IS NOT NULL AND m.inequality_columns IS NOT NULL
                      THEN m.equality_columns + N'', '' + m.inequality_columns
                  WHEN m.equality_columns IS NOT NULL THEN m.equality_columns
                  ELSE m.inequality_columns
              END
            + N'')''
            + CASE
                  WHEN m.included_columns IS NOT NULL
                      THEN CHAR(13) + CHAR(10) + N''    INCLUDE ('' + m.included_columns + N'')''
                  ELSE N''''
              END
            + N'';'',
        MetricNumeric = m.ImpactScore,
        MetricLabel = ''MissingIndexImpact'',
        QueryTextShort = NULL
    FROM Missing AS m
    ORDER BY m.ImpactScore DESC'

    BEGIN TRY
        EXEC sys.sp_executesql
            @Sql,
            N'@TopN int, @MinMissingIndexImpact decimal(18, 2)',
            @TopN = @TopN,
            @MinMissingIndexImpact = @MinMissingIndexImpact
    END TRY
    BEGIN CATCH
        INSERT INTO #Findings
        (
            PriorityScore, Severity, SeverityLabel, Category, ObjectName, QueryID, PlanID,
            FindingDetail, SuggestedAction, MetricNumeric, MetricLabel, QueryTextShort
        )
        VALUES
        (
            200, 1, 'Info', 'MISSING_INDEX', @TargetDatabase, NULL, NULL,
            N'Missing-index DMV collection failed: ' + ERROR_MESSAGE(),
            N'Ensure the caller has VIEW SERVER STATE / VIEW DATABASE STATE as required for missing-index DMVs.',
            NULL, 'MissingIndexError', NULL
        )
    END CATCH
END

ReturnResults:

SELECT
    @FindingCount  = COUNT(*),
    @CriticalCount = SUM(CASE WHEN Severity = 3 THEN 1 ELSE 0 END),
    @WarningCount  = SUM(CASE WHEN Severity = 2 THEN 1 ELSE 0 END),
    @InfoCount     = SUM(CASE WHEN Severity = 1 THEN 1 ELSE 0 END)
  FROM #Findings

SET @FindingCount  = ISNULL(@FindingCount, 0)
SET @CriticalCount = ISNULL(@CriticalCount, 0)
SET @WarningCount  = ISNULL(@WarningCount, 0)
SET @InfoCount     = ISNULL(@InfoCount, 0)

IF @ReturnResultSets = 1
BEGIN
    /* 1) Summary */
    SELECT
        ReportSection          = CONVERT(varchar(40), 'SUMMARY'),
        ServerName             = @ServerName,
        DatabaseName           = @TargetDatabase,
        CaptureDate            = @CaptureDate,
        ProductVersion         = @ProductVersion,
        Edition                = @Edition,
        CompatibilityLevel     = @CompatibilityLevel,
        DaysBack               = @DaysBack,
        CutoffTime             = @CutoffTime,
        MinExecutions          = @MinExecutions,
        ActualState            = @ActualState,
        DesiredState           = @DesiredState,
        ReadonlyReason         = @ReadonlyReason,
        CurrentStorageSizeMB   = @CurrentStorageSizeMB,
        MaxStorageSizeMB       = @MaxStorageSizeMB,
        StorageUsedPct         = @StorageUsedPct,
        FlushIntervalSeconds   = @FlushIntervalSeconds,
        IntervalLengthMinutes  = @IntervalLengthMinutes,
        StaleQueryThresholdDays = @StaleQueryThreshold,
        MaxPlansPerQuery       = @MaxPlansPerQuery,
        QueryCaptureMode       = @CaptureMode,
        SizeBasedCleanupMode   = @CleanupMode,
        WaitStatsCaptureMode   = @WaitStatsCaptureMode,
        CapturedQueries        = @CapturedQueries,
        TotalPlans             = @TotalPlans,
        ForcedPlanQueries      = @ForcedPlans,
        MultiPlanQueries       = @MultiPlanQueries,
        TotalExecutions        = @TotalExecutions,
        FailedExecutions       = @FailedExecutions,
        FindingCount           = @FindingCount,
        CriticalFindings       = @CriticalCount,
        WarningFindings        = @WarningCount,
        InfoFindings           = @InfoCount,
        Notes                  = @Note

    /* 2) Prioritized findings */
    SELECT
        ReportSection   = CONVERT(varchar(40), 'FINDINGS'),
        RankOrder       = ROW_NUMBER() OVER (ORDER BY f.PriorityScore DESC, f.Severity DESC, f.MetricNumeric DESC, f.FindingID),
        f.PriorityScore,
        f.Severity,
        f.SeverityLabel,
        f.Category,
        f.ObjectName,
        f.QueryID,
        f.PlanID,
        f.FindingDetail,
        f.SuggestedAction,
        f.MetricNumeric,
        f.MetricLabel,
        f.QueryTextShort
      FROM #Findings AS f
     ORDER BY f.PriorityScore DESC, f.Severity DESC, f.MetricNumeric DESC, f.FindingID

    /* 3) Top queries supporting detail */
    SELECT TOP (@TopN)
        ReportSection      = CONVERT(varchar(40), 'TOP_QUERIES'),
        q.QueryID,
        q.ObjectName,
        q.PlanCount,
        HasForcedPlan      = CASE WHEN q.ForcedPlanCount > 0 THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END,
        q.ForceFailureCount,
        q.Executions,
        q.FailedExecutions,
        AvgDurationMs      = CAST(q.AvgDurationUs / 1000.0 AS decimal(18, 2)),
        MaxDurationMs      = CAST(ISNULL(q.MaxDurationUs, 0) / 1000.0 AS decimal(18, 2)),
        AvgCpuMs           = CAST(q.AvgCpuUs / 1000.0 AS decimal(18, 2)),
        MaxCpuMs           = CAST(ISNULL(q.MaxCpuUs, 0) / 1000.0 AS decimal(18, 2)),
        AvgLogicalReads    = CAST(q.AvgLogicalReads AS decimal(18, 1)),
        TotalLogicalReads  = CAST(q.TotalLogicalReads AS decimal(28, 1)),
        AvgPhysicalReads   = CAST(q.AvgPhysicalReads AS decimal(18, 1)),
        TotalCpuSeconds    = CAST(q.TotalCpuUs / 1000000.0 AS decimal(28, 2)),
        TotalDurationSeconds = CAST(q.TotalDurationUs / 1000000.0 AS decimal(28, 2)),
        q.FirstExecutionTime,
        q.LastExecutionTime,
        QueryTextShort     = CASE WHEN @IncludeQueryText = 1 THEN q.QueryTextShort ELSE NULL END
      FROM #QueryAgg AS q
     WHERE q.Executions >= @MinExecutions
     ORDER BY q.TotalCpuUs DESC, q.TotalDurationUs DESC, q.QueryID
END

RETURN 0
GO

PRINT 'Procedure dbo.ExamineQueryStore created successfully.'
GO
