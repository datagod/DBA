/*
  QueryStoreStatus.sql
  Performance Tuning Framework

  Instance-wide Query Store configuration inventory for every database with
  Query Store enabled. Deploy to the tool database, then execute:

    EXEC dbo.QueryStoreStatus

  Optional parameters:
    @DatabaseFilter         - LIKE filter for database names (default '%')
    @IncludeSystemDatabases - include master, model, msdb, tempdb (default 0)
    @IncludeQueryCounts     - include query/plan/forced-plan counts when readable (default 1)
    @ReturnSummary          - return one-row summary result set first (default 1)

  Notes:
    - Requires SQL Server 2016 (13.x) or later on the instance (Query Store host feature).
    - Procedure deployment and T-SQL are compatibility level 100 safe (no CREATE OR ALTER).
    - Scans user databases with is_query_store_on = 1; per-database options are version-aware.
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
IF OBJECT_ID(N'dbo.QueryStoreStatus', N'P') IS NULL
BEGIN
    EXEC
    (
        N'CREATE PROCEDURE dbo.QueryStoreStatus
          AS
          BEGIN
              SET NOCOUNT ON;
              RETURN 0;
          END;'
    );
END
GO

ALTER PROCEDURE dbo.QueryStoreStatus
(
    @DatabaseFilter         sysname = N'%',
    @IncludeSystemDatabases bit     = 0,
    @IncludeQueryCounts     bit     = 1,
    @ReturnSummary          bit     = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: July 3, 2026
-- Author:       Bill McEvoy
-- Description:  Lists Query Store metadata for every database on the instance that has Query
--               Store enabled. Version-aware option columns; compatibility level 100 safe.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion            tinyint,
    @ProductVersion          varchar(30),
    @ServerName              sysname,
    @ReportTime              datetime,
    @DatabaseName            sysname,
    @DatabaseId              int,
    @CompatibilityLevel      int,
    @StateDesc               nvarchar(60),
    @RecoveryModelDesc       nvarchar(60),
    @IsReadOnly              bit,
    @Sql                     nvarchar(max),
    @OptionsSelectList       nvarchar(max),
    @ActualState             nvarchar(60),
    @DesiredState            nvarchar(60),
    @ReadonlyReason          int,
    @CurrentStorageSizeMB    decimal(12, 2),
    @MaxStorageSizeMB        decimal(12, 2),
    @FlushIntervalSeconds    int,
    @IntervalLengthMinutes   int,
    @StaleQueryThresholdDays int,
    @MaxPlansPerQuery        int,
    @QueryCaptureMode        nvarchar(60),
    @SizeBasedCleanupMode    nvarchar(60),
    @WaitStatsCaptureMode    nvarchar(60),
    @CapturePolicyExecCount  int,
    @CapturePolicyCompileCpu bigint,
    @CapturePolicyExecCpu    bigint,
    @CapturePolicyStaleHours int,
    @QueryCount              int,
    @PlanCount               int,
    @ForcedPlanCount         int,
    @Note                    nvarchar(400),
    @DatabasesScanned        int,
    @DatabasesReadable       int,
    @DatabasesWithError      int

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 13
BEGIN
    RAISERROR('Query Store requires SQL Server 2016 (13.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @ReportTime     = GETDATE()

IF @DatabaseFilter IS NULL OR LTRIM(RTRIM(@DatabaseFilter)) = N''
    SET @DatabaseFilter = N'%'

/* Version-aware option columns. Base set is SQL Server 2016; extras added by major version. */
SET @OptionsSelectList = N'
    @ActualState             = qso.actual_state_desc,
    @DesiredState            = qso.desired_state_desc,
    @ReadonlyReason          = qso.readonly_reason,
    @CurrentStorageSizeMB    = qso.current_storage_size_mb,
    @MaxStorageSizeMB        = qso.max_storage_size_mb,
    @FlushIntervalSeconds    = qso.flush_interval_seconds,
    @IntervalLengthMinutes   = qso.interval_length_minutes,
    @StaleQueryThresholdDays = qso.stale_query_threshold_days,
    @MaxPlansPerQuery        = qso.max_plans_per_query,
    @QueryCaptureMode        = qso.query_capture_mode_desc'

