/*
  ShowExpandedView.sql
  Performance Tuning Framework

  Requires SQL Server 2008 (10.x) or later on the instance.
  Target database compatibility level 100+ (SQL Server 2008 mode).
  Uses sys.sql_modules and sys.sql_expression_dependencies.

  Deploy to the tool database, then execute:
    EXEC dbo.ShowExpandedView
         @TargetDatabase = N'YourDatabase',
         @ViewName       = N'vLargeReport'

    EXEC dbo.ShowExpandedView
         @TargetDatabase = N'YourDatabase',
         @ViewName       = N'Sales.vOrders'
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowExpandedView') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowExpandedView'
    DROP PROCEDURE dbo.ShowExpandedView
END
GO

PRINT 'Creating: ShowExpandedView (2026-09-01)'
GO

CREATE PROCEDURE dbo.ShowExpandedView
(
    @TargetDatabase   sysname = NULL,
    @ViewName         sysname,
    @SchemaName       sysname = N'dbo',
    @ReturnResultSets bit     = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: September 1, 2026
-- Author:       Bill McEvoy
-- Description:  Decodes one view in a target database and recursively inlines nested view
--               definitions so the entire query can be inspected for troubleshooting.
--               Walks JOIN/FROM/APPLY/CTE view references via sys.sql_expression_dependencies.
--               Detects circular references. Does not execute the expanded SQL. Does not scan
--               user tables. Requires SQL Server 2008 (10.x) or later.
-- Date Revised: September 1, 2026
-- Reason:       Stop runaway expansion. Inline nested views leaves-first once; never UPPER()
--               the full nvarchar(max); cap body size and STUFF replacements.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion           tinyint,
    @CompatibilityLevel     int,
    @ReportedCompatLevel    int,
    @TargetDatabaseId       int,
    @QuotedDatabase         nvarchar(260),
    @Sql                    nvarchar(max),
    @ObjectId               int,
    @ParsedSchema           sysname,
    @ParsedView             sysname,
    @HasCircularReference   bit,
    @HitMaxWalkDepth        bit,
    @HitSizeCap             bit,
    @HitReplacementCap      bit,
    @NestedViewCount        int,
    @MaxDepth               int,
    @Note                   nvarchar(2000),
    @CycleList              nvarchar(2000),
    @ExpandedSql            nvarchar(max),
    @RootBody               nvarchar(max),
    @Qid                    int,
    @CurrentId              int,
    @CurrentDepth           int,
    @CurrentPath            varchar(max),
    @CurrentSchema          sysname,
    @CurrentView            sysname,
    @RefId                  int,
    @RefSchema              sysname,
    @RefView                sysname,
    @Already                bit,
    @IsCycle                bit,
    @KidId                  int,
    @MaxBodyBytes           int,
    @MaxReplacements        int,
    @TotalReplacements      int,
    @HostId                 int,
    @HostBody               nvarchar(max),
    @Needle                 nvarchar(1000),
    @Replacement            nvarchar(max),
    @Inline                 nvarchar(max),
    @Alias                  nvarchar(300),
    @NeedleLen              int,
    @ReplLen                int,
    @Found                  int,
    @SearchFrom             int,
    @Before                 nchar(1),
    @After                  nchar(1),
    @IsIdentBefore          bit,
    @IsIdentAfter           bit,
    @SkipThis               bit,
    @k                      int,
    @Oid                    int,
    @Body                   nvarchar(max),
    @Def                    nvarchar(max),
    @Phase                  int,
    @Tok                    nvarchar(256),
    @TokType                varchar(20),
    @ParenDepth             int,
    @n                      int,
    @i                      int,
    @c                      nchar(1),
    @c2                     nvarchar(2),
    @IsUnambiguous          bit,
    @InCycle                bit,
    @IsEncrypted            bit,
    @DidInline              bit,
    @Reason                 nvarchar(200),
    @StillPresent           bit,
    @Chk                    int,
    @Tail                   nvarchar(50)

IF @ViewName IS NULL OR LTRIM(RTRIM(@ViewName)) = N''
BEGIN
    RAISERROR('@ViewName is required.', 16, 1)
    RETURN
END

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @ParsedSchema = PARSENAME(@ViewName, 2)
SET @ParsedView  = PARSENAME(@ViewName, 1)

IF @ParsedView IS NULL
BEGIN
    RAISERROR('Could not parse @ViewName ''%s''.', 16, 1, @ViewName)
    RETURN
END

IF @ParsedSchema IS NOT NULL
    SET @SchemaName = @ParsedSchema

SET @ViewName = @ParsedView

IF @SchemaName IS NULL OR LTRIM(RTRIM(@SchemaName)) = N''
    SET @SchemaName = N'dbo'

SET @TargetDatabaseId = DB_ID(@TargetDatabase)
SET @QuotedDatabase   = QUOTENAME(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 10
BEGIN
    RAISERROR('ShowExpandedView requires SQL Server 2008 (10.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SELECT @CompatibilityLevel = d.compatibility_level
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId

SET @ReportedCompatLevel = ISNULL(@CompatibilityLevel, 0)

IF @ReportedCompatLevel < 100
BEGIN
    RAISERROR('Target database ''%s'' compatibility level %d is below 100 (SQL Server 2008).', 16, 1, @TargetDatabase, @ReportedCompatLevel)
    RETURN
END

SET @HasCircularReference = 0
SET @HitMaxWalkDepth      = 0
SET @HitSizeCap           = 0
SET @HitReplacementCap    = 0
SET @MaxBodyBytes         = 8 * 1024 * 1024
SET @MaxReplacements      = 2000
SET @TotalReplacements    = 0

IF OBJECT_ID('tempdb..#CatalogViews') IS NOT NULL DROP TABLE #CatalogViews
IF OBJECT_ID('tempdb..#CatalogViewDeps') IS NOT NULL DROP TABLE #CatalogViewDeps
IF OBJECT_ID('tempdb..#ViewList') IS NOT NULL DROP TABLE #ViewList
IF OBJECT_ID('tempdb..#ViewTree') IS NOT NULL DROP TABLE #ViewTree
IF OBJECT_ID('tempdb..#Queue') IS NOT NULL DROP TABLE #Queue
IF OBJECT_ID('tempdb..#Kids') IS NOT NULL DROP TABLE #Kids
IF OBJECT_ID('tempdb..#CycleEdges') IS NOT NULL DROP TABLE #CycleEdges
IF OBJECT_ID('tempdb..#BaseTables') IS NOT NULL DROP TABLE #BaseTables
IF OBJECT_ID('tempdb..#Unexpanded') IS NOT NULL DROP TABLE #Unexpanded
IF OBJECT_ID('tempdb..#Needles') IS NOT NULL DROP TABLE #Needles
IF OBJECT_ID('tempdb..#ExpandOrder') IS NOT NULL DROP TABLE #ExpandOrder

CREATE TABLE #CatalogViews
(
    ObjectId   int     NOT NULL PRIMARY KEY,
    SchemaName sysname NOT NULL,
    ViewName   sysname NOT NULL
)

CREATE TABLE #CatalogViewDeps
(
    ReferencingId int NOT NULL,
    ReferencedId  int NOT NULL,
    PRIMARY KEY (ReferencingId, ReferencedId)
)

CREATE TABLE #ViewList
(
    ObjectId      int           NOT NULL PRIMARY KEY,
    SchemaName    sysname       NOT NULL,
    ViewName      sysname       NOT NULL,
    IsRoot        bit           NOT NULL,
    MinDepth      int           NOT NULL,
    InCycle       bit           NOT NULL,
    IsEncrypted   bit           NOT NULL,
    Definition    nvarchar(max) NULL,
    Body          nvarchar(max) NULL,
    ReplacedCount int           NOT NULL
)

CREATE TABLE #ViewTree
(
    TreeId       int           NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    Depth        int           NOT NULL,
    SchemaName   sysname       NOT NULL,
    ViewName     sysname       NOT NULL,
    ReferencedBy nvarchar(260) NULL,
    ObjectId     int           NOT NULL
)

CREATE TABLE #Queue
(
    Qid      int          NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    ObjectId int          NOT NULL,
    Depth    int          NOT NULL,
    Path     varchar(max) NOT NULL,
    Taken    bit          NOT NULL
)

CREATE TABLE #Kids
(
    KidId        int     NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    ReferencedId int     NOT NULL,
    SchemaName   sysname NOT NULL,
    ViewName     sysname NOT NULL,
    Taken        bit     NOT NULL
)

CREATE TABLE #CycleEdges
(
    FromName nvarchar(260) NOT NULL,
    ToName   nvarchar(260) NOT NULL
)

CREATE TABLE #BaseTables
(
    SchemaName sysname NOT NULL,
    TableName  sysname NOT NULL,
    PRIMARY KEY (SchemaName, TableName)
)

CREATE TABLE #Unexpanded
(
    SchemaName sysname       NOT NULL,
    ViewName   sysname       NOT NULL,
    Reason     nvarchar(200) NOT NULL
)

CREATE TABLE #Needles
(
    NeedleId int            NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    Needle   nvarchar(1000) NOT NULL,
    Taken    bit            NOT NULL
)

CREATE TABLE #ExpandOrder
(
    ObjectId int NOT NULL PRIMARY KEY,
    Taken    bit NOT NULL
)

SET @Sql = N'
SELECT @ObjectId = v.object_id
  FROM __TARGET_DB__.sys.views AS v
 INNER JOIN __TARGET_DB__.sys.schemas AS s
    ON s.schema_id = v.schema_id
 WHERE s.name = @SchemaName
   AND v.name = @ViewName
   AND v.is_ms_shipped = 0
'

SET @Sql = REPLACE(@Sql, N'__TARGET_DB__', @QuotedDatabase)

EXEC sys.sp_executesql
    @Sql,
    N'@SchemaName sysname, @ViewName sysname, @ObjectId int OUTPUT',
    @SchemaName = @SchemaName,
    @ViewName   = @ViewName,
    @ObjectId   = @ObjectId OUTPUT

IF @ObjectId IS NULL
BEGIN
    RAISERROR('View %s.%s was not found in database ''%s''.', 16, 1, @SchemaName, @ViewName, @TargetDatabase)
    RETURN
END

SET @Sql = N'
INSERT #CatalogViews (ObjectId, SchemaName, ViewName)
SELECT
    v.object_id,
    s.name,
    v.name
  FROM __TARGET_DB__.sys.views AS v
 INNER JOIN __TARGET_DB__.sys.schemas AS s
    ON s.schema_id = v.schema_id
 WHERE v.is_ms_shipped = 0

INSERT #CatalogViewDeps (ReferencingId, ReferencedId)
SELECT DISTINCT
    d.referencing_id,
    d.referenced_id
  FROM __TARGET_DB__.sys.sql_expression_dependencies AS d
 INNER JOIN __TARGET_DB__.sys.views AS rv
    ON rv.object_id = d.referencing_id
 INNER JOIN __TARGET_DB__.sys.views AS tv
    ON tv.object_id = d.referenced_id
 WHERE d.referenced_class = 1
   AND d.referencing_class = 1
   AND d.referenced_id IS NOT NULL
   AND d.referenced_server_name IS NULL
   AND (d.referenced_database_name IS NULL OR d.referenced_database_name = @TargetDatabase)
   AND rv.is_ms_shipped = 0
   AND tv.is_ms_shipped = 0
'

SET @Sql = REPLACE(@Sql, N'__TARGET_DB__', @QuotedDatabase)

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabase sysname',
    @TargetDatabase = @TargetDatabase

INSERT #ViewList
(
    ObjectId, SchemaName, ViewName, IsRoot, MinDepth, InCycle, IsEncrypted,
    Definition, Body, ReplacedCount
)
VALUES
(
    @ObjectId, @SchemaName, @ViewName, 1, 0, 0, 0,
    NULL, NULL, 0
)

INSERT #ViewTree (Depth, SchemaName, ViewName, ReferencedBy, ObjectId)
VALUES (0, @SchemaName, @ViewName, NULL, @ObjectId)

INSERT #Queue (ObjectId, Depth, Path, Taken)
VALUES (@ObjectId, 0, '/' + CONVERT(varchar(11), @ObjectId) + '/', 0)

WHILE EXISTS (SELECT 1 FROM #Queue WHERE Taken = 0)
BEGIN
    SELECT TOP (1)
        @Qid           = Qid,
        @CurrentId     = ObjectId,
        @CurrentDepth  = Depth,
        @CurrentPath   = Path
      FROM #Queue
     WHERE Taken = 0
     ORDER BY Qid

    UPDATE #Queue
       SET Taken = 1
     WHERE Qid = @Qid

    SELECT
        @CurrentSchema = SchemaName,
        @CurrentView   = ViewName
      FROM #ViewList
     WHERE ObjectId = @CurrentId

    IF @CurrentDepth >= 20
    BEGIN
        SET @HitMaxWalkDepth = 1
        CONTINUE
    END

    DELETE FROM #Kids

    INSERT #Kids (ReferencedId, SchemaName, ViewName, Taken)
    SELECT
        d.ReferencedId,
        v.SchemaName,
        v.ViewName,
        0
      FROM #CatalogViewDeps AS d
     INNER JOIN #CatalogViews AS v
        ON v.ObjectId = d.ReferencedId
     WHERE d.ReferencingId = @CurrentId

    WHILE EXISTS (SELECT 1 FROM #Kids WHERE Taken = 0)
    BEGIN
        SELECT TOP (1)
            @KidId     = KidId,
            @RefId     = ReferencedId,
            @RefSchema = SchemaName,
            @RefView   = ViewName
          FROM #Kids
         WHERE Taken = 0
         ORDER BY KidId

        UPDATE #Kids
           SET Taken = 1
         WHERE KidId = @KidId

        SET @IsCycle = CASE
                           WHEN CHARINDEX('/' + CONVERT(varchar(11), @RefId) + '/', @CurrentPath) > 0
                           THEN 1
                           ELSE 0
                       END

        SET @Already = CASE
                           WHEN EXISTS (SELECT 1 FROM #ViewList WHERE ObjectId = @RefId)
                           THEN 1
                           ELSE 0
                       END

        INSERT #ViewTree (Depth, SchemaName, ViewName, ReferencedBy, ObjectId)
        VALUES
        (
            @CurrentDepth + 1,
            @RefSchema,
            @RefView,
            QUOTENAME(@CurrentSchema) + N'.' + QUOTENAME(@CurrentView),
            @RefId
        )

        IF @IsCycle = 1
        BEGIN
            SET @HasCircularReference = 1

            UPDATE #ViewList
               SET InCycle = 1
             WHERE ObjectId IN (@CurrentId, @RefId)

            INSERT #CycleEdges (FromName, ToName)
            VALUES
            (
                QUOTENAME(@CurrentSchema) + N'.' + QUOTENAME(@CurrentView),
                QUOTENAME(@RefSchema) + N'.' + QUOTENAME(@RefView)
            )
        END
        ELSE IF @Already = 0
        BEGIN
            INSERT #ViewList
            (
                ObjectId, SchemaName, ViewName, IsRoot, MinDepth, InCycle, IsEncrypted,
                Definition, Body, ReplacedCount
            )
            VALUES
            (
                @RefId, @RefSchema, @RefView, 0, @CurrentDepth + 1, 0, 0,
                NULL, NULL, 0
            )

            INSERT #Queue (ObjectId, Depth, Path, Taken)
            VALUES
            (
                @RefId,
                @CurrentDepth + 1,
                @CurrentPath + CONVERT(varchar(11), @RefId) + '/',
                0
            )
        END
    END
END

SET @Sql = N'
UPDATE vl
   SET Definition  = m.definition,
       IsEncrypted = CASE WHEN m.definition IS NULL THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END
  FROM #ViewList AS vl
 INNER JOIN __TARGET_DB__.sys.sql_modules AS m
    ON m.object_id = vl.ObjectId
'

SET @Sql = REPLACE(@Sql, N'__TARGET_DB__', @QuotedDatabase)

EXEC sys.sp_executesql @Sql

SET @Sql = N'
INSERT #BaseTables (SchemaName, TableName)
SELECT DISTINCT
    s.name,
    t.name
  FROM __TARGET_DB__.sys.sql_expression_dependencies AS d
 INNER JOIN __TARGET_DB__.sys.tables AS t
    ON t.object_id = d.referenced_id
 INNER JOIN __TARGET_DB__.sys.schemas AS s
    ON s.schema_id = t.schema_id
 INNER JOIN #ViewList AS vl
    ON vl.ObjectId = d.referencing_id
 WHERE d.referenced_class = 1
   AND d.referenced_id IS NOT NULL
   AND d.referenced_server_name IS NULL
   AND (d.referenced_database_name IS NULL OR d.referenced_database_name = @TargetDatabase)
   AND t.is_ms_shipped = 0
'

SET @Sql = REPLACE(@Sql, N'__TARGET_DB__', @QuotedDatabase)

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabase sysname',
    @TargetDatabase = @TargetDatabase

-- Strip CREATE VIEW ... AS (and optional WITH CHECK OPTION) to get the inlinable body.
SET @Oid = NULL

WHILE EXISTS (
    SELECT 1
      FROM #ViewList
     WHERE Body IS NULL
       AND IsEncrypted = 0
       AND Definition IS NOT NULL
       AND (@Oid IS NULL OR ObjectId > @Oid)
)
BEGIN
    SELECT TOP (1)
        @Oid = ObjectId,
        @Def = Definition
      FROM #ViewList
     WHERE Body IS NULL
       AND IsEncrypted = 0
       AND Definition IS NOT NULL
       AND (@Oid IS NULL OR ObjectId > @Oid)
     ORDER BY ObjectId

    SET @Body       = NULL
    SET @Phase      = 0
    SET @i          = 1
    SET @n          = DATALENGTH(@Def) / 2
    SET @ParenDepth = 0

    IF @n >= 1 AND UNICODE(SUBSTRING(@Def, 1, 1)) = 0xFEFF
        SET @i = 2

    WHILE @i <= @n AND @Phase < 6
    BEGIN
        SET @c  = SUBSTRING(@Def, @i, 1)
        SET @c2 = SUBSTRING(@Def, @i, 2)

        IF @c IN (N' ', NCHAR(9), NCHAR(10), NCHAR(13))
        BEGIN
            SET @i = @i + 1
            CONTINUE
        END

        IF @c2 = N'--'
        BEGIN
            SET @i = @i + 2
            WHILE @i <= @n AND SUBSTRING(@Def, @i, 1) NOT IN (NCHAR(10), NCHAR(13))
                SET @i = @i + 1
            CONTINUE
        END

        IF @c2 = N'/*'
        BEGIN
            SET @i = @i + 2
            WHILE @i < @n AND SUBSTRING(@Def, @i, 2) <> N'*/'
                SET @i = @i + 1
            SET @i = @i + 2
            CONTINUE
        END

        IF @Phase = 21
           AND @c = N'('
        BEGIN
            SET @ParenDepth = 1
            SET @i = @i + 1
            WHILE @i <= @n AND @ParenDepth > 0
            BEGIN
                SET @c  = SUBSTRING(@Def, @i, 1)
                SET @c2 = SUBSTRING(@Def, @i, 2)

                IF @c2 = N'--'
                BEGIN
                    SET @i = @i + 2
                    WHILE @i <= @n AND SUBSTRING(@Def, @i, 1) NOT IN (NCHAR(10), NCHAR(13))
                        SET @i = @i + 1
                    CONTINUE
                END

                IF @c2 = N'/*'
                BEGIN
                    SET @i = @i + 2
                    WHILE @i < @n AND SUBSTRING(@Def, @i, 2) <> N'*/'
                        SET @i = @i + 1
                    SET @i = @i + 2
                    CONTINUE
                END

                IF @c = N''''
                BEGIN
                    SET @i = @i + 1
                    WHILE @i <= @n
                    BEGIN
                        IF SUBSTRING(@Def, @i, 2) = N''''''
                            SET @i = @i + 2
                        ELSE IF SUBSTRING(@Def, @i, 1) = N''''
                        BEGIN
                            SET @i = @i + 1
                            BREAK
                        END
                        ELSE
                            SET @i = @i + 1
                    END
                    CONTINUE
                END

                IF @c = N'['
                BEGIN
                    SET @i = @i + 1
                    WHILE @i <= @n
                    BEGIN
                        IF SUBSTRING(@Def, @i, 2) = N']]'
                            SET @i = @i + 2
                        ELSE IF SUBSTRING(@Def, @i, 1) = N']'
                        BEGIN
                            SET @i = @i + 1
                            BREAK
                        END
                        ELSE
                            SET @i = @i + 1
                    END
                    CONTINUE
                END

                IF @c = N'('
                    SET @ParenDepth = @ParenDepth + 1
                ELSE IF @c = N')'
                    SET @ParenDepth = @ParenDepth - 1

                SET @i = @i + 1
            END
            SET @Phase = 4
            CONTINUE
        END

        SET @Tok     = N''
        SET @TokType = N'other'

        IF @c = N'['
        BEGIN
            SET @i = @i + 1
            WHILE @i <= @n
            BEGIN
                IF SUBSTRING(@Def, @i, 2) = N']]'
                BEGIN
                    SET @Tok = @Tok + N']'
                    SET @i = @i + 2
                END
                ELSE IF SUBSTRING(@Def, @i, 1) = N']'
                BEGIN
                    SET @i = @i + 1
                    BREAK
                END
                ELSE
                BEGIN
                    SET @Tok = @Tok + SUBSTRING(@Def, @i, 1)
                    SET @i = @i + 1
                END
            END
            SET @TokType = N'ident'
        END
        ELSE IF @c = N'.'
        BEGIN
            SET @Tok     = N'.'
            SET @TokType = N'dot'
            SET @i       = @i + 1
        END
        ELSE IF @c = N','
        BEGIN
            SET @Tok     = N','
            SET @TokType = N'comma'
            SET @i       = @i + 1
        END
        ELSE IF @c LIKE N'[A-Za-z_@#]'
        BEGIN
            WHILE @i <= @n AND SUBSTRING(@Def, @i, 1) LIKE N'[A-Za-z0-9_@#$]'
            BEGIN
                SET @Tok = @Tok + SUBSTRING(@Def, @i, 1)
                SET @i = @i + 1
            END
            SET @TokType = N'ident'
        END
        ELSE
        BEGIN
            SET @Tok = @c
            SET @i   = @i + 1
        END

        IF @Phase = 0
        BEGIN
            IF @TokType = N'ident' AND UPPER(@Tok) = N'CREATE'
                SET @Phase = 1
        END
        ELSE IF @Phase = 1
        BEGIN
            IF @TokType = N'ident' AND UPPER(@Tok) IN (N'OR', N'ALTER')
                SET @Phase = 1
            ELSE IF @TokType = N'ident' AND UPPER(@Tok) = N'VIEW'
                SET @Phase = 2
            ELSE
                SET @Phase = 9
        END
        ELSE IF @Phase = 2
        BEGIN
            IF @TokType = N'ident'
                SET @Phase = 21
            ELSE
                SET @Phase = 9
        END
        ELSE IF @Phase = 21
        BEGIN
            IF @TokType = N'dot'
                SET @Phase = 22
            ELSE IF @TokType = N'ident' AND UPPER(@Tok) = N'WITH'
                SET @Phase = 4
            ELSE IF @TokType = N'ident' AND UPPER(@Tok) = N'AS'
                SET @Phase = 6
            ELSE
                SET @Phase = 9
        END
        ELSE IF @Phase = 22
        BEGIN
            IF @TokType = N'ident'
                SET @Phase = 21
            ELSE
                SET @Phase = 9
        END
        ELSE IF @Phase = 4
        BEGIN
            IF @TokType = N'ident' AND UPPER(@Tok) = N'WITH'
                SET @Phase = 4
            ELSE IF @TokType = N'ident' AND UPPER(@Tok) IN (N'SCHEMABINDING', N'ENCRYPTION', N'VIEW_METADATA')
                SET @Phase = 4
            ELSE IF @TokType = N'comma'
                SET @Phase = 4
            ELSE IF @TokType = N'ident' AND UPPER(@Tok) = N'AS'
                SET @Phase = 6
            ELSE
                SET @Phase = 9
        END
    END

    IF @Phase = 6 AND @i <= @n
        SET @Body = SUBSTRING(@Def, @i, @n - @i + 1)
    ELSE
        SET @Body = @Def

    WHILE DATALENGTH(@Body) >= 2
      AND UNICODE(SUBSTRING(@Body, DATALENGTH(@Body) / 2, 1)) IN (9, 10, 13, 32, 59)
    BEGIN
        SET @Body = SUBSTRING(@Body, 1, DATALENGTH(@Body) / 2 - 1)
    END

    SET @Chk = PATINDEX(N'%WITH CHECK OPTION%', @Body COLLATE Latin1_General_CI_AS)
    IF @Chk > 0
    BEGIN
        SET @Tail = LTRIM(RTRIM(SUBSTRING(@Body, @Chk + 17, 40)))
        IF @Tail = N'' OR @Tail = N';'
            SET @Body = SUBSTRING(@Body, 1, @Chk - 1)

        WHILE DATALENGTH(@Body) >= 2
          AND UNICODE(SUBSTRING(@Body, DATALENGTH(@Body) / 2, 1)) IN (9, 10, 13, 32, 59)
        BEGIN
            SET @Body = SUBSTRING(@Body, 1, DATALENGTH(@Body) / 2 - 1)
        END
    END

    UPDATE #ViewList
       SET Body = @Body
     WHERE ObjectId = @Oid
