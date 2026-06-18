

/*
  ShowTraceWritablePaths.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.ShowTraceWritablePaths

  Lists local server paths where the SQL Server service can typically write
  server-side trace (.trc) files, including free space where available.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ShowTraceWritablePaths
(
    @IncludeActiveTraces bit = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Shows recommended and candidate local paths for server-side SQL Trace files.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion        tinyint,
    @DefaultDataPath     nvarchar(260),
    @DefaultLogPath      nvarchar(260),
    @PathSeparator       nchar(1),
    @RecommendedPath     nvarchar(245),
    @ServiceAccount      nvarchar(256),
    @MaxTracePathLength  tinyint

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @DefaultDataPath = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(260))
SET @DefaultLogPath  = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(260))
SET @PathSeparator   = CASE
                           WHEN CHARINDEX(N'/', @DefaultDataPath) > 0 THEN N'/'
                           ELSE N'\'
                       END
SET @RecommendedPath = CASE
                           WHEN RIGHT(@DefaultDataPath, 1) IN (N'\', N'/')
                               THEN @DefaultDataPath + N'PerformanceTraces' + @PathSeparator
                           ELSE @DefaultDataPath + @PathSeparator + N'PerformanceTraces' + @PathSeparator
                       END
SET @MaxTracePathLength = 245

IF OBJECT_ID('tempdb..#TracePaths') IS NOT NULL
    DROP TABLE #TracePaths

CREATE TABLE #TracePaths
(
    SortOrder        int            NOT NULL,
    PathType         varchar(40)    NOT NULL,
    TraceFolderPath  nvarchar(245)  NOT NULL,
    ExampleTraceFile nvarchar(245)  NOT NULL,
    DriveLetter      nvarchar(260)  NULL,
    FreeSpaceGB      decimal(12, 2) NULL,
    Notes            varchar(200)   NOT NULL
)

IF @MajorVersion >= 10
BEGIN
    SELECT TOP (1)
        @ServiceAccount = service_account
      FROM sys.dm_server_services
     WHERE servicename LIKE 'SQL Server (%'
        OR servicename = 'MSSQLSERVER'
END

INSERT INTO #TracePaths
(
    SortOrder,
    PathType,
    TraceFolderPath,
    ExampleTraceFile,
    Notes
)
VALUES
(
    1,
    'Recommended Default',
    LEFT(@RecommendedPath, 245),
    LEFT(@RecommendedPath + N'MyTrace', 245),
    'Default used by StartPerformanceTrace. Create this folder on the server if it does not exist.'
),
(
    2,
    'Instance Data Path',
    LEFT(CASE
             WHEN RIGHT(@DefaultDataPath, 1) IN (N'\', N'/') THEN @DefaultDataPath
             ELSE @DefaultDataPath + @PathSeparator
         END, 245),
    LEFT(CASE
             WHEN RIGHT(@DefaultDataPath, 1) IN (N'\', N'/') THEN @DefaultDataPath
             ELSE @DefaultDataPath + @PathSeparator
         END + N'MyTrace', 245),
    'Instance default data directory. Usually writable by the SQL Server service account.'
),
(
    3,
    'Instance Log Path',
    LEFT(CASE
             WHEN RIGHT(@DefaultLogPath, 1) IN (N'\', N'/') THEN @DefaultLogPath
             ELSE @DefaultLogPath + @PathSeparator
         END, 245),
    LEFT(CASE
             WHEN RIGHT(@DefaultLogPath, 1) IN (N'\', N'/') THEN @DefaultLogPath
             ELSE @DefaultLogPath + @PathSeparator
         END + N'MyTrace', 245),
    'Instance default log directory.'
)

IF @MajorVersion >= 10
BEGIN
    ;WITH DbFileFolders AS
    (
        SELECT DISTINCT
            FolderPath = LEFT(
                mf.physical_name,
                LEN(mf.physical_name) - CHARINDEX(
                    @PathSeparator,
                    REVERSE(mf.physical_name)))
            + @PathSeparator
        FROM sys.master_files AS mf
        WHERE mf.physical_name IS NOT NULL
    )
    INSERT INTO #TracePaths
    (
        SortOrder,
        PathType,
        TraceFolderPath,
        ExampleTraceFile,
        Notes
    )
    SELECT
        100 + ROW_NUMBER() OVER (ORDER BY dff.FolderPath),
        'Database File Folder',
        LEFT(dff.FolderPath, 245),
        LEFT(dff.FolderPath + N'MyTrace', 245),
        'Folder already used by a database file on this instance.'
    FROM DbFileFolders AS dff
    WHERE NOT EXISTS (
        SELECT 1
          FROM #TracePaths AS tp
         WHERE tp.TraceFolderPath = LEFT(dff.FolderPath, 245)
    )
END

IF @IncludeActiveTraces = 1
BEGIN
    INSERT INTO #TracePaths
    (
        SortOrder,
        PathType,
        TraceFolderPath,
        ExampleTraceFile,
        Notes
    )
    SELECT
        200 + ROW_NUMBER() OVER (ORDER BY ti.TraceFolderPath),
        'Active Trace Folder',
        ti.TraceFolderPath,
        ti.ExampleTraceFile,
        'Folder currently in use by an active server-side trace.'
    FROM (
        SELECT DISTINCT
            TraceFolderPath = LEFT(
                CONVERT(nvarchar(245), tgi.value),
                LEN(CONVERT(nvarchar(245), tgi.value))
                - CHARINDEX(@PathSeparator, REVERSE(CONVERT(nvarchar(245), tgi.value))))
            + @PathSeparator,
            ExampleTraceFile = LEFT(CONVERT(nvarchar(245), tgi.value), 245)
        FROM sys.fn_trace_getinfo(DEFAULT) AS tgi
        WHERE tgi.property = 2
          AND tgi.value IS NOT NULL
    ) AS ti
    WHERE ti.TraceFolderPath IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
            FROM #TracePaths AS tp
           WHERE tp.TraceFolderPath = ti.TraceFolderPath
      )
END

IF @MajorVersion >= 10
BEGIN
    ;WITH DriveSpace AS
    (
        SELECT DISTINCT
            UPPER(vs.volume_mount_point) AS DriveLetter,
            FreeSpaceGB = CAST(vs.available_bytes / 1024.0 / 1024 / 1024 AS decimal(12, 2))
        FROM sys.master_files AS mf
        CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
    )
    UPDATE tp
       SET tp.DriveLetter = ds.DriveLetter,
           tp.FreeSpaceGB = ds.FreeSpaceGB
      FROM #TracePaths AS tp
     INNER JOIN DriveSpace AS ds
        ON tp.TraceFolderPath LIKE ds.DriveLetter + N'%'
END

SELECT
    PathType,
    TraceFolderPath,
    ExampleTraceFile,
    DriveLetter,
    FreeSpaceGB,
    PathLength = LEN(TraceFolderPath),
    WithinTraceLimit = CASE
                           WHEN LEN(TraceFolderPath) <= @MaxTracePathLength THEN 'Yes'
                           ELSE 'No'
                       END,
    Notes
FROM #TracePaths
ORDER BY SortOrder, TraceFolderPath

SELECT
    ServiceAccount        = @ServiceAccount,
    MaxTracePathLength    = @MaxTracePathLength,
    RecommendedTracePath  = @RecommendedPath,
    StartTraceExample     = CONVERT(varchar(200),
        'EXEC dbo.StartPerformanceTrace @TraceFilePath = N'''
        + REPLACE(LEFT(@RecommendedPath, 180), '''', '''''') + ''', @TraceName = N''MyTrace''')

GO