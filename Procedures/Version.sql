
GO

/*
  Version.sql

  Deploy to the DBA tool database, then execute:
    EXEC dbo.Version
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.Version
(
    @ReportWidth tinyint = 120
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 20, 2026
-- Author:       Bill McEvoy
-- Description:  Reports the current SQL Server version and a fixed-width history of Microsoft
--               SQL Server releases from 1989 through 2026, including numeric version and
--               marketing name.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @ProductVersion     varchar(30),
    @ProductLevel       varchar(30),
    @ProductUpdateLevel varchar(30),
    @Edition            varchar(64),
    @EngineEdition      int,
    @ServerName         sysname,
    @ReportTime         varchar(19),
    @StartTime          varchar(19),
    @MajorVersion       int,
    @MinorVersion       int,
    @BuildVersion       int,
    @NumericVersion     varchar(20),
    @MarketingName      varchar(40),
    @Divider            varchar(120),
    @HeaderRule         varchar(120),
    @BlankLine          varchar(120),
    @YearWidth          tinyint,
    @VersionWidth       tinyint,
    @MarketingWidth     tinyint,
    @CodeNameWidth      tinyint,
    @StatusWidth        tinyint,
    @LineNo             int,
    @Line               varchar(200),
    @VersionKey         varchar(20)

-- This layout is calibrated to exactly 120 printable characters.
-- Keep the parameter so existing callers do not break, but force the report width.
SET @ReportWidth = 120
SET @ProductVersion     = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ProductLevel       = CAST(SERVERPROPERTY('ProductLevel') AS varchar(30))
SET @ProductUpdateLevel = CAST(ISNULL(SERVERPROPERTY('ProductUpdateLevel'), '') AS varchar(30))
SET @Edition            = CAST(SERVERPROPERTY('Edition') AS varchar(64))
SET @EngineEdition      = CAST(SERVERPROPERTY('EngineEdition') AS int)
SET @ServerName         = CAST(SERVERPROPERTY('MachineName') AS sysname)
                          + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @ReportTime         = CONVERT(varchar(19), GETDATE(), 120)
SET @Divider            = REPLICATE('-', @ReportWidth)
SET @HeaderRule         = REPLICATE('=', @ReportWidth)
SET @BlankLine          = REPLICATE(' ', @ReportWidth)

-- Column widths total 116 characters; single-space separators make 120.
SET @YearWidth      = 6
SET @VersionWidth   = 8
SET @MarketingWidth = 70
SET @CodeNameWidth  = 20
SET @StatusWidth    = 12

SET @MajorVersion = CONVERT(int,
    LEFT(@ProductVersion, NULLIF(CHARINDEX('.', @ProductVersion), 0) - 1))

SET @MinorVersion = CONVERT(int,
    SUBSTRING(
        @ProductVersion,
        CHARINDEX('.', @ProductVersion) + 1,
        NULLIF(CHARINDEX('.', @ProductVersion, CHARINDEX('.', @ProductVersion) + 1), 0)
            - CHARINDEX('.', @ProductVersion) - 1))

SET @BuildVersion = TRY_CONVERT(int,
    SUBSTRING(
        @ProductVersion,
        CHARINDEX('.', @ProductVersion, CHARINDEX('.', @ProductVersion) + 1) + 1,
        NULLIF(CHARINDEX('.', @ProductVersion, CHARINDEX('.', @ProductVersion, CHARINDEX('.', @ProductVersion) + 1) + 1), 0)
            - CHARINDEX('.', @ProductVersion, CHARINDEX('.', @ProductVersion) + 1) - 1))

SET @NumericVersion = CAST(@MajorVersion AS varchar(10)) + '.'
                    + CAST(ISNULL(@MinorVersion, 0) AS varchar(10))

SELECT @StartTime = CONVERT(varchar(19), sqlserver_start_time, 120)
  FROM sys.dm_os_sys_info

SET @MarketingName = CASE
    WHEN @MajorVersion <= 4 THEN 'SQL Server ' + @NumericVersion
    WHEN @MajorVersion = 6 AND ISNULL(@MinorVersion, 0) < 50 THEN 'SQL Server 6.0'
    WHEN @MajorVersion = 6 THEN 'SQL Server 6.5'
    WHEN @MajorVersion = 7 THEN 'SQL Server 7.0'
    WHEN @MajorVersion = 8 THEN 'SQL Server 2000'
    WHEN @MajorVersion = 9 THEN 'SQL Server 2005'
    WHEN @MajorVersion = 10 AND ISNULL(@MinorVersion, 0) < 50 THEN 'SQL Server 2008'
    WHEN @MajorVersion = 10 THEN 'SQL Server 2008 R2'
    WHEN @MajorVersion = 11 THEN 'SQL Server 2012'
    WHEN @MajorVersion = 12 THEN 'SQL Server 2014'
    WHEN @MajorVersion = 13 THEN 'SQL Server 2016'
    WHEN @MajorVersion = 14 THEN 'SQL Server 2017'
    WHEN @MajorVersion = 15 THEN 'SQL Server 2019'
    WHEN @MajorVersion = 16 THEN 'SQL Server 2022'
    WHEN @MajorVersion = 17 THEN 'SQL Server 2025'
    ELSE 'SQL Server (version ' + @NumericVersion + ')'
END

SET @VersionKey = CASE
    WHEN @MajorVersion <= 4 THEN @NumericVersion
    WHEN @MajorVersion = 6 AND ISNULL(@MinorVersion, 0) < 50 THEN '6.0'
    WHEN @MajorVersion = 6 THEN '6.5'
    WHEN @MajorVersion = 7 THEN '7.0'
    WHEN @MajorVersion = 8 THEN '8.0'
    WHEN @MajorVersion = 9 THEN '9.0'
    WHEN @MajorVersion = 10 AND ISNULL(@MinorVersion, 0) < 50 THEN '10.0'
    WHEN @MajorVersion = 10 THEN '10.50'
    WHEN @MajorVersion = 11 THEN '11.0'
    WHEN @MajorVersion = 12 THEN '12.0'
    WHEN @MajorVersion = 13 THEN '13.0'
    WHEN @MajorVersion = 14 THEN '14.0'
    WHEN @MajorVersion = 15 THEN '15.0'
    WHEN @MajorVersion = 16 THEN '16.0'
    WHEN @MajorVersion = 17 THEN '17.0'
    ELSE @NumericVersion
END

IF OBJECT_ID('tempdb..#VersionHistory') IS NOT NULL
    DROP TABLE #VersionHistory

CREATE TABLE #VersionHistory
(
    SortOrder      int          NOT NULL,
    ReleaseYear    smallint     NOT NULL,
    NumericVersion varchar(10)  NOT NULL,
    MarketingName  varchar(40)  NOT NULL,
    CodeName       varchar(20)  NULL,
    IsCurrent      bit          NOT NULL
)

INSERT INTO #VersionHistory
(
    SortOrder,
    ReleaseYear,
    NumericVersion,
    MarketingName,
    CodeName,
    IsCurrent
)
VALUES
    ( 1, 1989, '1.0',   'SQL Server 1.0',              'Filipi',       CASE WHEN @VersionKey = '1.0'   THEN 1 ELSE 0 END),
    ( 2, 1990, '1.1',   'SQL Server 1.1',              'Pietro',       CASE WHEN @VersionKey = '1.1'   THEN 1 ELSE 0 END),
    ( 3, 1992, '4.2',   'SQL Server 4.2',              NULL,           CASE WHEN @VersionKey = '4.2'   THEN 1 ELSE 0 END),
    ( 4, 1993, '4.21',  'SQL Server 4.21',             'SQLNT',        CASE WHEN @VersionKey = '4.21'  THEN 1 ELSE 0 END),
    ( 5, 1995, '6.0',   'SQL Server 6.0',              'SQL95',        CASE WHEN @VersionKey = '6.0'   THEN 1 ELSE 0 END),
    ( 6, 1996, '6.5',   'SQL Server 6.5',              'Hydra',        CASE WHEN @VersionKey = '6.5'   THEN 1 ELSE 0 END),
    ( 7, 1998, '7.0',   'SQL Server 7.0',              'Sphinx',       CASE WHEN @VersionKey = '7.0'   THEN 1 ELSE 0 END),
    ( 8, 2000, '8.0',   'SQL Server 2000',             'Shiloh',       CASE WHEN @VersionKey = '8.0'   THEN 1 ELSE 0 END),
    ( 9, 2005, '9.0',   'SQL Server 2005',             'Yukon',        CASE WHEN @VersionKey = '9.0'   THEN 1 ELSE 0 END),
    (10, 2008, '10.0',  'SQL Server 2008',             'Katmai',       CASE WHEN @VersionKey = '10.0'  THEN 1 ELSE 0 END),
    (11, 2010, '10.50', 'SQL Server 2008 R2',          'Kilimanjaro',  CASE WHEN @VersionKey = '10.50' THEN 1 ELSE 0 END),
    (12, 2012, '11.0',  'SQL Server 2012',             'Denali',       CASE WHEN @VersionKey = '11.0'  THEN 1 ELSE 0 END),
    (13, 2014, '12.0',  'SQL Server 2014',             'Hekaton',      CASE WHEN @VersionKey = '12.0'  THEN 1 ELSE 0 END),
    (14, 2016, '13.0',  'SQL Server 2016',             'SQL16',        CASE WHEN @VersionKey = '13.0'  THEN 1 ELSE 0 END),
    (15, 2017, '14.0',  'SQL Server 2017',             'Helsinki',     CASE WHEN @VersionKey = '14.0'  THEN 1 ELSE 0 END),
    (16, 2019, '15.0',  'SQL Server 2019',             'Seattle',      CASE WHEN @VersionKey = '15.0'  THEN 1 ELSE 0 END),
    (17, 2022, '16.0',  'SQL Server 2022',             'Dallas',       CASE WHEN @VersionKey = '16.0'  THEN 1 ELSE 0 END),
    (18, 2025, '17.0',  'SQL Server 2025',             NULL,           CASE WHEN @VersionKey = '17.0'  THEN 1 ELSE 0 END)

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
SELECT @LineNo + 1, LEFT('= SQL SERVER VERSION REPORT =' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 3, LEFT(' Server: ' + @ServerName + '  |  ' + @ReportTime + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT @LineNo + 5, LEFT(' CURRENT INSTANCE' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 6, LEFT(@Divider, @ReportWidth)

SET @LineNo = 7

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo,     LEFT(' Marketing name : ' + @MarketingName + @BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(' Numeric version: ' + @NumericVersion + '  (build ' + ISNULL(CAST(@BuildVersion AS varchar(12)), 'n/a') + ')' + @BlankLine, @ReportWidth)),
    (@LineNo + 2, LEFT(' Product version: ' + @ProductVersion + @BlankLine, @ReportWidth)),
    (@LineNo + 3, LEFT(' Product level  : ' + ISNULL(@ProductLevel, '') + @BlankLine, @ReportWidth)),
    (@LineNo + 4, LEFT(' Update level   : ' + ISNULL(NULLIF(@ProductUpdateLevel, ''), '(none)') + @BlankLine, @ReportWidth)),
    (@LineNo + 5, LEFT(' Edition        : ' + ISNULL(@Edition, '') + @BlankLine, @ReportWidth)),
    (@LineNo + 6, LEFT(' Engine edition : ' + CAST(@EngineEdition AS varchar(10)) + @BlankLine, @ReportWidth)),
    (@LineNo + 7, LEFT(' Instance start : ' + ISNULL(@StartTime, 'n/a') + @BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 8

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo, LEFT(@BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 1

SET @Line = LEFT(CAST(@@VERSION AS varchar(200)), @ReportWidth)
INSERT INTO #Report ([LineNo], ReportLine)
VALUES (@LineNo, LEFT(@Line + @BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 1

IF LEN(@@VERSION) > @ReportWidth
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES (@LineNo, LEFT(SUBSTRING(@@VERSION, @ReportWidth + 1, @ReportWidth) + @BlankLine, @ReportWidth))
    SET @LineNo = @LineNo + 1
END

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo,     LEFT(@BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(' VERSION HISTORY (1989 - 2026)' + @BlankLine, @ReportWidth)),
    (@LineNo + 2, LEFT(@Divider, @ReportWidth)),
    (@LineNo + 3, LEFT(
          RIGHT('YEAR' + @BlankLine, @YearWidth)
        + ' ' + LEFT('VERSION' + @BlankLine, @VersionWidth)
        + ' ' + LEFT('MARKETING NAME' + @BlankLine, @MarketingWidth)
        + ' ' + LEFT('CODE NAME' + @BlankLine, @CodeNameWidth)
        + ' ' + LEFT('STATUS' + @BlankLine, @StatusWidth),
        @ReportWidth)),
    (@LineNo + 4, LEFT(@Divider, @ReportWidth))

SET @LineNo = @LineNo + 5

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    @LineNo + ROW_NUMBER() OVER (ORDER BY v.SortOrder) - 1,
    LEFT(
          RIGHT(REPLICATE(' ', @YearWidth) + CAST(v.ReleaseYear AS varchar(6)), @YearWidth)
        + ' ' + LEFT(v.NumericVersion + @BlankLine, @VersionWidth)
        + ' ' + LEFT(v.MarketingName + @BlankLine, @MarketingWidth)
        + ' ' + LEFT(ISNULL(v.CodeName, '') + @BlankLine, @CodeNameWidth)
        + ' ' + LEFT(CASE WHEN v.IsCurrent = 1 THEN '<<< CURRENT' ELSE '' END + @BlankLine, @StatusWidth),
        @ReportWidth)
  FROM #VersionHistory AS v

SELECT @LineNo = ISNULL(MAX([LineNo]), @LineNo) + 1 FROM #Report

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo,     LEFT(@BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(' Note: Numeric version is the major/minor value in ProductVersion.' + @BlankLine, @ReportWidth)),
    (@LineNo + 2, LEFT('       SQL Server 2008 R2 reports as 10.50.x. Azure-only releases omitted.' + @BlankLine, @ReportWidth)),
    (@LineNo + 3, LEFT(@HeaderRule, @ReportWidth))

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

GO

IF OBJECT_ID('dbo.Version') IS NOT NULL
    PRINT 'Procedure Version created.'
ELSE
    PRINT 'Procedure Version NOT created.'
GO