use dba
go

CREATE or ALTER PROCEDURE ServerStatus
as
---------------------------------------------------------------------------------------------------
-- Date Created: February 7, 2013
-- Author:       Bill McEvoy
-- Version:      1.0
-- Description:  This procedure produces a detailed report about the SQL Server.  Information
--               produced includes disk free space, database sizes, backups, job statues, etc.
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: February 7, 2013
-- Author:       Bill McEvoy
-- Reason:       Added a nifty memory usage query, only works in SQL 2008 and up!
---------------------------------------------------------------------------------------------------
-- Date Revised: March 12, 2013
-- Author:       Bill McEvoy
-- Reason:       We can now check to see if the agent is running via T-SQL.
---------------------------------------------------------------------------------------------------
-- Date Revised: April 4, 2013
-- Author:       Bill McEvoy
-- Reason:       Added Distinct clause to reduce repeat entries in backup work tables.
---------------------------------------------------------------------------------------------------
-- Date Revised: April 6, 2013
-- Author:       Bill McEvoy
-- Reason:       We now check MSDB..suspect_pages for any reports of problematic pages.
---------------------------------------------------------------------------------------------------
-- Date Revised: July 31, 2013
-- Revision:     1.0
-- Author:       Bill McEvoy
-- Reason:       Implemented versioning.
--               Removed reliance on xp_cmdshell for determining server boot time and agent logs.
--               Databases are now indicated as being readonly in the backup report section.
---------------------------------------------------------------------------------------------------
-- Date Revised: August 25, 2013
-- Author:       Bill McEvoy
-- Reason:       Added the much awaited "long running job" logic.
---------------------------------------------------------------------------------------------------
-- Date Revised: April 5, 2014
-- Author:       Bill McEvoy
-- Reason:       Added Show Datase File sizes
---------------------------------------------------------------------------------------------------
-- Date Revised: November 13, 2015
-- Author:       William McEvoy
-- Reason:       Added new code to show free drive space
---------------------------------------------------------------------------------------------------
-- Date Revised: November 24, 2015
-- Author:       William McEvoy
-- Reason:       Added code to display CPU stats per database
---------------------------------------------------------------------------------------------------
-- Version:      1.1
-- Date Revised: 16 August, 2016
-- Author:       William McEvoy
-- Reason:       Added version information, modified who we load SQL Agent Log
---------------------------------------------------------------------------------------------------
-- Version:      1.2
-- Date Revised: 18 August, 2016
-- Author:       William McEvoy
-- Reason:       Increased length of servername fields
---------------------------------------------------------------------------------------------------
-- Version:      1.3
-- Date Revised: 26 August, 2016
-- Author:       William McEvoy
-- Reason:       - Fixed nuberic lengths to take into account Terabyte sizes
--               - increased lenth of errorlog strings
--               - added with(nolock) to queries that use sysindexes and sysfiles to avoid this
--                 process from being blocked by open transactions
--               - added code to show open transactions
---------------------------------------------------------------------------------------------------
-- Version:      1.4
-- Date Revised: 1 Sept, 2016
-- Author:       William McEvoy
-- Reason:       Added code to report on logfile usage
---------------------------------------------------------------------------------------------------
-- Version:      1.5
-- Date Revised: 8 Sept, 2016
-- Author:       William McEvoy
-- Reason:       Added last 10 minutes of CPU report
---------------------------------------------------------------------------------------------------
-- Version:      1.6
-- Date Revised: February 9, 2017
-- Author:       William McEvoy
-- Reason:       Added report to show local port and IP address
---------------------------------------------------------------------------------------------------
-- Version:      1.7
-- Date Revised: March 9, 2017
-- Author:       William McEvoy
-- Reason:       Removed use of double quotes.  Single quotes are now escaped properly.
---------------------------------------------------------------------------------------------------
-- Version:      1.8
-- Date Revised: August 30, 2018
-- Author:       William McEvoy
-- Reason:       Added report to show service account information
---------------------------------------------------------------------------------------------------
-- Version:      1.9
-- Date Revised: October 29, 2019
-- Author:       William McEvoy
-- Reason:       Expanded column width for errorlog table
---------------------------------------------------------------------------------------------------
-- Version:      1.10
-- Date Revised: January 9, 2020
-- Author:       William McEvoy
-- Reason:       Added to filters list for the ERRORLOG
---------------------------------------------------------------------------------------------------
-- Version:      1.10
-- Date Revised: January 9, 2020
-- Author:       William McEvoy
-- Reason:       Added to filters list for the ERRORLOG
---------------------------------------------------------------------------------------------------
-- Version:      1.11
-- Date Revised: January 16, 2023
-- Author:       William McEvoy
-- Reason:       Changing INT to BIGINT
---------------------------------------------------------------------------------------------------




print ' '
print ' '
print ' '
print '======================================================================================='
print '==                                                                                   =='
print '==                            S E R V E R   S T A T U S                              =='
print '==                                                                                   =='
print '==                                       1.10                                        =='
print '==                                                                                   =='
print '======================================================================================='
PRINT @@SERVERNAME
print ' '
print ' '
print '======================'
print '= SERVER INFORMATION ='
print '======================'
print ' '
print ' '

set nocount on

declare @output    varchar(8000),
        @cpu_busy  bigint,
        @idle      bigint,
        @io_busy   bigint,
        @cpu_count tinyint

select  @output    = '',
        @cpu_busy  = 0,
        @idle      = 0,
        @io_busy   = 0,
        @cpu_count = 0



---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
-- Display SQL Version                                             --
--                                                                 --
-- Gather detailed system information                              --
--                                                                 --
-- Determine drive free space                                      --
--                                                                 --
-- Calculate reboot times                                          --
--                                                                 --
-- Show SQL CPU usage info since last SQL restart                  --
--                                                                 --
-- Show list of linked server definitions                          --
--                                                                 --
---------------------------------------------------------------------

select convert(char(40), @@SERVERNAME) as 'SQL SERVER NAME'
print ' '


---------------------------------------------------------------------
-- Display SQL Version       --
---------------------------------------------------------------------

select @output = @@VERSION
print 'SQL SERVER VERSION'
print '------------------'
print  @output
print ' '

---------------------------------------------------------------------
-- Display Service Account Information                                            --
---------------------------------------------------------------------


print 'SERVICE ACCOUNTS'
print '----------------'
print ' '

select left(Service_Account,40)   as 'Account',
       left(ServiceName,55)       as 'Service',
       left(Startup_type_desc,12) as 'Startup',
	   left(Status_Desc,20)       as 'Status'
 from sys.dm_server_services



---------------------------------------------------------------------
-- Gather detailed system information                              --
---------------------------------------------------------------------

IF (object_id('tempdb..#MSVER') IS NOT NULL)
  drop table #MSVER
CREATE TABLE #MSVER
(
  TheIndex        int,
  TheName         varchar(32),
  InternalValue  varchar(20),
  CharacterValue varchar(150)
)

insert #MSVER (TheINdex, TheName, InternalValue, CharacterValue)
exec ('master.dbo.xp_msver')

select @cpu_count = InternalValue
  from #MSVER
 where TheName = 'ProcessorCount'

