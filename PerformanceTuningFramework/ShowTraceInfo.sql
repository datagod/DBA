

/*
  ShowTraceInfo.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.ShowTraceInfo

  Optional parameters:
    @TraceControlID - show one trace (default: all traces)
    @Status         - Running | Stopped | Error (default: all statuses)
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ShowTraceInfo
(
    @TraceControlID int         = NULL,
    @Status         varchar(20) = NULL
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Reports performance trace status from PerformanceTraceControl and
--               PerformanceTraceResults, correlated with active server-side traces.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

IF OBJECT_ID('dbo.PerformanceTraceControl') IS NULL
   OR OBJECT_ID('dbo.PerformanceTraceResults') IS NULL
BEGIN
    RAISERROR('Performance trace tables do not exist. Run PerformanceTraceResults.sql first.', 16, 1)
    RETURN
END

IF @Status IS NOT NULL AND @Status NOT IN ('Running', 'Stopped', 'Error')
BEGIN
    RAISERROR('@Status must be Running, Stopped, Error, or NULL.', 16, 1)
    RETURN
END

;WITH ActiveTraces AS
(
    SELECT
        TraceID = CONVERT(int, traceid),
        IsRunning = MAX(CASE WHEN property = 5 THEN CONVERT(int, value) END),
        TraceFilePath = MAX(CASE WHEN property = 2 THEN CONVERT(nvarchar(500), value) END)
    FROM sys.fn_trace_getinfo(DEFAULT)
    GROUP BY traceid
),
ResultStats AS
(
    SELECT
        ptr.TraceControlID,
        ImportedEventCount = COUNT(*),
        DistinctDatabases = COUNT(DISTINCT ptr.DatabaseName),
        DistinctLogins = COUNT(DISTINCT ptr.LoginName),
        MaxDurationUs = MAX(ptr.Duration),
        AvgDurationUs = AVG(CAST(ptr.Duration AS bigint)),
        MaxReads = MAX(ptr.Reads),
        MaxWrites = MAX(ptr.Writes),
        FirstEventTime = MIN(ptr.StartTime),
        LastEventTime = MAX(ptr.EndTime),
        LastImportedDate = MAX(ptr.ImportedDate)
    FROM dbo.PerformanceTraceResults AS ptr
    GROUP BY ptr.TraceControlID
)
SELECT
    SummaryRunningTraces = SUM(CASE WHEN ptc.Status = 'Running' THEN 1 ELSE 0 END),
    SummaryStoppedTraces = SUM(CASE WHEN ptc.Status = 'Stopped' THEN 1 ELSE 0 END),
    SummaryErrorTraces = SUM(CASE WHEN ptc.Status = 'Error' THEN 1 ELSE 0 END),
    SummaryImportedEvents = (
        SELECT COUNT(*)
          FROM dbo.PerformanceTraceResults AS ptr
         WHERE @TraceControlID IS NULL
            OR ptr.TraceControlID = @TraceControlID
    )
FROM dbo.PerformanceTraceControl AS ptc
WHERE (@TraceControlID IS NULL OR ptc.TraceControlID = @TraceControlID)
  AND (@Status IS NULL OR ptc.Status = @Status)

;WITH ActiveTraces AS
(
    SELECT
        TraceID = CONVERT(int, traceid),
        IsRunning = MAX(CASE WHEN property = 5 THEN CONVERT(int, value) END),
        TraceFilePath = MAX(CASE WHEN property = 2 THEN CONVERT(nvarchar(500), value) END)
    FROM sys.fn_trace_getinfo(DEFAULT)
    GROUP BY traceid
),
ResultStats AS
(
    SELECT
        ptr.TraceControlID,
        ImportedEventCount = COUNT(*),
        DistinctDatabases = COUNT(DISTINCT ptr.DatabaseName),
        DistinctLogins = COUNT(DISTINCT ptr.LoginName),
        MaxDurationUs = MAX(ptr.Duration),
        AvgDurationUs = AVG(CAST(ptr.Duration AS bigint)),
        MaxReads = MAX(ptr.Reads),
        MaxWrites = MAX(ptr.Writes),
        FirstEventTime = MIN(ptr.StartTime),
        LastEventTime = MAX(ptr.EndTime),
        LastImportedDate = MAX(ptr.ImportedDate)
    FROM dbo.PerformanceTraceResults AS ptr
    GROUP BY ptr.TraceControlID
)
SELECT
    ptc.TraceControlID,
    ptc.TraceID,
    ptc.TraceName,
    ptc.Status,
    ptc.StartTime,
    ptc.EndTime,
    ElapsedMinutes = CASE
                         WHEN ptc.Status = 'Running' THEN DATEDIFF(minute, ptc.StartTime, GETDATE())
                         ELSE DATEDIFF(minute, ptc.StartTime, ISNULL(ptc.EndTime, ptc.StartTime))
                     END,
    ptc.TraceFilePath,
    ActiveTraceFilePath = at.TraceFilePath,
    ServerTraceStatus = CASE
                            WHEN at.IsRunning = 1 THEN 'Running'
                            WHEN at.TraceID IS NULL THEN 'Not Found'
                            ELSE 'Stopped'
                        END,
    TraceStateSummary = CASE
                            WHEN ptc.Status = 'Running' AND at.IsRunning = 1
                                THEN 'Trace is running on the server and capturing events.'
                            WHEN ptc.Status = 'Running' AND at.TraceID IS NULL
                                THEN 'Trace is marked running in control table but not found on the server.'
                            WHEN ptc.Status = 'Running' AND ISNULL(at.IsRunning, 0) = 0
                                THEN 'Trace is marked running in control table but stopped on the server.'
                            WHEN ptc.Status = 'Stopped'
                                THEN 'Trace stopped. ' + ISNULL(CAST(rs.ImportedEventCount AS varchar(20)), '0')
                                     + ' events imported into PerformanceTraceResults.'
                            WHEN ptc.Status = 'Error'
                                THEN 'Trace ended with an import error. Review trace file and StopPerformanceTrace output.'
                            ELSE 'Trace status unknown.'
                        END,
    ptc.FilterDatabaseName,
    ptc.FilterMinReads,
    ptc.FilterMinWrites,
    ptc.FilterMinDuration,
    ptc.FilterLoginName,
    ptc.FilterHostName,
    ptc.MaxFileSizeMB,
    ptc.StartedBy,
    ptc.RowsImported,
    rs.ImportedEventCount,
    rs.DistinctDatabases,
    rs.DistinctLogins,
    MaxDurationMs = CAST(rs.MaxDurationUs / 1000.0 AS decimal(18, 2)),
    AvgDurationMs = CAST(rs.AvgDurationUs / 1000.0 AS decimal(18, 2)),
    rs.MaxReads,
    rs.MaxWrites,
    rs.FirstEventTime,
    rs.LastEventTime,
    rs.LastImportedDate,
    StopCommand = 'EXEC dbo.StopPerformanceTrace @TraceControlID = '
                  + CAST(ptc.TraceControlID AS varchar(20))
FROM dbo.PerformanceTraceControl AS ptc
LEFT JOIN ActiveTraces AS at
    ON at.TraceID = ptc.TraceID
LEFT JOIN ResultStats AS rs
    ON rs.TraceControlID = ptc.TraceControlID
WHERE (@TraceControlID IS NULL OR ptc.TraceControlID = @TraceControlID)
  AND (@Status IS NULL OR ptc.Status = @Status)
ORDER BY
    CASE ptc.Status WHEN 'Running' THEN 0 WHEN 'Error' THEN 1 ELSE 2 END,
    ptc.StartTime DESC

GO