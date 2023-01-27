use dba
go

create or alter procedure ShowSSISMessages
(
  @HoursToCheck    decimal(8,2) = 1,     -- only show records newer than this many hours ago
  @MessageIDCutoff bigint       = 50000, -- used to control how far back into the records we search
  @Project         varchar(100) = '%',   -- name of SSIS project
  @Package         varchar(100) = '%',   -- name of SSIS package
  @Message         varchar(100) = '%',   -- name of SSIS package
  @Rows            int          = 500,    -- maximum rows to return
  @ErrorsOnly      char(1)      = 'N'    -- If Y, show only error messages
)
  
as

declare @CutoffID bigint,
        @CutoffDate datetime

-- there is no index on message_time, so we use the event_message_id to cutoff the (very) large tables when joining
-- thus greatly reducing the amount if I/O required
select @cutoffID = (select max(event_message_id) from [SSISDB].[internal].[event_messages]) - @MessageIDCutoff

if(@HoursToCheck = 0 or @HoursToCheck IS NULL)
  select @HoursToCheck = 1.0

select @CutoffDate = getdate() - @HoursToCheck  



select top (@Rows)
       --om.message_time,
       convert(datetime,om.message_time) as 'MessageTime',
       case (om.message_type)
         when 120 then 'ERROR'
         when 110 then 'WARNING'
         when 70 then 'Information'
         when 10 then 'Pre-validate'
         when 20 then 'Post-validate'
         when 30 then 'Pre-execute'
         when 40 then 'Post-execute'
         when 50 then 'Status Change'
         when 60 then 'Progress'
         when 100 then 'Query Cancel'
         when 130 then 'Task Failed'
         when 90 then 'Diagnostic'
         when 200 then 'Custom'
         when 140 then 'DiagnosticEx'
         when 400 then 'Non diagnostic'
         when 80 then 'VariableValueChanged'
         else '??'
       end as 'MessageType',
       case (om.message_source_type)
         when 10 then 'Entry API / Stored Proc'
         when 20 then 'External process'
         when 30 then 'Package level'
         when 40 then 'Control flow tasks'
         when 50 then 'Control flow containers'
         when 60 then 'Data flow task'
         else '??'
       end as 'MessageSourceType',
       op.object_name as 'Project',
       em.Package_Name,
       em.message_source_name,
       om.message,
       em.event_name, 
       om.message_type,
       om.message_source_type, 
       em.subcomponent_name

       
--select top 10 * from ssisdb.internal.operations
--select top 10 * from ssisdb.internal.executions


  
--  top 10 Message_Time, Message, Execution_Path, package_name, Event_Name, Message_Source_Name, ThreadID
  FROM ssisdb.[internal].[operation_messages] om
  JOIN ssisdb.[internal].[event_messages]     em on em.event_message_id = om.operation_message_id
  join ssisdb.internal.operations             op on op.operation_id     = om.operation_id
where em.event_message_id >= @CutoffID
  and om.operation_message_id >= @CutoffID
  and em.event_name <> 'OnPreValidate'
  and em.event_name <> 'OnPostValidate'
  and em.event_name <> 'OnPreExecute'
  and om.message_time >= @CutoffDate
  and op.object_name like @Project
  and em.package_name like @Package
  and om.message like @Message  
  and (om.message_type in (110,120) or @ErrorsOnly = 'N')
order by om.operation_message_id asc
go


exec ShowSSISMessages 
  @HoursToCheck    = 0.01,
  @MessageIDCutoff = 10000,
  @Project         = 'cdw realtime',
  @Rows            = 25,
  @ErrorsOnly      = 'Y'
  
   