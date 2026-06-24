
/*
  ShowHeaps.sql
  Performance Tuning Framework

  Requires SQL Server 2008 (10.x) or later on the instance.
  Target database compatibility level 100+ (SQL Server 2008 mode).
  Supports newer instances (for example SQL Server 2022) examining older-compat databases.

  Deploy to the tool database, then execute:
    EXEC dbo.ShowHeaps @TargetDatabase = N'YourDatabase'

  Analyzes user-table heaps via DMVs and recommends a clustered index per table.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowHeaps') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowHeaps'
    DROP PROCEDURE dbo.ShowHeaps
END
GO

PRINT 'Creating: ShowHeaps'
GO

CREATE PROCEDURE dbo.ShowHeaps
(
    @TargetDatabase   sysname      = NULL,
    @SchemaFilter     sysname      = '%',
    @TableFilter      sysname      = '%',
    @MinPageCount     int          = 100,
    @TopN             int          = 100,
    @SortBy           varchar(10)  = 'SCORE',
    @ReturnResultSets bit          = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 23, 2026
-- Author:       Bill McEvoy
-- Description:  Identifies heap tables in a target database, analyzes DMV usage patterns and
--               missing-index signals, and recommends a strong clustered index for each heap.
--               Version-aware: instance version controls ONLINE index DDL; target compatibility
--               level controls database catalog and index-type logic.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion        tinyint,
    @TargetCompatMajor   tinyint,
    @EngineEdition       int,
    @CompatibilityLevel  int,
    @ServerName          sysname,
    @TargetDatabaseId    int,
    @QuotedDatabase      nvarchar(260),
    @Sql                 nvarchar(max),
    @ClusteredTypeFilter nvarchar(40),
    @IndexWithOptions    nvarchar(200),
    @IndexWithOptionsNC  nvarchar(200),
    @HeuristicTypeOrder  nvarchar(max),
    @SparseFilter        nvarchar(100),
    @SortByUpper         varchar(10),
    @HeapCount           int,
    @HighPriority        int,
    @CaptureDate         datetime

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)
SET @QuotedDatabase   = QUOTENAME(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

IF @TopN < 1
    SET @TopN = 100

IF @MinPageCount < 0
    SET @MinPageCount = 0

SET @SortByUpper = UPPER(ISNULL(@SortBy, 'SCORE'))
IF @SortByUpper NOT IN ('SCORE', 'SIZE', 'SCANS', 'UPDATES', 'IMPACT', 'OBJECT')
    SET @SortByUpper = 'SCORE'

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 10
BEGIN
    RAISERROR('ShowHeaps requires SQL Server 2008 (10.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SELECT @CompatibilityLevel = d.compatibility_level
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId

IF ISNULL(@CompatibilityLevel, 0) < 100
BEGIN
    RAISERROR('Target database ''%s'' compatibility level %d is below 100 (SQL Server 2008).', 16, 1, @TargetDatabase, @CompatibilityLevel)
    RETURN
END

SET @TargetCompatMajor = CONVERT(tinyint, @CompatibilityLevel / 10)

SET @EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS int)
SET @ServerName    = CAST(SERVERPROPERTY('MachineName') AS sysname)
                     + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @CaptureDate   = GETDATE()

-- Target database compatibility drives catalog/index-type behavior.
IF @CompatibilityLevel >= 110
    SET @ClusteredTypeFilter = N'ci.type IN (1, 5)'
ELSE
    SET @ClusteredTypeFilter = N'ci.type = 1'

-- Instance edition/version drives whether ONLINE rebuild is offered in suggested DDL.
IF @MajorVersion >= 10 AND @EngineEdition IN (3, 5)
    SET @IndexWithOptions = N'ONLINE = ON, SORT_IN_TEMPDB = ON'
ELSE
    SET @IndexWithOptions = N'SORT_IN_TEMPDB = ON'

SET @IndexWithOptionsNC = @IndexWithOptions

IF @CompatibilityLevel >= 100
BEGIN
    SET @SparseFilter = N'AND c.is_sparse = 0'
    SET @HeuristicTypeOrder = N'
                          WHEN ''date'' THEN 5
                          WHEN ''datetime'' THEN 6
                          WHEN ''datetime2'' THEN 7'
END
ELSE
BEGIN
    SET @SparseFilter = N''
    SET @HeuristicTypeOrder = N'
                          WHEN ''datetime'' THEN 6'
END

IF OBJECT_ID('tempdb..#HeapAnalysis') IS NOT NULL
    DROP TABLE #HeapAnalysis

CREATE TABLE #HeapAnalysis
(
    SortKey                   decimal(18, 4) NOT NULL,
    SchemaName                sysname        NOT NULL,
    TableName                 sysname        NOT NULL,
    ObjectID                  int            NOT NULL,
    RecordCount               bigint         NOT NULL,
    PageCount                 bigint         NOT NULL,
    SizeMB                    decimal(12, 1) NOT NULL,
    HeapSeeks                 bigint         NOT NULL,
    HeapScans                 bigint         NOT NULL,
    HeapLookups               bigint         NOT NULL,
    HeapUpdates               bigint         NOT NULL,
    TotalHeapReads            bigint         NOT NULL,
    ForwardedRecordCount      bigint         NOT NULL,
    AvgFragmentationPct       decimal(8, 2)  NOT NULL,
    NonClusteredIndexCount    int            NOT NULL,
    MissingIndexImpact        decimal(18, 4) NULL,
    MissingIndexEqualityCols  nvarchar(2000) NULL,
    MissingIndexInequalityCols nvarchar(2000) NULL,
    MissingIndexIncludedCols  nvarchar(2000) NULL,
    PrimaryKeyColumns         nvarchar(2000) NULL,
    PrimaryKeyIsUnique        bit            NOT NULL,
    TopNcIndexName            sysname        NULL,
    TopNcKeyColumns           nvarchar(2000) NULL,
    TopNcTotalReads           bigint         NOT NULL,
    IdentityColumn            sysname        NULL,
    SuggestionSource          varchar(30)    NOT NULL,
    SuggestedKeyColumns       nvarchar(2000) NOT NULL,
    RecommendationScore       int            NOT NULL,
    RecommendationRationale   nvarchar(2000) NOT NULL,
    SuggestedClusteredDdl     nvarchar(max)  NOT NULL,
    SuggestedNonClusteredDdl  nvarchar(max)  NULL
)

SET @Sql = N'
;WITH HeapTables AS
(
    SELECT
        s.name AS SchemaName,
        o.name AS TableName,
        o.object_id AS ObjectID
      FROM ' + @QuotedDatabase + N'.sys.objects AS o
     INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
        ON s.schema_id = o.schema_id
     WHERE o.type = ''U''
       AND s.name LIKE @SchemaFilter
       AND o.name LIKE @TableFilter
       AND EXISTS (
           SELECT 1
             FROM ' + @QuotedDatabase + N'.sys.indexes AS hi
            WHERE hi.object_id = o.object_id
              AND hi.index_id = 0
       )
       AND NOT EXISTS (
           SELECT 1
             FROM ' + @QuotedDatabase + N'.sys.indexes AS ci
            WHERE ci.object_id = o.object_id
              AND ci.index_id > 0
              AND ' + @ClusteredTypeFilter + N'
       )
),
HeapPhysical AS
(
    SELECT
        ips.object_id,
        RecordCount = SUM(ips.record_count),
        PageCount = SUM(ips.page_count),
        SizeMB = SUM(ips.page_count) * 8.0 / 1024.0,
        ForwardedRecordCount = SUM(ISNULL(ips.forwarded_record_count, 0)),
        AvgFragmentationPct = MAX(ips.avg_fragmentation_in_percent)
      FROM ' + @QuotedDatabase + N'.sys.dm_db_index_physical_stats(@TargetDatabaseId, NULL, NULL, NULL, ''LIMITED'') AS ips
     INNER JOIN HeapTables AS ht
        ON ht.ObjectID = ips.object_id
     WHERE ips.index_id = 0
     GROUP BY ips.object_id
),
HeapUsage AS
(
    SELECT
        us.object_id,
        HeapSeeks = ISNULL(us.user_seeks, 0),
        HeapScans = ISNULL(us.user_scans, 0),
        HeapLookups = ISNULL(us.user_lookups, 0),
        HeapUpdates = ISNULL(us.user_updates, 0),
        TotalHeapReads = ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0)
      FROM sys.dm_db_index_usage_stats AS us
     INNER JOIN HeapTables AS ht
        ON ht.ObjectID = us.object_id
     WHERE us.database_id = @TargetDatabaseId
       AND us.index_id = 0
),
NcIndexCounts AS
(
    SELECT
        i.object_id,
        NonClusteredIndexCount = COUNT(*)
      FROM ' + @QuotedDatabase + N'.sys.indexes AS i
     INNER JOIN HeapTables AS ht
        ON ht.ObjectID = i.object_id
     WHERE i.index_id > 0
       AND i.type = 2
       AND i.is_hypothetical = 0
     GROUP BY i.object_id
),
PrimaryKeyColumns AS
(
    SELECT
        i.object_id,
        PrimaryKeyIsUnique = i.is_unique,
        PrimaryKeyColumns = STUFF((
            SELECT '', '' + QUOTENAME(c.name)
              FROM ' + @QuotedDatabase + N'.sys.index_columns AS ic
             INNER JOIN ' + @QuotedDatabase + N'.sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
             WHERE ic.object_id = i.object_id
               AND ic.index_id = i.index_id
               AND ic.is_included_column = 0
               AND ic.key_ordinal > 0
             ORDER BY ic.key_ordinal
             FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 2, '''')
      FROM ' + @QuotedDatabase + N'.sys.indexes AS i
     INNER JOIN HeapTables AS ht
        ON ht.ObjectID = i.object_id
     WHERE i.is_primary_key = 1
),
TopNcIndex AS
(
    SELECT
        x.object_id,
        x.IndexName,
        x.TopNcKeyColumns,
        x.TopNcTotalReads
      FROM (
          SELECT
              i.object_id,
              IndexName = i.name,
              TopNcTotalReads = ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0),
              TopNcKeyColumns = STUFF((
                  SELECT '', '' + QUOTENAME(c.name)
                        + CASE WHEN ic.is_descending_key = 1 THEN '' DESC'' ELSE '' ASC'' END
                    FROM ' + @QuotedDatabase + N'.sys.index_columns AS ic
                   INNER JOIN ' + @QuotedDatabase + N'.sys.columns AS c
                      ON c.object_id = ic.object_id
                     AND c.column_id = ic.column_id
                   WHERE ic.object_id = i.object_id
                     AND ic.index_id = i.index_id
                     AND ic.is_included_column = 0
                     AND ic.key_ordinal > 0
                   ORDER BY ic.key_ordinal
                   FOR XML PATH(''''), TYPE
              ).value(''.'', ''nvarchar(max)''), 1, 2, ''''),
              rn = ROW_NUMBER() OVER (
                  PARTITION BY i.object_id
                  ORDER BY ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) DESC,
                           i.index_id
              )
            FROM ' + @QuotedDatabase + N'.sys.indexes AS i
           INNER JOIN HeapTables AS ht
              ON ht.ObjectID = i.object_id
            LEFT JOIN sys.dm_db_index_usage_stats AS us
              ON us.database_id = @TargetDatabaseId
             AND us.object_id = i.object_id
             AND us.index_id = i.index_id
           WHERE i.index_id > 0
             AND i.type = 2
             AND i.is_hypothetical = 0
      ) AS x
     WHERE x.rn = 1
),
IdentityColumns AS
(
    SELECT
        c.object_id,
        IdentityColumn = MIN(c.name)
      FROM ' + @QuotedDatabase + N'.sys.columns AS c
     INNER JOIN HeapTables AS ht
        ON ht.ObjectID = c.object_id
     WHERE c.is_identity = 1
     GROUP BY c.object_id
),
MissingIndexBest AS
(
    SELECT
        x.object_id,
        x.MissingIndexImpact,
        x.MissingIndexEqualityCols,
        x.MissingIndexInequalityCols,
        x.MissingIndexIncludedCols
      FROM (
          SELECT
              mid.object_id,
              MissingIndexImpact = CAST(migs.avg_user_impact * (migs.user_seeks + migs.user_scans) AS decimal(18, 4)),
              MissingIndexEqualityCols = mid.equality_columns,
              MissingIndexInequalityCols = mid.inequality_columns,
              MissingIndexIncludedCols = mid.included_columns,
              rn = ROW_NUMBER() OVER (
                  PARTITION BY mid.object_id
                  ORDER BY migs.avg_user_impact * (migs.user_seeks + migs.user_scans) DESC
              )
            FROM ' + @QuotedDatabase + N'.sys.dm_db_missing_index_group_stats AS migs
           INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_groups AS mig
              ON mig.index_group_handle = migs.group_handle
           INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_details AS mid
              ON mid.index_group_handle = mig.index_group_handle
           INNER JOIN HeapTables AS ht
              ON ht.ObjectID = mid.object_id
           WHERE migs.avg_user_impact * (migs.user_seeks + migs.user_scans) > 0
      ) AS x
     WHERE x.rn = 1
),
HeuristicColumn AS
(
    SELECT
        x.object_id,
        HeuristicColumn = x.ColumnName
      FROM (
          SELECT
              c.object_id,
              c.name AS ColumnName,
              rn = ROW_NUMBER() OVER (
                  PARTITION BY c.object_id
                  ORDER BY
                      CASE t.name
                          WHEN ''tinyint'' THEN 1
                          WHEN ''smallint'' THEN 2
                          WHEN ''int'' THEN 3
                          WHEN ''bigint'' THEN 4' + @HeuristicTypeOrder + N'
                          ELSE 100
                      END,
                      c.column_id
              )
            FROM ' + @QuotedDatabase + N'.sys.columns AS c
           INNER JOIN HeapTables AS ht
              ON ht.ObjectID = c.object_id
           INNER JOIN ' + @QuotedDatabase + N'.sys.types AS t
              ON t.user_type_id = c.user_type_id
           WHERE c.is_computed = 0
             ' + @SparseFilter + N'
             AND t.name NOT IN (''text'', ''ntext'', ''image'', ''xml'', ''varchar'', ''nvarchar'', ''varbinary'')
      ) AS x
     WHERE x.rn = 1
),
Prepared AS
(
    SELECT
        ht.SchemaName,
        ht.TableName,
        ht.ObjectID,
        RecordCount = ISNULL(hp.RecordCount, 0),
        PageCount = ISNULL(hp.PageCount, 0),
        SizeMB = ISNULL(hp.SizeMB, 0),
        HeapSeeks = ISNULL(hu.HeapSeeks, 0),
        HeapScans = ISNULL(hu.HeapScans, 0),
        HeapLookups = ISNULL(hu.HeapLookups, 0),
        HeapUpdates = ISNULL(hu.HeapUpdates, 0),
        TotalHeapReads = ISNULL(hu.TotalHeapReads, 0),
        ForwardedRecordCount = ISNULL(hp.ForwardedRecordCount, 0),
        AvgFragmentationPct = ISNULL(hp.AvgFragmentationPct, 0),
        NonClusteredIndexCount = ISNULL(nc.NonClusteredIndexCount, 0),
        MissingIndexImpact = mi.MissingIndexImpact,
        MissingIndexEqualityCols = mi.MissingIndexEqualityCols,
        MissingIndexInequalityCols = mi.MissingIndexInequalityCols,
        MissingIndexIncludedCols = mi.MissingIndexIncludedCols,
        PrimaryKeyColumns = pk.PrimaryKeyColumns,
        PrimaryKeyIsUnique = ISNULL(pk.PrimaryKeyIsUnique, 0),
        TopNcIndexName = tnc.IndexName,
        TopNcKeyColumns = tnc.TopNcKeyColumns,
        TopNcTotalReads = ISNULL(tnc.TopNcTotalReads, 0),
        IdentityColumn = ic.IdentityColumn,
        HeuristicColumn = hc.HeuristicColumn,
        MissingIndexKeyColumns = NULLIF(LTRIM(RTRIM(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(mi.MissingIndexEqualityCols)), '''') IS NOT NULL
                     AND NULLIF(LTRIM(RTRIM(mi.MissingIndexInequalityCols)), '''') IS NOT NULL
                    THEN LTRIM(RTRIM(mi.MissingIndexEqualityCols)) + '', '' + LTRIM(RTRIM(mi.MissingIndexInequalityCols))
                WHEN NULLIF(LTRIM(RTRIM(mi.MissingIndexEqualityCols)), '''') IS NOT NULL
                    THEN LTRIM(RTRIM(mi.MissingIndexEqualityCols))
                ELSE LTRIM(RTRIM(mi.MissingIndexInequalityCols))
            END
        )), '''')
      FROM HeapTables AS ht
      LEFT JOIN HeapPhysical AS hp
        ON hp.object_id = ht.ObjectID
      LEFT JOIN HeapUsage AS hu
        ON hu.object_id = ht.ObjectID
      LEFT JOIN NcIndexCounts AS nc
        ON nc.object_id = ht.ObjectID
      LEFT JOIN PrimaryKeyColumns AS pk
        ON pk.object_id = ht.ObjectID
      LEFT JOIN TopNcIndex AS tnc
        ON tnc.object_id = ht.ObjectID
      LEFT JOIN IdentityColumns AS ic
        ON ic.object_id = ht.ObjectID
      LEFT JOIN MissingIndexBest AS mi
        ON mi.object_id = ht.ObjectID
      LEFT JOIN HeuristicColumn AS hc
        ON hc.object_id = ht.ObjectID
     WHERE ISNULL(hp.PageCount, 0) >= @MinPageCount
),
Scored AS
(
    SELECT
        p.*,
        SuggestionSource = CASE
            WHEN p.PrimaryKeyColumns IS NOT NULL THEN ''PRIMARY_KEY''
            WHEN p.MissingIndexKeyColumns IS NOT NULL AND ISNULL(p.MissingIndexImpact, 0) >= 10000 THEN ''MISSING_INDEX''
            WHEN p.TopNcKeyColumns IS NOT NULL AND p.TopNcTotalReads > 0 THEN ''NC_INDEX_USAGE''
            WHEN p.MissingIndexKeyColumns IS NOT NULL THEN ''MISSING_INDEX''
            WHEN p.IdentityColumn IS NOT NULL THEN ''IDENTITY''
            ELSE ''HEURISTIC''
        END,
        SuggestedKeyColumns = CASE
            WHEN p.PrimaryKeyColumns IS NOT NULL THEN p.PrimaryKeyColumns
            WHEN p.MissingIndexKeyColumns IS NOT NULL AND ISNULL(p.MissingIndexImpact, 0) >= 10000 THEN p.MissingIndexKeyColumns
            WHEN p.TopNcKeyColumns IS NOT NULL AND p.TopNcTotalReads > 0 THEN p.TopNcKeyColumns
            WHEN p.MissingIndexKeyColumns IS NOT NULL THEN p.MissingIndexKeyColumns
            WHEN p.IdentityColumn IS NOT NULL THEN QUOTENAME(p.IdentityColumn) + '' ASC''
            WHEN p.HeuristicColumn IS NOT NULL THEN QUOTENAME(p.HeuristicColumn) + '' ASC''
            ELSE ''/* review table columns manually */''
        END,
        RecommendationScore =
              CASE WHEN ISNULL(p.PageCount, 0) >= 10000 THEN 20 WHEN ISNULL(p.PageCount, 0) >= 1000 THEN 12 WHEN ISNULL(p.PageCount, 0) >= 100 THEN 6 ELSE 2 END
            + CASE WHEN ISNULL(p.HeapScans, 0) >= 10000 THEN 20 WHEN ISNULL(p.HeapScans, 0) >= 1000 THEN 12 WHEN ISNULL(p.HeapScans, 0) >= 100 THEN 6 ELSE 0 END
            + CASE WHEN ISNULL(p.ForwardedRecordCount, 0) > 0 THEN 15 ELSE 0 END
            + CASE WHEN ISNULL(p.NonClusteredIndexCount, 0) >= 3 THEN 10 WHEN ISNULL(p.NonClusteredIndexCount, 0) >= 1 THEN 5 ELSE 0 END
            + CASE WHEN ISNULL(p.MissingIndexImpact, 0) >= 1000000 THEN 20 WHEN ISNULL(p.MissingIndexImpact, 0) >= 100000 THEN 12 WHEN ISNULL(p.MissingIndexImpact, 0) >= 10000 THEN 6 ELSE 0 END
            + CASE WHEN p.PrimaryKeyColumns IS NOT NULL THEN 10 ELSE 0 END
            + CASE WHEN ISNULL(p.AvgFragmentationPct, 0) >= 30 THEN 5 ELSE 0 END
      FROM Prepared AS p
)
INSERT INTO #HeapAnalysis
(
    SortKey,
    SchemaName,
    TableName,
    ObjectID,
    RecordCount,
    PageCount,
    SizeMB,
    HeapSeeks,
    HeapScans,
    HeapLookups,
    HeapUpdates,
    TotalHeapReads,
    ForwardedRecordCount,
    AvgFragmentationPct,
    NonClusteredIndexCount,
    MissingIndexImpact,
    MissingIndexEqualityCols,
    MissingIndexInequalityCols,
    MissingIndexIncludedCols,
    PrimaryKeyColumns,
    PrimaryKeyIsUnique,
    TopNcIndexName,
    TopNcKeyColumns,
    TopNcTotalReads,
    IdentityColumn,
    SuggestionSource,
    SuggestedKeyColumns,
    RecommendationScore,
    RecommendationRationale,
    SuggestedClusteredDdl,
    SuggestedNonClusteredDdl
)
SELECT
    SortKey = CASE @SortByUpper
                  WHEN ''SIZE'' THEN CAST(s.SizeMB AS decimal(18, 4))
                  WHEN ''SCANS'' THEN CAST(s.HeapScans AS decimal(18, 4))
                  WHEN ''UPDATES'' THEN CAST(s.HeapUpdates AS decimal(18, 4))
                  WHEN ''IMPACT'' THEN ISNULL(s.MissingIndexImpact, 0)
                  WHEN ''OBJECT'' THEN CAST(CHECKSUM(s.SchemaName, s.TableName) AS decimal(18, 4))
                  ELSE CAST(s.RecommendationScore AS decimal(18, 4))
              END,
    s.SchemaName,
    s.TableName,
    s.ObjectID,
    s.RecordCount,
    s.PageCount,
    CAST(s.SizeMB AS decimal(12, 1)),
    s.HeapSeeks,
    s.HeapScans,
    s.HeapLookups,
    s.HeapUpdates,
    s.TotalHeapReads,
    s.ForwardedRecordCount,
    CAST(s.AvgFragmentationPct AS decimal(8, 2)),
    s.NonClusteredIndexCount,
    s.MissingIndexImpact,
    s.MissingIndexEqualityCols,
    s.MissingIndexInequalityCols,
    s.MissingIndexIncludedCols,
    s.PrimaryKeyColumns,
    s.PrimaryKeyIsUnique,
    s.TopNcIndexName,
    s.TopNcKeyColumns,
    s.TopNcTotalReads,
    s.IdentityColumn,
    s.SuggestionSource,
    s.SuggestedKeyColumns,
    s.RecommendationScore,
    RecommendationRationale =
          CASE s.SuggestionSource
              WHEN ''PRIMARY_KEY'' THEN ''Heap has a nonclustered primary key; clustering the PK columns removes RID lookups and stabilizes NC index leaf pointers.''
              WHEN ''MISSING_INDEX'' THEN ''Missing-index DMVs show sustained seek/scan patterns on these key columns (impact score '' + ISNULL(CAST(CAST(s.MissingIndexImpact AS bigint) AS varchar(20)), ''0'') + '').''
              WHEN ''NC_INDEX_USAGE'' THEN ''Most-used nonclustered index ['' + ISNULL(s.TopNcIndexName, ''?'') + ''] indicates lookup columns that are strong clustered-index candidates.''
              WHEN ''IDENTITY'' THEN ''No stronger DMV signal found; identity column provides a narrow, ever-increasing clustering key.''
              ELSE ''No PK, missing-index, or NC-usage signal; heuristic narrow key column selected for initial clustering.''
          END
        + CASE WHEN s.ForwardedRecordCount > 0 THEN '' Forwarded records ('' + CAST(s.ForwardedRecordCount AS varchar(20)) + '') indicate update pressure on this heap.'' ELSE '''' END
        + CASE WHEN s.NonClusteredIndexCount >= 3 THEN '' Multiple NC indexes on a heap amplify RID lookup and maintenance cost.'' ELSE '''' END
        + CASE
              WHEN s.PrimaryKeyColumns IS NOT NULL
               AND s.MissingIndexKeyColumns IS NOT NULL
               AND s.SuggestionSource = ''PRIMARY_KEY''
               AND s.MissingIndexKeyColumns <> s.PrimaryKeyColumns
                  THEN '' Additional missing-index signal suggests a separate nonclustered index (see SuggestedNonClusteredDdl).''
              ELSE ''''
          END,
    SuggestedClusteredDdl =
          CASE
              WHEN s.SuggestedKeyColumns LIKE ''/*%'' THEN ''-- Manual review required for '' + QUOTENAME(s.SchemaName) + ''.'' + QUOTENAME(s.TableName)
              WHEN s.PrimaryKeyColumns IS NOT NULL AND s.PrimaryKeyIsUnique = 1 THEN
                  ''CREATE UNIQUE CLUSTERED INDEX '' + QUOTENAME(''CX_'' + s.TableName)
                  + '' ON '' + QUOTENAME(s.SchemaName) + ''.'' + QUOTENAME(s.TableName)
                  + '' ('' + s.SuggestedKeyColumns + '') WITH ('' + @IndexWithOptions + '');''
              ELSE
                  ''CREATE CLUSTERED INDEX '' + QUOTENAME(''CX_'' + s.TableName)
                  + '' ON '' + QUOTENAME(s.SchemaName) + ''.'' + QUOTENAME(s.TableName)
                  + '' ('' + s.SuggestedKeyColumns + '') WITH ('' + @IndexWithOptions + '', FILLFACTOR = 90);''
          END,
    SuggestedNonClusteredDdl =
          CASE
              WHEN s.MissingIndexKeyColumns IS NOT NULL
               AND (
                       s.SuggestionSource <> ''MISSING_INDEX''
                    OR s.PrimaryKeyColumns IS NOT NULL
                   )
               AND s.MissingIndexKeyColumns <> ISNULL(s.SuggestedKeyColumns, '''')
                  THEN ''CREATE NONCLUSTERED INDEX '' + QUOTENAME(''IX_'' + s.TableName + ''_MissingSignal'')
                     + '' ON '' + QUOTENAME(s.SchemaName) + ''.'' + QUOTENAME(s.TableName)
                     + '' ('' + s.MissingIndexKeyColumns + '')''
                     + CASE
                           WHEN NULLIF(LTRIM(RTRIM(s.MissingIndexIncludedCols)), '''') IS NOT NULL
                               THEN '' INCLUDE ('' + s.MissingIndexIncludedCols + '')''
                           ELSE ''''
                       END
                     + '' WITH ('' + @IndexWithOptionsNC + '');''
              ELSE NULL
          END
  FROM Scored AS s'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int,
      @SchemaFilter sysname,
      @TableFilter sysname,
      @MinPageCount int,
      @SortByUpper varchar(10),
      @IndexWithOptions nvarchar(200),
      @IndexWithOptionsNC nvarchar(200)',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @MinPageCount = @MinPageCount,
    @SortByUpper = @SortByUpper,
    @IndexWithOptions = @IndexWithOptions,
    @IndexWithOptionsNC = @IndexWithOptionsNC

SELECT
    @HeapCount = COUNT(*),
    @HighPriority = SUM(CASE WHEN RecommendationScore >= 50 THEN 1 ELSE 0 END)
  FROM #HeapAnalysis

IF @ReturnResultSets = 1
BEGIN
    SELECT
        CaptureDate = @CaptureDate,
        ServerName = @ServerName,
        DatabaseName = @TargetDatabase,
        HeapTableCount = @HeapCount,
        HighPriorityCount = @HighPriority,
        SchemaFilter = @SchemaFilter,
        TableFilter = @TableFilter,
        MinPageCount = @MinPageCount,
        TopN = @TopN,
        SortBy = @SortByUpper,
        SqlInstanceMajorVersion = @MajorVersion,
        TargetCompatibilityLevel = @CompatibilityLevel,
        TargetCompatMajorVersion = @TargetCompatMajor,
        IndexWithOptions = @IndexWithOptions,
        Note = 'Instance and target compatibility differ by design when a newer SQL Server hosts an older-compat database. Analysis uses target compatibility level; ONLINE DDL option uses instance edition. Usage stats are since instance restart.'

    SELECT TOP (@TopN)
        SchemaName,
        TableName,
        RecordCount,
        PageCount,
        SizeMB,
        HeapSeeks,
        HeapScans,
        HeapLookups,
        HeapUpdates,
        TotalHeapReads,
        ForwardedRecordCount,
        AvgFragmentationPct,
        NonClusteredIndexCount,
        MissingIndexImpact,
        MissingIndexEqualityCols,
        MissingIndexInequalityCols,
        MissingIndexIncludedCols,
        PrimaryKeyColumns,
        TopNcIndexName,
        TopNcKeyColumns,
        TopNcTotalReads,
        IdentityColumn,
        SuggestionSource,
        SuggestedKeyColumns,
        RecommendationScore,
        RecommendationRationale,
        SuggestedClusteredDdl,
        SuggestedNonClusteredDdl
      FROM #HeapAnalysis
     ORDER BY SortKey DESC, SchemaName, TableName
END

GO

IF OBJECT_ID('dbo.ShowHeaps') IS NOT NULL
    PRINT 'Procedure created.'
ELSE
    PRINT 'Procedure NOT created.'
GO