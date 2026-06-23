/*
  DatabasePerformanceAnalysis.sql
  Performance Tuning Framework

  Deploy to the tool database from which Performance Tuning Framework
  procedures are executed. Results from ExamineDatabasePerformance are stored here.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.DatabasePerformanceFinding') IS NOT NULL
BEGIN
    PRINT 'Dropping: DatabasePerformanceFinding'
    DROP TABLE dbo.DatabasePerformanceFinding
END
GO

IF OBJECT_ID('dbo.DatabasePerformanceMetric') IS NOT NULL
BEGIN
    PRINT 'Dropping: DatabasePerformanceMetric'
    DROP TABLE dbo.DatabasePerformanceMetric
END
GO

IF OBJECT_ID('dbo.DatabasePerformanceRun') IS NOT NULL
BEGIN
    PRINT 'Dropping: DatabasePerformanceRun'
    DROP TABLE dbo.DatabasePerformanceRun
END
GO

PRINT 'Creating: DatabasePerformanceRun'
GO

CREATE TABLE dbo.DatabasePerformanceRun
(
    AnalysisRunID        uniqueidentifier NOT NULL,
    CaptureDate          datetime         NOT NULL,
    ServerName           sysname          NOT NULL,
    DatabaseName         sysname          NOT NULL,
    SqlMajorVersion      tinyint          NOT NULL,
    ProductVersion       varchar(30)      NOT NULL,
    Edition              varchar(64)      NULL,
    TopN                 int              NOT NULL,
    MinFragmentationPct  decimal(5, 2)    NOT NULL,
    MinPageCount         int              NOT NULL,
    SchemaFilter         sysname          NOT NULL,
    TableFilter          sysname          NOT NULL
)
GO

ALTER TABLE dbo.DatabasePerformanceRun
    ADD CONSTRAINT PK_DatabasePerformanceRun__AnalysisRunID
    PRIMARY KEY CLUSTERED (AnalysisRunID)
GO

CREATE NONCLUSTERED INDEX IX_DatabasePerformanceRun__DatabaseName_CaptureDate
    ON dbo.DatabasePerformanceRun (DatabaseName, CaptureDate DESC)
GO

PRINT 'Creating: DatabasePerformanceMetric'
GO

CREATE TABLE dbo.DatabasePerformanceMetric
(
    DatabasePerformanceMetricID int              NOT NULL IDENTITY(1, 1),
    AnalysisRunID               uniqueidentifier NOT NULL,
    Category                    varchar(40)      NOT NULL,
    MetricName                  varchar(100)     NOT NULL,
    MetricValue                 nvarchar(4000)   NULL,
    MetricNumeric               decimal(18, 4)   NULL
)
GO

ALTER TABLE dbo.DatabasePerformanceMetric
    ADD CONSTRAINT PK_DatabasePerformanceMetric__DatabasePerformanceMetricID
    PRIMARY KEY CLUSTERED (DatabasePerformanceMetricID)
GO

CREATE NONCLUSTERED INDEX IX_DatabasePerformanceMetric__AnalysisRunID_Category
    ON dbo.DatabasePerformanceMetric (AnalysisRunID, Category, MetricName)
GO

PRINT 'Creating: DatabasePerformanceFinding'
GO

CREATE TABLE dbo.DatabasePerformanceFinding
(
    DatabasePerformanceFindingID int              NOT NULL IDENTITY(1, 1),
    AnalysisRunID                uniqueidentifier NOT NULL,
    Category                     varchar(40)      NOT NULL,
    Severity                     tinyint          NOT NULL,
    RankOrder                    int              NOT NULL,
    ObjectName                   nvarchar(500)    NULL,
    Detail                       nvarchar(max)    NULL,
    MetricNumeric                decimal(18, 4)   NULL
)
GO

ALTER TABLE dbo.DatabasePerformanceFinding
    ADD CONSTRAINT PK_DatabasePerformanceFinding__DatabasePerformanceFindingID
    PRIMARY KEY CLUSTERED (DatabasePerformanceFindingID)
GO

CREATE NONCLUSTERED INDEX IX_DatabasePerformanceFinding__AnalysisRunID_Category
    ON dbo.DatabasePerformanceFinding (AnalysisRunID, Category, RankOrder)
GO

IF OBJECT_ID('dbo.DatabasePerformanceRun') IS NOT NULL
    PRINT 'Tables created.'
ELSE
    PRINT 'Tables NOT created.'
GO