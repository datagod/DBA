
/*
  CheckForHeaps.sql
  Performance Tuning Framework

  Lightweight heap scan using catalog views only (no dm_db_index_physical_stats).
  Requires SQL Server 2008 (10.x) or later; target database compatibility level 100+.

  Deploy to the tool database, then execute:
    EXEC dbo.CheckForHeaps @TargetDatabase = N'YourDatabase'

  For full DMV analysis and clustered-index recommendations, use dbo.ShowHeaps.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.CheckForHeaps') IS NOT NULL
BEGIN
    PRINT 'Dropping: CheckForHeaps'
    DROP PROCEDURE dbo.CheckForHeaps
END
GO

PRINT 'Creating: CheckForHeaps'
GO

CREATE PROCEDURE dbo.CheckForHeaps
(
    @TargetDatabase   sysname      = NULL,
    @SchemaFilter     sysname      = '%',
    @TableFilter      sysname      = '%',
    @MinRows          bigint       = 0,
    @SortBy           varchar(10)  = 'SIZE',
    @ReturnSummary    bit          = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 23, 2026
-- Author:       Bill McEvoy
-- Description:  Lightweight examination of user tables and indexes to find heaps in a target
--               database using catalog views and optional usage stats.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion         tinyint,
    @CompatibilityLevel   int,
    @TargetDatabaseId     int,
    @QuotedDatabase       nvarchar(260),
    @Sql                  nvarchar(max),
    @ClusteredTypeFilter  nvarchar(40),
    @SortByUpper          varchar(10),
    @HeapCount            int,
    @TotalRows            bigint,
    @TotalSizeMB          decimal(18, 1)

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)
SET @QuotedDatabase   = QUOTENAME(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

SET @SortByUpper = UPPER(ISNULL(@SortBy, 'SIZE'))
IF @SortByUpper NOT IN ('SIZE', 'ROWS', 'NC', 'SCANS', 'OBJECT')
    SET @SortByUpper = 'SIZE'

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 10
BEGIN
    RAISERROR('CheckForHeaps requires SQL Server 2008 (10.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SELECT @CompatibilityLevel = d.compatibility_level
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId

IF ISNULL(@CompatibilityLevel, 0) < 100
BEGIN
    RAISERROR('Target database ''%s'' compatibility level %d is below 100 (SQL Server 2008).', 16, 1, @TargetDatabase, ISNULL(@CompatibilityLevel, 0))
    RETURN
END

IF @CompatibilityLevel >= 110
    SET @ClusteredTypeFilter = N'ci.type IN (1, 5)'
ELSE
    SET @ClusteredTypeFilter = N'ci.type = 1'

IF OBJECT_ID('tempdb..#Heaps') IS NOT NULL
    DROP TABLE #Heaps

CREATE TABLE #Heaps
(
    SchemaName             sysname        NOT NULL,
    TableName              sysname        NOT NULL,
    ObjectID               int            NOT NULL,
    RowCount               bigint         NOT NULL,
    SizeMB                 decimal(12, 1) NOT NULL,
    NonClusteredIndexCount int            NOT NULL,
    HasPrimaryKey          bit            NOT NULL,
    PrimaryKeyIsClustered  bit            NOT NULL,
    HeapScans              bigint         NOT NULL,
    HeapUpdates            bigint         NOT NULL,
    HasUsageStats          bit            NOT NULL
)

SET @Sql = N'
INSERT INTO #Heaps
(
    SchemaName,
    TableName,
    ObjectID,
    RowCount,
    SizeMB,
    NonClusteredIndexCount,
    HasPrimaryKey,
    PrimaryKeyIsClustered,
    HeapScans,
    HeapUpdates,
    HasUsageStats
)
SELECT
    s.name,
    o.name,
    o.object_id,
    ISNULL(sz.RowCount, 0),
    ISNULL(sz.SizeMB, 0),
    ISNULL(nc.NonClusteredIndexCount, 0),
    ISNULL(pk.HasPrimaryKey, 0),
    ISNULL(pk.PrimaryKeyIsClustered, 0),
    ISNULL(us.user_scans, 0),
    ISNULL(us.user_updates, 0),
    CASE WHEN us.database_id IS NULL THEN 0 ELSE 1 END
  FROM ' + @QuotedDatabase + N'.sys.objects AS o
 INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.indexes AS hi
    ON hi.object_id = o.object_id
   AND hi.index_id = 0
 WHERE o.type = ''U''
   AND s.name LIKE @SchemaFilter
   AND o.name LIKE @TableFilter
   AND NOT EXISTS (
       SELECT 1
         FROM ' + @QuotedDatabase + N'.sys.indexes AS ci
        WHERE ci.object_id = o.object_id
          AND ci.index_id > 0
          AND ' + @ClusteredTypeFilter + N'
   )
  LEFT JOIN (
      SELECT
          p.object_id,
          RowCount = SUM(p.rows),
          SizeMB = SUM(a.total_pages) * 8.0 / 1024.0
        FROM ' + @QuotedDatabase + N'.sys.partitions AS p
       INNER JOIN ' + @QuotedDatabase + N'.sys.allocation_units AS a
          ON p.partition_id = a.container_id
       WHERE p.index_id = 0
       GROUP BY p.object_id
  ) AS sz
    ON sz.object_id = o.object_id
  LEFT JOIN (
      SELECT
          i.object_id,
          NonClusteredIndexCount = COUNT(*)
        FROM ' + @QuotedDatabase + N'.sys.indexes AS i
       WHERE i.index_id > 0
         AND i.type = 2
         AND i.is_hypothetical = 0
       GROUP BY i.object_id
  ) AS nc
    ON nc.object_id = o.object_id
  LEFT JOIN (
      SELECT
          i.object_id,
          HasPrimaryKey = 1,
          PrimaryKeyIsClustered = CASE WHEN i.type IN (1, 5) THEN 1 ELSE 0 END
        FROM ' + @QuotedDatabase + N'.sys.indexes AS i
       WHERE i.is_primary_key = 1
  ) AS pk
    ON pk.object_id = o.object_id
  LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = @TargetDatabaseId
   AND us.object_id = o.object_id
   AND us.index_id = 0
 WHERE ISNULL(sz.RowCount, 0) >= @MinRows'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int, @SchemaFilter sysname, @TableFilter sysname, @MinRows bigint',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @MinRows = @MinRows

SELECT
    @HeapCount = COUNT(*),
    @TotalRows = ISNULL(SUM(RowCount), 0),
    @TotalSizeMB = ISNULL(SUM(SizeMB), 0)
  FROM #Heaps

IF @ReturnSummary = 1
BEGIN
    SELECT
        DatabaseName = @TargetDatabase,
        CompatibilityLevel = @CompatibilityLevel,
        HeapTableCount = @HeapCount,
        TotalRows = @TotalRows,
        TotalSizeMB = @TotalSizeMB,
        SchemaFilter = @SchemaFilter,
        TableFilter = @TableFilter,
        MinRows = @MinRows,
        SortBy = @SortByUpper,
        Note = 'Catalog-only scan. Use dbo.ShowHeaps for fragmentation, missing-index, and clustered-index recommendations.'
END

SELECT
    SchemaName,
    TableName,
    ObjectID,
    RowCount,
    SizeMB,
    NonClusteredIndexCount,
    HasPrimaryKey,
    PrimaryKeyIsClustered,
    HeapScans,
    HeapUpdates,
    HasUsageStats
  FROM #Heaps
 ORDER BY
    CASE WHEN @SortByUpper = 'ROWS'  THEN RowCount END DESC,
    CASE WHEN @SortByUpper = 'SIZE'  THEN SizeMB END DESC,
    CASE WHEN @SortByUpper = 'NC'    THEN NonClusteredIndexCount END DESC,
    CASE WHEN @SortByUpper = 'SCANS' THEN HeapScans END DESC,
    CASE WHEN @SortByUpper = 'OBJECT' THEN CHECKSUM(SchemaName, TableName) END,
    SchemaName,
    TableName

GO

IF OBJECT_ID('dbo.CheckForHeaps') IS NOT NULL
    PRINT 'Procedure created.'
ELSE
    PRINT 'Procedure NOT created.'
GO