select 'Configuration' = left(TheName,20),
       'Value'         = case when (TheName = 'PhysicalMemory') then left(InternalValue,10)  + ' (MB)' else left(InternalValue,10)  end,
       'Description'   = left(CharacterValue,50)
  from #MSVER
 where TheName in ('Language','ProcessorCount','ProcessorActiveMask','ProcessorType','PhysicalMemory')
order by 1


select distinct local_net_address as 'Server IP Address',
       local_tcp_port as 'Port'
  from sys.dm_exec_connections where local_net_address is not null


---------------------------------------------------------------------
-- Determine drive free space                                      --
---------------------------------------------------------------------

print ' '
print '** Note: only drives with databases show up in this list **'
print ' '


/*
IF (object_id('tempdb..#RESULTS') IS NOT NULL)
  drop table #RESULTS

create table #RESULTS
(
  drive char(1) NULL,
  freespace bigint NULL
)

insert into #RESULTS (drive, freespace)
exec master..xp_fixeddrives

select drive as 'Drive',
       cast((freespace / 1024.0) as decimal(6,2)) as 'Free Space(GB)'
  from #RESULTS
*/


;with DriveSpace
as
(
  SELECT DISTINCT UPPER(vs.volume_mount_point) AS Drive_Letter
      ,vs.logical_volume_name AS Drive_Label
      ,str((vs.total_bytes / 1024.0 / 1024),15,2) AS SizeMB
      ,str((vs.available_bytes / 1024.0 / 1024),15,2)  AS FreeSpaceMB
      ,str((vs.total_bytes / 1024.0 / 1024.0 / 1024.0),15,2) AS TotalSizeGB
      ,str((vs.available_bytes / 1024.0 / 1024.0 / 1024.0),15,2) AS FreeSpaceGB
      ,str((vs.available_bytes / 1024.0 / 1024.0 / 1024.0) / (vs.Total_Bytes / 1024.0 / 1024 / 1024) *100 ,8,2) AS 'FreeSpace%',
      ((vs.available_bytes / 1024.0 / 1024.0 / 1024.0) / (vs.Total_Bytes / 1024.0 / 1024 / 1024) *100) as 'intFreeSpace%',
      (vs.available_bytes / 1024.0 / 1024.0 / 1024.0)  AS [intFreeSpaceGB]
  FROM sys.master_files f
  CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id) AS vs
)
  select left(Drive_Letter,10) as 'Drive', 
         left(Drive_Label,20) as 'Label',
         SizeMB,
         FreeSpaceMB,
         TotalSizeGB,
         FreeSpaceGB,
         [FreeSpace%],
         'Alert' = case when ([intFreeSpace%] < 20 and [intFreeSpaceGB]< 50) then '**ALERT**  Warning: LOW DISK SPACE  **ALERT**' else '' end
    from DriveSpace ds
order by Drive



---------------------------------------------------------------------
-- Calculate reboot times                                          --
---------------------------------------------------------------------

/*print ' '
IF (object_id('tempdb..#NET_STATS') IS NOT NULL)
  drop table #NET_STATS

create table #NET_STATS
(
  log_id    int identity,
  net_stats varchar(100) NULL
)
insert into #NET_STATS (net_stats)
exec master..xp_cmdshell 'net statistics server'

-- remove extra line feed characters
update #NET_STATS
   set net_stats = replace(net_stats, char(13), ' ' )

--  select  'Server Reboot' = (select substring(net_stats,18,18) from #NET_STATS where net_stats like 'statistics since%')
*/

-- display reboot times
print ' '

select 'SQL Uptime(days)' = convert(varchar(16),cast((datediff(mi,login_time, getdate()) / 60.0 / 24.0) as decimal (4,1))),
       'SQL Started'      = convert(char(19), login_time,120),
       'Windows Started'  = (select dateadd(second,(ms_ticks/1000)*(-1),getdate()) from sys.dm_os_sys_info)
  from master..sysprocesses
where spid = 1

---------------------------------------------------------------------
-- Show SQL CPU usage info since last SQL restart                  --
---------------------------------------------------------------------




/*
-- In SQL 2005, the system statistical functions (@@idle, @@cpu_busy) store the number of cpu ticks.
-- To convert to milliseconds, multiply by @@TIMETICKS
  select @cpu_busy = convert(bigint,@@CPU_BUSY) * @@TIMETICKS,
         @idle     = convert(bigint,@@IDLE)     * @@TIMETICKS,
         @io_busy  = convert(bigint,@@IO_BUSY)  * @@TIMETICKS

print ' '
select 'SQL CPU Busy Time'         = ltrim(str((@cpu_busy /1000 / 60.0),12,2)) + ' minutes',
       'SQL CPU Idle Time'         = ltrim(str((@idle / 1000.0 / 60.0), 12,2)) + ' minutes',
       'CPU Percent Busy'          = str((@cpu_busy * 100.0 / @idle),5,2)      + ' %',
       'Time Spent Performing I/O' = ltrim(str((@@IO_BUSY / 1000.0 / 60.0),12,2))  + ' minutes'
*/



-- New qeury does not need variables
;with CPUUsage as
(
    select 'CPUBusy' = convert(bigint,@@CPU_BUSY) * @@TIMETICKS,
	       'CPUIdle' = convert(bigint,@@IDLE)     * @@TIMETICKS,
		   'IOBusy'  = convert(bigint,@@IO_BUSY)  * @@TIMETICKS
)
  select 'SQL CPU Busy Time'         = ltrim(str((CPUBusy /1000 / 60.0),12,2)) + ' minutes',
         'SQL CPU Idle Time'         = ltrim(str((CPUIdle / 1000.0 / 60.0), 12,2)) + ' minutes',
         'CPU Percent Busy'          = str((CPUBusy * 100.0 / CPUIdle),5,2)      + ' %',
         'Time Spent Performing I/O' = ltrim(str((IObusy / 1000.0 / 60.0),12,2))  + ' minutes',
         'CPUPercentBusy'            = CPUBusy * 100.0 / CPUidle,
         'Alert'                     = case 
                                        when (CPUBusy * 100.0 / CPUidle) >= 80 then 'CRITICAL'
                                        when (CPUBusy * 100.0 / CPUidle) >= 20 then 'WARNING'
                                        else 'GOOD'
                                      end
  from CPUUsage









print ' '
Select 'SignalWaitTime(ss)'   = str((sum(signal_wait_time_ms) / 1000.0),18,2),
       'ResourceWaitTime(ss)' = str((sum(wait_time_ms - signal_wait_time_ms) / 1000.0),20,2),
       'CPU Pressure'         = str((cast(100.0 * sum(signal_wait_time_ms) / sum (wait_time_ms) as numeric(20,2))),12,2) + '%',
       'Resource Pressure'    = str((cast(100.0 * sum(wait_time_ms - signal_wait_time_ms) / sum (wait_time_ms) as numeric(20,2))),17,2) + '%'
From sys.dm_os_wait_stats

-- Reset stats
--dbcc sqlperf ([sys.dm_os_wait_stats],clear) with no_infomsgs




-- Show CPU usage for the past 10 minutes


