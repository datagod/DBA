USE dbatools
GO

/*
    Compatibility-safe replacement pattern.

    CREATE OR ALTER is intentionally not used because this database
    is running at compatibility level 100.
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
        RETURN;
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
        RETURN;
    END;

    IF @HoursBack < (@CompareHours * 2)
    BEGIN
        RAISERROR
        (
            '@HoursBack must be at least twice @CompareHours.',
            16,
            1
        );
        RETURN;
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
        RETURN;
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
        RETURN;
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
        RETURN;
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
        RETURN;
    END;

    -------------------------------------------------------------------------
    -- Time boundaries
    -------------------------------------------------------------------------

    DECLARE @AnalysisEndTime       datetimeoffset(7);
    DECLARE @AnalysisStartTime     datetimeoffset(7);
    DECLARE @RecentStartTime       datetimeoffset(7);
    DECLARE @BaselineStartTime     datetimeoffset(7);

    SET @AnalysisEndTime =
        SYSDATETIMEOFFSET();

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
    -- Result set 1: Query Store configuration and report boundaries
    -------------------------------------------------------------------------

    SELECT
          N'QUERY_STORE_STATUS' AS report_section
        , DB_NAME() AS database_name
        , d.compatibility_level
        , CONVERT(varchar(128), SERVERPROPERTY('ProductVersion'))
            AS product_version
        , CONVERT(varchar(128), SERVERPROPERTY('Edition'))
            AS edition
        , qso.actual_state_desc
        , qso.desired_state_desc
        , qso.readonly_reason
        , qso.query_capture_mode_desc
        , qso.size_based_cleanup_mode_desc
        , qso.current_storage_size_mb
        , qso.max_storage_size_mb
        , CONVERT
          (
              decimal(9, 2),
              CASE
                  WHEN qso.max_storage_size_mb = 0
                      THEN NULL
                  ELSE
                      qso.current_storage_size_mb
                      * 100.0
                      / qso.max_storage_size_mb
              END
          ) AS storage_used_pct
        , qso.interval_length_minutes
        , qso.flush_interval_seconds
        , qso.stale_query_threshold_days
        , qso.max_plans_per_query
        , @AnalysisStartTime AS analysis_start_time
        , @AnalysisEndTime AS analysis_end_time
        , @BaselineStartTime AS baseline_start_time
        , @RecentStartTime AS recent_start_time
        , @AnalysisEndTime AS recent_end_time
        , @HoursBack AS analysis_hours
        , @CompareHours AS comparison_period_hours
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
        RAISERROR
        (
            'Query Store is currently OFF for database %s.',
            16,
            1,
            'whatever'
        );
        RETURN;
    END;

    -------------------------------------------------------------------------
    -- Collect Query Store runtime rows once.
    --
    -- We store weighted totals:
    --
    --     average metric * execution count
    --
    -- This correctly combines metrics from multiple Query Store intervals.
    -------------------------------------------------------------------------

    CREATE TABLE #QSRuntime
    (
          query_id                    bigint             NOT NULL
        , query_text_id               bigint             NOT NULL
        , object_id                   bigint             NULL
        , query_hash                  varbinary(8)        NULL
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

    INSERT INTO #QSRuntime
    (
          query_id
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
          q.query_id
        , q.query_text_id
        , q.object_id
        , q.query_hash
        , p.plan_id
        , p.is_forced_plan
        , p.compatibility_level
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
    INNER JOIN sys.query_store_plan AS p
        ON p.plan_id = rs.plan_id
    INNER JOIN sys.query_store_query AS q
        ON q.query_id = p.query_id
    WHERE rs.execution_type = 0
      AND rsi.end_time > @AnalysisStartTime
      AND rsi.start_time < @AnalysisEndTime
      AND
      (
          @QueryId IS NULL
          OR q.query_id = @QueryId
      )
      AND
      (
          q.object_id IS NULL
          OR q.object_id <> CONVERT(bigint, @@PROCID)
      )
    OPTION (RECOMPILE);

    IF NOT EXISTS
    (
        SELECT 1
        FROM #QSRuntime
    )
    BEGIN
        RAISERROR
        (
            'No successful Query Store executions were found for the requested period.',
            10,
            1
        );
        RETURN;
    END;

    CREATE CLUSTERED INDEX CX_QSRuntime
        ON #QSRuntime
        (
              query_id
            , interval_start
            , plan_id
        );

    CREATE NONCLUSTERED INDEX IX_QSRuntime_Plan
        ON #QSRuntime
        (
              plan_id
            , interval_start
        );

    -------------------------------------------------------------------------
    -- Result set 2: Top queries for the complete analysis period
    -------------------------------------------------------------------------

    ;WITH QueryTotals AS
    (
        SELECT
              r.query_id
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
              r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
        HAVING SUM(r.execution_count) >= @MinExecutions
    )
    SELECT TOP (@TopRows)
          N'TOP_QUERIES' AS report_section
        , t.query_id
        , CONVERT(varchar(18), t.query_hash, 1) AS query_hash

        , CASE
              WHEN ISNULL(t.object_id, 0) = 0
                  THEN N'<ad hoc>'
              ELSE
                  COALESCE
                  (
                      QUOTENAME
                      (
                          OBJECT_SCHEMA_NAME
                          (
                              CONVERT(int, t.object_id),
                              DB_ID()
                          )
                      )
                      + N'.'
                      + QUOTENAME
                        (
                            OBJECT_NAME
                            (
                                CONVERT(int, t.object_id),
                                DB_ID()
                            )
                        ),
                      N'<object_id='
                      + CONVERT(nvarchar(20), t.object_id)
                      + N'>'
                  )
          END AS containing_object

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
              / 1000.0
          ) AS average_cpu_ms

        , CONVERT
          (
              decimal(28, 2),
              t.total_duration_us
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
              / 1000.0
          ) AS average_duration_ms

        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_cpu_us) / 1000.0
          ) AS maximum_cpu_ms

        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_duration_us) / 1000.0
          ) AS maximum_duration_ms

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

        , CASE
              WHEN @IncludeQueryText = 1
                  THEN qt.query_sql_text
              ELSE CONVERT(nvarchar(max), NULL)
          END AS query_sql_text
    FROM QueryTotals AS t
    INNER JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = t.query_text_id
    ORDER BY
          CASE
              WHEN @SortBy = 'CPU'
                  THEN t.total_cpu_us
          END DESC

        , CASE
              WHEN @SortBy = 'DURATION'
                  THEN t.total_duration_us
          END DESC

        , CASE
              WHEN @SortBy = 'READS'
                  THEN t.total_logical_reads
          END DESC

        , CASE
              WHEN @SortBy = 'EXECUTIONS'
                  THEN CONVERT(float, t.execution_count)
          END DESC

        , t.total_cpu_us DESC
        , t.query_id;

    -------------------------------------------------------------------------
    -- Result set 3: Recent-period regressions
    --
    -- Example with @CompareHours = 4:
    --
    --     Baseline: 8 hours ago through 4 hours ago
    --     Recent:   4 hours ago through now
    --
    -- Only intervals fully contained in each period are included. This
    -- prevents a single Query Store interval from being divided between
    -- the baseline and recent periods.
    -------------------------------------------------------------------------

    ;WITH ComparisonTotals AS
    (
        SELECT
              r.query_id
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
              r.query_id
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
    )
    SELECT TOP (@TopRows)
          N'REGRESSIONS' AS report_section
        , r.query_id
        , CONVERT(varchar(18), r.query_hash, 1) AS query_hash

        , CASE
              WHEN ISNULL(r.object_id, 0) = 0
                  THEN N'<ad hoc>'
              ELSE
                  COALESCE
                  (
                      QUOTENAME
                      (
                          OBJECT_SCHEMA_NAME
                          (
                              CONVERT(int, r.object_id),
                              DB_ID()
                          )
                      )
                      + N'.'
                      + QUOTENAME
                        (
                            OBJECT_NAME
                            (
                                CONVERT(int, r.object_id),
                                DB_ID()
                            )
                        ),
                      N'<object_id='
                      + CONVERT(nvarchar(20), r.object_id)
                      + N'>'
                  )
          END AS containing_object

        , r.has_forced_plan
        , r.baseline_plan_count
        , r.recent_plan_count
        , r.baseline_executions
        , r.recent_executions

        , CONVERT
          (
              decimal(28, 2),
              r.baseline_average_duration_us / 1000.0
          ) AS baseline_average_duration_ms

        , CONVERT
          (
              decimal(28, 2),
              r.recent_average_duration_us / 1000.0
          ) AS recent_average_duration_ms

        , CONVERT
          (
              decimal(28, 2),
              (r.duration_ratio - 1.0) * 100.0
          ) AS duration_change_pct

        , CONVERT
          (
              decimal(28, 2),
              r.baseline_average_cpu_us / 1000.0
          ) AS baseline_average_cpu_ms

        , CONVERT
          (
              decimal(28, 2),
              r.recent_average_cpu_us / 1000.0
          ) AS recent_average_cpu_ms

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

        , CASE
              WHEN @IncludeQueryText = 1
                  THEN qt.query_sql_text
              ELSE CONVERT(nvarchar(max), NULL)
          END AS query_sql_text
    FROM RankedRegressions AS r
    INNER JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = r.query_text_id
    WHERE r.baseline_executions >= @MinExecutions
      AND r.recent_executions >= @MinExecutions
      AND r.worst_regression_ratio >=
          (
              1.0
              + CONVERT(float, @RegressionThresholdPct)
                / 100.0
          )
    ORDER BY
          r.worst_regression_ratio DESC
        , r.recent_cpu_us DESC
        , r.query_id;

    -------------------------------------------------------------------------
    -- Result set 4: Plan-level resource consumption
    -------------------------------------------------------------------------

    ;WITH PlanTotals AS
    (
        SELECT
              r.query_id
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
              r.query_id
            , r.query_text_id
            , r.object_id
            , r.query_hash
            , r.plan_id
        HAVING SUM(r.execution_count) >= @MinExecutions
    )
    SELECT TOP (@TopRows)
          N'PLAN_DETAILS' AS report_section
        , t.query_id
        , t.plan_id
        , CONVERT(varchar(18), t.query_hash, 1) AS query_hash

        , CASE
              WHEN ISNULL(t.object_id, 0) = 0
                  THEN N'<ad hoc>'
              ELSE
                  COALESCE
                  (
                      QUOTENAME
                      (
                          OBJECT_SCHEMA_NAME
                          (
                              CONVERT(int, t.object_id),
                              DB_ID()
                          )
                      )
                      + N'.'
                      + QUOTENAME
                        (
                            OBJECT_NAME
                            (
                                CONVERT(int, t.object_id),
                                DB_ID()
                            )
                        ),
                      N'<object_id='
                      + CONVERT(nvarchar(20), t.object_id)
                      + N'>'
                  )
          END AS containing_object

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
              / 1000.0
          ) AS average_cpu_ms

        , CONVERT
          (
              decimal(28, 2),
              t.total_duration_us
              / NULLIF(CONVERT(float, t.execution_count), 0.0)
              / 1000.0
          ) AS average_duration_ms

        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_cpu_us) / 1000.0
          ) AS maximum_cpu_ms

        , CONVERT
          (
              decimal(28, 2),
              CONVERT(float, t.maximum_duration_us) / 1000.0
          ) AS maximum_duration_ms

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

        , CASE
              WHEN @IncludeQueryText = 1
                  THEN qt.query_sql_text
              ELSE CONVERT(nvarchar(max), NULL)
          END AS query_sql_text

        , CASE
              WHEN @IncludePlanXml = 1
                  THEN p.query_plan
              ELSE CONVERT(nvarchar(max), NULL)
          END AS query_plan
    FROM PlanTotals AS t
    INNER JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = t.query_text_id
    INNER JOIN sys.query_store_plan AS p
        ON p.plan_id = t.plan_id
    ORDER BY
          CASE
              WHEN @SortBy = 'CPU'
                  THEN t.total_cpu_us
          END DESC

        , CASE
              WHEN @SortBy = 'DURATION'
                  THEN t.total_duration_us
          END DESC

        , CASE
              WHEN @SortBy = 'READS'
                  THEN t.total_logical_reads
          END DESC

        , CASE
              WHEN @SortBy = 'EXECUTIONS'
                  THEN CONVERT(float, t.execution_count)
          END DESC

        , t.total_cpu_us DESC
        , t.query_id
        , t.plan_id;
END;
GO



QueryStorePerformanceAnalysis