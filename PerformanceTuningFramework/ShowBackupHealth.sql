/*
  ShowBackupHealth.sql
  Performance Tuning Framework

  Requires SQL Server 2012 (11.x) or later on the instance.

  Deploy to the tool database, then execute:
    EXEC dbo.ShowBackupHealth
    EXEC dbo.ShowBackupHealth @LongRunningMinutes = 30, @FullMaxHours = 24
    EXEC dbo.ShowBackupHealth @DatabaseFilter = N'YourDatabase%', @IncludeSystem = 0

  Ranks instance backup problems (long/stalled backups, stale differential
  bases, missing FULL/DIFF/LOG coverage, Agent job failures, slow throughput).
  Complements Procedures/ShowBackups.sql (history report) and
  Procedures/ShowBackupsInProgress (live dm_exec_requests dump).
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowBackupHealth') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowBackupHealth'
    DROP PROCEDURE dbo.ShowBackupHealth
END
GO

PRINT 'Creating: ShowBackupHealth'
GO

CREATE PROCEDURE dbo.ShowBackupHealth
(
    @DatabaseFilter     sysname = N'%',
    @FullMaxHours       int     = 36,
    @DiffMaxHours       int     = 36,
    @LogMaxMinutes      int     = 60,
    @LongRunningMinutes int     = 60,
    @HistoryDays        int     = 14,
    @IncludeSystem      bit     = 0,
    @ReturnResultSets   bit     = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: August 23, 2026
-- Author:       Bill McEvoy
-- Description:  Examines instance backup health and ranks problems with practical suggested
--               actions. Intended for consultants: long-running differentials, stale FULL bases,
--               missing log coverage, failed backup jobs, and slow throughput.
--               Requires SQL Server 2012 (11.x) or later. Does not replace ShowBackups or
--               ShowBackupsInProgress.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion         tinyint,
    @ServerName           sysname,
    @CaptureDate          datetime,
    @HistoryStart         datetime,
    @RunningBackupCount   int,
    @HighPriorityCount    int,
    @DatabaseCount        int,
    @Note                 varchar(400)

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 11
BEGIN
    RAISERROR('ShowBackupHealth requires SQL Server 2012 (11.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

IF @DatabaseFilter IS NULL OR @DatabaseFilter = N''
    SET @DatabaseFilter = N'%'

IF @FullMaxHours < 0
    SET @FullMaxHours = ABS(@FullMaxHours)
IF @FullMaxHours = 0
    SET @FullMaxHours = 36

IF @DiffMaxHours < 0
    SET @DiffMaxHours = ABS(@DiffMaxHours)
IF @DiffMaxHours = 0
    SET @DiffMaxHours = 36

IF @LogMaxMinutes < 0
    SET @LogMaxMinutes = ABS(@LogMaxMinutes)
IF @LogMaxMinutes = 0
    SET @LogMaxMinutes = 60

IF @LongRunningMinutes < 0
    SET @LongRunningMinutes = ABS(@LongRunningMinutes)
IF @LongRunningMinutes = 0
    SET @LongRunningMinutes = 60

IF @HistoryDays < 0
    SET @HistoryDays = ABS(@HistoryDays)
IF @HistoryDays = 0
    SET @HistoryDays = 14

SET @ServerName   = CAST(SERVERPROPERTY('MachineName') AS sysname)
                  + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @CaptureDate  = GETDATE()
SET @HistoryStart = DATEADD(day, -@HistoryDays, @CaptureDate)
SET @Note = 'Review Findings first. An in-flight backup is not usable until it completes. Use ShowBackups for history detail and ShowBackupsInProgress for a raw request dump.'

IF OBJECT_ID('tempdb..#InProgress') IS NOT NULL
    DROP TABLE #InProgress
IF OBJECT_ID('tempdb..#LastBackup') IS NOT NULL
    DROP TABLE #LastBackup
IF OBJECT_ID('tempdb..#BackupJobs') IS NOT NULL
    DROP TABLE #BackupJobs
IF OBJECT_ID('tempdb..#Findings') IS NOT NULL
    DROP TABLE #Findings
IF OBJECT_ID('tempdb..#BackupHist') IS NOT NULL
    DROP TABLE #BackupHist
IF OBJECT_ID('tempdb..#AvgDuration') IS NOT NULL
    DROP TABLE #AvgDuration
IF OBJECT_ID('tempdb..#TypeThroughput') IS NOT NULL
    DROP TABLE #TypeThroughput

CREATE TABLE #InProgress
(
    SessionId                 int            NOT NULL,
    DatabaseName              sysname        NULL,
    Command                   nvarchar(32)   NULL,
    BackupType                char(1)        NULL,
    Status                    nvarchar(30)   NULL,
    StartTime                 datetime       NULL,
    ElapsedMinutes            int            NULL,
    PercentComplete           real           NULL,
    EstimatedRemainingMinutes decimal(18, 2) NULL,
    WaitType                  nvarchar(60)   NULL,
    WaitTimeMs                bigint         NULL,
    BlockingSessionId         int            NULL,
    CpuMs                     int            NULL,
    Reads                     bigint         NULL,
    Writes                    bigint         NULL,
    LogicalReads              bigint         NULL,
    ProgramName               nvarchar(128)  NULL,
    JobName                   sysname        NULL,
    LoginName                 sysname        NULL,
    HostName                  sysname        NULL,
    CommandText               nvarchar(400)  NULL,
    SqlText                   nvarchar(max)  NULL
)

CREATE TABLE #LastBackup
(
    DatabaseName              sysname        NOT NULL,
    DatabaseId                int            NULL,
    RecoveryModel             nvarchar(60)   NULL,
    StateDesc                 nvarchar(60)   NULL,
    SizeMB                    decimal(18, 2) NULL,
    LastFullFinish            datetime       NULL,
    LastFullAgeHours          decimal(18, 2) NULL,
    LastFullDurationSeconds   int            NULL,
    LastFullSizeMB            decimal(18, 2) NULL,
    LastFullCompressedMB      decimal(18, 2) NULL,
    LastFullMBps              decimal(18, 4) NULL,
    LastFullDevice            nvarchar(260)  NULL,
    LastFullIsCopyOnly        bit            NULL,
    LastCopyOnlyFullFinish    datetime       NULL,
    LastDiffFinish            datetime       NULL,
    LastDiffAgeHours          decimal(18, 2) NULL,
    LastDiffDurationSeconds   int            NULL,
    LastDiffSizeMB            decimal(18, 2) NULL,
    LastDiffCompressedMB      decimal(18, 2) NULL,
    LastDiffMBps              decimal(18, 4) NULL,
    LastDiffDevice            nvarchar(260)  NULL,
    LastLogFinish             datetime       NULL,
    LastLogAgeMinutes         decimal(18, 2) NULL,
    LastLogDurationSeconds    int            NULL,
    LastLogSizeMB             decimal(18, 2) NULL,
    LastLogCompressedMB       decimal(18, 2) NULL,
    LastLogMBps               decimal(18, 4) NULL,
    LastLogDevice             nvarchar(260)  NULL,
    HasDiffInHistory          bit            NOT NULL DEFAULT (0)
)

CREATE TABLE #BackupJobs
(
    JobId                     uniqueidentifier NOT NULL,
    JobName                   sysname          NOT NULL,
    Enabled                   bit              NULL,
    StepId                    int              NULL,
    StepName                  sysname          NULL,
    LastRunStart              datetime         NULL,
    LastRunFinish             datetime         NULL,
    LastRunDurationSeconds    int              NULL,
    LastRunStatus             varchar(20)      NULL,
    IsRunning                 bit              NOT NULL DEFAULT (0),
    CurrentRunStart           datetime         NULL,
    CurrentRunElapsedMinutes  int              NULL,
    NextRunTime               datetime         NULL
)

CREATE TABLE #Findings
(
    Severity          tinyint        NOT NULL,
    FindingType       varchar(40)    NOT NULL,
    DatabaseName      sysname        NULL,
    BackupType        varchar(20)    NULL,
    SessionId         int            NULL,
    JobName           sysname        NULL,
    ElapsedMinutes    int            NULL,
    Detail            varchar(2000)  NULL,
    SuggestedAction   varchar(4000)  NULL
)

CREATE TABLE #BackupHist
(
    DatabaseName         sysname        NOT NULL,
    BackupType           char(1)        NOT NULL,
    IsCopyOnly           bit            NOT NULL,
    BackupStartDate      datetime       NULL,
    BackupFinishDate     datetime       NULL,
    DurationSeconds      int            NULL,
    BackupSizeMB         decimal(18, 2) NULL,
    CompressedSizeMB     decimal(18, 2) NULL,
    MBps                 decimal(18, 4) NULL,
    DevicePath           nvarchar(260)  NULL,
    RnType               int            NULL,
    RnRealType           int            NULL,
    RnCopyOnlyFull       int            NULL
)

CREATE TABLE #AvgDuration
(
    DatabaseName         sysname NOT NULL,
    BackupType           char(1) NOT NULL,
    SampleCount          int     NULL,
    AvgDurationSeconds   int     NULL
)

CREATE TABLE #TypeThroughput
(
    BackupType           char(1)        NOT NULL,
    AvgMBps              decimal(18, 4) NULL,
    SampleCount          int            NULL
)

---------------------------------------------------------------------
-- In-progress BACKUP requests
---------------------------------------------------------------------

INSERT #InProgress
(
    SessionId, DatabaseName, Command, BackupType, Status, StartTime, ElapsedMinutes,
    PercentComplete, EstimatedRemainingMinutes, WaitType, WaitTimeMs, BlockingSessionId,
    CpuMs, Reads, Writes, LogicalReads, ProgramName, JobName, LoginName, HostName,
    CommandText, SqlText
)
SELECT
    SessionId = r.session_id,
    DatabaseName = DB_NAME(r.database_id),
    Command = r.command,
    BackupType = CASE
                     WHEN r.command LIKE N'%LOG%' THEN 'L'
                     WHEN ISNULL(st.text, N'') LIKE N'%DIFFERENTIAL%' THEN 'I'
                     ELSE 'D'
                 END,
    Status = r.status,
    StartTime = r.start_time,
    ElapsedMinutes = DATEDIFF(minute, r.start_time, @CaptureDate),
    PercentComplete = r.percent_complete,
    EstimatedRemainingMinutes = CASE
                                    WHEN r.estimated_completion_time IS NULL THEN NULL
                                    ELSE CAST(r.estimated_completion_time / 60000.0 AS decimal(18, 2))
                                END,
    WaitType = r.wait_type,
    WaitTimeMs = r.wait_time,
    BlockingSessionId = r.blocking_session_id,
    CpuMs = r.cpu_time,
    Reads = r.reads,
    Writes = r.writes,
    LogicalReads = r.logical_reads,
    ProgramName = s.program_name,
    JobName = CASE
                  WHEN s.program_name LIKE N'SQLAgent - TSQL JobStep (Job 0x%'
                   AND LEN(s.program_name) >= 63
                      THEN
                      (
                          SELECT j.name
                            FROM msdb.dbo.sysjobs AS j
                           WHERE j.job_id = CAST(CONVERT(binary(16), SUBSTRING(s.program_name, 30, 34), 1) AS uniqueidentifier)
                      )
                  ELSE NULL
              END,
    LoginName = s.login_name,
    HostName = s.host_name,
    CommandText = LEFT(st.text, 400),
    SqlText = st.text
  FROM sys.dm_exec_requests AS r
  LEFT JOIN sys.dm_exec_sessions AS s
    ON s.session_id = r.session_id
 OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
 WHERE r.command LIKE N'%BACKUP%'

UPDATE i
   SET DatabaseName = x.ParsedName,
       BackupType = CASE
                        WHEN i.Command LIKE N'%LOG%' OR ISNULL(i.SqlText, N'') LIKE N'%BACKUP LOG%' THEN 'L'
                        WHEN ISNULL(i.SqlText, N'') LIKE N'%DIFFERENTIAL%' THEN 'I'
                        ELSE i.BackupType
                    END
  FROM #InProgress AS i
 CROSS APPLY
 (
    SELECT
        KeywordPos = CASE
                         WHEN PATINDEX('%BACKUP DATABASE%', UPPER(ISNULL(i.SqlText, N''))) > 0
                             THEN PATINDEX('%BACKUP DATABASE%', UPPER(ISNULL(i.SqlText, N''))) + 15
                         WHEN PATINDEX('%BACKUP LOG%', UPPER(ISNULL(i.SqlText, N''))) > 0
                             THEN PATINDEX('%BACKUP LOG%', UPPER(ISNULL(i.SqlText, N''))) + 10
                         ELSE 0
                     END
 ) AS k
 CROSS APPLY
 (
    SELECT
        NameStart = CASE
                        WHEN k.KeywordPos = 0 THEN 0
                        ELSE k.KeywordPos
                             + PATINDEX('%[^ ' + CHAR(9) + CHAR(13) + CHAR(10) + ']%',
                                        SUBSTRING(i.SqlText + N'x', k.KeywordPos, 200) + N'x') - 1
                    END
 ) AS n
 CROSS APPLY
 (
    SELECT ParsedName =
        CASE
            WHEN n.NameStart <= 0 THEN NULL
            WHEN SUBSTRING(i.SqlText, n.NameStart, 1) = N'['
                THEN SUBSTRING(i.SqlText, n.NameStart + 1,
                               NULLIF(CHARINDEX(N']', i.SqlText, n.NameStart + 1), 0) - n.NameStart - 1)
            WHEN SUBSTRING(i.SqlText, n.NameStart, 1) = N'@'
                THEN NULL
            ELSE LEFT(SUBSTRING(i.SqlText, n.NameStart, 128),
                      NULLIF(PATINDEX('%[^A-Za-z0-9_#.$]%', SUBSTRING(i.SqlText, n.NameStart, 128) + N' '), 0) - 1)
        END
 ) AS x
 WHERE (i.DatabaseName IS NULL OR i.DatabaseName IN (N'master', N'tempdb', N'msdb', N'model'))
   AND NULLIF(LTRIM(RTRIM(x.ParsedName)), N'') IS NOT NULL

---------------------------------------------------------------------
-- Backup history (400-day lookback so last FULL/DIFF/LOG is visible)
---------------------------------------------------------------------

INSERT #BackupHist
(
    DatabaseName, BackupType, IsCopyOnly, BackupStartDate, BackupFinishDate,
    DurationSeconds, BackupSizeMB, CompressedSizeMB, MBps, DevicePath,
    RnType, RnRealType, RnCopyOnlyFull
)
SELECT
    DatabaseName = bs.database_name,
    BackupType = bs.type,
    IsCopyOnly = bs.is_copy_only,
    BackupStartDate = bs.backup_start_date,
    BackupFinishDate = bs.backup_finish_date,
    DurationSeconds = DATEDIFF(second, bs.backup_start_date, bs.backup_finish_date),
    BackupSizeMB = CAST(bs.backup_size / 1024.0 / 1024.0 AS decimal(18, 2)),
    CompressedSizeMB = CAST(ISNULL(bs.compressed_backup_size, bs.backup_size) / 1024.0 / 1024.0 AS decimal(18, 2)),
    MBps = CAST(
               (ISNULL(NULLIF(bs.compressed_backup_size, 0), bs.backup_size) / 1024.0 / 1024.0)
               / NULLIF(DATEDIFF(second, bs.backup_start_date, bs.backup_finish_date), 0)
               AS decimal(18, 4)),
    DevicePath = dev.physical_device_name,
    RnType = ROW_NUMBER() OVER (
                 PARTITION BY bs.database_name, bs.type
                 ORDER BY bs.backup_finish_date DESC),
    RnRealType = CASE
                     WHEN bs.is_copy_only = 0
                         THEN ROW_NUMBER() OVER (
                                  PARTITION BY bs.database_name, bs.type, bs.is_copy_only
                                  ORDER BY bs.backup_finish_date DESC)
                     ELSE NULL
                 END,
    RnCopyOnlyFull = CASE
                         WHEN bs.type = 'D' AND bs.is_copy_only = 1
                             THEN ROW_NUMBER() OVER (
                                      PARTITION BY bs.database_name, bs.type, bs.is_copy_only
                                      ORDER BY bs.backup_finish_date DESC)
                         ELSE NULL
                     END
  FROM msdb.dbo.backupset AS bs
 OUTER APPLY
 (
    SELECT TOP 1
           bmf.physical_device_name
      FROM msdb.dbo.backupmediafamily AS bmf
     WHERE bmf.media_set_id = bs.media_set_id
     ORDER BY bmf.family_sequence_number
 ) AS dev
 WHERE bs.type IN ('D', 'I', 'L')
   AND bs.backup_finish_date IS NOT NULL
   AND bs.backup_finish_date >= DATEADD(day, -400, @CaptureDate)

INSERT #AvgDuration
(
    DatabaseName, BackupType, SampleCount, AvgDurationSeconds
)
SELECT
    h.DatabaseName,
    h.BackupType,
    COUNT(*),
    AVG(h.DurationSeconds)
  FROM
  (
    SELECT
        DatabaseName,
        BackupType,
        DurationSeconds,
        Rn = ROW_NUMBER() OVER (
                 PARTITION BY DatabaseName, BackupType
                 ORDER BY BackupFinishDate DESC)
      FROM #BackupHist
     WHERE DurationSeconds > 0
       AND IsCopyOnly = 0
  ) AS h
 WHERE h.Rn <= 8
 GROUP BY h.DatabaseName, h.BackupType

INSERT #TypeThroughput
(
    BackupType, AvgMBps, SampleCount
)
SELECT
    BackupType,
    AVG(MBps),
    COUNT(*)
  FROM #BackupHist
 WHERE BackupFinishDate >= @HistoryStart
   AND DurationSeconds > 0
   AND MBps IS NOT NULL
 GROUP BY BackupType

---------------------------------------------------------------------
-- Last backup by database
---------------------------------------------------------------------

INSERT #LastBackup
(
    DatabaseName, DatabaseId, RecoveryModel, StateDesc, SizeMB,
    LastFullFinish, LastFullAgeHours, LastFullDurationSeconds,
    LastFullSizeMB, LastFullCompressedMB, LastFullMBps, LastFullDevice, LastFullIsCopyOnly,
    LastCopyOnlyFullFinish,
    LastDiffFinish, LastDiffAgeHours, LastDiffDurationSeconds,
    LastDiffSizeMB, LastDiffCompressedMB, LastDiffMBps, LastDiffDevice,
    LastLogFinish, LastLogAgeMinutes, LastLogDurationSeconds,
    LastLogSizeMB, LastLogCompressedMB, LastLogMBps, LastLogDevice,
    HasDiffInHistory
)
SELECT
    DatabaseName = d.name,
    DatabaseId = d.database_id,
    RecoveryModel = d.recovery_model_desc,
    StateDesc = d.state_desc,
    SizeMB = CAST(f.SizePages * 8.0 / 1024.0 AS decimal(18, 2)),
    LastFullFinish = lf.BackupFinishDate,
    LastFullAgeHours = CAST(DATEDIFF(minute, lf.BackupFinishDate, @CaptureDate) / 60.0 AS decimal(18, 2)),
    LastFullDurationSeconds = lf.DurationSeconds,
    LastFullSizeMB = lf.BackupSizeMB,
    LastFullCompressedMB = lf.CompressedSizeMB,
    LastFullMBps = lf.MBps,
    LastFullDevice = lf.DevicePath,
    LastFullIsCopyOnly = CAST(lad.IsCopyOnly AS bit),
    LastCopyOnlyFullFinish = lcf.BackupFinishDate,
    LastDiffFinish = ld.BackupFinishDate,
    LastDiffAgeHours = CAST(DATEDIFF(minute, ld.BackupFinishDate, @CaptureDate) / 60.0 AS decimal(18, 2)),
    LastDiffDurationSeconds = ld.DurationSeconds,
    LastDiffSizeMB = ld.BackupSizeMB,
    LastDiffCompressedMB = ld.CompressedSizeMB,
    LastDiffMBps = ld.MBps,
    LastDiffDevice = ld.DevicePath,
    LastLogFinish = ll.BackupFinishDate,
    LastLogAgeMinutes = CAST(DATEDIFF(minute, ll.BackupFinishDate, @CaptureDate) AS decimal(18, 2)),
    LastLogDurationSeconds = ll.DurationSeconds,
    LastLogSizeMB = ll.BackupSizeMB,
    LastLogCompressedMB = ll.CompressedSizeMB,
    LastLogMBps = ll.MBps,
    LastLogDevice = ll.DevicePath,
    HasDiffInHistory = CASE
                           WHEN EXISTS
                           (
                               SELECT 1
                                 FROM #BackupHist AS hx
                                WHERE hx.DatabaseName = d.name
                                  AND hx.BackupType = 'I'
                                  AND hx.BackupFinishDate >= @HistoryStart
                           )
                               THEN 1
                           ELSE 0
                       END
  FROM sys.databases AS d
  LEFT JOIN
  (
      SELECT database_id, SizePages = SUM(CAST(size AS bigint))
        FROM sys.master_files
       GROUP BY database_id
  ) AS f
    ON f.database_id = d.database_id
 OUTER APPLY
 (
    SELECT TOP 1 h.*
      FROM #BackupHist AS h
     WHERE h.DatabaseName = d.name
       AND h.BackupType = 'D'
       AND h.IsCopyOnly = 0
       AND h.RnRealType = 1
 ) AS lf
 OUTER APPLY
 (
    SELECT TOP 1 h.*
      FROM #BackupHist AS h
     WHERE h.DatabaseName = d.name
       AND h.RnCopyOnlyFull = 1
 ) AS lcf
 OUTER APPLY
 (
    SELECT TOP 1 h.*
      FROM #BackupHist AS h
     WHERE h.DatabaseName = d.name
       AND h.BackupType = 'D'
       AND h.RnType = 1
 ) AS lad
 OUTER APPLY
 (
    SELECT TOP 1 h.*
      FROM #BackupHist AS h
     WHERE h.DatabaseName = d.name
       AND h.BackupType = 'I'
       AND h.IsCopyOnly = 0
       AND h.RnRealType = 1
 ) AS ld
 OUTER APPLY
 (
    SELECT TOP 1 h.*
      FROM #BackupHist AS h
     WHERE h.DatabaseName = d.name
       AND h.BackupType = 'L'
       AND h.IsCopyOnly = 0
       AND h.RnRealType = 1
 ) AS ll
 WHERE d.name <> N'tempdb'
   AND d.name LIKE @DatabaseFilter
   AND (
           @IncludeSystem = 1
        OR d.name NOT IN (N'master', N'model', N'msdb')
       )

---------------------------------------------------------------------
-- Agent jobs whose step command contains BACKUP
---------------------------------------------------------------------

INSERT #BackupJobs
(
    JobId, JobName, Enabled, StepId, StepName,
    LastRunStart, LastRunFinish, LastRunDurationSeconds, LastRunStatus,
    IsRunning, CurrentRunStart, CurrentRunElapsedMinutes, NextRunTime
)
SELECT
    JobId = j.job_id,
    JobName = j.name,
    Enabled = j.enabled,
    StepId = js.step_id,
    StepName = js.step_name,
    LastRunStart = hist.RunStart,
    LastRunFinish = CASE
                        WHEN hist.RunStart IS NULL OR hist.DurationSeconds IS NULL THEN NULL
                        ELSE DATEADD(second, hist.DurationSeconds, hist.RunStart)
                    END,
    LastRunDurationSeconds = hist.DurationSeconds,
    LastRunStatus = hist.StatusText,
    IsRunning = CASE
                    WHEN act.start_execution_date IS NOT NULL
                     AND act.stop_execution_date IS NULL
                        THEN 1
                    ELSE 0
                END,
    CurrentRunStart = CASE
                          WHEN act.start_execution_date IS NOT NULL
                           AND act.stop_execution_date IS NULL
                              THEN act.start_execution_date
                          ELSE NULL
                      END,
    CurrentRunElapsedMinutes = CASE
                                   WHEN act.start_execution_date IS NOT NULL
                                    AND act.stop_execution_date IS NULL
                                       THEN DATEDIFF(minute, act.start_execution_date, @CaptureDate)
                                   ELSE NULL
                               END,
    NextRunTime = COALESCE(act.next_scheduled_run_date, sched.NextRun)
  FROM msdb.dbo.sysjobs AS j
  INNER JOIN msdb.dbo.sysjobsteps AS js
    ON js.job_id = j.job_id
  LEFT JOIN
  (
      SELECT job_id, session_id = MAX(session_id)
        FROM msdb.dbo.sysjobactivity
       GROUP BY job_id
  ) AS actid
    ON actid.job_id = j.job_id
  LEFT JOIN msdb.dbo.sysjobactivity AS act
    ON act.job_id = actid.job_id
   AND act.session_id = actid.session_id
 OUTER APPLY
 (
    SELECT TOP 1
           RunStart = DATEADD(second,
                              (h.run_time / 10000) * 3600
                              + ((h.run_time / 100) % 100) * 60
                              + (h.run_time % 100),
                              CONVERT(datetime, CONVERT(char(8), h.run_date))),
           DurationSeconds = (h.run_duration / 10000) * 3600
                             + ((h.run_duration / 100) % 100) * 60
                             + (h.run_duration % 100),
           StatusText = CASE h.run_status
                            WHEN 0 THEN 'Failed'
                            WHEN 1 THEN 'Succeeded'
                            WHEN 2 THEN 'Retry'
                            WHEN 3 THEN 'Canceled'
                            WHEN 4 THEN 'InProgress'
                            ELSE 'Unknown'
                        END
      FROM msdb.dbo.sysjobhistory AS h
     WHERE h.job_id = j.job_id
       AND h.step_id IN (0, js.step_id)
       AND h.run_date > 0
     ORDER BY h.run_date DESC, h.run_time DESC, CASE WHEN h.step_id = 0 THEN 0 ELSE 1 END
 ) AS hist
 OUTER APPLY
 (
    SELECT TOP 1
           NextRun = CASE
                         WHEN sjs.next_run_date IS NULL OR sjs.next_run_date = 0 THEN NULL
                         ELSE DATEADD(second,
                                      (sjs.next_run_time / 10000) * 3600
                                      + ((sjs.next_run_time / 100) % 100) * 60
                                      + (sjs.next_run_time % 100),
                                      CONVERT(datetime, CONVERT(char(8), sjs.next_run_date)))
                     END
      FROM msdb.dbo.sysjobschedules AS sjs
     WHERE sjs.job_id = j.job_id
     ORDER BY CASE WHEN sjs.next_run_date = 0 THEN 1 ELSE 0 END,
              sjs.next_run_date,
              sjs.next_run_time
 ) AS sched
 WHERE UPPER(js.command) LIKE N'%BACKUP%'

---------------------------------------------------------------------
-- Findings
---------------------------------------------------------------------

-- BACKUP_RUNNING_LONG
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = CASE
                   WHEN i.ElapsedMinutes >= 240 THEN 3
                   WHEN a.AvgDurationSeconds IS NOT NULL
                    AND i.ElapsedMinutes * 60 >= 3 * a.AvgDurationSeconds THEN 3
                   ELSE 2
               END,
    FindingType = 'BACKUP_RUNNING_LONG',
    DatabaseName = i.DatabaseName,
    BackupType = CASE i.BackupType WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE i.Command END,
    SessionId = i.SessionId,
    JobName = i.JobName,
    ElapsedMinutes = i.ElapsedMinutes,
    Detail = 'Session ' + CONVERT(varchar(11), i.SessionId)
           + ' has been running a '
           + CASE i.BackupType WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE ISNULL(i.Command, 'BACKUP') END
           + ' backup of '
           + ISNULL(CONVERT(varchar(128), i.DatabaseName), '(unknown)')
           + ' for '
           + CONVERT(varchar(12), i.ElapsedMinutes)
           + ' minutes ('
           + CONVERT(varchar(12), CONVERT(decimal(10, 1), i.ElapsedMinutes / 60.0))
           + ' hours). percent_complete='
           + ISNULL(CONVERT(varchar(12), CONVERT(decimal(10, 2), i.PercentComplete)), 'NULL')
           + ', wait='
           + ISNULL(i.WaitType, '(none)')
           + CASE
                 WHEN a.AvgDurationSeconds IS NOT NULL
                     THEN ', historical avg duration '
                          + CONVERT(varchar(12), a.AvgDurationSeconds)
                          + ' seconds ('
                          + CONVERT(varchar(6), a.SampleCount)
                          + ' samples)'
                 ELSE ''
             END
           + '.',
    SuggestedAction =
        CASE
            WHEN ISNULL(i.PercentComplete, 0) > 0
                THEN 'Do not KILL this session. percent_complete is '
                     + CONVERT(varchar(12), CONVERT(decimal(10, 2), i.PercentComplete))
                     + ' so the backup is advancing; an in-flight backup is not usable until it finishes. '
            WHEN ISNULL(i.PercentComplete, 0) = 0 AND i.ElapsedMinutes >= 30
                THEN 'percent_complete is still 0 after '
                     + CONVERT(varchar(12), i.ElapsedMinutes)
                     + ' minutes. If it stays at 0, you can KILL session '
                     + CONVERT(varchar(11), i.SessionId)
                     + ' and take a FULL instead; the in-flight backup file is not usable. '
            ELSE 'Watch percent_complete before considering KILL. An in-flight backup is not usable until it completes. '
        END
      + CASE
            WHEN i.WaitType LIKE 'BACKUPIO%' OR i.WaitType = 'ASYNC_IO_COMPLETION'
                THEN 'Wait ' + i.WaitType + ' points at the destination (UNC share, disk, or backup device). Check free space, network, and whether the target is queued or offline. '
            WHEN i.WaitType LIKE 'BACKUPBUFFER%' OR i.WaitType LIKE 'BACKUPTHREAD%'
                THEN 'Wait ' + i.WaitType + ' points at backup buffers or CPU. This is usually secondary to destination speed. '
            WHEN i.WaitType LIKE 'LCK_%'
                THEN 'Wait ' + i.WaitType + ' means the backup is blocked. Inspect blocking_session_id '
                     + ISNULL(CONVERT(varchar(11), NULLIF(i.BlockingSessionId, 0)), '(none)')
                     + ' before you touch the backup session. '
            WHEN i.WaitType LIKE 'PREEMPTIVE_OS_%'
                THEN 'Wait ' + i.WaitType + ' is an OS/network call (file create, share, memory). Check the destination path and OS errors. '
            WHEN i.WaitType IS NOT NULL
                THEN 'Current wait is ' + i.WaitType + '. '
            ELSE ''
        END
      + CASE
            WHEN i.BackupType = 'I'
                THEN 'If the last non-copy-only FULL is old, take a new FULL after this DIFF finishes (or instead of it, if it is stalled) so the next differential is small. '
            ELSE 'After this finishes, confirm the backup completed in msdb and that the next scheduled run will not overlap. '
        END
      + CASE
            WHEN i.JobName IS NOT NULL
                THEN 'Check Agent job [' + CONVERT(varchar(128), i.JobName) + '] so it does not start another overlapping backup. '
            ELSE 'If this came from an Agent job, confirm the job is not scheduled to stack another run. '
        END
      + 'Compression, striping, BUFFERCOUNT, and MAXTRANSFERSIZE are next-run tuning only — do not treat them as the first step while this session is still running.'
  FROM #InProgress AS i
  LEFT JOIN #AvgDuration AS a
    ON a.DatabaseName = i.DatabaseName
   AND a.BackupType = i.BackupType
 WHERE i.ElapsedMinutes >= @LongRunningMinutes
   AND (
           i.DatabaseName IS NULL
        OR i.DatabaseName LIKE @DatabaseFilter
       )
   AND (
           @IncludeSystem = 1
        OR ISNULL(i.DatabaseName, N'') NOT IN (N'master', N'model', N'msdb', N'tempdb')
        OR i.DatabaseName IS NULL
       )

-- BACKUP_STALLED
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'BACKUP_STALLED',
    DatabaseName = i.DatabaseName,
    BackupType = CASE i.BackupType WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE i.Command END,
    SessionId = i.SessionId,
    JobName = i.JobName,
    ElapsedMinutes = i.ElapsedMinutes,
    Detail = 'Session ' + CONVERT(varchar(11), i.SessionId)
           + ' backup of '
           + ISNULL(CONVERT(varchar(128), i.DatabaseName), '(unknown)')
           + ' looks stalled. elapsed='
           + CONVERT(varchar(12), i.ElapsedMinutes)
           + ' minutes, percent_complete='
           + ISNULL(CONVERT(varchar(12), CONVERT(decimal(10, 2), i.PercentComplete)), 'NULL')
           + ', wait='
           + ISNULL(i.WaitType, '(none)')
           + ', wait_time_ms='
           + ISNULL(CONVERT(varchar(20), i.WaitTimeMs), 'NULL')
           + '.',
    SuggestedAction =
        'This backup does not appear to be making progress. '
      + CASE
            WHEN i.WaitType LIKE 'BACKUPIO%' OR i.WaitType = 'ASYNC_IO_COMPLETION'
                THEN 'Wait ' + i.WaitType + ' usually means the destination (UNC/disk) is not accepting writes. '
            WHEN i.WaitType LIKE 'PREEMPTIVE_OS_%'
                THEN 'Wait ' + i.WaitType + ' is an OS/network call — check the share, permissions, and disk. '
            WHEN i.WaitType LIKE 'LCK_%'
                THEN 'Clear the blocker (session '
                     + ISNULL(CONVERT(varchar(11), NULLIF(i.BlockingSessionId, 0)), '?')
                     + ') before killing the backup. '
            WHEN i.WaitType LIKE 'BACKUPBUFFER%' OR i.WaitType LIKE 'BACKUPTHREAD%'
                THEN 'Wait ' + i.WaitType + ' is buffers/CPU; confirm it is truly stuck and not just slow. '
            ELSE ''
        END
      + CASE
            WHEN ISNULL(i.PercentComplete, 0) = 0 AND i.ElapsedMinutes >= 30
                THEN 'percent_complete has been 0 for '
                     + CONVERT(varchar(12), i.ElapsedMinutes)
                     + ' minutes. You can KILL session '
                     + CONVERT(varchar(11), i.SessionId)
                     + '; the in-flight backup is not usable. Then take a FULL (not another DIFF) to reset the differential base. '
            ELSE 'If percent_complete stays under 1% and the wait does not move, KILL session '
                 + CONVERT(varchar(11), i.SessionId)
                 + ' and take a FULL. The in-flight backup is not usable. '
        END
      + CASE
            WHEN i.JobName IS NOT NULL
                THEN 'Stop or idle Agent job [' + CONVERT(varchar(128), i.JobName) + '] so it does not stack another run. '
            ELSE 'Make sure the backup job will not start again on top of this. '
        END
      + 'Leave BUFFERCOUNT/MAXTRANSFERSIZE/striping/compression for the next successful run.'
  FROM #InProgress AS i
 WHERE (
           (ISNULL(i.PercentComplete, 0) = 0 AND i.ElapsedMinutes >= 30)
        OR (
               i.ElapsedMinutes >= @LongRunningMinutes
           AND ISNULL(i.PercentComplete, 0) < 1
           AND (
                   i.WaitType IN (N'BACKUPIO', N'ASYNC_IO_COMPLETION')
                OR i.WaitType LIKE N'PREEMPTIVE_OS_%'
               )
           )
       )
   AND (
           i.DatabaseName IS NULL
        OR i.DatabaseName LIKE @DatabaseFilter
       )
   AND (
           @IncludeSystem = 1
        OR ISNULL(i.DatabaseName, N'') NOT IN (N'master', N'model', N'msdb', N'tempdb')
        OR i.DatabaseName IS NULL
       )

-- DIFF_BASE_STALE
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'DIFF_BASE_STALE',
    DatabaseName = b.DatabaseName,
    BackupType = 'DIFF',
    SessionId = i.SessionId,
    JobName = i.JobName,
    ElapsedMinutes = i.ElapsedMinutes,
    Detail = 'Database '
           + CONVERT(varchar(128), b.DatabaseName)
           + CASE
                 WHEN i.SessionId IS NOT NULL
                     THEN ' has a DIFF running (session '
                          + CONVERT(varchar(11), i.SessionId)
                          + ', '
                          + CONVERT(varchar(12), i.ElapsedMinutes)
                          + ' minutes).'
                 ELSE ' has a completed DIFF.'
             END
           + CASE
                 WHEN b.LastFullFinish IS NULL
                     THEN ' No non-copy-only FULL was found in the 400-day lookback.'
                 ELSE ' Last non-copy-only FULL finished '
                      + CONVERT(varchar(19), b.LastFullFinish, 120)
                      + ' ('
                      + CONVERT(varchar(12), b.LastFullAgeHours)
                      + ' hours ago; threshold '
                      + CONVERT(varchar(12), @FullMaxHours)
                      + ' hours).'
             END,
    SuggestedAction =
        'A differential backup copies every page changed since the last non-copy-only FULL (the differential base / changed-page map). '
      + 'When that FULL is old, the DIFF grows toward FULL size and can run for many hours. '
      + CASE
            WHEN i.SessionId IS NOT NULL AND ISNULL(i.PercentComplete, 0) > 0
                THEN 'Let the current DIFF finish — do not KILL it while percent_complete is advancing. After it completes, take a new FULL so the next DIFF is small. '
            WHEN i.SessionId IS NOT NULL AND ISNULL(i.PercentComplete, 0) = 0 AND i.ElapsedMinutes >= 30
                THEN 'This DIFF looks stalled at 0%. KILL session '
                     + CONVERT(varchar(11), i.SessionId)
                     + ' (the in-flight backup is not usable) and take a FULL instead of another DIFF. '
            WHEN i.SessionId IS NOT NULL
                THEN 'When this DIFF ends, take a new FULL before the next differential window. '
            ELSE 'Take a new non-copy-only FULL now so the next DIFF is small. '
        END
      + CASE
            WHEN i.JobName IS NOT NULL
                THEN 'Check job [' + CONVERT(varchar(128), i.JobName) + '] so another DIFF does not start on the same stale base. '
            ELSE 'Check the DIFF job schedule so it does not stack another run on the stale base. '
        END
      + 'Compression, striping, BUFFERCOUNT, and MAXTRANSFERSIZE can help the next run; they will not shrink a DIFF whose FULL base is days old.'
  FROM #LastBackup AS b
  LEFT JOIN #InProgress AS i
    ON i.DatabaseName = b.DatabaseName
   AND i.BackupType = 'I'
 WHERE (
           EXISTS (SELECT 1 FROM #InProgress AS ix WHERE ix.DatabaseName = b.DatabaseName AND ix.BackupType = 'I')
        OR b.LastDiffFinish IS NOT NULL
       )
   AND (
           b.LastFullFinish IS NULL
        OR b.LastFullAgeHours > @FullMaxHours
       )

-- DIFF_SLOWER_THAN_FULL
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 2,
    FindingType = 'DIFF_SLOWER_THAN_FULL',
    DatabaseName = b.DatabaseName,
    BackupType = 'DIFF',
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Last completed DIFF for '
           + CONVERT(varchar(128), b.DatabaseName)
           + ' took '
           + CONVERT(varchar(12), b.LastDiffDurationSeconds)
           + ' seconds versus last completed FULL '
           + CONVERT(varchar(12), b.LastFullDurationSeconds)
           + ' seconds (DIFF size '
           + ISNULL(CONVERT(varchar(20), b.LastDiffSizeMB), '?')
           + ' MB, FULL size '
           + ISNULL(CONVERT(varchar(20), b.LastFullSizeMB), '?')
           + ' MB).',
    SuggestedAction =
        'A differential that takes longer than a FULL is a strong sign the differential base is stale or the destination is slower than when the FULL ran. '
      + 'Take a fresh non-copy-only FULL (after any in-flight backup finishes) and compare the next DIFF. '
      + 'Do not add BUFFERCOUNT/MAXTRANSFERSIZE until the base is current; those are next-run knobs only.'
  FROM #LastBackup AS b
 WHERE b.LastDiffDurationSeconds IS NOT NULL
   AND b.LastFullDurationSeconds IS NOT NULL
   AND b.LastDiffDurationSeconds > b.LastFullDurationSeconds

-- NO_RECENT_FULL
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'NO_RECENT_FULL',
    DatabaseName = b.DatabaseName,
    BackupType = 'FULL',
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Online database '
           + CONVERT(varchar(128), b.DatabaseName)
           + CASE
                 WHEN b.LastFullFinish IS NULL
                     THEN ' has no non-copy-only FULL in the 400-day lookback.'
                 ELSE ' last non-copy-only FULL finished '
                      + CONVERT(varchar(19), b.LastFullFinish, 120)
                      + ' ('
                      + CONVERT(varchar(12), b.LastFullAgeHours)
                      + ' hours ago; threshold '
                      + CONVERT(varchar(12), @FullMaxHours)
                      + ').'
             END
           + CASE
                 WHEN b.LastCopyOnlyFullFinish IS NOT NULL
                     THEN ' Last copy-only FULL: ' + CONVERT(varchar(19), b.LastCopyOnlyFullFinish, 120) + '.'
                 ELSE ''
             END,
    SuggestedAction =
        'Take a non-copy-only FULL for ['
      + CONVERT(varchar(128), b.DatabaseName)
      + '] (after any in-flight backup completes, or instead of a stalled DIFF). '
      + 'Copy-only fulls do not reset the differential base. '
      + 'Confirm the backup job is enabled and writing to a reachable destination. '
      + 'Compression/striping are optional for the next run, not a substitute for taking the FULL.'
  FROM #LastBackup AS b
 WHERE b.StateDesc = N'ONLINE'
   AND (
           b.LastFullFinish IS NULL
        OR b.LastFullAgeHours > @FullMaxHours
       )

-- NO_RECENT_DIFF
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 2,
    FindingType = 'NO_RECENT_DIFF',
    DatabaseName = b.DatabaseName,
    BackupType = 'DIFF',
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), b.DatabaseName)
           + ' uses differentials (seen in the last '
           + CONVERT(varchar(6), @HistoryDays)
           + ' days) but the last DIFF finished '
           + ISNULL(CONVERT(varchar(19), b.LastDiffFinish, 120), '(never in lookback)')
           + CASE
                 WHEN b.LastDiffAgeHours IS NULL THEN ''
                 ELSE ' (' + CONVERT(varchar(12), b.LastDiffAgeHours) + ' hours ago)'
             END
           + '; threshold '
           + CONVERT(varchar(12), @DiffMaxHours)
           + ' hours. Last real FULL: '
           + ISNULL(CONVERT(varchar(19), b.LastFullFinish, 120), '(none)')
           + '.',
    SuggestedAction =
        'This database has a differential history, so a missed DIFF is a coverage gap, not a SIMPLE/small database that never uses them. '
      + 'If a DIFF is running now, let it finish (or replace it with a FULL if stalled). '
      + 'Otherwise run a DIFF only if the last non-copy-only FULL is recent; if the FULL is older than '
      + CONVERT(varchar(12), @FullMaxHours)
      + ' hours, take a FULL first so the DIFF stays small. Check the Agent job did not fail or skip.'
  FROM #LastBackup AS b
 WHERE b.LastFullFinish IS NOT NULL
   AND b.HasDiffInHistory = 1
   AND (
           b.LastDiffFinish IS NULL
        OR b.LastDiffAgeHours > @DiffMaxHours
       )

-- NO_RECENT_LOG
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'NO_RECENT_LOG',
    DatabaseName = b.DatabaseName,
    BackupType = 'LOG',
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), b.DatabaseName)
           + ' is '
           + CONVERT(varchar(60), b.RecoveryModel)
           + ' and ONLINE. Last LOG backup: '
           + ISNULL(CONVERT(varchar(19), b.LastLogFinish, 120), '(none in lookback)')
           + CASE
                 WHEN b.LastLogAgeMinutes IS NULL THEN ''
                 ELSE ' (' + CONVERT(varchar(12), b.LastLogAgeMinutes) + ' minutes ago)'
             END
           + '; threshold '
           + CONVERT(varchar(12), @LogMaxMinutes)
           + ' minutes.',
    SuggestedAction =
        'Take a transaction-log backup for ['
      + CONVERT(varchar(128), b.DatabaseName)
      + '] now to protect against data loss and to keep the log from growing. '
      + 'Confirm the log-backup job is enabled, not blocked by a long FULL/DIFF, and not writing copy-only-only backups. '
      + 'If a large backup is running, let it finish unless it is stalled; log backups can usually run concurrently but may be slower.'
  FROM #LastBackup AS b
 WHERE b.StateDesc = N'ONLINE'
   AND b.RecoveryModel IN (N'FULL', N'BULK_LOGGED')
   AND b.LastFullFinish IS NOT NULL
   AND (
           b.LastLogFinish IS NULL
        OR b.LastLogAgeMinutes > @LogMaxMinutes
       )

-- COPY_ONLY_ONLY
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 2,
    FindingType = 'COPY_ONLY_ONLY',
    DatabaseName = b.DatabaseName,
    BackupType = 'FULL',
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), b.DatabaseName)
           + ' last FULL in history is copy-only'
           + CASE
                 WHEN b.LastCopyOnlyFullFinish IS NOT NULL
                     THEN ' (' + CONVERT(varchar(19), b.LastCopyOnlyFullFinish, 120) + ')'
                 ELSE ''
             END
           + CASE
                 WHEN b.LastFullFinish IS NULL
                     THEN ' and no non-copy-only FULL was found.'
                 ELSE ' and the last real FULL is '
                      + CONVERT(varchar(19), b.LastFullFinish, 120)
                      + ' ('
                      + CONVERT(varchar(12), b.LastFullAgeHours)
                      + ' hours ago).'
             END,
    SuggestedAction =
        'Copy-only fulls do not reset the differential base and do not replace the regular FULL job. '
      + 'Take a non-copy-only FULL after any in-flight backup finishes. '
      + 'Leave ad-hoc copy-only backups (for vendors or refreshes) as a side process, not as the only FULL.'
  FROM #LastBackup AS b
 WHERE b.LastCopyOnlyFullFinish IS NOT NULL
   AND (
           b.LastFullFinish IS NULL
        OR b.LastFullAgeHours > @FullMaxHours
       )

-- SLOW_THROUGHPUT
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 2,
    FindingType = 'SLOW_THROUGHPUT',
    DatabaseName = b.DatabaseName,
    BackupType = CASE v.BackupType WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE v.BackupType END,
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Last '
           + CASE v.BackupType WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE v.BackupType END
           + ' for '
           + CONVERT(varchar(128), b.DatabaseName)
           + ' ran at '
           + ISNULL(CONVERT(varchar(20), v.MBps), 'NULL')
           + ' MB/s versus instance average '
           + ISNULL(CONVERT(varchar(20), t.AvgMBps), 'NULL')
           + ' MB/s for that type (n='
           + CONVERT(varchar(12), t.SampleCount)
           + '). Duration '
           + CONVERT(varchar(12), v.DurationSeconds)
           + ' seconds, size '
           + ISNULL(CONVERT(varchar(20), v.BackupSizeMB), '?')
           + ' MB, device '
           + ISNULL(CONVERT(varchar(260), v.DevicePath), '(unknown)')
           + '.',
    SuggestedAction =
        'Throughput well below the instance average usually means a slow destination, not a need to KILL anything. '
      + 'Check the device path (UNC vs local), competing I/O, and whether this database is much larger than peers. '
      + 'After the next successful FULL, consider striping to multiple files, backup compression, and only then BUFFERCOUNT/MAXTRANSFERSIZE. '
      + 'If this was a DIFF and the FULL base is old, fix the base first — a huge DIFF will look "slow" even on a healthy disk.'
  FROM #LastBackup AS b
 INNER JOIN
 (
    SELECT DatabaseName, BackupType, MBps, DurationSeconds, BackupSizeMB, DevicePath
      FROM #BackupHist
     WHERE RnType = 1
       AND DurationSeconds > 900
       AND MBps IS NOT NULL
 ) AS v
    ON v.DatabaseName = b.DatabaseName
 INNER JOIN #TypeThroughput AS t
    ON t.BackupType = v.BackupType
   AND t.AvgMBps > 0
   AND t.SampleCount >= 3
 WHERE v.MBps < (t.AvgMBps * 0.25)

-- BACKUP_JOB_RUNNING_LONG
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT DISTINCT
    Severity = CASE WHEN j.CurrentRunElapsedMinutes >= 240 THEN 3 ELSE 2 END,
    FindingType = 'BACKUP_JOB_RUNNING_LONG',
    DatabaseName = NULL,
    BackupType = NULL,
    SessionId = NULL,
    JobName = j.JobName,
    ElapsedMinutes = j.CurrentRunElapsedMinutes,
    Detail = 'Backup-related Agent job ['
           + CONVERT(varchar(128), j.JobName)
           + '] step ['
           + CONVERT(varchar(128), j.StepName)
           + '] has been running for '
           + CONVERT(varchar(12), j.CurrentRunElapsedMinutes)
           + ' minutes (started '
           + CONVERT(varchar(19), j.CurrentRunStart, 120)
           + ').',
    SuggestedAction =
        'Do not disable the job in a way that cancels a progressing backup unless Findings also show BACKUP_STALLED. '
      + 'Open the matching InProgress session, read wait_type, and let it finish if percent_complete is moving. '
      + 'Prevent a stacked second run (most backup jobs should not start while the previous execution is still going). '
      + 'If this job is a 24-hour DIFF, take a FULL after it ends so the next run is small.'
  FROM #BackupJobs AS j
 WHERE j.IsRunning = 1
   AND j.CurrentRunElapsedMinutes >= @LongRunningMinutes

-- BACKUP_JOB_FAILED
INSERT #Findings
(
    Severity, FindingType, DatabaseName, BackupType, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT DISTINCT
    Severity = 3,
    FindingType = 'BACKUP_JOB_FAILED',
    DatabaseName = NULL,
    BackupType = NULL,
    SessionId = NULL,
    JobName = j.JobName,
    ElapsedMinutes = NULL,
    Detail = 'Backup-related Agent job ['
           + CONVERT(varchar(128), j.JobName)
           + '] last recorded outcome was Failed (step '
           + ISNULL(CONVERT(varchar(12), j.StepId), '?')
           + ' ['
           + ISNULL(CONVERT(varchar(128), j.StepName), '')
           + ']) at '
           + ISNULL(CONVERT(varchar(19), j.LastRunFinish, 120), CONVERT(varchar(19), j.LastRunStart, 120))
           + ', duration '
           + ISNULL(CONVERT(varchar(12), j.LastRunDurationSeconds), '?')
           + ' seconds.',
    SuggestedAction =
        'Open the job history for ['
      + CONVERT(varchar(128), j.JobName)
      + '] and fix the destination/permission/space error before the next window. '
      + 'If a backup is still running from a retry, do not start a second copy. '
      + 'After a failed DIFF, prefer a FULL if the last real FULL is older than '
      + CONVERT(varchar(12), @FullMaxHours)
      + ' hours.'
  FROM #BackupJobs AS j
 WHERE j.LastRunStatus = 'Failed'
   AND (
           j.LastRunStart >= @HistoryStart
        OR j.LastRunFinish >= @HistoryStart
       )

SELECT
    @RunningBackupCount = COUNT(*)
  FROM #InProgress

SELECT
    @DatabaseCount = COUNT(*)
  FROM #LastBackup

SELECT
    @HighPriorityCount = COUNT(*)
  FROM #Findings
 WHERE Severity >= 3

IF @ReturnResultSets = 1
BEGIN
    SELECT
        CaptureDate = @CaptureDate,
        ServerName = @ServerName,
        SqlMajorVersion = @MajorVersion,
        RunningBackupCount = @RunningBackupCount,
        HighPriorityCount = @HighPriorityCount,
        DatabaseCount = @DatabaseCount,
        DatabaseFilter = @DatabaseFilter,
        FullMaxHours = @FullMaxHours,
        DiffMaxHours = @DiffMaxHours,
        LogMaxMinutes = @LogMaxMinutes,
        LongRunningMinutes = @LongRunningMinutes,
        HistoryDays = @HistoryDays,
        IncludeSystem = @IncludeSystem,
        Note = @Note

    SELECT
        SessionId,
        DatabaseName,
        Command,
        Status,
        StartTime,
        ElapsedMinutes,
        PercentComplete,
        EstimatedRemainingMinutes,
        WaitType,
        WaitTimeMs,
        BlockingSessionId,
        CpuMs,
        Reads,
        Writes,
        LogicalReads,
        ProgramName,
        JobName,
        LoginName,
        HostName,
        CommandText
      FROM #InProgress
     ORDER BY ElapsedMinutes DESC, SessionId

    SELECT
        DatabaseName,
        RecoveryModel,
        StateDesc,
        SizeMB,
        LastFullFinish,
        LastFullAgeHours,
        LastFullDurationSeconds,
        LastFullSizeMB,
        LastFullCompressedMB,
        LastFullMBps,
        LastFullDevice,
        LastFullIsCopyOnly,
        LastCopyOnlyFullFinish,
        LastDiffFinish,
        LastDiffAgeHours,
        LastDiffDurationSeconds,
        LastDiffSizeMB,
        LastDiffCompressedMB,
        LastDiffMBps,
        LastDiffDevice,
        LastLogFinish,
        LastLogAgeMinutes,
        LastLogDurationSeconds,
        LastLogSizeMB,
        LastLogCompressedMB,
        LastLogMBps,
        LastLogDevice
      FROM #LastBackup
     ORDER BY DatabaseName

    SELECT
        JobName,
        Enabled,
        StepName,
        LastRunStart,
        LastRunFinish,
        LastRunDurationSeconds,
        LastRunStatus,
        IsRunning,
        CurrentRunStart,
        CurrentRunElapsedMinutes,
        NextRunTime
      FROM #BackupJobs
     ORDER BY JobName, StepId

    SELECT
        Severity,
        FindingType,
        DatabaseName,
        BackupType,
        SessionId,
        JobName,
        ElapsedMinutes,
        Detail,
        SuggestedAction
      FROM #Findings
     ORDER BY Severity DESC, FindingType, DatabaseName, SessionId
END
GO
