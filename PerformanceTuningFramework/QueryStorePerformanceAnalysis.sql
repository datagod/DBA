
/*
    Centralized Query Store performance analysis.

    @DatabaseName behavior:
      - Supplied: analyze only that database.
      - NULL: analyze every online, accessible user database where
              sys.databases.is_query_store_on = 1.

    The procedure is installed in dbatools, but the Query Store collection
    statements execute through each target database's sys.sp_executesql.
    Results 1 through 4 include database_name.

    Compatibility note:
      CREATE OR ALTER is intentionally not used because dbatools is running
      at compatibility level 100.
*/
IF OBJECT_ID(N'dbo.QueryStorePerformanceAnalysis', N'P') IS NULL
BEGIN
    EXEC
    (
        N'CREATE PROCEDURE dbo.QueryStorePerformanceAnalysis
          AS
          BEGIN
              SET NOCOUNT ON;
              RETURN 0;
          END;'
    );
END;
GO

ALTER PROCEDURE dbo.QueryStorePerformanceAnalysis
      @HoursBack                 int            = 72
    , @CompareHours              int            = 4
    , @TopRows                   int            = 25
    , @MinExecutions             bigint         = 1
    , @RegressionThresholdPct    decimal(9, 2)  = 20.00
    , @SortBy                    varchar(20)     = 'CPU'
    , @QueryId                   bigint         = NULL
    , @IncludeQueryText          bit            = 1
    , @IncludePlanXml            bit            = 0
    , @DatabaseName              sysname        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -------------------------------------------------------------------------
    -- Parameter validation
    -------------------------------------------------------------------------

    IF @HoursBack IS NULL
       OR @HoursBack < 1
       OR @HoursBack > 8760
    BEGIN
        RAISERROR
        (
            '@HoursBack must be between 1 and 8760.',
            16,
            1
        );
        RETURN 1;
    END;

    IF @CompareHours IS NULL
       OR @CompareHours < 1
       OR @CompareHours > 4380
    BEGIN
        RAISERROR
        (
            '@CompareHours must be between 1 and 4380.',
            16,
            1
        );
        RETURN 1;
    END;

    IF @HoursBack < (@CompareHours * 2)
    BEGIN
        RAISERROR
        (
            '@HoursBack must be at least twice @CompareHours.',
            16,
            1
        );
        RETURN 1;
    END;

    IF @TopRows IS NULL
       OR @TopRows < 1
       OR @TopRows > 1000
    BEGIN
        RAISERROR
        (
            '@TopRows must be between 1 and 1000.',
            16,
            1
        );
        RETURN 1;
    END;

    IF @MinExecutions IS NULL
       OR @MinExecutions < 1
    BEGIN
        RAISERROR
        (
            '@MinExecutions must be at least 1.',
            16,
            1
        );
        RETURN 1;
    END;

    IF @RegressionThresholdPct IS NULL
       OR @RegressionThresholdPct < 0
       OR @RegressionThresholdPct > 100000
    BEGIN
        RAISERROR
        (
            '@RegressionThresholdPct must be between 0 and 100000.',
            16,
            1
        );
        RETURN 1;
    END;

    SET @SortBy = UPPER(LTRIM(RTRIM(@SortBy)));

    IF @SortBy NOT IN
       (
           'CPU',
           'DURATION',
           'READS',
           'EXECUTIONS'
       )
    BEGIN
        RAISERROR
        (
            '@SortBy must be CPU, DURATION, READS, or EXECUTIONS.',
            16,
            1
        );
        RETURN 1;
    END;

    IF @DatabaseName IS NOT NULL
    BEGIN
        SET @DatabaseName = LTRIM(RTRIM(@DatabaseName));

        IF @DatabaseName = N''
        BEGIN
            RAISERROR
            (
                '@DatabaseName cannot be an empty string.',
                16,
                1
            );
            RETURN 1;
        END;
    END;

    IF @QueryId IS NOT NULL
       AND @DatabaseName IS NULL
    BEGIN
        RAISERROR
        (
            '@DatabaseName is required when @QueryId is supplied because query_id values are database scoped.',
            16,
            1
        );
        RETURN 1;
    END;

    -------------------------------------------------------------------------
    -- Time boundaries
    -------------------------------------------------------------------------

    DECLARE @AnalysisEndTime       datetimeoffset(7);
    DECLARE @AnalysisStartTime     datetimeoffset(7);
    DECLARE @RecentStartTime       datetimeoffset(7);
    DECLARE @BaselineStartTime     datetimeoffset(7);

    SET @AnalysisEndTime = SYSDATETIMEOFFSET();

    SET @AnalysisStartTime =
        DATEADD
        (
            hour,
            -@HoursBack,
            @AnalysisEndTime
        );

    SET @RecentStartTime =
        DATEADD
        (
            hour,
            -@CompareHours,
            @AnalysisEndTime
        );

    SET @BaselineStartTime =
        DATEADD
        (
            hour,
            -(@CompareHours * 2),
            @AnalysisEndTime
        );

    -------------------------------------------------------------------------
    -- Target databases
    -------------------------------------------------------------------------

    CREATE TABLE #TargetDatabases
    (
          database_id       int       NOT NULL
        , database_name     sysname   NOT NULL
        , PRIMARY KEY CLUSTERED (database_id)
    );

    IF @DatabaseName IS NOT NULL
    BEGIN
        IF DB_ID(@DatabaseName) IS NULL
        BEGIN
            RAISERROR
            (
                'Database %s does not exist.',
                16,
                1,
                @DatabaseName
            );
            RETURN 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM sys.databases
            WHERE name = @DatabaseName
              AND state_desc <> N'ONLINE'
        )
        BEGIN
            RAISERROR
            (
                'Database %s is not ONLINE.',
                16,
                1,
                @DatabaseName
            );
            RETURN 1;
        END;

        IF ISNULL(HAS_DBACCESS(@DatabaseName), 0) <> 1
        BEGIN
            RAISERROR
            (
                'The current login cannot access database %s.',
                16,
                1,
                @DatabaseName
            );
            RETURN 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM sys.databases
            WHERE name = @DatabaseName
              AND is_query_store_on = 0
        )
        BEGIN
            RAISERROR
            (
                'Query Store is not enabled for database %s.',
                16,
                1,
                @DatabaseName
            );
            RETURN 1;
        END;

        INSERT INTO #TargetDatabases
        (
              database_id
            , database_name
        )
        SELECT
              database_id
            , name
        FROM sys.databases
        WHERE name = @DatabaseName;
    END
    ELSE
    BEGIN
        INSERT INTO #TargetDatabases
        (
              database_id
            , database_name
        )
        SELECT
              d.database_id
            , d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = N'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_query_store_on = 1
          AND HAS_DBACCESS(d.name) = 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM #TargetDatabases
        )
        BEGIN
            RAISERROR
            (
                'No online, accessible user databases have Query Store enabled.',
                10,
                1
            );
            RETURN 0;
        END;
    END;

    -------------------------------------------------------------------------
    -- Central collection tables
    -------------------------------------------------------------------------

    CREATE TABLE #QSStatus
    (
          database_id                    int             NOT NULL
        , compatibility_level            tinyint         NULL
        , actual_state                   tinyint         NULL
        , actual_state_desc              nvarchar(60)    NULL
        , desired_state_desc             nvarchar(60)    NULL
        , readonly_reason                bigint          NULL
        , query_capture_mode_desc        nvarchar(60)    NULL
        , size_based_cleanup_mode_desc   nvarchar(60)    NULL
        , current_storage_size_mb        bigint          NULL
        , max_storage_size_mb            bigint          NULL
        , interval_length_minutes        bigint          NULL
        , flush_interval_seconds         bigint          NULL
        , stale_query_threshold_days     bigint          NULL
        , max_plans_per_query            bigint          NULL
        , PRIMARY KEY CLUSTERED (database_id)
    );

    CREATE TABLE #QSQuery
    (
          database_id          int              NOT NULL
        , query_id             bigint           NOT NULL
        , query_text_id        bigint           NOT NULL
        , object_id            bigint           NULL
        , query_hash           varbinary(8)     NULL
        , containing_object    nvarchar(517)    NULL
        , query_sql_text       nvarchar(max)    NULL
        , PRIMARY KEY CLUSTERED
              (
                    database_id
                  , query_id
              )
    );

    CREATE TABLE #QSPlan
    (
          database_id                 int              NOT NULL
        , plan_id                     bigint           NOT NULL
        , query_id                    bigint           NOT NULL
        , is_forced_plan              bit              NULL
        , plan_compatibility_level    smallint         NULL
        , engine_version              nvarchar(32)     NULL
        , query_plan                  nvarchar(max)    NULL
        , PRIMARY KEY CLUSTERED
              (
                    database_id
                  , plan_id
              )
    );

    CREATE NONCLUSTERED INDEX IX_QSPlan_Query
        ON #QSPlan
        (
              database_id
            , query_id
        );

    CREATE TABLE #QSRuntime
    (
          database_id                 int                NOT NULL
        , query_id                    bigint             NOT NULL
        , query_text_id               bigint             NOT NULL
        , object_id                   bigint             NULL
        , query_hash                  varbinary(8)       NULL
        , plan_id                     bigint             NOT NULL
        , is_forced_plan              bit                NULL
        , plan_compatibility_level    smallint           NULL
        , engine_version              nvarchar(32)       NULL
        , runtime_stats_interval_id   bigint             NOT NULL
        , interval_start              datetimeoffset(7)  NOT NULL
        , interval_end                datetimeoffset(7)  NOT NULL
        , first_execution_time        datetimeoffset(7)  NULL
        , last_execution_time         datetimeoffset(7)  NULL
        , execution_count             bigint             NOT NULL
        , total_duration_us           float              NOT NULL
        , total_cpu_us                float              NOT NULL
        , total_logical_reads         float              NOT NULL
        , total_logical_writes        float              NOT NULL
        , total_physical_reads        float              NOT NULL
        , max_duration_us             bigint             NULL
        , max_cpu_us                  bigint             NULL
    );

    CREATE TABLE #DatabaseMessages
    (
          database_id       int              NOT NULL
        , message_severity  int              NOT NULL
        , message_text      nvarchar(4000)   NOT NULL
        , error_number      int              NULL
        , error_state       int              NULL
        , error_line        int              NULL
        , error_procedure   nvarchar(128)    NULL
    );

    -------------------------------------------------------------------------
    -- Build the database-context collection batch
    -------------------------------------------------------------------------

    DECLARE @CollectorSql          nvarchar(max);
    DECLARE @CollectorParameters   nvarchar(max);

    SET @CollectorSql = N'';
    SET @CollectorSql = @CollectorSql + N'SET NOCOUNT ON;

