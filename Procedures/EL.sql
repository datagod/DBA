alter procedure [dbo].[EL]
(
  @Days        decimal(5,2) = 0.01,
  @Process     varchar(100) = '%',
  @Description varchar(100) = '%'
)
as


select e1.EventLogID, 
       e1.EventTime, 
      e1.databasename,
       'Seconds' = datediff(ss,e2.EventTime, e1.EventTime),
       'Process' = left(e1.Process,35),
       e1.Description
  from EventLog e1
  left join EventLog e2 on e1.EventLogID = e2.EventLogID + 1
 where e1.EventTime >= getdate()-(@Days)
   and e2.EventTime >= getdate()-(@Days)
   and e1.Process like @process
   --and e2.Process like @process
   and e1.Description like @description 
 order by e1.EventLogID asc
go