IF @MajorVersion >= 14
    SET @OptionsSelectList = @OptionsSelectList + N',
    @SizeBasedCleanupMode    = qso.size_based_cleanup_mode_desc,
    @WaitStatsCaptureMode    = qso.wait_stats_capture_mode_desc'
ELSE
    SET @OptionsSelectList = @OptionsSelectList + N',
    @SizeBasedCleanupMode    = CAST(NULL AS nvarchar(60)),
    @WaitStatsCaptureMode    = CAST(NULL AS nvarchar(60))'

IF @MajorVersion >= 15
    SET @OptionsSelectList = @OptionsSelectList + N',
    @CapturePolicyExecCount  = qso.capture_policy_execution_count,
    @CapturePolicyCompileCpu = qso.capture_policy_total_compile_cpu_time_ms,
    @CapturePolicyExecCpu    = qso.capture_policy_total_execution_cpu_time_ms,
    @CapturePolicyStaleHours = qso.capture_policy_stale_threshold_hours'
ELSE
    SET @OptionsSelectList = @OptionsSelectList + N',
    @CapturePolicyExecCount  = CAST(NULL AS int),
    @CapturePolicyCompileCpu = CAST(NULL AS bigint),
    @CapturePolicyExecCpu    = CAST(NULL AS bigint),
    @CapturePolicyStaleHours = CAST(NULL AS int)'

IF OBJECT_ID('tempdb..#QueryStoreStatus') IS NOT NULL
    DROP TABLE #QueryStoreStatus

CREATE TABLE #QueryStoreStatus
(
    DatabaseName               sysname         NOT NULL,
    DatabaseId                 int             NOT NULL,
    CompatibilityLevel         int             NULL,
    StateDesc                  nvarchar(60)    NULL,
    RecoveryModelDesc          nvarchar(60)    NULL,
    IsReadOnly                 bit             NULL,
    QueryStoreEnabled          bit             NOT NULL,
    ActualState                nvarchar(60)    NULL,
    DesiredState               nvarchar(60)    NULL,
    ReadonlyReason             int             NULL,
    ReadonlyReasonDesc         nvarchar(400)   NULL,
    IsReadable                 bit             NOT NULL,
    CurrentStorageSizeMB       decimal(12, 2)  NULL,
    MaxStorageSizeMB           decimal(12, 2)  NULL,
    StorageUsedPct             decimal(8, 2)   NULL,
    FlushIntervalSeconds       int             NULL,
    IntervalLengthMinutes      int             NULL,
    StaleQueryThresholdDays    int             NULL,
    MaxPlansPerQuery           int             NULL,
    QueryCaptureMode           nvarchar(60)    NULL,
    SizeBasedCleanupMode       nvarchar(60)    NULL,
    WaitStatsCaptureMode       nvarchar(60)    NULL,
    CapturePolicyExecCount     int             NULL,
    CapturePolicyCompileCpuMs  bigint          NULL,
    CapturePolicyExecCpuMs     bigint          NULL,
    CapturePolicyStaleHours    int             NULL,
    QueryCount                 int             NULL,
    PlanCount                  int             NULL,
    ForcedPlanCount            int             NULL,
    Note                       nvarchar(400)   NULL
)

IF OBJECT_ID('tempdb..#DatabaseList') IS NOT NULL
    DROP TABLE #DatabaseList

CREATE TABLE #DatabaseList
(
    DatabaseName         sysname      NOT NULL,
    DatabaseId           int          NOT NULL,
    CompatibilityLevel   int          NULL,
    StateDesc            nvarchar(60) NULL,
    RecoveryModelDesc    nvarchar(60) NULL,
    IsReadOnly           bit          NULL
)

INSERT INTO #DatabaseList
(
    DatabaseName,
    DatabaseId,
    CompatibilityLevel,
    StateDesc,
    RecoveryModelDesc,
    IsReadOnly
)
SELECT
    d.name,
    d.database_id,
    d.compatibility_level,
    d.state_desc,
    d.recovery_model_desc,
    d.is_read_only
  FROM sys.databases AS d
 WHERE d.is_query_store_on = 1
   AND d.name LIKE @DatabaseFilter
   AND (@IncludeSystemDatabases = 1 OR d.database_id > 4)

DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    DatabaseName,
    DatabaseId,
    CompatibilityLevel,
    StateDesc,
    RecoveryModelDesc,
    IsReadOnly
  FROM #DatabaseList
 ORDER BY DatabaseName

OPEN DatabaseCursor
FETCH NEXT FROM DatabaseCursor INTO
    @DatabaseName,
    @DatabaseId,
    @CompatibilityLevel,
    @StateDesc,
    @RecoveryModelDesc,
    @IsReadOnly

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ActualState             = NULL
    SET @DesiredState            = NULL
    SET @ReadonlyReason          = NULL
    SET @CurrentStorageSizeMB    = NULL
    SET @MaxStorageSizeMB        = NULL
    SET @FlushIntervalSeconds    = NULL
    SET @IntervalLengthMinutes   = NULL
    SET @StaleQueryThresholdDays = NULL
    SET @MaxPlansPerQuery        = NULL
    SET @QueryCaptureMode        = NULL
    SET @SizeBasedCleanupMode    = NULL
    SET @WaitStatsCaptureMode    = NULL
    SET @CapturePolicyExecCount  = NULL
    SET @CapturePolicyCompileCpu = NULL
    SET @CapturePolicyExecCpu    = NULL
    SET @CapturePolicyStaleHours = NULL
    SET @QueryCount              = NULL
    SET @PlanCount               = NULL
    SET @ForcedPlanCount         = NULL
    SET @Note                    = NULL

    IF @StateDesc <> N'ONLINE'
    BEGIN
        INSERT INTO #QueryStoreStatus
        (
            DatabaseName,
            DatabaseId,
            CompatibilityLevel,
            StateDesc,
            RecoveryModelDesc,
            IsReadOnly,
            QueryStoreEnabled,
            IsReadable,
            Note
        )
        VALUES
        (
            @DatabaseName,
            @DatabaseId,
            @CompatibilityLevel,
            @StateDesc,
            @RecoveryModelDesc,
            @IsReadOnly,
            1,
            0,
            N'Database is not ONLINE; Query Store options were not read.'
        )
    END
    ELSE
    BEGIN
        BEGIN TRY
            SET @Sql = N'
SELECT
' + @OptionsSelectList + N'
  FROM ' + QUOTENAME(@DatabaseName) + N'.sys.database_query_store_options AS qso'

            EXEC sys.sp_executesql
                @Sql,
                N'@ActualState nvarchar(60) OUTPUT,
                  @DesiredState nvarchar(60) OUTPUT,
                  @ReadonlyReason int OUTPUT,
                  @CurrentStorageSizeMB decimal(12, 2) OUTPUT,
                  @MaxStorageSizeMB decimal(12, 2) OUTPUT,
                  @FlushIntervalSeconds int OUTPUT,
                  @IntervalLengthMinutes int OUTPUT,
                  @StaleQueryThresholdDays int OUTPUT,
                  @MaxPlansPerQuery int OUTPUT,
                  @QueryCaptureMode nvarchar(60) OUTPUT,
                  @SizeBasedCleanupMode nvarchar(60) OUTPUT,
                  @WaitStatsCaptureMode nvarchar(60) OUTPUT,
                  @CapturePolicyExecCount int OUTPUT,
                  @CapturePolicyCompileCpu bigint OUTPUT,
                  @CapturePolicyExecCpu bigint OUTPUT,
                  @CapturePolicyStaleHours int OUTPUT',
                @ActualState = @ActualState OUTPUT,
                @DesiredState = @DesiredState OUTPUT,
                @ReadonlyReason = @ReadonlyReason OUTPUT,
                @CurrentStorageSizeMB = @CurrentStorageSizeMB OUTPUT,
                @MaxStorageSizeMB = @MaxStorageSizeMB OUTPUT,
                @FlushIntervalSeconds = @FlushIntervalSeconds OUTPUT,
                @IntervalLengthMinutes = @IntervalLengthMinutes OUTPUT,
                @StaleQueryThresholdDays = @StaleQueryThresholdDays OUTPUT,
                @MaxPlansPerQuery = @MaxPlansPerQuery OUTPUT,
                @QueryCaptureMode = @QueryCaptureMode OUTPUT,
                @SizeBasedCleanupMode = @SizeBasedCleanupMode OUTPUT,
                @WaitStatsCaptureMode = @WaitStatsCaptureMode OUTPUT,
                @CapturePolicyExecCount = @CapturePolicyExecCount OUTPUT,
                @CapturePolicyCompileCpu = @CapturePolicyCompileCpu OUTPUT,
                @CapturePolicyExecCpu = @CapturePolicyExecCpu OUTPUT,
                @CapturePolicyStaleHours = @CapturePolicyStaleHours OUTPUT

            IF @IncludeQueryCounts = 1
               AND @ActualState IN (N'READ_WRITE', N'READ_ONLY')
            BEGIN
                SET @Sql = N'
