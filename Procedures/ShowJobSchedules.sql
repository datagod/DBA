-- NOTE:  Because this will not compile on 2005 due to missing columns in the system tables,
--        you must first remove the 2000 specific section before compiling.

use DBA_CONTROL
go
IF (object_id('ShowJobSchedules') IS NOT NULL)
BEGIN
  print 'Dropping procedure: ShowJobSchedules'
  drop procedure ShowJobSchedules
END
print 'Creating procedure: ShowJobSchedules'
GO
CREATE PROCEDURE ShowJobSchedules
as
---------------------------------------------------------------------------------------------------
-- Date Created: September 21, 2006
-- Author:       Bill McEvoy
-- Description:  This procedure produces a report that details the schedule information for all 
--               scheduled jobs on the server.
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: June 1, 2007
-- Author:       Bill McEvoy
-- Reason:       I converted this procedure to support SQL Server 2005
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Generate report                                                 --
---------------------------------------------------------------------

-- SQL 2000
IF (@@version like 'Microsoft SQL Server  2000%')
BEGIN
  select 'Server'       = left(@@ServerName,10),
         'JobName'      = left(S.name,55),
         'ScheduleName' = left(SJ.name,55),
         'Enabled'      = case (S.enabled)
		                    when 0 then 'No'
                            when 1 then 'Yes'
                            else '??'
                          end,
		 'Frequency' = case(SJ.freq_type)
		                 when 1 then 'Once'
		                 when 4  then 'Daily'
		                 when 8  then (case when (SJ.freq_recurrence_factor >1) then 'Every ' + convert(varchar(3),SJ.freq_recurrence_factor) + ' Weeks'  else 'Weekly' end)
                		 when 16 then (case when (SJ.freq_recurrence_factor >1) then 'Every ' + convert(varchar(3),SJ.freq_recurrence_factor) + ' Months' else 'Monthly' end)
		                 when 32 then 'Every ' + convert(varchar(3),SJ.freq_recurrence_factor) + 'Months' -- Relative
                		 when 64 then 'SQL Startup'
                		 when 128 then 'SQL Idle'
                		 else '??'
                       end,
         'Interval'  = case 
                         when (freq_type = 1) then 'One time only'
                         when (freq_type = 4 and freq_interval = 1) then 'Every Day'
                         when (freq_type = 4 and freq_interval > 1) then 'Every ' + convert(varchar(10), freq_interval) + ' Days'
                         when (freq_type = 8) then (select 'Weekly Schedule' = D1 +D2+D3+D4+D5+D6+D7
                                                      from (select SJ.schedule_id,
                                                                   freq_interval,
                                                                   'D1' = case when (freq_interval & 1  <> 0) then 'Sun ' else '' end,
                                                                   'D2' = case when (freq_interval & 2  <> 0) then 'Mon ' else '' end,
                                                                   'D3' = case when (freq_interval & 4  <> 0) then 'Tue ' else '' end,
                                                                   'D4' = case when (freq_interval & 8  <> 0) then 'Wed ' else '' end,
                                                                   'D5' = case when (freq_interval & 16 <> 0) then 'Thu ' else '' end,
                                                                   'D6' = case when (freq_interval & 32 <> 0) then 'Fri ' else '' end,
                                                                   'D7' = case when (freq_interval & 64 <> 0) then 'Sat ' else '' end
                                                              from msdb..sysjobschedules SJ where freq_type = 8) as F
                                                        where schedule_id = sj.schedule_id)
                         when (freq_type = 16) then 'Day ' + convert(varchar(2), freq_interval)
                         when (freq_type = 32) then (select freq_rel + WDAY
                                                       from (select SJ.schedule_id,
                                                                    'freq_rel' = case(freq_relative_interval)
                                                                                   when 1 then 'First'
                                                                                   when 2 then 'First'
                                                                                   when 4 then 'First'
                                                                                   when 8 then 'First'
                                                                                   when 16 then 'First'
                                                                                   else '??'
                                                                                 end,
                                                                    'WDAY'     = case(freq_interval)
                                                                                   when 1  then 'Sun'
                                                                                   when 2  then 'Mon'
                                                                                   when 3  then 'Tue'
                                                                                   when 4  then 'Wed'
                                                                                   when 5  then 'Thu'
                                                                                   when 6  then 'Fri'
                                                                                   when 7  then 'Sat'
                                                                                   when 8  then 'Day'
                                                                                   when 9  then 'Weekday'
                                                                                   when 10 then 'Weekend'
                                                                                   else '??'
                                                                                 end
                                                                from msdb..sysjobschedules SJ
                                                               where SJ.freq_type = 32) as WS
                                                        where WS.schedule_id = SJ.schedule_id)
                            end,

         'Time' = case(freq_subday_type)
                    when 1 then left(stuff((stuff((replicate('0',6-len(active_start_time)))+convert(varchar(6),active_start_time),3,0,':')),6,0,':'),8)
                    when 2 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' seconds'
                    when 4 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' minutes'
                    when 8 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' hours'
                    else '??'
                  end,
         'Next Run Time' = case (sj.next_run_date)
                             when 0 then cast('n/a' as char(10))
                             else convert(char(10), convert(datetime, convert(char(8), SJ.next_run_date)),120) + ' ' + left(stuff((stuff((replicate('0',6-len(next_run_time))) + convert(varchar(6),next_run_time),3,0,':')),6,0,':'),8)
                           end,
         'Created'  = convert(char(10),S.date_created,120),
         'Modified' = convert(char(10),S.date_modified,120)
    from msdb.dbo.sysjobschedules SJ
    right join msdb.dbo.sysjobs         S   on S.job_id       = SJ.job_id
   order by s.name
