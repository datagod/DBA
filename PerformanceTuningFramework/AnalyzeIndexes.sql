use dbatools
/*
  AnalyzeIndexes.sql
  Performance Tuning Framework

  Deploy to the tool database, create IndexAnalysis first, then execute:
    EXEC dbo.AnalyzeIndexes @TargetDatabase = N'YourDatabase'

  Optional parameters:
    @TargetDatabase - database to analyze (default: current database)
    @SchemaFilter   - schema name filter (default '%')
    @TableFilter    - table name filter (default '%')
    @SortBy         - READS | WRITES | SIZE | OBJECT | LAST_USE
    @ReturnSummary  - return one-row summary result set (default 1)
    @AnalysisRunID  - OUTPUT unique identifier for this capture run
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.AnalyzeIndexes
(
    @TargetDatabase sysname           = NULL,
    @SchemaFilter   sysname           = '%',
    @TableFilter    sysname           = '%',
    @SortBy         varchar(10)       = 'READS',
    @ReturnSummary  bit               = 1,
    @AnalysisRunID  uniqueidentifier  = NULL OUTPUT
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Captures index usage statistics from a target database and stores the results
--               in IndexAnalysis for later querying and reporting.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion        tinyint,
    @ServerName          sysname,
    @TargetDatabaseId    int,
    @CaptureDate         datetime,
    @SortByUpper         varchar(10),
    @Sql                 nvarchar(max),
    @RowsInserted        int,
    @TotalIndexes        int,
    @UnusedIndexes       int,
    @WriteHeavyIndexes   int,
    @DisabledIndexes     int,
    @NeverSampled        int,
    @CompressionCte      nvarchar(max)

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)

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

SET @SortByUpper = UPPER(ISNULL(@SortBy, 'READS'))
IF @SortByUpper NOT IN ('READS', 'WRITES', 'SIZE', 'OBJECT', 'LAST_USE')
    SET @SortByUpper = 'READS'

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @ServerName    = CAST(SERVERPROPERTY('MachineName') AS sysname)
                     + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @AnalysisRunID = NEWID()
SET @CaptureDate   = GETDATE()

IF @MajorVersion >= 10
    SET @CompressionCte = N'
IndexCompression AS
(
    SELECT
        p.object_id,
        p.index_id,
        CompressionDesc = CASE
            WHEN MIN(p.data_compression_desc) = MAX(p.data_compression_desc) THEN MIN(p.data_compression_desc)
            ELSE ''MULTIPLE''
        END
    FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.partitions AS p
    GROUP BY p.object_id, p.index_id
),'
ELSE
    SET @CompressionCte = N'
IndexCompression AS
(
    SELECT
        object_id = CAST(NULL AS int),
        index_id = CAST(NULL AS int),
        CompressionDesc = CAST(NULL AS nvarchar(60))
    WHERE 1 = 0
),'

IF OBJECT_ID('tempdb..#IndexUsage') IS NOT NULL
    DROP TABLE #IndexUsage

CREATE TABLE #IndexUsage
(
    SchemaName       sysname         NOT NULL,
    TableName        sysname         NOT NULL,
    ObjectID         int             NOT NULL,
    IndexID          int             NOT NULL,
    IndexName        varchar(128)    NOT NULL,
    IndexTypeDesc    nvarchar(60)    NOT NULL,
    UserSeeks        bigint          NOT NULL,
    UserScans        bigint          NOT NULL,
    UserLookups      bigint          NOT NULL,
    UserUpdates      bigint          NOT NULL,
    TotalReads       bigint          NOT NULL,
    ReadWriteNumeric decimal(18, 4)  NULL,
    RecordCount      bigint          NOT NULL,
    SizeMB           decimal(12, 1)   NOT NULL,
    LastUserSeek     datetime        NULL,
    LastUserScan     datetime        NULL,
    LastUserLookup   datetime        NULL,
    LastUserUpdate   datetime        NULL,
    IsDisabled       bit             NOT NULL,
    HasUsageStats    bit             NOT NULL,
    IsFiltered       bit             NOT NULL,
    IsUnique         bit             NOT NULL,
    IsPrimaryKey     bit             NOT NULL,
    [FillFactor]     tinyint         NULL,
    KeyColumns       nvarchar(2000)  NULL,
    IncludedColumns  nvarchar(2000)  NULL,
    FilterDefinition nvarchar(max)   NULL,
    CompressionDesc  nvarchar(60)    NULL
)

SET @Sql = N'
;WITH IndexColumnDefs AS
(
    SELECT
        ic.object_id,
        ic.index_id,
        ic.is_included_column,
        ic.key_ordinal,
        ic.index_column_id,
        ic.is_descending_key,
        ColumnName = c.name
    FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.index_columns AS ic
    INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.columns AS c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
),
KeyColumnList AS
(
    SELECT
        icd.object_id,
        icd.index_id,
        KeyColumns = STUFF((
            SELECT '', '' + icd2.ColumnName
                + CASE WHEN icd2.is_descending_key = 1 THEN '' DESC'' ELSE '' ASC'' END
            FROM IndexColumnDefs AS icd2
            WHERE icd2.object_id = icd.object_id
              AND icd2.index_id = icd.index_id
              AND icd2.is_included_column = 0
              AND icd2.key_ordinal > 0
            ORDER BY icd2.key_ordinal
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 2, '''')
    FROM IndexColumnDefs AS icd
    WHERE icd.is_included_column = 0
      AND icd.key_ordinal > 0
    GROUP BY icd.object_id, icd.index_id
),
IncludedColumnList AS
(
    SELECT
        icd.object_id,
        icd.index_id,
        IncludedColumns = STUFF((
            SELECT '', '' + icd2.ColumnName
            FROM IndexColumnDefs AS icd2
            WHERE icd2.object_id = icd.object_id
              AND icd2.index_id = icd.index_id
              AND icd2.is_included_column = 1
            ORDER BY icd2.index_column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 2, '''')
    FROM IndexColumnDefs AS icd
    WHERE icd.is_included_column = 1
    GROUP BY icd.object_id, icd.index_id
),
' + @CompressionCte + N'
IndexMetrics AS
(
    SELECT
        p.object_id,
        p.index_id,
        RecordCount = SUM(p.rows),
        SizeMB = SUM(a.total_pages) * 8.0 / 1024.0
    FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.partitions AS p
    INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.allocation_units AS a
        ON p.partition_id = a.container_id
    GROUP BY p.object_id, p.index_id
)
INSERT INTO #IndexUsage
(
    SchemaName,
    TableName,
    ObjectID,
    IndexID,
    IndexName,
    IndexTypeDesc,
    UserSeeks,
    UserScans,
    UserLookups,
    UserUpdates,
    TotalReads,
    ReadWriteNumeric,
    RecordCount,
    SizeMB,
    LastUserSeek,
    LastUserScan,
    LastUserLookup,
    LastUserUpdate,
    IsDisabled,
    HasUsageStats,
    IsFiltered,
    IsUnique,
    IsPrimaryKey,
    [FillFactor],
    KeyColumns,
    IncludedColumns,
    FilterDefinition,
    CompressionDesc
)
SELECT
    SchemaName = s.name,
    TableName = o.name,
    ObjectID = o.object_id,
    IndexID = i.index_id,
    IndexName = CASE
                    WHEN i.index_id = 0 THEN ''[HEAP]''
                    WHEN i.name IS NULL THEN ''[unnamed]''
                    ELSE i.name
                END,
    IndexTypeDesc = CASE
                        WHEN i.index_id = 0 THEN ''HEAP''
                        ELSE i.type_desc
                    END,
    UserSeeks   = ISNULL(us.user_seeks, 0),
    UserScans   = ISNULL(us.user_scans, 0),
    UserLookups = ISNULL(us.user_lookups, 0),
    UserUpdates = ISNULL(us.user_updates, 0),
    TotalReads  = ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0),
    ReadWriteNumeric = CASE
                           WHEN ISNULL(us.user_updates, 0) = 0 THEN NULL
                           ELSE (ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0))
                                * 1.0 / us.user_updates
                       END,
    RecordCount = ISNULL(im.RecordCount, 0),
    SizeMB = ISNULL(im.SizeMB, 0),
    LastUserSeek = us.last_user_seek,
    LastUserScan = us.last_user_scan,
    LastUserLookup = us.last_user_lookup,
    LastUserUpdate = us.last_user_update,
    IsDisabled = ISNULL(i.is_disabled, 0),
    HasUsageStats = CASE WHEN us.database_id IS NULL THEN 0 ELSE 1 END,
    IsFiltered = CASE WHEN @MajorVersion >= 10 AND ISNULL(i.has_filter, 0) = 1 THEN 1 ELSE 0 END,
    IsUnique = ISNULL(i.is_unique, 0),
    IsPrimaryKey = ISNULL(i.is_primary_key, 0),
    [FillFactor] = CASE WHEN i.index_id = 0 THEN NULL ELSE i.fill_factor END,
    KeyColumns = kcl.KeyColumns,
    IncludedColumns = icl.IncludedColumns,
    FilterDefinition = CASE
                           WHEN @MajorVersion >= 10 AND ISNULL(i.has_filter, 0) = 1 THEN i.filter_definition
                           ELSE NULL
                       END,
    CompressionDesc = CASE
                          WHEN @MajorVersion >= 10 THEN ISNULL(icomp.CompressionDesc, ''NONE'')
                          ELSE NULL
                      END
FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.objects AS o
INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.indexes AS i
    ON i.object_id = o.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = @TargetDatabaseId
   AND us.object_id = i.object_id
   AND us.index_id = i.index_id
LEFT JOIN IndexMetrics AS im
    ON im.object_id = i.object_id
   AND im.index_id = i.index_id
LEFT JOIN KeyColumnList AS kcl
    ON kcl.object_id = i.object_id
   AND kcl.index_id = i.index_id
LEFT JOIN IncludedColumnList AS icl
    ON icl.object_id = i.object_id
   AND icl.index_id = i.index_id
LEFT JOIN IndexCompression AS icomp
    ON icomp.object_id = i.object_id
   AND icomp.index_id = i.index_id
WHERE o.type = ''U''
  AND s.name LIKE @SchemaFilter
  AND o.name LIKE @TableFilter
  AND i.index_id >= 0'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int,
      @SchemaFilter sysname,
      @TableFilter sysname,
      @MajorVersion tinyint',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @MajorVersion = @MajorVersion

INSERT INTO dbo.IndexAnalysis
(
    AnalysisRunID,
    CaptureDate,
    ServerName,
    DatabaseName,
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
    LastUserSeek,
    LastUserScan,
    LastUserLookup,
    LastUserUpdate,
    IsDisabled,
    HasUsageStats,
    IsFiltered,
    IsUnique,
    IsPrimaryKey,
    [FillFactor],
    KeyColumns,
    IncludedColumns,
    FilterDefinition,
    CompressionDesc,
    FilterSchema,
    FilterTable,
    SortBy
)
SELECT
    @AnalysisRunID,
    @CaptureDate,
    @ServerName,
    @TargetDatabase,
    u.SchemaName,
    u.TableName,
    CASE WHEN u.IndexID = 0 OR u.IndexName IN ('[HEAP]', '[unnamed]') THEN NULL ELSE u.IndexName END,
    u.ObjectID,
    u.IndexID,
    u.IndexTypeDesc,
    u.UserSeeks,
    u.UserScans,
    u.UserLookups,
    u.UserUpdates,
    u.TotalReads,
    u.ReadWriteNumeric,
    u.RecordCount,
    u.SizeMB,
    u.LastUserSeek,
    u.LastUserScan,
    u.LastUserLookup,
    u.LastUserUpdate,
    u.IsDisabled,
    u.HasUsageStats,
    u.IsFiltered,
    u.IsUnique,
    u.IsPrimaryKey,
    u.[FillFactor],
    u.KeyColumns,
    u.IncludedColumns,
    u.FilterDefinition,
    u.CompressionDesc,
    @SchemaFilter,
    @TableFilter,
    @SortByUpper
FROM #IndexUsage AS u

SET @RowsInserted = @@ROWCOUNT

SELECT
    @TotalIndexes      = COUNT(*),
    @UnusedIndexes     = SUM(CASE WHEN TotalReads = 0 AND UserUpdates > 0 THEN 1 ELSE 0 END),
    @WriteHeavyIndexes = SUM(CASE WHEN TotalReads > 0 AND UserUpdates > TotalReads * 10 THEN 1 ELSE 0 END),
    @DisabledIndexes   = SUM(CASE WHEN IsDisabled = 1 THEN 1 ELSE 0 END),
    @NeverSampled      = SUM(CASE WHEN HasUsageStats = 0 THEN 1 ELSE 0 END)
FROM #IndexUsage

IF @ReturnSummary = 1
BEGIN
    SELECT
        AnalysisRunID     = @AnalysisRunID,
        CaptureDate       = @CaptureDate,
        ServerName        = @ServerName,
        DatabaseName      = @TargetDatabase,
        RowsInserted      = @RowsInserted,
        TotalIndexes      = @TotalIndexes,
        UnusedIndexes     = @UnusedIndexes,
        WriteHeavyIndexes = @WriteHeavyIndexes,
        DisabledIndexes   = @DisabledIndexes,
        NeverSampled      = @NeverSampled,
        FilterSchema      = @SchemaFilter,
        FilterTable       = @TableFilter,
        SortBy            = @SortByUpper
END

GO