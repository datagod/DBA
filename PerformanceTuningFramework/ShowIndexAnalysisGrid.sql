/*
  ShowIndexAnalysisGrid.sql
  Performance Tuning Framework

  Requires: dbo.IndexAnalysis (run IndexAnalysis.sql), then AnalyzeIndexes captures.

  Deploy to the tool database, then execute:
    EXEC dbo.ShowIndexAnalysisGrid @TargetDatabase = N'YourDatabase'
    EXEC dbo.ShowIndexAnalysisGrid
         @TargetDatabase = N'YourDatabase',
         @UnusedOnly     = 1,
         @SortBy         = N'SIZE',
         @TopN           = 50
    EXEC dbo.ShowIndexAnalysisGrid
         @TargetDatabase = N'YourDatabase',
         @UsageCategory  = 'Write-heavy',
         @ReturnSummary  = 1,
         @ReturnDetail   = 1

  Grid-friendly companion to ShowIndexUsageReport (PRINT / fixed-width text).
  Returns typed columns for the SSMS Results grid, with optional summary + detail
  result sets, filters, and any AnalysisRunID (not only the latest).
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowIndexAnalysisGrid') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowIndexAnalysisGrid'
    DROP PROCEDURE dbo.ShowIndexAnalysisGrid
END
GO

PRINT 'Creating: ShowIndexAnalysisGrid'
GO

CREATE PROCEDURE dbo.ShowIndexAnalysisGrid
(
    @TargetDatabase   sysname          = NULL,          -- default DB_NAME(); filter IndexAnalysis.DatabaseName
    @AnalysisRunID    uniqueidentifier = NULL,          -- default: latest run for that database
    @SchemaFilter     sysname          = N'%',
    @TableFilter      sysname          = N'%',
    @IndexFilter      sysname          = N'%',
    @UsageCategory    varchar(40)      = NULL,          -- NULL=all; or Disabled|Heap|No usage stats since restart|Unused (writes only)|Write-heavy|No activity|Active
    @UnusedOnly       bit              = 0,             -- TotalReads=0 AND UserUpdates>0
    @WriteHeavyOnly   bit              = 0,
    @IncludeHeaps     bit              = 1,
    @TopN             int              = 200,
    @SortBy           varchar(20)      = N'READS',      -- READS|WRITES|SIZE|OBJECT|LAST_USE|SEEKS|SCANS
    @ReturnSummary    bit              = 1,             -- result set 1: one-row summary
    @ReturnDetail     bit              = 1              -- result set 2: grid detail
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: September 22, 2026
-- Author:       Bill McEvoy
-- Description:  Returns IndexAnalysis captures as SSMS Results-grid friendly result sets
--               (summary + typed detail). Complements ShowIndexUsageReport, which prints a
--               fixed-width text report. Supports any AnalysisRunID and the same usage
--               category / unused / write-heavy logic as vIndexAnalysis.
---------------------------------------------------------------------------------------------------
-- Version:      1.0
-- Date Revised: September 22, 2026
-- Author:       Bill McEvoy
-- Reason:       Initial release.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @SortByUpper     varchar(20),
    @CaptureDate     datetime,
    @ServerName      sysname,
    @DatabaseName    sysname,
    @RunIdText       varchar(36)

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

IF @SchemaFilter IS NULL OR @SchemaFilter = N''
    SET @SchemaFilter = N'%'

IF @TableFilter IS NULL OR @TableFilter = N''
    SET @TableFilter = N'%'

IF @IndexFilter IS NULL OR @IndexFilter = N''
    SET @IndexFilter = N'%'

IF @TopN IS NULL OR @TopN < 1
    SET @TopN = 200

SET @SortByUpper = UPPER(LTRIM(RTRIM(ISNULL(@SortBy, N'READS'))))
IF @SortByUpper NOT IN ('READS', 'WRITES', 'SIZE', 'OBJECT', 'LAST_USE', 'SEEKS', 'SCANS')
    SET @SortByUpper = 'READS'

IF OBJECT_ID('dbo.IndexAnalysis') IS NULL
BEGIN
    RAISERROR('Table dbo.IndexAnalysis does not exist. Run IndexAnalysis.sql in this database first.', 16, 1)
    RETURN
END

IF @AnalysisRunID IS NULL
BEGIN
    SELECT TOP (1)
        @AnalysisRunID = ia.AnalysisRunID,
        @CaptureDate   = ia.CaptureDate,
        @ServerName    = ia.ServerName,
        @DatabaseName  = ia.DatabaseName
      FROM dbo.IndexAnalysis AS ia
     WHERE ia.DatabaseName = @TargetDatabase
     ORDER BY ia.CaptureDate DESC, ia.AnalysisRunID DESC
END
ELSE
BEGIN
    SELECT TOP (1)
        @CaptureDate   = ia.CaptureDate,
        @ServerName    = ia.ServerName,
        @DatabaseName  = ia.DatabaseName,
        @TargetDatabase = ia.DatabaseName
      FROM dbo.IndexAnalysis AS ia
     WHERE ia.AnalysisRunID = @AnalysisRunID
END

IF @AnalysisRunID IS NULL
BEGIN
    RAISERROR('No IndexAnalysis data found for database ''%s''.', 16, 1, @TargetDatabase)
    RETURN
END

IF @DatabaseName IS NULL
BEGIN
    SET @RunIdText = CONVERT(varchar(36), @AnalysisRunID)
    RAISERROR('No IndexAnalysis data found for AnalysisRunID %s.', 16, 1, @RunIdText)
    RETURN
END

IF OBJECT_ID('tempdb..#IndexGrid') IS NOT NULL
    DROP TABLE #IndexGrid

CREATE TABLE #IndexGrid
(
    SchemaName         sysname          NOT NULL,
    TableName          sysname          NOT NULL,
    ObjectName         nvarchar(517)    NOT NULL,
    DisplayIndexName   sysname          NOT NULL,
    IndexID            int              NOT NULL,
    IndexTypeLabel     varchar(4)       NOT NULL,
    IndexTypeDesc      nvarchar(60)     NOT NULL,
    KeyColumns         nvarchar(2000)   NULL,
    IncludedColumns    nvarchar(2000)   NULL,
    IsFiltered         bit              NOT NULL,
    FilterDefinition   nvarchar(max)    NULL,
    IsUnique           bit              NOT NULL,
    IsPrimaryKey       bit              NOT NULL,
    IsDisabled         bit              NOT NULL,
    [FillFactor]       tinyint          NULL,
    CompressionDesc    nvarchar(60)     NULL,
    UserSeeks          bigint           NOT NULL,
    UserScans          bigint           NOT NULL,
    UserLookups        bigint           NOT NULL,
    UserUpdates        bigint           NOT NULL,
    TotalReads         bigint           NOT NULL,
    ReadWriteRatio     decimal(18, 4)   NULL,
    ReadWriteRatioText varchar(32)      NOT NULL,
    RecordCount        bigint           NOT NULL,
    SizeMB             decimal(12, 1)   NOT NULL,
    LastUserSeek       datetime         NULL,
    LastUserScan       datetime         NULL,
    LastUserLookup     datetime         NULL,
    LastUserUpdate     datetime         NULL,
    LastUsedDate       datetime         NULL,
    HasUsageStats      bit              NOT NULL,
    UsageCategory      varchar(40)      NOT NULL,
    IsUnused           bit              NOT NULL,
    IsWriteHeavy       bit              NOT NULL,
    IsHeap             bit              NOT NULL,
    AnalysisRunID      uniqueidentifier NOT NULL,
    CaptureDate        datetime         NOT NULL,
    DatabaseName       sysname          NOT NULL,
    ServerName         sysname          NOT NULL
)

INSERT INTO #IndexGrid
(
    SchemaName,
    TableName,
    ObjectName,
    DisplayIndexName,
    IndexID,
    IndexTypeLabel,
    IndexTypeDesc,
    KeyColumns,
    IncludedColumns,
    IsFiltered,
    FilterDefinition,
    IsUnique,
    IsPrimaryKey,
    IsDisabled,
    [FillFactor],
    CompressionDesc,
    UserSeeks,
    UserScans,
    UserLookups,
    UserUpdates,
    TotalReads,
    ReadWriteRatio,
    ReadWriteRatioText,
    RecordCount,
    SizeMB,
    LastUserSeek,
    LastUserScan,
    LastUserLookup,
    LastUserUpdate,
    LastUsedDate,
    HasUsageStats,
    UsageCategory,
    IsUnused,
    IsWriteHeavy,
    IsHeap,
    AnalysisRunID,
    CaptureDate,
    DatabaseName,
    ServerName
)
SELECT
    ia.SchemaName,
    ia.TableName,
    ObjectName = QUOTENAME(ia.SchemaName) + N'.' + QUOTENAME(ia.TableName),
    DisplayIndexName = CASE
                           WHEN ia.IndexID = 0 THEN N'(HEAP)'
                           WHEN ia.IndexName IS NULL OR LTRIM(RTRIM(ia.IndexName)) = N'' THEN N'(unnamed)'
                           ELSE ia.IndexName
                       END,
    ia.IndexID,
    IndexTypeLabel = CASE
                         WHEN ia.IndexID = 0 THEN 'HEAP'
                         WHEN ia.IndexTypeDesc = 'CLUSTERED' THEN 'CL '
                         WHEN ia.IndexTypeDesc = 'NONCLUSTERED' THEN 'NC '
                         WHEN ia.IndexTypeDesc = 'XML' THEN 'XML'
                         WHEN ia.IndexTypeDesc LIKE 'CLUSTERED%COLUMNSTORE%' THEN 'CC '
                         WHEN ia.IndexTypeDesc LIKE '%COLUMNSTORE%' THEN 'CS '
                         ELSE LEFT(REPLACE(ia.IndexTypeDesc, ' ', ''), 3)
                     END,
    ia.IndexTypeDesc,
    ia.KeyColumns,
    ia.IncludedColumns,
    ia.IsFiltered,
    ia.FilterDefinition,
    ia.IsUnique,
    ia.IsPrimaryKey,
    ia.IsDisabled,
    ia.[FillFactor],
    ia.CompressionDesc,
    ia.UserSeeks,
    ia.UserScans,
    ia.UserLookups,
    ia.UserUpdates,
    ia.TotalReads,
    ia.ReadWriteRatio,
    ReadWriteRatioText = CASE
                             WHEN ia.UserUpdates = 0 AND ia.TotalReads = 0 THEN 'n/a'
                             WHEN ia.UserUpdates = 0 THEN 'inf'
                             ELSE CONVERT(varchar(32), ia.ReadWriteRatio)
                         END,
    ia.RecordCount,
    ia.SizeMB,
    ia.LastUserSeek,
    ia.LastUserScan,
    ia.LastUserLookup,
    ia.LastUserUpdate,
    LastUsedDate = (
        SELECT MAX(v.LastUsed)
          FROM (VALUES
                    (ia.LastUserSeek),
                    (ia.LastUserScan),
                    (ia.LastUserLookup),
                    (ia.LastUserUpdate)
               ) AS v(LastUsed)
         WHERE v.LastUsed IS NOT NULL),
    ia.HasUsageStats,
    UsageCategory = CASE
                        WHEN ia.IsDisabled = 1 THEN 'Disabled'
                        WHEN ia.IndexID = 0 THEN 'Heap'
                        WHEN ia.HasUsageStats = 0 THEN 'No usage stats since restart'
                        WHEN ia.TotalReads = 0 AND ia.UserUpdates > 0 THEN 'Unused (writes only)'
                        WHEN ia.TotalReads > 0 AND ia.UserUpdates > (ia.TotalReads * 10) THEN 'Write-heavy'
                        WHEN ia.TotalReads = 0 AND ia.UserUpdates = 0 THEN 'No activity'
                        ELSE 'Active'
                    END,
    IsUnused = CASE
                   WHEN ia.TotalReads = 0 AND ia.UserUpdates > 0 THEN CAST(1 AS bit)
                   ELSE CAST(0 AS bit)
               END,
    IsWriteHeavy = CASE
                       WHEN ia.TotalReads > 0 AND ia.UserUpdates > (ia.TotalReads * 10) THEN CAST(1 AS bit)
                       ELSE CAST(0 AS bit)
                   END,
    IsHeap = CASE WHEN ia.IndexID = 0 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,
    ia.AnalysisRunID,
    ia.CaptureDate,
    ia.DatabaseName,
    ia.ServerName
  FROM dbo.IndexAnalysis AS ia
 WHERE ia.AnalysisRunID = @AnalysisRunID
   AND ia.DatabaseName = @DatabaseName
   AND ia.SchemaName LIKE @SchemaFilter
   AND ia.TableName LIKE @TableFilter
   AND ISNULL(ia.IndexName, CASE WHEN ia.IndexID = 0 THEN N'(HEAP)' ELSE N'(unnamed)' END) LIKE @IndexFilter
   AND (@IncludeHeaps = 1 OR ia.IndexID <> 0)
   AND (@UnusedOnly = 0 OR (ia.TotalReads = 0 AND ia.UserUpdates > 0))
   AND (@WriteHeavyOnly = 0 OR (ia.TotalReads > 0 AND ia.UserUpdates > (ia.TotalReads * 10)))

IF @UsageCategory IS NOT NULL AND LTRIM(RTRIM(@UsageCategory)) <> ''
BEGIN
    DELETE FROM #IndexGrid
     WHERE UsageCategory <> @UsageCategory
END

IF NOT EXISTS (SELECT 1 FROM #IndexGrid)
BEGIN
    SET @RunIdText = CONVERT(varchar(36), @AnalysisRunID)
    RAISERROR('No IndexAnalysis rows matched AnalysisRunID %s with the requested filters.', 16, 1, @RunIdText)
    RETURN
END

IF @ReturnSummary = 1
BEGIN
    SELECT
        AnalysisRunID     = @AnalysisRunID,
        CaptureDate       = @CaptureDate,
        ServerName        = @ServerName,
        DatabaseName      = @DatabaseName,
        TotalIndexes      = COUNT(*),
        UnusedIndexes     = SUM(CASE WHEN IsUnused = 1 THEN 1 ELSE 0 END),
        WriteHeavyIndexes = SUM(CASE WHEN IsWriteHeavy = 1 THEN 1 ELSE 0 END),
        DisabledIndexes   = SUM(CASE WHEN IsDisabled = 1 THEN 1 ELSE 0 END),
        NeverSampled      = SUM(CASE WHEN HasUsageStats = 0 THEN 1 ELSE 0 END),
        HeapCount         = SUM(CASE WHEN IsHeap = 1 THEN 1 ELSE 0 END),
        TotalSizeMB       = SUM(SizeMB),
        SortByUsed        = @SortByUpper
      FROM #IndexGrid
END

IF @ReturnDetail = 1
BEGIN
    SELECT TOP (@TopN)
        g.SchemaName,
        g.TableName,
        g.ObjectName,
        g.DisplayIndexName,
        g.IndexID,
        g.IndexTypeLabel,
        g.IndexTypeDesc,
        g.KeyColumns,
        g.IncludedColumns,
        g.IsFiltered,
        g.FilterDefinition,
        g.IsUnique,
        g.IsPrimaryKey,
        g.IsDisabled,
        g.[FillFactor],
        g.CompressionDesc,
        g.UserSeeks,
        g.UserScans,
        g.UserLookups,
        g.UserUpdates,
        g.TotalReads,
        g.ReadWriteRatio,
        g.ReadWriteRatioText,
        g.RecordCount,
        g.SizeMB,
        g.LastUserSeek,
        g.LastUserScan,
        g.LastUserLookup,
        g.LastUserUpdate,
        g.LastUsedDate,
        g.HasUsageStats,
        g.UsageCategory,
        g.IsUnused,
        g.IsWriteHeavy,
        g.IsHeap,
        g.AnalysisRunID,
        g.CaptureDate,
        g.DatabaseName,
        g.ServerName
      FROM #IndexGrid AS g
     ORDER BY
        CASE WHEN @SortByUpper = 'OBJECT' THEN g.SchemaName END ASC,
        CASE WHEN @SortByUpper = 'OBJECT' THEN g.TableName END ASC,
        CASE WHEN @SortByUpper = 'OBJECT' THEN g.DisplayIndexName END ASC,
        CASE WHEN @SortByUpper = 'READS' THEN g.TotalReads END DESC,
        CASE WHEN @SortByUpper = 'WRITES' THEN g.UserUpdates END DESC,
        CASE WHEN @SortByUpper = 'SIZE' THEN g.SizeMB END DESC,
        CASE WHEN @SortByUpper = 'LAST_USE' THEN g.LastUsedDate END DESC,
        CASE WHEN @SortByUpper = 'SEEKS' THEN g.UserSeeks END DESC,
        CASE WHEN @SortByUpper = 'SCANS' THEN g.UserScans END DESC,
        g.SchemaName,
        g.TableName,
        g.DisplayIndexName
END

GO

PRINT 'Procedure created successfully.'
GO
