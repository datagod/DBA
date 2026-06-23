/*
  IndexAnalysis.sql
  Performance Tuning Framework

  Deploy to the tool database from which Performance Tuning Framework
  procedures are executed. Results from AnalyzeIndexes are stored here.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.IndexAnalysis') IS NOT NULL
BEGIN
    PRINT 'Dropping: IndexAnalysis'
    DROP TABLE dbo.IndexAnalysis
END
GO

PRINT 'Creating: IndexAnalysis'
GO

CREATE TABLE dbo.IndexAnalysis
(
    IndexAnalysisID   int              NOT NULL IDENTITY(1, 1),
    AnalysisRunID     uniqueidentifier NOT NULL,
    CaptureDate       datetime         NOT NULL,
    ServerName        sysname          NOT NULL,
    DatabaseName      sysname          NOT NULL,
    SchemaName        sysname          NOT NULL,
    TableName         sysname          NOT NULL,
    IndexName         sysname          NULL,
    ObjectID          int              NOT NULL,
    IndexID           int              NOT NULL,
    IndexTypeDesc     nvarchar(60)     NOT NULL,
    UserSeeks         bigint           NOT NULL,
    UserScans         bigint           NOT NULL,
    UserLookups       bigint           NOT NULL,
    UserUpdates       bigint           NOT NULL,
    TotalReads        bigint           NOT NULL,
    ReadWriteRatio    decimal(18, 4)   NULL,
    RecordCount       bigint           NOT NULL,
    SizeMB            decimal(12, 1)   NOT NULL,
    LastUserSeek      datetime         NULL,
    LastUserScan      datetime         NULL,
    LastUserLookup    datetime         NULL,
    LastUserUpdate    datetime         NULL,
    IsDisabled        bit              NOT NULL,
    HasUsageStats     bit              NOT NULL,
    IsFiltered        bit              NOT NULL,
    IsUnique          bit              NOT NULL,
    IsPrimaryKey      bit              NOT NULL,
    FillFactor        tinyint          NULL,
    KeyColumns        nvarchar(2000)   NULL,
    IncludedColumns   nvarchar(2000)   NULL,
    FilterDefinition  nvarchar(max)    NULL,
    CompressionDesc   nvarchar(60)     NULL,
    FilterSchema      sysname          NOT NULL,
    FilterTable       sysname          NOT NULL,
    SortBy            varchar(10)      NOT NULL
)
GO

ALTER TABLE dbo.IndexAnalysis
    ADD CONSTRAINT PK_IndexAnalysis__IndexAnalysisID
    PRIMARY KEY CLUSTERED (IndexAnalysisID)
GO

CREATE NONCLUSTERED INDEX IX_IndexAnalysis__AnalysisRunID
    ON dbo.IndexAnalysis (AnalysisRunID)
GO

CREATE NONCLUSTERED INDEX IX_IndexAnalysis__DatabaseName_CaptureDate
    ON dbo.IndexAnalysis (DatabaseName, CaptureDate DESC)
    INCLUDE (SchemaName, TableName, IndexName, TotalReads, UserUpdates, RecordCount)
GO

IF OBJECT_ID('dbo.IndexAnalysis') IS NOT NULL
    PRINT 'Table created.'
ELSE
    PRINT 'Table NOT created.'
GO