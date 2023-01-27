use DBA
go
IF (object_id('ShowDatabaseSizes') IS NOT NULL)
BEGIN
  print 'Dropping procedure: ShowDatabaseSizes'
  drop procedure ShowDatabaseSizes
END
print 'Creating procedure: ShowDatabaseSizes'
GO
CREATE PROCEDURE ShowDatabaseSizes

as
---------------------------------------------------------------------------------------------------
-- Date Created: April 18, 2019
-- Author:       Bill McEvoy
--
-- Description:  This stored procedure reports the size of each available database
--
---------------------------------------------------------------------------------------------------
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------
set nocount on



select left(@@ServerName,30) as 'ServerName',
        'DatabaseName' = left(db_name(mf.database_id),30),
        'Status'   = left(max(case(d.state_desc) when 'ONLINE' then 'online' else d.State_desc end),6),
        'Recovery' = left(max(d.recovery_model_desc),6),
        'Data GB'  = str(sum(case (mf.type) when 0 then (convert(decimal(12,2),(mf.size * 8128.0) / 1024.0 / 1024.0 / 1024.0)) else 0 end),6,2),
        'Log GB'   = str(sum(case (mf.type) when 1 then (convert(decimal(12,2),(mf.size * 8128.0) / 1024.0 / 1024.0 / 1024.0)) else 0 end),6,2)
  from sys.master_files mf
  join sys.databases     d on d.database_id = mf.database_id
 --where db_name(mf.database_id) like '$DatabaseName'
group by mf.database_id
order by DatabaseName 
go
IF (object_id('ShowDatabaseSizes') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO

-- Grants
grant execute on ShowDatabaseSizes to R_CDW_Support

exec dba.dbo.ShowDatabaseSizes




