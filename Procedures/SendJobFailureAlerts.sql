use DBA
IF (object_id('SendJobFailureAlerts') IS NOT NULL)
BEGIN
  PRINT 'Dropping: SendJobFailureAlerts'
  DROP PROCEDURE SendJobFailureAlerts     
END
GO
PRINT 'Creating: SendJobFailureAlerts'
GO
create procedure SendJobFailureAlerts
(
  @HoursToCheck float = 24  --> Number of hours in the past to check for job failures, default is one full day
)
as
 
---------------------------------------------------------------------------------------------------
-- Date Created: October 15, 2010
-- Author:       William McEvoy
--               
-- Description:  This stored procedure examines the SQL job history tables to determine if there
--               have been any job failures.  If so, an email alert is sent out to the DBA team.
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: February 8, 2011
-- Author:       William McEvoy
-- Reason:       Added code to handle servers running in UTC/GMT
---------------------------------------------------------------------------------------------------
-- Date Revised: March 25, 2014
-- Author:       William McEvoy
-- Reason:       We no longer report errors caused by management warehouse jobs, as they are 
--               almost always noise.
---------------------------------------------------------------------------------------------------
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------

declare @JobString varchar(8000),
        @EmailTo   varchar(500),
        @EmailFrom varchar(100),
        @Subject   varchar(100),
        @Body      varchar(8000)


select  @JobString = '',
        @Body      = 'The following job failures were detected on server: ' + upper(@@SERVERNAME) + char(13) + char(10) + char(13) + char(10),
        @Subject   = 'SQL Job Failure Detected: ' + upper(@@SERVERNAME),
        @EmailTo   = '',
        @EmailFrom = '' 




declare @Results table 
  ( RunTime   char(20),
    LocalTime char(20),
    Status    varchar(20),
    Step      char(3),
    JobName   varchar(50),
    StepName  varchar(35),
    StepID    varchar(3),
    Message   varchar(200)
)

---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
-- Determine To/From addresses                                     --
--                                                                 --
-- Capture job information                                         --
--                                                                 --
-- Parse job information result set into a single string           --
--                                                                 --
-- Send alert if required                                          --
--                                                                 --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- Determine To/From addresses                                     --
---------------------------------------------------------------------


-- Determine email address from server profile
select top 1 @EmailFrom = email_address from msdb.dbo.sysmail_account

-- Determine recipients
select @EmailTo  = email_address + ';' from msdb.dbo.sysoperators


print 'From: ' + @EmailFrom
print 'To:   ' + @EMailTo

---------------------------------------------------------------------
-- Capture job information                                         --
---------------------------------------------------------------------

insert into @Results
select 
       'RunTime'   = convert(char(10),convert(datetime,convert(char(8),h.run_date)),120) + ' ' + left(right('00000' + cast(run_time as varchar(6)),6),2) + ':' + left(right('00000' + cast(run_time as varchar(6)),4),2) + ':' +  right(cast(run_time as varchar(6)),2) + ' ',
       'LocalTime' = dateadd(hh,-5,convert(datetime,convert(char(10),convert(datetime,convert(char(8),h.run_date)),120) + ' ' + left(right('00000' + cast(run_time as varchar(6)),6),2) + ':' + left(right('00000' + cast(run_time as varchar(6)),4),2) + ':' +  right(cast(run_time as varchar(6)),2))),
       'Status'    = case(run_status)
                       when 0 then 'JOB FAILED'
                       when 1 then 'Success '
                       when 2 then 'RETRY '
                       when 3 then 'CANCELLED '
                       when 4 then 'IN PROGRESS '
                       else '??'
                     end,
       'Step'      = convert(char(3),h.step_id),
       'Job Name'  = left(s.name,50),
       'Step Name' = left(h.step_name,35),
       'StepID'    = convert(varchar(3),h.step_id),
       'Message'   = left(h.message,200)
from msdb.dbo.sysjobhistory h
 right join msdb.dbo.sysjobs s on s.job_id = h.job_id
 where h.run_status <> 1
   and step_name NOT LIKE 'collection_set%'
 order by h.instance_id desc


---------------------------------------------------------------------
-- Parse job information result set into a single string           --
---------------------------------------------------------------------

select @JobString = @JobString 
                    + upper(@@SERVERNAME) + ' ' 
                    +  Status 
                    + ': ' + (case when (datepart(hh,getdate()) = datepart(hh,getutcdate())) then LocalTime else RunTime end)
                    + ' Job --> '     + JobName + ' '
                    + ' Step --> ' + StepID + ' '   + StepName + char(13) + char(10)
from @Results
where (RunTime >= dateadd(hh,(@HoursToCheck * (-1)),getdate()))
  and (StepID <> 0 or (StepID = 0 and message like '%does not have server access%'))
   


---------------------------------------------------------------------
-- Send alert if required                                          --
---------------------------------------------------------------------

IF (@JobString <> '')
BEGIN
  print 'Job failures detected...'

  select @Body = @Body + @JobString

  exec DBA.dbo.SendEmail
    @EmailTo   = @EmailTo,
    @EmailFrom = @EmailFrom,
    @Subject   = @Subject,
    @Body      = @Body

  print 'Email sent.'

END
ELSE
  print 'No failures detected...'
GO



SendJobFailureAlerts 1