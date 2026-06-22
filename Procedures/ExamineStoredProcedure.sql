USE dba
GO

/*
  ExamineStoredProcedure.sql

  Deploy to the DBA tool database, then execute:
    EXEC dbo.ExamineStoredProcedure
         @TargetDatabase = N'YourDatabase',
         @ProcedureName  = N'YourProcedure'

  Optional parameters:
    @SchemaName         - schema of the procedure (default dbo)
    @MinSeverity        - LOW | MEDIUM | HIGH | CRITICAL (default LOW)
    @GiantLineChars     - flag a single line at or above this length (default 2000)
    @GiantModuleChars   - flag monolithic procedures at or above this length (default 10000)
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ExamineStoredProcedure
(
    @TargetDatabase     sysname      = NULL,
    @SchemaName         sysname      = N'dbo',
    @ProcedureName      sysname,
    @MinSeverity        varchar(10)  = N'LOW',
    @GiantLineChars     int          = 2000,
    @GiantModuleChars   int          = 10000
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 20, 2026
-- Author:       Bill McEvoy
-- Description:  Examines a stored procedure definition and reports common SQL Server anti-patterns
--               with severity, line number, excerpt, and remediation guidance.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @ObjectId        int,
    @Definition      nvarchar(max),
    @Normalized      nvarchar(max),
    @Line            nvarchar(max),
    @LineNo          int,
    @LineUpper       nvarchar(max),
    @ObjectName      nvarchar(261),
    @CreateDate      datetime,
    @ModifyDate      datetime,
    @ModuleLength    int,
    @FindingCount    int,
    @CriticalCount   int,
    @HighCount       int,
    @MediumCount     int,
    @LowCount        int,
    @MinSeverityRank tinyint,
    @Sql               nvarchar(max),
    @SchemaQuoted      nvarchar(260),
    @ProcQuoted        nvarchar(260),
    @NormalizedUpper   nvarchar(max),
    @MaxLineLen        int,
    @LineCount         int,
    @StatementCount    int,
    @SelectCount       int,
    @FuncSchema        sysname,
    @FuncName          sysname,
    @FuncToken         nvarchar(260),
    @FuncPos           int,
    @ContextWindow     nvarchar(200),
    @ContextLineNo     int,
    @ContextExcerpt    nvarchar(400),
    @SearchFrom        int

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

IF @ProcedureName IS NULL OR LTRIM(RTRIM(@ProcedureName)) = ''
BEGIN
    RAISERROR('@ProcedureName is required.', 16, 1)
    RETURN
END

SET @MinSeverity = UPPER(ISNULL(@MinSeverity, 'LOW'))

SET @MinSeverityRank = CASE @MinSeverity
    WHEN 'CRITICAL' THEN 4
    WHEN 'HIGH'     THEN 3
    WHEN 'MEDIUM'   THEN 2
    WHEN 'LOW'      THEN 1
    ELSE 1
END

SET @SchemaQuoted = QUOTENAME(@SchemaName)
SET @ProcQuoted   = QUOTENAME(@ProcedureName)
SET @ObjectName   = QUOTENAME(@TargetDatabase) + N'.' + @SchemaQuoted + N'.' + @ProcQuoted

IF DB_ID(@TargetDatabase) IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

SET @Sql = N'
SELECT
    @ObjectId     = o.object_id,
    @Definition   = m.definition,
    @CreateDate   = o.create_date,
    @ModifyDate   = o.modify_date,
    @ModuleLength = LEN(m.definition)
FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.objects AS o
INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.sql_modules AS m
    ON o.object_id = m.object_id
WHERE o.type = ''P''
  AND o.name = @ProcedureName
  AND SCHEMA_NAME(o.schema_id) = @SchemaName'

EXEC sys.sp_executesql
    @Sql,
    N'@ProcedureName sysname, @SchemaName sysname,
      @ObjectId int OUTPUT, @Definition nvarchar(max) OUTPUT,
      @CreateDate datetime OUTPUT, @ModifyDate datetime OUTPUT,
      @ModuleLength int OUTPUT',
    @ProcedureName = @ProcedureName,
    @SchemaName = @SchemaName,
    @ObjectId = @ObjectId OUTPUT,
    @Definition = @Definition OUTPUT,
    @CreateDate = @CreateDate OUTPUT,
    @ModifyDate = @ModifyDate OUTPUT,
    @ModuleLength = @ModuleLength OUTPUT

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Stored procedure %s was not found in database ''%s''.', 16, 1, @ObjectName, @TargetDatabase)
    RETURN
END

IF @Definition IS NULL OR LEN(@Definition) = 0
BEGIN
    RAISERROR('Stored procedure %s is encrypted or has no readable definition.', 16, 1, @ObjectName)
    RETURN
END

IF OBJECT_ID('tempdb..#Lines') IS NOT NULL
    DROP TABLE #Lines

CREATE TABLE #Lines
(
    LineNo   int            NOT NULL PRIMARY KEY,
    LineText nvarchar(max)  NOT NULL
)

IF OBJECT_ID('tempdb..#InlineTVFs') IS NOT NULL
    DROP TABLE #InlineTVFs

CREATE TABLE #InlineTVFs
(
    SchemaName   sysname NOT NULL,
    FunctionName sysname NOT NULL,
    PRIMARY KEY (SchemaName, FunctionName)
)

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL
    DROP TABLE #Findings

CREATE TABLE #Findings
(
    FindingId      int            NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    Severity       varchar(10)    NOT NULL,
    SeverityRank   tinyint        NOT NULL,
    Category       varchar(30)    NOT NULL,
    PatternName    varchar(60)    NOT NULL,
    LineNo         int            NULL,
    Excerpt        nvarchar(400)  NULL,
    Recommendation nvarchar(500)  NOT NULL
)

SET @Normalized = REPLACE(REPLACE(REPLACE(@Definition, CHAR(13) + CHAR(10), CHAR(10)), CHAR(13), CHAR(10)), CHAR(9), ' ')
SET @NormalizedUpper = UPPER(@Normalized)

SET @Sql = N'
INSERT INTO #InlineTVFs (SchemaName, FunctionName)
SELECT SCHEMA_NAME(o.schema_id), o.name
  FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.objects AS o
 WHERE o.type = ''IF'''

EXEC sys.sp_executesql @Sql

;WITH LineSplit AS
(
    SELECT
        LineNo   = 1,
        StartPos = 1,
        EndPos   = CHARINDEX(CHAR(10), @Normalized + CHAR(10), 1) - 1
    UNION ALL
    SELECT
        LineNo   = ls.LineNo + 1,
        StartPos = ls.EndPos + 2,
        EndPos   = CHARINDEX(CHAR(10), @Normalized + CHAR(10), ls.EndPos + 2) - 1
      FROM LineSplit AS ls
     WHERE ls.EndPos < LEN(@Normalized)
)
INSERT INTO #Lines (LineNo, LineText)
SELECT
    ls.LineNo,
    SUBSTRING(@Normalized, ls.StartPos, ls.EndPos - ls.StartPos + 1)
  FROM LineSplit AS ls
OPTION (MAXRECURSION 32767)

IF NOT EXISTS (SELECT 1 FROM #Lines)
    INSERT INTO #Lines (LineNo, LineText) VALUES (1, @Normalized)

DECLARE LineCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT LineNo, LineText
  FROM #Lines
 ORDER BY LineNo

OPEN LineCursor
FETCH NEXT FROM LineCursor INTO @LineNo, @Line

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @LineUpper = UPPER(@Line)

    IF @LineUpper LIKE '%SELECT%*%' AND @LineUpper NOT LIKE '%SELECT%@%'
       AND @LineUpper NOT LIKE '%COUNT(%*%)%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Query', 'SELECT *',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'List required columns instead of SELECT * to reduce I/O, breaking schema changes, and plan instability.'
        )
    END

    IF @LineUpper LIKE '%(NOLOCK)%' OR @LineUpper LIKE '% NOLOCK%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Concurrency', 'NOLOCK / READ UNCOMMITTED',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'NOLOCK can return dirty reads, phantom rows, and duplicate or missing rows. Prefer READ COMMITTED SNAPSHOT or proper isolation.'
        )
    END

    IF @LineUpper LIKE '%READ UNCOMMITTED%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Concurrency', 'READ UNCOMMITTED isolation',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'READ UNCOMMITTED has the same consistency risks as NOLOCK. Use RCSI or an explicit isolation level with intent.'
        )
    END

    IF @LineUpper LIKE '%DECLARE%CURSOR%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'Cursor', 'DECLARE CURSOR',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Set-based operations are usually faster and more scalable than row-by-row cursors.'
        )
    END

    IF @LineUpper LIKE '%@@IDENTITY%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'Identity', '@@IDENTITY',
            @LineNo, LEFT(LTRIM(@Line), 400),
            '@@IDENTITY can reflect triggers or other scopes. Prefer SCOPE_IDENTITY() or OUTPUT.'
        )
    END

    IF @LineUpper LIKE '%XP_CMDSHELL%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'CRITICAL', 4, 'Security', 'xp_cmdshell',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'xp_cmdshell expands the attack surface. Restrict usage, audit callers, and prefer safer integration paths.'
        )
    END

    IF @LineUpper LIKE '%XP_REG%' OR @LineUpper LIKE '%SP_OA%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'CRITICAL', 4, 'Security', 'Extended/OLE automation procedure',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Registry and OLE extended procedures are high-risk. Remove if possible and restrict to trusted admins only.'
        )
    END

    IF @LineUpper LIKE '%SP_MSFOREACH%' OR @LineUpper LIKE '%SP_MSFOREACHDB%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Deprecated', 'sp_msforeach*',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Undocumented sp_msforeach* procedures are unsupported. Replace with explicit loops or catalog queries.'
        )
    END

    IF @LineUpper LIKE '%INSERT%INTO%SELECT%' AND @LineUpper NOT LIKE '%INSERT%INTO%(%SELECT%'
       AND @LineUpper NOT LIKE '%INSERT%INTO%(%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'DML', 'INSERT without column list',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Specify the destination column list so schema changes do not silently break inserts.'
        )
    END

    IF @LineUpper LIKE '%DELETE%FROM%' AND @LineUpper NOT LIKE '%WHERE%'
       AND @LineUpper NOT LIKE '%JOIN%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'DML', 'DELETE without WHERE',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Unqualified DELETE removes all rows. Add a selective WHERE clause or JOIN.'
        )
    END

    IF @LineUpper LIKE '%UPDATE %' AND @LineUpper LIKE '% SET %' AND @LineUpper NOT LIKE '%WHERE%'
       AND @LineUpper NOT LIKE '%JOIN%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'DML', 'UPDATE without WHERE',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Unqualified UPDATE changes every row in the target. Add a selective WHERE clause or JOIN.'
        )
    END

    IF @LineUpper LIKE '%LIKE ''%[%]%'
       OR @LineUpper LIKE '%LIKE N''%[%]%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'SARGability', 'Leading wildcard LIKE',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Leading % prevents efficient index seeks. Consider full-text search, persisted computed columns, or redesigned filters.'
        )
    END

    IF @LineUpper LIKE '%WHERE%YEAR(%' OR @LineUpper LIKE '%WHERE%MONTH(%' OR @LineUpper LIKE '%WHERE%DATEPART(%'
       OR @LineUpper LIKE '%AND%YEAR(%' OR @LineUpper LIKE '%AND%MONTH(%' OR @LineUpper LIKE '%AND%DATEPART(%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'SARGability', 'Function on column in predicate',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Applying functions to columns in WHERE/JOIN predicates often blocks index usage. Filter on a range instead.'
        )
    END

    IF @LineUpper LIKE '%WHERE%CONVERT(%' OR @LineUpper LIKE '%WHERE%CAST(%'
       OR @LineUpper LIKE '%AND%CONVERT(%' OR @LineUpper LIKE '%AND%CAST(%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'SARGability', 'CONVERT/CAST on column in predicate',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Converting column data in predicates can force scans. Compare compatible types or persist a converted value.'
        )
    END

    IF @LineUpper LIKE '%OPTION (%FORCE ORDER%' OR @LineUpper LIKE '%OPTION(%FORCE ORDER%'
       OR @LineUpper LIKE '%OPTION (%LOOP JOIN%' OR @LineUpper LIKE '%OPTION(%LOOP JOIN%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Hints', 'Join order hint',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Forced join order can help a single query but often becomes brittle as data changes. Document and retest regularly.'
        )
    END

    IF @LineUpper LIKE '%OPTION (%RECOMPILE%' OR @LineUpper LIKE '%OPTION(%RECOMPILE%'
       OR @LineUpper LIKE '%WITH RECOMPILE%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'LOW', 1, 'Hints', 'RECOMPILE',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Compile-on-every-execution can increase CPU. Use only when parameter sniffing truly requires it.'
        )
    END

    IF @LineUpper LIKE '%SET ROWCOUNT%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Deprecated', 'SET ROWCOUNT',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'SET ROWCOUNT is deprecated for DML. Use TOP with an ORDER BY or set-based logic instead.'
        )
    END

    IF @LineUpper LIKE '%TOP 100 PERCENT%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Deprecated', 'TOP 100 PERCENT',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'TOP 100 PERCENT with ORDER BY is a legacy pattern. Use ORDER BY without TOP when sorting the full set.'
        )
    END

    IF @LineUpper LIKE '%GOTO %'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Control Flow', 'GOTO',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'GOTO obscures control flow and makes maintenance harder. Prefer structured IF/ELSE and TRY/CATCH.'
        )
    END

    IF @LineUpper LIKE '%WAITFOR DELAY%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'LOW', 1, 'Performance', 'WAITFOR DELAY',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Artificial delays consume worker threads. Use only for polling, throttling, or deliberate diagnostics.'
        )
    END

    IF @LineUpper LIKE '%##%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'TempDB', 'Global temp table',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Global temp tables (##) are visible across sessions and can create contention or naming collisions.'
        )
    END

    IF @LineUpper LIKE '%EXEC %' OR @LineUpper LIKE '%EXECUTE %'
    BEGIN
        IF (@LineUpper LIKE '%+ %' OR @LineUpper LIKE '%''%+%''%')
           AND @LineUpper NOT LIKE '%SP_EXECUTESQL%'
        BEGIN
            INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
            VALUES (
                'HIGH', 3, 'Dynamic SQL', 'Concatenated dynamic SQL',
                @LineNo, LEFT(LTRIM(@Line), 400),
                'Concatenating SQL can invite injection and plan-cache bloat. Use sp_executesql with parameters.'
            )
        END
    END

    IF @LineUpper LIKE '%SP_EXECUTESQL%' AND (@LineUpper LIKE '%+ %' OR @LineUpper LIKE '%''%+%''%')
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'Dynamic SQL', 'Concatenated sp_executesql text',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Even with sp_executesql, concatenating the SQL text is risky. Keep parameters separate from command text.'
        )
    END

    IF @LineUpper LIKE '%WHILE %'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'LOW', 1, 'Iteration', 'WHILE loop',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Row-by-row loops are often slower than set-based rewrites. Validate whether a set-based approach is possible.'
        )
    END

    IF @LineUpper LIKE '%PRINT %'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'LOW', 1, 'Diagnostics', 'PRINT',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'PRINT is fine for ad hoc debugging but noisy in production. Consider structured logging for permanent instrumentation.'
        )
    END

    IF @LineUpper LIKE '%CROSS APPLY %(%' OR @LineUpper LIKE '%OUTER APPLY %(%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'Inline TVF', 'APPLY with table-valued function',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Inline table-valued functions in APPLY can perform poorly. Consider inline subqueries, indexed views, or multi-statement TVFs where appropriate.'
        )
    END

    IF (@LineUpper LIKE '%JOIN %.%(%' OR (@LineUpper LIKE '%JOIN %(%' AND @LineUpper NOT LIKE '%JOIN (%'))
       AND @LineUpper NOT LIKE '%JOIN (SELECT%'
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'Inline TVF', 'JOIN to table-valued function',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Joining to a table-valued function can force row-by-row evaluation. Materialize to a temp table or rewrite as a set-based join.'
        )
    END

    IF @LineUpper LIKE '%WHERE%'
       AND (
            @LineUpper LIKE '%EXISTS%(%(%'
            OR @LineUpper LIKE '% IN %(%'
            OR (@LineUpper LIKE '%=%(%' AND @LineUpper NOT LIKE '%=%(%SELECT%')
       )
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'MEDIUM', 2, 'Inline TVF', 'Table-valued function in WHERE predicate',
            @LineNo, LEFT(LTRIM(@Line), 400),
            'Table-valued functions in WHERE/EXISTS/IN predicates are often non-SARGable and expensive. Rewrite to joins or staged temp tables.'
        )
    END

    IF LEN(@Line) >= @GiantLineChars
    BEGIN
        INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
        VALUES (
            'HIGH', 3, 'Giant Query', 'Very long single line',
            @LineNo, LEFT(LTRIM(@Line), 400) + ' ... [truncated]',
            'A single line of ' + CAST(LEN(@Line) AS varchar(12)) + ' characters suggests a monolithic statement that is hard to tune, test, and maintain. Break into stages, temp tables, or views.'
        )
    END

    FETCH NEXT FROM LineCursor INTO @LineNo, @Line
END

CLOSE LineCursor
DEALLOCATE LineCursor

SELECT
    @MaxLineLen     = MAX(LEN(LineText)),
    @LineCount      = COUNT(*)
  FROM #Lines

SET @StatementCount = LEN(@Normalized) - LEN(REPLACE(@Normalized, ';', ''))
SET @SelectCount    = (LEN(@NormalizedUpper) - LEN(REPLACE(@NormalizedUpper, 'SELECT', ''))) / 6

IF @ModuleLength >= @GiantModuleChars
   AND @StatementCount <= 4
   AND @SelectCount <= 2
BEGIN
    INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
    VALUES (
        'HIGH', 3, 'Giant Query', 'One giant query procedure',
        NULL,
        'Module length ' + CAST(@ModuleLength AS varchar(12)) + ' chars; statements ~' + CAST(@StatementCount AS varchar(10)) + '; SELECT count ~' + CAST(@SelectCount AS varchar(10)),
        'The procedure appears to be dominated by one very large query. Split into staged temp tables, views, or smaller procedures to improve plan quality and maintainability.'
    )
END

IF @LineCount <= 8 AND @ModuleLength >= (@GiantModuleChars / 2)
BEGIN
    INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
    VALUES (
        'MEDIUM', 2, 'Giant Query', 'Few lines, large module',
        NULL,
        CAST(@LineCount AS varchar(10)) + ' lines across ' + CAST(@ModuleLength AS varchar(12)) + ' characters (max line ' + CAST(ISNULL(@MaxLineLen, 0) AS varchar(12)) + ')',
        'Very long lines or pasted SQL make the procedure difficult to review. Format into readable steps and named sections.'
    )
END

DECLARE InlineFuncCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT SchemaName, FunctionName
  FROM #InlineTVFs

OPEN InlineFuncCursor
FETCH NEXT FROM InlineFuncCursor INTO @FuncSchema, @FuncName

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SearchFrom = 1

    WHILE @SearchFrom <= @ModuleLength
    BEGIN
        SET @FuncPos = CHARINDEX(UPPER(@FuncSchema) + '.' + UPPER(@FuncName) + '(', @NormalizedUpper, @SearchFrom)

        IF @FuncPos = 0
            SET @FuncPos = CHARINDEX('[' + UPPER(@FuncSchema) + '].[' + UPPER(@FuncName) + '](', @NormalizedUpper, @SearchFrom)

        IF @FuncPos = 0
            SET @FuncPos = CHARINDEX('.' + UPPER(@FuncName) + '(', @NormalizedUpper, @SearchFrom)

        IF @FuncPos = 0
            SET @FuncPos = CHARINDEX('[' + UPPER(@FuncName) + '](', @NormalizedUpper, @SearchFrom)

        IF @FuncPos = 0
            SET @FuncPos = CHARINDEX(UPPER(@FuncName) + '(', @NormalizedUpper, @SearchFrom)

        IF @FuncPos = 0
            BREAK
        SET @ContextWindow = SUBSTRING(
            @NormalizedUpper,
            CASE WHEN @FuncPos - 120 < 1 THEN 1 ELSE @FuncPos - 120 END,
            120)

        SET @ContextLineNo = (
            LEN(SUBSTRING(@Normalized, 1, @FuncPos))
            - LEN(REPLACE(SUBSTRING(@Normalized, 1, @FuncPos), CHAR(10), ''))
            + 1
        )

        SET @ContextExcerpt = SUBSTRING(@Normalized, @FuncPos, 400)

        IF @ContextWindow LIKE '%JOIN %' OR @ContextWindow LIKE '%JOIN%'
           OR @ContextWindow LIKE '%APPLY %' OR @ContextWindow LIKE '%APPLY%'
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                  FROM #Findings
                 WHERE PatternName = 'Catalog inline TVF in JOIN/APPLY'
                   AND Excerpt LIKE '%' + @FuncName + '%'
            )
            INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
            VALUES (
                'HIGH', 3, 'Inline TVF', 'Catalog inline TVF in JOIN/APPLY',
                @ContextLineNo, LEFT(@ContextExcerpt, 400),
                QUOTENAME(@FuncSchema) + '.' + QUOTENAME(@FuncName) + ' is an inline TVF (type IF). Avoid joining or APPLYing inline TVFs; stage results or rewrite as set-based SQL.'
            )
        END
        ELSE IF @ContextWindow LIKE '%WHERE %' OR @ContextWindow LIKE '%WHERE%'
                OR @ContextWindow LIKE '%EXISTS %' OR @ContextWindow LIKE '% IN %'
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                  FROM #Findings
                 WHERE PatternName = 'Catalog inline TVF in WHERE'
                   AND Excerpt LIKE '%' + @FuncName + '%'
            )
            INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
            VALUES (
                'HIGH', 3, 'Inline TVF', 'Catalog inline TVF in WHERE',
                @ContextLineNo, LEFT(@ContextExcerpt, 400),
                QUOTENAME(@FuncSchema) + '.' + QUOTENAME(@FuncName) + ' is an inline TVF used in a predicate. Move to a temp table or join in the FROM clause instead.'
            )
        END
        ELSE IF @ContextWindow LIKE '%FROM %' OR @ContextWindow LIKE '%FROM,%' OR @ContextWindow LIKE '%,%'
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                  FROM #Findings
                 WHERE PatternName = 'Catalog inline TVF in FROM'
                   AND Excerpt LIKE '%' + @FuncName + '%'
            )
            INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
            VALUES (
                'MEDIUM', 2, 'Inline TVF', 'Catalog inline TVF in FROM',
                @ContextLineNo, LEFT(@ContextExcerpt, 400),
                QUOTENAME(@FuncSchema) + '.' + QUOTENAME(@FuncName) + ' is an inline TVF in the FROM clause. Consider whether a view, temp table, or rewritten query would plan better.'
            )
        END

        SET @SearchFrom = @FuncPos + 1
    END

    FETCH NEXT FROM InlineFuncCursor INTO @FuncSchema, @FuncName
END

CLOSE InlineFuncCursor
DEALLOCATE InlineFuncCursor

IF UPPER(@Normalized) NOT LIKE '%SET NOCOUNT ON%'
BEGIN
    INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
    VALUES (
        'LOW', 1, 'Procedure Style', 'Missing SET NOCOUNT ON',
        NULL, NULL,
        'SET NOCOUNT ON reduces DONE_IN_PROC messages and is standard for stored procedures.'
    )
END

IF UPPER(@Normalized) LIKE '%TRY%' AND UPPER(@Normalized) LIKE '%CATCH%'
   AND UPPER(@Normalized) LIKE '%BEGIN TRAN%'
   AND UPPER(@Normalized) NOT LIKE '%@@TRANCOUNT%'
   AND UPPER(@Normalized) NOT LIKE '%ROLLBACK%'
BEGIN
    INSERT INTO #Findings (Severity, SeverityRank, Category, PatternName, LineNo, Excerpt, Recommendation)
    VALUES (
        'MEDIUM', 2, 'Error Handling', 'TRY/CATCH with transaction',
        NULL, NULL,
        'Transactions inside TRY/CATCH should check @@TRANCOUNT and roll back on failure to avoid orphaned transactions.'
    )
END

SELECT
    @FindingCount  = COUNT(*),
    @CriticalCount = SUM(CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 0 END),
    @HighCount     = SUM(CASE WHEN Severity = 'HIGH' THEN 1 ELSE 0 END),
    @MediumCount   = SUM(CASE WHEN Severity = 'MEDIUM' THEN 1 ELSE 0 END),
    @LowCount      = SUM(CASE WHEN Severity = 'LOW' THEN 1 ELSE 0 END)
  FROM #Findings
 WHERE SeverityRank >= @MinSeverityRank

PRINT '====================================='
PRINT '= STORED PROCEDURE ANTI-PATTERN SCAN ='
PRINT '====================================='
PRINT CONVERT(char(19), GETDATE(), 120)
PRINT 'Object: ' + @ObjectName
PRINT 'Created: ' + CONVERT(char(19), @CreateDate, 120)
PRINT 'Modified: ' + CONVERT(char(19), @ModifyDate, 120)
PRINT 'Module length (chars): ' + CAST(@ModuleLength AS varchar(12))
PRINT 'Minimum severity: ' + @MinSeverity
PRINT ' '
PRINT 'Findings: ' + CAST(ISNULL(@FindingCount, 0) AS varchar(10))
PRINT '  Critical: ' + CAST(ISNULL(@CriticalCount, 0) AS varchar(10))
PRINT '  High    : ' + CAST(ISNULL(@HighCount, 0) AS varchar(10))
PRINT '  Medium  : ' + CAST(ISNULL(@MediumCount, 0) AS varchar(10))
PRINT '  Low     : ' + CAST(ISNULL(@LowCount, 0) AS varchar(10))
PRINT ' '

IF ISNULL(@FindingCount, 0) = 0
BEGIN
    PRINT 'No anti-patterns matched at or above the requested severity.'
END
ELSE
BEGIN
    SELECT
        Severity,
        Category,
        PatternName,
        LineNo,
        Excerpt,
        Recommendation
      FROM #Findings
     WHERE SeverityRank >= @MinSeverityRank
     ORDER BY SeverityRank DESC, ISNULL(LineNo, 2147483647), PatternName
END

GO

IF OBJECT_ID('dbo.ExamineStoredProcedure') IS NOT NULL
    PRINT 'Procedure ExamineStoredProcedure created.'
ELSE
    PRINT 'Procedure ExamineStoredProcedure NOT created.'
GO