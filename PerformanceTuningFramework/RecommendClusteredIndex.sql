
/*
  RecommendClusteredIndex.sql
  Performance Tuning Framework

  Requires SQL Server 2008 (10.x) or later on the instance.
  Target database compatibility level 100+ (SQL Server 2008 mode).

  Deploy to the tool database, then execute:
    EXEC dbo.RecommendClusteredIndex
         @TargetDatabase = N'YourDatabase',
         @SchemaName     = N'dbo',
         @TableName      = N'YourTable'
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.RecommendClusteredIndex') IS NOT NULL
BEGIN
    PRINT 'Dropping: RecommendClusteredIndex'
    DROP PROCEDURE dbo.RecommendClusteredIndex
END
GO

PRINT 'Creating: RecommendClusteredIndex'
GO

CREATE PROCEDURE dbo.RecommendClusteredIndex
(
    @TargetDatabase   sysname,
    @SchemaName       sysname = N'dbo',
    @TableName        sysname,
    @PreferIdentity   bit     = 1,
    @ReturnResultSets bit     = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 25, 2026
-- Author:       Bill McEvoy
-- Description:  Examines one user table and related DMVs to recommend a clustered index. Prioritizes
--               a single ascending identity column when available or when one can be added safely.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion        tinyint,
    @EngineEdition       int,
    @CompatibilityLevel  int,
    @ReportedCompatLevel int,
    @TargetDatabaseId    int,
    @QuotedDatabase      nvarchar(260),
    @Sql                 nvarchar(max),
    @ClusteredTypeFilter nvarchar(40),
    @IndexWithOptions    nvarchar(200),
    @IndexWithOptionsNC  nvarchar(200),
    @ServerName          sysname,
    @CaptureDate         datetime,
    @ProposedIdentityCol sysname,
    @ObjectId            int

IF @TargetDatabase IS NULL OR @TableName IS NULL
BEGIN
    RAISERROR('@TargetDatabase and @TableName are required.', 16, 1)
    RETURN
END

SET @TargetDatabaseId = DB_ID(@TargetDatabase)
SET @QuotedDatabase   = QUOTENAME(@TargetDatabase)
SET @ProposedIdentityCol = @TableName + N'ID'

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
    RAISERROR('RecommendClusteredIndex requires SQL Server 2008 (10.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
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

SET @EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS int)
SET @ServerName    = CAST(SERVERPROPERTY('MachineName') AS sysname)
                     + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @CaptureDate   = GETDATE()

IF @CompatibilityLevel >= 110
    SET @ClusteredTypeFilter = N'i.type IN (1, 5)'
ELSE
    SET @ClusteredTypeFilter = N'i.type = 1'

IF @MajorVersion >= 10 AND @EngineEdition IN (3, 5)
    SET @IndexWithOptions = N'ONLINE = ON, SORT_IN_TEMPDB = ON'
ELSE
    SET @IndexWithOptions = N'SORT_IN_TEMPDB = ON'

SET @IndexWithOptionsNC = @IndexWithOptions

IF OBJECT_ID('tempdb..#ClusteredRecommendation') IS NOT NULL
    DROP TABLE #ClusteredRecommendation

CREATE TABLE #ClusteredRecommendation
(
    SchemaName                 sysname        NOT NULL,
    TableName                  sysname        NOT NULL,
    ObjectID                   int            NOT NULL,
    IsHeap                     bit            NOT NULL,
    HasClusteredIndex          bit            NOT NULL,
    ExistingClusteredIndexName sysname        NULL,
    ExistingClusteredKeyColumns nvarchar(2000) NULL,
    RecordCount                bigint         NOT NULL,
    PageCount                  bigint         NOT NULL,
    SizeMB                     decimal(12, 1) NOT NULL,
    HeapSeeks                  bigint         NOT NULL,
    HeapScans                  bigint         NOT NULL,
    HeapUpdates                bigint         NOT NULL,
    ForwardedRecordCount       bigint         NOT NULL,
    AvgFragmentationPct        decimal(8, 2)  NOT NULL,
    NonClusteredIndexCount     int            NOT NULL,
    MissingIndexImpact         decimal(18, 4) NULL,
    MissingIndexEqualityCols   nvarchar(2000) NULL,
    MissingIndexInequalityCols nvarchar(2000) NULL,
    MissingIndexIncludedCols   nvarchar(2000) NULL,
    MissingIndexKeyColumns     nvarchar(2000) NULL,
    PrimaryKeyColumns          nvarchar(2000) NULL,
    PrimaryKeyIsUnique         bit            NOT NULL,
    TopNcIndexName             sysname        NULL,
    TopNcKeyColumns            nvarchar(2000) NULL,
    TopNcTotalReads            bigint         NOT NULL,
    IdentityColumn             sysname        NULL,
    IdentityTypeName           sysname        NULL,
    IdentitySeed               sql_variant    NULL,
    IdentityIncrement          sql_variant    NULL,
    IdentityIsAscending        bit            NOT NULL,
    IdentityIsPreferredType    bit            NOT NULL,
    HeuristicColumn            sysname        NULL,
    SuggestionSource           varchar(30)    NOT NULL,
    SuggestedKeyColumns        nvarchar(2000) NOT NULL,
    RecommendationScore        int            NOT NULL,
    RecommendationRationale    nvarchar(2000) NOT NULL,
    SuggestedAlterTableDdl     nvarchar(max)  NULL,
    SuggestedClusteredDdl      nvarchar(max)  NOT NULL,
    SuggestedNonClusteredDdl   nvarchar(max)  NULL
)

SET @Sql = N'
DECLARE @ObjectId int

SELECT @ObjectId = o.object_id
  FROM __TARGET_DB__.sys.objects AS o
 INNER JOIN __TARGET_DB__.sys.schemas AS s
    ON s.schema_id = o.schema_id
 WHERE o.type = ''U''
   AND s.name = @SchemaName
   AND o.name = @TableName

IF @ObjectId IS NULL
BEGIN
    RAISERROR(''Table %s.%s was not found in the target database.'', 16, 1, @SchemaName, @TableName)
    RETURN
END

;WITH TargetTable AS
(
    SELECT
        SchemaName = s.name,
        TableName = o.name,
        ObjectID = o.object_id
      FROM __TARGET_DB__.sys.objects AS o
     INNER JOIN __TARGET_DB__.sys.schemas AS s
        ON s.schema_id = o.schema_id
     WHERE o.object_id = @ObjectId
),
ClusteredIndex AS
(
    SELECT
        i.object_id,
        IndexName = i.name,
        ClusteredKeyColumns = STUFF((
            SELECT '', '' + QUOTENAME(c.name)
                  + CASE WHEN ic.is_descending_key = 1 THEN '' DESC'' ELSE '' ASC'' END
              FROM __TARGET_DB__.sys.index_columns AS ic
             INNER JOIN __TARGET_DB__.sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
             WHERE ic.object_id = i.object_id
               AND ic.index_id = i.index_id
               AND ic.is_included_column = 0
               AND ic.key_ordinal > 0
             ORDER BY ic.key_ordinal
             FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 2, '''')
      FROM __TARGET_DB__.sys.indexes AS i
     WHERE i.object_id = @ObjectId
       AND __CLUSTERED_FILTER__
),
TablePhysical AS
(
    SELECT
        ips.object_id,
        RecordCount = SUM(ips.record_count),
        PageCount = SUM(ips.page_count),
        SizeMB = SUM(ips.page_count) * 8.0 / 1024.0,
        ForwardedRecordCount = SUM(ISNULL(ips.forwarded_record_count, 0)),
        AvgFragmentationPct = MAX(ips.avg_fragmentation_in_percent)
      FROM __TARGET_DB__.sys.dm_db_index_physical_stats(@TargetDatabaseId, @ObjectId, NULL, NULL, ''LIMITED'') AS ips
     WHERE ips.index_id = 0
     GROUP BY ips.object_id
),
HeapUsage AS
(
    SELECT
        us.object_id,
        HeapSeeks = ISNULL(SUM(CASE WHEN us.index_id = 0 THEN us.user_seeks ELSE 0 END), 0),
        HeapScans = ISNULL(SUM(CASE WHEN us.index_id = 0 THEN us.user_scans ELSE 0 END), 0),
        HeapUpdates = ISNULL(SUM(CASE WHEN us.index_id = 0 THEN us.user_updates ELSE 0 END), 0)
      FROM sys.dm_db_index_usage_stats AS us
     WHERE us.database_id = @TargetDatabaseId
       AND us.object_id = @ObjectId
     GROUP BY us.object_id
),
NcIndexCounts AS
(
    SELECT
        i.object_id,
        NonClusteredIndexCount = COUNT(*)
      FROM __TARGET_DB__.sys.indexes AS i
     WHERE i.object_id = @ObjectId
       AND i.index_id > 0
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
              FROM __TARGET_DB__.sys.index_columns AS ic
             INNER JOIN __TARGET_DB__.sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
             WHERE ic.object_id = i.object_id
               AND ic.index_id = i.index_id
               AND ic.is_included_column = 0
               AND ic.key_ordinal > 0
             ORDER BY ic.key_ordinal
             FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 2, '''')
      FROM __TARGET_DB__.sys.indexes AS i
     WHERE i.object_id = @ObjectId
       AND i.is_primary_key = 1
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
                    FROM __TARGET_DB__.sys.index_columns AS ic
                   INNER JOIN __TARGET_DB__.sys.columns AS c
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
                  ORDER BY ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) DESC,
                           i.index_id
              )
            FROM __TARGET_DB__.sys.indexes AS i
            LEFT JOIN sys.dm_db_index_usage_stats AS us
              ON us.database_id = @TargetDatabaseId
             AND us.object_id = i.object_id
             AND us.index_id = i.index_id
           WHERE i.object_id = @ObjectId
             AND i.index_id > 0
             AND i.type = 2
             AND i.is_hypothetical = 0
      ) AS x
     WHERE x.rn = 1
),
BestIdentity AS
(
    SELECT
        x.object_id,
        x.IdentityColumn,
        x.IdentityTypeName,
        x.IdentitySeed,
        x.IdentityIncrement,
        x.IdentityIsAscending,
        x.IdentityIsPreferredType
      FROM (
          SELECT
              c.object_id,
              IdentityColumn = c.name,
              IdentityTypeName = t.name,
              IdentitySeed = ic.seed_value,
              IdentityIncrement = ic.increment_value,
              IdentityIsAscending = CASE WHEN CONVERT(decimal(38, 0), ic.increment_value) > 0 THEN 1 ELSE 0 END,
              IdentityIsPreferredType = CASE WHEN t.name IN (''tinyint'', ''smallint'', ''int'', ''bigint'') THEN 1 ELSE 0 END,
              rn = ROW_NUMBER() OVER (
                  ORDER BY
                      CASE WHEN CONVERT(decimal(38, 0), ic.increment_value) > 0 THEN 0 ELSE 1 END,
                      CASE t.name
                          WHEN ''int'' THEN 1
                          WHEN ''bigint'' THEN 2
                          WHEN ''smallint'' THEN 3
                          WHEN ''tinyint'' THEN 4
                          ELSE 100
                      END,
                      c.column_id
              )
            FROM __TARGET_DB__.sys.columns AS c
           INNER JOIN __TARGET_DB__.sys.types AS t
              ON t.user_type_id = c.user_type_id
           INNER JOIN __TARGET_DB__.sys.identity_columns AS ic
              ON ic.object_id = c.object_id
             AND ic.column_id = c.column_id
           WHERE c.object_id = @ObjectId
             AND c.is_identity = 1
             AND c.is_computed = 0
      ) AS x
     WHERE x.rn = 1
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
                  ORDER BY migs.avg_user_impact * (migs.user_seeks + migs.user_scans) DESC
              )
            FROM __TARGET_DB__.sys.dm_db_missing_index_group_stats AS migs
           INNER JOIN __TARGET_DB__.sys.dm_db_missing_index_groups AS mig
              ON mig.index_group_handle = migs.group_handle
           INNER JOIN __TARGET_DB__.sys.dm_db_missing_index_details AS mid
              ON mid.index_handle = mig.index_handle
           WHERE mid.object_id = @ObjectId
             AND migs.avg_user_impact * (migs.user_seeks + migs.user_scans) > 0
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
                  ORDER BY
                      CASE t.name
                          WHEN ''tinyint'' THEN 1
                          WHEN ''smallint'' THEN 2
                          WHEN ''int'' THEN 3
                          WHEN ''bigint'' THEN 4
                          WHEN ''date'' THEN 5
                          WHEN ''datetime'' THEN 6
                          WHEN ''datetime2'' THEN 7
                          ELSE 100
                      END,
                      c.column_id
              )
            FROM __TARGET_DB__.sys.columns AS c
           INNER JOIN __TARGET_DB__.sys.types AS t
              ON t.user_type_id = c.user_type_id
           WHERE c.object_id = @ObjectId
             AND c.is_computed = 0
             AND c.is_identity = 0
             AND c.is_sparse = 0
             AND t.name NOT IN (''text'', ''ntext'', ''image'', ''xml'', ''varchar'', ''nvarchar'', ''varbinary'')
      ) AS x
     WHERE x.rn = 1
),
Prepared AS
(
    SELECT
        tt.SchemaName,
        tt.TableName,
        tt.ObjectID,
        IsHeap = CASE WHEN cx.object_id IS NULL THEN 1 ELSE 0 END,
        HasClusteredIndex = CASE WHEN cx.object_id IS NULL THEN 0 ELSE 1 END,
        ExistingClusteredIndexName = cx.IndexName,
        ExistingClusteredKeyColumns = cx.ClusteredKeyColumns,
        RecordCount = ISNULL(tp.RecordCount, 0),
        PageCount = ISNULL(tp.PageCount, 0),
        SizeMB = ISNULL(tp.SizeMB, 0),
        HeapSeeks = ISNULL(hu.HeapSeeks, 0),
        HeapScans = ISNULL(hu.HeapScans, 0),
        HeapUpdates = ISNULL(hu.HeapUpdates, 0),
        ForwardedRecordCount = ISNULL(tp.ForwardedRecordCount, 0),
        AvgFragmentationPct = ISNULL(tp.AvgFragmentationPct, 0),
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
        IdentityColumn = bi.IdentityColumn,
        IdentityTypeName = bi.IdentityTypeName,
        IdentitySeed = bi.IdentitySeed,
        IdentityIncrement = bi.IdentityIncrement,
        IdentityIsAscending = ISNULL(bi.IdentityIsAscending, 0),
        IdentityIsPreferredType = ISNULL(bi.IdentityIsPreferredType, 0),
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
      FROM TargetTable AS tt
      LEFT JOIN ClusteredIndex AS cx
        ON cx.object_id = tt.ObjectID
      LEFT JOIN TablePhysical AS tp
        ON tp.object_id = tt.ObjectID
      LEFT JOIN HeapUsage AS hu
        ON hu.object_id = tt.ObjectID
      LEFT JOIN NcIndexCounts AS nc
        ON nc.object_id = tt.ObjectID
      LEFT JOIN PrimaryKeyColumns AS pk
        ON pk.object_id = tt.ObjectID
      LEFT JOIN TopNcIndex AS tnc
        ON tnc.object_id = tt.ObjectID
      LEFT JOIN BestIdentity AS bi
        ON bi.object_id = tt.ObjectID
      LEFT JOIN MissingIndexBest AS mi
        ON mi.object_id = tt.ObjectID
      LEFT JOIN HeuristicColumn AS hc
        ON hc.object_id = tt.ObjectID
)
INSERT INTO #ClusteredRecommendation
(
    SchemaName,
    TableName,
    ObjectID,
    IsHeap,
    HasClusteredIndex,
    ExistingClusteredIndexName,
    ExistingClusteredKeyColumns,
    RecordCount,
    PageCount,
    SizeMB,
    HeapSeeks,
    HeapScans,
    HeapUpdates,
    ForwardedRecordCount,
    AvgFragmentationPct,
    NonClusteredIndexCount,
    MissingIndexImpact,
    MissingIndexEqualityCols,
    MissingIndexInequalityCols,
    MissingIndexIncludedCols,
    MissingIndexKeyColumns,
    PrimaryKeyColumns,
    PrimaryKeyIsUnique,
    TopNcIndexName,
    TopNcKeyColumns,
    TopNcTotalReads,
    IdentityColumn,
    IdentityTypeName,
    IdentitySeed,
    IdentityIncrement,
    IdentityIsAscending,
    IdentityIsPreferredType,
    HeuristicColumn,
    SuggestionSource,
    SuggestedKeyColumns,
    RecommendationScore,
    RecommendationRationale,
    SuggestedAlterTableDdl,
    SuggestedClusteredDdl,
    SuggestedNonClusteredDdl
)
SELECT
    p.SchemaName,
    p.TableName,
    p.ObjectID,
    p.IsHeap,
    p.HasClusteredIndex,
    p.ExistingClusteredIndexName,
    p.ExistingClusteredKeyColumns,
    p.RecordCount,
    p.PageCount,
    CAST(p.SizeMB AS decimal(12, 1)),
    p.HeapSeeks,
    p.HeapScans,
    p.HeapUpdates,
    p.ForwardedRecordCount,
    CAST(p.AvgFragmentationPct AS decimal(8, 2)),
    p.NonClusteredIndexCount,
    p.MissingIndexImpact,
    p.MissingIndexEqualityCols,
    p.MissingIndexInequalityCols,
    p.MissingIndexIncludedCols,
    p.MissingIndexKeyColumns,
    p.PrimaryKeyColumns,
    p.PrimaryKeyIsUnique,
    p.TopNcIndexName,
    p.TopNcKeyColumns,
    p.TopNcTotalReads,
    p.IdentityColumn,
    p.IdentityTypeName,
    p.IdentitySeed,
    p.IdentityIncrement,
    p.IdentityIsAscending,
    p.IdentityIsPreferredType,
    p.HeuristicColumn,
    SuggestionSource = ''PENDING'',
    SuggestedKeyColumns = '''',
    RecommendationScore = 0,
    RecommendationRationale = '''',
    SuggestedAlterTableDdl = NULL,
    SuggestedClusteredDdl = '''',
    SuggestedNonClusteredDdl = NULL
  FROM Prepared AS p'

SET @Sql = REPLACE(@Sql, N'__TARGET_DB__', @QuotedDatabase)
SET @Sql = REPLACE(@Sql, N'__CLUSTERED_FILTER__', @ClusteredTypeFilter)

BEGIN TRY
    EXEC sys.sp_executesql
        @Sql,
        N'@TargetDatabaseId int,
          @SchemaName sysname,
          @TableName sysname',
        @TargetDatabaseId = @TargetDatabaseId,
        @SchemaName = @SchemaName,
        @TableName = @TableName
END TRY
BEGIN CATCH
    DECLARE @ErrMsg nvarchar(4000) = ERROR_MESSAGE()
    RAISERROR('RecommendClusteredIndex analysis failed: %s', 16, 1, @ErrMsg)
    RETURN
END CATCH

IF NOT EXISTS (SELECT 1 FROM #ClusteredRecommendation)
BEGIN
    RAISERROR('Table %s.%s was not found in database %s.', 16, 1, @SchemaName, @TableName, @TargetDatabase)
    RETURN
END

SELECT @ObjectId = ObjectID
  FROM #ClusteredRecommendation

UPDATE r
   SET SuggestionSource = CASE
           WHEN r.HasClusteredIndex = 1
                AND @PreferIdentity = 1
                AND r.IdentityColumn IS NOT NULL
                AND r.IdentityIsAscending = 1
                AND r.IdentityIsPreferredType = 1
                AND ISNULL(r.ExistingClusteredKeyColumns, '') <> QUOTENAME(r.IdentityColumn) + ' ASC'
                AND CHARINDEX(QUOTENAME(r.IdentityColumn), ISNULL(r.ExistingClusteredKeyColumns, '')) = 0
               THEN 'RECLUSTER_IDENTITY'
           WHEN r.HasClusteredIndex = 1 THEN 'ALREADY_CLUSTERED'
           WHEN @PreferIdentity = 1
                AND r.IdentityColumn IS NOT NULL
                AND r.IdentityIsAscending = 1
                AND r.IdentityIsPreferredType = 1
               THEN 'IDENTITY'
           WHEN @PreferIdentity = 1
                AND r.IdentityColumn IS NULL
                AND r.PrimaryKeyColumns IS NULL
               THEN 'ADD_IDENTITY'
           WHEN r.PrimaryKeyColumns IS NOT NULL THEN 'PRIMARY_KEY'
           WHEN r.MissingIndexKeyColumns IS NOT NULL AND ISNULL(r.MissingIndexImpact, 0) >= 10000 THEN 'MISSING_INDEX'
           WHEN r.TopNcKeyColumns IS NOT NULL AND r.TopNcTotalReads > 0 THEN 'NC_INDEX_USAGE'
           WHEN r.MissingIndexKeyColumns IS NOT NULL THEN 'MISSING_INDEX'
           WHEN r.IdentityColumn IS NOT NULL THEN 'IDENTITY'
           WHEN r.HeuristicColumn IS NOT NULL THEN 'HEURISTIC'
           ELSE 'MANUAL_REVIEW'
       END,
       SuggestedKeyColumns = CASE
           WHEN r.HasClusteredIndex = 1
                AND @PreferIdentity = 1
                AND r.IdentityColumn IS NOT NULL
                AND r.IdentityIsAscending = 1
                AND r.IdentityIsPreferredType = 1
                AND ISNULL(r.ExistingClusteredKeyColumns, '') <> QUOTENAME(r.IdentityColumn) + ' ASC'
                AND CHARINDEX(QUOTENAME(r.IdentityColumn), ISNULL(r.ExistingClusteredKeyColumns, '')) = 0
               THEN QUOTENAME(r.IdentityColumn) + ' ASC'
           WHEN r.HasClusteredIndex = 1 THEN ISNULL(r.ExistingClusteredKeyColumns, '')
           WHEN @PreferIdentity = 1
                AND r.IdentityColumn IS NOT NULL
                AND r.IdentityIsAscending = 1
                AND r.IdentityIsPreferredType = 1
               THEN QUOTENAME(r.IdentityColumn) + ' ASC'
           WHEN @PreferIdentity = 1
                AND r.IdentityColumn IS NULL
                AND r.PrimaryKeyColumns IS NULL
               THEN QUOTENAME(@ProposedIdentityCol) + ' ASC'
           WHEN r.PrimaryKeyColumns IS NOT NULL THEN r.PrimaryKeyColumns
           WHEN r.MissingIndexKeyColumns IS NOT NULL AND ISNULL(r.MissingIndexImpact, 0) >= 10000 THEN r.MissingIndexKeyColumns
           WHEN r.TopNcKeyColumns IS NOT NULL AND r.TopNcTotalReads > 0 THEN r.TopNcKeyColumns
           WHEN r.MissingIndexKeyColumns IS NOT NULL THEN r.MissingIndexKeyColumns
           WHEN r.IdentityColumn IS NOT NULL THEN QUOTENAME(r.IdentityColumn) + ' ASC'
           WHEN r.HeuristicColumn IS NOT NULL THEN QUOTENAME(r.HeuristicColumn) + ' ASC'
           ELSE ''
       END,
       RecommendationScore =
             CASE WHEN ISNULL(r.PageCount, 0) >= 10000 THEN 20 WHEN ISNULL(r.PageCount, 0) >= 1000 THEN 12 WHEN ISNULL(r.PageCount, 0) >= 100 THEN 6 ELSE 2 END
           + CASE WHEN ISNULL(r.HeapScans, 0) >= 10000 THEN 20 WHEN ISNULL(r.HeapScans, 0) >= 1000 THEN 12 WHEN ISNULL(r.HeapScans, 0) >= 100 THEN 6 ELSE 0 END
           + CASE WHEN ISNULL(r.ForwardedRecordCount, 0) > 0 THEN 15 ELSE 0 END
           + CASE WHEN ISNULL(r.NonClusteredIndexCount, 0) >= 3 THEN 10 WHEN ISNULL(r.NonClusteredIndexCount, 0) >= 1 THEN 5 ELSE 0 END
           + CASE WHEN ISNULL(r.MissingIndexImpact, 0) >= 1000000 THEN 20 WHEN ISNULL(r.MissingIndexImpact, 0) >= 100000 THEN 12 WHEN ISNULL(r.MissingIndexImpact, 0) >= 10000 THEN 6 ELSE 0 END
           + CASE WHEN @PreferIdentity = 1 AND r.IdentityColumn IS NOT NULL AND r.IdentityIsAscending = 1 THEN 25 ELSE 0 END
           + CASE WHEN @PreferIdentity = 1 AND r.IdentityColumn IS NULL AND r.PrimaryKeyColumns IS NULL THEN 15 ELSE 0 END
           + CASE WHEN r.PrimaryKeyColumns IS NOT NULL THEN 10 ELSE 0 END
           + CASE WHEN ISNULL(r.AvgFragmentationPct, 0) >= 30 THEN 5 ELSE 0 END
  FROM #ClusteredRecommendation AS r

UPDATE r
   SET RecommendationRationale =
           CASE r.SuggestionSource
               WHEN 'IDENTITY' THEN 'Ascending identity column [' + r.IdentityColumn + '] (' + ISNULL(r.IdentityTypeName, '?')
                    + ', seed ' + ISNULL(CONVERT(varchar(30), r.IdentitySeed), '?')
                    + ', increment ' + ISNULL(CONVERT(varchar(30), r.IdentityIncrement), '?')
                    + ') is the preferred narrow monotonic clustering key.'
               WHEN 'ADD_IDENTITY' THEN 'Table has no identity column. Adding a single int IDENTITY column provides a fast ever-increasing clustering key for insert-heavy workloads.'
               WHEN 'RECLUSTER_IDENTITY' THEN 'Table is clustered on [' + ISNULL(r.ExistingClusteredKeyColumns, '?')
                    + ']. A single ascending identity column [' + r.IdentityColumn + '] is available and is preferred for insert locality.'
               WHEN 'ALREADY_CLUSTERED' THEN 'Table already has clustered index [' + ISNULL(r.ExistingClusteredIndexName, '?') + '] on ('
                    + ISNULL(r.ExistingClusteredKeyColumns, '?') + '). No change recommended unless workload analysis suggests otherwise.'
               WHEN 'PRIMARY_KEY' THEN 'Nonclustered primary key columns should be clustered to eliminate RID lookups and stabilize nonclustered index leaf pointers.'
               WHEN 'MISSING_INDEX' THEN 'Missing-index DMVs show sustained access patterns on these key columns (impact score '
                    + ISNULL(CONVERT(varchar(20), CONVERT(bigint, r.MissingIndexImpact)), '0') + ').'
               WHEN 'NC_INDEX_USAGE' THEN 'Most-used nonclustered index [' + ISNULL(r.TopNcIndexName, '?')
                    + '] indicates lookup columns that are strong clustered-index candidates.'
               WHEN 'HEURISTIC' THEN 'No identity, PK, or DMV signal; narrow key column selected as a fallback clustering candidate.'
               ELSE 'Insufficient metadata to recommend a clustered index automatically.'
           END
         + CASE WHEN r.IdentityColumn IS NOT NULL AND r.IdentityIsAscending = 0
                THEN ' Warning: identity increment is not positive; ascending clustering may not match insert pattern.'
                ELSE ''
           END
         + CASE WHEN r.IdentityColumn IS NOT NULL AND r.IdentityIsPreferredType = 0
                THEN ' Warning: identity type is not an integer family; consider int or bigint for a narrow clustering key.'
                ELSE ''
           END
         + CASE WHEN r.ForwardedRecordCount > 0
                THEN ' Forwarded records (' + CAST(r.ForwardedRecordCount AS varchar(20)) + ') indicate heap update pressure.'
                ELSE ''
           END
         + CASE WHEN r.SuggestionSource = 'ADD_IDENTITY'
                THEN ' Review constraints, replication, and load before adding an identity column to a populated table.'
                ELSE ''
           END,
       SuggestedAlterTableDdl =
           CASE
               WHEN r.SuggestionSource = 'ADD_IDENTITY' THEN
                   'ALTER TABLE ' + QUOTENAME(r.SchemaName) + '.' + QUOTENAME(r.TableName)
                   + ' ADD ' + QUOTENAME(@ProposedIdentityCol) + ' int NOT NULL IDENTITY(1, 1);'
               ELSE NULL
           END,
       SuggestedClusteredDdl =
           CASE
               WHEN r.SuggestionSource = 'ALREADY_CLUSTERED' THEN
                   '-- No action required. Existing clustered index: '
                   + ISNULL(r.ExistingClusteredIndexName, '?') + ' (' + ISNULL(r.ExistingClusteredKeyColumns, '?') + ')'
               WHEN r.SuggestionSource IN ('MANUAL_REVIEW') OR NULLIF(r.SuggestedKeyColumns, '') IS NULL THEN
                   '-- Manual review required for ' + QUOTENAME(r.SchemaName) + '.' + QUOTENAME(r.TableName)
               WHEN r.SuggestionSource = 'RECLUSTER_IDENTITY' THEN
                   '-- Drop or rebuild existing clustered index before creating the identity-based clustered index.' + CHAR(13) + CHAR(10)
                   + 'CREATE CLUSTERED INDEX ' + QUOTENAME('CX_' + r.TableName)
                   + ' ON ' + QUOTENAME(r.SchemaName) + '.' + QUOTENAME(r.TableName)
                   + ' (' + r.SuggestedKeyColumns + ') WITH (' + @IndexWithOptions + ', FILLFACTOR = 90);'
               WHEN r.SuggestionSource = 'ADD_IDENTITY' THEN
                   '-- Run SuggestedAlterTableDdl first, then execute:' + CHAR(13) + CHAR(10)
                   + 'CREATE CLUSTERED INDEX ' + QUOTENAME('CX_' + r.TableName)
                   + ' ON ' + QUOTENAME(r.SchemaName) + '.' + QUOTENAME(r.TableName)
                   + ' (' + r.SuggestedKeyColumns + ') WITH (' + @IndexWithOptions + ', FILLFACTOR = 90);'
               WHEN r.PrimaryKeyColumns IS NOT NULL AND r.PrimaryKeyIsUnique = 1 AND r.SuggestionSource = 'PRIMARY_KEY' THEN
                   'CREATE UNIQUE CLUSTERED INDEX ' + QUOTENAME('CX_' + r.TableName)
                   + ' ON ' + QUOTENAME(r.SchemaName) + '.' + QUOTENAME(r.TableName)
                   + ' (' + r.SuggestedKeyColumns + ') WITH (' + @IndexWithOptions + ');'
               ELSE
                   'CREATE CLUSTERED INDEX ' + QUOTENAME('CX_' + r.TableName)
                   + ' ON ' + QUOTENAME(r.SchemaName) + '.' + QUOTENAME(r.TableName)
                   + ' (' + r.SuggestedKeyColumns + ') WITH (' + @IndexWithOptions + ', FILLFACTOR = 90);'
           END,
       SuggestedNonClusteredDdl =
           CASE
               WHEN r.SuggestionSource IN ('ALREADY_CLUSTERED', 'MANUAL_REVIEW', 'ADD_IDENTITY', 'RECLUSTER_IDENTITY') THEN NULL
               WHEN r.MissingIndexKeyColumns IS NOT NULL
                AND r.MissingIndexKeyColumns <> ISNULL(r.SuggestedKeyColumns, '')
                AND (
                        r.SuggestionSource <> 'MISSING_INDEX'
                     OR r.PrimaryKeyColumns IS NOT NULL
                    )
                   THEN 'CREATE NONCLUSTERED INDEX ' + QUOTENAME('IX_' + r.TableName + '_MissingSignal')
                      + ' ON ' + QUOTENAME(r.SchemaName) + '.' + QUOTENAME(r.TableName)
                      + ' (' + r.MissingIndexKeyColumns + ')'
                      + CASE
                            WHEN NULLIF(LTRIM(RTRIM(r.MissingIndexIncludedCols)), '') IS NOT NULL
                                THEN ' INCLUDE (' + r.MissingIndexIncludedCols + ')'
                            ELSE ''
                        END
                      + ' WITH (' + @IndexWithOptionsNC + ');'
               ELSE NULL
           END
  FROM #ClusteredRecommendation AS r

IF @ReturnResultSets = 1
BEGIN
    SELECT
        CaptureDate = @CaptureDate,
        ServerName = @ServerName,
        DatabaseName = @TargetDatabase,
        TargetCompatibilityLevel = @CompatibilityLevel,
        IndexWithOptions = @IndexWithOptions,
        PreferIdentity = @PreferIdentity,
        ProposedIdentityColumn = @ProposedIdentityCol,
        Note = 'Prioritizes a single ascending integer identity clustering key when possible. Usage stats are since instance restart. Test DDL in a maintenance window.'

    SELECT
        SchemaName,
        TableName,
        ObjectID,
        IsHeap,
        HasClusteredIndex,
        ExistingClusteredIndexName,
        ExistingClusteredKeyColumns,
        RecordCount,
        PageCount,
        SizeMB,
        HeapSeeks,
        HeapScans,
        HeapUpdates,
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
        IdentityTypeName,
        IdentitySeed,
        IdentityIncrement,
        IdentityIsAscending,
        IdentityIsPreferredType,
        SuggestionSource,
        SuggestedKeyColumns,
        RecommendationScore,
        RecommendationRationale,
        SuggestedAlterTableDdl,
        SuggestedClusteredDdl,
        SuggestedNonClusteredDdl
      FROM #ClusteredRecommendation
END

GO

IF OBJECT_ID('dbo.RecommendClusteredIndex') IS NOT NULL
    PRINT 'RecommendClusteredIndex created successfully.'
ELSE
BEGIN
    RAISERROR('RecommendClusteredIndex was not created. Fix syntax errors above and redeploy this script only.', 16, 1)
END
GO