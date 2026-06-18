

/*
  StopPerformanceTrace.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.StopPerformanceTrace @TraceControlID = 1

  Identify the trace with ShowRunningPerformanceTraces.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.StopPerformanceTrace
(
    @TraceControlID int = NULL,
    @TraceID        int = NULL,
    @TraceName      sysname = NULL
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Stops a running server-side trace, imports the trace file into
--               PerformanceTraceResults, and updates trace control metadata.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @ReturnCode        int,
    @TraceFilePath     nvarchar(500),
    @TraceFileImport   nvarchar(500),
    @Status            varchar(20),
    @EndTime           datetime,
    @RowsImported      int,
    @FilterDatabaseName sysname,
    @FilterMinReads    bigint,
    @FilterMinWrites   bigint,
    @FilterMinDuration bigint,
    @FilterLoginName   sysname,
    @FilterHostName    sysname,
    @Sql               nvarchar(max)

IF OBJECT_ID('dbo.PerformanceTraceControl') IS NULL
   OR OBJECT_ID('dbo.PerformanceTraceResults') IS NULL
BEGIN
    RAISERROR('Performance trace tables do not exist. Run PerformanceTraceResults.sql first.', 16, 1)
    RETURN
END

IF @TraceControlID IS NULL AND @TraceID IS NULL AND @TraceName IS NULL
BEGIN
    RAISERROR('Specify @TraceControlID, @TraceID, or @TraceName.', 16, 1)
    RETURN
END

SELECT
    @TraceControlID = TraceControlID,
    @TraceID = TraceID,
    @TraceName = TraceName,
    @TraceFilePath = TraceFilePath,
    @Status = Status,
    @FilterDatabaseName = FilterDatabaseName,
    @FilterMinReads = FilterMinReads,
    @FilterMinWrites = FilterMinWrites,
    @FilterMinDuration = FilterMinDuration,
    @FilterLoginName = FilterLoginName,
    @FilterHostName = FilterHostName
FROM dbo.PerformanceTraceControl
WHERE (@TraceControlID IS NOT NULL AND TraceControlID = @TraceControlID)
   OR (@TraceControlID IS NULL AND @TraceID IS NOT NULL AND TraceID = @TraceID)
   OR (@TraceControlID IS NULL AND @TraceID IS NULL AND @TraceName IS NOT NULL AND TraceName = @TraceName)

IF @TraceControlID IS NULL
BEGIN
    RAISERROR('Performance trace not found.', 16, 1)
    RETURN
END

IF @Status <> 'Running'
BEGIN
    RAISERROR('Trace %s (TraceControlID %d) is not running. Current status: %s', 16, 1, @TraceName, @TraceControlID, @Status)
    RETURN
END

IF EXISTS (
    SELECT 1
      FROM sys.fn_trace_getinfo(@TraceID)
     WHERE property = 5
       AND CONVERT(int, value) = 1
)
BEGIN
    EXEC @ReturnCode = sp_trace_setstatus @TraceID, 0

    IF @ReturnCode <> 0
    BEGIN
        RAISERROR('sp_trace_setstatus stop failed with return code %d for TraceID %d.', 16, 1, @ReturnCode, @TraceID)
        RETURN
    END
END

EXEC @ReturnCode = sp_trace_setstatus @TraceID, 2

SET @EndTime = GETDATE()
SET @TraceFileImport = @TraceFilePath + N'.trc'

IF OBJECT_ID('tempdb..#TraceImport') IS NOT NULL
    DROP TABLE #TraceImport

CREATE TABLE #TraceImport
(
    RowNumber        int            NOT NULL,
    EventClass       int            NULL,
    EventSubClass    int            NULL,
    DatabaseName     nvarchar(128)  NULL,
    ObjectName       nvarchar(128)  NULL,
    TextData         nvarchar(max)  NULL,
    Reads            bigint         NULL,
    Writes           bigint         NULL,
    CPU              int            NULL,
    Duration         bigint         NULL,
    RowCounts        bigint         NULL,
    LoginName        nvarchar(128)  NULL,
    HostName         nvarchar(128)  NULL,
    ApplicationName  nvarchar(128)  NULL,
    SPID             int            NULL,
    StartTime        datetime       NULL,
    EndTime          datetime       NULL
)

BEGIN TRY
    SET @Sql = N'
    INSERT INTO #TraceImport
    (
        RowNumber,
        EventClass,
        EventSubClass,
        DatabaseName,
        ObjectName,
        TextData,
        Reads,
        Writes,
        CPU,
        Duration,
        RowCounts,
        LoginName,
        HostName,
        ApplicationName,
        SPID,
        StartTime,
        EndTime
    )
    SELECT
        RowNumber = ROW_NUMBER() OVER (ORDER BY StartTime, EventClass),
        EventClass,
        EventSubClass,
        DatabaseName,
        ObjectName,
        CONVERT(nvarchar(max), TextData),
        Reads,
        Writes,
        CPU,
        Duration,
        RowCounts,
        LoginName,
        HostName,
        ApplicationName,
        SPID,
        StartTime,
        EndTime
    FROM fn_trace_gettable(@TraceFileImport, DEFAULT)
    WHERE EventClass IN (10, 12, 45)'

    EXEC sys.sp_executesql
        @Sql,
        N'@TraceFileImport nvarchar(500)',
        @TraceFileImport = @TraceFileImport
END TRY
BEGIN CATCH
    UPDATE dbo.PerformanceTraceControl
       SET Status = 'Error',
           EndTime = @EndTime
     WHERE TraceControlID = @TraceControlID

    DECLARE @ImportError nvarchar(4000) = ERROR_MESSAGE()
    RAISERROR('Failed to import trace file %s. %s', 16, 1, @TraceFileImport, @ImportError)
    RETURN
END CATCH

INSERT INTO dbo.PerformanceTraceResults
(
    TraceControlID,
    TraceID,
    EventClass,
    EventSubclass,
    DatabaseName,
    ObjectName,
    QueryText,
    Reads,
    Writes,
    CPU,
    Duration,
    RowCounts,
    LoginName,
    HostName,
    ApplicationName,
    SPID,
    StartTime,
    EndTime,
    ImportedDate
)
SELECT
    @TraceControlID,
    @TraceID,
    ti.EventClass,
    ti.EventSubClass,
    ti.DatabaseName,
    ti.ObjectName,
    ti.TextData,
    ti.Reads,
    ti.Writes,
    ti.CPU,
    ti.Duration,
    ti.RowCounts,
    ti.LoginName,
    ti.HostName,
    ti.ApplicationName,
    ti.SPID,
    ti.StartTime,
    ti.EndTime,
    @EndTime
FROM #TraceImport AS ti
WHERE (@FilterDatabaseName IS NULL OR ti.DatabaseName IS NOT NULL)
  AND (@FilterMinReads IS NULL OR ti.Reads IS NOT NULL)
  AND (@FilterMinWrites IS NULL OR ti.Writes IS NOT NULL)
  AND (@FilterMinDuration IS NULL OR ti.Duration IS NOT NULL)
  AND (@FilterLoginName IS NULL OR ti.LoginName IS NOT NULL)
  AND (@FilterHostName IS NULL OR ti.HostName IS NOT NULL)
  AND (@FilterDatabaseName IS NULL OR ti.DatabaseName LIKE @FilterDatabaseName)
  AND (@FilterMinReads IS NULL OR ti.Reads >= @FilterMinReads)
  AND (@FilterMinWrites IS NULL OR ti.Writes >= @FilterMinWrites)
  AND (@FilterMinDuration IS NULL OR ti.Duration >= @FilterMinDuration)
  AND (@FilterLoginName IS NULL OR ti.LoginName LIKE @FilterLoginName)
  AND (@FilterHostName IS NULL OR ti.HostName LIKE @FilterHostName)

SET @RowsImported = @@ROWCOUNT

UPDATE dbo.PerformanceTraceControl
   SET Status = 'Stopped',
       EndTime = @EndTime,
       RowsImported = @RowsImported
 WHERE TraceControlID = @TraceControlID

SELECT
    TraceControlID = @TraceControlID,
    TraceID        = @TraceID,
    TraceName      = @TraceName,
    Status         = 'Stopped',
    EndTime        = @EndTime,
    RowsImported   = @RowsImported,
    TraceFilePath  = @TraceFileImport

GO