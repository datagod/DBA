/*
  QueryStoreAnalysis.sql
  Performance Tuning Framework

  Deploy to the tool database from which Performance Tuning Framework
  procedures are executed. Results from ShowQueryStoreReport are stored here.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.QueryStoreAnalysis') IS NOT NULL
BEGIN
    PRINT 'Dropping: QueryStoreAnalysis'
    DROP TABLE dbo.QueryStoreAnalysis
END
GO

PRINT 'Creating: QueryStoreAnalysis'
GO

CREATE TABLE dbo.QueryStoreAnalysis
(
    QueryStoreAnalysisID  int              NOT NULL IDENTITY(1, 1),
    AnalysisRunID         uniqueidentifier NOT NULL,
    CaptureDate           datetime         NOT NULL,
    ServerName            sysname          NOT NULL,
    DatabaseName          sysname          NOT NULL,
    ActualState           nvarchar(60)     NOT NULL,
    DesiredState          nvarchar(60)     NOT NULL,
    CurrentStorageSizeMB  decimal(12, 2)   NOT NULL,
    MaxStorageSizeMB      decimal(12, 2)   NOT NULL,
    QueryID               bigint           NOT NULL,
    QueryText             nvarchar(max)    NOT NULL,
    PlanCount             int              NOT NULL,
    IsForcedPlan          bit              NOT NULL,
    Executions            bigint           NOT NULL,
    AvgDurationUs         bigint           NOT NULL,
    AvgCpuUs              bigint           NOT NULL,
    AvgLogicalReads       bigint           NOT NULL,
    TotalDurationUs       bigint           NOT NULL,
    LastExecutionTime     datetime         NULL,
    SortBy                varchar(10)      NOT NULL,
    TopN                  int              NOT NULL,
    MinExecutions         bigint           NOT NULL
)
GO

ALTER TABLE dbo.QueryStoreAnalysis
    ADD CONSTRAINT PK_QueryStoreAnalysis__QueryStoreAnalysisID
    PRIMARY KEY CLUSTERED (QueryStoreAnalysisID)
GO

CREATE NONCLUSTERED INDEX IX_QueryStoreAnalysis__AnalysisRunID
    ON dbo.QueryStoreAnalysis (AnalysisRunID)
GO

CREATE NONCLUSTERED INDEX IX_QueryStoreAnalysis__DatabaseName_CaptureDate
    ON dbo.QueryStoreAnalysis (DatabaseName, CaptureDate DESC)
    INCLUDE (QueryID, Executions, AvgDurationUs, AvgCpuUs, AvgLogicalReads)
GO

IF OBJECT_ID('dbo.QueryStoreAnalysis') IS NOT NULL
    PRINT 'Table created.'
ELSE
    PRINT 'Table NOT created.'
GO