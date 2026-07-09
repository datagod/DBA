/*
  SearchQueryStoreForObject.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.SearchQueryStoreForObject
        @ObjectName = N'MyTable',
        @TargetDatabase = N'YourDatabase'

  Optional parameters:
    @TargetDatabase   - database to search (default: current database)
    @SchemaName       - optional schema for object resolution and text patterns
    @DaysBack         - lookback on last_execution_time (default NULL = all retained history)
    @MinExecutions    - minimum executions to include a query (default 1)
    @SearchByObjectId - match queries attributed to the object via object_id (default 1)
    @SearchQueryText  - match object name in query_sql_text (default 1)
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.SearchQueryStoreForObject
(
    @ObjectName       sysname,
    @TargetDatabase   sysname = NULL,
    @SchemaName       sysname = NULL,
    @DaysBack         int     = NULL,
    @MinExecutions    bigint  = 1,
    @SearchByObjectId bit     = 1,
    @SearchQueryText  bit     = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: July 3, 2026
-- Author:       Bill McEvoy
-- Description:  Searches Query Store in a target database for references to an object name.
--               Matches queries attributed to the object via object_id and/or queries whose
--               text references the object name.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion         tinyint,
    @CompatibilityLevel   int,
    @TargetDatabaseId     int,
    @BareObjectName       sysname,
    @ActualState          nvarchar(60),
    @QueryStoreReadable   bit,
    @CutoffTime           datetime,
    @TextPattern          nvarchar(520),
    @QualifiedTextPattern nvarchar(520),
    @Sql                  nvarchar(max)

IF NULLIF(LTRIM(RTRIM(@ObjectName)), N'') IS NULL
BEGIN
    RAISERROR('@ObjectName is required.', 16, 1)
    RETURN
END

IF @SearchByObjectId = 0 AND @SearchQueryText = 0
BEGIN
    RAISERROR('At least one of @SearchByObjectId or @SearchQueryText must be 1.', 16, 1)
    RETURN
END

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

IF @MinExecutions < 1
    SET @MinExecutions = 1

IF @DaysBack IS NOT NULL AND @DaysBack < 1
    SET @DaysBack = 1

SET @BareObjectName = @ObjectName

IF @SchemaName IS NULL AND CHARINDEX(N'.', @ObjectName) > 0
BEGIN
    SET @SchemaName     = PARSENAME(@ObjectName, 2)
    SET @BareObjectName = PARSENAME(@ObjectName, 1)
END

IF @BareObjectName IS NULL
BEGIN
    RAISERROR('Could not parse object name ''%s''.', 16, 1, @ObjectName)
    RETURN
END

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

SET @ActualState        = N'UNKNOWN'
SET @QueryStoreReadable = 0

SET @Sql = N'
SELECT @ActualState = actual_state_desc
  FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.database_query_store_options'

BEGIN TRY
    EXEC sys.sp_executesql
        @Sql,
        N'@ActualState nvarchar(60) OUTPUT',
        @ActualState = @ActualState OUTPUT

    SET @QueryStoreReadable = CASE
                                  WHEN @ActualState IN (N'READ_WRITE', N'READ_ONLY') THEN 1
                                  ELSE 0
                              END
END TRY
BEGIN CATCH
    SET @ActualState        = N'UNAVAILABLE'
    SET @QueryStoreReadable = 0
END CATCH

IF @QueryStoreReadable = 0
BEGIN
    RAISERROR('Query Store is not readable in database ''%s''. Current state: %s.', 16, 1, @TargetDatabase, @ActualState)
    RETURN
END

SET @CutoffTime = CASE
                      WHEN @DaysBack IS NULL THEN NULL
                      ELSE DATEADD(day, -@DaysBack, GETDATE())
                  END

SET @TextPattern = N'%' + REPLACE(REPLACE(REPLACE(@BareObjectName, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%'

IF @SchemaName IS NOT NULL
    SET @QualifiedTextPattern = N'%' + REPLACE(REPLACE(REPLACE(@SchemaName, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]')
        + N'.%'
        + REPLACE(REPLACE(REPLACE(@BareObjectName, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]')
        + N'%'
ELSE
    SET @QualifiedTextPattern = NULL

CREATE TABLE #ResolvedObjects
(
    object_id   int          NOT NULL PRIMARY KEY,
    schema_name sysname      NOT NULL,
    object_name sysname      NOT NULL,
    type_desc   nvarchar(60) NOT NULL
)

IF @SearchByObjectId = 1
BEGIN
    SET @Sql = N'
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
      FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.objects AS o
      + N'
      INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.schemas AS s
          ON o.schema_id = s.schema_id
     WHERE o.name = @BareObjectName
       AND o.type IN (''P'', ''PC'', ''FN'', ''IF'', ''TF'', ''FS'', ''FT'', ''V'', ''TR'', ''TA'', ''U'')'

    IF @SchemaName IS NOT NULL
        SET @Sql = @Sql + N'
       AND s.name = @SchemaName'

    EXEC sys.sp_executesql
        @Sql,
        N'@BareObjectName sysname, @SchemaName sysname',
        @BareObjectName = @BareObjectName,
        @SchemaName = @SchemaName
END

SET @Sql = N'
;WITH QueryAgg AS
(
    SELECT
        q.query_id,
        q.object_id,
        qt.query_sql_text,
        o.type_desc,
        PlanCount = COUNT(DISTINCT p.plan_id),
        IsForcedPlan = MAX(CASE WHEN p.is_forced_plan = 1 THEN 1 ELSE 0 END),
        Executions = SUM(rs.count_executions),
        AvgDurationUs = CAST(SUM(rs.count_executions * rs.avg_duration)
            / NULLIF(SUM(rs.count_executions), 0) AS bigint),
        AvgCpuUs = CAST(SUM(rs.count_executions * rs.avg_cpu_time)
            / NULLIF(SUM(rs.count_executions), 0) AS bigint),
        AvgLogicalReads = CAST(SUM(rs.count_executions * rs.avg_logical_io_reads)
            / NULLIF(SUM(rs.count_executions), 0) AS bigint),
        LastExecutionTime = MAX(rs.last_execution_time)
      FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_query AS q
      + N'
      INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_query_text AS qt
          ON q.query_text_id = qt.query_text_id
      INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_plan AS p
          ON q.query_id = p.query_id
      INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.query_store_runtime_stats AS rs
          ON p.plan_id = rs.plan_id
      LEFT JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.objects AS o
          ON q.object_id = o.object_id
     WHERE q.is_internal_query = 0
       AND (@CutoffTime IS NULL OR rs.last_execution_time >= @CutoffTime)
     GROUP BY
        q.query_id,
        q.object_id,
        qt.query_sql_text,
        o.type_desc
    HAVING SUM(rs.count_executions) >= @MinExecutions
),
Matched AS
(
    SELECT
        qa.query_id,
        qa.object_id,
        qa.query_sql_text,
        qa.type_desc,
        qa.PlanCount,
        qa.IsForcedPlan,
        qa.Executions,
        qa.AvgDurationUs,
        qa.AvgCpuUs,
        qa.AvgLogicalReads,
        qa.LastExecutionTime,
        MatchedByObjectId = CASE
                                WHEN @SearchByObjectId = 1
                                 AND EXISTS (
                                     SELECT 1
                                       FROM #ResolvedObjects AS ro
                                      WHERE ro.object_id = qa.object_id
                                 ) THEN 1
                                ELSE 0
                            END,
        MatchedByText = CASE
                            WHEN @SearchQueryText = 1
                             AND (
                                 qa.query_sql_text LIKE @TextPattern
                                 OR (
                                     @QualifiedTextPattern IS NOT NULL
                                     AND qa.query_sql_text LIKE @QualifiedTextPattern
                                 )
                             ) THEN 1
                            ELSE 0
                        END
      FROM QueryAgg AS qa
)
SELECT
    DatabaseName = @TargetDatabase,
    SearchObject = CASE
                       WHEN @SchemaName IS NOT NULL THEN @SchemaName + N''.'' + @BareObjectName
                       ELSE @BareObjectName
                   END,
    m.query_id AS QueryID,
    MatchType = CASE
                    WHEN m.MatchedByObjectId = 1 AND m.MatchedByText = 1 THEN N''Both''
                    WHEN m.MatchedByObjectId = 1 THEN N''Object''
                    ELSE N''Query Text''
                END,
    ObjectSchema = COALESCE(ro.schema_name, OBJECT_SCHEMA_NAME(m.object_id, @TargetDatabaseId)),
    ObjectName = COALESCE(ro.object_name, OBJECT_NAME(m.object_id, @TargetDatabaseId)),
    ObjectType = COALESCE(ro.type_desc, m.type_desc),
    m.PlanCount,
    m.IsForcedPlan,
    m.Executions,
    AvgDurationMs = CAST(m.AvgDurationUs / 1000.0 AS decimal(18, 3)),
    AvgCpuMs = CAST(m.AvgCpuUs / 1000.0 AS decimal(18, 3)),
    m.AvgLogicalReads,
    m.LastExecutionTime,
    m.query_sql_text AS QueryText
  FROM Matched AS m
  LEFT JOIN #ResolvedObjects AS ro
    ON m.object_id = ro.object_id
 WHERE m.MatchedByObjectId = 1
    OR m.MatchedByText = 1
 ORDER BY
    m.LastExecutionTime DESC,
    m.Executions DESC,
    m.query_id'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabase sysname,
      @TargetDatabaseId int,
      @BareObjectName sysname,
      @SchemaName sysname,
      @CutoffTime datetime,
      @MinExecutions bigint,
      @SearchByObjectId bit,
      @SearchQueryText bit,
      @TextPattern nvarchar(520),
      @QualifiedTextPattern nvarchar(520)',
    @TargetDatabase = @TargetDatabase,
    @TargetDatabaseId = @TargetDatabaseId,
    @BareObjectName = @BareObjectName,
    @SchemaName = @SchemaName,
    @CutoffTime = @CutoffTime,
    @MinExecutions = @MinExecutions,
    @SearchByObjectId = @SearchByObjectId,
    @SearchQueryText = @SearchQueryText,
    @TextPattern = @TextPattern,
    @QualifiedTextPattern = @QualifiedTextPattern

GO

IF OBJECT_ID('dbo.SearchQueryStoreForObject') IS NOT NULL
    PRINT 'Procedure SearchQueryStoreForObject created.'
ELSE
    PRINT 'Procedure SearchQueryStoreForObject NOT created.'