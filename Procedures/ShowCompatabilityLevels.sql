
/*
  ShowCompatabilityLevels.sql

  Deploy to the DBA tool database, then execute:
    EXEC dbo.ShowCompatabilityLevels
    EXEC dbo.ShowCompatabilityLevels @IncludeSystemDatabases = 1
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowCompatabilityLevels') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowCompatabilityLevels'
    DROP PROCEDURE dbo.ShowCompatabilityLevels
END
GO

PRINT 'Creating: ShowCompatabilityLevels'
GO

CREATE PROCEDURE dbo.ShowCompatabilityLevels
(
    @DatabaseFilter          sysname = '%',
    @IncludeSystemDatabases  bit     = 0,
    @ReportWidth             tinyint = 120
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 23, 2026
-- Author:       Bill McEvoy
-- Description:  Displays the current compatibility level for each user database on the instance.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion     tinyint,
    @ProductVersion   varchar(30),
    @ServerName       sysname,
    @ReportTime       varchar(19),
    @InstanceCompat   int,
    @DatabaseCount    int,
    @Divider          varchar(120),
    @HeaderRule       varchar(120),
    @BlankLine        varchar(120),
    @DbWidth          tinyint,
    @LevelWidth       tinyint,
    @ModeWidth        tinyint,
    @StateWidth       tinyint,
    @LineNo           int

SET @ReportWidth = 120
SET @Divider     = REPLICATE('-', @ReportWidth)
SET @HeaderRule  = REPLICATE('=', @ReportWidth)
SET @BlankLine   = REPLICATE(' ', @ReportWidth)

SET @DbWidth    = 28
SET @LevelWidth = 6
SET @ModeWidth  = 22
SET @StateWidth = 12

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @InstanceCompat = @MajorVersion * 10

IF OBJECT_ID('tempdb..#DatabaseCompat') IS NOT NULL
    DROP TABLE #DatabaseCompat

CREATE TABLE #DatabaseCompat
(
    DatabaseName        sysname      NOT NULL,
    CompatibilityLevel  int          NOT NULL,
    CompatibilityMode   varchar(30)  NOT NULL,
    StateDesc           nvarchar(60) NOT NULL,
    UserAccessDesc      nvarchar(60) NOT NULL,
    IsSystemDatabase    bit          NOT NULL,
    InstanceMatch       bit          NOT NULL
)

INSERT INTO #DatabaseCompat
(
    DatabaseName,
    CompatibilityLevel,
    CompatibilityMode,
    StateDesc,
    UserAccessDesc,
    IsSystemDatabase,
    InstanceMatch
)
SELECT
    d.name,
    d.compatibility_level,
    CompatibilityMode = CASE d.compatibility_level
        WHEN 80  THEN 'SQL Server 2000'
        WHEN 90  THEN 'SQL Server 2005'
        WHEN 100 THEN 'SQL Server 2008'
        WHEN 110 THEN 'SQL Server 2012'
        WHEN 120 THEN 'SQL Server 2014'
        WHEN 130 THEN 'SQL Server 2016'
        WHEN 140 THEN 'SQL Server 2017'
        WHEN 150 THEN 'SQL Server 2019'
        WHEN 160 THEN 'SQL Server 2022'
        WHEN 170 THEN 'SQL Server 2025'
        ELSE 'Level ' + CAST(d.compatibility_level AS varchar(10))
    END,
    d.state_desc,
    d.user_access_desc,
    IsSystemDatabase = CASE WHEN d.database_id <= 4 THEN 1 ELSE 0 END,
    InstanceMatch = CASE WHEN d.compatibility_level = @InstanceCompat THEN 1 ELSE 0 END
  FROM sys.databases AS d
 WHERE d.name LIKE @DatabaseFilter
   AND (
           @IncludeSystemDatabases = 1
        OR d.database_id > 4
       )

SELECT @DatabaseCount = COUNT(*)
  FROM #DatabaseCompat

IF OBJECT_ID('tempdb..#Report') IS NOT NULL
    DROP TABLE #Report

CREATE TABLE #Report
(
    [LineNo]   int          NOT NULL,
    ReportLine varchar(200) NOT NULL
)

SET @LineNo = 0

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(' DATABASE COMPATIBILITY LEVELS' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2,
       LEFT(' Server: ' + @ServerName + '  |  SQL Server ' + @ProductVersion + '  |  ' + @ReportTime + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 3,
       LEFT(' Instance default compatibility: ' + CAST(@InstanceCompat AS varchar(10))
            + '  |  Databases listed: ' + CAST(@DatabaseCount AS varchar(10))
            + CASE WHEN @IncludeSystemDatabases = 0 THEN '  (user only)' ELSE '  (incl system)' END
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 5,
       LEFT(
              LEFT('DATABASE' + @BlankLine, @DbWidth)
            + ' ' + RIGHT(REPLICATE(' ', @LevelWidth) + 'LEVEL', @LevelWidth)
            + ' ' + LEFT('COMPATIBILITY MODE' + @BlankLine, @ModeWidth)
            + ' ' + LEFT('STATE' + @BlankLine, @StateWidth)
            + ' ' + LEFT('ACCESS' + @BlankLine, @ReportWidth - @DbWidth - @LevelWidth - @ModeWidth - @StateWidth - 3),
            @ReportWidth)
UNION ALL
SELECT @LineNo + 6, LEFT(@Divider, @ReportWidth)

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    ROW_NUMBER() OVER (ORDER BY dc.IsSystemDatabase, dc.DatabaseName) + 6,
    LEFT(
          LEFT(dc.DatabaseName + @BlankLine, @DbWidth)
        + ' ' + RIGHT(REPLICATE(' ', @LevelWidth) + CAST(dc.CompatibilityLevel AS varchar(10)), @LevelWidth)
        + ' ' + LEFT(dc.CompatibilityMode + @BlankLine, @ModeWidth)
        + ' ' + LEFT(dc.StateDesc + @BlankLine, @StateWidth)
        + ' ' + LEFT(
              dc.UserAccessDesc
              + CASE WHEN dc.InstanceMatch = 0 THEN ' *' ELSE '' END
              + @BlankLine,
              @ReportWidth - @DbWidth - @LevelWidth - @ModeWidth - @StateWidth - 3),
        @ReportWidth)
  FROM #DatabaseCompat AS dc

SELECT @LineNo = 6 + @DatabaseCount + 1

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(' * = compatibility level differs from instance default (' + CAST(@InstanceCompat AS varchar(10)) + ')' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2, LEFT(' To change: ALTER DATABASE [name] SET COMPATIBILITY_LEVEL = 160;' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 3, LEFT(@HeaderRule, @ReportWidth)

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

SELECT
    DatabaseName,
    CompatibilityLevel,
    CompatibilityMode,
    StateDesc,
    UserAccessDesc,
    IsSystemDatabase,
    InstanceMatch,
    InstanceDefaultCompatibility = @InstanceCompat
  FROM #DatabaseCompat
 ORDER BY IsSystemDatabase, DatabaseName

GO

IF OBJECT_ID('dbo.ShowCompatabilityLevels') IS NOT NULL
    PRINT 'Procedure created.'
ELSE
    PRINT 'Procedure NOT created.'
GO