DECLARE @ts_now bigint = (SELECT cpu_ticks/(cpu_ticks/ms_ticks)FROM sys.dm_os_sys_info); 
-- Top 10 : for the last 10 minutes
SELECT TOP(10)  100 - SystemIdle as [CPU Usage %],
           DATEADD(ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS [Event Time] 
FROM ( 
  SELECT record.value('(./Record/@id)[1]', 'int') AS record_id, 
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') 
        AS [SystemIdle], 
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 
        'int') 
        AS [SQLProcessUtilization], [timestamp] 
  FROM ( 
        SELECT [timestamp], CONVERT(xml, record) AS [record] 
        FROM sys.dm_os_ring_buffers 
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' 
        AND record LIKE '%<SystemHealth>%') AS x 
  ) AS y 
ORDER BY record_id DESC;



-- SQL 2008 and up!
---------------------------------------------------------------------
-- Show current Memory usage                                       --
---------------------------------------------------------------------
print ' '
print 'CPU USAGE PER DATABASE'
print '----------------------'
print ' '

;WITH DB_CPU_Stats
AS
(SELECT DatabaseID,
        left(DB_Name(DatabaseID),35) AS [Database Name],
        SUM(total_worker_time) AS [CPU_Time_Ms]
 FROM sys.dm_exec_query_stats AS qs
 CROSS APPLY (SELECT CONVERT(int, value) AS [DatabaseID] 
              FROM sys.dm_exec_plan_attributes(qs.plan_handle)
             WHERE attribute = N'dbid'
              ) AS F_DB
 GROUP BY DatabaseID)
SELECT ROW_NUMBER() OVER(ORDER BY [CPU_Time_Ms] DESC) AS [CPU Rank],
       [Database Name], [CPU_Time_Ms] AS [CPU Time (ms)], 
       CAST([CPU_Time_Ms] * 1.0 / SUM([CPU_Time_Ms]) OVER() * 100.0 AS DECIMAL(5, 2)) AS [CPU Percent]
FROM DB_CPU_Stats
WHERE DatabaseID <> 32767 -- ResourceDB 
ORDER BY [CPU Rank] OPTION (RECOMPILE)



---------------------------------------------------------------------
-- Show current Memory usage                                       --
---------------------------------------------------------------------

/* Physical memory. View external pressure. */
SELECT 'TotalMemory(MB)' = total_physical_memory_kb/1024,
	     'Used(MB)'        = (total_physical_memory_kb - available_physical_memory_kb)/1024, 
	     'Available(MB)'   = available_physical_memory_kb/1024, 
	     'Free'            = str(((available_physical_memory_kb) / convert(numeric(15,2),total_physical_memory_kb) * 100.0),5,3) + '%',
	     'Used'            = str(((total_physical_memory_kb - available_physical_memory_kb) / convert(numeric(15,2),total_physical_memory_kb) * 100.0),5,3) + '%',
	     left(system_memory_state_desc,40) as 'Memory State'
FROM master.sys.dm_os_sys_memory; 








---------------------------------------------------------------------
-- Show list of linked server definitions                          --
---------------------------------------------------------------------

print ' '
select 'LocalServer'  = left(@@SERVERNAME,30),
       'LinkedServer' = left(srvname,15),
       'DataSource'   = left(datasource,15),
       'NetworkName'  = left(srvnetname,15),
       'LocalLogin'   = isnull(left(sl.loginname,15),''),
       'RemoteLogin'  = isnull(left(sou.rmtloginame,15),''),
--       'Status'       = case (sou.status) when 0 then 'No Credentials' when 1 then 'Use Credentials' else '??' end,
--       'DateUpdated'  = convert(varchar(19),schemadate,120),
       'Description'  = case
                          when ((sou.rmtloginame IS NOT NULL) and (sl.loginname IS NOT NULL) and (sou.status = 0)) then 'Local login maps to remote login.'
                          when ((sou.rmtloginame IS NOT NULL) and (sl.loginname IS     NULL) and (sou.status = 0) and rmtpassword IS NOT NULL) then 'For connections not listed, connect using the remote login.'
                          when ((sou.rmtloginame IS NOT NULL) and (sl.loginname IS     NULL) and (sou.status = 0)) then 'For connections not listed, do not connect.'
                          when ((sou.rmtloginame IS     NULL) and (sl.loginname IS NOT NULL) and (sou.status = 1)) then 'Local login is impersonated remotely using the current security credentials.'
                          when ((sou.rmtloginame IS     NULL) and (sl.loginname IS     NULL) and (sou.status = 0)) then 'For connections not listed, make a connection without a security context.'
                          when ((sou.rmtloginame IS     NULL) and (sl.loginname IS     NULL) and (sou.status = 1)) then 'For connections not listed, connect using the current security credentials.'
                          else '??'
                        end,
       'Product'      = left(srvproduct,12),
       'Provider'     = left(providername,10),
       rpc,
       rpcout
  from master.dbo.sysservers     ss
  join master.dbo.sysoledbusers  sou on sou.rmtsrvid = ss.srvid
  left join master.dbo.syslogins      sl  on sl.sid = sou.loginsid
 where srvid <> 0



---------------------------------------------------------------------
-- Show open transactions                                          --
---------------------------------------------------------------------

print ' '
print ' '
print 'Open Transactions'
print '-----------------'
print ' '

select left(db_name(t.database_id),20) as 'Database',
       left(s.Host_Name,15) as 'Host',
       left(s.Login_name,25) as 'Login',
       Database_Transaction_Begin_Time as 'TxStart',
       database_transaction_log_record_count as 'TxLogRecordCount',
       database_transaction_log_bytes_used   as 'TxLogBytesUsed',
       left(s.Program_name,50) as 'Program'
from sys.dm_tran_database_transactions t
join sys.dm_tran_session_transactions st on t.transaction_id = st.transaction_id 
join sys.dm_exec_sessions s on s.session_id = st.session_id 



---------------------------------------------------------------------
-- Show database sizes                                             --
---------------------------------------------------------------------

print ' '
print ' '
select 'Database' = left(db_name(mf.database_id),25),
        'Status'   = left(max(case(d.state_desc) when 'ONLINE' then 'online' else d.State_desc end),6),
        'Recovery' = left(max(d.recovery_model_desc),6),
        'Data GB'  = str(sum(case (mf.type) when 0 then (convert(decimal(12,2),(mf.size * 8128.0) / 1024.0 / 1024.0 / 1024.0)) else 0 end),6,2),
        'Log GB'   = str(sum(case (mf.type) when 1 then (convert(decimal(12,2),(mf.size * 8128.0) / 1024.0 / 1024.0 / 1024.0)) else 0 end),6,2)
  from sys.master_files mf
  join sys.databases     d on d.database_id = mf.database_id
group by mf.database_id


---------------------------------------------------------------------
-- Show database FILE sizes                                        --
---------------------------------------------------------------------
print ' '
print ' '
select 'Database' = left(db_name(database_id),25),
       'FileName' = left(Name,25),
       'Type'     = left(Type_Desc,5),
       'SizeGB'   = str((Size * 8128.0) / 1024.0 / 1024.0 / 1024.0,10,2),
       'GrowthMB' = str((Growth * 8128.0) / 1024.0 / 1024.0,10,2),
       'FileName' = left(Physical_Name,60)
 from sys.master_files with (nolock)