END

-- SQL 2005
IF (@@version like 'Microsoft SQL Server 2005%')
BEGIN
  select 'Server'       = left(@@ServerName,10),
         'JobName'      = left(S.name,55),
         'ScheduleName' = left(ss.name,55),
         'Enabled'      = case (S.enabled)
		                    when 0 then 'No'
                            when 1 then 'Yes'
                            else '??'
                          end,
		 'Frequency' = case(ss.freq_type)
		                 when 1 then 'Once'
		                 when 4  then 'Daily'
		                 when 8  then (case when (ss.freq_recurrence_factor >1) then 'Every ' + convert(varchar(3),ss.freq_recurrence_factor) + ' Weeks'  else 'Weekly' end)
                		 when 16 then (case when (ss.freq_recurrence_factor >1) then 'Every ' + convert(varchar(3),ss.freq_recurrence_factor) + ' Months' else 'Monthly' end)
		                 when 32 then 'Every ' + convert(varchar(3),ss.freq_recurrence_factor) + 'Months' -- Relative
                		 when 64 then 'SQL Startup'
                		 when 128 then 'SQL Idle'
                		 else '??'
                       end,
         'Interval'  = case 
                         when (freq_type = 1) then 'One time only'
                         when (freq_type = 4 and freq_interval = 1) then 'Every Day'
                         when (freq_type = 4 and freq_interval > 1) then 'Every ' + convert(varchar(10), freq_interval) + ' Days'
                         when (freq_type = 8) then (select 'Weekly Schedule' = D1 +D2+D3+D4+D5+D6+D7
                                                      from (select ss.schedule_id,
                                                                   freq_interval,
                                                                   'D1' = case when (freq_interval & 1  <> 0) then 'Sun ' else '' end,
                                                                   'D2' = case when (freq_interval & 2  <> 0) then 'Mon ' else '' end,
                                                                   'D3' = case when (freq_interval & 4  <> 0) then 'Tue ' else '' end,
                                                                   'D4' = case when (freq_interval & 8  <> 0) then 'Wed ' else '' end,
                                                                   'D5' = case when (freq_interval & 16 <> 0) then 'Thu ' else '' end,
                                                                   'D6' = case when (freq_interval & 32 <> 0) then 'Fri ' else '' end,
                                                                   'D7' = case when (freq_interval & 64 <> 0) then 'Sat ' else '' end
                                                              from msdb..sysschedules ss where freq_type = 8) as F
                                                        where schedule_id = sj.schedule_id)
                         when (freq_type = 16) then 'Day ' + convert(varchar(2), freq_interval)
                         when (freq_type = 32) then (select freq_rel + WDAY
                                                       from (select ss.schedule_id,
                                                                    'freq_rel' = case(freq_relative_interval)
                                                                                   when 1 then 'First'
                                                                                   when 2 then 'First'
                                                                                   when 4 then 'First'
                                                                                   when 8 then 'First'
                                                                                   when 16 then 'First'
                                                                                   else '??'
                                                                                 end,
                                                                    'WDAY'     = case(freq_interval)
                                                                                   when 1  then 'Sun'
                                                                                   when 2  then 'Mon'
                                                                                   when 3  then 'Tue'
                                                                                   when 4  then 'Wed'
                                                                                   when 5  then 'Thu'
                                                                                   when 6  then 'Fri'
                                                                                   when 7  then 'Sat'
                                                                                   when 8  then 'Day'
                                                                                   when 9  then 'Weekday'
                                                                                   when 10 then 'Weekend'
                                                                                   else '??'
                                                                                 end
                                                                from msdb..sysschedules ss
                                                               where ss.freq_type = 32) as WS
                                                        where WS.schedule_id = ss.schedule_id)
                            end,

         'Time' = case(freq_subday_type)
                    when 1 then left(stuff((stuff((replicate('0',6-len(active_start_time)))+convert(varchar(6),active_start_time),3,0,':')),6,0,':'),8)
                    when 2 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' seconds'
                    when 4 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' minutes'
                    when 8 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' hours'
                    else '??'
                  end,
         'Next Run Time' = case (sj.next_run_date)
                             when 0 then cast('n/a' as char(10))
                             else convert(char(10), convert(datetime, convert(char(8), SJ.next_run_date)),120) + ' ' + left(stuff((stuff((replicate('0',6-len(next_run_time))) + convert(varchar(6),next_run_time),3,0,':')),6,0,':'),8)
                           end,
         'Created'  = convert(char(10),S.date_created,120),
         'Modified' = convert(char(10),S.date_modified,120)
    from msdb.dbo.sysjobschedules SJ
    right join msdb.dbo.sysjobs         S   on S.job_id       = SJ.job_id
    join msdb.dbo.sysschedules    SS  on SS.schedule_id = sj.schedule_id
   order by s.name

END
go
IF (object_id('ShowJobSchedules') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO

    

ShowJobSchedules