/* QSPerformanceAnalysisCollector: status */
INSERT INTO #QSStatus
(
      database_id
    , compatibility_level
    , actual_state
    , actual_state_desc
    , desired_state_desc
    , readonly_reason
    , query_capture_mode_desc
    , size_based_cleanup_mode_desc
    , current_storage_size_mb
    , max_storage_size_mb
    , interval_length_minutes
    , flush_interval_seconds
    , stale_query_threshold_days
    , max_plans_per_query
)
SELECT
      @TargetDatabaseId
    , d.compatibility_level
    , qso.actual_state
    , qso.actual_state_desc
    , qso.desired_state_desc
    , qso.readonly_reason
    , qso.query_capture_mode_desc
    , qso.size_based_cleanup_mode_desc
    , qso.current_storage_size_mb
    , qso.max_storage_size_mb
    , qso.interval_length_minutes
    , qso.flush_interval_seconds
    , qso.stale_query_threshold_days
    , qso.max_plans_per_query
FROM sys.databases AS d
CROSS JOIN sys.database_query_store_options AS qso
WHERE d.database_id = DB_ID();

IF EXISTS
(
    SELECT 1
    FROM sys.database_query_store_options
    WHERE actual_state = 0
)
BEGIN
    INSERT INTO #DatabaseMessages
    (
          database_id
        , message_severity
        , message_text
    )
    VALUES
    (
          @TargetDatabaseId
        , 10
        , N''Query Store is currently OFF.''
    );

    RETURN;
