/*
  ShowAgentJobReport.sql
  Performance Tuning Framework

  Deploy to the tool database, then execute:
    EXEC dbo.ShowAgentJobReport
    EXEC dbo.ShowAgentJobReport @JobFilter = N'%Backup%', @EnabledOnly = 1

  Produces a fixed-width text report of SQL Agent jobs, schedules, and job steps
  (subsystem, database, success/fail flow, and optional command text).

  Optional parameters:
    @JobFilter           - LIKE filter for job name (default '%')
    @CategoryFilter      - LIKE filter for category name (default '%')
    @EnabledOnly         - 1 = enabled jobs only (default 0)
    @IncludeSchedules    - include schedule detail (default 1)
    @IncludeSteps        - include job step detail (default 1)
    @IncludeCommandText  - include truncated step command text (default 1)
    @MaxCommandLength    - max command characters shown per step (default 160)
    @SortBy              - NAME | CATEGORY | OWNER | ENABLED (default NAME)
    @ReportWidth         - kept for compatibility; layout fixed at 120 characters

  Notes:
    - Reads msdb SQL Agent catalog views (instance-scoped).
    - Procedure deployment is compatibility level 100 safe (no CREATE OR ALTER).
    - Requires permission to read msdb job metadata (typically SQLAgentReaderRole
      or equivalent / sysadmin).
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
  Compatibility-safe replacement pattern.

  CREATE OR ALTER is intentionally not used so this script can deploy to a tool
  database running at compatibility level 100.
*/
IF OBJECT_ID(N'dbo.ShowAgentJobReport', N'P') IS NULL
BEGIN
    EXEC
    (
        N'CREATE PROCEDURE dbo.ShowAgentJobReport
          AS
          BEGIN
              SET NOCOUNT ON;
              RETURN 0;
          END;'
    );
END
GO

