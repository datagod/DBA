use dba
go
alter procedure ShowBackups
(
  @days int = 1,
  @dbname varchar(50) = '%',
  @ShowSchedules char(1) = 'N',
  @ShowDetails   char(1) = 'Y',
  @ShowPath      char(1) = 'N',  
  @WikiFormat    char(1) = 'N'

)  
as



-- Note: If the backups span midnight, the HH:MM:SS field might be incorrect

/*
declare @days   smallint, 
        @dbname sysname
select  @days   = 1,  --> number of days to include in the report
        @dbname = '%' --> specifies which database name, defaults to all
*/


---------------------------------------------------------------------------------------------------
-- Date Created: February 10, 2014
-- Author:       Bill McEvoy
-- Description:  This procedure generates a report which details the backup history for the
--               specified database (defaults to all) for the specified number of days in the
--               past.
--               
---------------------------------------------------------------------------------------------------
-- Date Modified: September 9, 2020
-- Reason:        Added backup compression information
--               
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------

declare @BackupPath varchar(1000)

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




---------------------------------------------------------------------
-- Get backup directory                                            --
---------------------------------------------------------------------

EXEC master.dbo.xp_instance_regread
            N'HKEY_LOCAL_MACHINE',
            N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory',
            @BackupPath OUTPUT, 
            'no_output'

IF (@ShowPath = 'Y')
BEGIN
  select @BackupPath  as 'BackupPath'
END


IF (@ShowSchedules = 'Y')
BEGIN

	---------------------------------------------------------------------
	-- Show Backup Schedules                                           --
	---------------------------------------------------------------------

	select '|Project|Environment|Server|JobName|ScheduleName|Enabled|Frequency|Interval|time|'
	union 
	select '|-------|-----------|------|-------|------------|-------|---------|--------|----|'


	 select   '|' +  'CDW' + '|', 
			 'PROD' + '|',
			 'Server'       = + left(@@ServerName,30) + '|', 
			 'JobName'      = +left(S.name,55)+ '|' ,
			 'ScheduleName' = +left(ss.name,55)+ '|' ,
			 'Enabled'      = case (S.enabled)
								when 0 then 'No'+ '|' 
								when 1 then 'Yes'+ '|' 
								else '??'+ '|' 
							  end,
			 'Frequency' = case(ss.freq_type)
							 when 1 then 'Once'+ '|' 
							 when 4  then 'Daily'+ '|' 
							 when 8  then (case when (ss.freq_recurrence_factor >1) then 'Every ' + convert(varchar(3),ss.freq_recurrence_factor) + ' Weeks'  else 'Weekly' end)+ '|' 
                			 when 16 then (case when (ss.freq_recurrence_factor >1) then 'Every ' + convert(varchar(3),ss.freq_recurrence_factor) + ' Months' else 'Monthly' end)+ '|' 
							 when 32 then 'Every ' + convert(varchar(3),ss.freq_recurrence_factor) + 'Months' + '|' -- Relative
                			 when 64 then 'SQL Startup'+ '|' 
                			 when 128 then 'SQL Idle'+ '|' 
                			 else '??'+ '|' 
						   end,
			 'Interval'  = case 
							 when (freq_type = 1) then 'One time only'+ '|' 
							 when (freq_type = 4 and freq_interval = 1) then 'Every Day'+ '|' 
							 when (freq_type = 4 and freq_interval > 1) then 'Every ' + convert(varchar(10), freq_interval) + ' Days'+ '|' 
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
															where schedule_id = sj.schedule_id) + '|' 
							 when (freq_type = 16) then 'Day ' + convert(varchar(2), freq_interval) + '|' 
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
															where WS.schedule_id = ss.schedule_id) + '|' 
								end,

			 'Time' = case(freq_subday_type)
						when 1 then left(stuff((stuff((replicate('0',6-len(active_start_time)))+convert(varchar(6),active_start_time),3,0,':')),6,0,':'),8) 
						when 2 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' seconds'
						when 4 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' minutes'
						when 8 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' hours'
						else '??'
					  end + '|',
             'BackupPath' = @BackupPath + '|'
		from msdb.dbo.sysjobschedules SJ
		right join msdb.dbo.sysjobs         S   on S.job_id       = SJ.job_id
		left  join msdb.dbo.sysschedules    SS  on SS.schedule_id = sj.schedule_id
		left  join master..syslogins        sl  on sl.sid    = S.owner_sid
	   where S.Name like '%Backup%' -- jobname
		  or SS.Name like '%Backup%' -- schedulename

	   order by s.name
END




IF (@ShowDetails = 'Y')
BEGIN

	print ' '
	print ' '
	print '===================='
	print '== Backup History =='
	print '===================='
	print ' '
	print 'Backups since: ' + convert(char(19),getdate() -@days,120)

	---------------------------------------------------------------------
	-- Populate work tables                                            --
	---------------------------------------------------------------------

	IF (object_id('tempdb..#Backups') IS NOT NULL)
	  DROP TABLE #Backups

	select 'Server'   = left(ServerName,25),
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
		   'ServerName'	            = left(bs.server_name,25),
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
		   'FileSizeInMB'           = cast((isnull(bf.backup_size,0) / 1024.0 / 1024.0) as decimal(14,2))
       
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
	---------------------------------------------------------------------

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
		   'ServerName'	            = left(bs.server_name,25),
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
		   'FileSizeInBytes'        = bf.file_size,
		   'FileSizeInMB'           = cast((bf.file_size / 1024.0 / 1024.0) as decimal(14,2))
	  from msdb.dbo.backupset         bs
	  join msdb.dbo.backupmediafamily bmf on bmf.media_set_id = bs.media_set_id
	  join msdb.dbo.backupfile        bf  on bf.backup_set_id = bs.backup_set_id
	) as vBackupHistory


	 where DurationInSeconds > 10 -- Removing insignificant times
	   and BackedupPageCount > 10 -- Removing insignificant sizes
	 group by BackupDeviceType, convert(char(7),BackupStartDate,120)
	 order by 6
END


go

ShowBackups @ShowSchedules = 'N', @ShowPath = 'Y',@ShowDetails = 'N'
