
/*
  vRunningJobs.sql

  Deploy to the DBA tool database, then query:
    SELECT * FROM dbo.vRunningJobs ORDER BY StartDate, JobName
    SELECT * FROM dbo.vRunningJobs WHERE DurationInSeconds >= 3600
*/

USE DBA
GO

IF OBJECT_ID('dbo.vRunningJobs') IS NOT NULL
BEGIN
    PRINT 'Dropping view: vRunningJobs'
    DROP VIEW dbo.vRunningJobs
END
GO

PRINT 'Creating view: vRunningJobs'
GO

CREATE VIEW dbo.vRunningJobs
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 28, 2026
-- Author:       Bill McEvoy
-- Description:  SQL Agent jobs currently executing on this instance.
---------------------------------------------------------------------------------------------------
SELECT
    sj.job_id AS JobId,
    CONVERT(varchar(128), sj.name) AS JobName,
    aj.start_execution_date AS StartDate,
    aj.last_executed_step_id AS LastExecutedStepId,
    ISNULL(aj.last_executed_step_id, 0) + 1 AS CurrentStepId,
    CONVERT(varchar(128), ISNULL(js.step_name, '(starting)')) AS CurrentStepName,
    DATEDIFF(SECOND, aj.start_execution_date, GETDATE()) AS DurationInSeconds,
    dbo.fn_SecondsToTime(DATEDIFF(SECOND, aj.start_execution_date, GETDATE())) AS Duration,
    sj.enabled AS JobEnabled,
    CONVERT(varchar(128), c.name) AS JobCategory,
    CONVERT(varchar(128), sp.name) AS JobOwner,
    aj.session_id AS AgentSessionId
  FROM msdb.dbo.sysjobactivity AS aj
  JOIN msdb.dbo.sysjobs AS sj
    ON sj.job_id = aj.job_id
  LEFT JOIN msdb.dbo.sysjobsteps AS js
    ON js.job_id = sj.job_id
   AND js.step_id = ISNULL(aj.last_executed_step_id, 0) + 1
  LEFT JOIN msdb.dbo.syscategories AS c
    ON c.category_id = sj.category_id
  LEFT JOIN sys.server_principals AS sp
    ON sp.sid = sj.owner_sid
 WHERE aj.stop_execution_date IS NULL
   AND aj.start_execution_date IS NOT NULL
   AND aj.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
   AND NOT EXISTS (
         SELECT 1
           FROM msdb.dbo.sysjobactivity AS newer
          WHERE newer.job_id = aj.job_id
            AND newer.start_execution_date > aj.start_execution_date
       )
GO

IF OBJECT_ID('dbo.vRunningJobs') IS NOT NULL
    PRINT 'View created'
ELSE
    PRINT 'View NOT created'
GO