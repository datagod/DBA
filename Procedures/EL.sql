use DBA
go
IF (object_id('EL') IS NOT NULL)
BEGIN
  print 'Dropping procedure: EL'
  drop procedure EL
END
print 'Creating procedure: EL'
GO
CREATE procedure [dbo].[EL]
(
  @Days decimal(5,2) = 0.01,
  @Process varchar(100) = '%'
)
as



select EventLogID, 
       EventTime, 
       'Process' = left(Process,35),
       Description
  from EventLog
 where EventTime >= getdate()-(@Days)
   and isnull(Process,'') like @process
 order by 1 asc
GO


IF (object_id('EL') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO
