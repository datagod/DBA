

/*
  ShowRunningPerformanceTraces.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.ShowRunningPerformanceTraces
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ShowRunningPerformanceTraces
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Lists performance traces started by StartPerformanceTrace that are still running.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

IF OBJECT_ID('dbo.PerformanceTraceControl') IS NULL
BEGIN
    RAISERROR('Table dbo.PerformanceTraceControl does not exist. Run PerformanceTraceResults.sql first.', 16, 1)
    RETURN
END

;WITH ActiveTraces AS
(
    SELECT
        TraceID = CONVERT(int, traceid),
        IsRunning = MAX(CASE WHEN property = 5 THEN CONVERT(int, value) END)
    FROM sys.fn_trace_getinfo(DEFAULT)
    GROUP BY traceid
)
SELECT
    ptc.TraceControlID,
    ptc.TraceID,
    ptc.TraceName,
    ptc.TraceFilePath,
    ptc.Status,
    ptc.StartTime,
    RunningMinutes = DATEDIFF(minute, ptc.StartTime, GETDATE()),
    ptc.FilterDatabaseName,
    ptc.FilterMinReads,
    ptc.FilterMinWrites,
    ptc.FilterMinDuration,
    ptc.FilterLoginName,
    ptc.FilterHostName,
    ptc.MaxFileSizeMB,
    ptc.StartedBy,
    ServerTraceStatus = CASE
                            WHEN at.IsRunning = 1 THEN 'Running'
                            WHEN at.TraceID IS NULL THEN 'Not Found'
                            ELSE 'Stopped'
                        END
FROM dbo.PerformanceTraceControl AS ptc
LEFT JOIN ActiveTraces AS at
    ON at.TraceID = ptc.TraceID
WHERE ptc.Status = 'Running'
ORDER BY ptc.StartTime DESC

GO