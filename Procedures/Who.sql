use dba
go
alter PROCEDURE Who
(
  @db varchar(100) = '%',
  @kill char(1) = 'N',
  @tran char(1) = 'N'
)
as

/*  This proc should be rewritten to take advantage of:
  select * from sys.dm_exec_connections
  select * from sys.dm_exec_sessions
  select * from sys.dm_exec_requests
*/



---------------------------------------------------------------------------------------------------
-- Date Created: July 17, 2007
-- Author:       Bill McEvoy
-- Description:  This procedure gives a summary report and a detailed report of the logged-in
--               processes.  This procedure is a derivative of sp_who3 which I wrote in 2002.
--               
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
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
-- Generate login summary report                                   --
--                                                                 --
--                                                                 --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- Generate login summary report                                   --
---------------------------------------------------------------------

select 'loginame'   = convert(char(30),loginame),
       'connection' = count(*),
       'phys_io'    = str(sum(physical_io),10),
--       'cpu'        = sum(cpu),
       'cpu(mm:ss)' = str((sum(cpu)/1000/60),12) + ':' + case 
                                            when left((str(((sum(cpu)/1000) % 60),2)),1) = ' ' then stuff(str(((sum(cpu)/1000) %60),2),1,1,'0') 
                                            else str(((sum(cpu)/1000) %60),2)
                                         end,
       'wait_time'  = str(sum(waittime),12),
       'Total Memory(MB)' = convert(decimal(12,2),sum(convert(float,memusage) * 8192.0 / 1024.0 / 1024.0))
from master.dbo.sysprocesses
where db_name(dbid) like @db
  and not (loginame = 'sa' and program_name = '' and db_name(dbid) = 'master')
group by loginame
order by 3 desc



---------------------------------------------------------------------
-- Generate detailed activity report                               --
---------------------------------------------------------------------

select 'loginame'     = left(loginame, 30),
       'hostname'     = left(hostname,25),
       'database'     = left(db_name(dbid),25),
       'spid'         = str(spid,4,0),
       'block'        = str(blocked,5,0),
       'phys_io'      = str(physical_io,10,0),
       'cpu(mm:ss)'   = str((cpu/1000/60),10) + ':' + case when left((str(((cpu/1000) % 60),2)),1) = ' ' then stuff(str(((cpu/1000) % 60),2),1,1,'0') else str(((cpu/1000) % 60),2) END,
       'mem(MB)'      = str((convert(float,memusage) * 8192.0 / 1024.0 / 1024.0),8,2),
       'program_name' = left(program_name,50),
       'command'      = cmd,
       'lastwaittype' = left(lastwaittype,20),
       'login_time'   = convert(char(19),login_time,120),
       'last_batch'   = convert(char(19),last_batch,120),
       'status'       = [status]
       
 from master..sysprocesses
where db_name(dbid) like @db
  and not (loginame = 'sa' and program_name = '' and db_name(dbid) = 'master')
order by 5,4


---------------------------------------------------------------------
-- Generate KILL commands                                          --
---------------------------------------------------------------------

IF (upper(@Kill) = 'Y')
BEGIN
  select 'kill' + ' ' + str(spid,4,0)
    from master..sysprocesses
  where db_name(dbid) like @db
    and not (loginame = 'sa' and program_name = '' and db_name(dbid) = 'master')
  order by spid
END



---------------------------------------------------------------------
-- Report on open transactions                                     --
---------------------------------------------------------------------

IF (UPPER(@Tran) = 'Y')
BEGIN

  -- Create the temporary table to accept the results.
  IF (object_id('tempdb..#Transactions') is NOT NULL)
    DROP TABLE #Transactions
  CREATE TABLE #Transactions
  (
    DatabaseName    varchar(30),
    TransactionName varchar(25),
    Details         sql_variant 
  )

  -- Execute the command, putting the results in the table.
  exec sp_msforeachdb '
  INSERT INTO #Transactions (TransactionName, Details)
     EXEC (''DBCC OPENTRAN([?]) WITH TABLERESULTS, NO_INFOMSGS'');
  update #Transactions 
     set DatabaseName = ''[?]''
   where DatabaseName is NULL'

  -- Display the results.
  SELECT * FROM #Transactions order by transactionname
END

go