SELECT
    @QueryCount = COUNT(DISTINCT q.query_id),
    @PlanCount = COUNT(DISTINCT p.plan_id),
    @ForcedPlanCount = COUNT(DISTINCT CASE WHEN p.is_forced_plan = 1 THEN p.plan_id END)
  FROM ' + QUOTENAME(@DatabaseName) + N'.sys.query_store_query AS q
  LEFT JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.query_store_plan AS p
    ON p.query_id = q.query_id
 WHERE q.is_internal_query = 0'

                EXEC sys.sp_executesql
                    @Sql,
                    N'@QueryCount int OUTPUT, @PlanCount int OUTPUT, @ForcedPlanCount int OUTPUT',
                    @QueryCount = @QueryCount OUTPUT,
                    @PlanCount = @PlanCount OUTPUT,
                    @ForcedPlanCount = @ForcedPlanCount OUTPUT
            END

            IF @CompatibilityLevel IS NOT NULL AND @CompatibilityLevel < 130
                SET @Note = N'Compatibility level is below 130; Query Store is enabled but may be limited.'

            IF @ActualState NOT IN (N'READ_WRITE', N'READ_ONLY')
                SET @Note = CASE
                                WHEN @Note IS NULL THEN N'Query Store state is not readable.'
                                ELSE @Note + N' Query Store state is not readable.'
                            END
        END TRY
        BEGIN CATCH
            SET @ActualState = N'UNAVAILABLE'
            SET @DesiredState = N'UNAVAILABLE'
            SET @Note = LEFT(ERROR_MESSAGE(), 400)
        END CATCH

        INSERT INTO #QueryStoreStatus
        (
            DatabaseName,
            DatabaseId,
            CompatibilityLevel,
            StateDesc,
            RecoveryModelDesc,
            IsReadOnly,
            QueryStoreEnabled,
            ActualState,
            DesiredState,
            ReadonlyReason,
            ReadonlyReasonDesc,
            IsReadable,
            CurrentStorageSizeMB,
            MaxStorageSizeMB,
            StorageUsedPct,
            FlushIntervalSeconds,
            IntervalLengthMinutes,
            StaleQueryThresholdDays,
            MaxPlansPerQuery,
            QueryCaptureMode,
            SizeBasedCleanupMode,
            WaitStatsCaptureMode,
            CapturePolicyExecCount,
            CapturePolicyCompileCpuMs,
            CapturePolicyExecCpuMs,
            CapturePolicyStaleHours,
            QueryCount,
            PlanCount,
            ForcedPlanCount,
            Note
        )
        SELECT
            @DatabaseName,
            @DatabaseId,
            @CompatibilityLevel,
            @StateDesc,
            @RecoveryModelDesc,
            @IsReadOnly,
            1,
            @ActualState,
            @DesiredState,
            @ReadonlyReason,
            ReadonlyReasonDesc = CASE
                WHEN @ReadonlyReason IS NULL OR @ReadonlyReason = 0 THEN NULL
                ELSE
                    STUFF(
                        CASE WHEN @ReadonlyReason & 1 = 1 THEN N'; Database is in read-only mode' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 2 = 2 THEN N'; Database is in single-user mode' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 4 = 4 THEN N'; Database is in emergency mode' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 8 = 8 THEN N'; Database is a secondary replica' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 65536 = 65536 THEN N'; Query Store reached capacity limit' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 131072 = 131072 THEN N'; Query Store statement memory limit reached' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 262144 = 262144 THEN N'; In-memory persistence queue memory limit reached' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 524288 = 524288 THEN N'; Database disk size limit reached' ELSE N'' END
                      + CASE WHEN @ReadonlyReason & 1048576 = 1048576 THEN N'; Query Store cannot be initialized' ELSE N'' END,
                        1, 2, N''
                    )
            END,
            IsReadable = CASE WHEN @ActualState IN (N'READ_WRITE', N'READ_ONLY') THEN 1 ELSE 0 END,
            @CurrentStorageSizeMB,
            @MaxStorageSizeMB,
            StorageUsedPct = CASE
                                 WHEN @MaxStorageSizeMB IS NULL OR @MaxStorageSizeMB <= 0 THEN NULL
                                 WHEN @CurrentStorageSizeMB IS NULL THEN NULL
                                 ELSE CAST((@CurrentStorageSizeMB * 100.0) / @MaxStorageSizeMB AS decimal(8, 2))
                             END,
            @FlushIntervalSeconds,
            @IntervalLengthMinutes,
            @StaleQueryThresholdDays,
            @MaxPlansPerQuery,
            @QueryCaptureMode,
            @SizeBasedCleanupMode,
            @WaitStatsCaptureMode,
            @CapturePolicyExecCount,
            @CapturePolicyCompileCpu,
            @CapturePolicyExecCpu,
            @CapturePolicyStaleHours,
            @QueryCount,
            @PlanCount,
            @ForcedPlanCount,
            @Note
    END

    FETCH NEXT FROM DatabaseCursor INTO
        @DatabaseName,
        @DatabaseId,
        @CompatibilityLevel,
        @StateDesc,
        @RecoveryModelDesc,
        @IsReadOnly
END

CLOSE DatabaseCursor
DEALLOCATE DatabaseCursor

SELECT
    @DatabasesScanned   = COUNT(*),
    @DatabasesReadable  = SUM(CASE WHEN IsReadable = 1 THEN 1 ELSE 0 END),
    @DatabasesWithError = SUM(CASE WHEN ActualState = N'UNAVAILABLE' THEN 1 ELSE 0 END)
  FROM #QueryStoreStatus

SET @DatabasesScanned   = ISNULL(@DatabasesScanned, 0)
SET @DatabasesReadable  = ISNULL(@DatabasesReadable, 0)
SET @DatabasesWithError = ISNULL(@DatabasesWithError, 0)

IF @ReturnSummary = 1
BEGIN
    SELECT
        ReportTime              = @ReportTime,
        ServerName              = @ServerName,
        ProductVersion          = @ProductVersion,
        SqlInstanceMajorVersion = @MajorVersion,
        DatabaseFilter          = @DatabaseFilter,
        IncludeSystemDatabases  = @IncludeSystemDatabases,
        IncludeQueryCounts      = @IncludeQueryCounts,
        DatabasesWithQueryStore = @DatabasesScanned,
        DatabasesReadable       = @DatabasesReadable,
        DatabasesWithError      = @DatabasesWithError,
        Note = N'Only databases with is_query_store_on = 1 are listed. Option columns depend on the host SQL Server version.'
END

SELECT
    DatabaseName,
    DatabaseId,
    CompatibilityLevel,
    StateDesc,
    RecoveryModelDesc,
    IsReadOnly,
    QueryStoreEnabled,
    ActualState,
    DesiredState,
    ReadonlyReason,
    ReadonlyReasonDesc,
    IsReadable,
    CurrentStorageSizeMB,
    MaxStorageSizeMB,
    StorageUsedPct,
    FlushIntervalSeconds,
    IntervalLengthMinutes,
    StaleQueryThresholdDays,
    MaxPlansPerQuery,
    QueryCaptureMode,
    SizeBasedCleanupMode,
    WaitStatsCaptureMode,
    CapturePolicyExecCount,
    CapturePolicyCompileCpuMs,
    CapturePolicyExecCpuMs,
    CapturePolicyStaleHours,
    QueryCount,
    PlanCount,
    ForcedPlanCount,
    Note
  FROM #QueryStoreStatus
 ORDER BY DatabaseName

GO

IF OBJECT_ID(N'dbo.QueryStoreStatus', N'P') IS NOT NULL
    PRINT 'Procedure QueryStoreStatus created.'
ELSE
    PRINT 'Procedure QueryStoreStatus NOT created.'
GO