END;

/* QSPerformanceAnalysisCollector: query metadata */
INSERT INTO #QSQuery
(
      database_id
    , query_id
    , query_text_id
    , object_id
    , query_hash
    , containing_object
    , query_sql_text
)
SELECT
      @TargetDatabaseId
    , q.query_id
    , q.query_text_id
    , q.object_id
    , q.query_hash
    , CASE
          WHEN ISNULL(q.object_id, 0) = 0
              THEN N''<ad hoc>''
          ELSE
              COALESCE
              (
                  QUOTENAME
                  (
                      OBJECT_SCHEMA_NAME
                      (
                          CONVERT(int, q.object_id),
                          DB_ID()
                      )
                  )
                  + N''.''
                  + QUOTENAME
                    (
                        OBJECT_NAME
                        (
                            CONVERT(int, q.object_id),
                            DB_ID()
                        )
                    ),
                  N''<object_id=''
                  + CONVERT(nvarchar(20), q.object_id)
                  + N''>''
              )
      END
    , CASE
          WHEN @IncludeQueryText = 1
              THEN qt.query_sql_text
          ELSE CONVERT(nvarchar(max), NULL)
      END
FROM sys.query_store_query AS q
INNER JOIN sys.query_store_query_text AS qt
    ON qt.query_text_id = q.query_text_id
WHERE
    (
        @QueryId IS NULL
        OR q.query_id = @QueryId
    )
    AND qt.query_sql_text NOT LIKE
        N''%QSPerformanceAnalysisCollector:%'';

/* QSPerformanceAnalysisCollector: plans */
INSERT INTO #QSPlan
(
      database_id
    , plan_id
    , query_id
';
    SET @CollectorSql = @CollectorSql + N'    , is_forced_plan
    , plan_compatibility_level
    , engine_version
    , query_plan
)
SELECT
      @TargetDatabaseId
    , p.plan_id
    , p.query_id
    , p.is_forced_plan
    , p.compatibility_level
    , p.engine_version
    , CASE
          WHEN @IncludePlanXml = 1
              THEN p.query_plan
          ELSE CONVERT(nvarchar(max), NULL)
      END
FROM sys.query_store_plan AS p
INNER JOIN #QSQuery AS q
    ON q.database_id = @TargetDatabaseId
   AND q.query_id = p.query_id;

