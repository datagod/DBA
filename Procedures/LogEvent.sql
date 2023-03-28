use DBA
go
IF (object_id('LogEvent') IS NOT NULL)
BEGIN
  print 'Dropping procedure: LogEvent'
  drop procedure LogEvent
END
print 'Creating procedure: LogEvent'
GO
CREATE PROCEDURE LogEvent
(
  @Process       varchar(100)  = '',
  @DatabaseName  varchar(50)   = '',
  @Severity      tinyint       = 0,
  @Description1  varchar(7000) = '',
  @Description2  varchar(7000) = '',
  @Description3  varchar(7000) = '',
  @Description4  varchar(7000) = '',
  @Description5  varchar(7000) = '',
  @Description6  varchar(7000) = '',
  @Description7  varchar(7000) = '',
  @Description8  varchar(7000) = '',
  @Description9  varchar(7000) = '',
  @Description10 varchar(7000) = '',
  @Instructions  varchar(7000) = '',
  @Print         char(1)       = 'N' -- (Y/N) set to Y to force printing of message, regardless of connecting client
)
as
---------------------------------------------------------------------------------------------------
-- Date Created: February 19, 2008
-- Author:       William McEvoy
-- Version:      1.0
--               
-- Description:  This procedure is used to insert records into the EventLog table.
--               
-- Notes:        The Description input parameters will be concatenated.
--               Any occurrence of <date> will be replaced with the current date/time.
--               If the connecting program is "Query Analyzer" or "Management Studio", the 
--               logged messages will also be printed to the console.
--               
---------------------------------------------------------------------------------------------------
-- Version:      1.1
-- Date Revised: December 12, 2012 (end of the world??)
-- Author:       William McEvoy
-- Reason:       I added some date handling to the second parameter.
---------------------------------------------------------------------------------------------------
-- Version       1.2
-- Date Revised: August 11, 2016
-- Author:       William McEvoy
-- Reason:       Added code to display messages if called from powershell
---------------------------------------------------------------------------------------------------
-- Version:      1.3
-- Date Revised: January 29, 2023
-- Author:       William McEvoy
-- Reason:       Changed Process and DatabaseName to be optional parameters
---------------------------------------------------------------------------------------------------
-- Version:      1.4
-- Date Revised: March 27, 2023
-- Author:       William McEvoy
-- Reason:       Added Severity and Instructions optional columns
---------------------------------------------------------------------------------------------------
-- Version:      
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------
set nocount on


---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------

declare @error       int,
        @rowcount    int,
        @EventTime   datetime,
        @Description varchar(7000),
        @HostName    varchar(30),
        @UserName    varchar(30),
        @DateTime    varchar(19)


select  @error       = 0,
        @rowcount    = 0,
        @EventTime   = getdate(),
        @Description = '',
        @HostName    = HOST_NAME(),
        @UserName    = SYSTEM_USER,
        @DateTime    = convert(varchar(19),getdate(),120)


-- Fill in current database name if none supplied
IF (@DatabaseName = '' OR @DatabaseName IS NULL)
  select @DatabaseName = db_name()

if (@Process = '' or @Process IS NULL)
  select @process = program_name from master.dbo.sysprocesses with (nolock) where spid = @@SPID 
  

  


---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
-- Parse description for special options (and replace NULLS)       --
--                                                                 --
-- Write EventLog record                                           --
--                                                                 --
---------------------------------------------------------------------


---------------------------------------------------------------------
-- Parse description for special options (and replace NULLS)       --
---------------------------------------------------------------------

-- Format second description parameter as yyyy-mm-dd hh:mm:ss (if it is a date)
IF (@Description1 like '%Date: ') or (@Description1 like '%DateUTC: ') or (@Description1 like '%DateEST: ')
  select @Description2 = convert(char(19),convert(datetime,@Description2),120)

IF (@Description2 like '%Date: ') or (@Description2 like '%DateUTC: ') or (@Description2 like '%DateEST: ')
  select @Description3 = convert(char(19),convert(datetime,@Description3),120)


-- Current DateTime (yyyy-mm-dd hh:mm:ss)
select @Description = coalesce(replace(@Description1, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description2, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description3, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description4, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description5, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description6, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description7, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description8, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description9, '<datetime>', @DateTime),'NULL') + 
                      coalesce(replace(@Description10,'<datetime>', @DateTime),'NULL') 

-- Add nested formatting
select @Description = isnull(replicate('    ',@@NestLevel-2),'') + @Description


---------------------------------------------------------------------
-- Write EventLog record                                           --
---------------------------------------------------------------------

-- Some client connections are expecting a single result set.  We do not want
-- to cause those clients grief so we only send messages to the console if
-- the client is a query based application like "Query Analyzer".

IF EXISTS (select 1 from master.dbo.sysprocesses with (nolock) 
            where spid = @@SPID and (lower(program_name) like '%Management Studio%')
          ) OR (@Print <> 'N')
BEGIN
  print @Description
END

-- insert record into table
insert EventLog (EventTime,  DatabaseName,  Severity,  HostName,  UserName,  Process,  [Description], Instructions)
values          (@EventTime, @DatabaseName, @Severity, @HostName, @UserName, @Process, @Description,  @Instructions)

select @error = @@ERROR

IF (@error <> 0)
BEGIN
  raiserror ('An error occurred while writing to the EventLog table.  @@error: %d',16,1,@error)
  return -1
END
return 0
GO

IF (object_id('LogEvent') IS NOT NULL)
  print 'Procedure created'
ELSE
  print 'Procedure NOT created'
GO
