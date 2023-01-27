
use DBA
go
IF (object_id('ShowJobHistory') IS NOT NULL)
BEGIN
  print 'Dropping procedure: ShowJobHistory'
  drop procedure ShowJobHistory
END
print 'Creating procedure: ShowJobHistory'
GO
CREATE PROCEDURE ShowJobHistory
@Days int = 14
as
---------------------------------------------------------------------------------------------------
-- Date Created: September 13, 2010
-- Author:       Bill McEvoy
-- Description:  This procedure produces an easy to read report that details all jobs
--               that have run on this server in the specified number of days.
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
print 'RECENT JOB HISTORY'
print '=================='
print ' '

select 'ID'        = convert(char(8), h.instance_id),
       'Run Time'  = convert(char(10),convert(datetime,convert(char(8),h.run_date)),120) + ' ' + left(right('00000' + cast(run_time as varchar(6)),6),2) + ':' + left(right('00000' + cast(run_time as varchar(6)),4),2) + ':' +  right(cast(run_time as varchar(6)),2) + ' ',
       'Duration'  = case when (h.run_duration > 1800) then '>' else ' ' end + left(right(convert(char(19),(dateadd(ss,h.run_duration,'')),20),8),8) + ' ',
       'Status'    = case(run_status)
                       when 0 then '** FAILED ** '
                       when 1 then 'Success '
                       when 2 then 'RETRY '
                       when 3 then 'CANCELLED '
                       when 4 then 'IN PROGRESS '
                       else '??'
                     end,
       'Step'      = convert(char(3),h.step_id),
       'Job Name'  = left(s.name,50),
       'Step Name' = left(h.step_name,35),
       'Message'   = left(h.message,200)
  from msdb.dbo.sysjobhistory h
 right join msdb.dbo.sysjobs s on s.job_id = h.job_id
 where h.run_date >= convert(int,(convert(char(8), (getdate()-@Days),112)))
--   and (h.step_id = 0 or run_status = 0)
 order by h.instance_id desc



go
IF (object_id('ShowJobHistory') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO

    

ShowJobHistory

