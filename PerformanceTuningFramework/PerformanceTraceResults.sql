/*
  PerformanceTraceResults.sql
  Performance Tuning Framework

  Deploy to the tool database. Stores server-side trace control metadata and
  imported trace event results.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.PerformanceTraceControl') IS NOT NULL
BEGIN
    PRINT 'Dropping: PerformanceTraceControl'
    DROP TABLE dbo.PerformanceTraceControl
END
GO

IF OBJECT_ID('dbo.PerformanceTraceResults') IS NOT NULL
BEGIN
    PRINT 'Dropping: PerformanceTraceResults'
    DROP TABLE dbo.PerformanceTraceResults
END
GO

PRINT 'Creating: PerformanceTraceControl'
GO

CREATE TABLE dbo.PerformanceTraceControl
(
    TraceControlID      int              NOT NULL IDENTITY(1, 1),
    TraceID             int              NOT NULL,
    TraceName           sysname          NOT NULL,
    TraceFilePath       nvarchar(500)    NOT NULL,
    Status              varchar(20)      NOT NULL,
    StartTime           datetime         NOT NULL,
    EndTime             datetime         NULL,
    FilterDatabaseName  sysname          NULL,
    FilterMinReads      bigint           NULL,
    FilterMinWrites     bigint           NULL,
    FilterMinDuration   bigint           NULL,
    FilterLoginName     sysname          NULL,
    FilterHostName      sysname          NULL,
    MaxFileSizeMB       int              NOT NULL,
    StartedBy           sysname          NOT NULL,
    RowsImported        int              NULL
)
GO

ALTER TABLE dbo.PerformanceTraceControl
    ADD CONSTRAINT PK_PerformanceTraceControl__TraceControlID
    PRIMARY KEY CLUSTERED (TraceControlID)
GO

CREATE UNIQUE NONCLUSTERED INDEX UX_PerformanceTraceControl__TraceID
    ON dbo.PerformanceTraceControl (TraceID)
GO

CREATE NONCLUSTERED INDEX IX_PerformanceTraceControl__Status_StartTime
    ON dbo.PerformanceTraceControl (Status, StartTime DESC)
GO

PRINT 'Creating: PerformanceTraceResults'
GO

CREATE TABLE dbo.PerformanceTraceResults
(
    PerformanceTraceResultID int              NOT NULL IDENTITY(1, 1),
    TraceControlID           int              NOT NULL,
    TraceID                  int              NOT NULL,
    EventClass               int              NULL,
    EventSubclass            int              NULL,
    DatabaseName             nvarchar(128)    NULL,
    ObjectName               nvarchar(128)    NULL,
    QueryText                nvarchar(max)    NULL,
    Reads                    bigint           NULL,
    Writes                   bigint           NULL,
    CPU                      int              NULL,
    Duration                 bigint           NULL,
    RowCounts                bigint           NULL,
    LoginName                nvarchar(128)    NULL,
    HostName                 nvarchar(128)    NULL,
    ApplicationName          nvarchar(128)    NULL,
    SPID                     int              NULL,
    StartTime                datetime         NULL,
    EndTime                  datetime         NULL,
    ImportedDate             datetime         NOT NULL
)
GO

ALTER TABLE dbo.PerformanceTraceResults
    ADD CONSTRAINT PK_PerformanceTraceResults__PerformanceTraceResultID
    PRIMARY KEY CLUSTERED (PerformanceTraceResultID)
GO

ALTER TABLE dbo.PerformanceTraceResults
    ADD CONSTRAINT FK_PerformanceTraceResults__TraceControlID
    FOREIGN KEY (TraceControlID) REFERENCES dbo.PerformanceTraceControl (TraceControlID)
GO

CREATE NONCLUSTERED INDEX IX_PerformanceTraceResults__TraceControlID
    ON dbo.PerformanceTraceResults (TraceControlID)
    INCLUDE (DatabaseName, Duration, Reads, Writes, StartTime)
GO

CREATE NONCLUSTERED INDEX IX_PerformanceTraceResults__DatabaseName_Duration
    ON dbo.PerformanceTraceResults (DatabaseName, Duration DESC)
    INCLUDE (Reads, Writes, LoginName, HostName)
GO

IF OBJECT_ID('dbo.PerformanceTraceResults') IS NOT NULL
    PRINT 'Tables created.'
ELSE
    PRINT 'Tables NOT created.'
GO