END

UPDATE #ViewList
   SET Body = NULL
 WHERE IsEncrypted = 1

-- Leaves-first, one pass. Deepest nested views first (MinDepth DESC, then name
-- length DESC). For each nested view v, replace references in every other view
-- body (including root). After v has been substituted into a host, leftover
-- mentions become [ViewName]; do not paste v.Body again. Never UPPER() the
-- full nvarchar(max). Then ExpandedSql is the root Body.
INSERT #ExpandOrder (ObjectId, Taken)
SELECT
    ObjectId,
    0
  FROM #ViewList
 WHERE IsRoot = 0
   AND Body IS NOT NULL
   AND InCycle = 0

WHILE EXISTS (SELECT 1 FROM #ExpandOrder WHERE Taken = 0)
  AND @HitSizeCap = 0
  AND @HitReplacementCap = 0
BEGIN
    SELECT TOP (1)
        @Oid           = v.ObjectId,
        @CurrentSchema = v.SchemaName,
        @CurrentView   = v.ViewName,
        @Body          = v.Body
      FROM #ExpandOrder AS e
     INNER JOIN #ViewList AS v
        ON v.ObjectId = e.ObjectId
     WHERE e.Taken = 0
     ORDER BY v.MinDepth DESC,
              LEN(v.SchemaName) + LEN(v.ViewName) DESC,
              LEN(v.ViewName) DESC,
              v.ObjectId

    UPDATE #ExpandOrder
       SET Taken = 1
     WHERE ObjectId = @Oid

    IF @Body IS NULL
        CONTINUE

    IF DATALENGTH(@Body) > @MaxBodyBytes
    BEGIN
        SET @HitSizeCap = 1
        CONTINUE
    END

    SET @IsUnambiguous = CASE
                             WHEN (
                                 SELECT COUNT(*)
                                   FROM #ViewList AS x
                                  WHERE x.ViewName = @CurrentView
                             ) = 1
                             THEN 1
                             ELSE 0
                         END

    SET @Inline = N'(' + @Body + N') AS ' + QUOTENAME(@CurrentView)
    SET @Alias  = QUOTENAME(@CurrentView)

    IF DATALENGTH(@Inline) > @MaxBodyBytes
    BEGIN
        SET @HitSizeCap = 1
        CONTINUE
    END

    DELETE FROM #Needles

    INSERT #Needles (Needle, Taken)
    VALUES (QUOTENAME(@CurrentSchema) + N'.' + QUOTENAME(@CurrentView), 0)

    INSERT #Needles (Needle, Taken)
    VALUES (@CurrentSchema + N'.' + QUOTENAME(@CurrentView), 0)

    INSERT #Needles (Needle, Taken)
    VALUES (QUOTENAME(@CurrentSchema) + N'.' + @CurrentView, 0)

    INSERT #Needles (Needle, Taken)
    VALUES (@CurrentSchema + N'.' + @CurrentView, 0)

    IF @IsUnambiguous = 1
        INSERT #Needles (Needle, Taken)
        VALUES (QUOTENAME(@CurrentView), 0)

    SET @HostId = 0

    WHILE EXISTS (
            SELECT 1
              FROM #ViewList
             WHERE ObjectId <> @Oid
               AND Body IS NOT NULL
               AND ObjectId > @HostId
          )
      AND @HitSizeCap = 0
      AND @HitReplacementCap = 0
    BEGIN
        SELECT TOP (1)
            @HostId   = ObjectId,
            @HostBody = Body
          FROM #ViewList
         WHERE ObjectId <> @Oid
           AND Body IS NOT NULL
           AND ObjectId > @HostId
         ORDER BY ObjectId

        IF DATALENGTH(@HostBody) > @MaxBodyBytes
        BEGIN
            SET @HitSizeCap = 1
            BREAK
        END

        SET @DidInline = 0

        UPDATE #Needles
           SET Taken = 0

        WHILE EXISTS (SELECT 1 FROM #Needles WHERE Taken = 0)
          AND @HitSizeCap = 0
          AND @HitReplacementCap = 0
        BEGIN
            SELECT TOP (1)
                @KidId  = NeedleId,
                @Needle = Needle
              FROM #Needles
             WHERE Taken = 0
             ORDER BY NeedleId

            UPDATE #Needles
               SET Taken = 1
             WHERE NeedleId = @KidId

            SET @NeedleLen = DATALENGTH(@Needle) / 2
            IF @NeedleLen IS NULL OR @NeedleLen = 0
                CONTINUE

            SET @SearchFrom = 1

            WHILE 1 = 1
            BEGIN
                IF @HitSizeCap = 1 OR @HitReplacementCap = 1
                    BREAK

                SET @Found = CHARINDEX(@Needle, @HostBody COLLATE Latin1_General_CI_AS, @SearchFrom)
                IF @Found IS NULL OR @Found = 0
                    BREAK

                SET @Before = CASE
                                  WHEN @Found = 1 THEN N' '
                                  ELSE SUBSTRING(@HostBody, @Found - 1, 1)
                              END
                SET @After = SUBSTRING(@HostBody, @Found + @NeedleLen, 1)

                SET @IsIdentBefore = CASE
                                         WHEN @Before LIKE N'[A-Za-z0-9_@#$]' THEN 1
                                         ELSE 0
                                     END
                SET @IsIdentAfter = CASE
                                        WHEN @After LIKE N'[A-Za-z0-9_@#$]' THEN 1
                                        ELSE 0
                                    END

                SET @SkipThis = CASE
                                    WHEN @IsIdentBefore = 1 OR @IsIdentAfter = 1 THEN 1
                                    ELSE 0
                                END

                -- Skip already-inlined aliases (AS [ViewName]) and [ViewName].col.
                IF @SkipThis = 0
                   AND @Needle COLLATE Latin1_General_CI_AS = @Alias COLLATE Latin1_General_CI_AS
                BEGIN
                    IF @After = N'.'
                        SET @SkipThis = 1

                    SET @k = @Found - 1
                    WHILE @k >= 1 AND SUBSTRING(@HostBody, @k, 1) IN (N' ', NCHAR(9), NCHAR(10), NCHAR(13))
                        SET @k = @k - 1

                    IF @k >= 2
                       AND SUBSTRING(@HostBody, @k - 1, 2) COLLATE Latin1_General_CI_AS = N'AS'
                       AND (
                                @k = 2
                             OR SUBSTRING(@HostBody, @k - 2, 1) NOT LIKE N'[A-Za-z0-9_]'
                           )
                        SET @SkipThis = 1
                END

                IF @SkipThis = 1
                BEGIN
                    SET @SearchFrom = @Found + 1
                    CONTINUE
                END

                -- schema.view.column is not a table source; skip until substituted.
                IF @DidInline = 0
                   AND @After = N'.'
                   AND CHARINDEX(N'.', @Needle) > 0
                BEGIN
                    SET @SearchFrom = @Found + 1
                    CONTINUE
                END

                -- First table-source match in this host: (v.Body) AS [ViewName].
                -- After that, leftover mentions become just [ViewName].
                IF @DidInline = 1
                    SET @Replacement = @Alias
                ELSE
                BEGIN
                    SET @Replacement = @Inline
                    SET @DidInline = 1

                    UPDATE #ViewList
                       SET ReplacedCount = ReplacedCount + 1
                     WHERE ObjectId = @Oid
                END

                SET @ReplLen = DATALENGTH(@Replacement) / 2
                SET @HostBody = STUFF(@HostBody, @Found, @NeedleLen, @Replacement)
                SET @TotalReplacements = @TotalReplacements + 1
                SET @SearchFrom = @Found + @ReplLen

                IF DATALENGTH(@HostBody) > @MaxBodyBytes
                    SET @HitSizeCap = 1

                IF @TotalReplacements >= @MaxReplacements
                    SET @HitReplacementCap = 1
            END
        END

        UPDATE #ViewList
           SET Body = @HostBody
         WHERE ObjectId = @HostId
    END
END

SELECT @RootBody = Body
  FROM #ViewList
 WHERE IsRoot = 1

SET @ExpandedSql = @RootBody

IF @ExpandedSql IS NOT NULL
   AND DATALENGTH(@ExpandedSql) > @MaxBodyBytes
    SET @HitSizeCap = 1


-- Nested views that were not safely inlined.
SET @Oid = NULL

WHILE EXISTS (
    SELECT 1
      FROM #ViewList
     WHERE IsRoot = 0
       AND (@Oid IS NULL OR ObjectId > @Oid)
)
BEGIN
    SELECT TOP (1)
        @Oid           = ObjectId,
        @CurrentSchema = SchemaName,
        @CurrentView   = ViewName,
        @InCycle       = InCycle,
        @IsEncrypted   = IsEncrypted,
        @Body          = Body,
        @DidInline     = CASE WHEN ReplacedCount > 0 THEN 1 ELSE 0 END
      FROM #ViewList
     WHERE IsRoot = 0
       AND (@Oid IS NULL OR ObjectId > @Oid)
     ORDER BY ObjectId

    SET @Reason       = NULL
    SET @StillPresent = 0

    IF @ExpandedSql IS NOT NULL
    BEGIN
        IF CHARINDEX(QUOTENAME(@CurrentSchema) + N'.' + QUOTENAME(@CurrentView), @ExpandedSql COLLATE Latin1_General_CI_AS) > 0
           OR CHARINDEX(@CurrentSchema + N'.' + @CurrentView, @ExpandedSql COLLATE Latin1_General_CI_AS) > 0
            SET @StillPresent = 1
        ELSE IF @DidInline = 0
            AND CHARINDEX(QUOTENAME(@CurrentView), @ExpandedSql COLLATE Latin1_General_CI_AS) > 0
            SET @StillPresent = 1
    END

    IF @IsEncrypted = 1 OR @Body IS NULL
        SET @Reason = N'Encrypted or missing module definition'
    ELSE IF @InCycle = 1
        SET @Reason = N'Circular reference'
    ELSE IF @DidInline = 0 AND @StillPresent = 1
        SET @Reason = N'Reference could not be replaced safely'
    ELSE IF @StillPresent = 1
        SET @Reason = N'Partial expansion; a two-part name remains'
    ELSE IF @HitSizeCap = 1 AND @DidInline = 0
        SET @Reason = N'Expansion truncated (size cap)'
    ELSE IF @HitReplacementCap = 1 AND @DidInline = 0
        SET @Reason = N'Expansion truncated (replacement cap)'

    IF @Reason IS NOT NULL
        INSERT #Unexpanded (SchemaName, ViewName, Reason)
        VALUES (@CurrentSchema, @CurrentView, @Reason)
END

SELECT @NestedViewCount = COUNT(*)
  FROM #ViewList
 WHERE IsRoot = 0

SELECT @MaxDepth = MAX(Depth)
  FROM #ViewTree

SET @MaxDepth = ISNULL(@MaxDepth, 0)

SET @CycleList = N''
SELECT @CycleList = @CycleList + CASE WHEN @CycleList = N'' THEN N'' ELSE N'; ' END
                 + FromName + N' -> ' + ToName
  FROM #CycleEdges

SET @Note = N'Decoded ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ViewName)
          + N' in database ' + QUOTENAME(@TargetDatabase) + N'.'

IF @NestedViewCount = 0
    SET @Note = @Note + N' No nested views were found.'
ELSE
    SET @Note = @Note + N' Nested view count: '
              + CONVERT(varchar(11), @NestedViewCount) + N'.'

IF @HasCircularReference = 1
    SET @Note = @Note + N' Circular reference(s) were detected and those views were not inlined'
              + CASE WHEN @CycleList = N'' THEN N'.' ELSE N': ' + @CycleList + N'.' END

IF @HitMaxWalkDepth = 1
    SET @Note = @Note + N' Stopped at max walk depth 20.'

IF @HitSizeCap = 1
    SET @Note = @Note + N' Expansion was truncated because the SQL exceeded 8 MB.'

IF @HitReplacementCap = 1
    SET @Note = @Note + N' Expansion was truncated after 2000 replacements.'

IF EXISTS (SELECT 1 FROM #Unexpanded)
    SET @Note = @Note + N' One or more views remain in Unexpanded.'

SET @Note = @Note + N' Expanded SQL is not executed. Base tables are left as names. User tables were not scanned.'

IF @ReturnResultSets = 1
BEGIN
    SELECT
        DatabaseName         = @TargetDatabase,
        RootView             = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ViewName),
        NestedViewCount      = @NestedViewCount,
        MaxDepth             = @MaxDepth,
        HasCircularReference = @HasCircularReference,
        Note                 = @Note

    SELECT
        Depth,
        SchemaName,
        ViewName,
        ReferencedBy,
        ObjectId
      FROM #ViewTree
     ORDER BY Depth, TreeId

    SELECT
        SchemaName,
        ViewName,
        Definition
      FROM #ViewList
     ORDER BY IsRoot DESC, SchemaName, ViewName

    SELECT ExpandedSql = @ExpandedSql

    SELECT BaseTable = QUOTENAME(SchemaName) + N'.' + QUOTENAME(TableName)
      FROM #BaseTables
     ORDER BY SchemaName, TableName

    SELECT
        SchemaName,
        ViewName,
        Reason
      FROM #Unexpanded
     ORDER BY SchemaName, ViewName
END

GO
