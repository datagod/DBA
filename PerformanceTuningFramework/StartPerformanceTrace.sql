

/*
  StartPerformanceTrace.sql
  Performance Tuning Framework

  Deploy to the tool database after PerformanceTraceResults.sql, then execute:
    EXEC dbo.StartPerformanceTrace

  Optional filters (NULL = no filter / use trace defaults):
    @DatabaseName, @MinReads, @MinWrites, @MinDuration, @LoginName, @HostName

  When a filter is populated, matching NULL rows are excluded on import at stop time.

  Note: create the trace folder on the SQL Server host before starting, for example:
    {InstanceDefaultDataPath}\PerformanceTraces\

  To list candidate local paths:
    EXEC dbo.ShowTraceWritablePaths
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.StartPerformanceTrace
(
    @TraceName         sysname       = NULL,
    @DatabaseName      sysname       = NULL,
    @MinReads          bigint        = NULL,
    @MinWrites         bigint        = NULL,
    @MinDuration       bigint        = NULL,
    @LoginName         sysname       = NULL,
    @HostName          sysname       = NULL,
    @TraceFilePath     nvarchar(245) = NULL,
    @MaxFileSizeMB     int           = 100,
    @TraceControlID    int           = NULL OUTPUT
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Starts a server-side SQL Trace and records control metadata in the tool database.
--               Results are imported into PerformanceTraceResults when the trace is stopped.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @TraceID           int,
    @ReturnCode        int,
    @TraceFileBase     nvarchar(245),
    @DefaultDataPath   nvarchar(260),
    @StartTime         datetime,
    @EventID           int,
    @ColumnID          int,
    @FilterValue       nvarchar(256)

IF OBJECT_ID('dbo.PerformanceTraceControl') IS NULL
   OR OBJECT_ID('dbo.PerformanceTraceResults') IS NULL
BEGIN
    RAISERROR('Performance trace tables do not exist. Run PerformanceTraceResults.sql first.', 16, 1)
    RETURN
END

IF ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE'), 0) = 0
BEGIN
    RAISERROR('ALTER TRACE permission is required to start a server-side trace.', 16, 1)
    RETURN
END

IF @MaxFileSizeMB IS NULL OR @MaxFileSizeMB < 1
    SET @MaxFileSizeMB = 100

IF @TraceName IS NULL
    SET @TraceName = 'PerfTrace_' + REPLACE(REPLACE(REPLACE(CONVERT(varchar(19), GETDATE(), 120), '-', ''), ':', ''), ' ', '_')

IF EXISTS (
    SELECT 1
      FROM dbo.PerformanceTraceControl
     WHERE TraceName = @TraceName
       AND Status = 'Running'
)
BEGIN
    RAISERROR('A performance trace named ''%s'' is already running.', 16, 1, @TraceName)
    RETURN
END

SET @DefaultDataPath = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(260))

IF @TraceFilePath IS NULL
    SET @TraceFileBase = @DefaultDataPath + N'PerformanceTraces\' + @TraceName
ELSE
    SET @TraceFileBase = CASE
                             WHEN RIGHT(@TraceFilePath, 1) IN (N'\', N'/') THEN @TraceFilePath + @TraceName
                             ELSE @TraceFilePath
                         END

SET @StartTime = GETDATE()

EXEC @ReturnCode = sp_trace_create
    @TraceID OUTPUT,
    2,
    @TraceFileBase,
    @MaxFileSizeMB,
    @stoptime = NULL

IF @ReturnCode <> 0 OR @TraceID IS NULL
BEGIN
    RAISERROR('sp_trace_create failed with return code %d. Verify the trace folder exists and the path is valid.', 16, 1, @ReturnCode)
    RETURN
END

DECLARE EventCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT EventID
      FROM (VALUES (10), (12), (45)) AS e(EventID)

OPEN EventCursor
FETCH NEXT FROM EventCursor INTO @EventID

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE ColumnCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT ColumnID
          FROM (VALUES
                (1), (9), (10), (11), (12), (13), (14), (15), (16), (17), (18),
                (19), (34), (35), (48)
          ) AS c(ColumnID)

    OPEN ColumnCursor
    FETCH NEXT FROM ColumnCursor INTO @ColumnID

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sp_trace_setevent @TraceID, @EventID, @ColumnID, 1
        FETCH NEXT FROM ColumnCursor INTO @ColumnID
    END

    CLOSE ColumnCursor
    DEALLOCATE ColumnCursor

    FETCH NEXT FROM EventCursor INTO @EventID
END

CLOSE EventCursor
DEALLOCATE EventCursor

IF @DatabaseName IS NOT NULL
BEGIN
    SET @FilterValue = CONVERT(nvarchar(256), @DatabaseName)
    EXEC sp_trace_setfilter @TraceID, 35, 0, 6, @FilterValue
END

IF @MinReads IS NOT NULL
    EXEC sp_trace_setfilter @TraceID, 16, 0, 4, @MinReads

IF @MinWrites IS NOT NULL
    EXEC sp_trace_setfilter @TraceID, 17, 0, 4, @MinWrites

IF @MinDuration IS NOT NULL
    EXEC sp_trace_setfilter @TraceID, 13, 0, 4, @MinDuration

IF @LoginName IS NOT NULL
BEGIN
    SET @FilterValue = CONVERT(nvarchar(256), @LoginName)
    EXEC sp_trace_setfilter @TraceID, 11, 0, 6, @FilterValue
END

IF @HostName IS NOT NULL
BEGIN
    SET @FilterValue = CONVERT(nvarchar(256), @HostName)
    EXEC sp_trace_setfilter @TraceID, 48, 0, 6, @FilterValue
END

EXEC @ReturnCode = sp_trace_setstatus @TraceID, 1

IF @ReturnCode <> 0
BEGIN
    EXEC sp_trace_setstatus @TraceID, 2
    RAISERROR('sp_trace_setstatus start failed with return code %d.', 16, 1, @ReturnCode)
    RETURN
END

INSERT INTO dbo.PerformanceTraceControl
(
    TraceID,
    TraceName,
    TraceFilePath,
    Status,
    StartTime,
    FilterDatabaseName,
    FilterMinReads,
    FilterMinWrites,
    FilterMinDuration,
    FilterLoginName,
    FilterHostName,
    MaxFileSizeMB,
    StartedBy
)
VALUES
(
    @TraceID,
    @TraceName,
    @TraceFileBase,
    'Running',
    @StartTime,
    @DatabaseName,
    @MinReads,
    @MinWrites,
    @MinDuration,
    @LoginName,
    @HostName,
    @MaxFileSizeMB,
    SUSER_SNAME()
)

SET @TraceControlID = SCOPE_IDENTITY()

SELECT
    TraceControlID      = @TraceControlID,
    TraceID             = @TraceID,
    TraceName           = @TraceName,
    TraceFilePath       = @TraceFileBase,
    Status              = 'Running',
    StartTime           = @StartTime,
    FilterDatabaseName  = @DatabaseName,
    FilterMinReads      = @MinReads,
    FilterMinWrites     = @MinWrites,
    FilterMinDuration   = @MinDuration,
    FilterLoginName     = @LoginName,
    FilterHostName      = @HostName,
    MaxFileSizeMB       = @MaxFileSizeMB

GO