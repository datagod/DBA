
/*
  ShowServerState.sql

  Deploy to the DBA tool database, then execute:
    EXEC dbo.ShowServerState
    EXEC dbo.ShowServerState @SampleSeconds = 3, @CpuHistoryPoints = 24
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowServerState') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowServerState'
    DROP PROCEDURE dbo.ShowServerState
END
GO

PRINT 'Creating: ShowServerState'
GO

CREATE PROCEDURE dbo.ShowServerState
(
    @ReportWidth        tinyint = 120,
    @SampleSeconds      tinyint = 2,
    @CpuHistoryPoints   tinyint = 24,
    @BarWidth           tinyint = 36
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 26, 2026
-- Author:       Bill McEvoy
-- Description:  Fixed-width, SSMS-friendly server workload report with ASCII bar graphs for CPU,
--               memory, scheduler engagement, and throughput counters.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion           tinyint,
    @ProductVersion         varchar(30),
    @ProductLevel           varchar(30),
    @Edition                varchar(64),
    @ServerName             sysname,
    @SqlInstance            sysname,
    @ReportTime             varchar(19),
    @StartTime              varchar(19),
    @Divider                varchar(120),
    @HeaderRule             varchar(120),
    @BlankLine              varchar(120),
    @LineNo                 int,
    @Delay                  varchar(8),
    @Sparkline              varchar(80),
    @CpuHistMin             int,
    @CpuHistMax             int,
    @CpuHistSamples         int,
    @Seq                    int,
    @PointPct               int,
    @PointChar              char(1),
    @ts_now                 bigint,
    @CpuCount               int,
    @SchedulerCount         int,
    @EngagedSchedulers      int,
    @RunnableSchedulers     int,
    @RunnableTasks          int,
    @CurrentTasks           int,
    @ActiveWorkers          int,
    @MaxWorkerThreads       int,
    @ActiveSessions         int,
    @RunningRequests        int,
    @RunnableRequests       int,
    @SuspendedRequests      int,
    @BlockedRequests        int,
    @SqlCpuPct              int,
    @SystemCpuPct           int,
    @OsTotalMB              bigint,
    @OsUsedMB               bigint,
    @OsAvailMB              bigint,
    @OsUsedPct              decimal(18, 4),
    @SqlCommittedMB         bigint,
    @SqlTargetMB            bigint,
    @SqlMaxServerMB         bigint,
    @SqlUsedPct             decimal(18, 4),
    @PleSeconds             bigint,
    @BufferHitPct           decimal(8, 2),
    @PendingMemoryGrants    int,
    @BatchPerSec            decimal(18, 2),
    @CompilationsPerSec     decimal(18, 2),
    @RecompilationsPerSec   decimal(18, 2),
    @TransactionsPerSec     decimal(18, 2),
    @PageReadsPerSec        decimal(18, 2),
    @PageWritesPerSec       decimal(18, 2),
    @UserConnections        bigint,
    @SignalWaitPct          decimal(8, 2),
    @BatchSample1           bigint,
    @BatchSample2           bigint,
    @CompSample1            bigint,
    @CompSample2            bigint,
    @RecompSample1          bigint,
    @RecompSample2          bigint,
    @TranSample1            bigint,
    @TranSample2            bigint,
    @ReadSample1            bigint,
    @ReadSample2            bigint,
    @WriteSample1           bigint,
    @WriteSample2           bigint,
    @CounterPrefix          nvarchar(128),
    @ThroughputPeak         decimal(38, 4),
    @SampleStart            datetime2(3),
    @SampleEnd              datetime2(3),
    @ElapsedSec             decimal(18, 4)

IF @ReportWidth IS NULL OR @ReportWidth < 80
    SET @ReportWidth = 120

IF @SampleSeconds IS NULL OR @SampleSeconds < 1
    SET @SampleSeconds = 1

IF @SampleSeconds > 30
    SET @SampleSeconds = 30

IF @CpuHistoryPoints IS NULL OR @CpuHistoryPoints < 5
    SET @CpuHistoryPoints = 5

IF @CpuHistoryPoints > 60
    SET @CpuHistoryPoints = 60

IF @BarWidth IS NULL OR @BarWidth < 20
    SET @BarWidth = 40

IF @BarWidth > 60
    SET @BarWidth = 60

SET @CounterPrefix = CASE
    WHEN CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) IS NULL THEN N'SQLServer'
    ELSE N'MSSQL$' + CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128))
END

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ProductLevel   = CAST(SERVERPROPERTY('ProductLevel') AS varchar(30))
SET @Edition        = CAST(SERVERPROPERTY('Edition') AS varchar(64))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @SqlInstance    = CAST(@@SERVERNAME AS sysname)
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @Divider        = REPLICATE('-', @ReportWidth)
SET @HeaderRule     = REPLICATE('=', @ReportWidth)
SET @BlankLine      = REPLICATE(' ', @ReportWidth)
SET @Delay          = CONVERT(varchar(8), DATEADD(SECOND, @SampleSeconds, 0), 108)

SELECT @StartTime = CONVERT(varchar(19), osi.sqlserver_start_time, 120)
  FROM sys.dm_os_sys_info AS osi

IF OBJECT_ID('tempdb..#Report') IS NOT NULL
    DROP TABLE #Report

CREATE TABLE #Report
(
    [LineNo]    int          NOT NULL,
    ReportLine  varchar(200) NOT NULL
)

IF OBJECT_ID('tempdb..#CpuHistory') IS NOT NULL
    DROP TABLE #CpuHistory

CREATE TABLE #CpuHistory
(
    RowNum          int      NOT NULL,
    EventTime       datetime NOT NULL,
    SqlCpuPct       int      NOT NULL,
    SystemCpuPct    int      NOT NULL
)

IF OBJECT_ID('tempdb..#Bars') IS NOT NULL
    DROP TABLE #Bars

CREATE TABLE #Bars
(
    SortOrder     int           NOT NULL,
    MetricLabel   varchar(28)   NOT NULL,
    CurrentText   varchar(40)   NOT NULL,
    MinText       varchar(24)   NOT NULL,
    MaxText       varchar(24)   NOT NULL,
    FillPct       decimal(18, 4) NOT NULL,
    BarFill       int            NOT NULL,
    BarChar       char(1)       NOT NULL,
    AxisLeft      varchar(8)    NOT NULL,
    AxisRight     varchar(12)   NOT NULL
)

IF OBJECT_ID('tempdb..#Throughput') IS NOT NULL
    DROP TABLE #Throughput

CREATE TABLE #Throughput
(
    SortOrder     int             NOT NULL,
    MetricLabel   varchar(24)     NOT NULL,
    RatePerSec    decimal(38, 4)  NOT NULL,
    RateText      varchar(16)     NOT NULL,
    SharePct      decimal(8, 1)   NOT NULL,
    BarFill       int             NOT NULL
)

SELECT
    @CpuCount = osi.cpu_count,
    @SqlCommittedMB = CAST(osi.committed_kb / 1024 AS bigint),
    @SqlTargetMB = CAST(osi.committed_target_kb / 1024 AS bigint),
    @SqlMaxServerMB = CAST(osi.physical_memory_kb / 1024 AS bigint)
  FROM sys.dm_os_sys_info AS osi

SELECT
    @SchedulerCount = COUNT(*),
    @EngagedSchedulers = SUM(CASE WHEN s.current_tasks_count > 0 THEN 1 ELSE 0 END),
    @RunnableSchedulers = SUM(CASE WHEN s.runnable_tasks_count > 0 THEN 1 ELSE 0 END),
    @RunnableTasks = SUM(s.runnable_tasks_count),
    @CurrentTasks = SUM(s.current_tasks_count),
    @ActiveWorkers = SUM(s.active_workers_count)
  FROM sys.dm_os_schedulers AS s
 WHERE s.is_online = 1
   AND s.scheduler_id < 255

SELECT @MaxWorkerThreads = CONVERT(int, c.value_in_use)
  FROM sys.configurations AS c
 WHERE c.name = 'max worker threads'

SELECT
    @ActiveSessions = COUNT(*)
  FROM sys.dm_exec_sessions AS s
 WHERE s.is_user_process = 1

SELECT
    @RunningRequests = SUM(CASE WHEN r.status = 'running' THEN 1 ELSE 0 END),
    @RunnableRequests = SUM(CASE WHEN r.status = 'runnable' THEN 1 ELSE 0 END),
    @SuspendedRequests = SUM(CASE WHEN r.status = 'suspended' THEN 1 ELSE 0 END),
    @BlockedRequests = SUM(CASE WHEN r.blocking_session_id > 0 THEN 1 ELSE 0 END)
  FROM sys.dm_exec_requests AS r
 WHERE r.session_id > 50
   AND r.session_id <> @@SPID

SET @RunningRequests   = ISNULL(@RunningRequests, 0)
SET @RunnableRequests  = ISNULL(@RunnableRequests, 0)
SET @SuspendedRequests = ISNULL(@SuspendedRequests, 0)
SET @BlockedRequests   = ISNULL(@BlockedRequests, 0)

IF @MajorVersion >= 11
BEGIN
    SELECT
        @OsTotalMB = CAST(m.total_physical_memory_kb / 1024 AS bigint),
        @OsAvailMB = CAST(m.available_physical_memory_kb / 1024 AS bigint),
        @OsUsedMB = CAST((m.total_physical_memory_kb - m.available_physical_memory_kb) / 1024 AS bigint),
        @OsUsedPct = CAST(
                        CASE
                            WHEN (CAST(m.total_physical_memory_kb - m.available_physical_memory_kb AS decimal(38, 4))
                                  * 100.0
                                  / NULLIF(CAST(m.total_physical_memory_kb AS decimal(38, 4)), 0)) > 9999999999999999.9999
                                THEN 9999999999999999.9999
                            WHEN (CAST(m.total_physical_memory_kb - m.available_physical_memory_kb AS decimal(38, 4))
                                  * 100.0
                                  / NULLIF(CAST(m.total_physical_memory_kb AS decimal(38, 4)), 0)) < 0
                                THEN 0
                            ELSE (CAST(m.total_physical_memory_kb - m.available_physical_memory_kb AS decimal(38, 4))
                                  * 100.0
                                  / NULLIF(CAST(m.total_physical_memory_kb AS decimal(38, 4)), 0))
                        END AS decimal(18, 4))
      FROM sys.dm_os_sys_memory AS m
END
ELSE
BEGIN
    SET @OsTotalMB = @SqlMaxServerMB
    SET @OsUsedMB = @SqlCommittedMB
    SET @OsAvailMB = CASE WHEN @SqlMaxServerMB > @SqlCommittedMB THEN @SqlMaxServerMB - @SqlCommittedMB ELSE 0 END
    SET @OsUsedPct = CAST(
                        CAST(@SqlCommittedMB AS decimal(38, 4)) * 100.0
                        / NULLIF(CAST(@SqlMaxServerMB AS decimal(38, 4)), 0)
                     AS decimal(18, 4))
END

SET @SqlUsedPct = CASE
    WHEN @SqlTargetMB IS NULL OR @SqlTargetMB = 0 THEN 0
    ELSE CAST(
        CASE
            WHEN (CAST(@SqlCommittedMB AS decimal(38, 4)) * 100.0 / CAST(@SqlTargetMB AS decimal(38, 4))) > 9999999999999999.9999
                THEN 9999999999999999.9999
            WHEN (CAST(@SqlCommittedMB AS decimal(38, 4)) * 100.0 / CAST(@SqlTargetMB AS decimal(38, 4))) < 0
                THEN 0
            ELSE (CAST(@SqlCommittedMB AS decimal(38, 4)) * 100.0 / CAST(@SqlTargetMB AS decimal(38, 4)))
        END AS decimal(18, 4))
END

SELECT @PleSeconds = c.cntr_value
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name LIKE '%Buffer Manager%'
   AND c.counter_name = 'Page life expectancy'

SELECT @BufferHitPct = CAST(
                        CAST(ratio AS decimal(38, 4)) * 100.0
                        / NULLIF(CAST(base_cnt AS decimal(38, 4)), 0)
                     AS decimal(8, 2))
  FROM (
      SELECT
          ratio = MAX(CASE WHEN counter_name = 'Buffer cache hit ratio' THEN cntr_value END),
          base_cnt = MAX(CASE WHEN counter_name = 'Buffer cache hit ratio base' THEN cntr_value END)
        FROM sys.dm_os_performance_counters
       WHERE object_name LIKE '%Buffer Manager%'
         AND counter_name IN ('Buffer cache hit ratio', 'Buffer cache hit ratio base')
  ) AS b

SELECT @PendingMemoryGrants = COUNT(*)
  FROM sys.dm_exec_query_memory_grants
 WHERE grant_time IS NULL

SELECT
    @SignalWaitPct = CAST(
                        100.0 * CAST(SUM(CAST(signal_wait_time_ms AS decimal(38, 4))) AS decimal(38, 4))
                        / NULLIF(CAST(SUM(CAST(wait_time_ms AS decimal(38, 4))) AS decimal(38, 4)), 0)
                     AS decimal(8, 2))
  FROM sys.dm_os_wait_stats
 WHERE wait_type NOT LIKE '%SLEEP%'

SET @SignalWaitPct = ISNULL(@SignalWaitPct, 0)

SELECT @UserConnections = c.cntr_value
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name LIKE '%General Statistics%'
   AND c.instance_name = ''
   AND c.counter_name = 'User Connections'

SELECT
    @ts_now = cpu_ticks / NULLIF(cpu_ticks / ms_ticks, 0)
  FROM sys.dm_os_sys_info

;WITH RingData AS
(
    SELECT TOP (@CpuHistoryPoints)
        record.value('(./Record/@id)[1]', 'int') AS record_id,
        DATEADD(ms,
            -1 * CAST(
                CASE
                    WHEN (@ts_now - x.[timestamp]) > 2147483647 THEN 2147483647
                    WHEN (@ts_now - x.[timestamp]) < -2147483647 THEN -2147483647
                    ELSE (@ts_now - x.[timestamp])
                END AS int),
            GETDATE()) AS EventTime,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SqlCpuPct,
        100 - record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemCpuPct
      FROM (
          SELECT [timestamp], CONVERT(xml, record) AS record
            FROM sys.dm_os_ring_buffers
           WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
             AND record LIKE '%<SystemHealth>%'
      ) AS x
     ORDER BY record.value('(./Record/@id)[1]', 'int') DESC
)
INSERT INTO #CpuHistory (RowNum, EventTime, SqlCpuPct, SystemCpuPct)
SELECT
    ROW_NUMBER() OVER (ORDER BY r.record_id ASC),
    r.EventTime,
    ISNULL(r.SqlCpuPct, 0),
    ISNULL(r.SystemCpuPct, 0)
  FROM RingData AS r

SELECT TOP (1)
    @SqlCpuPct = h.SqlCpuPct,
    @SystemCpuPct = h.SystemCpuPct
  FROM #CpuHistory AS h
 ORDER BY h.RowNum DESC

SELECT
    @CpuHistMin = MIN(h.SystemCpuPct),
    @CpuHistMax = MAX(h.SystemCpuPct)
  FROM #CpuHistory AS h

SET @CpuHistMin = ISNULL(@CpuHistMin, 0)
SET @CpuHistMax = ISNULL(@CpuHistMax, 0)
SET @CpuHistSamples = (SELECT COUNT(*) FROM #CpuHistory)

SET @Sparkline = ''
SET @Seq = 1

WHILE @Seq <= (SELECT COUNT(*) FROM #CpuHistory)
BEGIN
    SELECT @PointPct = h.SystemCpuPct
      FROM #CpuHistory AS h
     WHERE h.RowNum = @Seq

    SET @PointChar = CASE
                        WHEN @PointPct >= 90 THEN '#'
                        WHEN @PointPct >= 70 THEN '+'
                        WHEN @PointPct >= 50 THEN ':'
                        WHEN @PointPct >= 25 THEN '.'
                        ELSE ' '
                     END
    SET @Sparkline = @Sparkline + @PointChar
    SET @Seq += 1
END

SELECT
    @BatchSample1 = 0,
    @CompSample1 = 0,
    @RecompSample1 = 0,
    @TranSample1 = 0,
    @ReadSample1 = 0,
    @WriteSample1 = 0,
    @BatchSample2 = 0,
    @CompSample2 = 0,
    @RecompSample2 = 0,
    @TranSample2 = 0,
    @ReadSample2 = 0,
    @WriteSample2 = 0

SET @SampleStart = SYSDATETIME()

SELECT @BatchSample1 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':SQL Statistics'
   AND c.counter_name = N'Batch Requests/sec'
   AND c.instance_name = N''

SELECT @CompSample1 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':SQL Statistics'
   AND c.counter_name = N'SQL Compilations/sec'
   AND c.instance_name = N''

SELECT @RecompSample1 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':SQL Statistics'
   AND c.counter_name = N'SQL Re-Compilations/sec'
   AND c.instance_name = N''

SELECT @TranSample1 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':Databases'
   AND c.counter_name = N'Transactions/sec'
   AND c.instance_name = N'_Total'

SELECT @ReadSample1 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':Buffer Manager'
   AND c.counter_name = N'Page reads/sec'
   AND c.instance_name = N''

SELECT @WriteSample1 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':Buffer Manager'
   AND c.counter_name = N'Page writes/sec'
   AND c.instance_name = N''

WAITFOR DELAY @Delay

SET @SampleEnd = SYSDATETIME()

SELECT @BatchSample2 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':SQL Statistics'
   AND c.counter_name = N'Batch Requests/sec'
   AND c.instance_name = N''

SELECT @CompSample2 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':SQL Statistics'
   AND c.counter_name = N'SQL Compilations/sec'
   AND c.instance_name = N''

SELECT @RecompSample2 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':SQL Statistics'
   AND c.counter_name = N'SQL Re-Compilations/sec'
   AND c.instance_name = N''

SELECT @TranSample2 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':Databases'
   AND c.counter_name = N'Transactions/sec'
   AND c.instance_name = N'_Total'

SELECT @ReadSample2 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':Buffer Manager'
   AND c.counter_name = N'Page reads/sec'
   AND c.instance_name = N''

SELECT @WriteSample2 = ISNULL(c.cntr_value, 0)
  FROM sys.dm_os_performance_counters AS c
 WHERE c.object_name = @CounterPrefix + N':Buffer Manager'
   AND c.counter_name = N'Page writes/sec'
   AND c.instance_name = N''

SET @ElapsedSec = CAST(DATEDIFF(millisecond, @SampleStart, @SampleEnd) AS decimal(18, 4)) / 1000.0
IF @ElapsedSec <= 0
    SET @ElapsedSec = CAST(@SampleSeconds AS decimal(18, 4))

SET @BatchPerSec = CASE
    WHEN @BatchSample2 >= @BatchSample1
        THEN CAST(@BatchSample2 - @BatchSample1 AS decimal(38, 4)) / @ElapsedSec
    ELSE CAST(@BatchSample2 AS decimal(38, 4)) / @ElapsedSec
END
SET @CompilationsPerSec = CASE
    WHEN @CompSample2 >= @CompSample1
        THEN CAST(@CompSample2 - @CompSample1 AS decimal(38, 4)) / @ElapsedSec
    ELSE CAST(@CompSample2 AS decimal(38, 4)) / @ElapsedSec
END
SET @RecompilationsPerSec = CASE
    WHEN @RecompSample2 >= @RecompSample1
        THEN CAST(@RecompSample2 - @RecompSample1 AS decimal(38, 4)) / @ElapsedSec
    ELSE CAST(@RecompSample2 AS decimal(38, 4)) / @ElapsedSec
END
SET @TransactionsPerSec = CASE
    WHEN @TranSample2 >= @TranSample1
        THEN CAST(@TranSample2 - @TranSample1 AS decimal(38, 4)) / @ElapsedSec
    ELSE CAST(@TranSample2 AS decimal(38, 4)) / @ElapsedSec
END
SET @PageReadsPerSec = CASE
    WHEN @ReadSample2 >= @ReadSample1
        THEN CAST(@ReadSample2 - @ReadSample1 AS decimal(38, 4)) / @ElapsedSec
    ELSE CAST(@ReadSample2 AS decimal(38, 4)) / @ElapsedSec
END
SET @PageWritesPerSec = CASE
    WHEN @WriteSample2 >= @WriteSample1
        THEN CAST(@WriteSample2 - @WriteSample1 AS decimal(38, 4)) / @ElapsedSec
    ELSE CAST(@WriteSample2 AS decimal(38, 4)) / @ElapsedSec
END

INSERT INTO #Throughput (SortOrder, MetricLabel, RatePerSec, RateText, SharePct, BarFill)
SELECT
    v.SortOrder,
    v.MetricLabel,
    v.RatePerSec,
    CASE
        WHEN v.RatePerSec >= 1000000000 THEN LTRIM(STR(v.RatePerSec / 1000000000.0, 8, 2)) + 'B'
        WHEN v.RatePerSec >= 1000000 THEN LTRIM(STR(v.RatePerSec / 1000000.0, 8, 2)) + 'M'
        WHEN v.RatePerSec >= 1000 THEN LTRIM(STR(v.RatePerSec / 1000.0, 8, 1)) + 'K'
        ELSE LTRIM(STR(v.RatePerSec, 10, 0))
    END,
    0,
    0
  FROM (
      VALUES
          (1, 'Batch requests', @BatchPerSec),
          (2, 'SQL compilations', @CompilationsPerSec),
          (3, 'SQL re-compiles', @RecompilationsPerSec),
          (4, 'Transactions', @TransactionsPerSec),
          (5, 'Page reads', @PageReadsPerSec),
          (6, 'Page writes', @PageWritesPerSec)
  ) AS v(SortOrder, MetricLabel, RatePerSec)

SELECT @ThroughputPeak = MAX(t.RatePerSec)
  FROM #Throughput AS t

SET @ThroughputPeak = NULLIF(@ThroughputPeak, 0)

UPDATE t
   SET SharePct = CAST(
           CASE
               WHEN @ThroughputPeak IS NULL OR t.RatePerSec <= 0 THEN 0
               ELSE (t.RatePerSec * 100.0) / @ThroughputPeak
           END AS decimal(8, 1)),
       BarFill = CASE
           WHEN @ThroughputPeak IS NULL OR t.RatePerSec <= 0 THEN 0
           WHEN CAST(ROUND((t.RatePerSec * 100.0) / @ThroughputPeak * @BarWidth / 100.0, 0) AS int) > @BarWidth
               THEN CAST(@BarWidth AS int)
           ELSE CAST(ROUND((t.RatePerSec * 100.0) / @ThroughputPeak * @BarWidth / 100.0, 0) AS int)
       END
  FROM #Throughput AS t

SET @LineNo = 0

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT(' SERVER STATE REPORT' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2,
       LEFT(' Instance: ' + @SqlInstance
            + '  |  Host: ' + @ServerName
            + '  |  ' + @ReportTime, @ReportWidth)
UNION ALL
SELECT @LineNo + 3,
       LEFT(' SQL Server ' + @ProductVersion + ' ' + @ProductLevel
            + '  |  ' + LEFT(@Edition, 28)
            + '  |  Up since ' + ISNULL(@StartTime, 'n/a'), @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(@HeaderRule, @ReportWidth)

SET @LineNo = @LineNo + 5

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo,     LEFT(' PROCESSOR & SCHEDULER ENGAGEMENT' + @BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(@Divider, @ReportWidth)),
    (@LineNo + 2, LEFT(' Logical CPUs (visible)  : ' + CAST(@CpuCount AS varchar(10))
                      + '   Online schedulers     : ' + CAST(@SchedulerCount AS varchar(10))
                      + '   Engaged schedulers    : ' + CAST(@EngagedSchedulers AS varchar(10)), @ReportWidth)),
    (@LineNo + 3, LEFT(' Runnable schedulers     : ' + CAST(@RunnableSchedulers AS varchar(10))
                      + '   Runnable tasks        : ' + CAST(@RunnableTasks AS varchar(10))
                      + '   Current tasks       : ' + CAST(@CurrentTasks AS varchar(10)), @ReportWidth)),
    (@LineNo + 4, LEFT(' Active workers          : ' + CAST(@ActiveWorkers AS varchar(10))
                      + '   Max worker threads    : ' + CAST(@MaxWorkerThreads AS varchar(10))
                      + '   Signal waits (CPU)    : ' + CAST(@SignalWaitPct AS varchar(10)) + '%', @ReportWidth)),
    (@LineNo + 5, LEFT(' Sample window for throughput counters: ' + CAST(@SampleSeconds AS varchar(10)) + ' second(s)' + @BlankLine, @ReportWidth)),
    (@LineNo + 6, LEFT(' System CPU trend (ring buffer, older << now)' + @BlankLine, @ReportWidth)),
    (@LineNo + 7, LEFT('   CURRENT ' + RIGHT(REPLICATE(' ', 6) + CAST(ISNULL(@SystemCpuPct, 0) AS varchar(6)) + '%', 7)
                      + '   MIN ' + RIGHT(REPLICATE(' ', 6) + CAST(@CpuHistMin AS varchar(6)) + '%', 7)
                      + '   MAX ' + RIGHT(REPLICATE(' ', 6) + CAST(@CpuHistMax AS varchar(6)) + '%', 7)
                      + '   samples=' + CAST(@CpuHistSamples AS varchar(10)), @ReportWidth)),
    (@LineNo + 8, LEFT('   ' + @Sparkline + @BlankLine, @ReportWidth)),
    (@LineNo + 9, LEFT('   0% |' + REPLICATE('-', @BarWidth) + '| 100%   (#=90% +=70% :=50% .=25%)' + @BlankLine, @ReportWidth)),
    (@LineNo + 10, LEFT(@BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 11

INSERT INTO #Bars (SortOrder, MetricLabel, CurrentText, MinText, MaxText, FillPct, BarChar, AxisLeft, AxisRight, BarFill)
SELECT
    v.SortOrder,
    v.MetricLabel,
    v.CurrentText,
    v.MinText,
    v.MaxText,
    v.FillPct,
    v.BarChar,
    v.AxisLeft,
    v.AxisRight,
    CASE
        WHEN v.FillPct <= 0 THEN 0
        WHEN v.FillPct >= 100 THEN CAST(@BarWidth AS int)
        ELSE
            CASE
                WHEN CAST(ROUND(v.FillPct * CAST(@BarWidth AS decimal(18, 4)) / 100.0, 0) AS int) > @BarWidth
                    THEN CAST(@BarWidth AS int)
                WHEN CAST(ROUND(v.FillPct * CAST(@BarWidth AS decimal(18, 4)) / 100.0, 0) AS int) < 0
                    THEN 0
                ELSE CAST(ROUND(v.FillPct * CAST(@BarWidth AS decimal(18, 4)) / 100.0, 0) AS int)
            END
    END
  FROM (
      VALUES
          (1, 'SQL process CPU',
              RIGHT(REPLICATE(' ', 8) + CAST(ISNULL(@SqlCpuPct, 0) AS varchar(8)) + '%', 10),
              '0%', '100%',
              CAST(ISNULL(@SqlCpuPct, 0) AS decimal(18, 4)), '#', '0%', '100%'),
          (2, 'System CPU usage',
              RIGHT(REPLICATE(' ', 8) + CAST(ISNULL(@SystemCpuPct, 0) AS varchar(8)) + '%', 10),
              '0%', '100%',
              CAST(ISNULL(@SystemCpuPct, 0) AS decimal(18, 4)), '#', '0%', '100%'),
          (3, 'Schedulers engaged',
              CAST(@EngagedSchedulers AS varchar(10)) + ' of ' + CAST(@SchedulerCount AS varchar(10))
                  + ' (' + CAST(CAST(
                        CAST(@EngagedSchedulers AS decimal(18, 4)) * 100.0
                        / NULLIF(CAST(@SchedulerCount AS decimal(18, 4)), 0)
                     AS decimal(8, 1)) AS varchar(8)) + '%)',
              '0 schedulers', CAST(@SchedulerCount AS varchar(10)) + ' schedulers',
              ISNULL(
                  CAST(
                      CAST(@EngagedSchedulers AS decimal(18, 4)) * 100.0
                      / NULLIF(CAST(@SchedulerCount AS decimal(18, 4)), 0)
                   AS decimal(18, 4)), 0),
              'o', '0', CAST(@SchedulerCount AS varchar(10)))
  ) AS v(SortOrder, MetricLabel, CurrentText, MinText, MaxText, FillPct, BarChar, AxisLeft, AxisRight)

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    @LineNo + ((b.SortOrder - 1) * 3) + v.LineType,
    LEFT(
        CASE v.LineType
            WHEN 1 THEN ' ' + b.MetricLabel
                        + '   CURRENT ' + b.CurrentText
                        + '   MIN ' + b.MinText
                        + '   MAX ' + b.MaxText
            WHEN 2 THEN '   ' + b.AxisLeft + '|'
                        + REPLICATE(b.BarChar, CASE WHEN b.BarFill < 0 THEN 0 WHEN b.BarFill > @BarWidth THEN @BarWidth ELSE b.BarFill END)
                        + REPLICATE('-', CASE WHEN @BarWidth > b.BarFill THEN @BarWidth - b.BarFill ELSE 0 END)
                        + '|' + b.AxisRight
                        + CASE WHEN b.FillPct > 100 THEN '  (>MAX scale)' ELSE '' END
            ELSE @BlankLine
        END,
        @ReportWidth)
  FROM #Bars AS b
 CROSS JOIN (VALUES (1), (2), (3)) AS v(LineType)

SET @LineNo = @LineNo + ((SELECT COUNT(*) FROM #Bars) * 3)

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo, LEFT(@BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(' MEMORY' + @BlankLine, @ReportWidth)),
    (@LineNo + 2, LEFT(@Divider, @ReportWidth))

SET @LineNo = @LineNo + 3

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo, LEFT(' OS memory total (MB)    : ' + CAST(@OsTotalMB AS varchar(12))
                  + '   used ' + CAST(@OsUsedMB AS varchar(12))
                  + '   free ' + CAST(@OsAvailMB AS varchar(12)), @ReportWidth)),
    (@LineNo + 1, LEFT(' SQL committed/target MB : ' + CAST(@SqlCommittedMB AS varchar(12))
                      + ' / ' + CAST(@SqlTargetMB AS varchar(12))
                      + '   max server ' + CAST(@SqlMaxServerMB AS varchar(12)), @ReportWidth)),
    (@LineNo + 2, LEFT(' Page life expectancy    : ' + CAST(ISNULL(@PleSeconds, 0) AS varchar(12)) + ' sec'
                      + '   buffer cache hit    : ' + CAST(ISNULL(@BufferHitPct, 0) AS varchar(8)) + '%'
                      + '   pending mem grants  : ' + CAST(ISNULL(@PendingMemoryGrants, 0) AS varchar(8)), @ReportWidth)),
    (@LineNo + 3, LEFT(@BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 4

TRUNCATE TABLE #Bars

INSERT INTO #Bars (SortOrder, MetricLabel, CurrentText, MinText, MaxText, FillPct, BarChar, AxisLeft, AxisRight, BarFill)
SELECT
    v.SortOrder,
    v.MetricLabel,
    v.CurrentText,
    v.MinText,
    v.MaxText,
    v.FillPct,
    v.BarChar,
    v.AxisLeft,
    v.AxisRight,
    CASE
        WHEN v.FillPct <= 0 THEN 0
        WHEN v.FillPct >= 100 THEN CAST(@BarWidth AS int)
        ELSE
            CASE
                WHEN CAST(ROUND(v.FillPct * CAST(@BarWidth AS decimal(18, 4)) / 100.0, 0) AS int) > @BarWidth
                    THEN CAST(@BarWidth AS int)
                WHEN CAST(ROUND(v.FillPct * CAST(@BarWidth AS decimal(18, 4)) / 100.0, 0) AS int) < 0
                    THEN 0
                ELSE CAST(ROUND(v.FillPct * CAST(@BarWidth AS decimal(18, 4)) / 100.0, 0) AS int)
            END
    END
  FROM (
      VALUES
          (1, 'OS memory used',
              CAST(@OsUsedMB AS varchar(12)) + ' MB (' + LTRIM(STR(ISNULL(@OsUsedPct, 0), 8, 1)) + '%)',
              '0 MB', CAST(@OsTotalMB AS varchar(12)) + ' MB',
              CAST(CASE
                  WHEN ISNULL(@OsUsedPct, 0) > 9999999999999999.9999 THEN 9999999999999999.9999
                  WHEN ISNULL(@OsUsedPct, 0) < 0 THEN 0
                  ELSE ISNULL(@OsUsedPct, 0)
              END AS decimal(18, 4)), 'M', '0 MB', CAST(@OsTotalMB AS varchar(12)) + ' MB'),
          (2, 'SQL mem vs target',
              CAST(@SqlCommittedMB AS varchar(12)) + ' MB (' + LTRIM(STR(ISNULL(@SqlUsedPct, 0), 8, 1)) + '%)',
              '0 MB', CAST(@SqlTargetMB AS varchar(12)) + ' MB target',
              CAST(CASE
                  WHEN ISNULL(@SqlUsedPct, 0) > 9999999999999999.9999 THEN 9999999999999999.9999
                  WHEN ISNULL(@SqlUsedPct, 0) < 0 THEN 0
                  ELSE ISNULL(@SqlUsedPct, 0)
              END AS decimal(18, 4)), 'M', '0 MB', CAST(@SqlTargetMB AS varchar(12)) + ' MB')
  ) AS v(SortOrder, MetricLabel, CurrentText, MinText, MaxText, FillPct, BarChar, AxisLeft, AxisRight)

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    @LineNo + ((b.SortOrder - 1) * 3) + v.LineType,
    LEFT(
        CASE v.LineType
            WHEN 1 THEN ' ' + b.MetricLabel
                        + '   CURRENT ' + b.CurrentText
                        + '   MIN ' + b.MinText
                        + '   MAX ' + b.MaxText
            WHEN 2 THEN '   ' + b.AxisLeft + '|'
                        + REPLICATE(b.BarChar, CASE WHEN b.BarFill < 0 THEN 0 WHEN b.BarFill > @BarWidth THEN @BarWidth ELSE b.BarFill END)
                        + REPLICATE('.', CASE WHEN @BarWidth > b.BarFill THEN @BarWidth - b.BarFill ELSE 0 END)
                        + '|' + b.AxisRight
                        + CASE WHEN b.FillPct > 100 THEN '  (>MAX scale)' ELSE '' END
            ELSE @BlankLine
        END,
        @ReportWidth)
  FROM #Bars AS b
 CROSS JOIN (VALUES (1), (2), (3)) AS v(LineType)

SET @LineNo = @LineNo + ((SELECT COUNT(*) FROM #Bars) * 3)

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo, LEFT(@BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(' WORKLOAD & THROUGHPUT' + @BlankLine, @ReportWidth)),
    (@LineNo + 2, LEFT(@Divider, @ReportWidth)),
    (@LineNo + 3, LEFT(' User connections        : ' + CAST(ISNULL(@UserConnections, 0) AS varchar(12))
                      + '   Active user sessions: ' + CAST(ISNULL(@ActiveSessions, 0) AS varchar(12)), @ReportWidth)),
    (@LineNo + 4, LEFT(' Requests running        : ' + CAST(@RunningRequests AS varchar(12))
                      + '   runnable            : ' + CAST(@RunnableRequests AS varchar(12)), @ReportWidth)),
    (@LineNo + 5, LEFT(' Requests suspended      : ' + CAST(@SuspendedRequests AS varchar(12))
                      + '   blocked             : ' + CAST(@BlockedRequests AS varchar(12)), @ReportWidth)),
    (@LineNo + 6, LEFT(' Rates = counter delta over ' + LTRIM(STR(@ElapsedSec, 6, 1)) + 's sample'
                      + '  |  bars = share of busiest counter' + @BlankLine, @ReportWidth)),
    (@LineNo + 7, LEFT(@BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 8

INSERT INTO #Report ([LineNo], ReportLine)
SELECT
    @LineNo,
    LEFT(
          LEFT('Counter' + @BlankLine, 22)
        + ' ' + LEFT('/sec' + @BlankLine, 8)
        + ' ' + LEFT('Share' + @BlankLine, 6)
        + ' Activity (relative)' + @BlankLine,
        @ReportWidth)
UNION ALL
SELECT
    @LineNo + 1,
    LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT
    @LineNo + 1 + t.SortOrder,
    LEFT(
          LEFT(t.MetricLabel + @BlankLine, 22)
        + ' ' + RIGHT(REPLICATE(' ', 8) + t.RateText, 8)
        + ' ' + RIGHT(REPLICATE(' ', 6) + CAST(CAST(t.SharePct AS decimal(5, 1)) AS varchar(6)) + '%', 6)
        + ' |'
        + REPLICATE('>', CASE WHEN t.BarFill < 0 THEN 0 WHEN t.BarFill > @BarWidth THEN @BarWidth ELSE t.BarFill END)
        + REPLICATE('-', CASE WHEN @BarWidth > t.BarFill THEN @BarWidth - t.BarFill ELSE 0 END)
        + '|',
        @ReportWidth)
  FROM #Throughput AS t

SET @LineNo = @LineNo + 2 + (SELECT COUNT(*) FROM #Throughput)

INSERT INTO #Report ([LineNo], ReportLine)
VALUES
    (@LineNo, LEFT(@BlankLine, @ReportWidth)),
    (@LineNo + 1, LEFT(' READING THE BARS' + @BlankLine, @ReportWidth)),
    (@LineNo + 2, LEFT(@Divider, @ReportWidth)),
    (@LineNo + 3, LEFT(' Each metric shows CURRENT value, then MIN and MAX scale endpoints.' + @BlankLine, @ReportWidth)),
    (@LineNo + 4, LEFT(' The bar line is: MIN|filled portion + empty portion|MAX. Full bar = MAX.' + @BlankLine, @ReportWidth)),
    (@LineNo + 5, LEFT(' CPU % bars: 0% to 100%. Memory bars: 0 MB to total/target MB.' + @BlankLine, @ReportWidth)),
    (@LineNo + 6, LEFT(' Throughput bars compare each counter to the busiest counter in this snapshot.' + @BlankLine, @ReportWidth)),
    (@LineNo + 7, LEFT(' /sec = (sample2 - sample1) / elapsed seconds from perfmon DMVs.' + @BlankLine, @ReportWidth)),
    (@LineNo + 8, LEFT(@HeaderRule, @ReportWidth))

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

GO

IF OBJECT_ID('dbo.ShowServerState') IS NOT NULL
    PRINT 'Procedure created'
ELSE
    PRINT 'Procedure NOT created'
GO