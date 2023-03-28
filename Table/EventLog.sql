IF (object_id('EventLog') IS NOT NULL)
BEGIN
  print 'Dropping Table: EventLog'
  drop table EventLog2
END
print 'Creating Table: EventLog'

create table EventLog2
(
  EventLogID   int identity,
  EventTime    datetime,
  Severity     tinyint NULL default 0,
  DatabaseName varchar(50) NULL,
  HostName     varchar(30) NULL,
  UserName     varchar(30) NULL,
  Process      varchar(50) NULL,
  Parameters   varchar(100) NULL,
  Description  varchar(7000) NULL,
  Instructions varchar(7000) NULL

)
--with (data_compression = page)
go
IF (object_id('EventLog') IS NOT NULL)
  print 'Table created.'
ELSE
  print 'Table NOT created.' 


ALTER TABLE dbo.EventLog 
  ADD CONSTRAINT PK_EventLog PRIMARY KEY NONCLUSTERED (EventLogID) WITH  FILLFACTOR = 99
CREATE CLUSTERED INDEX [i_EventLog__EventTime]ON EventLog(EventTime) WITH FILLFACTOR = 99 ON [PRIMARY]


