CREATE or alter PROCEDURE Blocks
(
  @Loginame varchar(50) = '%'
)
as
---------------------------------------------------------------------------------------------------
-- Date Created: February 8, 2013
-- Author:       Bill McEvoy
-- Description:  This procedure displays a summary of blocked processes.
---------------------------------------------------------------------------------------------------
set nocount on

declare @sql_handle binary(20),
        @spid       int,
        @blocker    int,
        @rowcount   int,
        @output     varchar(8000),
        @blocks     int,
        @spids      int,
        @SQL        varchar(8000)

IF (object_id('tempdb..#DBCCResults') IS NOT NULL)
  drop table #DBCCResults

CREATE TABLE #DBCCResults
(
  EventType  varchar(200)   NULL,
  Parameters varchar(200)   NULL,
  EventInfo  varchar(7000) NULL 
)


-- count active processes
 select @rowcount = count(*)
   from master.dbo.sysprocesses a
with (nolock)   
  where (sql_handle <> 0x0000000000000000000000000000000000000000 
    and status <> 'sleeping'
    and spid <> @@SPID)
     or (blocked > 0)
     or exists (select 1 from master.dbo.sysprocesses b with (nolock) where a.spid = b.blocked)  -- this includes the blocker process information
   

print '====================='
print '= BLOCKED PROCESSES ='
print '====================='
print convert(char(19),getdate(),120)
print ' '
print 'Active  SPIDs: ' +  convert(varchar(8),@rowcount)
select @blocks = count(*) from master..sysprocesses where blocked > 0
print 'Blocked SPIDs: ' + convert(varchar(8),@blocks)
select @spids  = count(*) from master..sysprocesses
print 'Total   SPIDs: ' + convert(varchar(8),@spids)


IF (@blocks > 0)
BEGIN
  print ' '
  print ' '
  print 'Blocked Process Summary'
  print '-----------------------'
  print ' '
  select 'loginame'     = left(loginame, 20),
         'hostname'     = left(hostname,20),
         'database'     = left(db_name(dbid),25),
         'spid'         = str(spid,4,0),
         'block'        = str(blocked,5,0),
         'phys_io'      = str(physical_io,8,0),
         'cpu(mm:ss)'   = str((cpu/1000/60),6) + ':' + case when left((str(((cpu/1000) % 60),2)),1) = ' ' then stuff(str(((cpu/1000) % 60),2),1,1,'0') 
else str(((cpu/1000) % 60),2) END,
         'mem(MB)'      = str((convert(float,memusage) * 8192.0 / 1024.0 / 1024.0),8,2),
         'program_name' = left(program_name,50),
         'command'      = cmd,
         'lastwaittype' = left(lastwaittype,25),
         'login_time'   = convert(char(19),login_time,120),
         'last_batch'   = convert(char(19),last_batch,120),
         'status'       = left(nt_username,20)
    from master.dbo.sysprocesses
    with (nolock)
   where blocked > 0
     and loginame like @Loginame
UNION 
  select 'loginame'     = left(loginame, 20),
         'hostname'     = left(hostname,20),
         'database'     = left(db_name(dbid),25),
         'spid'         = str(spid,4,0),
         'block'        = str(blocked,5,0),
         'phys_io'      = str(physical_io,8,0),
         'cpu(mm:ss)'   = str((cpu/1000/60),6) + ':' + case when left((str(((cpu/1000) % 60),2)),1) = ' ' then stuff(str(((cpu/1000) % 60),2),1,1,'0') 
else str(((cpu/1000) % 60),2) END,
         'mem(MB)'      = str((convert(float,memusage) * 8192.0 / 1024.0 / 1024.0),8,2),
         'program_name' = left(program_name,50),
         'command'      = cmd,
         'lastwaittype' = left(lastwaittype,25),
         'login_time'   = convert(char(19),login_time,120),
         'last_batch'   = convert(char(19),last_batch,120),
         'status'       = left(nt_username,20)
    from master.dbo.sysprocesses
    with (nolock)
   where spid in (select blocked from master.dbo.sysprocesses where blocked > 0)
END
GO




 exec blocks