/* QSPerformanceAnalysisCollector: runtime statistics */
INSERT INTO #QSRuntime
(
      database_id
    , query_id
    , query_text_id
    , object_id
    , query_hash
    , plan_id
    , is_forced_plan
    , plan_compatibility_level
    , engine_version
    , runtime_stats_interval_id
    , interval_start
    , interval_end
    , first_execution_time
    , last_execution_time
    , execution_count
    , total_duration_us
    , total_cpu_us
    , total_logical_reads
    , total_logical_writes
    , total_physical_reads
    , max_duration_us
    , max_cpu_us
)
SELECT
      @TargetDatabaseId
    , q.query_id
    , q.query_text_id
    , q.object_id
    , q.query_hash
    , p.plan_id
    , p.is_forced_plan
    , p.plan_compatibility_level
    , p.engine_version
    , rs.runtime_stats_interval_id
    , rsi.start_time
    , rsi.end_time
    , rs.first_execution_time
    , rs.last_execution_time
    , rs.count_executions
    , CONVERT(float, rs.avg_duration)
      * CONVERT(float, rs.count_executions)
    , CONVERT(float, rs.avg_cpu_time)
      * CONVERT(float, rs.count_executions)
    , CONVERT(float, rs.avg_logical_io_reads)
      * CONVERT(float, rs.count_executions)
    , CONVERT(float, rs.avg_logical_io_writes)
      * CONVERT(float, rs.count_executions)
    , CONVERT(float, rs.avg_physical_io_reads)
      * CONVERT(float, rs.count_executions)
    , rs.max_duration
    , rs.max_cpu_time
FROM sys.query_store_runtime_stats AS rs
INNER JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rsi.runtime_stats_interval_id =
       rs.runtime_stats_interval_id
INNER JOIN #QSPlan AS p
    ON p.database_id = @TargetDatabaseId
   AND p.plan_id = rs.plan_id
INNER JOIN #QSQuery AS q
    ON q.database_id = p.database_id
   AND q.query_id = p.query_id
WHERE rs.execution_type = 0
  AND rsi.end_time > @AnalysisStartTime
  AND rsi.start_time < @AnalysisEndTime
OPTION (RECOMPILE);

IF NOT EXISTS
(
    SELECT 1
    FROM #QSRuntime
    WHERE database_id = @TargetDatabaseId
)
BEGIN
    INSERT INTO #DatabaseMessages
    (
          database_id
        , message_severity
        , message_text
    )
    VALUES
    (
          @TargetDatabaseId
        , 10
        , N''No successful Query Store executions were found for the requested period.''
    );
