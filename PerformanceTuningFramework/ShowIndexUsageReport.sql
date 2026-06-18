

/*
  ShowIndexUsageReport.sql
  Performance Tuning Framework

  Deploy to the tool database, create IndexAnalysis first, then execute:
    EXEC dbo.ShowIndexUsageReport @TargetDatabase = N'YourDatabase'

  Optional parameters:
    @TargetDatabase - database to analyze (default: current database)
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
    @TargetDatabase sysname      = NULL,
    @SchemaFilter   sysname      = '%',
    @TableFilter    sysname      = '%',
    @ReportWidth    tinyint      = 120,
    @SortBy         varchar(10)  = 'READS'
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Version-aware index usage report. Reads index metadata from a target database,
--               joins instance-wide sys.dm_db_index_usage_stats, stores results in IndexAnalysis,
--               and returns a fixed-width, screen-friendly text report.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion        tinyint,
    @ProductVersion      varchar(30),
    @ProductLevel        varchar(30),
    @Edition             varchar(64),
    @ServerName          sysname,
    @DatabaseName        sysname,
    @TargetDatabaseId    int,
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
    @SizeWidth           tinyint,
    @DateWidth           tinyint,
    @TotalIndexes        int,
    @UnusedIndexes       int,
    @WriteHeavyIndexes   int,
    @DisabledIndexes     int,
    @NeverSampled        int,
    @LineNo              int,
    @SortByUpper         varchar(10),
    @AnalysisRunID       uniqueidentifier,
    @CaptureDate         datetime,
    @Sql                 nvarchar(max)

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
SET @DatabaseName   = @TargetDatabase
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @RestartKnown   = CASE WHEN @MajorVersion >= 10 THEN 1 ELSE 0 END
SET @Divider        = REPLICATE('-', @ReportWidth)
SET @HeaderRule     = REPLICATE('=', @ReportWidth)
SET @BlankLine      = REPLICATE(' ', @ReportWidth)
SET @AnalysisRunID  = NEWID()
SET @CaptureDate    = GETDATE()

-- Column widths total 111 characters; 9 one-character separators make 120.
SET @ObjectWidth = 34
SET @IndexWidth  = 28
SET @TypeWidth   = 3
SET @NumWidth    = 7
SET @RatioWidth  = 5
SET @SizeWidth   = 8
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
    ReadWriteRatio   varchar(8)      NOT NULL,
    ReadWriteNumeric decimal(18, 4)  NULL,
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

SET @Sql = N'
;WITH IndexSizes AS
(
    SELECT
        p.object_id,
        p.index_id,
        SizeMB = SUM(a.total_pages) * 8.0 / 1024.0
    FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.partitions AS p
    INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.allocation_units AS a
        ON p.partition_id = a.container_id
    GROUP BY p.object_id, p.index_id
)
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
                  WHEN ''WRITES''   THEN ISNULL(us.user_updates, 0)
                  WHEN ''SIZE''     THEN CAST(ISNULL(sz.SizeMB, 0) * 10 AS bigint)
                  WHEN ''OBJECT''   THEN CHECKSUM(s.name, o.name, ISNULL(i.name, ''''))
                  WHEN ''LAST_USE'' THEN DATEDIFF(minute, ''2000-01-01'',
                                      COALESCE(us.last_user_seek, us.last_user_scan,
                                               us.last_user_lookup, us.last_user_update, ''2000-01-01''))
                  ELSE ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0)
              END,
    SchemaName = s.name,
    TableName = o.name,
    ObjectName = s.name + ''.'' + o.name,
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
    TypeAbbr = CASE
                   WHEN i.index_id = 0 THEN ''HP ''
                   WHEN i.is_disabled = 1 THEN
                       CASE i.type_desc
                           WHEN ''CLUSTERED'' THEN ''CL*''
                           WHEN ''NONCLUSTERED'' THEN ''NC*''
                           WHEN ''XML'' THEN ''XML''
                           ELSE LEFT(REPLACE(i.type_desc, '' '', ''''), 3)
                       END
                   WHEN i.type_desc = ''CLUSTERED'' THEN ''CL ''
                   WHEN i.type_desc = ''NONCLUSTERED'' THEN ''NC ''
                   WHEN i.type_desc = ''XML'' THEN ''XML''
                   WHEN @MajorVersion >= 11 AND i.type_desc LIKE ''%COLUMNSTORE%'' THEN
                       CASE WHEN i.type_desc LIKE ''CLUSTERED%'' THEN ''CC '' ELSE ''CS '' END
                   ELSE LEFT(REPLACE(i.type_desc, '' '', ''''), 3)
               END,
    UserSeeks   = ISNULL(us.user_seeks, 0),
    UserScans   = ISNULL(us.user_scans, 0),
    UserLookups = ISNULL(us.user_lookups, 0),
    UserUpdates = ISNULL(us.user_updates, 0),
    TotalReads  = ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0),
    ReadWriteRatio = CASE
                         WHEN ISNULL(us.user_updates, 0) = 0 AND
                              (ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0)) = 0
                             THEN ''n/a''
                         WHEN ISNULL(us.user_updates, 0) = 0 THEN ''inf''
                         ELSE CAST(
                              (ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0))
                              / NULLIF(us.user_updates, 0) AS varchar(8))
                     END,
    ReadWriteNumeric = CASE
                           WHEN ISNULL(us.user_updates, 0) = 0 THEN NULL
                           ELSE (ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0))
                                * 1.0 / us.user_updates
                       END,
    SizeMB = ISNULL(sz.SizeMB, 0),
    LastUserSeek = us.last_user_seek,
    LastUserScan = us.last_user_scan,
    LastUserLookup = us.last_user_lookup,
    LastUserUpdate = us.last_user_update,
    LastUseDate = CASE
                      WHEN COALESCE(us.last_user_seek, us.last_user_scan, us.last_user_lookup, us.last_user_update) IS NULL
                          THEN ''     ''
                      ELSE RIGHT(''0'' + CAST(MONTH(
                               COALESCE(us.last_user_seek, us.last_user_scan, us.last_user_lookup, us.last_user_update)) AS varchar(2)), 2)
                           + ''-''
                           + RIGHT(''0'' + CAST(DAY(
                               COALESCE(us.last_user_seek, us.last_user_scan, us.last_user_lookup, us.last_user_update)) AS varchar(2)), 2)
                  END,
    IsDisabled = ISNULL(i.is_disabled, 0),
    HasUsageStats = CASE WHEN us.database_id IS NULL THEN 0 ELSE 1 END,
    IsFiltered = CASE WHEN @MajorVersion >= 10 AND ISNULL(i.has_filter, 0) = 1 THEN 1 ELSE 0 END
FROM ' + QUOTENAME(@TargetDatabase) + N'.sys.objects AS o
INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
INNER JOIN ' + QUOTENAME(@TargetDatabase) + N'.sys.indexes AS i
    ON i.object_id = o.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = @TargetDatabaseId
   AND us.object_id = i.object_id
   AND us.index_id = i.index_id
LEFT JOIN IndexSizes AS sz
    ON sz.object_id = i.object_id
   AND sz.index_id = i.index_id
WHERE o.type = ''U''
  AND s.name LIKE @SchemaFilter
  AND o.name LIKE @TableFilter
  AND i.index_id >= 0'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int,
      @SchemaFilter sysname,
      @TableFilter sysname,
      @MajorVersion tinyint,
      @SortByUpper varchar(10)',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @MajorVersion = @MajorVersion,
    @SortByUpper = @SortByUpper

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
    SizeMB,
    LastUserSeek,
    LastUserScan,
    LastUserLookup,
    LastUserUpdate,
    IsDisabled,
    HasUsageStats,
    IsFiltered,
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
    u.SizeMB,
    u.LastUserSeek,
    u.LastUserScan,
    u.LastUserLookup,
    u.LastUserUpdate,
    u.IsDisabled,
    u.HasUsageStats,
    u.IsFiltered,
    @SchemaFilter,
    @TableFilter,
    @SortByUpper
FROM #IndexUsage AS u

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
       LEFT(' Stats since restart: ' + @RestartTime
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
SELECT @LineNo + 2, LEFT(' USED=last seek/scan/lookup/update (MM-DD). R/W=read operations per write.' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 3, LEFT(' Note: usage stats reset at instance restart; missing rows mean no activity since restart.' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(' Stored in IndexAnalysis run: ' + CAST(@AnalysisRunID AS varchar(36)) + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 5, LEFT(@HeaderRule, @ReportWidth)

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

GO