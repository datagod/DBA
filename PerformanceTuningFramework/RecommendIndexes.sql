/*
  RecommendIndexes.sql
  Performance Tuning Framework

  Deploy to the tool database after IndexAnalysis.sql and AnalyzeIndexes.sql, then execute:
    EXEC dbo.AnalyzeIndexes @TargetDatabase = N'YourDatabase'
    EXEC dbo.RecommendIndexes @TargetDatabase = N'YourDatabase'

  Optional parameters:
    @TargetDatabase        - database analyzed (default: current database)
    @AnalysisRunID         - specific capture run (default: latest for @TargetDatabase)
    @SchemaFilter          - schema name filter (default '%')
    @TableFilter           - table name filter (default '%')
    @MinSizeMB             - minimum index size for DROP recommendations (default 1)
    @MinUpdatesForUnused   - minimum writes on unused indexes to recommend DROP (default 10)
    @MinHeapActivity       - minimum heap reads+writes to recommend clustered index (default 100)
    @TopN                  - maximum recommendations returned (default 100)
    @IncludeMissingIndexes - include live missing-index DMV recommendations (default 1)
    @ReturnResultSets      - return summary, analysis, and recommendation result sets (default 1)

  The recommendations result set includes RecordCount (estimated rows in the index at capture time).

  DROP_DUPLICATE / DROP_REDUNDANT compare nonclustered, non-unique, non-PK indexes
  on the same table and the same filter (or both unfiltered). Exact key + include
  match is DROP_DUPLICATE. A left-prefix key, or the same key with a proper include
  subset, is DROP_REDUNDANT when the inferior includes are covered by the superior
  keys and includes. Unique and clustered indexes are never drop candidates here.
  The kept index is the one with more reads, then larger size, then lower IndexID.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.RecommendIndexes
(
    @TargetDatabase        sysname           = NULL,
    @AnalysisRunID         uniqueidentifier  = NULL,
    @SchemaFilter          sysname           = '%',
    @TableFilter           sysname           = '%',
    @MinSizeMB             decimal(12, 1)    = 1,
    @MinUpdatesForUnused   bigint            = 10,
    @MinHeapActivity       bigint            = 100,
    @TopN                  int               = 100,
    @IncludeMissingIndexes bit               = 1,
    @ReturnResultSets      bit               = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: July 3, 2026
-- Author:       Bill McEvoy
-- Description:  Analyzes the latest IndexAnalysis capture for a target database, summarizes index
--               health findings, and returns prioritized index recommendations with actionable DDL.
--               Duplicate and redundant nonclustered indexes are ranked by usage, size, and key /
--               include / filter overlap. Unique and clustered indexes are not drop candidates.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion         tinyint,
    @EngineEdition        int,
    @CompatibilityLevel   int,
    @TargetDatabaseId     int,
    @QuotedDatabase       nvarchar(260),
    @ServerName           sysname,
    @CaptureDate          datetime,
    @Sql                  nvarchar(max),
    @IndexWithOptions     nvarchar(200),
    @IndexWithOptionsNC   nvarchar(200),
    @TotalIndexes         int,
    @HeapCount            int,
    @UnusedCount          int,
    @WriteHeavyCount      int,
    @DisabledCount        int,
    @NoStatsCount         int,
    @UnusedSizeMB         decimal(18, 1),
    @RecommendationCount  int,
    @HighPriorityCount    int,
    @AnalysisRunIDText    varchar(36)

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)
SET @QuotedDatabase   = QUOTENAME(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

IF OBJECT_ID('dbo.IndexAnalysis') IS NULL
BEGIN
    RAISERROR('Table dbo.IndexAnalysis does not exist. Run IndexAnalysis.sql in this database first.', 16, 1)
    RETURN
END

IF @MinSizeMB < 0
    SET @MinSizeMB = 0

IF @MinUpdatesForUnused < 1
    SET @MinUpdatesForUnused = 1

IF @MinHeapActivity < 1
    SET @MinHeapActivity = 1

IF @TopN < 1
    SET @TopN = 100

IF @AnalysisRunID IS NULL
BEGIN
    SELECT TOP (1)
        @AnalysisRunID = ia.AnalysisRunID,
        @CaptureDate   = ia.CaptureDate
      FROM dbo.IndexAnalysis AS ia
     WHERE ia.DatabaseName = @TargetDatabase
     ORDER BY ia.CaptureDate DESC, ia.AnalysisRunID DESC
END
ELSE
BEGIN
    SELECT TOP (1)
        @CaptureDate   = ia.CaptureDate,
        @TargetDatabase = ia.DatabaseName
      FROM dbo.IndexAnalysis AS ia
     WHERE ia.AnalysisRunID = @AnalysisRunID
END

IF @AnalysisRunID IS NULL
BEGIN
    RAISERROR('No IndexAnalysis data found for database ''%s''. Run dbo.AnalyzeIndexes first.', 16, 1, @TargetDatabase)
    RETURN
END

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS int)
SET @ServerName    = CAST(SERVERPROPERTY('MachineName') AS sysname)
                     + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')

SELECT @CompatibilityLevel = d.compatibility_level
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId

IF @MajorVersion >= 10 AND @EngineEdition IN (3, 5)
    SET @IndexWithOptions = N'ONLINE = ON, SORT_IN_TEMPDB = ON'
ELSE
    SET @IndexWithOptions = N'SORT_IN_TEMPDB = ON'

SET @IndexWithOptionsNC = @IndexWithOptions

IF OBJECT_ID('tempdb..#CapturedIndexes') IS NOT NULL
    DROP TABLE #CapturedIndexes

CREATE TABLE #CapturedIndexes
(
    SchemaName           sysname         NOT NULL,
    TableName            sysname         NOT NULL,
    IndexName            sysname         NULL,
    ObjectID             int             NOT NULL,
    IndexID              int             NOT NULL,
    IndexTypeDesc        nvarchar(60)    NOT NULL,
    UserSeeks            bigint          NOT NULL,
    UserScans            bigint          NOT NULL,
    UserLookups          bigint          NOT NULL,
    UserUpdates          bigint          NOT NULL,
    TotalReads           bigint          NOT NULL,
    ReadWriteRatio       decimal(18, 4)  NULL,
    RecordCount          bigint          NOT NULL,
    SizeMB               decimal(12, 1)  NOT NULL,
    IsDisabled           bit             NOT NULL,
    HasUsageStats        bit             NOT NULL,
    IsFiltered           bit             NOT NULL,
    IsUnique             bit             NOT NULL,
    IsPrimaryKey         bit             NOT NULL,
    KeyColumns            nvarchar(2000)  NULL,
    IncludedColumns       nvarchar(2000)  NULL,
    FilterDefinition      nvarchar(max)   NULL,
    NormalizedKeyColumns  nvarchar(2000)  NULL,
    NormalizedIncludeSet  nvarchar(2000)  NULL,
    NormalizedFilter      nvarchar(max)   NULL,
    ObjectDisplay         nvarchar(400)   NOT NULL
)

INSERT INTO #CapturedIndexes
(
    SchemaName,
    TableName,
    IndexName,
    ObjectID,
    IndexID,
    IndexTypeDesc,
    UserSeeks,
    UserScans,
    UserLookups,
    UserUpdates,
    TotalReads,
    ReadWriteRatio,
    RecordCount,
    SizeMB,
    IsDisabled,
    HasUsageStats,
    IsFiltered,
    IsUnique,
    IsPrimaryKey,
    KeyColumns,
    IncludedColumns,
    FilterDefinition,
    NormalizedKeyColumns,
    NormalizedIncludeSet,
    NormalizedFilter,
    ObjectDisplay
)
SELECT
    ia.SchemaName,
    ia.TableName,
    ia.IndexName,
    ia.ObjectID,
    ia.IndexID,
    ia.IndexTypeDesc,
    ia.UserSeeks,
    ia.UserScans,
    ia.UserLookups,
    ia.UserUpdates,
    ia.TotalReads,
    ia.ReadWriteRatio,
    ia.RecordCount,
    ia.SizeMB,
    ia.IsDisabled,
    ia.HasUsageStats,
    ia.IsFiltered,
    ia.IsUnique,
    ia.IsPrimaryKey,
    ia.KeyColumns,
    ia.IncludedColumns,
    ia.FilterDefinition,
    NormalizedKeyColumns = LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(ia.KeyColumns, N''), N'[', N''), N']', N''), N' ASC', N''), N' DESC', N''), N' ', N'')),
    NormalizedIncludeSet = NULL,
    NormalizedFilter = LOWER(LTRIM(RTRIM(ISNULL(ia.FilterDefinition, N'')))),
    ObjectDisplay = ia.SchemaName + N'.' + ia.TableName
                  + N' [' + CASE
                                WHEN ia.IndexID = 0 THEN N'HEAP'
                                WHEN ia.IndexName IS NULL THEN N'unnamed'
                                ELSE ia.IndexName
                            END + N']'
  FROM dbo.IndexAnalysis AS ia
 WHERE ia.AnalysisRunID = @AnalysisRunID
   AND ia.DatabaseName = @TargetDatabase
   AND ia.SchemaName LIKE @SchemaFilter
   AND ia.TableName LIKE @TableFilter

IF NOT EXISTS (SELECT 1 FROM #CapturedIndexes)
BEGIN
    SET @AnalysisRunIDText = CONVERT(varchar(36), @AnalysisRunID)
    RAISERROR('No IndexAnalysis rows found for run %s in database ''%s'' with the current filters.', 16, 1, @AnalysisRunIDText, @TargetDatabase)
    RETURN
END

UPDATE ci
   SET NormalizedIncludeSet = ISNULL(sorted.IncludeSet, N'')
  FROM #CapturedIndexes AS ci
 OUTER APPLY
 (
    SELECT IncludeSet = STUFF((
        SELECT N',' + d.Col
          FROM (
                SELECT CAST(N'<i>' + REPLACE(
                           LOWER(REPLACE(REPLACE(ISNULL(ci.IncludedColumns, N''), N'[', N''), N']', N'')),
                           N',',
                           N'</i><i>'
                       ) + N'</i>' AS xml) AS x
               ) AS t
         CROSS APPLY t.x.nodes('/i') AS n(c)
         CROSS APPLY (SELECT Col = LTRIM(RTRIM(n.c.value(N'.', N'nvarchar(128)')))) AS d
         WHERE d.Col <> N''
         ORDER BY d.Col
           FOR XML PATH(N''), TYPE
    ).value(N'.', N'nvarchar(2000)'), 1, 1, N'')
 ) AS sorted

SELECT
    @TotalIndexes    = COUNT(*),
    @HeapCount       = SUM(CASE WHEN IndexID = 0 THEN 1 ELSE 0 END),
    @UnusedCount     = SUM(CASE WHEN IndexID > 0 AND TotalReads = 0 AND UserUpdates >= @MinUpdatesForUnused THEN 1 ELSE 0 END),
    @WriteHeavyCount = SUM(CASE WHEN IndexID > 0 AND TotalReads > 0 AND UserUpdates > (TotalReads * 10) THEN 1 ELSE 0 END),
    @DisabledCount   = SUM(CASE WHEN IsDisabled = 1 THEN 1 ELSE 0 END),
    @NoStatsCount    = SUM(CASE WHEN HasUsageStats = 0 THEN 1 ELSE 0 END),
    @UnusedSizeMB    = SUM(CASE WHEN IndexID > 0 AND TotalReads = 0 AND UserUpdates >= @MinUpdatesForUnused THEN SizeMB ELSE 0 END)
  FROM #CapturedIndexes

IF OBJECT_ID('tempdb..#TableRowCounts') IS NOT NULL
    DROP TABLE #TableRowCounts

CREATE TABLE #TableRowCounts
(
    ObjectID          int    NOT NULL PRIMARY KEY,
    TableRecordCount  bigint NOT NULL
)

INSERT INTO #TableRowCounts
(
    ObjectID,
    TableRecordCount
)
SELECT
    ci.ObjectID,
    TableRecordCount = MAX(ci.RecordCount)
  FROM #CapturedIndexes AS ci
 GROUP BY ci.ObjectID

IF OBJECT_ID('tempdb..#Recommendations') IS NOT NULL
    DROP TABLE #Recommendations

CREATE TABLE #Recommendations
(
    PriorityScore      int             NOT NULL,
    Severity           tinyint         NOT NULL,
    RecommendationType varchar(30)     NOT NULL,
    SchemaName         sysname         NOT NULL,
    TableName          sysname         NOT NULL,
    IndexName          sysname         NULL,
    ObjectDisplay      nvarchar(400)   NOT NULL,
    RelatedObject      nvarchar(400)   NULL,
    FindingDetail      nvarchar(max)   NOT NULL,
    Rationale          nvarchar(max)   NOT NULL,
    SuggestedDdl       nvarchar(max)   NULL,
    MetricNumeric      decimal(18, 4)  NOT NULL,
    RecordCount        bigint          NOT NULL
)

----------------------------------------------------------------------------------------------------
-- DROP unused nonclustered indexes (reads = 0, maintenance writes > 0)
----------------------------------------------------------------------------------------------------
INSERT INTO #Recommendations
(
    PriorityScore,
    Severity,
    RecommendationType,
    SchemaName,
    TableName,
    IndexName,
    ObjectDisplay,
    RelatedObject,
    FindingDetail,
    Rationale,
    SuggestedDdl,
    MetricNumeric,
    RecordCount
)
SELECT
    PriorityScore = CAST(
        CASE WHEN ci.SizeMB >= 1000 THEN 40 WHEN ci.SizeMB >= 100 THEN 30 WHEN ci.SizeMB >= 10 THEN 20 ELSE 10 END
        + CASE WHEN ci.UserUpdates >= 100000 THEN 30 WHEN ci.UserUpdates >= 10000 THEN 20 WHEN ci.UserUpdates >= 1000 THEN 10 ELSE 5 END
    AS int),
    Severity = CASE
                   WHEN ci.UserUpdates >= 10000 OR ci.SizeMB >= 100 THEN 3
                   WHEN ci.UserUpdates >= 1000 OR ci.SizeMB >= 10 THEN 2
                   ELSE 1
               END,
    RecommendationType = 'DROP_UNUSED',
    ci.SchemaName,
    ci.TableName,
    ci.IndexName,
    ci.ObjectDisplay,
    RelatedObject = NULL,
    FindingDetail = N'Index has zero reads and ' + CAST(ci.UserUpdates AS nvarchar(20)) + N' updates since the last instance restart.'
                  + N' Size=' + CAST(ci.SizeMB AS nvarchar(20)) + N' MB'
                  + N', KeyColumns=' + ISNULL(ci.KeyColumns, N'(none)')
                  + CASE WHEN ci.IncludedColumns IS NOT NULL THEN N', Includes=' + ci.IncludedColumns ELSE N'' END,
    Rationale = N'Nonclustered indexes that receive maintenance writes without supporting read activity increase INSERT/UPDATE/DELETE cost and consume storage.',
    SuggestedDdl = N'DROP INDEX ' + QUOTENAME(ci.IndexName) + N' ON ' + QUOTENAME(ci.SchemaName) + N'.' + QUOTENAME(ci.TableName) + N';',
    MetricNumeric = CAST(ci.UserUpdates AS decimal(18, 4)),
    ci.RecordCount
  FROM #CapturedIndexes AS ci
 WHERE ci.IndexID > 0
   AND ci.IndexTypeDesc = 'NONCLUSTERED'
   AND ci.IsPrimaryKey = 0
   AND ci.IsUnique = 0
   AND ci.IsDisabled = 0
   AND ci.TotalReads = 0
   AND ci.UserUpdates >= @MinUpdatesForUnused
   AND ci.SizeMB >= @MinSizeMB

----------------------------------------------------------------------------------------------------
-- Disabled indexes: enable when used, drop when unused but maintained
----------------------------------------------------------------------------------------------------
INSERT INTO #Recommendations
(
    PriorityScore,
    Severity,
    RecommendationType,
    SchemaName,
    TableName,
    IndexName,
    ObjectDisplay,
    RelatedObject,
    FindingDetail,
    Rationale,
    SuggestedDdl,
    MetricNumeric,
    RecordCount
)
SELECT
    PriorityScore = CASE
                        WHEN ci.TotalReads > 0 THEN 35
                        WHEN ci.UserUpdates >= 1000 THEN 25
                        ELSE 10
                    END,
    Severity = CASE
                   WHEN ci.TotalReads > 0 THEN 3
                   WHEN ci.UserUpdates >= 1000 THEN 2
                   ELSE 1
               END,
    RecommendationType = CASE WHEN ci.TotalReads > 0 THEN 'ENABLE_INDEX' ELSE 'DROP_DISABLED' END,
    ci.SchemaName,
    ci.TableName,
    ci.IndexName,
    ci.ObjectDisplay,
    RelatedObject = NULL,
    FindingDetail = N'Disabled index. Reads=' + CAST(ci.TotalReads AS nvarchar(20))
                  + N', Updates=' + CAST(ci.UserUpdates AS nvarchar(20))
                  + N', Size=' + CAST(ci.SizeMB AS nvarchar(20)) + N' MB.',
    Rationale = CASE
                    WHEN ci.TotalReads > 0
                        THEN N'Index is disabled but still shows read activity in the capture. Re-enable it or confirm the disable was intentional.'
                    WHEN ci.UserUpdates > 0
                        THEN N'Disabled index continues to incur maintenance overhead on data changes without providing an access path.'
                    ELSE N'Disabled index has no captured activity. Remove it if it is no longer required.'
                END,
    SuggestedDdl = CASE
                       WHEN ci.TotalReads > 0 AND ci.IndexName IS NOT NULL
                           THEN N'ALTER INDEX ' + QUOTENAME(ci.IndexName)
                              + N' ON ' + QUOTENAME(ci.SchemaName) + N'.' + QUOTENAME(ci.TableName)
                              + N' REBUILD WITH (' + @IndexWithOptions + N');'
                       WHEN ci.IndexName IS NOT NULL
                           THEN N'DROP INDEX ' + QUOTENAME(ci.IndexName)
                              + N' ON ' + QUOTENAME(ci.SchemaName) + N'.' + QUOTENAME(ci.TableName) + N';'
                       ELSE NULL
                   END,
    MetricNumeric = CAST(ISNULL(ci.UserUpdates, 0) + ISNULL(ci.TotalReads, 0) AS decimal(18, 4)),
    ci.RecordCount
  FROM #CapturedIndexes AS ci
 WHERE ci.IndexID > 0
   AND ci.IsDisabled = 1
   AND (
           ci.TotalReads > 0
        OR ci.UserUpdates >= @MinUpdatesForUnused
       )

----------------------------------------------------------------------------------------------------
-- Write-heavy indexes (high update cost relative to reads)
----------------------------------------------------------------------------------------------------
INSERT INTO #Recommendations
(
    PriorityScore,
    Severity,
    RecommendationType,
    SchemaName,
    TableName,
    IndexName,
    ObjectDisplay,
    RelatedObject,
    FindingDetail,
    Rationale,
    SuggestedDdl,
    MetricNumeric,
    RecordCount
)
SELECT
    PriorityScore = CAST(
        CASE WHEN ci.UserUpdates >= 100000 THEN 25 WHEN ci.UserUpdates >= 10000 THEN 18 ELSE 12 END
        + CASE WHEN ci.ReadWriteRatio IS NOT NULL AND ci.ReadWriteRatio < 0.01 THEN 15
               WHEN ci.ReadWriteRatio IS NOT NULL AND ci.ReadWriteRatio < 0.1 THEN 8
               ELSE 0
          END
    AS int),
    Severity = CASE
                   WHEN ci.UserUpdates >= 100000 AND ISNULL(ci.ReadWriteRatio, 0) < 0.05 THEN 3
                   WHEN ci.UserUpdates >= 10000 THEN 2
                   ELSE 1
               END,
    RecommendationType = 'REVIEW_WRITE_HEAVY',
    ci.SchemaName,
    ci.TableName,
    ci.IndexName,
    ci.ObjectDisplay,
    RelatedObject = NULL,
    FindingDetail = N'Reads=' + CAST(ci.TotalReads AS nvarchar(20))
                  + N', Updates=' + CAST(ci.UserUpdates AS nvarchar(20))
                  + N', Read/Write ratio=' + ISNULL(CONVERT(nvarchar(32), ci.ReadWriteRatio), N'n/a')
                  + N', Size=' + CAST(ci.SizeMB AS nvarchar(20)) + N' MB.',
    Rationale = N'Index maintenance cost is high relative to read benefit. Validate whether the index is still required, can be narrowed, or should be replaced with a more selective design.',
    SuggestedDdl = N'-- Review index usage and consider DROP or redesign:' + CHAR(13) + CHAR(10)
                 + N'-- DROP INDEX ' + QUOTENAME(ISNULL(ci.IndexName, N'<index>')) + N' ON '
                 + QUOTENAME(ci.SchemaName) + N'.' + QUOTENAME(ci.TableName) + N';',
    MetricNumeric = CAST(ci.UserUpdates AS decimal(18, 4)),
    ci.RecordCount
  FROM #CapturedIndexes AS ci
 WHERE ci.IndexID > 0
   AND ci.IsDisabled = 0
   AND ci.TotalReads > 0
   AND ci.UserUpdates > (ci.TotalReads * 10)
   AND ci.SizeMB >= @MinSizeMB

----------------------------------------------------------------------------------------------------
-- Redundant / duplicate nonclustered indexes (keys, includes, and filter)
----------------------------------------------------------------------------------------------------
;WITH Eligible AS
(
    SELECT
        ci.SchemaName,
        ci.TableName,
        ci.IndexName,
        ci.ObjectID,
        ci.IndexID,
        ci.KeyColumns,
        ci.IncludedColumns,
        ci.FilterDefinition,
        ci.NormalizedKeyColumns,
        ci.NormalizedIncludeSet,
        ci.NormalizedFilter,
        ci.TotalReads,
        ci.UserUpdates,
        ci.SizeMB,
        ci.RecordCount,
        ci.ObjectDisplay,
        CoverSet = N',' + ISNULL(ci.NormalizedKeyColumns, N'')
                 + CASE
                       WHEN NULLIF(ci.NormalizedIncludeSet, N'') IS NOT NULL
                           THEN N',' + ci.NormalizedIncludeSet
                       ELSE N''
                   END
                 + N','
      FROM #CapturedIndexes AS ci
     WHERE ci.IndexID > 0
       AND ci.IndexTypeDesc = 'NONCLUSTERED'
       AND ci.IsPrimaryKey = 0
       AND ci.IsUnique = 0
       AND ci.IsDisabled = 0
       AND ci.IndexName IS NOT NULL
       AND NULLIF(ci.NormalizedKeyColumns, N'') IS NOT NULL
),
Pairs AS
(
    SELECT
        inferior.SchemaName,
        inferior.TableName,
        inferior.IndexName,
        inferior.ObjectDisplay,
        inferior.KeyColumns,
        inferior.IncludedColumns,
        inferior.FilterDefinition,
        inferior.NormalizedKeyColumns,
        inferior.NormalizedIncludeSet,
        inferior.TotalReads,
        inferior.UserUpdates,
        inferior.SizeMB,
        inferior.RecordCount,
        SuperiorDisplay = superior.ObjectDisplay,
        SuperiorKeyColumns = superior.KeyColumns,
        SuperiorIncludedColumns = superior.IncludedColumns,
        SuperiorNormalizedKeyColumns = superior.NormalizedKeyColumns,
        SuperiorTotalReads = superior.TotalReads,
        MatchKind = CASE
                        WHEN inferior.NormalizedKeyColumns = superior.NormalizedKeyColumns
                         AND ISNULL(inferior.NormalizedIncludeSet, N'') = ISNULL(superior.NormalizedIncludeSet, N'')
                            THEN 'DUPLICATE'
                        ELSE 'REDUNDANT'
                    END,
        SuperiorRank = ROW_NUMBER() OVER (
            PARTITION BY inferior.ObjectID, inferior.IndexID
            ORDER BY superior.TotalReads DESC, superior.SizeMB DESC, superior.IndexID
        )
      FROM Eligible AS inferior
     INNER JOIN Eligible AS superior
        ON superior.ObjectID = inferior.ObjectID
       AND superior.IndexID <> inferior.IndexID
     WHERE ISNULL(inferior.NormalizedFilter, N'') = ISNULL(superior.NormalizedFilter, N'')
       AND (
               inferior.NormalizedKeyColumns = superior.NormalizedKeyColumns
            OR superior.NormalizedKeyColumns LIKE inferior.NormalizedKeyColumns + N',%'
           )
       AND (
               inferior.TotalReads < superior.TotalReads
            OR (
                   inferior.TotalReads = superior.TotalReads
               AND inferior.SizeMB < superior.SizeMB
               )
            OR (
                   inferior.TotalReads = superior.TotalReads
               AND inferior.SizeMB = superior.SizeMB
               AND inferior.IndexID > superior.IndexID
               )
           )
       AND NOT EXISTS (
               SELECT 1
                 FROM (
                        SELECT CAST(
                                   N'<i>' + REPLACE(ISNULL(inferior.NormalizedIncludeSet, N''), N',', N'</i><i>') + N'</i>'
                                   AS xml
                               ) AS x
                      ) AS t
                CROSS APPLY t.x.nodes('/i') AS n(c)
                CROSS APPLY (SELECT Col = LTRIM(RTRIM(n.c.value(N'.', N'nvarchar(128)')))) AS d
                WHERE d.Col <> N''
                  AND superior.CoverSet NOT LIKE N'%,' + d.Col + N',%'
           )
)
INSERT INTO #Recommendations
(
    PriorityScore,
    Severity,
    RecommendationType,
    SchemaName,
    TableName,
    IndexName,
    ObjectDisplay,
    RelatedObject,
    FindingDetail,
    Rationale,
    SuggestedDdl,
    MetricNumeric,
    RecordCount
)
SELECT
    PriorityScore = CAST(
        CASE WHEN p.MatchKind = 'DUPLICATE' THEN 30 ELSE 22 END
        + CASE WHEN p.SizeMB >= 100 THEN 10 WHEN p.SizeMB >= 10 THEN 5 ELSE 0 END
    AS int),
    Severity = CASE WHEN p.MatchKind = 'DUPLICATE' THEN 3 ELSE 2 END,
    RecommendationType = CASE WHEN p.MatchKind = 'DUPLICATE' THEN 'DROP_DUPLICATE' ELSE 'DROP_REDUNDANT' END,
    p.SchemaName,
    p.TableName,
    p.IndexName,
    p.ObjectDisplay,
    RelatedObject = p.SuperiorDisplay,
    FindingDetail = CASE
                        WHEN p.MatchKind = 'DUPLICATE'
                            THEN N'Exact duplicate keys and includes with inferior read activity.'
                        WHEN p.NormalizedKeyColumns = p.SuperiorNormalizedKeyColumns
                            THEN N'Same key columns; inferior includes are covered by the better-used index.'
                        ELSE N'Key columns are a left-prefix of a broader index with equal or better read activity.'
                    END
                  + N' Inferior reads=' + CAST(p.TotalReads AS nvarchar(20))
                  + N', Superior reads=' + CAST(p.SuperiorTotalReads AS nvarchar(20))
                  + N', Inferior key=' + ISNULL(p.KeyColumns, N'(none)')
                  + N', Superior key=' + ISNULL(p.SuperiorKeyColumns, N'(none)')
                  + N', Inferior includes=' + ISNULL(p.IncludedColumns, N'(none)')
                  + N', Superior includes=' + ISNULL(p.SuperiorIncludedColumns, N'(none)')
                  + N', Filter=' + ISNULL(NULLIF(p.FilterDefinition, N''), N'(none)'),
    Rationale = N'SQL Server can satisfy the inferior index access paths using the broader or better-used index, reducing storage and DML overhead. Unique and clustered indexes are left in place.',
    SuggestedDdl = N'DROP INDEX ' + QUOTENAME(p.IndexName) + N' ON '
                 + QUOTENAME(p.SchemaName) + N'.' + QUOTENAME(p.TableName) + N';',
    MetricNumeric = CAST(p.UserUpdates AS decimal(18, 4)),
    p.RecordCount
  FROM Pairs AS p
 WHERE p.SuperiorRank = 1

----------------------------------------------------------------------------------------------------
-- Active heaps: recommend clustered indexes from capture signals
----------------------------------------------------------------------------------------------------
;WITH PrimaryKeyIndexes AS
(
    SELECT
        ci.ObjectID,
        ci.KeyColumns,
        ROW_NUMBER() OVER (PARTITION BY ci.ObjectID ORDER BY ci.TotalReads DESC, ci.IndexID) AS RowNum
      FROM #CapturedIndexes AS ci
     WHERE ci.IsPrimaryKey = 1
       AND NULLIF(ci.KeyColumns, N'') IS NOT NULL
),
TopNcIndexes AS
(
    SELECT
        ci.ObjectID,
        ci.IndexName,
        ci.KeyColumns,
        ci.TotalReads,
        ROW_NUMBER() OVER (PARTITION BY ci.ObjectID ORDER BY ci.TotalReads DESC, ci.SizeMB DESC, ci.IndexID) AS RowNum
      FROM #CapturedIndexes AS ci
     WHERE ci.IndexTypeDesc = 'NONCLUSTERED'
       AND ci.IndexID > 0
       AND ci.IsDisabled = 0
       AND NULLIF(ci.KeyColumns, N'') IS NOT NULL
)
INSERT INTO #Recommendations
(
    PriorityScore,
    Severity,
    RecommendationType,
    SchemaName,
    TableName,
    IndexName,
    ObjectDisplay,
    RelatedObject,
    FindingDetail,
    Rationale,
    SuggestedDdl,
    MetricNumeric,
    RecordCount
)
SELECT
    PriorityScore = CAST(
        CASE WHEN heap.RecordCount >= 1000000 THEN 30 WHEN heap.RecordCount >= 100000 THEN 20 WHEN heap.RecordCount >= 10000 THEN 12 ELSE 6 END
        + CASE WHEN heap.TotalReads >= 100000 THEN 25 WHEN heap.TotalReads >= 10000 THEN 15 WHEN heap.TotalReads >= 1000 THEN 8 ELSE 0 END
        + CASE WHEN heap.UserUpdates >= 100000 THEN 15 WHEN heap.UserUpdates >= 10000 THEN 8 ELSE 0 END
    AS int),
    Severity = CASE
                   WHEN heap.TotalReads >= 10000 OR heap.RecordCount >= 100000 THEN 3
                   WHEN heap.TotalReads >= 1000 OR heap.RecordCount >= 10000 THEN 2
                   ELSE 1
               END,
    RecommendationType = 'CREATE_CLUSTERED',
    heap.SchemaName,
    heap.TableName,
    IndexName = NULL,
    heap.ObjectDisplay,
    RelatedObject = COALESCE(pk.KeyColumns, nc.IndexName, N'(manual review)'),
    FindingDetail = N'Heap activity: Reads=' + CAST(heap.TotalReads AS nvarchar(20))
                  + N', Updates=' + CAST(heap.UserUpdates AS nvarchar(20))
                  + N', Rows=' + CAST(heap.RecordCount AS nvarchar(20))
                  + N', Size=' + CAST(heap.SizeMB AS nvarchar(20)) + N' MB.',
    Rationale = CASE
                    WHEN pk.KeyColumns IS NOT NULL
                        THEN N'Table is a heap with a nonclustered primary key. Clustering the PK columns removes RID lookups and stabilizes nonclustered leaf pointers.'
                    WHEN nc.KeyColumns IS NOT NULL
                        THEN N'Table is a heap and the most-used nonclustered index [' + nc.IndexName + N'] indicates strong clustering key columns from workload patterns.'
                    ELSE N'Table is a heap with sustained activity. Select a narrow, selective clustering key after validating access patterns.'
                END,
    SuggestedDdl = CASE
                       WHEN COALESCE(pk.KeyColumns, nc.KeyColumns) IS NULL
                           THEN N'-- Manual review required for ' + QUOTENAME(heap.SchemaName) + N'.' + QUOTENAME(heap.TableName)
                       WHEN pk.KeyColumns IS NOT NULL
                           THEN N'CREATE UNIQUE CLUSTERED INDEX ' + QUOTENAME(N'CX_' + heap.TableName)
                              + N' ON ' + QUOTENAME(heap.SchemaName) + N'.' + QUOTENAME(heap.TableName)
                              + N' (' + pk.KeyColumns + N') WITH (' + @IndexWithOptions + N');'
                       ELSE N'CREATE CLUSTERED INDEX ' + QUOTENAME(N'CX_' + heap.TableName)
                          + N' ON ' + QUOTENAME(heap.SchemaName) + N'.' + QUOTENAME(heap.TableName)
                          + N' (' + nc.KeyColumns + N') WITH (' + @IndexWithOptions + N', FILLFACTOR = 90);'
                   END,
    MetricNumeric = CAST(heap.TotalReads + heap.UserUpdates AS decimal(18, 4)),
    heap.RecordCount
  FROM #CapturedIndexes AS heap
  LEFT JOIN PrimaryKeyIndexes AS pk
    ON pk.ObjectID = heap.ObjectID
   AND pk.RowNum = 1
  LEFT JOIN TopNcIndexes AS nc
    ON nc.ObjectID = heap.ObjectID
   AND nc.RowNum = 1
 WHERE heap.IndexID = 0
   AND (heap.TotalReads + heap.UserUpdates) >= @MinHeapActivity

----------------------------------------------------------------------------------------------------
-- Missing-index DMV recommendations (live workload signal)
----------------------------------------------------------------------------------------------------
IF @IncludeMissingIndexes = 1 AND @MajorVersion >= 10
BEGIN
    IF OBJECT_ID('tempdb..#MissingIndexes') IS NOT NULL
        DROP TABLE #MissingIndexes

    CREATE TABLE #MissingIndexes
    (
        SchemaName           sysname         NOT NULL,
        TableName            sysname         NOT NULL,
        ObjectID             int             NOT NULL,
        EqualityColumns      nvarchar(2000)  NULL,
        InequalityColumns    nvarchar(2000)  NULL,
        IncludedColumns      nvarchar(2000)  NULL,
        KeyColumns           nvarchar(2000)  NULL,
        NormalizedKeyColumns nvarchar(2000)  NULL,
        ImpactScore          decimal(18, 4)  NOT NULL,
        UserSeeks            bigint          NOT NULL,
        UserScans            bigint          NOT NULL,
        AvgUserImpact        decimal(12, 2)  NOT NULL,
        LastUserSeek         datetime        NULL
    )

    SET @Sql = N'
    INSERT INTO #MissingIndexes
    (
        SchemaName,
        TableName,
        ObjectID,
        EqualityColumns,
        InequalityColumns,
        IncludedColumns,
        KeyColumns,
        NormalizedKeyColumns,
        ImpactScore,
        UserSeeks,
        UserScans,
        AvgUserImpact,
        LastUserSeek
    )
    SELECT
        s.name,
        o.name,
        o.object_id,
        mid.equality_columns,
        mid.inequality_columns,
        mid.included_columns,
        KeyColumns = NULLIF(LTRIM(RTRIM(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(mid.equality_columns)), N'''') IS NOT NULL
                     AND NULLIF(LTRIM(RTRIM(mid.inequality_columns)), N'''') IS NOT NULL
                    THEN LTRIM(RTRIM(mid.equality_columns)) + N'', '' + LTRIM(RTRIM(mid.inequality_columns))
                WHEN NULLIF(LTRIM(RTRIM(mid.equality_columns)), N'''') IS NOT NULL
                    THEN LTRIM(RTRIM(mid.equality_columns))
                ELSE LTRIM(RTRIM(mid.inequality_columns))
            END
        )), N''''),
        NormalizedKeyColumns = LOWER(REPLACE(REPLACE(REPLACE(
            NULLIF(LTRIM(RTRIM(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(mid.equality_columns)), N'''') IS NOT NULL
                         AND NULLIF(LTRIM(RTRIM(mid.inequality_columns)), N'''') IS NOT NULL
                        THEN LTRIM(RTRIM(mid.equality_columns)) + N'', '' + LTRIM(RTRIM(mid.inequality_columns))
                    WHEN NULLIF(LTRIM(RTRIM(mid.equality_columns)), N'''') IS NOT NULL
                        THEN LTRIM(RTRIM(mid.equality_columns))
                    ELSE LTRIM(RTRIM(mid.inequality_columns))
                END
            )), N''''), N''['', N''''), N'']'', N''''), N'' '', N'''')),
        ImpactScore = CAST(migs.avg_user_impact * (migs.user_seeks + migs.user_scans) AS decimal(18, 4)),
        migs.user_seeks,
        migs.user_scans,
        migs.avg_user_impact,
        migs.last_user_seek
      FROM ' + @QuotedDatabase + N'.sys.dm_db_missing_index_group_stats AS migs
     INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_groups AS mig
        ON mig.index_group_handle = migs.group_handle
     INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_details AS mid
        ON mid.index_handle = mig.index_handle
     INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
        ON o.object_id = mid.object_id
     INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
        ON s.schema_id = o.schema_id
     WHERE o.type = N''U''
       AND s.name LIKE @SchemaFilter
       AND o.name LIKE @TableFilter
       AND migs.avg_user_impact * (migs.user_seeks + migs.user_scans) > 0'

    EXEC sys.sp_executesql
        @Sql,
        N'@SchemaFilter sysname, @TableFilter sysname',
        @SchemaFilter = @SchemaFilter,
        @TableFilter = @TableFilter

    INSERT INTO #Recommendations
    (
        PriorityScore,
        Severity,
        RecommendationType,
        SchemaName,
        TableName,
        IndexName,
        ObjectDisplay,
        RelatedObject,
        FindingDetail,
        Rationale,
        SuggestedDdl,
        MetricNumeric,
        RecordCount
    )
    SELECT
        PriorityScore = CAST(
            CASE WHEN mi.ImpactScore >= 1000000 THEN 45 WHEN mi.ImpactScore >= 100000 THEN 35 WHEN mi.ImpactScore >= 10000 THEN 25 ELSE 15 END
        AS int),
        Severity = CASE
                       WHEN mi.ImpactScore >= 1000000 THEN 3
                       WHEN mi.ImpactScore >= 100000 THEN 2
                       ELSE 1
                   END,
        RecommendationType = 'CREATE_NONCLUSTERED',
        mi.SchemaName,
        mi.TableName,
        IndexName = NULL,
        ObjectDisplay = mi.SchemaName + N'.' + mi.TableName + N' [missing-index signal]',
        RelatedObject = NULL,
        FindingDetail = N'Equality=' + ISNULL(mi.EqualityColumns, N'')
                      + N', Inequality=' + ISNULL(mi.InequalityColumns, N'')
                      + N', Include=' + ISNULL(mi.IncludedColumns, N'')
                      + N', ImpactScore=' + CAST(mi.ImpactScore AS nvarchar(20))
                      + N', Seeks=' + CAST(mi.UserSeeks AS nvarchar(20))
                      + N', Scans=' + CAST(mi.UserScans AS nvarchar(20))
                      + N', AvgImpactPct=' + CAST(mi.AvgUserImpact AS nvarchar(20)),
        Rationale = N'Missing-index DMVs report sustained seek/scan patterns that may benefit from a supporting nonclustered index.',
        SuggestedDdl = N'CREATE NONCLUSTERED INDEX ' + QUOTENAME(N'IX_' + mi.TableName + N'_MissingSignal')
                     + N' ON ' + QUOTENAME(mi.SchemaName) + N'.' + QUOTENAME(mi.TableName)
                     + N' (' + mi.KeyColumns + N')'
                     + CASE
                           WHEN NULLIF(LTRIM(RTRIM(mi.IncludedColumns)), N'') IS NOT NULL
                               THEN N' INCLUDE (' + mi.IncludedColumns + N')'
                           ELSE N''
                       END
                     + N' WITH (' + @IndexWithOptionsNC + N');',
        MetricNumeric = mi.ImpactScore,
        RecordCount = ISNULL(tr.TableRecordCount, 0)
      FROM #MissingIndexes AS mi
      LEFT JOIN #TableRowCounts AS tr
        ON tr.ObjectID = mi.ObjectID
     WHERE NULLIF(mi.KeyColumns, N'') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
             FROM #CapturedIndexes AS ci
            WHERE ci.ObjectID = mi.ObjectID
              AND ci.IndexID > 0
              AND ci.IsDisabled = 0
              AND (
                      ci.NormalizedKeyColumns = mi.NormalizedKeyColumns
                   OR ci.NormalizedKeyColumns LIKE mi.NormalizedKeyColumns + N',%'
                   OR mi.NormalizedKeyColumns LIKE ci.NormalizedKeyColumns + N',%'
                  )
       )
END

SELECT
    @RecommendationCount = COUNT(*),
    @HighPriorityCount   = SUM(CASE WHEN Severity >= 3 THEN 1 ELSE 0 END)
  FROM #Recommendations

IF @ReturnResultSets = 1
BEGIN
    SELECT
        AnalysisRunID          = @AnalysisRunID,
        CaptureDate            = @CaptureDate,
        ServerName             = @ServerName,
        DatabaseName           = @TargetDatabase,
        SchemaFilter           = @SchemaFilter,
        TableFilter            = @TableFilter,
        TotalIndexesCaptured   = @TotalIndexes,
        HeapCount              = @HeapCount,
        UnusedIndexCount       = @UnusedCount,
        WriteHeavyIndexCount   = @WriteHeavyCount,
        DisabledIndexCount     = @DisabledCount,
        NoUsageStatsCount      = @NoStatsCount,
        UnusedIndexSizeMB      = @UnusedSizeMB,
        RecommendationCount    = @RecommendationCount,
        HighPriorityCount      = @HighPriorityCount,
        SqlInstanceMajorVersion = @MajorVersion,
        TargetCompatibilityLevel = @CompatibilityLevel,
        Note = 'Analysis is based on the selected IndexAnalysis capture. Usage stats are since the last instance restart. Missing-index recommendations use current DMV data when enabled.'

    SELECT
        AnalysisCategory = v.AnalysisCategory,
        FindingCount     = v.FindingCount,
        TotalSizeMB      = v.TotalSizeMB,
        TotalReads       = v.TotalReads,
        TotalUpdates     = v.TotalUpdates,
        CategorySummary  = v.CategorySummary
      FROM (
            SELECT
                AnalysisCategory = 'Heap tables',
                FindingCount     = COUNT(*),
                TotalSizeMB      = SUM(ci.SizeMB),
                TotalReads       = SUM(ci.TotalReads),
                TotalUpdates     = SUM(ci.UserUpdates),
                CategorySummary  = 'Tables without a clustered index in the capture.'
              FROM #CapturedIndexes AS ci
             WHERE ci.IndexID = 0

            UNION ALL

            SELECT
                'Unused nonclustered indexes',
                COUNT(*),
                SUM(ci.SizeMB),
                SUM(ci.TotalReads),
                SUM(ci.UserUpdates),
                'NC indexes with zero reads and ongoing maintenance writes.'
              FROM #CapturedIndexes AS ci
             WHERE ci.IndexID > 0
               AND ci.IndexTypeDesc = 'NONCLUSTERED'
               AND ci.TotalReads = 0
               AND ci.UserUpdates >= @MinUpdatesForUnused

            UNION ALL

            SELECT
                'Write-heavy indexes',
                COUNT(*),
                SUM(ci.SizeMB),
                SUM(ci.TotalReads),
                SUM(ci.UserUpdates),
                'Indexes where updates exceed reads by more than 10x.'
              FROM #CapturedIndexes AS ci
             WHERE ci.IndexID > 0
               AND ci.TotalReads > 0
               AND ci.UserUpdates > (ci.TotalReads * 10)

            UNION ALL

            SELECT
                'Disabled indexes',
                COUNT(*),
                SUM(ci.SizeMB),
                SUM(ci.TotalReads),
                SUM(ci.UserUpdates),
                'Indexes currently disabled in the capture.'
              FROM #CapturedIndexes AS ci
             WHERE ci.IsDisabled = 1

            UNION ALL

            SELECT
                'No usage stats since restart',
                COUNT(*),
                SUM(ci.SizeMB),
                SUM(ci.TotalReads),
                SUM(ci.UserUpdates),
                'Indexes with no row in dm_db_index_usage_stats since the instance restarted.'
              FROM #CapturedIndexes AS ci
             WHERE ci.HasUsageStats = 0
           ) AS v
     WHERE v.FindingCount > 0
     ORDER BY v.FindingCount DESC, v.TotalSizeMB DESC

    SELECT TOP (@TopN)
        PriorityRank         = ROW_NUMBER() OVER (ORDER BY r.PriorityScore DESC, r.MetricNumeric DESC, r.ObjectDisplay),
        r.PriorityScore,
        r.Severity,
        SeverityLabel        = CASE r.Severity WHEN 3 THEN 'High' WHEN 2 THEN 'Medium' ELSE 'Low' END,
        r.RecommendationType,
        r.SchemaName,
        r.TableName,
        r.IndexName,
        r.ObjectDisplay,
        r.RelatedObject,
        r.FindingDetail,
        r.Rationale,
        r.SuggestedDdl,
        r.MetricNumeric,
        r.RecordCount
      FROM #Recommendations AS r
     ORDER BY
        r.PriorityScore DESC,
        r.MetricNumeric DESC,
        r.ObjectDisplay
END

GO

IF OBJECT_ID('dbo.RecommendIndexes') IS NOT NULL
    PRINT 'Procedure RecommendIndexes created.'
ELSE
    PRINT 'Procedure RecommendIndexes NOT created.'