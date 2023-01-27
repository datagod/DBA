use DBA
go
IF (object_id('ShowSSISExecutions') IS NOT NULL)
BEGIN
  print 'Dropping procedure: ShowSSISExecutions'
  drop procedure ShowSSISExecutions
END
print 'Creating procedure: ShowSSISExecutions'
GO
CREATE PROCEDURE ShowSSISExecutions
(
  @CutoffTime datetime = NULL,
  @Days       int      = 1
)
as
---------------------------------------------------------------------------------------------------
-- Date Created: April 11, 2019
-- Author:       Bill McEvoy
--
-- Description:  This procedure produces a report of the recently run SSIS projects/packages/tasks.
--
---------------------------------------------------------------------------------------------------
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------
set nocount on


---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------

-- if no trace time is passed in, use 24 hour period
IF (@CutoffTime IS NULL)
  set @CutoffTime = getdate()-(@Days)


---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------

;with Report as
(
    SELECT
        CONVERT(datetime, msg.[message_time]) as 'RunTime',
        left(isnull(op.Object_name,'??'),50)  as 'ProjectName',
        left(package_name,50)                 as 'PackageName',
        Message_Source_type                   as 'MessageSourceType',
        msg.[message_source_name]             as 'MessageSource',
        
        [message]
    FROM
        [SSISDB].[catalog].[event_messages] msg
         LEFT JOIN [SSISDB].[catalog].[extended_operation_info] info ON msg.extended_info_id = info.info_id
         left join ssisdb.catalog.operations op on msg.operation_id = op.operation_id
    --where [Message_Time] >= @CutoffTime



)
select distinct 
       RunTime,
       ProjectName, 
       PackageName,
      'MessageSourceType' = case
                              when MessageSourceType = 10 then 'Entry API'
                              when MessageSourceType = 20 then 'External Process'
                              when MessageSourceType = 30 then 'Package-level object'
                              when MessageSourceType = 40 then 'Control flow tasks'
                              when MessageSourceType = 50 then 'Control flow container'
                              when MessageSourceType = 60 then 'Data Flow task'
                              else '??'
                            end,
--       MessageSourceType as 'MessageSourceTypeID',
       'StepType' = case 
                      when MessageSource like '%execute SQL%' then 'Execute SQL'
                      when MessageSource like '%package task%' then 'Execute Task'
                      when MessageSource like '%execute package%' then 'Execute Package'
                      else ''
                    end,
       MessageSource



        
       
  from Report
 where RunTime >= @CutoffTime
 order by RunTime


 go
IF (object_id('ShowSSISExecutions') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO

-- Grants
grant execute on ShowSSISExecutions to R_CDW_Support



set statistics io on
-- Show messages from the last 4 days
declare @CutoffTime datetime = getdate()-1
exec dba.dbo.ShowSSISExecutions
   @CutoffTime = @CutoffTime


   USE [DBA]
GO



