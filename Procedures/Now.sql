use dba
go
IF (object_id('Now') IS NOT NULL)
BEGIN
  print 'Dropping procedure: Now'
  drop procedure Now
END
print 'Creating procedure: Now'
GO
CREATE PROCEDURE Now
as
---------------------------------------------------------------------------------------------------
-- Date Created: February 11, 2007
-- Author:       Bill McEvoy
-- Description:  This procedure produces a report that details the current activity on the
--               SQL Server.  Each process that is actively performing I/O will be listed along 
--               with the SQL code that is being executed.
---------------------------------------------------------------------------------------------------
-- Version:      1.1  
-- Date Revised: April 22, 2014
-- Author:       Bill McEvoy
-- Reason:       We now wrap the database name with square brackets to accomodate names with
--               non alphanumeric characters.
---------------------------------------------------------------------------------------------------
-- Version:      
-- Date Revised: 
-- Author:       
-- Reason:       
--               
---------------------------------------------------------------------------------------------------
set nocount on

declare @sql_handle binary(20),
        @spid       int,
        @blocker    int,
        @rowcount   int,
        @output     varchar(8000),
        @blocks     int,
        @spids      int,
        @SQL        varchar(8000),
        @version    varchar(10)

select  @version    = '1.1'        

IF (object_id('tempdb..#DBCCResults') IS NOT NULL)
  drop table #DBCCResults

CREATE TABLE #DBCCResults
(
  EventType  varchar(200)   NULL,
  Parameters varchar(200)   NULL,
  EventInfo  varchar(7000) NULL 
)


declare ActiveSpids_Cursor CURSOR FOR 
 select spid,
        blocked,
        sql_handle
   from master.dbo.sysprocesses a
  where (sql_handle <> 0x0000000000000000000000000000000000000000 
    and status <> 'sleeping'
    and spid <> @@SPID)
     or (blocked > 0)
     or exists (select 1 from master.dbo.sysprocesses b where a.spid = b.blocked)  -- this includes the blocker process information

  order by cpu desc
    

OPEN ActiveSpids_Cursor

FETCH NEXT 
 FROM ActiveSpids_Cursor
 INTO @spid,
      @blocker,
      @sql_handle

set @rowcount = @@CURSOR_ROWS

print '===================='
print '= CURRENT ACTIVITY ='
print '===================='
print convert(char(19),getdate(),120)
print 'Version ' + @version
print ' '
print 'Active  SPIDs: ' +  convert(varchar(8),@rowcount)

-- Blocking processes summary
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
         'cpu(mm:ss)'   = str((cpu/1000/60),6) + ':' + case when left((str(((cpu/1000) % 60),2)),1) = ' ' then stuff(str(((cpu/1000) % 60),2),1,1,'0') else str(((cpu/1000) % 60),2) END,
         'mem(MB)'      = str((convert(float,memusage) * 8192.0 / 1024.0 / 1024.0),8,2),
         'program_name' = left(program_name,50),
         'command'      = cmd,
         'lastwaittype' = left(lastwaittype,25),
         'login_time'   = convert(char(19),login_time,120),
         'last_batch'   = convert(char(19),last_batch,120),
         'status'       = left(nt_username,20)
    from master.dbo.sysprocesses
   where blocked > 0
END



WHILE (@@FETCH_STATUS = 0 )
BEGIN
  print ' '
  print ' '
  print 'O' + replicate('x',120) + 'O'  
  print 'O' + replicate('x',120) + 'O'  
  print ' '
  print ' '
  print ' '

  IF (exists (select 1 from master..sysprocesses where blocked = @spid))
  BEGIN

    print '================'
    print '=== BLOCKER ===='
    print '================'
    print ' '
  END


  select 'loginame'     = left(loginame, 30),
         'hostname'     = left(hostname,30),
         'database'     = left(db_name(dbid),30),
         'spid'         = str(spid,4,0),
         'block'        = str(blocked,5,0),
         'phys_io'      = str(physical_io,8,0),
         'cpu(mm:ss)'   = str((cpu/1000/60),6) + ':' + case when left((str(((cpu/1000) % 60),2)),1) = ' ' then stuff(str(((cpu/1000) % 60),2),1,1,'0') else str(((cpu/1000) % 60),2) END,
         'mem(MB)'      = str((convert(float,memusage) * 8192.0 / 1024.0 / 1024.0),8,2),
         'program_name' = left(program_name,50),
         'command'      = cmd,
         'lastwaittype' = left(lastwaittype,25),
         'login_time'   = convert(char(19),login_time,120),
         'last_batch'   = convert(char(19),last_batch,120),
         'status'       = left(nt_username,20)
    from master..sysprocesses
   where spid = @spid

  -- Dump the inputbuffer to get an idea of what the spid is doing
  print '----------------------'
  print '-- DBCC INPUTBUFFER --'
  print '----------------------'
  print ' '
  truncate table #DBCCResults
  select @SQL = 'DBCC INPUTBUFFER(' + convert(varchar(12),@spid) + ') WITH NO_INFOMSGS'

  insert into #DBCCResults(EventType, Parameters, EventInfo)
  exec (@SQL)

  select @output = EventInfo
    from #DBCCResults

  print  @output
  print ' '
  print ' '

  -- Use the built-in function to show the exact SQL code that the spid is running
  select @output = ''
  select @output = [text] from ::fn_get_sql(@sql_handle)
  IF (@output <> '' and @output is not null)
  BEGIN
    print '------------------'
    print '-- fn_get_sql() --'
    print '------------------'
    print ' '
    print @output
  END

  FETCH NEXT 
   FROM ActiveSpids_Cursor
   INTO @spid,
        @blocker,
        @sql_handle
                           
END

IF (@spid is not null)
BEGIN
  print ' '
  print ' '
  print 'O' + replicate('x',120) + 'O'  
  print 'O' + replicate('x',120) + 'O'  
  print ' '
  print ' '
  print ' '
END


CLOSE      ActiveSpids_Cursor
DEALLOCATE ActiveSpids_Cursor



create table #Results
(
  DatabaseID smallint,
  FileName varchar(128),
  DBFileName   varchar(255),
  FileID       int,
  IO_Pending   bit
)

exec sp_msforeachdb 'use [?]; insert into #Results SELECT vfs.database_id, df.name, df.physical_name
,vfs.FILE_ID, ior.io_pending
FROM sys.dm_io_pending_io_requests ior
INNER JOIN sys.dm_io_virtual_file_stats (DB_ID(), NULL) vfs
ON (vfs.file_handle = ior.io_handle)
INNER JOIN sys.database_files df ON (df.FILE_ID = vfs.FILE_ID)'

print '----------------------'
print '-- Pending File I/O --'
print '----------------------'
print ''
select 'Database'   = left(db_name(DatabaseID),25),
       'FileName'   = left(FileName,30),
       'DBFileName' = left(DBFileName,50),
       FileID,
       IO_Pending
  from #Results



IF (@Blocks > 0)
    waitfor delay '00:00:03'

go
IF (object_id('Now') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO
