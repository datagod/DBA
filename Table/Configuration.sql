use DBA
IF (object_id('Configuration') IS NOT NULL)
BEGIN
  PRINT 'Dropping: Configuration'
  DROP Table Configuration
END
PRINT 'Creating: Configuration'
GO
go
CREATE TABLE Configuration
(
  ConfigurationID int identity,
  Name            varchar(50),
  Description     varchar(100),
  IntValue        int,
  VarcharValue    varchar(255),
  DateCreated     datetime NOT NULL,
  DateUpdated     datetime NOT NULL
)
GO
IF (object_id('Configuration') IS NOT NULL)
  PRINT 'Table created.'
ELSE
  PRINT 'Table NOT created'
GO


ALTER TABLE Configuration ADD 
  CONSTRAINT PK_Configuration__ConfigurationID PRIMARY KEY (ConfigurationID)   WITH  FILLFACTOR = 98, 
  CONSTRAINT ui_Configuration__Name           UNIQUE       (Name)              WITH  FILLFACTOR = 98

GO


/*

insert into Configuration values ('Inbox UNC','Source File input directory',NULL,'C:\SourceData\Inbox',getdate(),getdate())
insert into Configuration values ('To Be Processed UNC','Source File to be processed directory',NULL,'C:\SourceData\ToBeProcessed',getdate(),getdate())
insert into Configuration values ('Processed UNC','Source File processed directory',NULL,'C:\SourceData\Processed',getdate(),getdate())
insert into Configuration values ('Archived UNC','Directory where Source File are archived',NULL,'C:\SourceData\Archived',getdate(),getdate())
insert into Configuration values ('DatabaseVersion','Current Database Version',NULL,'1.000',getdate(),getdate())
insert into Configuration values ('UpgradeInProgress','Database Upgrade In Progress',0,'Complete',getdate(),getdate())
insert into Configuration values ('Errors UNC','Directory where errors during BulkInsert are logged',NULL,'C:\SourceData\Errors',getdate(),getdate())


-- Database Version
insert configuration (Name,             Description,                       IntValue, VarcharValue, DateCreated, DateUpdated)
              select 'DatabaseVersion', 'Current database schema version', NULL,     '1.000',      getdate(),   getdate()


-- Upgrade information
insert configuration (Name,               Description,                           IntValue, VarcharValue, DateCreated, DateUpdated)
              select 'UpgradeInProgress', 'Indicates if an upgrade is underway', 0,        NULL,        getdate(),   getdate()


*/