where db_name(database_id) not in ('master','model','msdb')
 order by 1


---------------------------------------------------------------------
-- Show logfile usage                                              --
---------------------------------------------------------------------
print ' '
print ' '
IF (object_id('tempdb..#SQLPerfResults') IS NOT NULL)
  drop table #SQLPerfResults
create table #SQLPerfResults 
(
  DatabaseName      varchar(100),
  [LogSize(MB)]     decimal(15,3),
  [LogSpaceUsed(%)] decimal(5,2),
  Status int
)
insert into #SQLPerfResults(DatabaseName, [LogSize(MB)], [LogSpaceUsed(%)], Status)
exec ('dbcc sqlperf(logspace) with no_infomsgs')


select 'Database' = left(DatabaseName,20),
       'LogSize(MB)'     = str([LogSize(MB)],15,2),
       'LogSpaceUsed(%)' = str([LogSpaceUsed(%)],15,2),
       'Alert' = case when ([LogSpaceUsed(%)] > 80) then '**ALERT**  Low free space in TX log detected  **ALERT**' else '' end
  from #SQLPerfResults
order by 1 desc





print ' '
print ' '
print '========================='
print '== Database Space Used =='
print '========================='
print ' '

IF NOT EXISTS(select 1 from sys.dm_tran_database_transactions where database_transaction_begin_time is not null)
BEGIN

  ---------------------------------------------------------------------------------------------------
  -- Date Created: July 11, 2005        
  -- Author:       Bill McEvoy
  --               
  -- Description:  This procedure reports on the space used by each database on the server.
  --               
  ---------------------------------------------------------------------------------------------------
  -- Date Revised: 
  -- Author:       
  -- Reason:       
  ---------------------------------------------------------------------------------------------------
  set nocount on
  declare @errnum         int          ,
          @errors         char(1)      ,
          @rowcnt         bigint       ,
          @rows_found     int     ,
          @pages          int          ,
          @dbsize         dec(18,0)    ,
          @bytesperpage   dec(18,0)    ,
          @pagesperMB     dec(18,0)    ,
          @database_name  varchar(255) ,
          @sql            varchar(8000)

  select  @errnum         = 0          ,
          @errors         = 'N'        ,
          @rowcnt         = 0          ,
          @rows_found     = 0          ,
          @Output         = ''         ,
          @bytesperpage   = 8196       ,
          @pagesperMB     = 1048576 / @bytesperpage, -- 127.9
          @database_name  = ''         ,
          @sql            = ''

  if object_id('tempdb..#SPACE_USED') is not null
  begin
     drop table #SPACE_USED
  end

  create table #SPACE_USED
  (
     Database_Name  varchar(255),
     RecoveryModel  varchar(10),
     Database_Size  decimal(12,2),
     Space_Reserved decimal(12,2),
     Space_Free     decimal(12,2),
     Data_Portion   decimal(12,2),
     Index_Portion  decimal(12,2),
     Tx_Log         decimal(12,2)
  )

  declare dblist_csr cursor for 
  select name, *
  from master.dbo.sysdatabases sd
  join sys.dm_hadr_database_replica_states rs on sd.dbid = rs.database_id
  where DATABASEPROPERTYEX(name, 'Status') = 'ONLINE'
  and rs.is_local = 1 -- we cant query secondary databases


  open dblist_csr

  fetch next from dblist_csr  
  into @database_name           

  while (@@FETCH_STATUS = @rows_found)
  begin
    select @sql = 'select  ''Database''          = ''' + @database_name + ''',' +
    '        convert(varchar(10),databasepropertyex(''' + @Database_Name + ''',''recovery'')) as ''RecoveryModel'',' +
    '        ''Database_Size''     = str((select sum(size) from [' + @database_name + '].dbo.sysfiles with (nolock) where filename not like ''%.LDF%'')/ 128.0,15,2), ' +
    '        ''Space_Reserved''    = str((select sum(reserved)from [' + @database_name + '].dbo.sysindexes with (nolock)	where indid in (0, 1, 255))  * 8192.0 / 1048576.0,15,2),' +
    '        ''Space_Free''        = str(((select sum(size) from [' + @database_name + '].dbo.sysfiles with (nolock) where filename not like ''%.LDF%'') - (select sum(convert(dec(15),reserved)) from [' + @database_name + '].dbo.sysindexes with (nolock) where indid in (0, 1, 255))) / 128.0,15,2),' +
    '        ''Data_Portion''      = str((((select sum(convert(dec(15),dpages))   from [' + @database_name + '].dbo.sysindexes with (nolock) where indid < 2) + (select isnull(sum(convert(dec(15),used)), 0) from [' + @database_name + '].dbo.sysindexes with (nolock) where indid = 255)) * 8192 / 1048576),15,2),         ' +
    '        ''Index_Portion''     = str(((select sum(convert(dec(18),used)) from [' + @database_name + '].dbo.sysindexes with (nolock) where indid in (0, 1, 255))* 8192 / 1048576.0) - (((select sum(convert(dec(18),dpages))   from [' + @database_name + '].dbo.sysindexes with (nolock) where indid < 2) + (select isnull(sum(convert(dec(18),used)), 0) from [' + @database_name + '].dbo.sysindexes with (nolock) where indid = 255))*8192 / 1048576),18,2),' +
    '        ''Tx_Log''            = (select cast ((sum(size) * 8/1024) as decimal(18,2)) from [' + @database_name + '].dbo.sysfiles with (nolock) where filename like ''%.LDF%'')'

    insert into #SPACE_USED  
    execute(@sql)

    fetch next from dblist_csr  
    into @database_name           
  end

  close dblist_csr
  deallocate dblist_csr


  -- CORRECT ANOMOLIES
  -- SOMETIMES THE INDEX_PORTION COLUMN HAS A VALUE LESS THAN 0.
  -- THIS IS POSSIBLY BECAUSE THE STATISTICS ARE OUT OF DATE
  update #space_used 
     set index_portion = 0 
   where index_portion < 0

  select left(database_name,30)  as 'DB Name',
         RecoveryModel,
         convert(varchar(15),convert(decimal(12,2),database_size))  as 'DB Size(MB)',
         convert(varchar(20),tx_log)         as 'Tx Log(MB)',
         convert(varchar(20),space_reserved) as 'Reserved(MB)',
         convert(varchar(20),space_free)     as 'Free(MB)',
convert(varchar(20),data_portion)   as 'Data(MB)',
         convert(varchar(20),index_portion)  as 'Index(MB)',
         convert(varchar(20),convert(decimal(6,2),(database_size + tx_log) / 1024)) as 'Total (GB)'
  from #SPACE_USED
  order by database_name
  print ' '
  print ' '

  -- DISPLAY BAR GRAPH REPRESENTING USAGE INFO
  select 'Database'        = left(database_name,30),
         'Reserved / Free' = convert(char(25),replicate('0',(round(space_reserved / database_size * 25.0,0))) + replicate('.',(round(space_free / database_size * 25.0,0)))),
         'Data / Index'    = convert(char(25),replicate('o',(round((data_portion / (data_portion + index_portion) * 25.0),0))) + replicate('I',(round((index_portion / (data_portion + index_portion)  * 25.0),0 ))))
    FROM #space_used




  print ' '
  print ' '
  print '================='
  print '== Table Sizes =='
  print '================='
  print ' '

  declare @Tables  int,     --> Number of tables per database to include in report
          @ColSort smallint --> Column number to sort on (7th column = Total MB)

  select  @Tables  = 2,
          @ColSort = 7

  ---------------------------------------------------------------------------------------------------
  -- Date Created: February 10, 2007
  -- Author:       Bill McEvoy
  --               
  -- Description:  This procedure produces a report that summarizes the top X number of tables
  --               in each database.
  --               
  ---------------------------------------------------------------------------------------------------
  set nocount on



  select  @SQL = '
    IF(''?'' NOT IN (''tempdb'',''pubs'',''northwind'',''model'',''msdb'',''master''))
    BEGIN
      print '' ''
      print ''------------------------------- ''
      print ''-- ?''
      print ''------------------------------- ''
      print '' ''
      select top ' + convert(varchar(8),@Tables) + '
             ''Table Name'' = convert(char(50),so.name),
             ''PKey/Text/Index'' = convert(char(50),si.name),
             ''Type''            = case (indid)
                                   when 0 then ''Heap''
                                   when 1 then ''Clustered''
                                   when 255 then ''Text''
                                   else str(indid,4,0)
                                 end,
             ''Rows''            = str(rows,10,0),
             ''Data MB''         = str(convert(decimal(15,3),(dpages        * 8196.0 / 1048567.0)),10,2),
             ''Index MB''        = str(convert(decimal(15,3),((used-dpages) * 8196.0 / 1048567.0)),10,2),
             ''Total MB''        = str(convert(decimal(15,3),((used)        * 8196.0 / 1048567.0)),10,2),
             ''FillFactor''      = str(origfillfactor,10,0)
        from [?].dbo.sysindexes  si with (nolock)
        join [?].dbo.sysobjects so  with (nolock) on so.id = si.id
       where si.indid in (0,1,1255)
         and so.xtype <> ''S''
       order by ' + convert(varchar(8),@ColSort) + ' desc
     END
   '
 
  exec msdb..sp_msforeachdb @SQL


END
ELSE
BEGIN
  print ' '
  print ' '
  print 'WARNING!  An open transaction may interfere with our abiliity to calculate storage.  Rerun ServerStatus once the transaction has completed'
  print ' '
END




---------------------------------------------------------------------
-- Show suspect pages                                              --
---------------------------------------------------------------------
print ' '
print ' '
print '=========================='
print '== TORN / SUSPECT Pages =='
print '=========================='
print ' '

select left(db_name(database_id),30) as 'Database', 
       database_id,
       file_id,
       page_id,
       event_type,
       error_count,
       Last_Update_Date
  from MSDB.dbo.suspect_pages





print ' '
print ' '
print '==================='
print '== SQL Errorlogs =='
print '==================='
print ' '


declare
  @FirstLog      smallint, 
  @LastLog       smallint,
  @BufferRecords smallint

select
  @FirstLog      = 0, --> Defaults to current logfile
  @LastLog       = 1, --> Defaults to logfile immediately preceding current
  @BufferRecords = 4  --> Used to give a frame of reference to the error message

---------------------------------------------------------------------------------------------------
-- Date Created: July 11, 2005
-- Author:       Bill McEvoy
-- Description:  This procedure combines and parses the SQL Error Logs.  Entries of special 
--               interest are marked which allows the operator to quickly scan the output for
--               errors.  Entries of interest are removed from the output.  Entries before and
--               after the errors are included to give a frame of reference.
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: December 7, 2006
-- Author:       Bill McEvoy
-- Reason:       I converted this procedure to support SQL Server 2005
---------------------------------------------------------------------------------------------------
set nocount on
declare @count  smallint,
        @alert  char(5)
 
select  @count  = 0,
        @SQL    = '',
        @output = '',
        @alert  = '---->'

---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------

IF (@FirstLog > @LastLog)
BEGIN
  select @lastLog = @FirstLog + 1
END


---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
-- Create work tables                                              --
--                                                                 --
-- Import SQL Error Logs                                           --
--                                                                 --
-- Remove unwanted entries                                         --
--                                                                 --
-- Mark items of interest                                          --
--                                                                 --
-- Generate report                                                 --
--                                                                 --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- Create work tables                                              --
---------------------------------------------------------------------

IF (object_id('tempdb..#ERRORLOG') IS NOT NULL)
  drop table #ERRORLOG

CREATE TABLE #ERRORLOG
(
  LogID       int identity primary key clustered,
  LogDate     datetime NULL,
  ProcessInfo varchar(12) NULL, 
  Alert       char(5) default ' ',
  LogEntry    varchar(7500) NULL,
  Row         smallint NULL
  
)

-- Add indexes
create index [IX_ERRORLOG_Alert]           on dbo.[#ERRORLOG](Alert)          with fillfactor = 98 on [PRIMARY]

-- No longer needed it seems!
--create index [IX_ERRORLOG_LogEntrySearch] on dbo.[#ERRORLOG](LogEntrySearch) with fillfactor = 98 on [PRIMARY]


---------------------------------------------------------------------
-- Import SQL Error Logs                                           --
---------------------------------------------------------------------

select @count = @FirstLog



  WHILE (@Count <= @LastLog) 
  BEGIN
    insert into #ERRORLOG (ProcessInfo, Alert, LogEntry) values (' ','',' ')
    insert into #ERRORLOG (ProcessInfo, Alert, LogEntry) values (' ','',' ')
    insert into #ERRORLOG (ProcessInfo, Alert, LogEntry) values (' ','',' ')
    insert into #ERRORLOG (ProcessInfo, Alert, LogEntry) values (' ','','------------------------------')
    select @output = '-- Processing: ERRORLOG' + case(@count) when 0 then '    ' else '.' + convert(char(3), @count) end + ' --'
    insert into #ERRORLOG (ProcessInfo, Alert, LogEntry) values (' ','',@output)
    insert into #ERRORLOG (ProcessInfo, Alert, LogEntry) values (' ','','------------------------------')
    insert into #ERRORLOG (ProcessInfo, Alert, LogEntry) values (' ','',' ')
    select @SQL = 'exec master..sp_readerrorlog ' + convert(varchar(3), @count)
    insert into #errorlog (LogDate, ProcessInfo, LogEntry)
    execute (@SQL)
    select @count = @count + 1
  END

select max(len(logentry)) as 'MaxLen' from #Errorlog

---------------------------------------------------------------------
-- Remove unwanted entries                                         --
---------------------------------------------------------------------


delete 
  from #ERRORLOG 
 where LogEntry like '%Bypassing recovery for database%'
    or LogEntry like '%Setting database option ANSI_WARNINGS%'
    or LogEntry like '%Log backed up with following information:%'
    or LogEntry like '%Login succeeded for user%'
    or LogEntry like '%found 0 errors and repaired 0 errors%'
    or LogEntry like '%Database differential changes%'
    or LogEntry like '%The certificate was successfully loaded%'
    or LogEntry like '%this is an informational message only%'
    or LogEntry like '%logging sql server messages in file%'
    or LogEntry like '%Recovery complete.%'
    or LogEntry like '%Recovery model%'
    or LogEntry like '%Starting up database ''ERROR_LOGGING''%'
    or LogEntry like '%Database backed up: Database: %'
    or LogEntry like '%Log backed up: Database: %'
    or LogEntry like '%Is preferred backup replica:%'
    or LogEntry like '%Parameters: @Databases = %'
    



---------------------------------------------------------------------
-- Mark items of interest                                          --
---------------------------------------------------------------------

update #ERRORLOG
   set Alert = @alert
 where (LogEntry like '%err%'
    or  LogEntry like '%exception%'
    or  LogEntry like '%violation%'
    or  LogEntry like '%warn%'
    or  LogEntry like '%kill%'
    or  LogEntry like '%dead%'
    or  LogEntry like '%encounter%'
    or  LogEntry like '%cannot%'
    or  LogEntry like '%could%'
    or  LogEntry like '%fail%'
    or  LogEntry like '%full%'
    or  LogEntry like '%not%'
    or  LogEntry like '%terminate%'
    or  LogEntry like '%bypass%'
    or  LogEntry like '%recover%'
    or  LogEntry like '%roll%'
    or  LogEntry like '%upgrade%'
    or  LogEntry like '%victim%'
    or  LogEntry like '%stop%'
    or  LogEntry like '%shut%'
    or  LogEntry like '%timed out%'
    or  LogEntry like '%truncate%'
    or  LogEntry like '%terminat%')
   and  (ProcessInfo <> ' ' or  ProcessInfo IS NULL)



---------------------------------------------------------------------
-- Generate report                                                 --
---------------------------------------------------------------------


BEGIN

  -- Show entries of interest + buffer records
  select A.LogID,
         'Date'       = isnull(convert(varchar(19), A.LogDate, 120), ''),
         A.ProcessInfo,
         A.Alert,
         'Descripton' = left(A.logEntry, 250)
    from #ERRORLOG A
   join (select LogID from #ERRORLOG where Alert = @alert) B  on (A.LogID >= (B.LogID - @BufferRecords))
                                                           and (A.LogID <= (B.LogID + @BufferRecords))

  -- Show informational records
  union
  select A.LogID,
         'Date'       = isnull(convert(varchar(19), A.LogDate, 120), ''),
         A.ProcessInfo,
         A.Alert,
         'Descripton' = left(A.logEntry, 250)
    from #ERRORLOG A
   where ProcessInfo = ''
   order by A.LogID
END













print ' '
print ' '
print '================================='
print '== SQL Agent / Job Information =='
print '================================='
print ' '

declare @JobFailedDays smallint,
        @JobAllDays    smallint

select  @JobFailedDays = 3,
        @JobAllDays    = 3

---------------------------------------------------------------------------------------------------
-- Date Created: February 10, 2007
-- Author:       Bill McEvoy
--               
-- Description:  This procedure produces a report that details extensive information pertaining
--               to sQL Schedule djobs and SQL Maintenance plans.
--               
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------

declare @AgentLog  sysname,
        @CMD       varchar(2000),
		@RegistryValue varchar(1000)


select  @AgentLog  = '',
        @CMD       = '',
		@RegistryValue = ''


---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
-- Display SQL Server Agent error log                              --
--                                                                 --
-- Display Maintenance Plan Information                            --
--                                                                 --
-- Display Scheduled Job Information                               --
--                                                                 --
---------------------------------------------------------------------



---------------------------------------------------------------------
-- Is agent running?                                               --
---------------------------------------------------------------------


CREATE TABLE #SQLAgentStatus
(
Status varchar(50),
Timestamp datetime default (getdate())
)

-- Check status
INSERT #SQLAgentStatus (Status)
EXEC master..xp_servicecontrol N'QUERYSTATE',N'SQLServerAGENT' 

SELECT 'SQL AGENT STATUS' = case([status])
                              when 'running.' then 'running'
                              else 'WARNING!  SQL Agent is NOT running!'
                            end
  FROM #SQLAgentStatus



/*
-- STOP SQL Server Agent
EXEC xp_servicecontrol N'STOP',N'SQLServerAGENT' 

-- START SQL Server Agent
EXEC xp_servicecontrol N'START',N'SQLServerAGENT' 
*/




---------------------------------------------------------------------
-- Display SQL Server Agent error log                              --
---------------------------------------------------------------------

print 'SQL AGENT LOG'
print '============='
print ' '

  EXECUTE master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
                                         N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
                                         N'ErrorLogFile',
                                         @RegistryValue OUTPUT

BEGIN TRY
  select @AgentLog = '''' + @RegistryValue + ''''
  print @AgentLog
  select @cmd = 'select convert(varchar(max),convert(nvarchar(max), bulkcolumn))  from OPENROWSET(BULK' + @AgentLog + ',SINGLE_BLOB) x'
  exec( @Cmd)
END TRY
BEGIN CATCH
  print 'The SQL Agent Log could not be read. This is likely a permission issue.'
END CATCH



---------------------------------------------------------------------
-- Display Maintenance Plan Information                            --
---------------------------------------------------------------------

print ' '
print ' '
print 'CREATED MAINTENANCE PLANS'
print '========================='
print ' '

select 'Plan Name'    = left(plan_name,50),
       'Owner'        = left(owner,30),
       'Date Created' = date_created
  from msdb.dbo.sysdbmaintplans       


print ' '
print ' '
print 'FAILED MAINTENANCE PLANS'
print '========================'
print ' '

select top 10 'Date/Time' = convert(char(19), start_time, 120),
       'Plan Name' = left(plan_name,30),
       'Database'  = left(database_name,25),
       'Server'    = left(server_name,14),
       'Activity'  = left(activity, 20),
       'Status'    = case(succeeded) when (1) then '   Success' else '** FAILED **' end,
       'HH:MM:SS' = left(right(convert(char(19),(dateadd(ss,duration,getdate()) - getdate()),20),8),8),
       'error'     = convert(varchar(6),error_number),
       'message'   = left(message,225)
from msdb.dbo.sysdbmaintplan_history
where succeeded = 0


---------------------------------------------------------------------
-- Display Scheduled Job Information                               --
---------------------------------------------------------------------

print ' '
print ' '
print 'CREATED JOBS'
print '============'
print ' '

  select 'Server'       = left(@@ServerName,30),
         'JobName'      = left(S.name,55),
         'Owner'        = left(sl.name,25),
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
    left  join msdb.dbo.sysschedules    SS  on SS.schedule_id = sj.schedule_id
    left  join master..syslogins        sl  on sl.sid    = S.owner_sid
   order by s.name




print ' '
print ' '
print 'CURRENTLY RUNNING JOBS'
print '======================'
print ' '

;with JobTimings as
(
SELECT convert(varchar(50),name) as 'JobName',
       start_execution_date as 'StartDate',
       DATEDIFF(MINUTE,aj.start_execution_date,GetDate()) AS 'DurationInMinutes'
  FROM msdb..sysjobactivity aj
  JOIN msdb..sysjobs        sj on sj.job_id = aj.job_id
 WHERE aj.stop_execution_date IS NULL -- job hasn't stopped running
   AND aj.start_execution_date IS NOT NULL -- job is currently running
   and not exists( -- make sure this is the most recent run
       select 1
         from msdb..sysjobactivity new
        where new.job_id = aj.job_id
          and new.start_execution_date > aj.start_execution_date
      )
)
select StartDate,
       JobName,       DurationinMinutes,
       'Alert' = CASE when DurationInMinutes >= 120 then 'WARNING!  Long running job detected.' else '' end
  from JobTimings




print ' '
print ' '
print 'FAILED JOBS'
print '==========='
print ' '

select 'ID'        = convert(char(8), h.instance_id),
       'Run Time'  = convert(char(10),convert(datetime,convert(char(8),h.run_date)),120) + ' ' + left(right('00000' + cast(run_time as varchar(6)),6),2) + ':' + left(right('00000' + cast(run_time as varchar(6)),4),2) + ':' +
           right(cast(run_time as varchar(6)),2) + ' ',
--       'Duration'  = case when (h.run_duration > 1800) then '>' else ' ' end + left(right(convert(char(19),(dateadd(ss,h.run_duration,'')),20),8),8) + ' ',
       'Duration'  = case when (h.run_duration > 1800) then '>' else ' ' end + left(right(convert(char(19),(dateadd(ss,(left(stuff('000000',(7-len(h.run_duration)),len(h.run_duration),h.run_duration),2) * 3600 +
           substring(stuff('000000',(7-len(h.run_duration)),len(h.run_duration),h.run_duration),3,2) * 60 +     substring(stuff('000000',(7-len(h.run_duration)),len(h.run_duration),h.run_duration),5,2)),'')),20),8),8) + ' ',
       'Status'    = case(run_status)
                       when 0 then '** FAILED ** '
                       when 1 then 'Success '
                       when 2 then 'RETRY '
                       when 3 then 'CANCELLED '
                       when 4 then 'IN PROGRESS '
                       else '??'
                     end,
       'Step'      = convert(char(3),h.step_id),
       'Job Name'  = left(s.name,50),
       'Step Name' = left(h.step_name,35),
       'Message'   = left(h.message,200)
  from msdb.dbo.sysjobhistory h
 right join msdb.dbo.sysjobs s on s.job_id = h.job_id
 where h.run_date >= convert(int,(convert(char(8), (getdate()-@JobAllDays),112)))
   and h.run_status <> 1
 order by h.instance_id desc



print ' '
print ' '
print 'ALL JOB STATS'
print '============='
print ' '

select 'ID'        = convert(char(8), h.instance_id),
       'Run Time'  = convert(char(10),convert(datetime,convert(char(8),h.run_date)),120) + ' ' 
         + left(right('00000' + cast(run_time as varchar(6)),6),2) + ':' + left(right('00000' + cast(run_time as varchar(6)),4),2) + ':'
         +  right(cast(run_time as varchar(6)),2) + ' ',
--       'Duration'  = case when (h.run_duration > 1800) then '>' else ' ' end + left(right(convert(char(19),(dateadd(ss,h.run_duration,'')),20),8),8) + ' ',
       'Duration'  = case when (h.run_duration > 1800) then '>' else ' ' end + left(right(convert(char(19),(dateadd(ss,(left(stuff('000000',(7-len(h.run_duration)),len(h.run_duration),h.run_duration),2) * 3600 + 
       substring(stuff('000000',(7-len(h.run_duration)),len(h.run_duration),h.run_duration),3,2) * 60 +   
       substring(stuff('000000',(7-len(h.run_duration)),len(h.run_duration),h.run_duration),5,2)),'')),20),8),8) + ' ',
       'Status'    = case(run_status)
                       when 0 then '** FAILED ** '
                       when 1 then 'Success '
                       when 2 then 'RETRY '
                       when 3 then 'CANCELLED '
                       when 4 then 'IN PROGRESS '
                       else '??'
                     end,
       'Step'      = convert(char(3),h.step_id),
       'Job Name'  = left(s.name,50),
       'Step Name' = left(h.step_name,35),
       'Message'   = left(h.message,200)
  from msdb.dbo.sysjobhistory h
 right join msdb.dbo.sysjobs s on s.job_id = h.job_id
 where h.run_date >= convert(int,(convert(char(8), (getdate()-@JobAllDays),112)))
--   and (h.step_id = 0 or run_status = 0)
 order by h.instance_id desc








print ' '
print ' '
print '===================='
print '== Backup History =='
print '===================='
print ' '








-- Note: If the backups span midnight, the HH:MM:SS field might be incorrect

declare @days   smallint, 
        @dbname sysname
select  @days   = 1,  --> number of days to include in the report
        @dbname = '%' --> specifies which database name, defaults to all

---------------------------------------------------------------------------------------------------
-- Date Created: February 10, 2007
-- Author:       Bill McEvoy
-- Description:  This procedure generates a report which details the backup history for the
--               specified database (defaults to all) for the specified number of days in the
--               past.
--               
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------

IF (@days < 0 ) set @days = @days *(-1)


---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
-- Populate work tables                                            --
--                                                                 --
-- Produce Backup Summary                                          --
--                                                                 --
-- Show detailed backup history                                    --
--                                                                 --
-- Show backup throughput history                                  --
--                                                                 --
---------------------------------------------------------------------

print 'Backups since: ' + convert(char(19),getdate() -@days,120)


---------------------------------------------------------------------
-- Populate work tables                                            --
---------------------------------------------------------------------

IF (object_id('tempdb..#Backups') IS NOT NULL)
  DROP TABLE #Backups

select 'Server'   = left(ServerName,30),
       'Database' = left(DatabaseName,30),
       'Type'     = case (BackupType)
                      when 'L' then 'LOG'
                      when 'D' then 'DB'
                      when 'I' then 'INCR'
                      else BackupType
                    end,
       'UserName' = cast(UserName as varchar(30)),
       'Size(MB)' = FileSizeInMB,

       'HH:MM:SS' = left(right(convert(char(19),(BackupFinishDate - BackupStartDate),20),8),8),

       'Start'    = convert(char(20), BackupStartDate,20),
       'Finish'   = convert(char(20), BackupFinishDate,20),
       PhysicalDeviceName
  into #Backups
  from 
(
select distinct
       'ServerName'	            = left(bs.server_name,30),
       'DatabaseName'           = bs.database_name,
       'UserName'               = bs.user_name,
       'BackupType'             = bs.type,
       'BackupDeviceType'       = case when (bmf.device_type in (2,102)) then 'Disk' when (bmf.device_type in (5,7,105)) then 'Tape' else '??' end,
       'FileType'               = bf.file_type,
       'BackupSetType'          = bs.type,
       'PhysicalDeviceName'     = bmf.physical_device_name,
       'TransactionLogFileName' = substring(bmf.physical_device_name, (len(bmf.physical_device_name) - charindex('\',reverse(bmf.physical_device_name)) + 2) ,500),
       'BackupStartDate'        = bs.Backup_start_date,
       'BackupFinishDate'       = bs.backup_finish_date,
       'DurationInSeconds'      = datediff(ss,bs.backup_start_date, bs.backup_finish_date),
       'PageSizeInBytes'        = isnull(bf.page_size, 8192),
       'BackedUpPageCount'      = bf.backed_up_page_count,
       'FileSizeInBytes'        = isnull(bf.page_size,8192) * isnull(bf.backed_up_page_count,0),
       'FileSizeInMB'           = cast(((isnull(bf.page_size,8192) * isnull(bf.backed_up_page_count,0)) / 1024.0 / 1024.0) as decimal(14,2))
  from msdb.dbo.backupset         bs
  join msdb.dbo.backupmediafamily bmf on bmf.media_set_id = bs.media_set_id
  join msdb.dbo.backupfile        bf  on bf.backup_set_id = bs.backup_set_id
) as vBackupHistory


 where BackupStartDate >= convert(char(8),getdate()-@days,112)
   and DatabaseName like @dbname
   and NOT (BackupType = 'D' and FileType = 'L')
   and NOT (BackupType = 'I' and FileType = 'L')
   and DatabaseName not in ('tempdb','model','pubs','northwind')
 order by BackupStartDate


IF (object_id('tempdb..#BackupSummary') IS NOT NULL)
  DROP TABLE #BackupSummary

select 'Database' = (case when is_read_only = 1 then 'READONLY-> ' else '' end) + left(name,30),
       'Full_Backups' = (select count(*) from #Backups fb where fb.[Database] = sd.[name] and fb.type = 'DB'),
       'Incr_Backups' = (select count(*) from #Backups ib where ib.[Database] = sd.[name] and ib.type = 'INCR'),
       'Tx_Log'       = (select count(*) from #Backups tl where tl.[Database] = sd.[name] and tl.type = 'LOG')
  into #BackupSummary
  from sys.databases sd
 where name not in ('tempdb','model','pubs','northwind')
   and name like @dbname


---------------------------------------------------------------------
-- Produce Backup Summary                                          --
-------------------------------------------------------------------

print ' '
print '== BACKUP SUMMARY =='
print ' '


/*
select 'Database' = [Database],
       'Type'     = type,
       'Backups'  = count(*)
  from #Backups
 group by [Database], type
 order by [Database], type
*/

select distinct
       [Database],
       'Recent Full Backup' = case
                                when (Full_Backups > 0) then 'YES: ' + convert(char(4),Full_Backups)
                                else 'NO'
                              end,
       'Recent Incr Backup' = case
                                when (Incr_Backups > 0) then 'YES: ' + convert(char(4),Incr_Backups)
                                else 'NO'
                              end,
       'Recent TX Log'      = case
                                when (tx_log > 0) then 'YES: ' + convert(char(4),tx_log)
                                else 'NO'
                              end
  from #BackupSummary
 order by 1
 
---------------------------------------------------------------------
-- Show detailed backup history                                    --
---------------------------------------------------------------------

print ' '
print ' '
print '== FULL DATABASE BACKUPS =='
print ' '
select [Server],
       [Database],
       Type,
       'Size(MB)' = convert(varchar(10),[Size(MB)]),
       [HH:MM:SS],
       Start,
       Finish,
       'Day' = left(datename(dw,Start),9),
       UserName,
       'PhysicalDeviceName' = left(PhysicalDeviceName,120)
  from #Backups
 where Type = 'DB'
order by Finish desc       
       
print ' '
print ' '
print '== INCREMENTAL BACKUPS =='
print ' '
select [Server],
       [Database],
       Type,
       'Size(MB)' = convert(varchar(10),[Size(MB)]),
       [HH:MM:SS],
       Start,
       Finish,
       'Day' = left(datename(dw,Start),9),
       UserName,
       'PhysicalDeviceName' = left(PhysicalDeviceName,120)
  from #Backups
 where Type = 'INCR'
order by Finish desc       
       
print ' '
print ' '
print '== TRANSACTION LOG BACKUPS =='
print ' '
select distinct top 50 
       [Server],
       [Database],
       Type,
       'Size(MB)' = convert(varchar(10),[Size(MB)]),
       [HH:MM:SS],
       Start,
       Finish,
       'Day' = left(datename(dw,Start),9),
       UserName,
       'PhysicalDeviceName' = left(PhysicalDeviceName,120)
  from #Backups
 where Type = 'LOG'
order by Finish desc       
       
---------------------------------------------------------------------
-- Show backup throughput history                                  --
---------------------------------------------------------------------

print ' '
print ' '
print '== BACKUP THROUGHPUT (MB/s) == '
print ' '

select BackupDeviceType, 
       'Backups' = count(*),
       'Min' = convert(char(10),convert(decimal(10,4),min(FileSizeInBytes / DurationInSeconds / 1024.0 / 1024.0))),
       'Max' = convert(char(10),convert(decimal(10,4),max(FileSizeInBytes / DurationInSeconds / 1024.0 / 1024.0))),
       'Avg' = convert(char(10),convert(decimal(10,4),avg(FileSizeInBytes / DurationInSeconds / 1024.0 / 1024.0))),
       'Month' = convert(char(7),BackupStartDate,120)
  from 
(
select distinct
       'ServerName'	            = left(bs.server_name,30),
       'DatabaseName'           = bs.database_name,
       'UserName'               = bs.user_name,
       'BackupType'             = bs.type,
       'BackupDeviceType'       = case when (bmf.device_type in (2,102)) then 'Disk' when (bmf.device_type in (5,7,105)) then 'Tape' else '??' end,
       'FileType'               = bf.file_type,
       'BackupSetType'          = bs.type,
       'PhysicalDeviceName'     = bmf.physical_device_name,
       'TransactionLogFileName' = substring(bmf.physical_device_name, (len(bmf.physical_device_name) - charindex('\',reverse(bmf.physical_device_name)) + 2) ,500),
       'BackupStartDate'        = bs.Backup_start_date,
       'BackupFinishDate'       = bs.backup_finish_date,
       'DurationInSeconds'      = datediff(ss,bs.backup_start_date, bs.backup_finish_date),
       'PageSizeInBytes'        = isnull(bf.page_size, 8192),
       'BackedUpPageCount'      = bf.backed_up_page_count,
       'FileSizeInBytes'        = isnull(bf.page_size,8192) * isnull(bf.backed_up_page_count,0),
       'FileSizeInMB'           = cast(((isnull(bf.page_size,8192) * isnull(bf.backed_up_page_count,0)) / 1024.0 / 1024.0) as decimal(14,2))
  from msdb.dbo.backupset         bs
  join msdb.dbo.backupmediafamily bmf on bmf.media_set_id = bs.media_set_id
  join msdb.dbo.backupfile        bf  on bf.backup_set_id = bs.backup_set_id
) as vBackupHistory


 where DurationInSeconds > 10 -- Removing insignificant times
   and BackedupPageCount > 10 -- Removing insignificant sizes
 group by BackupDeviceType, convert(char(7),BackupStartDate,120)
 order by 6

 go


 
