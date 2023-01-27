
IF (object_id('MeasureIOLatency') IS NOT NULL)
BEGIN
  PRINT 'Dropping: MeasureIOLatency'
  DROP PROCEDURE MeasureIOLatency     
END
GO
PRINT 'Creating: MeasureIOLatency'
GO
create procedure MeasureIOLatency
(
  @Seconds int = 60  --> Number of seconds to measure IO
)
as
 
---------------------------------------------------------------------------------------------------
-- Date Created: March 2016
-- Author:       William McEvoy
--               
-- Description:  This stored procedure is used to measure latency on an database server.  Each 
--               file is analyzed twice and the final numbers displayed.  This is useful for 
--               determining hotspots.
--               
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Declare and initialize local variables and temp tables          --
---------------------------------------------------------------------

declare @delay varchar(8)

IF (object_id('tempdb..#ResultsStart') IS NOT NULL)
  drop table #ResultsStart

create table #ResultsStart
(
  DatabaseID          int,
  FileID              int,
  SecondsSinceReboot  bigint,
  Reads               bigint,
  Writes              bigint,
  BytesRead           bigint,
  BytesWritten        bigint,
  IOStallReadSeconds  bigint,
  IOStallWriteSeconds bigint,
  TotalIOStallSeconds bigint,
  FileHandle          varbinary(max)
)

IF (object_id('tempdb..#ResultsStop') IS NOT NULL)
  drop table #ResultsStop

create table #ResultsStop
(
  DatabaseID          int,
  FileID              int,
  SecondsSinceReboot  bigint,
  Reads               bigint,
  Writes              bigint,
  BytesRead           bigint,
  BytesWritten        bigint,
  IOStallReadSeconds  bigint,
  IOStallWriteSeconds bigint,
  TotalIOStallSeconds bigint,
  FileHandle          varbinary(max)
)


 
---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
--  Capture I/O statistics from system view                        --
--                                                                 --
---------------------------------------------------------------------


---------------------------------------------------------------------
--  Capture I/O statistics from system view                        --
---------------------------------------------------------------------

-- convert to HH:MM:SS format
select @delay =  convert(varchar(8),dateadd(s,@seconds,0),114)

-- Capture initial baseline
insert into #ResultsStart
     (
       DatabaseID,
       FileID,
       SecondsSinceReboot,
       Reads,
       Writes,
       BytesRead,
       BytesWritten,
       IOStallReadSeconds,
       IOStallWriteSeconds,
       TotalIOStallSeconds,
       FileHandle
     )
select database_id,
       file_id,
       sample_ms / 1000,
       num_of_reads,
       num_of_writes,
       num_of_bytes_read,
       num_of_bytes_written,
       io_stall_read_ms / 1000,
       io_stall_write_ms / 1000,
       io_stall / 1000,
       file_handle
  from sys.dm_io_virtual_file_stats (NULL,NULL)

waitfor delay @seconds


insert into #ResultsStop
     (
       DatabaseID,
       FileID,
       SecondsSinceReboot,
       Reads,
       Writes,
       BytesRead,
       BytesWritten,
       IOStallReadSeconds,
       IOStallWriteSeconds,
       TotalIOStallSeconds,
       FileHandle
     )
select database_id,
       file_id,
       sample_ms / 1000,
       num_of_reads,
       num_of_writes,
       num_of_bytes_read,
       num_of_bytes_written,
       io_stall_read_ms / 1000,
       io_stall_write_ms / 1000,
       io_stall / 1000,
       file_handle
  from sys.dm_io_virtual_file_stats (NULL,NULL)


---------------------------------------------------------------------
--  Produce Reports                                                --
---------------------------------------------------------------------


select left(db_name(a.DatabaseID),50) as 'DatabaseName',
       left(mf.type_desc,10) as FileType,
       Reads,
       Writes,
       BytesRead,
       BytesWritten,
       IOStallReadSeconds,
       IOStallWriteSeconds,
       TotalIOStallSeconds,
       left(mf.physical_name,100) as 'FileName'
  from #ResultsStart a
  join sys.master_files mf on mf.database_id = a.DatabaseID
                           and mf.file_id    = a.FileID


-- Averages
select left(db_name(a.DatabaseID),50)                as 'DatabaseName',
       left(mf.type_desc,10)                         as FileType,
       b.Reads - a.Reads                             as 'ReadsDuringTest',
       b.Writes - a.Writes                           as 'WritesDuringTest',
       b.BytesRead - a.BytesRead                     as 'BytesReadDuringTest',
       b.BytesWritten - a.BytesWritten               as 'BytesWrittenDuringTest',
       b.IOStallReadSeconds  - a.IOStallReadSeconds  as 'IOStallReadSecondsDuringTest',
       b.IOStallWriteSeconds - a.IOStallWriteSeconds as 'IOStallWriteSecondsDuringTest',
       b.TotalIOStallSeconds - a.TotalIOStallSeconds as 'TotalIOStallSecondsDuringTest',
       left(mf.physical_name,100) as 'FileName'
  from #ResultsStart a
  join #ResultsStop  b on b.FileHandle = a.FileHandle
  join sys.master_files mf on mf.database_id = a.DatabaseID
                           and mf.file_id    = a.FileID



GO



