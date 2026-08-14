/*
  ShowTableInfo.sql
  Performance Tuning Framework

  Requires SQL Server 2008 (10.x) or later on the instance.
  Target database compatibility level 100+ (SQL Server 2008 mode).

  Deploy to the tool database, then execute:
    EXEC dbo.ShowTableInfo
         @TargetDatabase = N'YourDatabase',
         @TableName      = N'YourTable'

    EXEC dbo.ShowTableInfo
         @TargetDatabase = N'YourDatabase',
         @TableName      = N'Sales.Orders'
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowTableInfo') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowTableInfo'
    DROP PROCEDURE dbo.ShowTableInfo
END
GO

PRINT 'Creating: ShowTableInfo (2026-08-14)'
GO

CREATE PROCEDURE dbo.ShowTableInfo
(
    @TargetDatabase sysname = NULL,
    @TableName      sysname,
    @SchemaName     sysname = N'dbo'
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: August 14, 2026
-- Author:       Bill McEvoy
-- Description:  Examines one user table in a target database and reports identity, size, storage
--               shape (heap vs clustered), indexes with usage and fragmentation, columns,
--               constraints, statistics, triggers, and missing-index suggestions.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion        tinyint,
    @CompatibilityLevel  int,
    @ReportedCompatLevel int,
    @TargetDatabaseId    int,
    @QuotedDatabase      nvarchar(260),
    @Sql                 nvarchar(max),
    @ObjectId            int,
    @ParsedSchema        sysname,
    @ParsedTable         sysname,
    @ServerName          sysname,
    @CaptureDate         datetime

IF @TableName IS NULL OR LTRIM(RTRIM(@TableName)) = N''
BEGIN
    RAISERROR('@TableName is required.', 16, 1)
    RETURN
END

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @ParsedSchema = PARSENAME(@TableName, 2)
SET @ParsedTable  = PARSENAME(@TableName, 1)

IF @ParsedTable IS NULL
BEGIN
    RAISERROR('Could not parse @TableName ''%s''.', 16, 1, @TableName)
    RETURN
END

IF @ParsedSchema IS NOT NULL
    SET @SchemaName = @ParsedSchema

SET @TableName = @ParsedTable

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
    RAISERROR('ShowTableInfo requires SQL Server 2008 (10.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
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

SET @ServerName  = CAST(SERVERPROPERTY('MachineName') AS sysname)
                   + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @CaptureDate = GETDATE()

IF OBJECT_ID('tempdb..#TableIdentity') IS NOT NULL DROP TABLE #TableIdentity
IF OBJECT_ID('tempdb..#TableSize') IS NOT NULL DROP TABLE #TableSize
IF OBJECT_ID('tempdb..#TableIndexes') IS NOT NULL DROP TABLE #TableIndexes
IF OBJECT_ID('tempdb..#TableColumns') IS NOT NULL DROP TABLE #TableColumns
IF OBJECT_ID('tempdb..#TableConstraints') IS NOT NULL DROP TABLE #TableConstraints
IF OBJECT_ID('tempdb..#TableStatistics') IS NOT NULL DROP TABLE #TableStatistics
IF OBJECT_ID('tempdb..#TableTriggers') IS NOT NULL DROP TABLE #TableTriggers
IF OBJECT_ID('tempdb..#TableMissingIndexes') IS NOT NULL DROP TABLE #TableMissingIndexes

CREATE TABLE #TableIdentity
(
    ServerName              sysname        NOT NULL,
    DatabaseName            sysname        NOT NULL,
    SchemaName              sysname        NOT NULL,
    TableName               sysname        NOT NULL,
    ObjectID                int            NOT NULL,
    CreateDate              datetime       NOT NULL,
    ModifyDate              datetime       NOT NULL,
    LockEscalation          nvarchar(60)   NULL,
    TextInRowLimit          int            NULL,
    LargeValueTypesOutOfRow bit            NULL,
    IsReplicated            bit            NULL,
    IsMemoryOptimized       bit            NULL,
    TemporalType            nvarchar(60)   NULL,
    HistoryTable            nvarchar(260)  NULL,
    DataFilegroup           sysname        NULL,
    LobFilegroup            sysname        NULL,
    HasAfterTrigger         bit            NOT NULL,
    HasInsteadOfTrigger     bit            NOT NULL,
    CaptureDate             datetime       NOT NULL
)

CREATE TABLE #TableSize
(
    RowCountValue       bigint          NOT NULL,
    ReservedKB          bigint          NOT NULL,
    DataKB              bigint          NOT NULL,
    IndexKB             bigint          NOT NULL,
    UnusedKB            bigint          NOT NULL,
    ReservedMB          decimal(18, 2)  NOT NULL,
    DataMB              decimal(18, 2)  NOT NULL,
    IndexMB             decimal(18, 2)  NOT NULL,
    UnusedMB            decimal(18, 2)  NOT NULL,
    ReservedPages       bigint          NOT NULL,
    UsedPages           bigint          NOT NULL,
    DataPages           bigint          NOT NULL,
    PartitionCount      int             NOT NULL,
    StorageShape        varchar(20)     NOT NULL,
    ClusteredIndexName  sysname         NULL,
    ClusteredKeyColumns nvarchar(2000)  NULL
)

CREATE TABLE #TableIndexes
(
    IndexID             int            NOT NULL,
    IndexName           sysname        NULL,
    IndexType           nvarchar(60)   NOT NULL,
    IsClustered         bit            NOT NULL,
    IsUnique            bit            NOT NULL,
    IsPrimaryKey        bit            NOT NULL,
    IsUniqueConstraint  bit            NOT NULL,
    IsDisabled          bit            NOT NULL,
    FillFactorValue     tinyint        NOT NULL,
    FilterDefinition    nvarchar(max)  NULL,
    KeyColumns          nvarchar(max)  NULL,
    IncludedColumns     nvarchar(max)  NULL,
    DataSpaceName       sysname        NULL,
    CompressionDesc     nvarchar(60)   NULL,
    PartitionCount      int            NOT NULL,
    RowCountValue       bigint         NOT NULL,
    ReservedPages       bigint         NOT NULL,
    UsedPages           bigint         NOT NULL,
    SizeMB              decimal(18, 2) NOT NULL,
    UserSeeks           bigint         NOT NULL,
    UserScans           bigint         NOT NULL,
    UserLookups         bigint         NOT NULL,
    UserUpdates         bigint         NOT NULL,
    LastUserSeek        datetime       NULL,
    LastUserScan        datetime       NULL,
    LastUserLookup      datetime       NULL,
    LastUserUpdate      datetime       NULL,
    AvgFragmentationPct decimal(8, 2)  NULL,
    FragmentedPageCount bigint         NULL,
    IndexDepth          tinyint        NULL
)

CREATE TABLE #TableColumns
(
    ColumnID           int           NOT NULL,
    ColumnName         sysname       NOT NULL,
    DataType           nvarchar(128) NOT NULL,
    MaxLength          smallint      NOT NULL,
    PrecisionValue     tinyint       NOT NULL,
    ScaleValue         tinyint       NOT NULL,
    IsNullable         bit           NOT NULL,
    IsIdentity         bit           NOT NULL,
    IsComputed         bit           NOT NULL,
    IsRowGuidCol       bit           NOT NULL,
    CollationName      nvarchar(128) NULL,
    DefaultDefinition  nvarchar(max) NULL,
    ComputedDefinition nvarchar(max) NULL
)

CREATE TABLE #TableConstraints
(
    ConstraintType    varchar(20)   NOT NULL,
    ConstraintName    sysname       NOT NULL,
    ColumnsList       nvarchar(max) NULL,
    ReferencedObject  nvarchar(260) NULL,
    ReferencedColumns nvarchar(max) NULL,
    CheckDefinition   nvarchar(max) NULL,
    DeleteAction      nvarchar(60)  NULL,
    UpdateAction      nvarchar(60)  NULL,
    IsDisabled        bit           NOT NULL,
    IsNotTrusted      bit           NOT NULL
)

CREATE TABLE #TableStatistics
(
    StatsName             sysname       NOT NULL,
    StatsID               int           NOT NULL,
    LeadingColumn         sysname       NULL,
    LastUpdated           datetime      NULL,
    RowsValue             bigint        NULL,
    RowsSampled           bigint        NULL,
    ModificationCounter   bigint        NULL,
    UnfilteredRows        bigint        NULL,
    HasFilter             bit           NOT NULL,
    FilterDefinition      nvarchar(max) NULL,
    IsAutoCreated         bit           NOT NULL,
    IsNoRecompute         bit           NOT NULL
)

CREATE TABLE #TableTriggers
(
    TriggerName           sysname      NOT NULL,
    TriggerType           nvarchar(60) NOT NULL,
    IsInsteadOf           bit          NOT NULL,
    IsDisabled            bit          NOT NULL,
    IsNotForReplication   bit          NOT NULL,
    CreateDate            datetime     NOT NULL,
    ModifyDate            datetime     NOT NULL
)

CREATE TABLE #TableMissingIndexes
(
    Impact            decimal(18, 2) NOT NULL,
    UniqueCompiles    bigint         NOT NULL,
    UserSeeks         bigint         NOT NULL,
    UserScans         bigint         NOT NULL,
    AvgTotalUserCost  float          NOT NULL,
    AvgUserImpact     float          NOT NULL,
    EqualityColumns   nvarchar(4000) NULL,
    InequalityColumns nvarchar(4000) NULL,
    IncludedColumns   nvarchar(4000) NULL
)

SET @Sql = N'
SELECT @ObjectId = t.object_id
  FROM __TARGET_DB__.sys.tables AS t
 INNER JOIN __TARGET_DB__.sys.schemas AS s
    ON s.schema_id = t.schema_id
 WHERE t.is_ms_shipped = 0
   AND s.name = @SchemaName
   AND t.name = @TableName
'

SET @Sql = REPLACE(@Sql, N'__TARGET_DB__', @QuotedDatabase)

EXEC sys.sp_executesql
    @Sql,
    N'@SchemaName sysname, @TableName sysname, @ObjectId int OUTPUT',
    @SchemaName = @SchemaName,
    @TableName  = @TableName,
    @ObjectId   = @ObjectId OUTPUT

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Table %s.%s was not found in database ''%s''.', 16, 1, @SchemaName, @TableName, @TargetDatabase)
    RETURN
END

SET @Sql = N'
INSERT #TableIdentity
(
    ServerName, DatabaseName, SchemaName, TableName, ObjectID,
    CreateDate, ModifyDate, LockEscalation, TextInRowLimit, LargeValueTypesOutOfRow,
    IsReplicated, IsMemoryOptimized, TemporalType, HistoryTable,
    DataFilegroup, LobFilegroup, HasAfterTrigger, HasInsteadOfTrigger, CaptureDate
)
SELECT
    @ServerName,
    @TargetDatabase,
    s.name,
    t.name,
    t.object_id,
    t.create_date,
    t.modify_date,
    t.lock_escalation_desc,
    t.text_in_row_limit,
    t.large_value_types_out_of_row,
    t.is_replicated,
    __MEMORY_OPT__,
    __TEMPORAL_TYPE__,
    __HISTORY_TABLE__,
    fg.name,
    lobfg.name,
    CASE WHEN EXISTS (
        SELECT 1
          FROM __TARGET_DB__.sys.triggers AS tr
         WHERE tr.parent_id = t.object_id
           AND tr.is_instead_of_trigger = 0
           AND tr.parent_class = 1
    ) THEN 1 ELSE 0 END,
    CASE WHEN EXISTS (
        SELECT 1
          FROM __TARGET_DB__.sys.triggers AS tr
         WHERE tr.parent_id = t.object_id
           AND tr.is_instead_of_trigger = 1
           AND tr.parent_class = 1
    ) THEN 1 ELSE 0 END,
    @CaptureDate
  FROM __TARGET_DB__.sys.tables AS t
 INNER JOIN __TARGET_DB__.sys.schemas AS s
    ON s.schema_id = t.schema_id
  LEFT JOIN __TARGET_DB__.sys.indexes AS i
    ON i.object_id = t.object_id
   AND i.index_id IN (0, 1)
  LEFT JOIN __TARGET_DB__.sys.data_spaces AS ds
    ON ds.data_space_id = i.data_space_id
  LEFT JOIN __TARGET_DB__.sys.filegroups AS fg
    ON fg.data_space_id = ds.data_space_id
  LEFT JOIN __TARGET_DB__.sys.filegroups AS lobfg
    ON lobfg.data_space_id = t.lob_data_space_id
 WHERE t.object_id = @ObjectId

INSERT #TableSize
(
    RowCountValue, ReservedKB, DataKB, IndexKB, UnusedKB,
    ReservedMB, DataMB, IndexMB, UnusedMB,
    ReservedPages, UsedPages, DataPages, PartitionCount,
    StorageShape, ClusteredIndexName, ClusteredKeyColumns
)
SELECT
    RowCountValue = ISNULL((
        SELECT SUM(p.rows)
          FROM __TARGET_DB__.sys.partitions AS p
         WHERE p.object_id = @ObjectId
           AND p.index_id IN (0, 1)
    ), 0),
    ReservedKB = SUM(a.total_pages) * 8,
    DataKB = SUM(CASE WHEN a.type = 1 THEN a.data_pages WHEN a.type IN (2, 3) THEN a.used_pages ELSE 0 END) * 8,
    IndexKB = (SUM(a.used_pages)
               - SUM(CASE WHEN a.type = 1 THEN a.data_pages WHEN a.type IN (2, 3) THEN a.used_pages ELSE 0 END)) * 8,
    UnusedKB = (SUM(a.total_pages) - SUM(a.used_pages)) * 8,
    ReservedMB = CONVERT(decimal(18, 2), SUM(a.total_pages) * 8.0 / 1024.0),
    DataMB = CONVERT(decimal(18, 2), SUM(CASE WHEN a.type = 1 THEN a.data_pages WHEN a.type IN (2, 3) THEN a.used_pages ELSE 0 END) * 8.0 / 1024.0),
    IndexMB = CONVERT(decimal(18, 2), (SUM(a.used_pages)
               - SUM(CASE WHEN a.type = 1 THEN a.data_pages WHEN a.type IN (2, 3) THEN a.used_pages ELSE 0 END)) * 8.0 / 1024.0),
    UnusedMB = CONVERT(decimal(18, 2), (SUM(a.total_pages) - SUM(a.used_pages)) * 8.0 / 1024.0),
    ReservedPages = SUM(a.total_pages),
    UsedPages = SUM(a.used_pages),
    DataPages = SUM(CASE WHEN a.type = 1 THEN a.data_pages ELSE 0 END),
    PartitionCount = (
        SELECT COUNT(*)
          FROM __TARGET_DB__.sys.partitions AS p
         WHERE p.object_id = @ObjectId
           AND p.index_id IN (0, 1)
    ),
    StorageShape = CASE
        WHEN EXISTS (
            SELECT 1 FROM __TARGET_DB__.sys.indexes AS ix
             WHERE ix.object_id = @ObjectId AND ix.type = 1
        ) THEN ''CLUSTERED''
        WHEN EXISTS (
            SELECT 1 FROM __TARGET_DB__.sys.indexes AS ix
             WHERE ix.object_id = @ObjectId AND ix.type = 5
        ) THEN ''CLUSTERED COLUMNSTORE''
        ELSE ''HEAP''
    END,
    ClusteredIndexName = (
        SELECT TOP (1) ix.name
          FROM __TARGET_DB__.sys.indexes AS ix
         WHERE ix.object_id = @ObjectId
           AND ix.type IN (1, 5)
         ORDER BY ix.index_id
    ),
    ClusteredKeyColumns = (
        SELECT STUFF((
            SELECT '', '' + QUOTENAME(c.name)
                  + CASE WHEN ic.is_descending_key = 1 THEN '' DESC'' ELSE '' ASC'' END
              FROM __TARGET_DB__.sys.index_columns AS ic
             INNER JOIN __TARGET_DB__.sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
             INNER JOIN __TARGET_DB__.sys.indexes AS ix
                ON ix.object_id = ic.object_id
               AND ix.index_id = ic.index_id
             WHERE ix.object_id = @ObjectId
               AND ix.type = 1
               AND ic.is_included_column = 0
               AND ic.key_ordinal > 0
             ORDER BY ic.key_ordinal
             FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 2, '''')
    )
  FROM __TARGET_DB__.sys.partitions AS p
 INNER JOIN __TARGET_DB__.sys.allocation_units AS a
    ON a.container_id = p.partition_id
 WHERE p.object_id = @ObjectId

INSERT #TableIndexes
(
    IndexID, IndexName, IndexType, IsClustered, IsUnique, IsPrimaryKey, IsUniqueConstraint,
    IsDisabled, FillFactorValue, FilterDefinition, KeyColumns, IncludedColumns, DataSpaceName,
    CompressionDesc, PartitionCount, RowCountValue, ReservedPages, UsedPages, SizeMB,
    UserSeeks, UserScans, UserLookups, UserUpdates,
    LastUserSeek, LastUserScan, LastUserLookup, LastUserUpdate,
    AvgFragmentationPct, FragmentedPageCount, IndexDepth
)
SELECT
    i.index_id,
    i.name,
    i.type_desc,
    CASE WHEN i.type IN (1, 5) THEN 1 ELSE 0 END,
    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    i.is_disabled,
    i.fill_factor,
    i.filter_definition,
    KeyColumns = STUFF((
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
    IncludedColumns = STUFF((
        SELECT '', '' + QUOTENAME(c.name)
          FROM __TARGET_DB__.sys.index_columns AS ic
         INNER JOIN __TARGET_DB__.sys.columns AS c
            ON c.object_id = ic.object_id
           AND c.column_id = ic.column_id
         WHERE ic.object_id = i.object_id
           AND ic.index_id = i.index_id
           AND ic.is_included_column = 1
         ORDER BY ic.index_column_id
         FOR XML PATH(''''), TYPE
    ).value(''.'', ''nvarchar(max)''), 1, 2, ''''),
    ds.name,
    p.CompressionDesc,
    p.PartitionCount,
    p.RowCountValue,
    ISNULL(sz.ReservedPages, 0),
    ISNULL(sz.UsedPages, 0),
    CONVERT(decimal(18, 2), ISNULL(sz.ReservedPages, 0) * 8.0 / 1024.0),
    ISNULL(us.user_seeks, 0),
    ISNULL(us.user_scans, 0),
    ISNULL(us.user_lookups, 0),
    ISNULL(us.user_updates, 0),
    us.last_user_seek,
    us.last_user_scan,
    us.last_user_lookup,
    us.last_user_update,
    phys.AvgFragmentationPct,
    phys.FragmentedPageCount,
    phys.IndexDepth
  FROM __TARGET_DB__.sys.indexes AS i
  LEFT JOIN __TARGET_DB__.sys.data_spaces AS ds
    ON ds.data_space_id = i.data_space_id
  LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = @TargetDatabaseId
   AND us.object_id = i.object_id
   AND us.index_id = i.index_id
  LEFT JOIN (
        SELECT
            p.object_id,
            p.index_id,
            PartitionCount = COUNT(*),
            RowCountValue = SUM(p.rows),
            CompressionDesc = MAX(p.data_compression_desc)
          FROM __TARGET_DB__.sys.partitions AS p
         GROUP BY p.object_id, p.index_id
  ) AS p
    ON p.object_id = i.object_id
   AND p.index_id = i.index_id
  LEFT JOIN (
        SELECT
            p.object_id,
            p.index_id,
            ReservedPages = SUM(a.total_pages),
            UsedPages = SUM(a.used_pages)
          FROM __TARGET_DB__.sys.partitions AS p
         INNER JOIN __TARGET_DB__.sys.allocation_units AS a
            ON a.container_id = p.partition_id
         GROUP BY p.object_id, p.index_id
  ) AS sz
    ON sz.object_id = i.object_id
   AND sz.index_id = i.index_id
  LEFT JOIN (
        SELECT
            ips.object_id,
            ips.index_id,
            AvgFragmentationPct = CONVERT(decimal(8, 2), AVG(ips.avg_fragmentation_in_percent)),
            FragmentedPageCount = SUM(ips.page_count),
            IndexDepth = CONVERT(tinyint, MAX(ips.index_depth))
          FROM __TARGET_DB__.sys.dm_db_index_physical_stats(@TargetDatabaseId, @ObjectId, NULL, NULL, ''LIMITED'') AS ips
         GROUP BY ips.object_id, ips.index_id
  ) AS phys
    ON phys.object_id = i.object_id
   AND phys.index_id = i.index_id
 WHERE i.object_id = @ObjectId
   AND i.is_hypothetical = 0

INSERT #TableColumns
(
    ColumnID, ColumnName, DataType, MaxLength, PrecisionValue, ScaleValue,
    IsNullable, IsIdentity, IsComputed, IsRowGuidCol, CollationName,
    DefaultDefinition, ComputedDefinition
)
SELECT
    c.column_id,
    c.name,
    ty.name,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    c.is_computed,
    c.is_rowguidcol,
    c.collation_name,
    dc.definition,
    cc.definition
  FROM __TARGET_DB__.sys.columns AS c
 INNER JOIN __TARGET_DB__.sys.types AS ty
    ON ty.user_type_id = c.user_type_id
  LEFT JOIN __TARGET_DB__.sys.default_constraints AS dc
    ON dc.object_id = c.default_object_id
  LEFT JOIN __TARGET_DB__.sys.computed_columns AS cc
    ON cc.object_id = c.object_id
   AND cc.column_id = c.column_id
 WHERE c.object_id = @ObjectId

INSERT #TableConstraints
(
    ConstraintType, ConstraintName, ColumnsList, ReferencedObject, ReferencedColumns,
    CheckDefinition, DeleteAction, UpdateAction, IsDisabled, IsNotTrusted
)
SELECT
    ConstraintType = ''PRIMARY KEY'',
    ConstraintName = kc.name,
    ColumnsList = STUFF((
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
    ).value(''.'', ''nvarchar(max)''), 1, 2, ''''),
    ReferencedObject = NULL,
    ReferencedColumns = NULL,
    CheckDefinition = NULL,
    DeleteAction = NULL,
    UpdateAction = NULL,
    IsDisabled = i.is_disabled,
    IsNotTrusted = 0
  FROM __TARGET_DB__.sys.key_constraints AS kc
 INNER JOIN __TARGET_DB__.sys.indexes AS i
    ON i.object_id = kc.parent_object_id
   AND i.index_id = kc.unique_index_id
 WHERE kc.parent_object_id = @ObjectId
   AND kc.type = ''PK''

UNION ALL

SELECT
    ConstraintType = ''UNIQUE'',
    ConstraintName = kc.name,
    ColumnsList = STUFF((
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
    ).value(''.'', ''nvarchar(max)''), 1, 2, ''''),
    ReferencedObject = NULL,
    ReferencedColumns = NULL,
    CheckDefinition = NULL,
    DeleteAction = NULL,
    UpdateAction = NULL,
    IsDisabled = i.is_disabled,
    IsNotTrusted = 0
  FROM __TARGET_DB__.sys.key_constraints AS kc
 INNER JOIN __TARGET_DB__.sys.indexes AS i
    ON i.object_id = kc.parent_object_id
   AND i.index_id = kc.unique_index_id
 WHERE kc.parent_object_id = @ObjectId
   AND kc.type = ''UQ''

UNION ALL

SELECT
    ConstraintType = ''FOREIGN KEY'',
    ConstraintName = fk.name,
    ColumnsList = STUFF((
        SELECT '', '' + QUOTENAME(c.name)
          FROM __TARGET_DB__.sys.foreign_key_columns AS fkc
         INNER JOIN __TARGET_DB__.sys.columns AS c
            ON c.object_id = fkc.parent_object_id
           AND c.column_id = fkc.parent_column_id
         WHERE fkc.constraint_object_id = fk.object_id
         ORDER BY fkc.constraint_column_id
         FOR XML PATH(''''), TYPE
    ).value(''.'', ''nvarchar(max)''), 1, 2, ''''),
    ReferencedObject = QUOTENAME(rs.name) + ''.'' + QUOTENAME(rt.name),
    ReferencedColumns = STUFF((
        SELECT '', '' + QUOTENAME(c.name)
          FROM __TARGET_DB__.sys.foreign_key_columns AS fkc
         INNER JOIN __TARGET_DB__.sys.columns AS c
            ON c.object_id = fkc.referenced_object_id
           AND c.column_id = fkc.referenced_column_id
         WHERE fkc.constraint_object_id = fk.object_id
         ORDER BY fkc.constraint_column_id
         FOR XML PATH(''''), TYPE
    ).value(''.'', ''nvarchar(max)''), 1, 2, ''''),
    CheckDefinition = NULL,
    DeleteAction = fk.delete_referential_action_desc,
    UpdateAction = fk.update_referential_action_desc,
    IsDisabled = fk.is_disabled,
    IsNotTrusted = fk.is_not_trusted
  FROM __TARGET_DB__.sys.foreign_keys AS fk
 INNER JOIN __TARGET_DB__.sys.tables AS rt
    ON rt.object_id = fk.referenced_object_id
 INNER JOIN __TARGET_DB__.sys.schemas AS rs
    ON rs.schema_id = rt.schema_id
 WHERE fk.parent_object_id = @ObjectId

UNION ALL

SELECT
    ConstraintType = ''CHECK'',
    ConstraintName = cc.name,
    ColumnsList = NULL,
    ReferencedObject = NULL,
    ReferencedColumns = NULL,
    CheckDefinition = cc.definition,
    DeleteAction = NULL,
    UpdateAction = NULL,
    IsDisabled = cc.is_disabled,
    IsNotTrusted = cc.is_not_trusted
  FROM __TARGET_DB__.sys.check_constraints AS cc
 WHERE cc.parent_object_id = @ObjectId

INSERT #TableStatistics
(
    StatsName, StatsID, LeadingColumn, LastUpdated, RowsValue, RowsSampled,
    ModificationCounter, UnfilteredRows, HasFilter, FilterDefinition,
    IsAutoCreated, IsNoRecompute
)
SELECT
    st.name,
    st.stats_id,
    LeadingColumn = (
        SELECT TOP (1) c.name
          FROM __TARGET_DB__.sys.stats_columns AS sc
         INNER JOIN __TARGET_DB__.sys.columns AS c
            ON c.object_id = sc.object_id
           AND c.column_id = sc.column_id
         WHERE sc.object_id = st.object_id
           AND sc.stats_id = st.stats_id
         ORDER BY sc.stats_column_id
    ),
    __STATS_LAST_UPDATED__,
    __STATS_ROWS__,
    __STATS_SAMPLED__,
    __STATS_MOD__,
    __STATS_UNFILTERED__,
    st.has_filter,
    st.filter_definition,
    st.auto_created,
    st.no_recompute
  FROM __TARGET_DB__.sys.stats AS st
  __STATS_FROM__
 WHERE st.object_id = @ObjectId

INSERT #TableTriggers
(
    TriggerName, TriggerType, IsInsteadOf, IsDisabled, IsNotForReplication,
    CreateDate, ModifyDate
)
SELECT
    tr.name,
    tr.type_desc,
    tr.is_instead_of_trigger,
    tr.is_disabled,
    tr.is_not_for_replication,
    tr.create_date,
    tr.modify_date
  FROM __TARGET_DB__.sys.triggers AS tr
 WHERE tr.parent_id = @ObjectId
   AND tr.parent_class = 1

INSERT #TableMissingIndexes
(
    Impact, UniqueCompiles, UserSeeks, UserScans, AvgTotalUserCost, AvgUserImpact,
    EqualityColumns, InequalityColumns, IncludedColumns
)
SELECT
    Impact = CONVERT(decimal(18, 2), gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans)),
    gs.unique_compiles,
    gs.user_seeks,
    gs.user_scans,
    gs.avg_total_user_cost,
    gs.avg_user_impact,
    d.equality_columns,
    d.inequality_columns,
    d.included_columns
  FROM sys.dm_db_missing_index_groups AS g
 INNER JOIN sys.dm_db_missing_index_group_stats AS gs
    ON gs.group_handle = g.index_group_handle
 INNER JOIN sys.dm_db_missing_index_details AS d
    ON d.index_handle = g.index_handle
 WHERE d.database_id = @TargetDatabaseId
   AND d.object_id = @ObjectId
'

IF @MajorVersion >= 12
    SET @Sql = REPLACE(@Sql, N'__MEMORY_OPT__', N't.is_memory_optimized')
ELSE
    SET @Sql = REPLACE(@Sql, N'__MEMORY_OPT__', N'CONVERT(bit, 0)')

IF @MajorVersion >= 13
BEGIN
    SET @Sql = REPLACE(@Sql, N'__TEMPORAL_TYPE__', N't.temporal_type_desc')
    SET @Sql = REPLACE(@Sql, N'__HISTORY_TABLE__', N'(
        SELECT QUOTENAME(hs.name) + ''.'' + QUOTENAME(ht.name)
          FROM __TARGET_DB__.sys.tables AS ht
         INNER JOIN __TARGET_DB__.sys.schemas AS hs
            ON hs.schema_id = ht.schema_id
         WHERE ht.object_id = t.history_table_id
    )')
END
ELSE
BEGIN
    SET @Sql = REPLACE(@Sql, N'__TEMPORAL_TYPE__', N'CONVERT(nvarchar(60), NULL)')
    SET @Sql = REPLACE(@Sql, N'__HISTORY_TABLE__', N'CONVERT(nvarchar(260), NULL)')
END

IF @MajorVersion >= 11
BEGIN
    SET @Sql = REPLACE(@Sql, N'__STATS_LAST_UPDATED__', N'sp.last_updated')
    SET @Sql = REPLACE(@Sql, N'__STATS_ROWS__', N'sp.rows')
    SET @Sql = REPLACE(@Sql, N'__STATS_SAMPLED__', N'sp.rows_sampled')
    SET @Sql = REPLACE(@Sql, N'__STATS_MOD__', N'sp.modification_counter')
    SET @Sql = REPLACE(@Sql, N'__STATS_UNFILTERED__', N'sp.unfiltered_rows')
    SET @Sql = REPLACE(@Sql, N'__STATS_FROM__', N'CROSS APPLY __TARGET_DB__.sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp')
END
ELSE
BEGIN
    SET @Sql = REPLACE(@Sql, N'__STATS_LAST_UPDATED__', N'STATS_DATE(st.object_id, st.stats_id)')
    SET @Sql = REPLACE(@Sql, N'__STATS_ROWS__', N'CONVERT(bigint, NULL)')
    SET @Sql = REPLACE(@Sql, N'__STATS_SAMPLED__', N'CONVERT(bigint, NULL)')
    SET @Sql = REPLACE(@Sql, N'__STATS_MOD__', N'CONVERT(bigint, NULL)')
    SET @Sql = REPLACE(@Sql, N'__STATS_UNFILTERED__', N'CONVERT(bigint, NULL)')
    SET @Sql = REPLACE(@Sql, N'__STATS_FROM__', N'')
END

SET @Sql = REPLACE(@Sql, N'__TARGET_DB__', @QuotedDatabase)

EXEC sys.sp_executesql
    @Sql,
    N'@ServerName sysname, @TargetDatabase sysname, @TargetDatabaseId int, @ObjectId int, @CaptureDate datetime',
    @ServerName       = @ServerName,
    @TargetDatabase   = @TargetDatabase,
    @TargetDatabaseId = @TargetDatabaseId,
    @ObjectId         = @ObjectId,
    @CaptureDate      = @CaptureDate

SELECT
    ServerName,
    DatabaseName,
    SchemaName,
    TableName,
    ObjectID,
    CreateDate,
    ModifyDate,
    LockEscalation,
    TextInRowLimit,
    LargeValueTypesOutOfRow,
    IsReplicated,
    IsMemoryOptimized,
    TemporalType,
    HistoryTable,
    DataFilegroup,
    LobFilegroup,
    HasAfterTrigger,
    HasInsteadOfTrigger,
    CaptureDate
  FROM #TableIdentity

SELECT
    RowCountValue AS [RowCount],
    ReservedKB,
    DataKB,
    IndexKB,
    UnusedKB,
    ReservedMB,
    DataMB,
    IndexMB,
    UnusedMB,
    ReservedPages,
    UsedPages,
    DataPages,
    PartitionCount,
    StorageShape,
    ClusteredIndexName,
    ClusteredKeyColumns
  FROM #TableSize

SELECT
    IndexID,
    IndexName,
    IndexType,
    IsClustered,
    IsUnique,
    IsPrimaryKey,
    IsUniqueConstraint,
    IsDisabled,
    FillFactorValue AS [FillFactor],
    FilterDefinition,
    KeyColumns,
    IncludedColumns,
    DataSpaceName,
    CompressionDesc,
    PartitionCount,
    RowCountValue AS [RowCount],
    ReservedPages,
    UsedPages,
    SizeMB,
    UserSeeks,
    UserScans,
    UserLookups,
    UserUpdates,
    LastUserSeek,
    LastUserScan,
    LastUserLookup,
    LastUserUpdate,
    AvgFragmentationPct,
    FragmentedPageCount,
    IndexDepth
  FROM #TableIndexes
 ORDER BY IsClustered DESC, IndexID

SELECT
    ColumnID,
    ColumnName,
    DataType,
    MaxLength,
    PrecisionValue AS [Precision],
    ScaleValue AS [Scale],
    IsNullable,
    IsIdentity,
    IsComputed,
    IsRowGuidCol,
    CollationName,
    DefaultDefinition,
    ComputedDefinition
  FROM #TableColumns
 ORDER BY ColumnID

SELECT
    ConstraintType,
    ConstraintName,
    ColumnsList,
    ReferencedObject,
    ReferencedColumns,
    CheckDefinition,
    DeleteAction,
    UpdateAction,
    IsDisabled,
    IsNotTrusted
  FROM #TableConstraints
 ORDER BY
    CASE ConstraintType
        WHEN 'PRIMARY KEY' THEN 1
        WHEN 'UNIQUE' THEN 2
        WHEN 'FOREIGN KEY' THEN 3
        WHEN 'CHECK' THEN 4
        ELSE 5
    END,
    ConstraintName

SELECT
    StatsName,
    StatsID,
    LeadingColumn,
    LastUpdated,
    RowsValue AS [Rows],
    RowsSampled,
    ModificationCounter,
    UnfilteredRows,
    HasFilter,
    FilterDefinition,
    IsAutoCreated,
    IsNoRecompute
  FROM #TableStatistics
 ORDER BY StatsID

SELECT
    TriggerName,
    TriggerType,
    IsInsteadOf,
    IsDisabled,
    IsNotForReplication,
    CreateDate,
    ModifyDate
  FROM #TableTriggers
 ORDER BY TriggerName

SELECT
    Impact,
    UniqueCompiles,
    UserSeeks,
    UserScans,
    AvgTotalUserCost,
    AvgUserImpact,
    EqualityColumns,
    InequalityColumns,
    IncludedColumns
  FROM #TableMissingIndexes
 ORDER BY Impact DESC

GO
