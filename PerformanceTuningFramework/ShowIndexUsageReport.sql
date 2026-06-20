/*
  ShowIndexUsageReport.sql
  Performance Tuning Framework

  Deploy to the tool database, create IndexAnalysis first, run AnalyzeIndexes, then execute:
    EXEC dbo.ShowIndexUsageReport @TargetDatabase = N'YourDatabase'

  Optional parameters:
    @TargetDatabase - database reported on (default: current database)
    @AnalysisRunID  - specific capture run (default: latest for @TargetDatabase)
    @SchemaFilter   - schema name filter (default '%')
    @TableFilter    - table name filter (default '%')
    @ReportWidth    - kept for backward compatibility; report layout is fixed at 120 characters
    @SortBy         - READS | WRITES | SIZE | OBJECT | LAST_USE
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ShowIndexUsageReport
(
    @TargetDatabase sysname           = NULL,
    @AnalysisRunID  uniqueidentifier  = NULL,
    @SchemaFilter   sysname           = '%',
    @TableFilter    sysname           = '%',
    @ReportWidth    tinyint           = 120,
    @SortBy         varchar(10)       = 'READS'
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Version-aware index usage report. Reads captured data from IndexAnalysis and
--               returns a fixed-width, screen-friendly text report.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion        tinyint,
    @ProductVersion      varchar(30),
    @ProductLevel        varchar(30),
    @Edition             varchar(64),
    @ServerName          sysname,
    @DatabaseName        sysname,
    @ReportTime          varchar(19),
    @RestartTime         varchar(19),
    @RestartKnown        bit,
    @Divider             varchar(120),
    @HeaderRule          varchar(120),
    @BlankLine           varchar(120),
    @ObjectWidth         tinyint,
    @IndexWidth          tinyint,
    @TypeWidth           tinyint,
    @NumWidth            tinyint,
    @RatioWidth          tinyint,
    @RowsWidth           tinyint,
    @SizeWidth           tinyint,
    @DateWidth           tinyint,
    @TotalIndexes        int,
    @UnusedIndexes       int,
    @WriteHeavyIndexes   int,
    @DisabledIndexes     int,
    @NeverSampled        int,
    @LineNo              int,
    @SortByUpper         varchar(10),
    @CaptureDate         varchar(19)

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

IF OBJECT_ID('dbo.IndexAnalysis') IS NULL
BEGIN
    RAISERROR('Table dbo.IndexAnalysis does not exist. Run IndexAnalysis.sql in this database first.', 16, 1)
    RETURN
END

IF @AnalysisRunID IS NULL
BEGIN
    SELECT TOP (1)
        @AnalysisRunID = AnalysisRunID,
        @CaptureDate   = CONVERT(varchar(19), CaptureDate, 120)
      FROM dbo.IndexAnalysis
     WHERE DatabaseName = @TargetDatabase
     ORDER BY CaptureDate DESC
END
ELSE
BEGIN
    SELECT TOP (1)
        @CaptureDate = CONVERT(varchar(19), CaptureDate, 120),
        @TargetDatabase = DatabaseName
      FROM dbo.IndexAnalysis
     WHERE AnalysisRunID = @AnalysisRunID
END

IF @AnalysisRunID IS NULL
BEGIN
    RAISERROR('No IndexAnalysis data found for database ''%s''.', 16, 1, @TargetDatabase)
    RETURN
END

SET @DatabaseName = @TargetDatabase

-- This layout is calibrated to exactly 120 printable characters.
-- Keep the parameter so existing callers do not break, but force the report width.
SET @ReportWidth = 120

SET @SortByUpper = UPPER(ISNULL(@SortBy, 'READS'))
IF @SortByUpper NOT IN ('READS', 'WRITES', 'SIZE', 'OBJECT', 'LAST_USE')
    SET @SortByUpper = 'READS'

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ProductLevel   = CAST(SERVERPROPERTY('ProductLevel') AS varchar(30))
SET @Edition        = CAST(SERVERPROPERTY('Edition') AS varchar(64))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @RestartKnown   = CASE WHEN @MajorVersion >= 10 THEN 1 ELSE 0 END
SET @Divider        = REPLICATE('-', @ReportWidth)
SET @HeaderRule     = REPLICATE('=', @ReportWidth)
SET @BlankLine      = REPLICATE(' ', @ReportWidth)

-- Column widths total 100 characters; separators make 120.
SET @ObjectWidth = 28
SET @IndexWidth  = 22
SET @TypeWidth   = 3
SET @NumWidth    = 6
SET @RatioWidth  = 4
SET @RowsWidth   = 7
SET @SizeWidth   = 7
SET @DateWidth   = 5

IF OBJECT_ID('tempdb..#IndexUsage') IS NOT NULL
    DROP TABLE #IndexUsage

CREATE TABLE #IndexUsage
(
    SortKey          bigint          NOT NULL,
    SchemaName       sysname         NOT NULL,
    TableName        sysname         NOT NULL,
    ObjectName       varchar(128)    NOT NULL,
    ObjectID         int             NOT NULL,
    IndexID          int             NOT NULL,
    IndexName        varchar(128)    NOT NULL,
    IndexTypeDesc    nvarchar(60)    NOT NULL,
    TypeAbbr         char(3)         NOT NULL,
    UserSeeks        bigint          NOT NULL,
    UserScans        bigint          NOT NULL,
    UserLookups      bigint          NOT NULL,
    UserUpdates      bigint          NOT NULL,
    TotalReads       bigint          NOT NULL,
    ReadWriteRatio   varchar(32)     NOT NULL,
    ReadWriteNumeric decimal(18, 4)  NULL,
    RecordCount      bigint          NOT NULL,
    SizeMB           decimal(12, 1)  NOT NULL,
    LastUserSeek     datetime        NULL,
    LastUserScan     datetime        NULL,
    LastUserLookup   datetime        NULL,
    LastUserUpdate   datetime        NULL,
    LastUseDate      char(5)         NOT NULL,
    IsDisabled       bit             NOT NULL,
    HasUsageStats    bit             NOT NULL,
    IsFiltered       bit             NOT NULL
)

IF OBJECT_ID('tempdb..#Report') IS NOT NULL
    DROP TABLE #Report

CREATE TABLE #Report
(
    [LineNo]     int          NOT NULL,
    ReportLine   varchar(200) NOT NULL
)

IF @RestartKnown = 1
BEGIN
    SELECT @RestartTime = CONVERT(varchar(19), sqlserver_start_time, 120)
      FROM sys.dm_os_sys_info
END
ELSE
BEGIN
    SET @RestartTime = 'n/a (SQL 2005)'
END

INSERT INTO #IndexUsage
(
    SortKey,
    SchemaName,
    TableName,
    ObjectName,
    ObjectID,
    IndexID,
    IndexName,
    IndexTypeDesc,
    TypeAbbr,
    UserSeeks,
    UserScans,
    UserLookups,
    UserUpdates,
    TotalReads,
    ReadWriteRatio,
    ReadWriteNumeric,
    RecordCount,
    SizeMB,
    LastUserSeek,
    LastUserScan,
    LastUserLookup,
    LastUserUpdate,
    LastUseDate,
    IsDisabled,
    HasUsageStats,
    IsFiltered
)
SELECT
    SortKey = CASE @SortByUpper
                  WHEN 'WRITES'   THEN ia.UserUpdates
                  WHEN 'SIZE'     THEN CAST(ia.SizeMB * 10 AS bigint)
                  WHEN 'OBJECT'   THEN CHECKSUM(ia.SchemaName, ia.TableName, ISNULL(ia.IndexName, ''))
                  WHEN 'LAST_USE' THEN DATEDIFF(minute, '2000-01-01',
                                      COALESCE(ia.LastUserSeek, ia.LastUserScan,
                                               ia.LastUserLookup, ia.LastUserUpdate, '2000-01-01'))
                  ELSE ia.TotalReads
              END,
    ia.SchemaName,
    ia.TableName,
    ObjectName = ia.SchemaName + '.' + ia.TableName,
    ia.ObjectID,
    ia.IndexID,
    IndexName = CASE
                    WHEN ia.IndexID = 0 THEN '[HEAP]'
                    WHEN ia.IndexName IS NULL THEN '[unnamed]'
                    ELSE ia.IndexName
                END,
    ia.IndexTypeDesc,
    TypeAbbr = CASE
                   WHEN ia.IndexID = 0 THEN 'HP '
                   WHEN ia.IsDisabled = 1 THEN
                       CASE ia.IndexTypeDesc
                           WHEN 'CLUSTERED' THEN 'CL*'
                           WHEN 'NONCLUSTERED' THEN 'NC*'
                           WHEN 'XML' THEN 'XML'
                           ELSE LEFT(REPLACE(ia.IndexTypeDesc, ' ', ''), 3)
                       END
                   WHEN ia.IndexTypeDesc = 'CLUSTERED' THEN 'CL '
                   WHEN ia.IndexTypeDesc = 'NONCLUSTERED' THEN 'NC '
                   WHEN ia.IndexTypeDesc = 'XML' THEN 'XML'
                   WHEN @MajorVersion >= 11 AND ia.IndexTypeDesc LIKE '%COLUMNSTORE%' THEN
                       CASE WHEN ia.IndexTypeDesc LIKE 'CLUSTERED%' THEN 'CC ' ELSE 'CS ' END
                   ELSE LEFT(REPLACE(ia.IndexTypeDesc, ' ', ''), 3)
               END,
    ia.UserSeeks,
    ia.UserScans,
    ia.UserLookups,
    ia.UserUpdates,
    ia.TotalReads,
    ReadWriteRatio = CASE
                         WHEN ia.UserUpdates = 0 AND ia.TotalReads = 0 THEN 'n/a'
                         WHEN ia.UserUpdates = 0 THEN 'inf'
                         ELSE CONVERT(varchar(32), ia.ReadWriteRatio)
                     END,
    ia.ReadWriteRatio,
    ia.RecordCount,
    ia.SizeMB,
    ia.LastUserSeek,
    ia.LastUserScan,
    ia.LastUserLookup,
    ia.LastUserUpdate,
    LastUseDate = CASE
                      WHEN COALESCE(ia.LastUserSeek, ia.LastUserScan, ia.LastUserLookup, ia.LastUserUpdate) IS NULL
                          THEN '     '
                      ELSE RIGHT('0' + CAST(MONTH(
                               COALESCE(ia.LastUserSeek, ia.LastUserScan, ia.LastUserLookup, ia.LastUserUpdate)) AS varchar(2)), 2)
                           + '-'
                           + RIGHT('0' + CAST(DAY(
                               COALESCE(ia.LastUserSeek, ia.LastUserScan, ia.LastUserLookup, ia.LastUserUpdate)) AS varchar(2)), 2)
                  END,
    ia.IsDisabled,
    ia.HasUsageStats,
    ia.IsFiltered
  FROM dbo.IndexAnalysis AS ia
 WHERE ia.AnalysisRunID = @AnalysisRunID
   AND ia.SchemaName LIKE @SchemaFilter
   AND ia.TableName LIKE @TableFilter

IF NOT EXISTS (SELECT 1 FROM #IndexUsage)
BEGIN
    DECLARE @AnalysisRunIDText varchar(36)

    SET @AnalysisRunIDText = CONVERT(varchar(36), @AnalysisRunID)

    RAISERROR('No IndexAnalysis rows matched AnalysisRunID %s with the requested filters.', 16, 1, @AnalysisRunIDText)
    RETURN
END

SELECT
    @TotalIndexes      = COUNT(*),
    @UnusedIndexes     = SUM(CASE WHEN TotalReads = 0 AND UserUpdates > 0 THEN 1 ELSE 0 END),
    @WriteHeavyIndexes = SUM(CASE WHEN TotalReads > 0 AND UserUpdates > TotalReads * 10 THEN 1 ELSE 0 END),
    @DisabledIndexes   = SUM(CASE WHEN IsDisabled = 1 THEN 1 ELSE 0 END),
    @NeverSampled      = SUM(CASE WHEN HasUsageStats = 0 THEN 1 ELSE 0 END)
FROM #IndexUsage

SET @LineNo = 0

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(' INDEX USAGE REPORT' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2,
       LEFT(' Database: ' + @DatabaseName
            + REPLICATE(' ', 2)
            + 'Server: ' + @ServerName
            + '  ' + @ReportTime + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 3,
       LEFT(' SQL Server ' + @ProductVersion + ' ' + @ProductLevel
            + '  |  ' + LEFT(@Edition, 24) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4,
       LEFT(' Captured: ' + ISNULL(@CaptureDate, 'unknown')
            + '  |  Stats since restart: ' + @RestartTime
            + CASE WHEN @MajorVersion < 10 THEN '  (upgrade to SQL 2008+ for start time)' ELSE '' END
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 5, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 6,
       LEFT(' ' + CAST(@TotalIndexes AS varchar(10)) + ' indexes'
            + '  |  ' + CAST(@UnusedIndexes AS varchar(10)) + ' unused (0 reads, has writes)'
            + '  |  ' + CAST(@WriteHeavyIndexes AS varchar(10)) + ' write-heavy'
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 7,
       LEFT(' ' + CAST(@DisabledIndexes AS varchar(10)) + ' disabled'
            + '  |  ' + CAST(@NeverSampled AS varchar(10)) + ' not in usage cache since restart'
            + '  |  sort: ' + @SortByUpper
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 8, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 9,
       LEFT(
              LEFT('OBJECT' + @BlankLine, @ObjectWidth)
            + ' ' + LEFT('INDEX' + @BlankLine, @IndexWidth)
            + ' ' + LEFT('TYP' + @BlankLine, @TypeWidth)
            + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + 'SEEKS', @NumWidth)
            + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + 'SCANS', @NumWidth)
            + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + 'LOOK', @NumWidth)
            + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + 'UPD', @NumWidth)
            + ' ' + RIGHT(REPLICATE(' ', @RatioWidth) + 'R/W', @RatioWidth)
            + ' ' + RIGHT(REPLICATE(' ', @RowsWidth) + 'ROWS', @RowsWidth)
            + ' ' + RIGHT(REPLICATE(' ', @SizeWidth) + 'MB', @SizeWidth)
            + ' ' + LEFT('USED' + @BlankLine, @DateWidth),
            @ReportWidth)
UNION ALL
SELECT @LineNo + 10, LEFT(@Divider, @ReportWidth)

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    ROW_NUMBER() OVER (ORDER BY u.SortKey DESC, u.ObjectName, u.IndexName) + 10,
    LEFT(
          LEFT(u.ObjectName + @BlankLine, @ObjectWidth)
        + ' ' + LEFT(u.IndexName + @BlankLine, @IndexWidth)
        + ' ' + LEFT(u.TypeAbbr + @BlankLine, @TypeWidth)
        + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + CASE
                WHEN u.UserSeeks >= 1000000000 THEN CAST(u.UserSeeks / 1000000000 AS varchar(10)) + 'B'
                WHEN u.UserSeeks >= 1000000 THEN LTRIM(STR(u.UserSeeks / 1000000.0, 4, 1)) + 'M'
                WHEN u.UserSeeks >= 10000 THEN CAST(u.UserSeeks / 1000 AS varchar(10)) + 'K'
                WHEN u.UserSeeks >= 1000 THEN LTRIM(STR(u.UserSeeks / 1000.0, 4, 1)) + 'K'
                ELSE CAST(u.UserSeeks AS varchar(10))
            END, @NumWidth)
        + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + CASE
                WHEN u.UserScans >= 1000000000 THEN CAST(u.UserScans / 1000000000 AS varchar(10)) + 'B'
                WHEN u.UserScans >= 1000000 THEN LTRIM(STR(u.UserScans / 1000000.0, 4, 1)) + 'M'
                WHEN u.UserScans >= 10000 THEN CAST(u.UserScans / 1000 AS varchar(10)) + 'K'
                WHEN u.UserScans >= 1000 THEN LTRIM(STR(u.UserScans / 1000.0, 4, 1)) + 'K'
                ELSE CAST(u.UserScans AS varchar(10))
            END, @NumWidth)
        + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + CASE
                WHEN u.UserLookups >= 1000000000 THEN CAST(u.UserLookups / 1000000000 AS varchar(10)) + 'B'
                WHEN u.UserLookups >= 1000000 THEN LTRIM(STR(u.UserLookups / 1000000.0, 4, 1)) + 'M'
                WHEN u.UserLookups >= 10000 THEN CAST(u.UserLookups / 1000 AS varchar(10)) + 'K'
                WHEN u.UserLookups >= 1000 THEN LTRIM(STR(u.UserLookups / 1000.0, 4, 1)) + 'K'
                ELSE CAST(u.UserLookups AS varchar(10))
            END, @NumWidth)
        + ' ' + RIGHT(REPLICATE(' ', @NumWidth) + CASE
                WHEN u.UserUpdates >= 1000000000 THEN CAST(u.UserUpdates / 1000000000 AS varchar(10)) + 'B'
                WHEN u.UserUpdates >= 1000000 THEN LTRIM(STR(u.UserUpdates / 1000000.0, 4, 1)) + 'M'
                WHEN u.UserUpdates >= 10000 THEN CAST(u.UserUpdates / 1000 AS varchar(10)) + 'K'
                WHEN u.UserUpdates >= 1000 THEN LTRIM(STR(u.UserUpdates / 1000.0, 4, 1)) + 'K'
                ELSE CAST(u.UserUpdates AS varchar(10))
            END, @NumWidth)
        + ' ' + RIGHT(REPLICATE(' ', @RatioWidth) + LEFT(u.ReadWriteRatio, @RatioWidth), @RatioWidth)
        + ' ' + RIGHT(REPLICATE(' ', @RowsWidth) + CASE
                WHEN u.RecordCount >= 1000000000 THEN CAST(u.RecordCount / 1000000000 AS varchar(10)) + 'B'
                WHEN u.RecordCount >= 1000000 THEN LTRIM(STR(u.RecordCount / 1000000.0, 4, 1)) + 'M'
                WHEN u.RecordCount >= 10000 THEN CAST(u.RecordCount / 1000 AS varchar(10)) + 'K'
                WHEN u.RecordCount >= 1000 THEN LTRIM(STR(u.RecordCount / 1000.0, 4, 1)) + 'K'
                ELSE CAST(u.RecordCount AS varchar(10))
            END, @RowsWidth)
        + ' ' + RIGHT(REPLICATE(' ', @SizeWidth) + CAST(u.SizeMB AS varchar(10)), @SizeWidth)
        + ' ' + LEFT(u.LastUseDate + @BlankLine, @DateWidth),
        @ReportWidth)
  FROM #IndexUsage AS u

SELECT @LineNo = 10 + COUNT(*) + 1
  FROM #IndexUsage

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(' Legend: CL=clustered  NC=nonclustered  HP=heap  CC/CS=columnstore  *=disabled' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2, LEFT(' USED=last seek/scan/lookup/update (MM-DD). ROWS=records in index. R/W=reads per write.' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 3, LEFT(' Note: usage stats reset at instance restart; missing rows mean no activity since restart.' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(' IndexAnalysis run: ' + CAST(@AnalysisRunID AS varchar(36)) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 5, LEFT(@HeaderRule, @ReportWidth)

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

GO