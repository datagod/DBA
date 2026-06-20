/*
  ShowQueryStoreWorkloadReport.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.ShowQueryStoreWorkloadReport @DaysBack = 7

  Optional parameters:
    @DaysBack               - lookback window based on Query Store last_execution_time (default 7)
    @MinExecutions          - minimum executions in the window to include a workload (default 1)
    @DatabaseFilter         - LIKE filter for database names (default '%')
    @IncludeSystemDatabases - include master, model, msdb, tempdb (default 0)
    @TopN                   - number of workload rows in the detail section (default 100)
    @SortBy                 - EXECUTIONS | LAST_EXEC | DURATION | DATABASE
    @ReportWidth            - kept for backward compatibility; report layout is fixed at 120 characters
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ShowQueryStoreWorkloadReport
(
    @DaysBack               int         = 7,
    @MinExecutions          bigint      = 1,
    @DatabaseFilter         sysname     = '%',
    @IncludeSystemDatabases bit         = 0,
    @TopN                   int         = 100,
    @SortBy                 varchar(12) = 'EXECUTIONS',
    @ReportWidth            tinyint     = 120
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 20, 2026
-- Author:       Bill McEvoy
-- Description:  Server-wide Query Store workload report. Scans each database with Query Store
--               enabled, classifies recent activity into stored procedures, SQL Agent jobs,
--               maintenance, application queries, and related workload types, then returns a
--               fixed-width text report.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion       tinyint,
    @ProductVersion     varchar(30),
    @ServerName         sysname,
    @ReportTime         varchar(19),
    @CutoffTime         datetime,
    @Divider            varchar(120),
    @HeaderRule         varchar(120),
    @BlankLine          varchar(120),
    @DbWidth            tinyint,
    @TypeWidth          tinyint,
    @NameWidth          tinyint,
    @ExecWidth          tinyint,
    @LastWidth          tinyint,
    @AvgWidth           tinyint,
    @LineNo             int,
    @SortByUpper        varchar(12),
    @DatabaseName       sysname,
    @DatabaseId         int,
    @QueryStoreState    nvarchar(60),
    @Sql                nvarchar(max),
    @DatabasesScanned   int,
    @DatabasesWithData  int,
    @DatabasesSkipped   int,
    @TotalWorkloads     int,
    @TotalExecutions    bigint,
    @StoredProcCount    int,
    @JobCount           int,
    @AppQueryCount      int

IF @DaysBack < 1
    SET @DaysBack = 1

IF @MinExecutions < 1
    SET @MinExecutions = 1

IF @TopN < 1
    SET @TopN = 100

SET @SortByUpper = UPPER(ISNULL(@SortBy, 'EXECUTIONS'))
IF @SortByUpper NOT IN ('EXECUTIONS', 'LAST_EXEC', 'DURATION', 'DATABASE')
    SET @SortByUpper = 'EXECUTIONS'

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 13
BEGIN
    RAISERROR('Query Store requires SQL Server 2016 (13.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SET @ReportWidth = 120
SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @CutoffTime     = DATEADD(day, -@DaysBack, GETDATE())
SET @Divider        = REPLICATE('-', @ReportWidth)
SET @HeaderRule     = REPLICATE('=', @ReportWidth)
SET @BlankLine      = REPLICATE(' ', @ReportWidth)

-- Column widths total 115 characters; single-space separators make 120.
SET @DbWidth    = 20
SET @TypeWidth  = 18
SET @NameWidth  = 59
SET @ExecWidth  = 8
SET @LastWidth  = 5
SET @AvgWidth   = 7

IF OBJECT_ID('tempdb..#DatabaseScan') IS NOT NULL
    DROP TABLE #DatabaseScan

CREATE TABLE #DatabaseScan
(
    DatabaseName      sysname       NOT NULL,
    CompatibilityLevel int          NULL,
    QueryStoreOn      bit           NOT NULL,
    QueryStoreState   nvarchar(60)  NULL,
    ScanStatus        varchar(20)   NOT NULL,
    WorkloadCount     int           NOT NULL,
    Note              varchar(200)  NULL
)

IF OBJECT_ID('tempdb..#Workload') IS NOT NULL
    DROP TABLE #Workload

CREATE TABLE #Workload
(
    DatabaseName       sysname        NOT NULL,
    WorkloadType       varchar(30)    NOT NULL,
    WorkloadName       varchar(200)   NOT NULL,
    QueryCount         int            NOT NULL,
    Executions         bigint         NOT NULL,
    AvgDurationUs      bigint         NOT NULL,
    TotalDurationUs    bigint         NOT NULL,
    LastExecutionTime  datetime       NULL,
    SortKeyBigint      bigint         NOT NULL,
    SortKeyDate        datetime       NULL,
    SortKeyText        sysname        NOT NULL
)

IF OBJECT_ID('tempdb..#Report') IS NOT NULL
    DROP TABLE #Report

CREATE TABLE #Report
(
    [LineNo]   int          NOT NULL,
    ReportLine varchar(200) NOT NULL
)

INSERT INTO #DatabaseScan
(
    DatabaseName,
    CompatibilityLevel,
    QueryStoreOn,
    QueryStoreState,
    ScanStatus,
    WorkloadCount,
    Note
)
SELECT
    d.name,
    d.compatibility_level,
    d.is_query_store_on,
    NULL,
    'PENDING',
    0,
    NULL
  FROM sys.databases AS d
 WHERE d.state = 0
   AND d.is_read_only = 0
   AND d.name LIKE @DatabaseFilter
   AND (@IncludeSystemDatabases = 1 OR d.database_id > 4)

DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DatabaseName
  FROM #DatabaseScan
 ORDER BY DatabaseName

OPEN DatabaseCursor
FETCH NEXT FROM DatabaseCursor INTO @DatabaseName

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @QueryStoreState = NULL
        SET @Sql = N'
        SELECT @QueryStoreState = actual_state_desc
          FROM ' + QUOTENAME(@DatabaseName) + N'.sys.database_query_store_options'

        EXEC sys.sp_executesql
            @Sql,
            N'@QueryStoreState nvarchar(60) OUTPUT',
            @QueryStoreState = @QueryStoreState OUTPUT

        UPDATE #DatabaseScan
           SET QueryStoreState = @QueryStoreState
         WHERE DatabaseName = @DatabaseName

        IF @QueryStoreState NOT IN ('READ_WRITE', 'READ_ONLY')
        BEGIN
            UPDATE #DatabaseScan
               SET ScanStatus = 'SKIPPED',
                   Note = 'Query Store state is not readable'
             WHERE DatabaseName = @DatabaseName
        END
        ELSE IF EXISTS (
            SELECT 1
              FROM #DatabaseScan
             WHERE DatabaseName = @DatabaseName
               AND CompatibilityLevel < 130
        )
        BEGIN
            UPDATE #DatabaseScan
               SET ScanStatus = 'SKIPPED',
                   Note = 'Compatibility level below 130'
             WHERE DatabaseName = @DatabaseName
        END
        ELSE
        BEGIN
            SET @DatabaseId = DB_ID(@DatabaseName)

            SET @Sql = N'
            ;WITH QueryActivity AS
            (
                SELECT
                    q.query_id,
                    q.object_id,
                    q.query_hash,
                    qt.query_sql_text,
                    o.type_desc,
                    Executions = SUM(rs.count_executions),
                    TotalDurationUs = CAST(SUM(rs.count_executions * rs.avg_duration) AS bigint),
                    LastExecutionTime = MAX(rs.last_execution_time)
                FROM ' + QUOTENAME(@DatabaseName) + N'.sys.query_store_query AS q
                INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.query_store_query_text AS qt
                    ON q.query_text_id = qt.query_text_id
                INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.query_store_plan AS p
                    ON q.query_id = p.query_id
                INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.query_store_runtime_stats AS rs
                    ON p.plan_id = rs.plan_id
                LEFT JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.objects AS o
                    ON q.object_id = o.object_id
                WHERE q.is_internal_query = 0
                  AND rs.last_execution_time >= @CutoffTime
                GROUP BY
                    q.query_id,
                    q.object_id,
                    q.query_hash,
                    qt.query_sql_text,
                    o.type_desc
            ),
            Classified AS
            (
                SELECT
                    qa.*,
                    NormalizedText = UPPER(LTRIM(REPLACE(REPLACE(REPLACE(qa.query_sql_text, CHAR(13), '' ''), CHAR(10), '' ''), ''  '', '' ''))),
                    WorkloadType = CASE
                        WHEN qa.object_id <> 0 AND qa.type_desc = ''SQL_STORED_PROCEDURE'' THEN ''Stored Procedure''
                        WHEN qa.object_id <> 0 AND qa.type_desc LIKE ''%FUNCTION%'' THEN ''Function''
                        WHEN qa.object_id <> 0 AND qa.type_desc = ''SQL_TRIGGER'' THEN ''Trigger''
                        WHEN qa.object_id <> 0 AND qa.type_desc = ''VIEW'' THEN ''View''
                        WHEN UPPER(LTRIM(qa.query_sql_text)) LIKE ''EXEC %''
                          OR UPPER(LTRIM(qa.query_sql_text)) LIKE ''EXECUTE %''
                          OR UPPER(LTRIM(qa.query_sql_text)) LIKE ''EXEC(''
                          OR UPPER(LTRIM(qa.query_sql_text)) LIKE ''EXECUTE(''
                            THEN ''Procedure Call''
                        WHEN UPPER(qa.query_sql_text) LIKE ''%SQLAGENT%''
                          OR UPPER(qa.query_sql_text) LIKE ''%SP_START_JOB%''
                          OR UPPER(qa.query_sql_text) LIKE ''%MSDB%DBO%SP_%''
                          OR UPPER(qa.query_sql_text) LIKE ''%SP_SEND_DBMAIL%''
                          OR UPPER(qa.query_sql_text) LIKE ''%DATABASEMAIL%''
                            THEN ''SQL Agent / Job''
                        WHEN UPPER(qa.query_sql_text) LIKE ''%BACKUP %''
                          OR UPPER(qa.query_sql_text) LIKE ''%RESTORE %''
                          OR UPPER(qa.query_sql_text) LIKE ''%DBCC %''
                          OR UPPER(qa.query_sql_text) LIKE ''%INDEXOPTIMIZE%''
                          OR UPPER(qa.query_sql_text) LIKE ''%DATABASEINTEGRITYCHECK%''
                          OR UPPER(qa.query_sql_text) LIKE ''%COMMANDEXECUTE%''
                          OR UPPER(qa.query_sql_text) LIKE ''%SP_UPDATESTATS%''
                          OR UPPER(qa.query_sql_text) LIKE ''%ALTER INDEX%REORGANIZE%''
                          OR UPPER(qa.query_sql_text) LIKE ''%ALTER INDEX%REBUILD%''
                            THEN ''Maintenance''
                        WHEN UPPER(LTRIM(qa.query_sql_text)) LIKE ''CREATE %''
                          OR UPPER(LTRIM(qa.query_sql_text)) LIKE ''ALTER %''
                          OR UPPER(LTRIM(qa.query_sql_text)) LIKE ''DROP %''
                          OR UPPER(LTRIM(qa.query_sql_text)) LIKE ''GRANT %''
                          OR UPPER(LTRIM(qa.query_sql_text)) LIKE ''REVOKE %''
                            THEN ''DDL / Admin''
                        ELSE ''Application Query''
                    END,
                    WorkloadName = CASE
                        WHEN qa.object_id <> 0 THEN
                            ISNULL(OBJECT_SCHEMA_NAME(qa.object_id, @DbId) + ''.'' + OBJECT_NAME(qa.object_id, @DbId), ''(unknown object)'')
                        ELSE LEFT(
                            REPLACE(REPLACE(REPLACE(qa.query_sql_text, CHAR(13), '' ''), CHAR(10), '' ''), ''  '', '' ''),
                            200)
                    END,
                    GroupKey = CASE
                        WHEN qa.object_id <> 0 THEN ''O:'' + CAST(qa.object_id AS varchar(20))
                        ELSE ''H:'' + CONVERT(varchar(20), qa.query_hash, 1)
                    END
                FROM QueryActivity AS qa
            )
            INSERT INTO #Workload
            (
                DatabaseName,
                WorkloadType,
                WorkloadName,
                QueryCount,
                Executions,
                AvgDurationUs,
                TotalDurationUs,
                LastExecutionTime,
                SortKeyBigint,
                SortKeyDate,
                SortKeyText
            )
            SELECT
                DatabaseName = @DbName,
                c.WorkloadType,
                WorkloadName = MIN(c.WorkloadName),
                QueryCount = COUNT(DISTINCT c.query_id),
                Executions = SUM(c.Executions),
                AvgDurationUs = CAST(SUM(c.TotalDurationUs) / NULLIF(SUM(c.Executions), 0) AS bigint),
                TotalDurationUs = SUM(c.TotalDurationUs),
                LastExecutionTime = MAX(c.LastExecutionTime),
                SortKeyBigint = SUM(c.Executions),
                SortKeyDate = MAX(c.LastExecutionTime),
                SortKeyText = @DbName
            FROM Classified AS c
            GROUP BY c.WorkloadType, c.GroupKey
            HAVING SUM(c.Executions) >= @MinExecutions'

            EXEC sys.sp_executesql
                @Sql,
                N'@DbId int, @DbName sysname, @CutoffTime datetime, @MinExecutions bigint',
                @DbId = @DatabaseId,
                @DbName = @DatabaseName,
                @CutoffTime = @CutoffTime,
                @MinExecutions = @MinExecutions

            UPDATE ds
               SET ScanStatus = 'SCANNED',
                   WorkloadCount = ISNULL(w.WorkloadCount, 0),
                   Note = CASE WHEN ISNULL(w.WorkloadCount, 0) = 0 THEN 'No qualifying activity in window' ELSE NULL END
              FROM #DatabaseScan AS ds
              LEFT JOIN (
                  SELECT DatabaseName, WorkloadCount = COUNT(*)
                    FROM #Workload
                   GROUP BY DatabaseName
              ) AS w
                ON w.DatabaseName = ds.DatabaseName
             WHERE ds.DatabaseName = @DatabaseName
        END
    END TRY
    BEGIN CATCH
        UPDATE #DatabaseScan
           SET ScanStatus = 'ERROR',
               Note = LEFT(ERROR_MESSAGE(), 200)
         WHERE DatabaseName = @DatabaseName
    END CATCH

    FETCH NEXT FROM DatabaseCursor INTO @DatabaseName
END

CLOSE DatabaseCursor
DEALLOCATE DatabaseCursor

UPDATE #DatabaseScan
   SET ScanStatus = 'SKIPPED',
       Note = 'Query Store is disabled'
 WHERE QueryStoreOn = 0
   AND ScanStatus = 'PENDING'

SELECT @DatabasesScanned  = COUNT(*) FROM #DatabaseScan
SELECT @DatabasesWithData = COUNT(*) FROM #DatabaseScan WHERE ScanStatus = 'SCANNED' AND WorkloadCount > 0
SELECT @DatabasesSkipped  = COUNT(*) FROM #DatabaseScan WHERE ScanStatus IN ('SKIPPED', 'ERROR')
SELECT @TotalWorkloads    = COUNT(*) FROM #Workload
SELECT @TotalExecutions   = ISNULL(SUM(Executions), 0) FROM #Workload
SELECT @StoredProcCount   = COUNT(*) FROM #Workload WHERE WorkloadType IN ('Stored Procedure', 'Procedure Call')
SELECT @JobCount          = COUNT(*) FROM #Workload WHERE WorkloadType IN ('SQL Agent / Job', 'Maintenance')
SELECT @AppQueryCount     = COUNT(*) FROM #Workload WHERE WorkloadType = 'Application Query'

SET @LineNo = 0

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(' QUERY STORE WORKLOAD REPORT' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2,
       LEFT(' Server: ' + @ServerName
            + '  |  SQL Server ' + @ProductVersion
            + '  |  ' + @ReportTime + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 3,
       LEFT(' Lookback: ' + CAST(@DaysBack AS varchar(10)) + ' days'
            + '  |  Since: ' + CONVERT(varchar(19), @CutoffTime, 120)
            + '  |  Min execs: ' + CAST(@MinExecutions AS varchar(12)) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 5, LEFT(' SCAN SUMMARY' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 6, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 7,
       LEFT(' Databases matched : ' + CAST(@DatabasesScanned AS varchar(10))
            + '  |  With activity: ' + CAST(@DatabasesWithData AS varchar(10))
            + '  |  Skipped/error: ' + CAST(@DatabasesSkipped AS varchar(10)) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 8,
       LEFT(' Workloads found   : ' + CAST(@TotalWorkloads AS varchar(10))
            + '  |  Executions   : ' + CAST(@TotalExecutions AS varchar(15))
            + '  |  sort: ' + @SortByUpper + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 9,
       LEFT(' Stored procedures : ' + CAST(@StoredProcCount AS varchar(10))
            + '  |  Agent/maint  : ' + CAST(@JobCount AS varchar(10))
            + '  |  App queries  : ' + CAST(@AppQueryCount AS varchar(10)) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 10, LEFT(@Divider, @ReportWidth)

SET @LineNo = 11

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(' DATABASE SCAN STATUS' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 2,
       LEFT(
              LEFT('DATABASE' + @BlankLine, @DbWidth)
            + ' ' + LEFT('STATUS' + @BlankLine, 10)
            + ' ' + LEFT('QS STATE' + @BlankLine, 12)
            + ' ' + LEFT('ITEMS' + @BlankLine, 6)
            + ' ' + LEFT('NOTE' + @BlankLine, 58),
            @ReportWidth)
UNION ALL
SELECT @LineNo + 3, LEFT(@Divider, @ReportWidth)

SET @LineNo = @LineNo + 4

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    @LineNo + ROW_NUMBER() OVER (ORDER BY d.DatabaseName) - 1,
    LEFT(
          LEFT(d.DatabaseName + @BlankLine, @DbWidth)
        + ' ' + LEFT(d.ScanStatus + @BlankLine, 10)
        + ' ' + LEFT(ISNULL(d.QueryStoreState, 'OFF') + @BlankLine, 12)
        + ' ' + RIGHT(REPLICATE(' ', 6) + CAST(d.WorkloadCount AS varchar(10)), 6)
        + ' ' + LEFT(ISNULL(d.Note, '') + @BlankLine, 58),
        @ReportWidth)
  FROM #DatabaseScan AS d

SELECT @LineNo = ISNULL(MAX([LineNo]), @LineNo) + 1 FROM #Report

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo,     LEFT(@BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(' WORKLOAD BY TYPE' + @BlankLine, @ReportWidth)),
    (@LineNo + 2, LEFT(@Divider, @ReportWidth)),
    (@LineNo + 3, LEFT(
          LEFT('TYPE' + @BlankLine, @TypeWidth)
        + ' ' + LEFT('ITEMS' + @BlankLine, 8)
        + ' ' + LEFT('EXECUTIONS' + @BlankLine, 12)
        + ' ' + LEFT('DATABASES' + @BlankLine, 12)
        + ' ' + LEFT('LAST EXEC' + @BlankLine, 19),
        @ReportWidth)),
    (@LineNo + 4, LEFT(@Divider, @ReportWidth))

SET @LineNo = @LineNo + 5

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    @LineNo + ROW_NUMBER() OVER (ORDER BY SUM(w.Executions) DESC, w.WorkloadType) - 1,
    LEFT(
          LEFT(w.WorkloadType + @BlankLine, @TypeWidth)
        + ' ' + RIGHT(REPLICATE(' ', 8) + CAST(COUNT(*) AS varchar(10)), 8)
        + ' ' + RIGHT(REPLICATE(' ', 12) + CAST(SUM(w.Executions) AS varchar(15)), 12)
        + ' ' + RIGHT(REPLICATE(' ', 12) + CAST(COUNT(DISTINCT w.DatabaseName) AS varchar(10)), 12)
        + ' ' + LEFT(CONVERT(varchar(19), MAX(w.LastExecutionTime), 120) + @BlankLine, 19),
        @ReportWidth)
  FROM #Workload AS w
 GROUP BY w.WorkloadType

SELECT @LineNo = ISNULL(MAX([LineNo]), @LineNo) + 1 FROM #Report

IF NOT EXISTS (SELECT 1 FROM #Workload)
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES
        (@LineNo,     LEFT(@BlankLine, @ReportWidth)),
        (@LineNo + 1, LEFT(' No qualifying Query Store workload activity was found in the lookback window.' + @BlankLine, @ReportWidth)),
        (@LineNo + 2, LEFT(@HeaderRule, @ReportWidth))
END
ELSE
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES
        (@LineNo,     LEFT(@BlankLine, @ReportWidth)),
        (@LineNo + 1, LEFT(' TOP ' + CAST(@TopN AS varchar(10)) + ' WORKLOADS' + @BlankLine, @ReportWidth)),
        (@LineNo + 2, LEFT(@Divider, @ReportWidth)),
        (@LineNo + 3, LEFT(
              LEFT('DATABASE' + @BlankLine, @DbWidth)
            + ' ' + LEFT('TYPE' + @BlankLine, @TypeWidth)
            + ' ' + LEFT('WORKLOAD' + @BlankLine, @NameWidth)
            + ' ' + LEFT('EXECS' + @BlankLine, @ExecWidth)
            + ' ' + LEFT('LAST' + @BlankLine, @LastWidth)
            + ' ' + LEFT('AVGMS' + @BlankLine, @AvgWidth),
            @ReportWidth)),
        (@LineNo + 4, LEFT(@Divider, @ReportWidth))

    SET @LineNo = @LineNo + 5

    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT
        @LineNo + ROW_NUMBER() OVER (
            ORDER BY
                CASE WHEN @SortByUpper = 'EXECUTIONS' THEN w.SortKeyBigint END DESC,
                CASE WHEN @SortByUpper = 'DURATION'   THEN w.TotalDurationUs END DESC,
                CASE WHEN @SortByUpper = 'LAST_EXEC'  THEN w.SortKeyDate END DESC,
                CASE WHEN @SortByUpper = 'DATABASE'   THEN w.SortKeyText END,
                w.WorkloadType,
                w.WorkloadName
        ) - 1,
        LEFT(
              LEFT(w.DatabaseName + @BlankLine, @DbWidth)
            + ' ' + LEFT(w.WorkloadType + @BlankLine, @TypeWidth)
            + ' ' + LEFT(w.WorkloadName + @BlankLine, @NameWidth)
            + ' ' + RIGHT(REPLICATE(' ', @ExecWidth) + CASE
                    WHEN w.Executions >= 1000000000 THEN CAST(w.Executions / 1000000000 AS varchar(10)) + 'B'
                    WHEN w.Executions >= 1000000 THEN LTRIM(STR(w.Executions / 1000000.0, 4, 1)) + 'M'
                    WHEN w.Executions >= 10000 THEN CAST(w.Executions / 1000 AS varchar(10)) + 'K'
                    WHEN w.Executions >= 1000 THEN LTRIM(STR(w.Executions / 1000.0, 4, 1)) + 'K'
                    ELSE CAST(w.Executions AS varchar(10))
                END, @ExecWidth)
            + ' ' + LEFT(
                    CASE
                        WHEN w.LastExecutionTime IS NULL THEN '     '
                        ELSE RIGHT('0' + CAST(MONTH(w.LastExecutionTime) AS varchar(2)), 2)
                             + '-'
                             + RIGHT('0' + CAST(DAY(w.LastExecutionTime) AS varchar(2)), 2)
                    END + @BlankLine, @LastWidth)
            + ' ' + RIGHT(REPLICATE(' ', @AvgWidth) + CASE
                    WHEN (w.AvgDurationUs / 1000.0) >= 10000 THEN CAST(CAST(w.AvgDurationUs / 1000000 AS bigint) AS varchar(10)) + 'K'
                    WHEN (w.AvgDurationUs / 1000.0) >= 1000 THEN LTRIM(STR(w.AvgDurationUs / 1000000.0, 4, 1)) + 'K'
                    ELSE LTRIM(STR(w.AvgDurationUs / 1000.0, 6, 1))
                END, @AvgWidth),
            @ReportWidth)
      FROM (
          SELECT TOP (@TopN) *
            FROM #Workload
           ORDER BY
                CASE WHEN @SortByUpper = 'EXECUTIONS' THEN SortKeyBigint END DESC,
                CASE WHEN @SortByUpper = 'DURATION'   THEN TotalDurationUs END DESC,
                CASE WHEN @SortByUpper = 'LAST_EXEC'  THEN SortKeyDate END DESC,
                CASE WHEN @SortByUpper = 'DATABASE'   THEN SortKeyText END,
                WorkloadType,
                WorkloadName
      ) AS w

    SELECT @LineNo = ISNULL(MAX([LineNo]), @LineNo) FROM #Report

    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT @LineNo + 1, LEFT(@Divider, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 2, LEFT(' Legend: WORKLOAD groups Query Store entries by object or query hash.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 3, LEFT(' Types: Stored Procedure, Procedure Call, SQL Agent / Job, Maintenance, Application Query.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 4, LEFT(' Note: SQL Agent jobs are inferred from query text patterns; program name is not in Query Store.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 5, LEFT(@HeaderRule, @ReportWidth)
END

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

GO

IF OBJECT_ID('dbo.ShowQueryStoreWorkloadReport') IS NOT NULL
    PRINT 'Procedure ShowQueryStoreWorkloadReport created.'
ELSE
    PRINT 'Procedure ShowQueryStoreWorkloadReport NOT created.'
GO