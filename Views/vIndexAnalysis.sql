
/*
  vIndexAnalysis.sql

  Requires: dbo.IndexAnalysis (run PerformanceTuningFramework\IndexAnalysis.sql first)

  Deploy to the DBA tool database, then query:
    SELECT * FROM dbo.vIndexAnalysis WHERE DatabaseName = N'YourDB' AND IsLatestRun = 1
    SELECT IndexDescription, TotalReads, UserUpdates, SizeMB FROM dbo.vIndexAnalysis WHERE IsUnused = 1
*/

USE DBA
GO

IF OBJECT_ID('dbo.vIndexAnalysis') IS NOT NULL
BEGIN
    PRINT 'Dropping view: vIndexAnalysis'
    DROP VIEW dbo.vIndexAnalysis
END
GO

PRINT 'Creating view: vIndexAnalysis'
GO

CREATE VIEW dbo.vIndexAnalysis
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 28, 2026
-- Author:       Bill McEvoy
-- Description:  Human-friendly index descriptions and usage context from captured IndexAnalysis rows.
---------------------------------------------------------------------------------------------------
WITH RankedRuns AS
(
    SELECT
        ia.IndexAnalysisID,
        RunRank = DENSE_RANK() OVER (
            PARTITION BY ia.DatabaseName
            ORDER BY ia.CaptureDate DESC, ia.AnalysisRunID DESC)
      FROM dbo.IndexAnalysis AS ia
)
SELECT
    ia.IndexAnalysisID,
    ia.AnalysisRunID,
    ia.CaptureDate,
    ia.ServerName,
    ia.DatabaseName,
    ia.SchemaName,
    ia.TableName,
    ia.IndexName,
    ia.ObjectID,
    ia.IndexID,

    QualifiedTableName = QUOTENAME(ia.DatabaseName) + N'.'
                       + QUOTENAME(ia.SchemaName) + N'.'
                       + QUOTENAME(ia.TableName),

    ObjectName = QUOTENAME(ia.SchemaName) + N'.' + QUOTENAME(ia.TableName),

    DisplayIndexName = CASE
                           WHEN ia.IndexID = 0 THEN N'(HEAP)'
                           WHEN ia.IndexName IS NULL OR LTRIM(RTRIM(ia.IndexName)) = N'' THEN N'(unnamed)'
                           ELSE ia.IndexName
                       END,

    IndexTypeDesc = ia.IndexTypeDesc,

    IndexTypeLabel = CASE
                         WHEN ia.IndexID = 0 THEN 'HEAP'
                         WHEN ia.IndexTypeDesc = 'CLUSTERED' THEN 'CL '
                         WHEN ia.IndexTypeDesc = 'NONCLUSTERED' THEN 'NC '
                         WHEN ia.IndexTypeDesc = 'XML' THEN 'XML'
                         WHEN ia.IndexTypeDesc LIKE 'CLUSTERED%COLUMNSTORE%' THEN 'CC '
                         WHEN ia.IndexTypeDesc LIKE '%COLUMNSTORE%' THEN 'CS '
                         ELSE LEFT(REPLACE(ia.IndexTypeDesc, ' ', ''), 3)
                     END,

    ia.KeyColumns,
    ia.IncludedColumns,
    ia.FilterDefinition,
    ia.IsFiltered,
    ia.IsUnique,
    ia.IsPrimaryKey,
    ia.IsDisabled,
    ia.[FillFactor],
    ia.CompressionDesc,

    IndexDescription = CASE
        WHEN ia.IndexID = 0 THEN
            N'HEAP on ' + QUOTENAME(ia.SchemaName) + N'.' + QUOTENAME(ia.TableName)
        ELSE
            UPPER(ia.IndexTypeDesc)
            + CASE WHEN ia.IsUnique = 1 THEN N' UNIQUE' ELSE N'' END
            + CASE WHEN ia.IsPrimaryKey = 1 THEN N' PRIMARY KEY' ELSE N'' END
            + CASE WHEN ia.IsDisabled = 1 THEN N' (DISABLED)' ELSE N'' END
            + N' on ' + QUOTENAME(ia.SchemaName) + N'.' + QUOTENAME(ia.TableName)
            + N' (' + ISNULL(ia.KeyColumns, N'') + N')'
            + CASE
                  WHEN ia.IncludedColumns IS NOT NULL AND LTRIM(RTRIM(ia.IncludedColumns)) <> N''
                      THEN N' INCLUDE (' + ia.IncludedColumns + N')'
                  ELSE N''
              END
            + CASE
                  WHEN ia.IsFiltered = 1
                   AND ia.FilterDefinition IS NOT NULL
                   AND LTRIM(RTRIM(ia.FilterDefinition)) <> N''
                      THEN N' WHERE ' + ia.FilterDefinition
                  ELSE N''
              END
            + CASE
                  WHEN ia.CompressionDesc IS NOT NULL
                   AND ia.CompressionDesc NOT IN (N'NONE', N'')
                      THEN N' WITH (' + ia.CompressionDesc + N')'
                  ELSE N''
              END
            + CASE
                  WHEN ia.[FillFactor] IS NOT NULL AND ia.[FillFactor] > 0 AND ia.[FillFactor] < 100
                      THEN N' FILLFACTOR = ' + CAST(ia.[FillFactor] AS nvarchar(3))
                  ELSE N''
              END
    END,

    IndexSummary = CASE
        WHEN ia.IndexID = 0 THEN
            N'Heap table with no clustered index'
        ELSE
            ISNULL(ia.IndexName, N'(unnamed)')
            + N' | '
            + ia.IndexTypeDesc
            + CASE WHEN ia.IsPrimaryKey = 1 THEN N' PK' ELSE N'' END
            + CASE WHEN ia.IsUnique = 1 AND ia.IsPrimaryKey = 0 THEN N' UQ' ELSE N'' END
            + N' | keys: ' + ISNULL(NULLIF(LTRIM(RTRIM(ia.KeyColumns)), N''), N'(none)')
            + CASE
                  WHEN ia.IncludedColumns IS NOT NULL AND LTRIM(RTRIM(ia.IncludedColumns)) <> N''
                      THEN N' | includes: ' + ia.IncludedColumns
                  ELSE N''
              END
    END,

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

    UsageSummary = N'seeks=' + CAST(ia.UserSeeks AS nvarchar(20))
                 + N', scans=' + CAST(ia.UserScans AS nvarchar(20))
                 + N', lookups=' + CAST(ia.UserLookups AS nvarchar(20))
                 + N', updates=' + CAST(ia.UserUpdates AS nvarchar(20)),

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
    ia.FilterSchema,
    ia.FilterTable,
    ia.SortBy,

    IsHeap = CASE WHEN ia.IndexID = 0 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,

    IsUnused = CASE
                   WHEN ia.TotalReads = 0 AND ia.UserUpdates > 0 THEN CAST(1 AS bit)
                   ELSE CAST(0 AS bit)
               END,

    IsWriteHeavy = CASE
                       WHEN ia.TotalReads > 0 AND ia.UserUpdates > (ia.TotalReads * 10) THEN CAST(1 AS bit)
                       ELSE CAST(0 AS bit)
                   END,

    UsageCategory = CASE
                        WHEN ia.IsDisabled = 1 THEN 'Disabled'
                        WHEN ia.IndexID = 0 THEN 'Heap'
                        WHEN ia.HasUsageStats = 0 THEN 'No usage stats since restart'
                        WHEN ia.TotalReads = 0 AND ia.UserUpdates > 0 THEN 'Unused (writes only)'
                        WHEN ia.TotalReads > 0 AND ia.UserUpdates > (ia.TotalReads * 10) THEN 'Write-heavy'
                        WHEN ia.TotalReads = 0 AND ia.UserUpdates = 0 THEN 'No activity'
                        ELSE 'Active'
                    END,

    rr.RunRank,
    IsLatestRun = CASE WHEN rr.RunRank = 1 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END
  FROM dbo.IndexAnalysis AS ia
  JOIN RankedRuns AS rr
    ON rr.IndexAnalysisID = ia.IndexAnalysisID
GO

IF OBJECT_ID('dbo.vIndexAnalysis') IS NOT NULL
    PRINT 'View created'
ELSE
    PRINT 'View NOT created'
GO