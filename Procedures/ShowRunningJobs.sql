
/*
  ShowRunningJobs.sql

  Requires: dbo.vRunningJobs, dbo.fn_SecondsToTime

  Deploy to the DBA tool database, then execute:
    EXEC dbo.ShowRunningJobs
    EXEC dbo.ShowRunningJobs @LongRunningMinutes = 60
*/

USE DBA
GO

IF OBJECT_ID('dbo.ShowRunningJobs') IS NOT NULL
BEGIN
    PRINT 'Dropping procedure: ShowRunningJobs'
    DROP PROCEDURE dbo.ShowRunningJobs
END
GO

PRINT 'Creating procedure: ShowRunningJobs'
GO

CREATE PROCEDURE dbo.ShowRunningJobs
(
    @LongRunningMinutes int = 120
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 26, 2026
-- Author:       Bill McEvoy
-- Description:  Report SQL Agent jobs that are currently executing on this instance.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

PRINT ' '
PRINT ' '
PRINT 'CURRENTLY RUNNING JOBS'
PRINT '======================'
PRINT ' '

SELECT
    'Start Time' = CONVERT(char(19), r.StartDate, 120),
    'Job Name'   = LEFT(r.JobName, 50),
    'Duration'   = r.Duration,
    'Step'       = CONVERT(char(3), r.CurrentStepId),
    'Step Name'  = LEFT(r.CurrentStepName, 35),
    'Alert'      = CASE
                        WHEN r.DurationInSeconds >= (@LongRunningMinutes * 60)
                        THEN 'WARNING!  Long running job detected.'
                        ELSE ''
                   END
  FROM dbo.vRunningJobs AS r
 ORDER BY r.StartDate,
          r.JobName

GO

IF OBJECT_ID('dbo.ShowRunningJobs') IS NOT NULL
    PRINT 'Procedure created'
ELSE
    PRINT 'Procedure NOT created'
GO