ALTER PROCEDURE dbo.ShowAgentJobReport
(
    @JobFilter          sysname     = N'%',
    @CategoryFilter     sysname     = N'%',
    @EnabledOnly        bit         = 0,
    @IncludeSchedules   bit         = 1,
    @IncludeSteps       bit         = 1,
    @IncludeCommandText bit         = 1,
    @MaxCommandLength   int         = 160,
    @SortBy             varchar(20) = 'NAME',
    @ReportWidth        tinyint     = 120
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: August 13, 2026
-- Author:       Bill McEvoy
-- Description:  Fixed-width SQL Agent job inventory report: jobs, schedules, and job steps
--               with subsystem, database context, flow control, and optional command text.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @ProductVersion   varchar(30),
    @ProductLevel     varchar(30),
    @Edition          varchar(64),
    @ServerName       sysname,
    @ReportTime       varchar(19),
    @Divider          varchar(120),
    @HeaderRule       varchar(120),
    @BlankLine        varchar(120),
    @LineNo           int,
    @SortByUpper      varchar(20),
    @TotalJobs        int,
    @EnabledJobs      int,
    @DisabledJobs     int,
    @ScheduledJobs    int,
    @UnscheduledJobs  int,
    @TotalSteps       int,
    @TotalSchedules   int,
    @RunningJobs      int,
    @FailedLastRun    int,
    @JobId            uniqueidentifier,
    @JobName          sysname,
    @JobEnabled       tinyint,
    @CategoryName     sysname,
    @OwnerName        sysname,
    @Description      nvarchar(512),
    @DateCreated      datetime,
    @DateModified     datetime,
    @LastRunOutcome   varchar(20),
    @LastRunDateTime  varchar(19),
    @LastRunDuration  varchar(12),
    @IsRunning        bit,
    @CurrentStepName  sysname,
    @StepCount        int,
    @ScheduleCount    int,
    @NotifyLevelEmail int,
    @DeleteLevel      int,
    @StartStepId      int,
    /* schedule loop vars */
    @SchedName        sysname,
    @SchedEnabled     tinyint,
    @SchedFrequency   varchar(40),
    @SchedInterval    varchar(80),
    @SchedTime        varchar(60),
    @SchedWindow      varchar(40),
    @SchedNext        varchar(30),
    /* step loop vars */
    @StepId           int,
    @StepName         sysname,
    @Subsystem        nvarchar(40),
    @StepDatabase     sysname,
    @StepDbUser       sysname,
    @OnSuccess        varchar(40),
    @OnFail           varchar(40),
    @RetryAttempts    int,
    @RetryInterval    int,
    @ProxyName        sysname,
    @CommandText      nvarchar(max)

IF @JobFilter IS NULL OR LTRIM(RTRIM(@JobFilter)) = N''
    SET @JobFilter = N'%'

IF @CategoryFilter IS NULL OR LTRIM(RTRIM(@CategoryFilter)) = N''
    SET @CategoryFilter = N'%'

IF @MaxCommandLength IS NULL OR @MaxCommandLength < 40
    SET @MaxCommandLength = 40

IF @MaxCommandLength > 400
    SET @MaxCommandLength = 400

SET @ReportWidth = 120
SET @SortByUpper = UPPER(LTRIM(RTRIM(ISNULL(@SortBy, 'NAME'))))

IF @SortByUpper NOT IN ('NAME', 'CATEGORY', 'OWNER', 'ENABLED')
    SET @SortByUpper = 'NAME'

SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ProductLevel   = CAST(SERVERPROPERTY('ProductLevel') AS varchar(30))
SET @Edition        = CAST(SERVERPROPERTY('Edition') AS varchar(64))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @Divider        = REPLICATE('-', @ReportWidth)
SET @HeaderRule     = REPLICATE('=', @ReportWidth)
SET @BlankLine      = REPLICATE(' ', @ReportWidth)

---------------------------------------------------------------------------------------------------
-- Working tables
---------------------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Jobs') IS NOT NULL
    DROP TABLE #Jobs

CREATE TABLE #Jobs
(
    SortOrder         int              NOT NULL,
    JobId             uniqueidentifier NOT NULL PRIMARY KEY,
    JobName           sysname          NOT NULL,
    JobEnabled        tinyint          NOT NULL,
    CategoryName      sysname          NULL,
    OwnerName         sysname          NULL,
    Description       nvarchar(512)    NULL,
    DateCreated       datetime         NULL,
    DateModified      datetime         NULL,
    StartStepId       int              NULL,
    NotifyLevelEmail  int              NULL,
    DeleteLevel       int              NULL,
    StepCount         int              NOT NULL,
    ScheduleCount     int              NOT NULL,
    LastRunOutcome    varchar(20)      NULL,
    LastRunDateTime   varchar(19)      NULL,
    LastRunDuration   varchar(12)      NULL,
    IsRunning         bit              NOT NULL,
    CurrentStepName   sysname          NULL
)

IF OBJECT_ID('tempdb..#Schedules') IS NOT NULL
    DROP TABLE #Schedules

CREATE TABLE #Schedules
(
    JobId            uniqueidentifier NOT NULL,
    ScheduleId       int              NOT NULL,
    ScheduleName     sysname          NULL,
    ScheduleEnabled  tinyint          NOT NULL,
    Frequency        varchar(40)      NOT NULL,
    IntervalText     varchar(80)      NOT NULL,
    TimeText         varchar(60)      NOT NULL,
    ActiveWindow     varchar(40)      NOT NULL,
    NextRunText      varchar(30)      NOT NULL,
    PRIMARY KEY (JobId, ScheduleId)
)

IF OBJECT_ID('tempdb..#Steps') IS NOT NULL
    DROP TABLE #Steps

CREATE TABLE #Steps
(
    JobId              uniqueidentifier NOT NULL,
    StepId             int              NOT NULL,
    StepName           sysname          NOT NULL,
    Subsystem          nvarchar(40)     NOT NULL,
    DatabaseName       sysname          NULL,
    DatabaseUserName   sysname          NULL,
    OnSuccessAction    varchar(40)      NOT NULL,
    OnSuccessStepId    int              NOT NULL,
    OnFailAction       varchar(40)      NOT NULL,
    OnFailStepId       int              NOT NULL,
    RetryAttempts      int              NOT NULL,
    RetryInterval      int              NOT NULL,
    Flags              int              NOT NULL,
    ProxyName          sysname          NULL,
    CommandText        nvarchar(max)    NULL,
    PRIMARY KEY (JobId, StepId)
)

IF OBJECT_ID('tempdb..#Report') IS NOT NULL
    DROP TABLE #Report

CREATE TABLE #Report
(
    [LineNo]   int          NOT NULL IDENTITY(1, 1) PRIMARY KEY,
    ReportLine varchar(200) NOT NULL
)

---------------------------------------------------------------------------------------------------
-- Collect jobs
---------------------------------------------------------------------------------------------------
;WITH LastHistory AS
(
    SELECT
        h.job_id,
        h.run_status,
        h.run_date,
        h.run_time,
        h.run_duration,
        RowNum = ROW_NUMBER() OVER
        (
            PARTITION BY h.job_id
            ORDER BY h.run_date DESC, h.run_time DESC, h.instance_id DESC
        )
      FROM msdb.dbo.sysjobhistory AS h
     WHERE h.step_id = 0
),
Running AS
(
    SELECT
        aj.job_id,
        CurrentStepName = CONVERT(sysname, ISNULL(js.step_name, N'(starting)'))
      FROM msdb.dbo.sysjobactivity AS aj
      LEFT JOIN msdb.dbo.sysjobsteps AS js
        ON js.job_id = aj.job_id
       AND js.step_id = ISNULL(aj.last_executed_step_id, 0) + 1
     WHERE aj.session_id =
       (
           SELECT MAX(s.session_id)
             FROM msdb.dbo.syssessions AS s
       )
       AND aj.start_execution_date IS NOT NULL
       AND aj.stop_execution_date IS NULL
)
INSERT INTO #Jobs
(
    SortOrder,
    JobId,
    JobName,
    JobEnabled,
    CategoryName,
    OwnerName,
    Description,
    DateCreated,
    DateModified,
    StartStepId,
    NotifyLevelEmail,
    DeleteLevel,
    StepCount,
    ScheduleCount,
    LastRunOutcome,
    LastRunDateTime,
    LastRunDuration,
    IsRunning,
    CurrentStepName
)
SELECT
    SortOrder = CASE @SortByUpper
                    WHEN 'CATEGORY' THEN ROW_NUMBER() OVER (ORDER BY ISNULL(c.name, N''), j.name)
                    WHEN 'OWNER'    THEN ROW_NUMBER() OVER (ORDER BY ISNULL(sp.name, N''), j.name)
                    WHEN 'ENABLED'  THEN ROW_NUMBER() OVER (ORDER BY j.enabled DESC, j.name)
                    ELSE ROW_NUMBER() OVER (ORDER BY j.name)
                END,
    j.job_id,
    j.name,
    j.enabled,
    CategoryName = c.name,
    OwnerName = sp.name,
    Description = CONVERT(nvarchar(512), j.description),
    j.date_created,
    j.date_modified,
    j.start_step_id,
    j.notify_level_email,
    j.delete_level,
    StepCount =
    (
        SELECT COUNT(*)
          FROM msdb.dbo.sysjobsteps AS st
         WHERE st.job_id = j.job_id
    ),
    ScheduleCount =
    (
        SELECT COUNT(*)
          FROM msdb.dbo.sysjobschedules AS jsched
         WHERE jsched.job_id = j.job_id
    ),
    LastRunOutcome = CASE lh.run_status
                         WHEN 0 THEN 'Failed'
                         WHEN 1 THEN 'Succeeded'
                         WHEN 2 THEN 'Retry'
                         WHEN 3 THEN 'Canceled'
                         WHEN 4 THEN 'In progress'
                         ELSE CASE WHEN lh.job_id IS NULL THEN 'Never run' ELSE 'Unknown' END
                     END,
    LastRunDateTime = CASE
                          WHEN lh.run_date IS NULL OR lh.run_date = 0 THEN NULL
                          ELSE CONVERT(varchar(10),
                                       CONVERT(datetime, CONVERT(char(8), lh.run_date)), 120)
                               + ' '
                               + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(lh.run_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                      END,
    LastRunDuration = CASE
                          WHEN lh.run_duration IS NULL THEN NULL
                          ELSE RIGHT('00' + CAST(lh.run_duration / 10000 AS varchar(10)), 2)
                               + ':'
                               + RIGHT('00' + CAST((lh.run_duration % 10000) / 100 AS varchar(10)), 2)
                               + ':'
                               + RIGHT('00' + CAST(lh.run_duration % 100 AS varchar(10)), 2)
                      END,
    IsRunning = CASE WHEN r.job_id IS NOT NULL THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END,
    CurrentStepName = r.CurrentStepName
  FROM msdb.dbo.sysjobs AS j
  LEFT JOIN msdb.dbo.syscategories AS c
    ON c.category_id = j.category_id
  LEFT JOIN sys.server_principals AS sp
    ON sp.sid = j.owner_sid
  LEFT JOIN LastHistory AS lh
    ON lh.job_id = j.job_id
   AND lh.RowNum = 1
  LEFT JOIN Running AS r
    ON r.job_id = j.job_id
 WHERE j.name LIKE @JobFilter
   AND ISNULL(c.name, N'') LIKE @CategoryFilter
   AND (@EnabledOnly = 0 OR j.enabled = 1)

SELECT
    @TotalJobs       = COUNT(*),
    @EnabledJobs     = SUM(CASE WHEN JobEnabled = 1 THEN 1 ELSE 0 END),
    @DisabledJobs    = SUM(CASE WHEN JobEnabled = 0 THEN 1 ELSE 0 END),
    @ScheduledJobs   = SUM(CASE WHEN ScheduleCount > 0 THEN 1 ELSE 0 END),
    @UnscheduledJobs = SUM(CASE WHEN ScheduleCount = 0 THEN 1 ELSE 0 END),
    @TotalSteps      = SUM(StepCount),
    @TotalSchedules  = SUM(ScheduleCount),
    @RunningJobs     = SUM(CASE WHEN IsRunning = 1 THEN 1 ELSE 0 END),
    @FailedLastRun   = SUM(CASE WHEN LastRunOutcome = 'Failed' THEN 1 ELSE 0 END)
  FROM #Jobs

SET @TotalJobs       = ISNULL(@TotalJobs, 0)
SET @EnabledJobs     = ISNULL(@EnabledJobs, 0)
SET @DisabledJobs    = ISNULL(@DisabledJobs, 0)
SET @ScheduledJobs   = ISNULL(@ScheduledJobs, 0)
SET @UnscheduledJobs = ISNULL(@UnscheduledJobs, 0)
SET @TotalSteps      = ISNULL(@TotalSteps, 0)
SET @TotalSchedules  = ISNULL(@TotalSchedules, 0)
SET @RunningJobs     = ISNULL(@RunningJobs, 0)
SET @FailedLastRun   = ISNULL(@FailedLastRun, 0)

---------------------------------------------------------------------------------------------------
-- Collect schedules
---------------------------------------------------------------------------------------------------
IF @IncludeSchedules = 1 AND @TotalJobs > 0
BEGIN
    INSERT INTO #Schedules
    (
        JobId,
        ScheduleId,
        ScheduleName,
        ScheduleEnabled,
        Frequency,
        IntervalText,
        TimeText,
        ActiveWindow,
        NextRunText
    )
    SELECT
        jsch.job_id,
        ss.schedule_id,
        ss.name,
        ss.enabled,
        Frequency = CASE ss.freq_type
                        WHEN 1 THEN 'Once'
                        WHEN 4 THEN CASE
                                        WHEN ss.freq_recurrence_factor > 1
                                            THEN 'Every ' + CAST(ss.freq_recurrence_factor AS varchar(10)) + ' days'
                                        ELSE 'Daily'
                                    END
                        WHEN 8 THEN CASE
                                        WHEN ss.freq_recurrence_factor > 1
                                            THEN 'Every ' + CAST(ss.freq_recurrence_factor AS varchar(10)) + ' weeks'
                                        ELSE 'Weekly'
                                    END
                        WHEN 16 THEN CASE
                                         WHEN ss.freq_recurrence_factor > 1
                                             THEN 'Every ' + CAST(ss.freq_recurrence_factor AS varchar(10)) + ' months'
                                         ELSE 'Monthly'
                                     END
                        WHEN 32 THEN CASE
                                         WHEN ss.freq_recurrence_factor > 1
                                             THEN 'Every ' + CAST(ss.freq_recurrence_factor AS varchar(10)) + ' months (rel)'
                                         ELSE 'Monthly (relative)'
                                     END
                        WHEN 64 THEN 'SQL Agent start'
                        WHEN 128 THEN 'CPU idle'
                        ELSE 'Other'
                    END,
        IntervalText = CASE
                           WHEN ss.freq_type = 1 THEN 'One time only'
                           WHEN ss.freq_type = 4 AND ss.freq_interval = 1 THEN 'Every day'
                           WHEN ss.freq_type = 4 AND ss.freq_interval > 1
                               THEN 'Every ' + CAST(ss.freq_interval AS varchar(10)) + ' days'
                           WHEN ss.freq_type = 8 THEN
                               CASE WHEN ss.freq_interval & 1  <> 0 THEN 'Sun ' ELSE '' END
                             + CASE WHEN ss.freq_interval & 2  <> 0 THEN 'Mon ' ELSE '' END
                             + CASE WHEN ss.freq_interval & 4  <> 0 THEN 'Tue ' ELSE '' END
                             + CASE WHEN ss.freq_interval & 8  <> 0 THEN 'Wed ' ELSE '' END
                             + CASE WHEN ss.freq_interval & 16 <> 0 THEN 'Thu ' ELSE '' END
                             + CASE WHEN ss.freq_interval & 32 <> 0 THEN 'Fri ' ELSE '' END
                             + CASE WHEN ss.freq_interval & 64 <> 0 THEN 'Sat ' ELSE '' END
                           WHEN ss.freq_type = 16
                               THEN 'Day ' + CAST(ss.freq_interval AS varchar(10)) + ' of month'
                           WHEN ss.freq_type = 32 THEN
                               CASE ss.freq_relative_interval
                                   WHEN 1 THEN 'First '
                                   WHEN 2 THEN 'Second '
                                   WHEN 4 THEN 'Third '
                                   WHEN 8 THEN 'Fourth '
                                   WHEN 16 THEN 'Last '
                                   ELSE ''
                               END
                             + CASE ss.freq_interval
                                   WHEN 1 THEN 'Sunday'
                                   WHEN 2 THEN 'Monday'
                                   WHEN 3 THEN 'Tuesday'
                                   WHEN 4 THEN 'Wednesday'
                                   WHEN 5 THEN 'Thursday'
                                   WHEN 6 THEN 'Friday'
                                   WHEN 7 THEN 'Saturday'
                                   WHEN 8 THEN 'day'
                                   WHEN 9 THEN 'weekday'
                                   WHEN 10 THEN 'weekend day'
                                   ELSE 'day'
                               END
                           WHEN ss.freq_type IN (64, 128) THEN 'Event-driven'
                           ELSE 'n/a'
                       END,
        TimeText = CASE ss.freq_subday_type
                       WHEN 1 THEN
                           'At '
                           + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(ss.active_start_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                       WHEN 2 THEN
                           'Every ' + CAST(ss.freq_subday_interval AS varchar(10)) + ' sec'
                           + ' from '
                           + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(ss.active_start_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                           + ' to '
                           + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(ss.active_end_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                       WHEN 4 THEN
                           'Every ' + CAST(ss.freq_subday_interval AS varchar(10)) + ' min'
                           + ' from '
                           + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(ss.active_start_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                           + ' to '
                           + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(ss.active_end_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                       WHEN 8 THEN
                           'Every ' + CAST(ss.freq_subday_interval AS varchar(10)) + ' hr'
                           + ' from '
                           + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(ss.active_start_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                           + ' to '
                           + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(ss.active_end_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                       ELSE 'n/a'
                   END,
        ActiveWindow =
            CASE
                WHEN ss.active_start_date IS NULL OR ss.active_start_date = 0 THEN 'n/a'
                ELSE CONVERT(varchar(10), CONVERT(datetime, CONVERT(char(8), ss.active_start_date)), 120)
            END
            + ' .. '
            + CASE
                  WHEN ss.active_end_date IS NULL OR ss.active_end_date = 0 OR ss.active_end_date >= 99991231
                      THEN 'open'
                  ELSE CONVERT(varchar(10), CONVERT(datetime, CONVERT(char(8), ss.active_end_date)), 120)
              END,
        NextRunText = CASE
                          WHEN jsch.next_run_date IS NULL OR jsch.next_run_date = 0 THEN 'n/a'
                          ELSE CONVERT(varchar(10),
                                       CONVERT(datetime, CONVERT(char(8), jsch.next_run_date)), 120)
                               + ' '
                               + LEFT(STUFF(STUFF(RIGHT(REPLICATE('0', 6) + CAST(jsch.next_run_time AS varchar(6)), 6), 3, 0, ':'), 6, 0, ':'), 8)
                      END
      FROM #Jobs AS j
     INNER JOIN msdb.dbo.sysjobschedules AS jsch
        ON jsch.job_id = j.JobId
     INNER JOIN msdb.dbo.sysschedules AS ss
        ON ss.schedule_id = jsch.schedule_id
END

---------------------------------------------------------------------------------------------------
-- Collect steps
---------------------------------------------------------------------------------------------------
IF @IncludeSteps = 1 AND @TotalJobs > 0
BEGIN
    INSERT INTO #Steps
    (
        JobId,
        StepId,
        StepName,
        Subsystem,
        DatabaseName,
        DatabaseUserName,
        OnSuccessAction,
        OnSuccessStepId,
        OnFailAction,
        OnFailStepId,
        RetryAttempts,
        RetryInterval,
        Flags,
        ProxyName,
        CommandText
    )
    SELECT
        st.job_id,
        st.step_id,
        st.step_name,
        st.subsystem,
        st.database_name,
        st.database_user_name,
        OnSuccessAction = CASE st.on_success_action
                              WHEN 1 THEN 'Quit success'
                              WHEN 2 THEN 'Quit fail'
                              WHEN 3 THEN 'Go next'
                              WHEN 4 THEN 'Go step ' + CAST(st.on_success_step_id AS varchar(10))
                              ELSE 'Other'
                          END,
        st.on_success_step_id,
        OnFailAction = CASE st.on_fail_action
                           WHEN 1 THEN 'Quit success'
                           WHEN 2 THEN 'Quit fail'
                           WHEN 3 THEN 'Go next'
                           WHEN 4 THEN 'Go step ' + CAST(st.on_fail_step_id AS varchar(10))
                           ELSE 'Other'
                       END,
        st.on_fail_step_id,
        st.retry_attempts,
        st.retry_interval,
        st.flags,
        ProxyName = p.name,
        CommandText = CASE
                          WHEN @IncludeCommandText = 0 THEN NULL
                          ELSE REPLACE(REPLACE(REPLACE(REPLACE(
                                   LEFT(ISNULL(st.command, N''), @MaxCommandLength),
                                   CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' '), N'  ', N' ')
                      END
      FROM #Jobs AS j
     INNER JOIN msdb.dbo.sysjobsteps AS st
        ON st.job_id = j.JobId
      LEFT JOIN msdb.dbo.sysproxies AS p
        ON p.proxy_id = st.proxy_id
END

---------------------------------------------------------------------------------------------------
-- Build report header
---------------------------------------------------------------------------------------------------
INSERT INTO #Report (ReportLine)
SELECT LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT LEFT(' SQL AGENT JOB REPORT' + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(' Server: ' + @ServerName
            + '  ' + @ReportTime + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(' SQL Server ' + @ProductVersion + ' ' + ISNULL(@ProductLevel, '')
            + '  |  ' + LEFT(ISNULL(@Edition, ''), 28) + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT LEFT(' SUMMARY' + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(@Divider, @ReportWidth)
UNION ALL
SELECT LEFT(' Jobs: ' + CAST(@TotalJobs AS varchar(10))
            + ' total  |  ' + CAST(@EnabledJobs AS varchar(10)) + ' enabled'
            + '  |  ' + CAST(@DisabledJobs AS varchar(10)) + ' disabled'
            + '  |  ' + CAST(@RunningJobs AS varchar(10)) + ' running now'
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(' Schedules: ' + CAST(@TotalSchedules AS varchar(10))
            + ' linked  |  ' + CAST(@ScheduledJobs AS varchar(10)) + ' jobs with schedule'
            + '  |  ' + CAST(@UnscheduledJobs AS varchar(10)) + ' without schedule'
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(' Steps: ' + CAST(@TotalSteps AS varchar(10))
            + '  |  last-run failed (outcome): ' + CAST(@FailedLastRun AS varchar(10))
            + '  |  filter job: ' + CONVERT(CAST(@JobFilter AS varchar(40)), 40)
            + '  |  sort: ' + @SortByUpper
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(' Options: schedules=' + CASE WHEN @IncludeSchedules = 1 THEN 'Y' ELSE 'N' END
            + ' steps=' + CASE WHEN @IncludeSteps = 1 THEN 'Y' ELSE 'N' END
            + ' command=' + CASE WHEN @IncludeCommandText = 1 THEN 'Y' ELSE 'N' END
            + '  |  category filter: ' + LEFT(CAST(@CategoryFilter AS varchar(40)), 40)
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(@Divider, @ReportWidth)

IF @TotalJobs = 0
BEGIN
    INSERT INTO #Report (ReportLine)
    SELECT LEFT(' No SQL Agent jobs matched the current filters.' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT LEFT(@HeaderRule, @ReportWidth)

    SELECT ReportLine
      FROM #Report
     ORDER BY [LineNo]

    RETURN 0
END

---------------------------------------------------------------------------------------------------
-- Per-job sections
---------------------------------------------------------------------------------------------------
DECLARE job_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        JobId,
        JobName,
        JobEnabled,
        CategoryName,
        OwnerName,
        Description,
        DateCreated,
        DateModified,
        StartStepId,
        NotifyLevelEmail,
        DeleteLevel,
        StepCount,
        ScheduleCount,
        LastRunOutcome,
        LastRunDateTime,
        LastRunDuration,
        IsRunning,
        CurrentStepName
      FROM #Jobs
     ORDER BY SortOrder

OPEN job_cursor

FETCH NEXT FROM job_cursor INTO
    @JobId, @JobName, @JobEnabled, @CategoryName, @OwnerName, @Description,
    @DateCreated, @DateModified, @StartStepId, @NotifyLevelEmail, @DeleteLevel,
    @StepCount, @ScheduleCount, @LastRunOutcome, @LastRunDateTime, @LastRunDuration,
    @IsRunning, @CurrentStepName

WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO #Report (ReportLine)
    SELECT LEFT(@BlankLine, @ReportWidth)
    UNION ALL
    SELECT LEFT(@HeaderRule, @ReportWidth)
    UNION ALL
    SELECT LEFT(
               ' JOB: ' + LEFT(CAST(@JobName AS varchar(80)), 70)
               + '  [' + CASE WHEN @JobEnabled = 1 THEN 'Enabled' ELSE 'DISABLED' END + ']'
               + CASE WHEN @IsRunning = 1 THEN '  ** RUNNING **' ELSE '' END
               + @BlankLine,
               @ReportWidth)
    UNION ALL
    SELECT LEFT(
               ' Category: ' + LEFT(ISNULL(CAST(@CategoryName AS varchar(40)), '(none)'), 28)
               + '  Owner: ' + LEFT(ISNULL(CAST(@OwnerName AS varchar(40)), '(unknown)'), 28)
               + '  Start step: ' + CAST(ISNULL(@StartStepId, 1) AS varchar(10))
               + @BlankLine,
               @ReportWidth)
    UNION ALL
    SELECT LEFT(
               ' Created: ' + ISNULL(CONVERT(varchar(19), @DateCreated, 120), 'n/a')
               + '  Modified: ' + ISNULL(CONVERT(varchar(19), @DateModified, 120), 'n/a')
               + '  Steps: ' + CAST(@StepCount AS varchar(10))
               + '  Schedules: ' + CAST(@ScheduleCount AS varchar(10))
               + @BlankLine,
               @ReportWidth)
    UNION ALL
    SELECT LEFT(
               ' Last run: ' + ISNULL(@LastRunOutcome, 'Never run')
               + CASE WHEN @LastRunDateTime IS NOT NULL THEN ' at ' + @LastRunDateTime ELSE '' END
               + CASE WHEN @LastRunDuration IS NOT NULL THEN '  duration ' + @LastRunDuration ELSE '' END
               + CASE WHEN @IsRunning = 1
                      THEN '  current step: ' + LEFT(ISNULL(CAST(@CurrentStepName AS varchar(40)), '?'), 40)
                      ELSE ''
                 END
               + @BlankLine,
               @ReportWidth)

    IF NULLIF(LTRIM(RTRIM(ISNULL(@Description, N''))), N'') IS NOT NULL
       AND UPPER(LTRIM(RTRIM(@Description))) NOT IN (N'NO DESCRIPTION AVAILABLE.', N'NO DESCRIPTION AVAILABLE')
    BEGIN
        INSERT INTO #Report (ReportLine)
        SELECT LEFT(' Description: ' + LEFT(REPLACE(REPLACE(REPLACE(
                     CAST(@Description AS varchar(200)), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' '), 100)
                    + @BlankLine, @ReportWidth)
    END

    INSERT INTO #Report (ReportLine)
    SELECT LEFT(@Divider, @ReportWidth)

    /* Schedules (emit each schedule's lines together) */
    IF @IncludeSchedules = 1
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM #Schedules WHERE JobId = @JobId)
        BEGIN
            INSERT INTO #Report (ReportLine)
            SELECT LEFT(' SCHEDULES: (none attached)' + @BlankLine, @ReportWidth)
        END
        ELSE
        BEGIN
            INSERT INTO #Report (ReportLine)
            SELECT LEFT(' SCHEDULES' + @BlankLine, @ReportWidth)

            DECLARE sched_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT
                    ScheduleName,
                    ScheduleEnabled,
                    Frequency,
                    IntervalText,
                    TimeText,
                    ActiveWindow,
                    NextRunText
                  FROM #Schedules
                 WHERE JobId = @JobId
                 ORDER BY ScheduleName, ScheduleId

            OPEN sched_cursor
            FETCH NEXT FROM sched_cursor INTO
                @SchedName, @SchedEnabled, @SchedFrequency, @SchedInterval,
                @SchedTime, @SchedWindow, @SchedNext

            WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT INTO #Report (ReportLine)
                SELECT LEFT(
                           '  * '
                           + LEFT(ISNULL(CAST(@SchedName AS varchar(40)), '(unnamed)') + @BlankLine, 28)
                           + ' [' + CASE WHEN @SchedEnabled = 1 THEN 'On' ELSE 'Off' END + '] '
                           + LEFT(@SchedFrequency + @BlankLine, 18)
                           + ' '
                           + LEFT(@SchedInterval + @BlankLine, 28)
                           + ' '
                           + LEFT(@SchedTime + @BlankLine, 30),
                           @ReportWidth)
                UNION ALL
                SELECT LEFT(
                           '    window: ' + @SchedWindow
                           + '  next run: ' + @SchedNext
                           + @BlankLine,
                           @ReportWidth)

                FETCH NEXT FROM sched_cursor INTO
                    @SchedName, @SchedEnabled, @SchedFrequency, @SchedInterval,
                    @SchedTime, @SchedWindow, @SchedNext
            END

            CLOSE sched_cursor
            DEALLOCATE sched_cursor
        END

        INSERT INTO #Report (ReportLine)
        SELECT LEFT(@Divider, @ReportWidth)
    END

    /* Steps (emit each step's lines together) */
    IF @IncludeSteps = 1
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM #Steps WHERE JobId = @JobId)
        BEGIN
            INSERT INTO #Report (ReportLine)
            SELECT LEFT(' STEPS: (none defined)' + @BlankLine, @ReportWidth)
        END
        ELSE
        BEGIN
            INSERT INTO #Report (ReportLine)
            SELECT LEFT(' STEPS' + @BlankLine, @ReportWidth)

            DECLARE step_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT
                    StepId,
                    StepName,
                    Subsystem,
                    DatabaseName,
                    DatabaseUserName,
                    OnSuccessAction,
                    OnFailAction,
                    RetryAttempts,
                    RetryInterval,
                    ProxyName,
                    CommandText
                  FROM #Steps
                 WHERE JobId = @JobId
                 ORDER BY StepId

            OPEN step_cursor
            FETCH NEXT FROM step_cursor INTO
                @StepId, @StepName, @Subsystem, @StepDatabase, @StepDbUser,
                @OnSuccess, @OnFail, @RetryAttempts, @RetryInterval, @ProxyName, @CommandText

            WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT INTO #Report (ReportLine)
                SELECT LEFT(
                           '  '
                           + RIGHT('  ' + CAST(@StepId AS varchar(4)), 2)
                           + '. '
                           + LEFT(CAST(@StepName AS varchar(40)) + @BlankLine, 34)
                           + ' ['
                           + LEFT(CAST(@Subsystem AS varchar(16)) + @BlankLine, 12)
                           + '] DB='
                           + LEFT(ISNULL(CAST(@StepDatabase AS varchar(30)), '-') + @BlankLine, 20)
                           + ' ok->'
                           + LEFT(@OnSuccess + @BlankLine, 14)
                           + ' fail->'
                           + LEFT(@OnFail + @BlankLine, 12),
                           @ReportWidth)

                IF @RetryAttempts > 0
                   OR @ProxyName IS NOT NULL
                   OR NULLIF(@StepDbUser, N'') IS NOT NULL
                BEGIN
                    INSERT INTO #Report (ReportLine)
                    SELECT LEFT(
                               '     retry=' + CAST(@RetryAttempts AS varchar(6))
                               + 'x/' + CAST(@RetryInterval AS varchar(6)) + 'min'
                               + CASE WHEN @ProxyName IS NOT NULL
                                      THEN '  proxy=' + LEFT(CAST(@ProxyName AS varchar(40)), 30)
                                      ELSE ''
                                 END
                               + CASE WHEN NULLIF(@StepDbUser, N'') IS NOT NULL
                                      THEN '  runas=' + LEFT(CAST(@StepDbUser AS varchar(40)), 30)
                                      ELSE ''
                                 END
                               + @BlankLine,
                               @ReportWidth)
                END

                IF @IncludeCommandText = 1
                   AND NULLIF(LTRIM(RTRIM(ISNULL(@CommandText, N''))), N'') IS NOT NULL
                BEGIN
                    INSERT INTO #Report (ReportLine)
                    SELECT LEFT(
                               '     cmd: '
                               + LEFT(ISNULL(CAST(@CommandText AS varchar(200)), '(empty)') + @BlankLine, @MaxCommandLength)
                               + CASE
                                     WHEN LEN(ISNULL(@CommandText, N'')) >= @MaxCommandLength THEN '...'
                                     ELSE ''
                                 END
                               + @BlankLine,
                               @ReportWidth)
                END

                FETCH NEXT FROM step_cursor INTO
                    @StepId, @StepName, @Subsystem, @StepDatabase, @StepDbUser,
                    @OnSuccess, @OnFail, @RetryAttempts, @RetryInterval, @ProxyName, @CommandText
            END

            CLOSE step_cursor
            DEALLOCATE step_cursor
        END
    END

    FETCH NEXT FROM job_cursor INTO
        @JobId, @JobName, @JobEnabled, @CategoryName, @OwnerName, @Description,
        @DateCreated, @DateModified, @StartStepId, @NotifyLevelEmail, @DeleteLevel,
        @StepCount, @ScheduleCount, @LastRunOutcome, @LastRunDateTime, @LastRunDuration,
        @IsRunning, @CurrentStepName
END

CLOSE job_cursor
DEALLOCATE job_cursor

INSERT INTO #Report (ReportLine)
SELECT LEFT(@BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT LEFT(' Legend: Last run uses job outcome history (step_id = 0). Next run from sysjobschedules.' + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(' Note: Command text is truncated. Review full steps in SSMS or msdb.dbo.sysjobsteps.' + @BlankLine, @ReportWidth)
UNION ALL
SELECT LEFT(@HeaderRule, @ReportWidth)

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

RETURN 0
GO

PRINT 'Procedure dbo.ShowAgentJobReport created successfully.'
GO
