
/*
  CompareDatabasePerformance.sql
  Performance Tuning Framework

  Deploy to the tool database after DatabasePerformanceAnalysis.sql and ExamineDatabasePerformance.sql.
  Compare two capture runs (for example, a fast database vs a slow database).

    EXEC dbo.CompareDatabasePerformance
        @AnalysisRunID_A = @FastDbRun,
        @AnalysisRunID_B = @SlowDbRun
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.CompareDatabasePerformance
(
    @AnalysisRunID_A uniqueidentifier,
    @AnalysisRunID_B uniqueidentifier
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 23, 2026
-- Author:       Bill McEvoy
-- Description:  Side-by-side comparison of two ExamineDatabasePerformance capture runs.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @AnalysisRunID_A_Text varchar(36),
    @AnalysisRunID_B_Text varchar(36)

IF OBJECT_ID('dbo.DatabasePerformanceRun') IS NULL
BEGIN
    RAISERROR('Tables dbo.DatabasePerformanceRun/Metric/Finding do not exist. Run DatabasePerformanceAnalysis.sql first.', 16, 1)
    RETURN
END

IF NOT EXISTS (SELECT 1 FROM dbo.DatabasePerformanceRun WHERE AnalysisRunID = @AnalysisRunID_A)
BEGIN
    SET @AnalysisRunID_A_Text = CONVERT(varchar(36), @AnalysisRunID_A)
    RAISERROR('AnalysisRunID_A %s was not found.', 16, 1, @AnalysisRunID_A_Text)
    RETURN
END

IF NOT EXISTS (SELECT 1 FROM dbo.DatabasePerformanceRun WHERE AnalysisRunID = @AnalysisRunID_B)
BEGIN
    SET @AnalysisRunID_B_Text = CONVERT(varchar(36), @AnalysisRunID_B)
    RAISERROR('AnalysisRunID_B %s was not found.', 16, 1, @AnalysisRunID_B_Text)
    RETURN
END

SELECT
    RunA = ra.DatabaseName,
    RunB = rb.DatabaseName,
    CaptureA = ra.CaptureDate,
    CaptureB = rb.CaptureDate,
    ServerA = ra.ServerName,
    ServerB = rb.ServerName,
    SqlVersionA = ra.ProductVersion,
    SqlVersionB = rb.ProductVersion
  FROM dbo.DatabasePerformanceRun AS ra
 CROSS JOIN dbo.DatabasePerformanceRun AS rb
 WHERE ra.AnalysisRunID = @AnalysisRunID_A
   AND rb.AnalysisRunID = @AnalysisRunID_B

SELECT
    Category = COALESCE(a.Category, b.Category),
    MetricName = COALESCE(a.MetricName, b.MetricName),
    RunA_Value = a.MetricValue,
    RunB_Value = b.MetricValue,
    RunA_Numeric = a.MetricNumeric,
    RunB_Numeric = b.MetricNumeric,
    NumericDelta = ISNULL(b.MetricNumeric, 0) - ISNULL(a.MetricNumeric, 0),
    ValueDiffers = CASE
                       WHEN ISNULL(a.MetricValue, N'') <> ISNULL(b.MetricValue, N'') THEN 1
                       ELSE 0
                   END
  FROM (
      SELECT Category, MetricName, MetricValue, MetricNumeric
        FROM dbo.DatabasePerformanceMetric
       WHERE AnalysisRunID = @AnalysisRunID_A
  ) AS a
  FULL OUTER JOIN (
      SELECT Category, MetricName, MetricValue, MetricNumeric
        FROM dbo.DatabasePerformanceMetric
       WHERE AnalysisRunID = @AnalysisRunID_B
  ) AS b
    ON b.Category = a.Category
   AND b.MetricName = a.MetricName
 ORDER BY ValueDiffers DESC, Category, MetricName

SELECT
    Category,
    RunA_Count = SUM(CASE WHEN f.AnalysisRunID = @AnalysisRunID_A THEN 1 ELSE 0 END),
    RunB_Count = SUM(CASE WHEN f.AnalysisRunID = @AnalysisRunID_B THEN 1 ELSE 0 END),
    CountDelta = SUM(CASE WHEN f.AnalysisRunID = @AnalysisRunID_B THEN 1 ELSE 0 END)
               - SUM(CASE WHEN f.AnalysisRunID = @AnalysisRunID_A THEN 1 ELSE 0 END)
  FROM dbo.DatabasePerformanceFinding AS f
 WHERE f.AnalysisRunID IN (@AnalysisRunID_A, @AnalysisRunID_B)
 GROUP BY Category
 ORDER BY ABS(
           SUM(CASE WHEN f.AnalysisRunID = @AnalysisRunID_B THEN 1 ELSE 0 END)
         - SUM(CASE WHEN f.AnalysisRunID = @AnalysisRunID_A THEN 1 ELSE 0 END)
       ) DESC, Category

GO