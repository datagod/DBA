
CREATE OR ALTER PROCEDURE dbo.SearchQueryStoreForObject
(
    @ObjectName       sysname,
    @TargetDatabase   sysname = NULL,
    @SchemaName       sysname = NULL,
    @DaysBack         int     = NULL,
    @MinExecutions    bigint  = 1,
    @SearchByObjectId bit     = 1,
    @SearchQueryText  bit     = 1,
    @Debug             bit     = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @BareObjectName       sysname,
        @ActualState          nvarchar(60),
        @QueryStoreError      nvarchar(4000),
        @CutoffTime           datetimeoffset(7),
        @TextPattern          nvarchar(520),
        @QualifiedTextPattern nvarchar(520),
        @Sql                  nvarchar(max);


    -------------------------------------------------------------------------
    -- Validate parameters
    -------------------------------------------------------------------------

    IF NULLIF(LTRIM(RTRIM(@ObjectName)), N'') IS NULL
    BEGIN
        RAISERROR('@ObjectName is required.', 16, 1);
        RETURN;
    END;


    IF @TargetDatabase IS NULL
        SET @TargetDatabase = DB_NAME();


    IF DB_ID(@TargetDatabase) IS NULL
    BEGIN
        RAISERROR(
            'Database ''%s'' does not exist.',
            16,
            1,
            @TargetDatabase
        );
        RETURN;
    END;


    IF @SearchByObjectId = 0
       AND @SearchQueryText = 0
    BEGIN
        RAISERROR(
            'At least one search method must be enabled.',
            16,
            1
        );
        RETURN;
    END;


    IF @MinExecutions IS NULL
       OR @MinExecutions < 1
    BEGIN
        SET @MinExecutions = 1;
    END;


    IF @DaysBack IS NOT NULL
       AND @DaysBack < 1
    BEGIN
        SET @DaysBack = 1;
    END;


    -------------------------------------------------------------------------
    -- Parse schema-qualified object name
    -------------------------------------------------------------------------

    SET @BareObjectName = @ObjectName;


    IF @SchemaName IS NULL
       AND PARSENAME(@ObjectName, 2) IS NOT NULL
    BEGIN
        SET @SchemaName     = PARSENAME(@ObjectName, 2);
        SET @BareObjectName = PARSENAME(@ObjectName, 1);
    END;


    IF @BareObjectName IS NULL
    BEGIN
        RAISERROR(
            'Unable to parse object name ''%s''.',
            16,
            1,
            @ObjectName
        );
        RETURN;
    END;


    -------------------------------------------------------------------------
    -- Check Query Store state
    -------------------------------------------------------------------------

    SET @ActualState     = NULL;
    SET @QueryStoreError = NULL;


    SET @Sql =
        N'USE ' + QUOTENAME(@TargetDatabase) + N';

SELECT
    @ActualState = actual_state_desc
FROM sys.database_query_store_options;
';


    IF @Debug = 1
    BEGIN
        SELECT
            N'Query Store State' AS DebugStage,
            @Sql AS DynamicSql;
    END;


    BEGIN TRY

        EXEC sys.sp_executesql
            @Sql,
            N'@ActualState nvarchar(60) OUTPUT',
            @ActualState = @ActualState OUTPUT;

    END TRY
    BEGIN CATCH

        SET @QueryStoreError = ERROR_MESSAGE();

        RAISERROR(
            'Unable to read Query Store for database ''%s''. Error: %s',
            16,
            1,
            @TargetDatabase,
            @QueryStoreError
        );

        RETURN;

    END CATCH;


    IF ISNULL(@ActualState, N'OFF') NOT IN
    (
        N'READ_WRITE',
        N'READ_ONLY',
        N'READ_CAPTURE_SECONDARY'
    )
    BEGIN
        RAISERROR(
            'Query Store is not readable in database ''%s''. State: %s.',
            16,
            1,
            @TargetDatabase,
            @ActualState
        );

        RETURN;
    END;


    -------------------------------------------------------------------------
    -- Date cutoff
    -------------------------------------------------------------------------

    IF @DaysBack IS NULL
        SET @CutoffTime = NULL;
    ELSE
        SET @CutoffTime =
            DATEADD
            (
                DAY,
                -@DaysBack,
                SYSDATETIMEOFFSET()
            );


    -------------------------------------------------------------------------
    -- Build LIKE patterns
    -------------------------------------------------------------------------

    SET @TextPattern =
        N'%'
        + REPLACE(
            REPLACE(
                REPLACE(
                    @BareObjectName,
                    N'[',
                    N'[[]'
                ),
                N'%',
                N'[%]'
            ),
            N'_',
            N'[_]'
        )
        + N'%';


    IF @SchemaName IS NOT NULL
    BEGIN

        SET @QualifiedTextPattern =
            N'%'
            + REPLACE(
                REPLACE(
                    REPLACE(
                        @SchemaName,
                        N'[',
                        N'[[]'
                    ),
                    N'%',
                    N'[%]'
                ),
                N'_',
                N'[_]'
            )
            + N'.%'
            + REPLACE(
                REPLACE(
                    REPLACE(
                        @BareObjectName,
                        N'[',
                        N'[[]'
                    ),
                    N'%',
                    N'[%]'
                ),
                N'_',
                N'[_]'
            )
            + N'%';

    END
    ELSE
    BEGIN

        SET @QualifiedTextPattern = NULL;

    END;


    -------------------------------------------------------------------------
    -- Resolve objects in target database
    -------------------------------------------------------------------------

    CREATE TABLE #ResolvedObjects
    (
        object_id      int          NOT NULL PRIMARY KEY,
        schema_name    sysname      NOT NULL,
        object_name    sysname      NOT NULL,
        type_desc      nvarchar(60) NOT NULL
    );


    IF @SearchByObjectId = 1
    BEGIN

        SET @Sql =
            N'USE ' + QUOTENAME(@TargetDatabase) + N';

INSERT INTO #ResolvedObjects
(
    object_id,
    schema_name,
    object_name,
    type_desc
)
SELECT
    o.object_id,
    s.name,
    o.name,
    o.type_desc
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
    ON s.schema_id = o.schema_id
WHERE o.name = @ObjectName
  AND o.is_ms_shipped = 0
';


        IF @SchemaName IS NOT NULL
        BEGIN

            SET @Sql += N'
  AND s.name = @SchemaName
';

        END;


        SET @Sql += N';
';


        IF @Debug = 1
        BEGIN
            SELECT
                N'Object Resolution' AS DebugStage,
                @Sql AS DynamicSql;
        END;


        EXEC sys.sp_executesql
            @Sql,
            N'
                @ObjectName sysname,
                @SchemaName sysname
            ',
            @ObjectName = @BareObjectName,
            @SchemaName = @SchemaName;

    END;


    -------------------------------------------------------------------------
    -- Search Query Store
    -------------------------------------------------------------------------

    SET @Sql =
        N'USE ' + QUOTENAME(@TargetDatabase) + N';

;WITH QueryAgg
AS
(
    SELECT
        q.query_id,
        q.object_id,
        qt.query_sql_text,

        ObjectSchema =
            s.name,

        ObjectName =
            o.name,

        ObjectType =
            o.type_desc,

        PlanCount =
            COUNT(DISTINCT p.plan_id),

        IsForcedPlan =
            MAX(
                CASE
                    WHEN p.is_forced_plan = 1
                        THEN 1
                    ELSE 0
                END
            ),

        Executions =
            SUM(
                CONVERT(bigint, rs.count_executions)
            ),

        AvgDurationUs =
            SUM(
                CONVERT(float, rs.count_executions)
                * rs.avg_duration
            )
            /
            NULLIF(
                SUM(
                    CONVERT(float, rs.count_executions)
                ),
                0
            ),

        AvgCpuUs =
            SUM(
                CONVERT(float, rs.count_executions)
                * rs.avg_cpu_time
            )
            /
            NULLIF(
                SUM(
                    CONVERT(float, rs.count_executions)
                ),
                0
            ),

        AvgLogicalReads =
            SUM(
                CONVERT(float, rs.count_executions)
                * rs.avg_logical_io_reads
            )
            /
            NULLIF(
                SUM(
                    CONVERT(float, rs.count_executions)
                ),
                0
            ),

        LastExecutionTime =
            MAX(rs.last_execution_time)

    FROM sys.query_store_query AS q

    INNER JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = q.query_text_id

    INNER JOIN sys.query_store_plan AS p
        ON p.query_id = q.query_id

    INNER JOIN sys.query_store_runtime_stats AS rs
        ON rs.plan_id = p.plan_id

    LEFT JOIN sys.objects AS o
        ON o.object_id = q.object_id

    LEFT JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id

    WHERE
        q.is_internal_query = 0

        AND
        (
            @CutoffTime IS NULL
            OR rs.last_execution_time >= @CutoffTime
        )

    GROUP BY
        q.query_id,
        q.object_id,
        qt.query_sql_text,
        s.name,
        o.name,
        o.type_desc

    HAVING
        SUM(
            CONVERT(bigint, rs.count_executions)
        ) >= @MinExecutions
),

Matched
AS
(
    SELECT
        qa.*,

        MatchedByObjectId =
            CASE
                WHEN @SearchByObjectId = 1
                     AND EXISTS
                     (
                         SELECT 1
                         FROM #ResolvedObjects AS ro
                         WHERE ro.object_id = qa.object_id
                     )
                    THEN 1
                ELSE 0
            END,

        MatchedByText =
            CASE
                WHEN @SearchQueryText = 1
                     AND
                     (
                         qa.query_sql_text LIKE @TextPattern

                         OR

                         (
                             @QualifiedTextPattern IS NOT NULL
                             AND qa.query_sql_text LIKE @QualifiedTextPattern
                         )
                     )
                    THEN 1
                ELSE 0
            END

    FROM QueryAgg AS qa
)

SELECT
    DatabaseName =
        DB_NAME(),

    SearchObject =
        CASE
            WHEN @SchemaName IS NOT NULL
                THEN
                    @SchemaName COLLATE DATABASE_DEFAULT
                    + N''.''
                    + @BareObjectName COLLATE DATABASE_DEFAULT
            ELSE
                @BareObjectName COLLATE DATABASE_DEFAULT
        END,

    QueryID =
        m.query_id,

    MatchType =
        CASE
            WHEN m.MatchedByObjectId = 1
             AND m.MatchedByText = 1
                THEN N''Both''

            WHEN m.MatchedByObjectId = 1
                THEN N''Object ID''

            ELSE N''Query Text''
        END,

    ObjectSchema =
        COALESCE(
            ro.schema_name COLLATE DATABASE_DEFAULT,
            m.ObjectSchema
        ),

    ObjectName =
        COALESCE(
            ro.object_name COLLATE DATABASE_DEFAULT,
            m.ObjectName
        ),

    ObjectType =
        COALESCE(
            ro.type_desc COLLATE DATABASE_DEFAULT,
            m.ObjectType
        ),

    m.PlanCount,

    m.IsForcedPlan,

    m.Executions,

    AvgDurationSeconds =
        CAST(
            m.AvgDurationUs / 1000000.0
            AS decimal(18,3)
        ),

    AvgCpuSeconds =
        CAST(
            m.AvgCpuUs / 1000000.0
            AS decimal(18,3)
        ),

    AvgLogicalReads =
        CAST(
            m.AvgLogicalReads
            AS bigint
        ),

    m.LastExecutionTime,

    QueryText =
        m.query_sql_text

FROM Matched AS m

LEFT JOIN #ResolvedObjects AS ro
    ON ro.object_id = m.object_id

WHERE
       m.MatchedByObjectId = 1
    OR m.MatchedByText = 1

ORDER BY
    m.LastExecutionTime DESC,
    m.Executions DESC,
    m.query_id;
';


    -------------------------------------------------------------------------
    -- Debug
    -------------------------------------------------------------------------

    IF @Debug = 1
    BEGIN
        SELECT
            N'Main Query Store Search' AS DebugStage,
            @Sql AS DynamicSql;
    END;


    -------------------------------------------------------------------------
    -- Execute Query Store search
    -------------------------------------------------------------------------

    EXEC sys.sp_executesql
        @Sql,
        N'
            @BareObjectName         sysname,
            @SchemaName             sysname,
            @CutoffTime             datetimeoffset(7),
            @MinExecutions          bigint,
            @SearchByObjectId       bit,
            @SearchQueryText        bit,
            @TextPattern            nvarchar(520),
            @QualifiedTextPattern   nvarchar(520)
        ',
        @BareObjectName       = @BareObjectName,
        @SchemaName           = @SchemaName,
        @CutoffTime           = @CutoffTime,
        @MinExecutions        = @MinExecutions,
        @SearchByObjectId     = @SearchByObjectId,
        @SearchQueryText      = @SearchQueryText,
        @TextPattern          = @TextPattern,
        @QualifiedTextPattern = @QualifiedTextPattern;

END;
GO

EXEC dbo.SearchQueryStoreForObject
    @ObjectName     = N'case34',
    @TargetDatabase = N'nova_datamart_staging',
    @Debug          = 0
