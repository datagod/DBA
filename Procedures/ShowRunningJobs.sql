
use DBA
go
IF (object_id('ShowRunningJobs') IS NOT NULL)
BEGIN
  print 'Dropping procedure: ShowRunningJobs'
  drop procedure ShowRunningJobs
END
print 'Creating procedure: ShowRunningJobs'
GO
CREATE PROCEDURE ShowRunningJobs
(
  @LongRunningMinutes int = 120
)
as
---------------------------------------------------------------------------------------------------
-- Date Created: June 26, 2026
-- Author:       Bill McEvoy
-- Description:  Report SQL Agent jobs that are currently executing on this instance.
--
---------------------------------------------------------------------------------------------------
-- Date Revised:
-- Author:
-- Reason:
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Generate report                                                 --
---------------------------------------------------------------------

print ' '
print ' '
print 'CURRENTLY RUNNING JOBS'
print '======================'
print ' '

;with RunningJobs as
(
  SELECT sj.job_id,
         convert(varchar(50), sj.name) as JobName,
         aj.start_execution_date as StartDate,
         aj.last_executed_step_id as LastExecutedStepId,
         DATEDIFF(SECOND, aj.start_execution_date, GETDATE()) AS DurationInSeconds
    FROM msdb.dbo.sysjobactivity aj
    JOIN msdb.dbo.sysjobs sj
      ON sj.job_id = aj.job_id
   WHERE aj.stop_execution_date IS NULL
     AND aj.start_execution_date IS NOT NULL
     AND aj.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
     AND NOT EXISTS (
           SELECT 1
             FROM msdb.dbo.sysjobactivity newer
            WHERE newer.job_id = aj.job_id
              AND newer.start_execution_date > aj.start_execution_date
         )
)
SELECT 'Start Time' = convert(char(19), r.StartDate, 120),
       'Job Name'   = left(r.JobName, 50),
       'Duration'   = dbo.fn_SecondsToTime(r.DurationInSeconds),
       'Step'       = convert(char(3), ISNULL(js.step_id, 0)),
       'Step Name'  = left(ISNULL(js.step_name, '(starting)'), 35),
       'Alert'      = CASE
                        WHEN r.DurationInSeconds >= (@LongRunningMinutes * 60)
                        THEN 'WARNING!  Long running job detected.'
                        ELSE ''
                      END
  FROM RunningJobs r
  LEFT JOIN msdb.dbo.sysjobsteps js
    ON js.job_id = r.job_id
   AND js.step_id = ISNULL(r.LastExecutedStepId, 0) + 1
 ORDER BY r.StartDate,
          r.JobName

go
IF (object_id('ShowRunningJobs') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO