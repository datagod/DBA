
/*
  ExamineDatabasePerformance.sql
  Performance Tuning Framework

  Deploy to the tool database, create DatabasePerformanceAnalysis tables first, then execute:
    EXEC dbo.ExamineDatabasePerformance @TargetDatabase = N'YourDatabase'

  Capture two databases and compare stored metrics/findings by AnalysisRunID.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.ExamineDatabasePerformance
(
    @TargetDatabase        sysname           = NULL,
    @SchemaFilter          sysname           = '%',
    @TableFilter           sysname           = '%',
    @TopN                  int               = 25,
    @MinFragmentationPct   decimal(5, 2)     = 10.0,
    @MinPageCount          int               = 1000,
    @PersistResults        bit               = 1,
    @ReturnResultSets      bit               = 1,
    @AnalysisRunID         uniqueidentifier  = NULL OUTPUT
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 23, 2026
-- Author:       Bill McEvoy
-- Description:  Captures database and instance performance diagnostics from DMVs for a target
--               database. Designed to compare two "identical" databases and explain runtime gaps.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion         tinyint,
    @ProductVersion       varchar(30),
    @Edition              varchar(64),
    @ServerName           sysname,
    @CaptureDate          datetime,
    @TargetDatabaseId     int,
    @QuotedDatabase       nvarchar(260),
    @Sql                  nvarchar(max),
    @VLFCount             int,
    @MetricCount          int,
    @FindingCount         int,
    @FragmentedCount      int,
    @MissingIndexCount    int,
    @UnusedIndexCount     int,
    @StaleStatsCount      int,
    @BlockingCount        int,
    @OpenTranCount        int

IF @TargetDatabase IS NULL
    SET @TargetDatabase = DB_NAME()

SET @TargetDatabaseId = DB_ID(@TargetDatabase)
SET @QuotedDatabase   = QUOTENAME(@TargetDatabase)

IF @TargetDatabaseId IS NULL
BEGIN
    RAISERROR('Target database ''%s'' does not exist on this server.', 16, 1, @TargetDatabase)
    RETURN
END

IF @PersistResults = 1
   AND OBJECT_ID('dbo.DatabasePerformanceRun') IS NULL
BEGIN
    RAISERROR('Tables dbo.DatabasePerformanceRun/Metric/Finding do not exist. Run DatabasePerformanceAnalysis.sql first.', 16, 1)
    RETURN
END

IF @TopN < 1
    SET @TopN = 25

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @Edition        = CAST(SERVERPROPERTY('Edition') AS varchar(64))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @AnalysisRunID  = NEWID()
SET @CaptureDate    = GETDATE()

IF OBJECT_ID('tempdb..#Metrics') IS NOT NULL
    DROP TABLE #Metrics

CREATE TABLE #Metrics
(
    Category      varchar(40)    NOT NULL,
    MetricName    varchar(100)   NOT NULL,
    MetricValue   nvarchar(4000) NULL,
    MetricNumeric decimal(18, 4) NULL
)

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL
    DROP TABLE #Findings

CREATE TABLE #Findings
(
    Category      varchar(40)    NOT NULL,
    Severity      tinyint        NOT NULL,
    RankOrder     int            NOT NULL,
    ObjectName    nvarchar(500)  NULL,
    Detail        nvarchar(max)  NULL,
    MetricNumeric decimal(18, 4) NULL
)

---------------------------------------------------------------------------------------------------
-- SERVER / INSTANCE METRICS
---------------------------------------------------------------------------------------------------
INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
SELECT 'SERVER', 'MachineName', CAST(SERVERPROPERTY('MachineName') AS nvarchar(4000)), NULL
UNION ALL
SELECT 'SERVER', 'InstanceName', CAST(ISNULL(SERVERPROPERTY('InstanceName'), '(default)') AS nvarchar(4000)), NULL
UNION ALL
SELECT 'SERVER', 'ServerName', @ServerName, NULL
UNION ALL
SELECT 'SERVER', 'ProductVersion', @ProductVersion, NULL
UNION ALL
SELECT 'SERVER', 'ProductLevel', CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(4000)), NULL
UNION ALL
SELECT 'SERVER', 'ProductUpdateLevel', CAST(ISNULL(SERVERPROPERTY('ProductUpdateLevel'), '') AS nvarchar(4000)), NULL
UNION ALL
SELECT 'SERVER', 'Edition', @Edition, NULL
UNION ALL
SELECT 'SERVER', 'EngineEdition', CAST(SERVERPROPERTY('EngineEdition') AS nvarchar(4000)), CAST(SERVERPROPERTY('EngineEdition') AS decimal(18, 4))
UNION ALL
SELECT 'SERVER', 'IsClustered', CAST(ISNULL(SERVERPROPERTY('IsClustered'), 0) AS nvarchar(4000)), CAST(ISNULL(SERVERPROPERTY('IsClustered'), 0) AS decimal(18, 4))
UNION ALL
SELECT 'SERVER', 'IsHadrEnabled', CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS nvarchar(4000)), CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS decimal(18, 4))

INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
SELECT 'SERVER', 'CPU_Count', CAST(osi.cpu_count AS nvarchar(20)), osi.cpu_count
  FROM sys.dm_os_sys_info AS osi
UNION ALL
SELECT 'SERVER', 'Scheduler_Count', CAST(COUNT(*) AS nvarchar(20)), COUNT(*)
  FROM sys.dm_os_schedulers
 WHERE is_online = 1
UNION ALL
SELECT 'SERVER', 'MaxWorkerThreads', CAST(c.max_worker_count AS nvarchar(20)), c.max_worker_count
  FROM sys.configurations AS c
 WHERE c.name = 'max worker threads'
UNION ALL
SELECT 'SERVER', 'MaxDegreeOfParallelism', CAST(c.value_in_use AS nvarchar(20)), c.value_in_use
  FROM sys.configurations AS c
 WHERE c.name = 'max degree of parallelism'
UNION ALL
SELECT 'SERVER', 'CostThresholdForParallelism', CAST(c.value_in_use AS nvarchar(20)), c.value_in_use
  FROM sys.configurations AS c
 WHERE c.name = 'cost threshold for parallelism'
UNION ALL
SELECT 'SERVER', 'OptimizeForAdHocWorkloads', CAST(c.value_in_use AS nvarchar(20)), c.value_in_use
  FROM sys.configurations AS c
 WHERE c.name = 'optimize for ad hoc workloads'
UNION ALL
SELECT 'SERVER', 'BackupCompressionDefault', CAST(c.value_in_use AS nvarchar(20)), c.value_in_use
  FROM sys.configurations AS c
 WHERE c.name = 'backup compression default'
UNION ALL
SELECT 'SERVER', 'SqlServerStartTime', CONVERT(nvarchar(19), osi.sqlserver_start_time, 120), NULL
  FROM sys.dm_os_sys_info AS osi

IF @MajorVersion >= 11
BEGIN
    INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
    SELECT 'SERVER', 'PhysicalMemoryMB', CAST(osi.physical_memory_kb / 1024 AS nvarchar(20)), osi.physical_memory_kb / 1024.0
      FROM sys.dm_os_sys_info AS osi
    UNION ALL
    SELECT 'SERVER', 'CommittedMemoryMB', CAST(osi.committed_kb / 1024 AS nvarchar(20)), osi.committed_kb / 1024.0
      FROM sys.dm_os_sys_info AS osi
    UNION ALL
    SELECT 'SERVER', 'CommittedTargetMemoryMB', CAST(osi.committed_target_kb / 1024 AS nvarchar(20)), osi.committed_target_kb / 1024.0
      FROM sys.dm_os_sys_info AS osi
END

IF @MajorVersion >= 13
BEGIN
    INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
    SELECT 'SERVER', 'SocketCount', CAST(osi.socket_count AS nvarchar(20)), osi.socket_count
      FROM sys.dm_os_sys_info AS osi
    UNION ALL
    SELECT 'SERVER', 'CoresPerSocket', CAST(osi.cores_per_socket AS nvarchar(20)), osi.cores_per_socket
      FROM sys.dm_os_sys_info AS osi
END

INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
SELECT 'SERVER', 'PageLifeExpectancySec', CAST(cntr_value AS nvarchar(20)), cntr_value
  FROM sys.dm_os_performance_counters
 WHERE object_name LIKE '%Buffer Manager%'
   AND counter_name = 'Page life expectancy'
UNION ALL
SELECT 'SERVER', 'BufferCacheHitRatioPct',
       CAST(CAST(ratio * 100.0 / NULLIF(base_cnt, 0) AS decimal(18, 2)) AS nvarchar(20)),
       CAST(ratio * 100.0 / NULLIF(base_cnt, 0) AS decimal(18, 4))
  FROM (
      SELECT
          ratio = MAX(CASE WHEN counter_name = 'Buffer cache hit ratio' THEN cntr_value END),
          base_cnt = MAX(CASE WHEN counter_name = 'Buffer cache hit ratio base' THEN cntr_value END)
        FROM sys.dm_os_performance_counters
       WHERE object_name LIKE '%Buffer Manager%'
         AND counter_name IN ('Buffer cache hit ratio', 'Buffer cache hit ratio base')
  ) AS b
UNION ALL
SELECT 'SERVER', 'PendingMemoryGrants', CAST(COUNT(*) AS nvarchar(20)), COUNT(*)
  FROM sys.dm_exec_query_memory_grants
 WHERE grant_time IS NULL

---------------------------------------------------------------------------------------------------
-- DATABASE CONFIGURATION
---------------------------------------------------------------------------------------------------
SET @Sql = N'
INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
SELECT ''DATABASE'', ''DatabaseName'', @TargetDatabase, NULL
UNION ALL
SELECT ''DATABASE'', ''StateDesc'', d.state_desc, NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''UserAccessDesc'', d.user_access_desc, NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''RecoveryModel'', d.recovery_model_desc, NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''CompatibilityLevel'', CAST(d.compatibility_level AS nvarchar(20)), d.compatibility_level
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''CollationName'', CAST(d.collation_name AS nvarchar(4000)), NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''PageVerifyOption'', d.page_verify_option_desc, NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''IsAutoCloseOn'', CAST(d.is_auto_close_on AS nvarchar(20)), d.is_auto_close_on
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''IsAutoShrinkOn'', CAST(d.is_auto_shrink_on AS nvarchar(20)), d.is_auto_shrink_on
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''IsAutoCreateStatsOn'', CAST(d.is_auto_create_stats_on AS nvarchar(20)), d.is_auto_create_stats_on
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''IsAutoUpdateStatsOn'', CAST(d.is_auto_update_stats_on AS nvarchar(20)), d.is_auto_update_stats_on
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''IsAutoUpdateStatsAsyncOn'', CAST(d.is_auto_update_stats_async_on AS nvarchar(20)), d.is_auto_update_stats_async_on
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''IsReadCommittedSnapshotOn'', CAST(d.is_read_committed_snapshot_on AS nvarchar(20)), d.is_read_committed_snapshot_on
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''SnapshotIsolationState'', d.snapshot_isolation_state_desc, NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''LogReuseWaitDesc'', d.log_reuse_wait_desc, NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''CreateDate'', CONVERT(nvarchar(19), d.create_date, 120), NULL
  FROM sys.databases AS d
 WHERE d.database_id = @TargetDatabaseId
UNION ALL
SELECT ''DATABASE'', ''LastGoodCheckDbTime'',
       CONVERT(nvarchar(19), DATABASEPROPERTYEX(@TargetDatabase, ''LastGoodCheckDbTime''), 120), NULL'

IF @MajorVersion >= 13
    SET @Sql = @Sql + N'
UNION ALL
SELECT ''DATABASE'', ''QueryStoreStateDesc'', qso.actual_state_desc, NULL
  FROM ' + @QuotedDatabase + N'.sys.database_query_store_options AS qso
UNION ALL
SELECT ''DATABASE'', ''QueryStoreDesiredStateDesc'', qso.desired_state_desc, NULL
  FROM ' + @QuotedDatabase + N'.sys.database_query_store_options AS qso
UNION ALL
SELECT ''DATABASE'', ''QueryStoreMaxStorageMB'', CAST(qso.max_storage_size_mb AS nvarchar(20)), qso.max_storage_size_mb
  FROM ' + @QuotedDatabase + N'.sys.database_query_store_options AS qso
UNION ALL
SELECT ''DATABASE'', ''QueryStoreStaleQueryThresholdDays'', CAST(qso.stale_query_threshold_days AS nvarchar(20)), qso.stale_query_threshold_days
  FROM ' + @QuotedDatabase + N'.sys.database_query_store_options AS qso'

SET @Sql = @Sql + N'
UNION ALL
SELECT ''DATABASE'', ''DataFileCount'', CAST(COUNT(*) AS nvarchar(20)), COUNT(*)
  FROM ' + @QuotedDatabase + N'.sys.database_files AS df
 WHERE df.type_desc = ''ROWS''
UNION ALL
SELECT ''DATABASE'', ''LogFileCount'', CAST(COUNT(*) AS nvarchar(20)), COUNT(*)
  FROM ' + @QuotedDatabase + N'.sys.database_files AS df
 WHERE df.type_desc = ''LOG''
UNION ALL
SELECT ''DATABASE'', ''DataSizeMB'', CAST(SUM(df.size) * 8.0 / 1024 AS nvarchar(20)), SUM(df.size) * 8.0 / 1024
  FROM ' + @QuotedDatabase + N'.sys.database_files AS df
 WHERE df.type_desc = ''ROWS''
UNION ALL
SELECT ''DATABASE'', ''LogSizeMB'', CAST(SUM(df.size) * 8.0 / 1024 AS nvarchar(20)), SUM(df.size) * 8.0 / 1024
  FROM ' + @QuotedDatabase + N'.sys.database_files AS df
 WHERE df.type_desc = ''LOG''
UNION ALL
SELECT ''DATABASE'', ''UserTableCount'', CAST(COUNT(*) AS nvarchar(20)), COUNT(*)
  FROM ' + @QuotedDatabase + N'.sys.tables AS t
 WHERE t.is_ms_shipped = 0
UNION ALL
SELECT ''DATABASE'', ''IndexCount'', CAST(COUNT(*) AS nvarchar(20)), COUNT(*)
  FROM ' + @QuotedDatabase + N'.sys.indexes AS i
 WHERE i.index_id > 0
UNION ALL
SELECT ''DATABASE'', ''DisabledIndexCount'', CAST(SUM(CASE WHEN i.is_disabled = 1 THEN 1 ELSE 0 END) AS nvarchar(20)),
       SUM(CASE WHEN i.is_disabled = 1 THEN 1 ELSE 0 END)
  FROM ' + @QuotedDatabase + N'.sys.indexes AS i
 WHERE i.index_id > 0'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabase sysname, @TargetDatabaseId int',
    @TargetDatabase = @TargetDatabase,
    @TargetDatabaseId = @TargetDatabaseId

---------------------------------------------------------------------------------------------------
-- DATABASE FILE I/O
---------------------------------------------------------------------------------------------------
INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT
    Category = 'FILE_IO',
    Severity = CASE
                   WHEN x.AvgReadLatencyMs >= 50 OR x.AvgWriteLatencyMs >= 50 THEN 3
                   WHEN x.AvgReadLatencyMs >= 20 OR x.AvgWriteLatencyMs >= 20 THEN 2
                   ELSE 1
               END,
    RankOrder = ROW_NUMBER() OVER (ORDER BY x.TotalIOStallMs DESC),
    ObjectName = @TargetDatabase + N':' + mf.name,
    Detail = N'Type=' + mf.type_desc
           + N' Path=' + LEFT(mf.physical_name, 200)
           + N' Reads=' + CAST(x.num_of_reads AS nvarchar(20))
           + N' Writes=' + CAST(x.num_of_writes AS nvarchar(20))
           + N' AvgReadMs=' + CAST(ISNULL(x.AvgReadLatencyMs, 0) AS nvarchar(20))
           + N' AvgWriteMs=' + CAST(ISNULL(x.AvgWriteLatencyMs, 0) AS nvarchar(20))
           + N' TotalStallMs=' + CAST(x.TotalIOStallMs AS nvarchar(20)),
    MetricNumeric = x.TotalIOStallMs
  FROM (
      SELECT
          vfs.file_id,
          vfs.num_of_reads,
          vfs.num_of_writes,
          AvgReadLatencyMs = CAST(vfs.io_stall_read_ms * 1.0 / NULLIF(vfs.num_of_reads, 0) AS decimal(18, 4)),
          AvgWriteLatencyMs = CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(18, 4)),
          TotalIOStallMs = CAST(vfs.io_stall AS decimal(18, 4))
        FROM sys.dm_io_virtual_file_stats(@TargetDatabaseId, NULL) AS vfs
  ) AS x
 INNER JOIN sys.master_files AS mf
    ON mf.database_id = @TargetDatabaseId
   AND mf.file_id = x.file_id

---------------------------------------------------------------------------------------------------
-- INDEX FRAGMENTATION
---------------------------------------------------------------------------------------------------
SET @Sql = N'
INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT TOP (@TopN)
    Category = ''FRAGMENTATION'',
    Severity = CASE
                   WHEN ips.avg_fragmentation_in_percent >= 30 THEN 3
                   WHEN ips.avg_fragmentation_in_percent >= @MinFragmentationPct THEN 2
                   ELSE 1
               END,
    RankOrder = ROW_NUMBER() OVER (ORDER BY ips.avg_fragmentation_in_percent DESC, ips.page_count DESC),
    ObjectName = s.name + ''.'' + o.name + CASE WHEN ips.index_id = 0 THEN '' [HEAP]'' ELSE '' ['' + i.name + '']'' END,
    Detail = N''Type='' + ips.index_type_desc
           + N'' FragPct='' + CAST(CAST(ips.avg_fragmentation_in_percent AS decimal(12, 2)) AS nvarchar(20))
           + N'' Pages='' + CAST(ips.page_count AS nvarchar(20))
           + N'' Records='' + CAST(ips.record_count AS nvarchar(20))
           + N'' Fragments='' + CAST(ips.fragment_count AS nvarchar(20)),
    MetricNumeric = CAST(ips.avg_fragmentation_in_percent AS decimal(18, 4))
  FROM ' + @QuotedDatabase + N'.sys.dm_db_index_physical_stats(@TargetDatabaseId, NULL, NULL, NULL, ''LIMITED'') AS ips
 INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
    ON o.object_id = ips.object_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.indexes AS i
    ON i.object_id = ips.object_id
   AND i.index_id = ips.index_id
 WHERE o.type = ''U''
   AND s.name LIKE @SchemaFilter
   AND o.name LIKE @TableFilter
   AND ips.page_count >= @MinPageCount
   AND ips.avg_fragmentation_in_percent >= @MinFragmentationPct
   AND ips.index_id > 0
 ORDER BY ips.avg_fragmentation_in_percent DESC, ips.page_count DESC'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int, @SchemaFilter sysname, @TableFilter sysname,
      @MinFragmentationPct decimal(5,2), @MinPageCount int, @TopN int',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @MinFragmentationPct = @MinFragmentationPct,
    @MinPageCount = @MinPageCount,
    @TopN = @TopN

SET @Sql = N'
SELECT @FragmentedCount = COUNT(*)
  FROM ' + @QuotedDatabase + N'.sys.dm_db_index_physical_stats(@TargetDatabaseId, NULL, NULL, NULL, ''LIMITED'') AS ips
 INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
    ON o.object_id = ips.object_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
 WHERE o.type = ''U''
   AND s.name LIKE @SchemaFilter
   AND o.name LIKE @TableFilter
   AND ips.page_count >= @MinPageCount
   AND ips.avg_fragmentation_in_percent >= @MinFragmentationPct
   AND ips.index_id > 0'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int, @SchemaFilter sysname, @TableFilter sysname,
      @MinFragmentationPct decimal(5,2), @MinPageCount int, @FragmentedCount int OUTPUT',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @MinFragmentationPct = @MinFragmentationPct,
    @MinPageCount = @MinPageCount,
    @FragmentedCount = @FragmentedCount OUTPUT

SET @FragmentedCount = ISNULL(@FragmentedCount, 0)

---------------------------------------------------------------------------------------------------
-- MISSING INDEXES
---------------------------------------------------------------------------------------------------
SET @Sql = N'
INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT TOP (@TopN)
    Category = ''MISSING_INDEX'',
    Severity = CASE
                   WHEN ImpactScore >= 1000000 THEN 3
                   WHEN ImpactScore >= 100000 THEN 2
                   ELSE 1
               END,
    RankOrder = ROW_NUMBER() OVER (ORDER BY ImpactScore DESC),
    ObjectName = mid.statement,
    Detail = N''Equality='' + ISNULL(mid.equality_columns, '''')
           + N'' Inequality='' + ISNULL(mid.inequality_columns, '''')
           + N'' Include='' + ISNULL(mid.included_columns, '''')
           + N'' Seeks='' + CAST(migs.user_seeks AS nvarchar(20))
           + N'' Scans='' + CAST(migs.user_scans AS nvarchar(20))
           + N'' AvgImpactPct='' + CAST(CAST(migs.avg_user_impact AS decimal(12, 2)) AS nvarchar(20))
           + N'' LastSeek='' + ISNULL(CONVERT(nvarchar(19), migs.last_user_seek, 120), ''''),
    MetricNumeric = ImpactScore
  FROM ' + @QuotedDatabase + N'.sys.dm_db_missing_index_group_stats AS migs
 INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_groups AS mig
    ON mig.index_group_handle = migs.group_handle
 INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_details AS mid
    ON mid.index_group_handle = mig.index_group_handle
 INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
    ON o.object_id = mid.object_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
 CROSS APPLY (
     SELECT ImpactScore = CAST(migs.avg_user_impact * (migs.user_seeks + migs.user_scans) AS decimal(18, 4))
 ) AS score
 WHERE o.type = ''U''
   AND s.name LIKE @SchemaFilter
   AND o.name LIKE @TableFilter
   AND score.ImpactScore > 0
 ORDER BY score.ImpactScore DESC'

EXEC sys.sp_executesql
    @Sql,
    N'@SchemaFilter sysname, @TableFilter sysname, @TopN int',
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @TopN = @TopN

SET @Sql = N'
SELECT @MissingIndexCount = COUNT(*)
  FROM ' + @QuotedDatabase + N'.sys.dm_db_missing_index_group_stats AS migs
 INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_groups AS mig
    ON mig.index_group_handle = migs.group_handle
 INNER JOIN ' + @QuotedDatabase + N'.sys.dm_db_missing_index_details AS mid
    ON mid.index_group_handle = mig.index_group_handle
 INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
    ON o.object_id = mid.object_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
 WHERE o.type = ''U''
   AND s.name LIKE @SchemaFilter
   AND o.name LIKE @TableFilter
   AND migs.avg_user_impact * (migs.user_seeks + migs.user_scans) > 0'

EXEC sys.sp_executesql
    @Sql,
    N'@SchemaFilter sysname, @TableFilter sysname, @MissingIndexCount int OUTPUT',
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @MissingIndexCount = @MissingIndexCount OUTPUT

SET @MissingIndexCount = ISNULL(@MissingIndexCount, 0)

---------------------------------------------------------------------------------------------------
-- UNUSED INDEXES (0 reads, has writes)
---------------------------------------------------------------------------------------------------
SET @Sql = N'
INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT TOP (@TopN)
    Category = ''UNUSED_INDEX'',
    Severity = CASE WHEN us.user_updates >= 10000 THEN 3 WHEN us.user_updates >= 1000 THEN 2 ELSE 1 END,
    RankOrder = ROW_NUMBER() OVER (ORDER BY us.user_updates DESC, ips.page_count DESC),
    ObjectName = s.name + ''.'' + o.name + '' ['' + i.name + '']'',
    Detail = N''Type='' + i.type_desc
           + N'' Seeks='' + CAST(ISNULL(us.user_seeks, 0) AS nvarchar(20))
           + N'' Scans='' + CAST(ISNULL(us.user_scans, 0) AS nvarchar(20))
           + N'' Lookups='' + CAST(ISNULL(us.user_lookups, 0) AS nvarchar(20))
           + N'' Updates='' + CAST(ISNULL(us.user_updates, 0) AS nvarchar(20))
           + N'' Pages='' + CAST(ISNULL(ips.page_count, 0) AS nvarchar(20)),
    MetricNumeric = CAST(ISNULL(us.user_updates, 0) AS decimal(18, 4))
  FROM ' + @QuotedDatabase + N'.sys.objects AS o
 INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.indexes AS i
    ON i.object_id = o.object_id
 LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = @TargetDatabaseId
   AND us.object_id = i.object_id
   AND us.index_id = i.index_id
 LEFT JOIN ' + @QuotedDatabase + N'.sys.dm_db_index_physical_stats(@TargetDatabaseId, NULL, NULL, NULL, ''LIMITED'') AS ips
    ON ips.object_id = i.object_id
   AND ips.index_id = i.index_id
 WHERE o.type = ''U''
   AND s.name LIKE @SchemaFilter
   AND o.name LIKE @TableFilter
   AND i.index_id > 0
   AND i.is_hypothetical = 0
   AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
   AND ISNULL(us.user_updates, 0) > 0
 ORDER BY ISNULL(us.user_updates, 0) DESC, ISNULL(ips.page_count, 0) DESC'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int, @SchemaFilter sysname, @TableFilter sysname, @TopN int',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @TopN = @TopN

SET @Sql = N'
SELECT @UnusedIndexCount = COUNT(*)
  FROM ' + @QuotedDatabase + N'.sys.objects AS o
 INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
    ON s.schema_id = o.schema_id
 INNER JOIN ' + @QuotedDatabase + N'.sys.indexes AS i
    ON i.object_id = o.object_id
 LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = @TargetDatabaseId
   AND us.object_id = i.object_id
   AND us.index_id = i.index_id
 WHERE o.type = ''U''
   AND s.name LIKE @SchemaFilter
   AND o.name LIKE @TableFilter
   AND i.index_id > 0
   AND i.is_hypothetical = 0
   AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
   AND ISNULL(us.user_updates, 0) > 0'

EXEC sys.sp_executesql
    @Sql,
    N'@TargetDatabaseId int, @SchemaFilter sysname, @TableFilter sysname, @UnusedIndexCount int OUTPUT',
    @TargetDatabaseId = @TargetDatabaseId,
    @SchemaFilter = @SchemaFilter,
    @TableFilter = @TableFilter,
    @UnusedIndexCount = @UnusedIndexCount OUTPUT

SET @UnusedIndexCount = ISNULL(@UnusedIndexCount, 0)

---------------------------------------------------------------------------------------------------
-- STALE STATISTICS
---------------------------------------------------------------------------------------------------
IF @MajorVersion >= 10
BEGIN
    SET @Sql = N'
    INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
    SELECT TOP (@TopN)
        Category = ''STALE_STATISTICS'',
        Severity = CASE
                       WHEN sp.modification_counter >= sp.[rows] * 0.5 THEN 3
                       WHEN sp.modification_counter >= sp.[rows] * 0.2 THEN 2
                       ELSE 1
                   END,
        RankOrder = ROW_NUMBER() OVER (ORDER BY sp.modification_counter DESC),
        ObjectName = s.name + ''.'' + o.name + '' ['' + st.name + '']'',
        Detail = N''StatsDate='' + ISNULL(CONVERT(nvarchar(19), STATS_DATE(st.object_id, st.stats_id), 120), '''')
               + N'' Rows='' + CAST(sp.[rows] AS nvarchar(20))
               + N'' Mods='' + CAST(sp.modification_counter AS nvarchar(20))
               + N'' AutoCreated='' + CAST(st.auto_created AS nvarchar(5))
               + N'' UserCreated='' + CAST(st.user_created AS nvarchar(5)),
        MetricNumeric = CAST(sp.modification_counter AS decimal(18, 4))
      FROM ' + @QuotedDatabase + N'.sys.stats AS st
     INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
        ON o.object_id = st.object_id
     INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
        ON s.schema_id = o.schema_id
     CROSS APPLY ' + @QuotedDatabase + N'.sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
     WHERE o.type = ''U''
       AND s.name LIKE @SchemaFilter
       AND o.name LIKE @TableFilter
       AND (
               sp.modification_counter >= CASE WHEN sp.[rows] > 0 THEN sp.[rows] * 0.2 ELSE 1000 END
            OR STATS_DATE(st.object_id, st.stats_id) < DATEADD(day, -7, GETDATE())
            OR STATS_DATE(st.object_id, st.stats_id) IS NULL
           )
     ORDER BY sp.modification_counter DESC'

    EXEC sys.sp_executesql
        @Sql,
        N'@SchemaFilter sysname, @TableFilter sysname, @TopN int',
        @SchemaFilter = @SchemaFilter,
        @TableFilter = @TableFilter,
        @TopN = @TopN

    SET @Sql = N'
    SELECT @StaleStatsCount = COUNT(*)
      FROM ' + @QuotedDatabase + N'.sys.stats AS st
     INNER JOIN ' + @QuotedDatabase + N'.sys.objects AS o
        ON o.object_id = st.object_id
     INNER JOIN ' + @QuotedDatabase + N'.sys.schemas AS s
        ON s.schema_id = o.schema_id
     CROSS APPLY ' + @QuotedDatabase + N'.sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
     WHERE o.type = ''U''
       AND s.name LIKE @SchemaFilter
       AND o.name LIKE @TableFilter
       AND (
               sp.modification_counter >= CASE WHEN sp.[rows] > 0 THEN sp.[rows] * 0.2 ELSE 1000 END
            OR STATS_DATE(st.object_id, st.stats_id) < DATEADD(day, -7, GETDATE())
            OR STATS_DATE(st.object_id, st.stats_id) IS NULL
           )'

    EXEC sys.sp_executesql
        @Sql,
        N'@SchemaFilter sysname, @TableFilter sysname, @StaleStatsCount int OUTPUT',
        @SchemaFilter = @SchemaFilter,
        @TableFilter = @TableFilter,
        @StaleStatsCount = @StaleStatsCount OUTPUT
END

SET @StaleStatsCount = ISNULL(@StaleStatsCount, 0)

---------------------------------------------------------------------------------------------------
-- INSTANCE WAIT STATS (TOP)
---------------------------------------------------------------------------------------------------
;WITH Waits AS
(
    SELECT
        wait_type,
        wait_time_ms,
        signal_wait_time_ms,
        waiting_tasks_count,
        Percentage = 100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0),
        RowNum = ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC)
      FROM sys.dm_os_wait_stats
     WHERE wait_type NOT IN (
               'CLR_SEMAPHORE', 'LAZYWRITER_SLEEP', 'RESOURCE_QUEUE', 'SLEEP_TASK',
               'SLEEP_SYSTEMTASK', 'SQLTRACE_BUFFER_FLUSH', 'WAITFOR', 'LOGMGR_QUEUE',
               'CHECKPOINT_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH', 'XE_TIMER_EVENT', 'BROKER_TO_FLUSH',
               'BROKER_TASK_STOP', 'CLR_MANUAL_EVENT', 'CLR_AUTO_EVENT', 'DISPATCHER_QUEUE_SEMAPHORE',
               'FT_IFTS_SCHEDULER_IDLE_WAIT', 'XE_DISPATCHER_WAIT', 'XE_DISPATCHER_JOIN', 'BROKER_EVENTHANDLER',
               'TRACEWRITE', 'FT_IFTSHC_MUTEX', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
               'BROKER_RECEIVE_WAITFOR', 'ONDEMAND_TASK_QUEUE', 'DBMIRROR_EVENTS_QUEUE',
               'DBMIRRORING_CMD', 'BROKER_TRANSMITTER', 'SQLTRACE_WAIT_ENTRIES',
               'SLEEP_BPOOL_FLUSH', 'SQLTRACE_LOCK', 'HADR_TIMER_TASK', 'HADR_WORK_QUEUE',
               'HADR_NOTIFICATION_DEQUEUE', 'HADR_CLUSAPI_CALL', 'HADR_TRANSPORT_SESSION',
               'HADR_DATABASE_FLOW_CONTROL', 'DIRTY_PAGE_POLL', 'SP_SERVER_DIAGNOSTICS_SLEEP')
       AND wait_time_ms > 0
)
INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT TOP (@TopN)
    Category = 'WAIT_STATS',
    Severity = CASE WHEN W1.Percentage >= 20 THEN 3 WHEN W1.Percentage >= 10 THEN 2 ELSE 1 END,
    RankOrder = ROW_NUMBER() OVER (ORDER BY W1.wait_time_ms DESC),
    ObjectName = W1.wait_type,
    Detail = N'WaitSec=' + CAST(CAST(W1.wait_time_ms / 1000.0 AS decimal(18, 2)) AS nvarchar(20))
           + N' Pct=' + CAST(CAST(W1.Percentage AS decimal(12, 2)) AS nvarchar(20))
           + N' Tasks=' + CAST(W1.waiting_tasks_count AS nvarchar(20))
           + N' SignalSec=' + CAST(CAST(W1.signal_wait_time_ms / 1000.0 AS decimal(18, 2)) AS nvarchar(20)),
    MetricNumeric = CAST(W1.wait_time_ms / 1000.0 AS decimal(18, 4))
  FROM Waits AS W1
 INNER JOIN Waits AS W2
    ON W2.RowNum <= W1.RowNum
 GROUP BY W1.RowNum, W1.wait_type, W1.wait_time_ms, W1.signal_wait_time_ms, W1.waiting_tasks_count, W1.Percentage
HAVING SUM(W2.Percentage) - W1.Percentage < 95
 ORDER BY W1.wait_time_ms DESC

---------------------------------------------------------------------------------------------------
-- TOP QUERIES (PLAN CACHE)
---------------------------------------------------------------------------------------------------
INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT
    Category = x.Category,
    Severity = CASE WHEN x.RankOrder <= 5 THEN 3 WHEN x.RankOrder <= 10 THEN 2 ELSE 1 END,
    RankOrder = x.RankOrder,
    ObjectName = LEFT(x.ObjectName, 500),
    Detail = x.Detail,
    MetricNumeric = x.MetricNumeric
  FROM (
      SELECT
          Category = 'TOP_QUERY_CPU',
          RankOrder = ROW_NUMBER() OVER (ORDER BY qs.total_worker_time DESC),
          ObjectName = LEFT(REPLACE(REPLACE(
              SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                  CASE WHEN qs.statement_end_offset = -1
                       THEN LEN(CONVERT(nvarchar(max), st.text)) * 2
                       ELSE qs.statement_end_offset
                  END - qs.statement_start_offset), CHAR(13), ' '), CHAR(10), ' '), 500),
          Detail = N'Execs=' + CAST(qs.execution_count AS nvarchar(20))
                 + N' AvgCpuMs=' + CAST(CAST(qs.total_worker_time * 1.0 / NULLIF(qs.execution_count, 0) / 1000.0 AS decimal(18, 2)) AS nvarchar(20))
                 + N' TotalCpuMs=' + CAST(CAST(qs.total_worker_time / 1000.0 AS decimal(18, 2)) AS nvarchar(20))
                 + N' AvgReads=' + CAST(CAST(qs.total_logical_reads * 1.0 / NULLIF(qs.execution_count, 0) AS decimal(18, 0)) AS nvarchar(20)),
          MetricNumeric = CAST(qs.total_worker_time / 1000.0 AS decimal(18, 4))
        FROM sys.dm_exec_query_stats AS qs
       CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
       WHERE qs.database_id = @TargetDatabaseId
  ) AS x
 WHERE x.RankOrder <= @TopN

INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT
    Category = x.Category,
    Severity = CASE WHEN x.RankOrder <= 5 THEN 3 WHEN x.RankOrder <= 10 THEN 2 ELSE 1 END,
    RankOrder = x.RankOrder,
    ObjectName = LEFT(x.ObjectName, 500),
    Detail = x.Detail,
    MetricNumeric = x.MetricNumeric
  FROM (
      SELECT
          Category = 'TOP_QUERY_DURATION',
          RankOrder = ROW_NUMBER() OVER (ORDER BY qs.total_elapsed_time DESC),
          ObjectName = LEFT(REPLACE(REPLACE(
              SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                  CASE WHEN qs.statement_end_offset = -1
                       THEN LEN(CONVERT(nvarchar(max), st.text)) * 2
                       ELSE qs.statement_end_offset
                  END - qs.statement_start_offset), CHAR(13), ' '), CHAR(10), ' '), 500),
          Detail = N'Execs=' + CAST(qs.execution_count AS nvarchar(20))
                 + N' AvgMs=' + CAST(CAST(qs.total_elapsed_time * 1.0 / NULLIF(qs.execution_count, 0) / 1000.0 AS decimal(18, 2)) AS nvarchar(20))
                 + N' TotalMs=' + CAST(CAST(qs.total_elapsed_time / 1000.0 AS decimal(18, 2)) AS nvarchar(20))
                 + N' AvgReads=' + CAST(CAST(qs.total_logical_reads * 1.0 / NULLIF(qs.execution_count, 0) AS decimal(18, 0)) AS nvarchar(20)),
          MetricNumeric = CAST(qs.total_elapsed_time / 1000.0 AS decimal(18, 4))
        FROM sys.dm_exec_query_stats AS qs
       CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
       WHERE qs.database_id = @TargetDatabaseId
  ) AS x
 WHERE x.RankOrder <= @TopN

INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
SELECT
    Category = x.Category,
    Severity = CASE WHEN x.RankOrder <= 5 THEN 3 WHEN x.RankOrder <= 10 THEN 2 ELSE 1 END,
    RankOrder = x.RankOrder,
    ObjectName = LEFT(x.ObjectName, 500),
    Detail = x.Detail,
    MetricNumeric = x.MetricNumeric
  FROM (
      SELECT
          Category = 'TOP_QUERY_READS',
          RankOrder = ROW_NUMBER() OVER (ORDER BY qs.total_logical_reads DESC),
          ObjectName = LEFT(REPLACE(REPLACE(
              SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                  CASE WHEN qs.statement_end_offset = -1
                       THEN LEN(CONVERT(nvarchar(max), st.text)) * 2
                       ELSE qs.statement_end_offset
                  END - qs.statement_start_offset), CHAR(13), ' '), CHAR(10), ' '), 500),
          Detail = N'Execs=' + CAST(qs.execution_count AS nvarchar(20))
                 + N' AvgReads=' + CAST(CAST(qs.total_logical_reads * 1.0 / NULLIF(qs.execution_count, 0) AS decimal(18, 0)) AS nvarchar(20))
                 + N' TotalReads=' + CAST(qs.total_logical_reads AS nvarchar(20))
                 + N' AvgCpuMs=' + CAST(CAST(qs.total_worker_time * 1.0 / NULLIF(qs.execution_count, 0) / 1000.0 AS decimal(18, 2)) AS nvarchar(20)),
          MetricNumeric = CAST(qs.total_logical_reads AS decimal(18, 4))
        FROM sys.dm_exec_query_stats AS qs
       CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
       WHERE qs.database_id = @TargetDatabaseId
  ) AS x
 WHERE x.RankOrder <= @TopN

---------------------------------------------------------------------------------------------------
-- VLF COUNT
---------------------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#DbccLogInfo') IS NOT NULL
    DROP TABLE #DbccLogInfo

IF @MajorVersion < 11
BEGIN
    CREATE TABLE #DbccLogInfo
    (
        FileId      smallint       NULL,
        FileSize    bigint         NULL,
        StartOffset bigint         NULL,
        FSeqNo      int            NULL,
        Status      tinyint        NULL,
        Parity      tinyint        NULL,
        CreateLSN   numeric(25, 0) NULL
    )
END
ELSE
BEGIN
    CREATE TABLE #DbccLogInfo
    (
        RecoveryUnitId int            NULL,
        FileId         smallint       NULL,
        FileSize       bigint         NULL,
        StartOffset    bigint         NULL,
        FSeqNo         int            NULL,
        Status         tinyint        NULL,
        Parity         tinyint        NULL,
        CreateLSN      numeric(25, 0) NULL
    )
END

SET @Sql = N'DBCC LOGINFO(' + @QuotedDatabase + N') WITH NO_INFOMSGS'
INSERT INTO #DbccLogInfo
EXEC (@Sql)

SET @VLFCount = @@ROWCOUNT

INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
VALUES ('DATABASE', 'VLFCount', CAST(@VLFCount AS nvarchar(20)), @VLFCount)

IF @VLFCount >= 1000
    INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
    VALUES ('VLF', 3, 1, @TargetDatabase, N'VLF count is high; log file may have excessive virtual log files.', @VLFCount)
ELSE IF @VLFCount >= 200
    INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
    VALUES ('VLF', 2, 1, @TargetDatabase, N'VLF count is elevated; consider log maintenance.', @VLFCount)

---------------------------------------------------------------------------------------------------
-- BLOCKING / OPEN TRANSACTIONS
---------------------------------------------------------------------------------------------------
SELECT @BlockingCount = COUNT(*)
  FROM sys.dm_exec_requests
 WHERE blocking_session_id > 0
   AND database_id = @TargetDatabaseId

SELECT @OpenTranCount = COUNT(*)
  FROM sys.dm_tran_database_transactions AS dt
 WHERE dt.database_id = @TargetDatabaseId
   AND dt.database_transaction_state <> 6

INSERT INTO #Metrics (Category, MetricName, MetricValue, MetricNumeric)
VALUES
    ('RUNTIME', 'BlockingSessionCount', CAST(@BlockingCount AS nvarchar(20)), @BlockingCount),
    ('RUNTIME', 'OpenTransactionCount', CAST(@OpenTranCount AS nvarchar(20)), @OpenTranCount),
    ('SUMMARY', 'FragmentedIndexCount', CAST(@FragmentedCount AS nvarchar(20)), @FragmentedCount),
    ('SUMMARY', 'MissingIndexCount', CAST(@MissingIndexCount AS nvarchar(20)), @MissingIndexCount),
    ('SUMMARY', 'UnusedIndexCount', CAST(@UnusedIndexCount AS nvarchar(20)), @UnusedIndexCount),
    ('SUMMARY', 'StaleStatisticsCount', CAST(@StaleStatsCount AS nvarchar(20)), @StaleStatsCount)

IF @BlockingCount > 0
    INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
    VALUES ('BLOCKING', 3, 1, @TargetDatabase, N'Active blocking sessions detected at capture time.', @BlockingCount)

IF @OpenTranCount > 0
    INSERT INTO #Findings (Category, Severity, RankOrder, ObjectName, Detail, MetricNumeric)
    VALUES ('OPEN_TRANSACTION', 2, 1, @TargetDatabase, N'Open transactions detected at capture time.', @OpenTranCount)

---------------------------------------------------------------------------------------------------
-- PERSIST
---------------------------------------------------------------------------------------------------
SELECT @MetricCount = COUNT(*) FROM #Metrics
SELECT @FindingCount = COUNT(*) FROM #Findings

IF @PersistResults = 1
BEGIN
    INSERT INTO dbo.DatabasePerformanceRun
    (
        AnalysisRunID,
        CaptureDate,
        ServerName,
        DatabaseName,
        SqlMajorVersion,
        ProductVersion,
        Edition,
        TopN,
        MinFragmentationPct,
        MinPageCount,
        SchemaFilter,
        TableFilter
    )
    VALUES
    (
        @AnalysisRunID,
        @CaptureDate,
        @ServerName,
        @TargetDatabase,
        @MajorVersion,
        @ProductVersion,
        @Edition,
        @TopN,
        @MinFragmentationPct,
        @MinPageCount,
        @SchemaFilter,
        @TableFilter
    )

    INSERT INTO dbo.DatabasePerformanceMetric
    (
        AnalysisRunID,
        Category,
        MetricName,
        MetricValue,
        MetricNumeric
    )
    SELECT
        @AnalysisRunID,
        m.Category,
        m.MetricName,
        m.MetricValue,
        m.MetricNumeric
      FROM #Metrics AS m

    INSERT INTO dbo.DatabasePerformanceFinding
    (
        AnalysisRunID,
        Category,
        Severity,
        RankOrder,
        ObjectName,
        Detail,
        MetricNumeric
    )
    SELECT
        @AnalysisRunID,
        f.Category,
        f.Severity,
        f.RankOrder,
        f.ObjectName,
        f.Detail,
        f.MetricNumeric
      FROM #Findings AS f
END

---------------------------------------------------------------------------------------------------
-- RETURN
---------------------------------------------------------------------------------------------------
IF @ReturnResultSets = 1
BEGIN
    SELECT
        AnalysisRunID = @AnalysisRunID,
        CaptureDate = @CaptureDate,
        ServerName = @ServerName,
        DatabaseName = @TargetDatabase,
        SqlMajorVersion = @MajorVersion,
        ProductVersion = @ProductVersion,
        Edition = @Edition,
        MetricCount = @MetricCount,
        FindingCount = @FindingCount,
        FragmentedIndexCount = @FragmentedCount,
        MissingIndexCount = @MissingIndexCount,
        UnusedIndexCount = @UnusedIndexCount,
        StaleStatisticsCount = @StaleStatsCount,
        VLFCount = @VLFCount,
        BlockingSessionCount = @BlockingCount,
        OpenTransactionCount = @OpenTranCount,
        SchemaFilter = @SchemaFilter,
        TableFilter = @TableFilter,
        TopN = @TopN,
        MinFragmentationPct = @MinFragmentationPct,
        MinPageCount = @MinPageCount

    SELECT
        Category,
        MetricName,
        MetricValue,
        MetricNumeric
      FROM #Metrics
     ORDER BY Category, MetricName

    SELECT
        Category,
        Severity,
        RankOrder,
        ObjectName,
        Detail,
        MetricNumeric
      FROM #Findings
     ORDER BY Category, Severity DESC, MetricNumeric DESC, RankOrder
END

GO