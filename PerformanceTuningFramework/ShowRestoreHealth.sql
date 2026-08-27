/*
  ShowRestoreHealth.sql
  Performance Tuning Framework

  Requires SQL Server 2012 (11.x) or later on the instance.

  Deploy to the tool database, then execute:
    EXEC dbo.ShowRestoreHealth
    EXEC dbo.ShowRestoreHealth @DatabaseFilter = N'YourDatabase%', @MorningHours = 12
    EXEC dbo.ShowRestoreHealth @LongRunningMinutes = 30, @HistoryDays = 14

  Ranks instance restore problems (long/stalled/blocked restores, databases
  left RESTORING or unusable, failed morning restore jobs, stale source
  backups). Complements ShowBackupHealth (backup-only). Does not replace
  ShowBackups, ShowBackupsInProgress, or ShowBackupHealth.
  ShowJobHistory / ShowRunningJobs / ShowAgentJobReport remain generic.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowRestoreHealth') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowRestoreHealth'
    DROP PROCEDURE dbo.ShowRestoreHealth
END
GO

PRINT 'Creating: ShowRestoreHealth'
GO

CREATE PROCEDURE dbo.ShowRestoreHealth
(
    @DatabaseFilter     sysname = N'%',
    @HistoryDays        int     = 14,
    @LongRunningMinutes int     = 60,
    @MorningHours       int     = 12,  -- last success older than this + restore job/history => NO_MORNING_RESTORE
    @IncludeSystem      bit     = 0,
    @ReturnResultSets   bit     = 1
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: August 27, 2026
-- Author:       Bill McEvoy
-- Description:  Examines instance restore health and ranks problems with practical suggested
--               actions. Intended for consultants: failed morning restores, databases left
--               RESTORING, stalled restore sessions, exclusive-access blockers, and stale
--               source FULL backups. Requires SQL Server 2012 (11.x) or later.
--               Does not replace ShowBackupHealth, ShowBackups, or ShowBackupsInProgress.
--               Does not scan user tables.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion          tinyint,
    @ServerName            sysname,
    @CaptureDate           datetime,
    @HistoryStart          datetime,
    @SourceBackupMaxHours  int,
    @RunningRestoreCount   int,
    @HighPriorityCount     int,
    @DatabaseCount         int,
    @InstanceHasRestoreJob bit,
    @Note                  varchar(400)

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 11
BEGIN
    RAISERROR('ShowRestoreHealth requires SQL Server 2012 (11.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

IF @DatabaseFilter IS NULL OR @DatabaseFilter = N''
    SET @DatabaseFilter = N'%'

IF @HistoryDays < 0
    SET @HistoryDays = ABS(@HistoryDays)
IF @HistoryDays = 0
    SET @HistoryDays = 14

IF @LongRunningMinutes < 0
    SET @LongRunningMinutes = ABS(@LongRunningMinutes)
IF @LongRunningMinutes = 0
    SET @LongRunningMinutes = 60

IF @MorningHours < 0
    SET @MorningHours = ABS(@MorningHours)
IF @MorningHours = 0
    SET @MorningHours = 12

SET @SourceBackupMaxHours = 36
SET @ServerName   = CAST(SERVERPROPERTY('MachineName') AS sysname)
                  + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @CaptureDate  = GETDATE()
SET @HistoryStart = DATEADD(day, -@HistoryDays, @CaptureDate)
SET @Note = 'Review Findings first. ShowBackupHealth / ShowBackups / ShowBackupsInProgress are backup-only. Do not KILL a progressing restore; a killed restore leaves the database RESTORING and you start over.'

IF OBJECT_ID('tempdb..#InProgress') IS NOT NULL
    DROP TABLE #InProgress
IF OBJECT_ID('tempdb..#DatabaseState') IS NOT NULL
    DROP TABLE #DatabaseState
IF OBJECT_ID('tempdb..#LastRestore') IS NOT NULL
    DROP TABLE #LastRestore
IF OBJECT_ID('tempdb..#RestoreJobs') IS NOT NULL
    DROP TABLE #RestoreJobs
IF OBJECT_ID('tempdb..#RestoreHist') IS NOT NULL
    DROP TABLE #RestoreHist
IF OBJECT_ID('tempdb..#Findings') IS NOT NULL
    DROP TABLE #Findings

CREATE TABLE #InProgress
(
    SessionId                 int            NOT NULL,
    DatabaseName              sysname        NULL,
    Command                   nvarchar(32)   NULL,
    RestoreType               varchar(20)    NULL,
    Status                    nvarchar(30)   NULL,
    StartTime                 datetime       NULL,
    ElapsedMinutes            int            NULL,
    PercentComplete           real           NULL,
    EstimatedRemainingMinutes decimal(18, 2) NULL,
    WaitType                  nvarchar(60)   NULL,
    WaitTimeMs                bigint         NULL,
    BlockingSessionId         int            NULL,
    BlockerLogin              sysname        NULL,
    BlockerProgram            nvarchar(128)  NULL,
    BlockerHost               sysname        NULL,
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

CREATE TABLE #DatabaseState
(
    DatabaseName         sysname        NOT NULL,
    DatabaseId           int            NULL,
    StateDesc            nvarchar(60)   NULL,
    IsInStandby          bit            NULL,
    UserAccessDesc       nvarchar(60)   NULL,
    LastRestoreDate      datetime       NULL,
    LastRestoreType      char(1)        NULL,
    LastRestoreTypeDesc  varchar(20)    NULL,
    LastRestoreAgeHours  decimal(18, 2) NULL,
    HasRestoreHistory    bit            NOT NULL DEFAULT (0),
    HasRestoreJob        bit            NOT NULL DEFAULT (0),
    IsRestoreTarget      bit            NOT NULL DEFAULT (0),
    SourceDatabaseName   sysname        NULL,
    LastFullFinish       datetime       NULL,
    LastFullAgeHours     decimal(18, 2) NULL,
    LastFullIsCopyOnly   bit            NULL,
    LastFullDevice       nvarchar(260)  NULL
)

CREATE TABLE #LastRestore
(
    DatabaseName              sysname        NOT NULL,
    RestoreDate               datetime       NULL,
    RestoreType               char(1)        NULL,
    RestoreTypeDesc           varchar(20)    NULL,
    UserName                  nvarchar(128)  NULL,
    BackupSetId               int            NULL,
    BackupStartDate           datetime       NULL,
    BackupFinishDate          datetime       NULL,
    BackupType                char(1)        NULL,
    BackupTypeDesc            varchar(20)    NULL,
    BackupIsCopyOnly          bit            NULL,
    BackupDurationSeconds     int            NULL,
    SourceDatabaseName        sysname        NULL,
    DevicePath                nvarchar(260)  NULL,
    DestinationFiles          nvarchar(max)  NULL,
    RestoreDurationSeconds    int            NULL,
    RestoreAgeHours           decimal(18, 2) NULL
)

CREATE TABLE #RestoreJobs
(
    JobId                     uniqueidentifier NOT NULL,
    JobName                   sysname          NOT NULL,
    Enabled                   bit              NULL,
    StepId                    int              NULL,
    StepName                  sysname          NULL,
    ParsedDatabaseName        sysname          NULL,
    LastRunStart              datetime         NULL,
    LastRunFinish             datetime         NULL,
    LastRunDurationSeconds    int              NULL,
    LastRunStatus             varchar(20)      NULL,
    LastRunMessage            nvarchar(1000)   NULL,
    IsRunning                 bit              NOT NULL DEFAULT (0),
    CurrentRunStart           datetime         NULL,
    CurrentRunElapsedMinutes  int              NULL,
    NextRunTime               datetime         NULL
)

CREATE TABLE #RestoreHist
(
    RestoreHistoryId      int            NOT NULL,
    DatabaseName          sysname        NOT NULL,
    RestoreDate           datetime       NULL,
    RestoreType           char(1)        NULL,
    UserName              nvarchar(128)  NULL,
    BackupSetId           int            NULL,
    BackupStartDate       datetime       NULL,
    BackupFinishDate      datetime       NULL,
    BackupType            char(1)        NULL,
    BackupIsCopyOnly      bit            NULL,
    BackupDurationSeconds int            NULL,
    SourceDatabaseName    sysname        NULL,
    DevicePath            nvarchar(260)  NULL,
    DestinationFiles      nvarchar(max)  NULL,
    Rn                    int            NULL
)

CREATE TABLE #Findings
(
    Severity          tinyint        NOT NULL,
    FindingType       varchar(40)    NOT NULL,
    DatabaseName      sysname        NULL,
    SessionId         int            NULL,
    JobName           sysname        NULL,
    ElapsedMinutes    int            NULL,
    Detail            varchar(2000)  NULL,
    SuggestedAction   varchar(4000)  NULL
)

---------------------------------------------------------------------
-- In-progress RESTORE requests
---------------------------------------------------------------------

INSERT #InProgress
(
    SessionId, DatabaseName, Command, RestoreType, Status, StartTime, ElapsedMinutes,
    PercentComplete, EstimatedRemainingMinutes, WaitType, WaitTimeMs, BlockingSessionId,
    BlockerLogin, BlockerProgram, BlockerHost,
    CpuMs, Reads, Writes, LogicalReads, ProgramName, JobName, LoginName, HostName,
    CommandText, SqlText
)
SELECT
    SessionId = r.session_id,
    DatabaseName = DB_NAME(r.database_id),
    Command = r.command,
    RestoreType = CASE
                      WHEN r.command LIKE N'%LOG%' OR ISNULL(st.text, N'') LIKE N'%RESTORE LOG%' THEN 'LOG'
                      WHEN ISNULL(st.text, N'') LIKE N'%FILELISTONLY%' THEN 'FILELISTONLY'
                      WHEN ISNULL(st.text, N'') LIKE N'%HEADERONLY%' THEN 'HEADERONLY'
                      WHEN ISNULL(st.text, N'') LIKE N'%VERIFYONLY%' THEN 'VERIFYONLY'
                      ELSE 'DATABASE'
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
    BlockingSessionId = NULLIF(r.blocking_session_id, 0),
    BlockerLogin = blk.login_name,
    BlockerProgram = blk.program_name,
    BlockerHost = blk.host_name,
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
  LEFT JOIN sys.dm_exec_sessions AS blk
    ON blk.session_id = NULLIF(r.blocking_session_id, 0)
 OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
 WHERE r.command LIKE N'%RESTORE%'

-- Placeholder-safe parse of RESTORE DATABASE / RESTORE LOG target.
-- A token that starts with @ is a variable/parameter, not a database name.
UPDATE i
   SET DatabaseName = x.ParsedName,
       RestoreType = CASE
                         WHEN i.Command LIKE N'%LOG%' OR ISNULL(i.SqlText, N'') LIKE N'%RESTORE LOG%' THEN 'LOG'
                         WHEN ISNULL(i.SqlText, N'') LIKE N'%FILELISTONLY%' THEN 'FILELISTONLY'
                         WHEN ISNULL(i.SqlText, N'') LIKE N'%HEADERONLY%' THEN 'HEADERONLY'
                         WHEN ISNULL(i.SqlText, N'') LIKE N'%VERIFYONLY%' THEN 'VERIFYONLY'
                         ELSE i.RestoreType
                     END
  FROM #InProgress AS i
 CROSS APPLY
 (
    SELECT
        KeywordPos = CASE
                         WHEN PATINDEX('%RESTORE DATABASE%', UPPER(ISNULL(i.SqlText, N''))) > 0
                             THEN PATINDEX('%RESTORE DATABASE%', UPPER(ISNULL(i.SqlText, N''))) + 16
                         WHEN PATINDEX('%RESTORE LOG%', UPPER(ISNULL(i.SqlText, N''))) > 0
                             THEN PATINDEX('%RESTORE LOG%', UPPER(ISNULL(i.SqlText, N''))) + 11
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
-- Agent jobs whose step command contains RESTORE
---------------------------------------------------------------------

INSERT #RestoreJobs
(
    JobId, JobName, Enabled, StepId, StepName, ParsedDatabaseName,
    LastRunStart, LastRunFinish, LastRunDurationSeconds, LastRunStatus, LastRunMessage,
    IsRunning, CurrentRunStart, CurrentRunElapsedMinutes, NextRunTime
)
SELECT
    JobId = j.job_id,
    JobName = j.name,
    Enabled = j.enabled,
    StepId = js.step_id,
    StepName = js.step_name,
    ParsedDatabaseName = x.ParsedName,
    LastRunStart = hist.RunStart,
    LastRunFinish = CASE
                        WHEN hist.RunStart IS NULL OR hist.DurationSeconds IS NULL THEN NULL
                        ELSE DATEADD(second, hist.DurationSeconds, hist.RunStart)
                    END,
    LastRunDurationSeconds = hist.DurationSeconds,
    LastRunStatus = hist.StatusText,
    LastRunMessage = COALESCE(failmsg.StepMessage, hist.StepMessage),
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
                        END,
           StepMessage = LEFT(h.message, 1000)
      FROM msdb.dbo.sysjobhistory AS h
     WHERE h.job_id = j.job_id
       AND h.step_id IN (0, js.step_id)
       AND h.run_date > 0
     ORDER BY h.run_date DESC, h.run_time DESC, CASE WHEN h.step_id = 0 THEN 0 ELSE 1 END
 ) AS hist
 OUTER APPLY
 (
    SELECT TOP 1
           StepMessage = LEFT(h.message, 1000)
      FROM msdb.dbo.sysjobhistory AS h
     WHERE h.job_id = j.job_id
       AND h.step_id = js.step_id
       AND h.run_status = 0
       AND h.run_date > 0
     ORDER BY h.run_date DESC, h.run_time DESC
 ) AS failmsg
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
 CROSS APPLY
 (
    SELECT
        KeywordPos = CASE
                         WHEN PATINDEX('%RESTORE DATABASE%', UPPER(ISNULL(js.command, N''))) > 0
                             THEN PATINDEX('%RESTORE DATABASE%', UPPER(ISNULL(js.command, N''))) + 16
                         WHEN PATINDEX('%RESTORE LOG%', UPPER(ISNULL(js.command, N''))) > 0
                             THEN PATINDEX('%RESTORE LOG%', UPPER(ISNULL(js.command, N''))) + 11
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
                                        SUBSTRING(js.command + N'x', k.KeywordPos, 200) + N'x') - 1
                    END
 ) AS n
 CROSS APPLY
 (
    SELECT ParsedName =
        CASE
            WHEN n.NameStart <= 0 THEN NULL
            WHEN SUBSTRING(js.command, n.NameStart, 1) = N'['
                THEN SUBSTRING(js.command, n.NameStart + 1,
                               NULLIF(CHARINDEX(N']', js.command, n.NameStart + 1), 0) - n.NameStart - 1)
            WHEN SUBSTRING(js.command, n.NameStart, 1) = N'@'
                THEN NULL
            ELSE LEFT(SUBSTRING(js.command, n.NameStart, 128),
                      NULLIF(PATINDEX('%[^A-Za-z0-9_#.$]%', SUBSTRING(js.command, n.NameStart, 128) + N' '), 0) - 1)
        END
 ) AS x
 WHERE UPPER(js.command) LIKE N'%RESTORE%'

SET @InstanceHasRestoreJob = CASE WHEN EXISTS (SELECT 1 FROM #RestoreJobs) THEN 1 ELSE 0 END

---------------------------------------------------------------------
-- Restore history (400-day lookback so last restore is visible)
---------------------------------------------------------------------

INSERT #RestoreHist
(
    RestoreHistoryId, DatabaseName, RestoreDate, RestoreType, UserName, BackupSetId,
    BackupStartDate, BackupFinishDate, BackupType, BackupIsCopyOnly, BackupDurationSeconds,
    SourceDatabaseName, DevicePath, DestinationFiles, Rn
)
SELECT
    RestoreHistoryId = rh.restore_history_id,
    DatabaseName = rh.destination_database_name,
    RestoreDate = rh.restore_date,
    RestoreType = rh.restore_type,
    UserName = rh.user_name,
    BackupSetId = rh.backup_set_id,
    BackupStartDate = bs.backup_start_date,
    BackupFinishDate = bs.backup_finish_date,
    BackupType = bs.type,
    BackupIsCopyOnly = bs.is_copy_only,
    BackupDurationSeconds = CASE
                                WHEN bs.backup_start_date IS NULL OR bs.backup_finish_date IS NULL THEN NULL
                                ELSE DATEDIFF(second, bs.backup_start_date, bs.backup_finish_date)
                            END,
    SourceDatabaseName = bs.database_name,
    DevicePath = dev.physical_device_name,
    DestinationFiles = files.FileList,
    Rn = ROW_NUMBER() OVER (
             PARTITION BY rh.destination_database_name
             ORDER BY rh.restore_date DESC, rh.restore_history_id DESC)
  FROM msdb.dbo.restorehistory AS rh
  LEFT JOIN msdb.dbo.backupset AS bs
    ON bs.backup_set_id = rh.backup_set_id
 OUTER APPLY
 (
    SELECT TOP 1
           bmf.physical_device_name
      FROM msdb.dbo.backupmediafamily AS bmf
     WHERE bmf.media_set_id = bs.media_set_id
     ORDER BY bmf.family_sequence_number
 ) AS dev
 OUTER APPLY
 (
    SELECT FileList = STUFF((
                          SELECT N', ' + LTRIM(RTRIM(ISNULL(rf.destination_phys_drive, N'')
                                                   + ISNULL(rf.destination_phys_name, N'')))
                            FROM msdb.dbo.restorefile AS rf
                           WHERE rf.restore_history_id = rh.restore_history_id
                           ORDER BY rf.file_number
                             FOR XML PATH(N''), TYPE
                      ).value(N'.[1]', N'nvarchar(max)'), 1, 2, N'')
 ) AS files
 WHERE rh.restore_date IS NOT NULL
   AND rh.restore_date >= DATEADD(day, -400, @CaptureDate)
   AND rh.destination_database_name LIKE @DatabaseFilter

INSERT #LastRestore
(
    DatabaseName, RestoreDate, RestoreType, RestoreTypeDesc, UserName, BackupSetId,
    BackupStartDate, BackupFinishDate, BackupType, BackupTypeDesc, BackupIsCopyOnly,
    BackupDurationSeconds, SourceDatabaseName, DevicePath, DestinationFiles,
    RestoreDurationSeconds, RestoreAgeHours
)
SELECT
    DatabaseName = h.DatabaseName,
    RestoreDate = h.RestoreDate,
    RestoreType = h.RestoreType,
    RestoreTypeDesc = CASE h.RestoreType
                          WHEN 'D' THEN 'Database'
                          WHEN 'F' THEN 'File'
                          WHEN 'G' THEN 'Filegroup'
                          WHEN 'I' THEN 'Differential'
                          WHEN 'L' THEN 'Log'
                          WHEN 'V' THEN 'Verifyonly'
                          WHEN 'R' THEN 'Revert'
                          ELSE ISNULL(h.RestoreType, 'Unknown')
                      END,
    UserName = h.UserName,
    BackupSetId = h.BackupSetId,
    BackupStartDate = h.BackupStartDate,
    BackupFinishDate = h.BackupFinishDate,
    BackupType = h.BackupType,
    BackupTypeDesc = CASE h.BackupType
                         WHEN 'D' THEN 'FULL'
                         WHEN 'I' THEN 'DIFF'
                         WHEN 'L' THEN 'LOG'
                         WHEN 'F' THEN 'FILE'
                         WHEN 'G' THEN 'FILEGROUP'
                         ELSE h.BackupType
                     END,
    BackupIsCopyOnly = h.BackupIsCopyOnly,
    BackupDurationSeconds = h.BackupDurationSeconds,
    SourceDatabaseName = h.SourceDatabaseName,
    DevicePath = h.DevicePath,
    DestinationFiles = h.DestinationFiles,
    RestoreDurationSeconds = jobdur.DurationSeconds,
    RestoreAgeHours = CAST(DATEDIFF(minute, h.RestoreDate, @CaptureDate) / 60.0 AS decimal(18, 2))
  FROM #RestoreHist AS h
 OUTER APPLY
 (
    SELECT TOP 1
           DurationSeconds = j.LastRunDurationSeconds
      FROM #RestoreJobs AS j
     WHERE j.LastRunFinish IS NOT NULL
       AND j.LastRunDurationSeconds IS NOT NULL
       AND ABS(DATEDIFF(minute, j.LastRunFinish, h.RestoreDate)) <= 15
       AND (
               j.ParsedDatabaseName = h.DatabaseName
            OR j.ParsedDatabaseName IS NULL
           )
     ORDER BY ABS(DATEDIFF(minute, j.LastRunFinish, h.RestoreDate)),
              j.LastRunDurationSeconds
 ) AS jobdur
 WHERE h.Rn = 1
   AND (
           @IncludeSystem = 1
        OR h.DatabaseName NOT IN (N'master', N'model', N'msdb', N'tempdb')
       )

---------------------------------------------------------------------
-- Database state for matching user databases
---------------------------------------------------------------------

INSERT #DatabaseState
(
    DatabaseName, DatabaseId, StateDesc, IsInStandby, UserAccessDesc,
    LastRestoreDate, LastRestoreType, LastRestoreTypeDesc, LastRestoreAgeHours,
    HasRestoreHistory, HasRestoreJob, IsRestoreTarget,
    SourceDatabaseName, LastFullFinish, LastFullAgeHours, LastFullIsCopyOnly, LastFullDevice
)
SELECT
    DatabaseName = d.name,
    DatabaseId = d.database_id,
    StateDesc = d.state_desc,
    IsInStandby = d.is_in_standby,
    UserAccessDesc = d.user_access_desc,
    LastRestoreDate = lr.RestoreDate,
    LastRestoreType = lr.RestoreType,
    LastRestoreTypeDesc = CASE lr.RestoreType
                              WHEN 'D' THEN 'Database'
                              WHEN 'F' THEN 'File'
                              WHEN 'G' THEN 'Filegroup'
                              WHEN 'I' THEN 'Differential'
                              WHEN 'L' THEN 'Log'
                              WHEN 'V' THEN 'Verifyonly'
                              WHEN 'R' THEN 'Revert'
                              ELSE lr.RestoreType
                          END,
    LastRestoreAgeHours = CAST(DATEDIFF(minute, lr.RestoreDate, @CaptureDate) / 60.0 AS decimal(18, 2)),
    HasRestoreHistory = CASE WHEN lr.RestoreDate IS NOT NULL THEN 1 ELSE 0 END,
    HasRestoreJob = CASE
                        WHEN EXISTS
                        (
                            SELECT 1
                              FROM #RestoreJobs AS j
                             WHERE j.ParsedDatabaseName = d.name
                        )
                            THEN 1
                        ELSE 0
                    END,
    IsRestoreTarget = CASE
                          WHEN lr.RestoreDate IS NOT NULL THEN 1
                          WHEN EXISTS
                          (
                              SELECT 1
                                FROM #RestoreJobs AS j
                               WHERE j.ParsedDatabaseName = d.name
                          )
                              THEN 1
                          ELSE 0
                      END,
    SourceDatabaseName = COALESCE(fullb.SourceDatabaseName, lr.SourceDatabaseName),
    LastFullFinish = fullb.BackupFinishDate,
    LastFullAgeHours = CAST(DATEDIFF(minute, fullb.BackupFinishDate, @CaptureDate) / 60.0 AS decimal(18, 2)),
    LastFullIsCopyOnly = fullb.IsCopyOnly,
    LastFullDevice = fullb.DevicePath
  FROM sys.databases AS d
  LEFT JOIN #LastRestore AS lr
    ON lr.DatabaseName = d.name
 OUTER APPLY
 (
    SELECT TOP 1
           bs.backup_finish_date AS BackupFinishDate,
           bs.is_copy_only AS IsCopyOnly,
           bs.database_name AS SourceDatabaseName,
           dev.physical_device_name AS DevicePath
      FROM msdb.dbo.backupset AS bs
     OUTER APPLY
     (
        SELECT TOP 1
               bmf.physical_device_name
          FROM msdb.dbo.backupmediafamily AS bmf
         WHERE bmf.media_set_id = bs.media_set_id
         ORDER BY bmf.family_sequence_number
     ) AS dev
     WHERE bs.type = 'D'
       AND bs.is_copy_only = 0
       AND bs.backup_finish_date IS NOT NULL
       AND bs.backup_finish_date >= DATEADD(day, -400, @CaptureDate)
       AND bs.database_name IN (d.name, ISNULL(lr.SourceDatabaseName, d.name))
     ORDER BY bs.backup_finish_date DESC
 ) AS fullb
 WHERE d.name <> N'tempdb'
   AND d.name LIKE @DatabaseFilter
   AND (
           @IncludeSystem = 1
        OR d.name NOT IN (N'master', N'model', N'msdb')
       )

---------------------------------------------------------------------
-- Findings
---------------------------------------------------------------------

-- RESTORE_RUNNING_LONG
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = CASE
                   WHEN i.ElapsedMinutes >= 240 THEN 3
                   ELSE 2
               END,
    FindingType = 'RESTORE_RUNNING_LONG',
    DatabaseName = i.DatabaseName,
    SessionId = i.SessionId,
    JobName = i.JobName,
    ElapsedMinutes = i.ElapsedMinutes,
    Detail = 'Session ' + CONVERT(varchar(11), i.SessionId)
           + ' has been running a '
           + ISNULL(i.RestoreType, 'RESTORE')
           + ' restore of '
           + ISNULL(CONVERT(varchar(128), i.DatabaseName), '(unknown)')
           + ' for '
           + CONVERT(varchar(12), i.ElapsedMinutes)
           + ' minutes ('
           + CONVERT(varchar(12), CONVERT(decimal(10, 1), i.ElapsedMinutes / 60.0))
           + ' hours). percent_complete='
           + ISNULL(CONVERT(varchar(12), CONVERT(decimal(10, 2), i.PercentComplete)), 'NULL')
           + ', wait='
           + ISNULL(i.WaitType, '(none)')
           + '.',
    SuggestedAction =
        CASE
            WHEN ISNULL(i.PercentComplete, 0) > 0
                THEN 'Do not KILL this session. percent_complete is '
                     + CONVERT(varchar(12), CONVERT(decimal(10, 2), i.PercentComplete))
                     + ' so the restore is advancing. A killed restore leaves the database in RESTORING and you start over. '
            ELSE 'Watch percent_complete before considering any cancel. Do not KILL a progressing restore. '
        END
      + CASE
            WHEN i.WaitType LIKE 'BACKUPIO%' OR i.WaitType = 'ASYNC_IO_COMPLETION'
                THEN 'Wait ' + i.WaitType + ' points at the source backup file (UNC share, disk, or device). Check that the file exists, is readable, and the network/disk is not queued. '
            WHEN i.WaitType LIKE 'LCK_%'
                THEN 'Wait ' + i.WaitType + ' means the restore is blocked waiting for exclusive access. Inspect blocker session '
                     + ISNULL(CONVERT(varchar(11), i.BlockingSessionId), '(none)')
                     + ISNULL(' (' + CONVERT(varchar(128), i.BlockerLogin) + ' / ' + CONVERT(varchar(128), i.BlockerProgram) + ')', '')
                     + ' and clear that session; do not KILL the restore. '
            WHEN i.WaitType LIKE 'PREEMPTIVE_OS_%'
                THEN 'Wait ' + i.WaitType + ' is an OS/network call (file open, share, memory). Check the backup path, permissions, and OS errors. '
            WHEN i.WaitType IS NOT NULL
                THEN 'Current wait is ' + i.WaitType + '. '
            ELSE ''
        END
      + CASE
            WHEN i.JobName IS NOT NULL
                THEN 'Check Agent job [' + CONVERT(varchar(128), i.JobName) + '] so it does not start another overlapping restore. '
            ELSE 'If this came from an Agent job, confirm the job is not scheduled to stack another run. '
        END
      + 'When it finishes, confirm restorehistory recorded a row and the database is ONLINE (or still RESTORING if NORECOVERY was intended).'
  FROM #InProgress AS i
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

-- RESTORE_STALLED
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'RESTORE_STALLED',
    DatabaseName = i.DatabaseName,
    SessionId = i.SessionId,
    JobName = i.JobName,
    ElapsedMinutes = i.ElapsedMinutes,
    Detail = 'Session ' + CONVERT(varchar(11), i.SessionId)
           + ' restore of '
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
        'This restore does not appear to be making progress. '
      + CASE
            WHEN i.WaitType LIKE 'BACKUPIO%' OR i.WaitType = 'ASYNC_IO_COMPLETION'
                THEN 'Wait ' + i.WaitType + ' usually means the source backup file is not being read (missing file, share down, permissions, or dead network). '
            WHEN i.WaitType LIKE 'PREEMPTIVE_OS_%'
                THEN 'Wait ' + i.WaitType + ' is an OS/network call — check the backup path, share, and disk. '
            WHEN i.WaitType LIKE 'LCK_%'
                THEN 'Clear the blocker (session '
                     + ISNULL(CONVERT(varchar(11), i.BlockingSessionId), '?')
                     + ISNULL(', ' + CONVERT(varchar(128), i.BlockerLogin), '')
                     + ') so the restore can get exclusive access. Do not KILL the restore. '
            ELSE ''
        END
      + 'Do not KILL a progressing restore. If percent_complete has been 0 for '
      + CONVERT(varchar(12), i.ElapsedMinutes)
      + ' minutes, fix the source path, permissions, or blocker first. Killing session '
      + CONVERT(varchar(11), i.SessionId)
      + ' will leave the database RESTORING and you will have to restart the restore. '
      + CASE
            WHEN i.JobName IS NOT NULL
                THEN 'Stop a stacked retry of job [' + CONVERT(varchar(128), i.JobName) + '] so a second restore does not start on top of this one. '
            ELSE 'Make sure the restore job will not start again on top of this. '
        END
  FROM #InProgress AS i
 WHERE (
           (ISNULL(i.PercentComplete, 0) = 0 AND i.ElapsedMinutes >= 30)
        OR (
               i.ElapsedMinutes >= @LongRunningMinutes
           AND (
                   i.WaitType LIKE N'BACKUPIO%'
                OR i.WaitType = N'ASYNC_IO_COMPLETION'
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

-- RESTORE_BLOCKED
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'RESTORE_BLOCKED',
    DatabaseName = i.DatabaseName,
    SessionId = i.SessionId,
    JobName = i.JobName,
    ElapsedMinutes = i.ElapsedMinutes,
    Detail = 'Session ' + CONVERT(varchar(11), i.SessionId)
           + ' restore of '
           + ISNULL(CONVERT(varchar(128), i.DatabaseName), '(unknown)')
           + ' is blocked. wait='
           + ISNULL(i.WaitType, '(none)')
           + ', wait_time_ms='
           + ISNULL(CONVERT(varchar(20), i.WaitTimeMs), 'NULL')
           + ', blocker_session_id='
           + ISNULL(CONVERT(varchar(11), i.BlockingSessionId), '(none)')
           + CASE
                 WHEN i.BlockerLogin IS NOT NULL
                     THEN ', blocker='
                          + CONVERT(varchar(128), i.BlockerLogin)
                          + ISNULL(' / ' + CONVERT(varchar(128), i.BlockerProgram), '')
                          + ISNULL(' on ' + CONVERT(varchar(128), i.BlockerHost), '')
                 ELSE ''
             END
           + '.',
    SuggestedAction =
        'RESTORE needs exclusive access to the target database. '
      + CASE
            WHEN i.BlockingSessionId IS NOT NULL
                THEN 'Blocker is session '
                     + CONVERT(varchar(11), i.BlockingSessionId)
                     + ISNULL(' login ' + CONVERT(varchar(128), i.BlockerLogin), '')
                     + ISNULL(' program ' + CONVERT(varchar(128), i.BlockerProgram), '')
                     + ISNULL(' host ' + CONVERT(varchar(128), i.BlockerHost), '')
                     + '. Disconnect or finish that session (or have the restore job issue ALTER DATABASE ... SET SINGLE_USER WITH ROLLBACK IMMEDIATE immediately before RESTORE). '
            ELSE 'No blocker session id is recorded, but the wait is a lock/exclusive-access wait. Find remaining connections in the target database and clear them. '
        END
      + 'Do not KILL restore session '
      + CONVERT(varchar(11), i.SessionId)
      + '. Clear the blocker first; once exclusive access is obtained, percent_complete should start moving.'
  FROM #InProgress AS i
 WHERE (
           i.WaitType LIKE N'LCK_%'
        OR i.BlockingSessionId IS NOT NULL
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

-- DATABASE_LEFT_RESTORING
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'DATABASE_LEFT_RESTORING',
    DatabaseName = d.DatabaseName,
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), d.DatabaseName)
           + ' is RESTORING'
           + CASE WHEN d.IsInStandby = 1 THEN ' (standby)' ELSE '' END
           + ', user_access='
           + ISNULL(CONVERT(varchar(60), d.UserAccessDesc), '(unknown)')
           + ', last restore '
           + ISNULL(CONVERT(varchar(19), d.LastRestoreDate, 120), '(none in lookback)')
           + ISNULL(' (' + d.LastRestoreTypeDesc + ')', '')
           + ', and no RESTORE session is running now.',
    SuggestedAction =
        'The database is not usable in this state. '
      + CASE
            WHEN d.LastRestoreType IN ('L', 'I')
                THEN 'A log or differential restore likely used NORECOVERY. Either restore the next log or run RESTORE DATABASE ['
                     + CONVERT(varchar(128), d.DatabaseName)
                     + '] WITH RECOVERY if this is the last file. '
            ELSE 'If the restore job uses NORECOVERY (log shipping / staged restore), apply the remaining files or WITH RECOVERY. '
        END
      + 'If the restore job failed mid-file, read RESTORE_JOB_FAILED, fix the source/path/space error, and restart the restore (WITH REPLACE if the files are already partly replaced). '
      + 'Do not DELETE the database until you have a known-good backup. Do not KILL anything — nothing is running.'
  FROM #DatabaseState AS d
 WHERE d.StateDesc = N'RESTORING'
   AND ISNULL(d.IsInStandby, 0) = 0
   AND NOT EXISTS
       (
           SELECT 1
             FROM #InProgress AS i
            WHERE i.DatabaseName = d.DatabaseName
       )

-- DATABASE_RECOVERY_PENDING
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'DATABASE_RECOVERY_PENDING',
    DatabaseName = d.DatabaseName,
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), d.DatabaseName)
           + ' is RECOVERY_PENDING. Last restore '
           + ISNULL(CONVERT(varchar(19), d.LastRestoreDate, 120), '(none in lookback)')
           + ISNULL(' (' + d.LastRestoreTypeDesc + ')', '')
           + '.',
    SuggestedAction =
        'SQL Server cannot finish recovery (missing log, missing file, or damaged file). '
      + 'Read the SQL Server error log for the file name and error. '
      + 'Restore from a known-good backup rather than trying to salvage a half-restored copy. '
      + 'Check destination disk space and that every file path in restorefile still exists. '
      + 'Do not DROP the database until you have confirmed a usable source backup.'
  FROM #DatabaseState AS d
 WHERE d.StateDesc = N'RECOVERY_PENDING'

-- DATABASE_SUSPECT
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'DATABASE_SUSPECT',
    DatabaseName = d.DatabaseName,
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), d.DatabaseName)
           + ' is SUSPECT. Last restore '
           + ISNULL(CONVERT(varchar(19), d.LastRestoreDate, 120), '(none in lookback)')
           + ISNULL(' (' + d.LastRestoreTypeDesc + ')', '')
           + '.',
    SuggestedAction =
        'Treat this as an emergency. Read the SQL Server error log for the page or file that failed. '
      + 'Prefer a full restore from a known-good backup over EMERGENCY / CONTINUE AFTER ERROR. '
      + 'If a restore job just ran, the restore likely did not complete cleanly — fix that job and restore again. '
      + 'Do not delete data files until a successful restore exists.'
  FROM #DatabaseState AS d
 WHERE d.StateDesc = N'SUSPECT'

-- DATABASE_OFFLINE
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = CASE WHEN d.IsRestoreTarget = 1 THEN 3 ELSE 2 END,
    FindingType = 'DATABASE_OFFLINE',
    DatabaseName = d.DatabaseName,
    SessionId = NULL,
    JobName = NULL,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), d.DatabaseName)
           + ' is OFFLINE. Last restore '
           + ISNULL(CONVERT(varchar(19), d.LastRestoreDate, 120), '(none in lookback)')
           + ISNULL(' (' + d.LastRestoreTypeDesc + ')', '')
           + CASE WHEN d.IsRestoreTarget = 1 THEN '. This database has restore history or a restore job.' ELSE '.' END,
    SuggestedAction =
        'Confirm whether OFFLINE is intentional. '
      + 'If a restore job ran this morning, check whether it issued ALTER DATABASE ... OFFLINE or failed after SET SINGLE_USER. '
      + 'OFFLINE is not the same as RESTORING — bring it online only after you know the intended state: ALTER DATABASE ['
      + CONVERT(varchar(128), d.DatabaseName)
      + '] SET ONLINE. '
      + 'If a restore is about to be retried, exclusive access is easier while users are off, but finish the restore and confirm ONLINE (or RESTORING + NORECOVERY if that is the design).'
  FROM #DatabaseState AS d
 WHERE d.StateDesc = N'OFFLINE'

-- RESTORE_JOB_FAILED (sysjobhistory run_status = 0)
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT DISTINCT
    Severity = 3,
    FindingType = 'RESTORE_JOB_FAILED',
    DatabaseName = j.ParsedDatabaseName,
    SessionId = NULL,
    JobName = j.JobName,
    ElapsedMinutes = NULL,
    Detail = 'Restore-related Agent job ['
           + CONVERT(varchar(128), j.JobName)
           + '] last recorded outcome was Failed (sysjobhistory run_status = 0, step '
           + ISNULL(CONVERT(varchar(12), j.StepId), '?')
           + ' ['
           + ISNULL(CONVERT(varchar(128), j.StepName), '')
           + ']) at '
           + ISNULL(CONVERT(varchar(19), j.LastRunFinish, 120), CONVERT(varchar(19), j.LastRunStart, 120))
           + ', duration '
           + ISNULL(CONVERT(varchar(12), j.LastRunDurationSeconds), '?')
           + ' seconds.'
           + CASE
                 WHEN NULLIF(LTRIM(RTRIM(j.LastRunMessage)), N'') IS NOT NULL
                     THEN ' Step message: ' + LEFT(CONVERT(varchar(800), j.LastRunMessage), 800)
                 ELSE ''
             END,
    SuggestedAction =
        'Open the job history for ['
      + CONVERT(varchar(128), j.JobName)
      + '] and fix the error in the step message before the next window. '
      + CASE
            WHEN j.LastRunMessage LIKE N'%exclusive access%'
              OR j.LastRunMessage LIKE N'%because the database is in use%'
                THEN 'Exclusive access could not be obtained. Put the target in SINGLE_USER WITH ROLLBACK IMMEDIATE (or disconnect users) immediately before RESTORE, then retry. '
            WHEN j.LastRunMessage LIKE N'%cannot open backup device%'
              OR j.LastRunMessage LIKE N'%Operating system error%'
              OR j.LastRunMessage LIKE N'%The system cannot find the file%'
                THEN 'The backup device/path is missing or not readable. Confirm last night''s backup file exists, the share is up, and the service account can read it. '
            WHEN j.LastRunMessage LIKE N'%not enough space%'
              OR j.LastRunMessage LIKE N'%insufficient%'
                THEN 'The destination data or log drive is full. Free space or relocate the restore files, then retry. '
            ELSE 'Typical causes: exclusive access (users still in the database), missing/unreadable backup file, permissions, or destination disk space. '
        END
      + 'If a restore is still running from a retry, do not start a second copy. '
      + 'If the database was left RESTORING, restart the restore (WITH REPLACE if files were partly replaced) rather than issuing WITH RECOVERY on a partial file. '
      + 'Use ShowBackupHealth on the source instance if last night''s FULL is in doubt.'
  FROM #RestoreJobs AS j
 WHERE j.LastRunStatus = 'Failed'
   AND (
           j.LastRunStart >= @HistoryStart
        OR j.LastRunFinish >= @HistoryStart
       )

-- RESTORE_JOB_RUNNING_LONG
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT DISTINCT
    Severity = CASE WHEN j.CurrentRunElapsedMinutes >= 240 THEN 3 ELSE 2 END,
    FindingType = 'RESTORE_JOB_RUNNING_LONG',
    DatabaseName = j.ParsedDatabaseName,
    SessionId = NULL,
    JobName = j.JobName,
    ElapsedMinutes = j.CurrentRunElapsedMinutes,
    Detail = 'Restore-related Agent job ['
           + CONVERT(varchar(128), j.JobName)
           + '] step ['
           + CONVERT(varchar(128), j.StepName)
           + '] has been running for '
           + CONVERT(varchar(12), j.CurrentRunElapsedMinutes)
           + ' minutes (started '
           + CONVERT(varchar(19), j.CurrentRunStart, 120)
           + ').',
    SuggestedAction =
        'Do not stop the job if Findings also show a restore whose percent_complete is advancing. '
      + 'Open the matching InProgress session, read wait_type, and let it finish. '
      + 'Prevent a stacked second run (most restore jobs should not start while the previous execution is still going). '
      + 'If percent_complete is 0 and the wait is BACKUPIO or a lock, treat it as RESTORE_STALLED / RESTORE_BLOCKED and fix the source file or blocker — do not KILL a progressing restore.'
  FROM #RestoreJobs AS j
 WHERE j.IsRunning = 1
   AND j.CurrentRunElapsedMinutes >= @LongRunningMinutes

-- NO_MORNING_RESTORE
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = 3,
    FindingType = 'NO_MORNING_RESTORE',
    DatabaseName = d.DatabaseName,
    SessionId = NULL,
    JobName = job.JobName,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), d.DatabaseName)
           + ' is a restore target (restore job or restore history exists) but the last successful restore is '
           + CASE
                 WHEN d.LastRestoreDate IS NULL THEN 'missing in the lookback'
                 ELSE CONVERT(varchar(19), d.LastRestoreDate, 120)
                      + ' ('
                      + CONVERT(varchar(12), d.LastRestoreAgeHours)
                      + ' hours ago)'
             END
           + '; threshold '
           + CONVERT(varchar(12), @MorningHours)
           + ' hours. Current state='
           + ISNULL(CONVERT(varchar(60), d.StateDesc), '(unknown)')
           + '.',
    SuggestedAction =
        'Today''s morning restore did not complete successfully (or has not run yet). '
      + 'Check whether the restore job is enabled, ran on schedule, or failed (see RESTORE_JOB_FAILED and the step message). '
      + 'Confirm the source backup exists and is recent (see SOURCE_BACKUP_STALE_OR_MISSING and ShowBackupHealth). '
      + CASE
            WHEN d.StateDesc = N'RESTORING'
                THEN 'The database is still RESTORING — finish WITH RECOVERY if the last file is applied, or restart the restore after fixing the job error. '
            WHEN d.StateDesc = N'ONLINE'
                THEN 'The database is ONLINE on yesterday''s (or older) copy. Retry the restore after exclusive access is available. '
            ELSE 'Current state is '
                 + ISNULL(CONVERT(varchar(60), d.StateDesc), 'unknown')
                 + ' — resolve that state before retrying the morning restore. '
        END
      + 'Do not start a second restore while one is already running.'
  FROM #DatabaseState AS d
 OUTER APPLY
 (
    SELECT TOP 1
           j.JobName
      FROM #RestoreJobs AS j
     WHERE j.ParsedDatabaseName = d.DatabaseName
        OR j.ParsedDatabaseName IS NULL
     ORDER BY CASE WHEN j.ParsedDatabaseName = d.DatabaseName THEN 0 ELSE 1 END,
              j.Enabled DESC,
              j.LastRunStart DESC
 ) AS job
 WHERE d.IsRestoreTarget = 1
   AND (
           d.LastRestoreDate IS NULL
        OR d.LastRestoreAgeHours > @MorningHours
       )
   AND NOT EXISTS
       (
           SELECT 1
             FROM #InProgress AS i
            WHERE i.DatabaseName = d.DatabaseName
       )

-- Job exists, no parseable target DB, and no restore-target database in the filter
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT DISTINCT
    Severity = 3,
    FindingType = 'NO_MORNING_RESTORE',
    DatabaseName = NULL,
    SessionId = NULL,
    JobName = j.JobName,
    ElapsedMinutes = NULL,
    Detail = 'Restore-related Agent job ['
           + CONVERT(varchar(128), j.JobName)
           + '] exists but no destination database could be parsed from the step command (placeholder-safe parse skipped an @variable) and no matching restore history was found. Last run '
           + ISNULL(CONVERT(varchar(19), j.LastRunStart, 120), '(never)')
           + ' status '
           + ISNULL(j.LastRunStatus, '(unknown)')
           + '.',
    SuggestedAction =
        'Inspect the job step command and confirm which database it restores. '
      + 'If the command uses a variable (@db), check the job history step message for the name and the failure reason. '
      + 'Confirm the job is enabled and that last night''s source backup is present. Retry after exclusive access is available. Do not KILL a progressing restore.'
  FROM #RestoreJobs AS j
 WHERE @InstanceHasRestoreJob = 1
   AND NOT EXISTS
       (
           SELECT 1
             FROM #DatabaseState AS d
            WHERE d.IsRestoreTarget = 1
       )
   AND (
           j.LastRunStart IS NULL
        OR j.LastRunStart < DATEADD(hour, -@MorningHours, @CaptureDate)
        OR j.LastRunStatus <> 'Succeeded'
       )

-- SOURCE_BACKUP_STALE_OR_MISSING
INSERT #Findings
(
    Severity, FindingType, DatabaseName, SessionId, JobName,
    ElapsedMinutes, Detail, SuggestedAction
)
SELECT
    Severity = CASE WHEN d.LastFullFinish IS NULL THEN 3 ELSE 2 END,
    FindingType = 'SOURCE_BACKUP_STALE_OR_MISSING',
    DatabaseName = d.DatabaseName,
    SessionId = NULL,
    JobName = job.JobName,
    ElapsedMinutes = NULL,
    Detail = 'Database '
           + CONVERT(varchar(128), d.DatabaseName)
           + ' has a restore job or restore history, but the last non-copy-only FULL'
           + CASE
                 WHEN d.SourceDatabaseName IS NOT NULL
                  AND d.SourceDatabaseName <> d.DatabaseName
                     THEN ' (source database ' + CONVERT(varchar(128), d.SourceDatabaseName) + ')'
                 ELSE ''
             END
           + CASE
                 WHEN d.LastFullFinish IS NULL
                     THEN ' is missing in the 400-day backupset lookback.'
                 ELSE ' finished '
                      + CONVERT(varchar(19), d.LastFullFinish, 120)
                      + ' ('
                      + CONVERT(varchar(12), d.LastFullAgeHours)
                      + ' hours ago; reasonable window '
                      + CONVERT(varchar(12), @SourceBackupMaxHours)
                      + ' hours). Device '
                      + ISNULL(CONVERT(varchar(260), d.LastFullDevice), '(unknown)')
                      + '.'
             END,
    SuggestedAction =
        'A morning restore needs a recent non-copy-only FULL (or the backup file the job points at). '
      + 'Confirm last night''s backup job succeeded — run ShowBackupHealth on the instance that takes the source backup. '
      + 'Check the device path the restore job uses and that the file is present and readable. '
      + 'Copy-only fulls can be restored but do not replace the regular FULL job. '
      + 'If the backup is missing, the restore cannot succeed until a new FULL exists. Do not KILL a restore that is already running.'
  FROM #DatabaseState AS d
 OUTER APPLY
 (
    SELECT TOP 1
           j.JobName
      FROM #RestoreJobs AS j
     WHERE j.ParsedDatabaseName = d.DatabaseName
        OR j.ParsedDatabaseName IS NULL
     ORDER BY CASE WHEN j.ParsedDatabaseName = d.DatabaseName THEN 0 ELSE 1 END,
              j.Enabled DESC
 ) AS job
 WHERE d.IsRestoreTarget = 1
   AND (
           d.LastFullFinish IS NULL
        OR d.LastFullAgeHours > @SourceBackupMaxHours
       )

SELECT
    @RunningRestoreCount = COUNT(*)
  FROM #InProgress

SELECT
    @DatabaseCount = COUNT(*)
  FROM #DatabaseState

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
        RunningRestoreCount = @RunningRestoreCount,
        HighPriorityCount = @HighPriorityCount,
        DatabaseCount = @DatabaseCount,
        DatabaseFilter = @DatabaseFilter,
        HistoryDays = @HistoryDays,
        LongRunningMinutes = @LongRunningMinutes,
        MorningHours = @MorningHours,
        IncludeSystem = @IncludeSystem,
        Note = @Note

    SELECT
        SessionId,
        DatabaseName,
        Command,
        RestoreType,
        Status,
        StartTime,
        ElapsedMinutes,
        PercentComplete,
        EstimatedRemainingMinutes,
        WaitType,
        WaitTimeMs,
        BlockingSessionId,
        BlockerLogin,
        BlockerProgram,
        BlockerHost,
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
        StateDesc,
        IsInStandby,
        UserAccessDesc,
        LastRestoreDate,
        LastRestoreType,
        LastRestoreTypeDesc,
        LastRestoreAgeHours
      FROM #DatabaseState
     ORDER BY DatabaseName

    SELECT
        DatabaseName,
        RestoreDate,
        RestoreType,
        RestoreTypeDesc,
        UserName,
        BackupFinishDate,
        BackupStartDate,
        BackupType,
        BackupTypeDesc,
        BackupIsCopyOnly,
        DevicePath,
        DestinationFiles,
        RestoreDurationSeconds,
        BackupDurationSeconds,
        RestoreAgeHours,
        SourceDatabaseName
      FROM #LastRestore
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
      FROM #RestoreJobs
     ORDER BY JobName, StepId

    SELECT
        Severity,
        FindingType,
        DatabaseName,
        SessionId,
        JobName,
        ElapsedMinutes,
        Detail,
        SuggestedAction
      FROM #Findings
     ORDER BY Severity DESC, FindingType, DatabaseName, SessionId
END
GO