END;
';

    SET @CollectorParameters =
        N'@TargetDatabaseId int,
          @AnalysisStartTime datetimeoffset(7),
          @AnalysisEndTime datetimeoffset(7),
          @QueryId bigint,
          @IncludeQueryText bit,
          @IncludePlanXml bit';

    -------------------------------------------------------------------------
    -- Collect each database
    -------------------------------------------------------------------------

    DECLARE @CurrentDatabaseId     int;
    DECLARE @CurrentDatabaseName   sysname;
    DECLARE @QualifiedExecutor     nvarchar(776);
    DECLARE @ErrorText             nvarchar(4000);

    DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT
              database_id
            , database_name
        FROM #TargetDatabases
        ORDER BY database_name;

    OPEN DatabaseCursor;

    FETCH NEXT FROM DatabaseCursor
        INTO
              @CurrentDatabaseId
            , @CurrentDatabaseName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        RAISERROR
        (
            'Analyzing Query Store database: %s',
            10,
            1,
            @CurrentDatabaseName
        ) WITH NOWAIT;

        BEGIN TRY
            SET @QualifiedExecutor =
                QUOTENAME(@CurrentDatabaseName)
                + N'.sys.sp_executesql';

            EXEC @QualifiedExecutor
                  @CollectorSql
                , @CollectorParameters
                , @CurrentDatabaseId
                , @AnalysisStartTime
                , @AnalysisEndTime
                , @QueryId
                , @IncludeQueryText
                , @IncludePlanXml;
        END TRY
        BEGIN CATCH
            SET @ErrorText =
                N'Collection failed for database '
                + QUOTENAME(@CurrentDatabaseName)
                + N': '
                + ERROR_MESSAGE();

            INSERT INTO #DatabaseMessages
            (
                  database_id
                , message_severity
                , message_text
                , error_number
                , error_state
                , error_line
                , error_procedure
            )
            VALUES
            (
                  @CurrentDatabaseId
                , 16
                , @ErrorText
                , ERROR_NUMBER()
                , ERROR_STATE()
                , ERROR_LINE()
                , ERROR_PROCEDURE()
            );

            IF @DatabaseName IS NOT NULL
            BEGIN
                CLOSE DatabaseCursor;
                DEALLOCATE DatabaseCursor;

                RAISERROR
                (
                    '%s',
                    16,
                    1,
                    @ErrorText
                );
                RETURN 1;
            END;
        END CATCH;

        FETCH NEXT FROM DatabaseCursor
            INTO
                  @CurrentDatabaseId
                , @CurrentDatabaseName;
    END;

    CLOSE DatabaseCursor;
    DEALLOCATE DatabaseCursor;

    CREATE CLUSTERED INDEX CX_QSRuntime
        ON #QSRuntime
        (
              database_id
            , query_id
            , interval_start
            , plan_id
        );

    CREATE NONCLUSTERED INDEX IX_QSRuntime_Plan
        ON #QSRuntime
        (
              database_id
            , plan_id
            , interval_start
        );

    -------------------------------------------------------------------------
    -- Result set 1: Query Store configuration and report boundaries
    -------------------------------------------------------------------------

    SELECT
          N'QUERY_STORE_STATUS' AS report_section
        , d.database_name
        , s.compatibility_level
        , CONVERT(varchar(128), SERVERPROPERTY('ProductVersion'))
              AS product_version
        , CONVERT(varchar(128), SERVERPROPERTY('Edition'))
              AS edition
        , s.actual_state_desc
        , s.desired_state_desc
        , s.readonly_reason
        , s.query_capture_mode_desc
        , s.size_based_cleanup_mode_desc
        , s.current_storage_size_mb
        , s.max_storage_size_mb
        , CONVERT
          (
              decimal(9, 2),
              CASE
                  WHEN s.max_storage_size_mb = 0
                      THEN NULL
                  ELSE
                      s.current_storage_size_mb
                      * 100.0
                      / s.max_storage_size_mb
              END
          ) AS storage_used_pct
        , s.interval_length_minutes
        , s.flush_interval_seconds
        , s.stale_query_threshold_days
        , s.max_plans_per_query
        , @AnalysisStartTime AS analysis_start_time
        , @AnalysisEndTime AS analysis_end_time
        , @BaselineStartTime AS baseline_start_time
        , @RecentStartTime AS recent_start_time
        , @AnalysisEndTime AS recent_end_time
        , @HoursBack AS analysis_hours
        , @CompareHours AS comparison_period_hours
    FROM #TargetDatabases AS d
    LEFT JOIN #QSStatus AS s
        ON s.database_id = d.database_id
    ORDER BY d.database_name;

    -------------------------------------------------------------------------
    -- Result set 2: Top queries for the complete analysis period
    -- @TopRows is applied separately to each database.
    -------------------------------------------------------------------------

    ;WITH QueryTotals AS
    (
        SELECT
              r.database_id
            , r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
            , COUNT(DISTINCT r.plan_id) AS plan_count
            , MAX
              (
                  CONVERT
                  (
                      tinyint,
                      ISNULL(r.is_forced_plan, 0)
                  )
              ) AS has_forced_plan
            , MIN(r.plan_compatibility_level)
                  AS minimum_plan_compatibility_level
            , MAX(r.plan_compatibility_level)
                  AS maximum_plan_compatibility_level
            , SUM(r.execution_count) AS execution_count
            , SUM(r.total_duration_us) AS total_duration_us
            , SUM(r.total_cpu_us) AS total_cpu_us
            , SUM(r.total_logical_reads) AS total_logical_reads
            , SUM(r.total_logical_writes) AS total_logical_writes
            , SUM(r.total_physical_reads) AS total_physical_reads
            , MAX(r.max_duration_us) AS maximum_duration_us
            , MAX(r.max_cpu_us) AS maximum_cpu_us
            , MIN(r.first_execution_time) AS first_execution_time
            , MAX(r.last_execution_time) AS last_execution_time
        FROM #QSRuntime AS r
        GROUP BY
              r.database_id
            , r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
        HAVING SUM(r.execution_count) >= @MinExecutions
    ),
    RankedQueryTotals AS
    (
        SELECT
              t.*
            , ROW_NUMBER() OVER
              (
                  PARTITION BY t.database_id
                  ORDER BY
                      CASE
                          WHEN @SortBy = 'CPU'
                              THEN t.total_cpu_us
                      END DESC,
                      CASE
                          WHEN @SortBy = 'DURATION'
                              THEN t.total_duration_us
                      END DESC,
                      CASE
                          WHEN @SortBy = 'READS'
                              THEN t.total_logical_reads
                      END DESC,
                      CASE
                          WHEN @SortBy = 'EXECUTIONS'
                              THEN CONVERT(float, t.execution_count)
                      END DESC,
                      t.total_cpu_us DESC,
                      t.query_id
              ) AS database_rank
        FROM QueryTotals AS t
    )
    SELECT
          N'TOP_QUERIES' AS report_section
        , d.database_name
        , t.database_rank
        , t.query_id
        , CONVERT(varchar(18), t.query_hash, 1) AS query_hash
        , q.containing_object
        , t.plan_count
        , t.has_forced_plan
        , t.minimum_plan_compatibility_level
        , t.maximum_plan_compatibility_level
        , t.execution_count
        , CONVERT
          (
              decimal(28, 2),
              t.total_cpu_us / 1000000.0
          ) AS total_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_duration_us / 1000000.0
          ) AS total_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_cpu_us
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
              / 1000000.0
          ) AS average_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_duration_us
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
              / 1000000.0
          ) AS average_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_cpu_us) / 1000000.0
          ) AS maximum_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_duration_us) / 1000000.0
          ) AS maximum_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_logical_reads
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
          ) AS average_logical_reads
        , CONVERT
          (
              decimal(28, 2),
              t.total_logical_reads
          ) AS total_logical_reads
        , CONVERT
          (
              decimal(28, 2),
              t.total_logical_writes
          ) AS total_logical_writes
        , CONVERT
          (
              decimal(28, 2),
              t.total_physical_reads
          ) AS total_physical_reads
        , t.first_execution_time
        , t.last_execution_time
        , q.query_sql_text
    FROM RankedQueryTotals AS t
    INNER JOIN #TargetDatabases AS d
        ON d.database_id = t.database_id
    INNER JOIN #QSQuery AS q
        ON q.database_id = t.database_id
       AND q.query_id = t.query_id
    WHERE t.database_rank <= @TopRows
    ORDER BY
          d.database_name
        , t.database_rank;

    -------------------------------------------------------------------------
    -- Result set 3: Recent-period regressions
    -------------------------------------------------------------------------

    ;WITH ComparisonTotals AS
    (
        SELECT
              r.database_id
            , r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
            , COUNT
              (
                  DISTINCT
                  CASE
                      WHEN r.interval_start >= @BaselineStartTime
                       AND r.interval_end <= @RecentStartTime
                          THEN r.plan_id
                      ELSE NULL
                  END
              ) AS baseline_plan_count
            , COUNT
              (
                  DISTINCT
                  CASE
                      WHEN r.interval_start >= @RecentStartTime
                       AND r.interval_end <= @AnalysisEndTime
                          THEN r.plan_id
                      ELSE NULL
                  END
              ) AS recent_plan_count
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @BaselineStartTime
                       AND r.interval_end <= @RecentStartTime
                          THEN r.execution_count
                      ELSE CONVERT(bigint, 0)
                  END
              ) AS baseline_executions
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @RecentStartTime
                       AND r.interval_end <= @AnalysisEndTime
                          THEN r.execution_count
                      ELSE CONVERT(bigint, 0)
                  END
              ) AS recent_executions
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @BaselineStartTime
                       AND r.interval_end <= @RecentStartTime
                          THEN r.total_duration_us
                      ELSE CONVERT(float, 0.0)
                  END
              ) AS baseline_duration_us
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @RecentStartTime
                       AND r.interval_end <= @AnalysisEndTime
                          THEN r.total_duration_us
                      ELSE CONVERT(float, 0.0)
                  END
              ) AS recent_duration_us
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @BaselineStartTime
                       AND r.interval_end <= @RecentStartTime
                          THEN r.total_cpu_us
                      ELSE CONVERT(float, 0.0)
                  END
              ) AS baseline_cpu_us
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @RecentStartTime
                       AND r.interval_end <= @AnalysisEndTime
                          THEN r.total_cpu_us
                      ELSE CONVERT(float, 0.0)
                  END
              ) AS recent_cpu_us
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @BaselineStartTime
                       AND r.interval_end <= @RecentStartTime
                          THEN r.total_logical_reads
                      ELSE CONVERT(float, 0.0)
                  END
              ) AS baseline_logical_reads
            , SUM
              (
                  CASE
                      WHEN r.interval_start >= @RecentStartTime
                       AND r.interval_end <= @AnalysisEndTime
                          THEN r.total_logical_reads
                      ELSE CONVERT(float, 0.0)
                  END
              ) AS recent_logical_reads
            , MAX
              (
                  CONVERT
                  (
                      tinyint,
                      ISNULL(r.is_forced_plan, 0)
                  )
              ) AS has_forced_plan
        FROM #QSRuntime AS r
        WHERE r.interval_start >= @BaselineStartTime
        GROUP BY
              r.database_id
            , r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
    ),
    AverageMetrics AS
    (
        SELECT
              c.*
            , c.baseline_duration_us
              / NULLIF
                (
                    CONVERT(float, c.baseline_executions),
                    0.0
                ) AS baseline_average_duration_us
            , c.recent_duration_us
              / NULLIF
                (
                    CONVERT(float, c.recent_executions),
                    0.0
                ) AS recent_average_duration_us
            , c.baseline_cpu_us
              / NULLIF
                (
                    CONVERT(float, c.baseline_executions),
                    0.0
                ) AS baseline_average_cpu_us
            , c.recent_cpu_us
              / NULLIF
                (
                    CONVERT(float, c.recent_executions),
                    0.0
                ) AS recent_average_cpu_us
            , c.baseline_logical_reads
              / NULLIF
                (
                    CONVERT(float, c.baseline_executions),
                    0.0
                ) AS baseline_average_logical_reads
            , c.recent_logical_reads
              / NULLIF
                (
                    CONVERT(float, c.recent_executions),
                    0.0
                ) AS recent_average_logical_reads
        FROM ComparisonTotals AS c
    ),
    RegressionRatios AS
    (
        SELECT
              m.*
            , m.recent_average_duration_us
              / NULLIF
                (
                    m.baseline_average_duration_us,
                    0.0
                ) AS duration_ratio
            , m.recent_average_cpu_us
              / NULLIF
                (
                    m.baseline_average_cpu_us,
                    0.0
                ) AS cpu_ratio
        FROM AverageMetrics AS m
    ),
    RankedRegressions AS
    (
        SELECT
              r.*
            , CASE
                  WHEN r.duration_ratio IS NULL
                      THEN r.cpu_ratio
                  WHEN r.cpu_ratio IS NULL
                      THEN r.duration_ratio
                  WHEN r.duration_ratio >= r.cpu_ratio
                      THEN r.duration_ratio
                  ELSE r.cpu_ratio
              END AS worst_regression_ratio
        FROM RegressionRatios AS r
    ),
    NumberedRegressions AS
    (
        SELECT
              r.*
            , ROW_NUMBER() OVER
              (
                  PARTITION BY r.database_id
                  ORDER BY
                        r.worst_regression_ratio DESC
                      , r.recent_cpu_us DESC
                      , r.query_id
              ) AS database_rank
        FROM RankedRegressions AS r
        WHERE r.baseline_executions >= @MinExecutions
          AND r.recent_executions >= @MinExecutions
          AND r.worst_regression_ratio >=
              (
                  1.0
                  + CONVERT(float, @RegressionThresholdPct)
                    / 100.0
              )
    )
    SELECT
          N'REGRESSIONS' AS report_section
        , d.database_name
        , r.database_rank
        , r.query_id
        , CONVERT(varchar(18), r.query_hash, 1) AS query_hash
        , q.containing_object
        , r.has_forced_plan
        , r.baseline_plan_count
        , r.recent_plan_count
        , r.baseline_executions
        , r.recent_executions
        , CONVERT
          (
              decimal(28, 2),
              r.baseline_average_duration_us / 1000000.0
          ) AS baseline_average_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              r.recent_average_duration_us / 1000000.0
          ) AS recent_average_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              (r.duration_ratio - 1.0) * 100.0
          ) AS duration_change_pct
        , CONVERT
          (
              decimal(28, 2),
              r.baseline_average_cpu_us / 1000000.0
          ) AS baseline_average_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              r.recent_average_cpu_us / 1000000.0
          ) AS recent_average_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              (r.cpu_ratio - 1.0) * 100.0
          ) AS cpu_change_pct
        , CONVERT
          (
              decimal(28, 2),
              r.baseline_average_logical_reads
          ) AS baseline_average_logical_reads
        , CONVERT
          (
              decimal(28, 2),
              r.recent_average_logical_reads
          ) AS recent_average_logical_reads
        , CONVERT
          (
              decimal(28, 2),
              r.baseline_duration_us / 1000000.0
          ) AS baseline_total_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              r.recent_duration_us / 1000000.0
          ) AS recent_total_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              r.worst_regression_ratio
          ) AS worst_regression_ratio
        , q.query_sql_text
    FROM NumberedRegressions AS r
    INNER JOIN #TargetDatabases AS d
        ON d.database_id = r.database_id
    INNER JOIN #QSQuery AS q
        ON q.database_id = r.database_id
       AND q.query_id = r.query_id
    WHERE r.database_rank <= @TopRows
    ORDER BY
          d.database_name
        , r.database_rank;

    -------------------------------------------------------------------------
    -- Result set 4: Plan-level resource consumption
    -- @TopRows is applied separately to each database.
    -------------------------------------------------------------------------

    ;WITH PlanTotals AS
    (
        SELECT
              r.database_id
            , r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
            , r.plan_id
            , MAX
              (
                  CONVERT
                  (
                      tinyint,
                      ISNULL(r.is_forced_plan, 0)
                  )
              ) AS is_forced_plan
            , MAX(r.plan_compatibility_level)
                  AS plan_compatibility_level
            , MAX(r.engine_version)
                  AS engine_version
            , SUM(r.execution_count)
                  AS execution_count
            , SUM(r.total_duration_us)
                  AS total_duration_us
            , SUM(r.total_cpu_us)
                  AS total_cpu_us
            , SUM(r.total_logical_reads)
                  AS total_logical_reads
            , SUM(r.total_logical_writes)
                  AS total_logical_writes
            , SUM(r.total_physical_reads)
                  AS total_physical_reads
            , MAX(r.max_duration_us)
                  AS maximum_duration_us
            , MAX(r.max_cpu_us)
                  AS maximum_cpu_us
            , MIN(r.first_execution_time)
                  AS first_execution_time
            , MAX(r.last_execution_time)
                  AS last_execution_time
        FROM #QSRuntime AS r
        GROUP BY
              r.database_id
            , r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
            , r.plan_id
        HAVING SUM(r.execution_count) >= @MinExecutions
    ),
    RankedPlanTotals AS
    (
        SELECT
              t.*
            , ROW_NUMBER() OVER
              (
                  PARTITION BY t.database_id
                  ORDER BY
                      CASE
                          WHEN @SortBy = 'CPU'
                              THEN t.total_cpu_us
                      END DESC,
                      CASE
                          WHEN @SortBy = 'DURATION'
                              THEN t.total_duration_us
                      END DESC,
                      CASE
                          WHEN @SortBy = 'READS'
                              THEN t.total_logical_reads
                      END DESC,
                      CASE
                          WHEN @SortBy = 'EXECUTIONS'
                              THEN CONVERT(float, t.execution_count)
                      END DESC,
                      t.total_cpu_us DESC,
                      t.query_id,
                      t.plan_id
              ) AS database_rank
        FROM PlanTotals AS t
    )
    SELECT
          N'PLAN_DETAILS' AS report_section
        , d.database_name
        , t.database_rank
        , t.query_id
        , t.plan_id
        , CONVERT(varchar(18), t.query_hash, 1) AS query_hash
        , q.containing_object
        , t.is_forced_plan
        , t.plan_compatibility_level
        , t.engine_version
        , t.execution_count
        , CONVERT
          (
              decimal(28, 2),
              t.total_cpu_us / 1000000.0
          ) AS total_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_duration_us / 1000000.0
          ) AS total_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_cpu_us
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
              / 1000000.0
          ) AS average_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_duration_us
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
              / 1000000.0
          ) AS average_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_cpu_us) / 1000000.0
          ) AS maximum_cpu_seconds
        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_duration_us) / 1000000.0
          ) AS maximum_duration_seconds
        , CONVERT
          (
              decimal(28, 2),
              t.total_logical_reads
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
          ) AS average_logical_reads
        , CONVERT
          (
              decimal(28, 2),
              t.total_logical_reads
          ) AS total_logical_reads
        , CONVERT
          (
              decimal(28, 2),
              t.total_logical_writes
          ) AS total_logical_writes
        , CONVERT
          (
              decimal(28, 2),
              t.total_physical_reads
          ) AS total_physical_reads
        , t.first_execution_time
        , t.last_execution_time
        , q.query_sql_text
        , p.query_plan
    FROM RankedPlanTotals AS t
    INNER JOIN #TargetDatabases AS d
        ON d.database_id = t.database_id
    INNER JOIN #QSQuery AS q
        ON q.database_id = t.database_id
       AND q.query_id = t.query_id
    INNER JOIN #QSPlan AS p
        ON p.database_id = t.database_id
       AND p.plan_id = t.plan_id
    WHERE t.database_rank <= @TopRows
    ORDER BY
          d.database_name
        , t.database_rank;

    -------------------------------------------------------------------------
    -- Optional result set 5: informational messages and collection errors
    -------------------------------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM #DatabaseMessages
    )
    BEGIN
        SELECT
              N'DATABASE_MESSAGES' AS report_section
            , d.database_name
            , m.message_severity
            , m.message_text
            , m.error_number
            , m.error_state
            , m.error_line
            , m.error_procedure
        FROM #DatabaseMessages AS m
        INNER JOIN #TargetDatabases AS d
            ON d.database_id = m.database_id
        ORDER BY
              d.database_name
            , m.message_severity DESC;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM #DatabaseMessages
        WHERE message_severity >= 16
    )
    BEGIN
        RETURN 1;
    END;

    RETURN 0;
END;
GO

/*
    Examples

    -- One database
    EXEC dbo.QueryStorePerformanceAnalysis
          @DatabaseName = N'YourDatabase'
        , @HoursBack = 72
        , @CompareHours = 4
        , @TopRows = 25
        , @SortBy = 'CPU';

    -- Every online, accessible user database with Query Store enabled
    EXEC dbo.QueryStorePerformanceAnalysis
          @HoursBack = 72
        , @CompareHours = 4
        , @TopRows = 25
        , @SortBy = 'CPU';

    -- One Query Store query_id in one database
    EXEC dbo.QueryStorePerformanceAnalysis
          @DatabaseName = N'YourDatabase'
        , @QueryId = 12345
        , @IncludeQueryText = 1
        , @IncludePlanXml = 1;
*/


