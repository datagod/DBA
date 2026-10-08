/*
  ShowBlackBoxTraces.sql

  Recent events from the instance default trace and any running black-box
  trace, or from one trace id you name.

  Requires SQL Server 2012 (11.x) or later. The script avoids CREATE OR ALTER
  and DROP IF EXISTS so it still deploys on 2012, 2014, and 2016 RTM.
  SQL Server 2022 is the expected local instance; the same script is what
  gets deployed onto older hosts.

  Deploy to the tool database, then execute:

      EXEC dbo.ShowBlackBoxTraces

      EXEC dbo.ShowBlackBoxTraces
           @TraceID     = 1,
           @TopN        = 50,
           @StartTime   = '2026-10-01',
           @EventFilter = N'%Auto Grow%'

      -- 0 means every matching event in the files that were opened
      EXEC dbo.ShowBlackBoxTraces
           @DatabaseName = N'YourDatabase',
           @TopN         = 0

  Parameters
      @TraceID       NULL reads the running default trace and any running
                     black-box trace (sp_trace_create option 8). A number
                     reads that trace id from sys.traces, including a
                     stopped trace whose file is still on disk.
      @TopN          How many of the newest matching events to return.
                     NULL or omitted is 100. 0 returns every matching event.
                     A negative value is rejected.
      @StartTime     Keep events at or after this time. NULL keeps all times.
      @EventFilter   Event name from sys.trace_events, or an event-class
                     number such as N'92'. If the value contains % or [,
                     it is a LIKE pattern. Otherwise it is an exact,
                     case-insensitive match, so underscores stay literal.
      @DatabaseName  Same match rules as @EventFilter, applied to DatabaseName.

  Permissions
      ALTER TRACE. Without it the procedure returns a Message row and
      does not raise. sys.fn_trace_gettable and sys.traces both require
      that permission.

  Rollover files
      sys.traces.path is the file currently being written, for example
      ...\Log\log_142.trc. fn_trace_gettable(path, DEFAULT) then looks for
      log_142_1.trc, not for log_141.trc. The default trace does not keep a
      log.trc parent; it keeps several log_N.trc siblings (five 20 MB files
      unless max_files says otherwise). This procedure opens each sibling
      with number_files = 1, newest first.

      A black-box trace is blackbox.trc plus blackbox_N.trc (filecount
      defaults to 2). A normal rollover trace whose current file is
      name_N.trc is walked back through name.trc, at most 256 files.
      A current file that is still the unnumbered base has not rolled yet,
      so only that file is opened. Names that already end in _digits are
      ambiguous to fn_trace_gettable; StartPerformanceTrace avoids that
      pattern on purpose.

  Duration
      SQL Trace stores Duration in microseconds and CPU in milliseconds.
      The result uses DurationMilliseconds, DurationSeconds, and
      DurationMicroseconds so the unit is in the column name. CPU is
      returned as CpuMilliseconds, unchanged.

      For data-file and log-file auto grow (event classes 92 and 93),
      IntegerData is the growth in 8 KB pages. FileGrowthMB converts that
      to megabytes. Other events leave FileGrowthMB NULL and IntegerData
      keeps whatever that event class stores.

  This is not the Performance Tuning Framework trace. StartPerformanceTrace,
  StopPerformanceTrace, and ShowTraceInfo record their own traces in
  PerformanceTraceControl. ShowDecodedTrace decodes a table you already
  imported. ShowBlackBoxTraces reads the server trace files directly.

  When there is nothing to show (no trace, default trace disabled, rowset
  trace, or the files cannot be read), the procedure returns one Message
  column and does not raise. Invalid @TopN and an instance older than
  SQL Server 2012 still raise.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowBlackBoxTraces') IS NOT NULL
BEGIN
    PRINT 'Dropping procedure: ShowBlackBoxTraces'
    DROP PROCEDURE dbo.ShowBlackBoxTraces
END
GO

PRINT 'Creating procedure: ShowBlackBoxTraces'
GO

CREATE PROCEDURE dbo.ShowBlackBoxTraces
(
    @TraceID      int           = NULL,
    @TopN         int           = 100,
    @StartTime    datetime      = NULL,
    @EventFilter  nvarchar(128) = NULL,
    @DatabaseName nvarchar(128) = NULL
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: January 29, 2023
-- Author:       ChatGPT
-- Description:  Returns the newest events from the instance default trace and any running
--               black-box trace, or from a single trace id. Decodes event class and subclass,
--               and reads the rollover files that belong to that trace. Requires ALTER TRACE
--               and SQL Server 2012 or later. Does not read PerformanceTraceResults.
---------------------------------------------------------------------------------------------------
-- Version:      1.0
-- Date Revised: January 29, 2023
-- Author:       ChatGPT
-- Reason:       Initial script. It referenced a path column on sys.fn_trace_getinfo. That
--               function returns traceid, property, and value, so the procedure failed
--               when created or run.
---------------------------------------------------------------------------------------------------
-- Version:      1.1
-- Date Revised: October 8, 2026
-- Author:       William McEvoy
-- Reason:       Read running file traces from sys.traces instead of fn_trace_getinfo.path.
--               Open each rollover sibling separately, because fn_trace_gettable does not
--               walk log_N.trc back to log_(N-1).trc. Decode names, convert duration from
--               microseconds, and return a message (not an error) when the default trace
--               is disabled, the trace is a rowset, or ALTER TRACE is missing.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON
SET XACT_ABORT OFF

---------------------------------------------------------------------
-- Locals                                                          --
---------------------------------------------------------------------
DECLARE
    @MajorVersion        tinyint,
    @ProductVersion      varchar(30),
    @DefaultTraceEnabled int,
    @EventLike           bit,
    @DatabaseLike        bit,
    @EventClassNumber    int,
    @HasEventFilter      bit,
    @Message             nvarchar(max),
    @RowID               int,
    @CurrentTraceID      int,
    @ActivePath          nvarchar(260),
    @MaxFiles            int,
    @IsRollover          bit,
    @IsDefault           bit,
    @IsBlackBox          bit,
    @TraceRole           nvarchar(20),
    @TraceStatus         nvarchar(10),
    @FileName            nvarchar(260),
    @Directory           nvarchar(260),
    @Stem                nvarchar(260),
    @BaseStem            nvarchar(260),
    @Suffix              nvarchar(20),
    @Sequence            int,
    @FileWindow          int,
    @Lowest              int,
    @n                   int,
    @Candidate           nvarchar(260),
    @PosBack             int,
    @PosFwd              int,
    @Pos                 int,
    @RevUs               int,
    @FileID              int,
    @CurrentFile         nvarchar(260),
    @IsActiveFile        bit,
    @LoadedForTrace      int,
    @Sql                 nvarchar(max),
    @Expr                nvarchar(max),
    @Where               nvarchar(max),
    @Piece               nvarchar(400),
    @ColName             sysname,
    @SqlType             nvarchar(30),
    @Kind                varchar(10),
    @Ordinal             int,
    @MaxOrdinal          int,
    @ErrNum              int,
    @ErrMsg              nvarchar(4000),
    @ErrorID             int,
    @Loaded              int,
    @RowLimit            int,
    @Banner              nvarchar(max)

DECLARE @FileErrors TABLE
(
    ErrorID      int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    TraceID      int NULL,
    FilePath     nvarchar(260) NULL,
    ErrorNumber  int NULL,
    ErrorMessage nvarchar(4000) NULL,
    IsActiveFile bit NOT NULL
)

DECLARE @ColumnMap TABLE
(
    Ordinal    int          NOT NULL PRIMARY KEY,
    ColumnName sysname      NOT NULL,
    SqlType    nvarchar(30) NOT NULL,
    Kind       varchar(10)  NOT NULL
)

---------------------------------------------------------------------
-- Version: SQL Server 2012 (11.x) or later                        --
---------------------------------------------------------------------
SET @ProductVersion = CONVERT(varchar(30), SERVERPROPERTY('ProductVersion'))
SET @MajorVersion = CONVERT(tinyint,
    LEFT(@ProductVersion, NULLIF(CHARINDEX('.', @ProductVersion), 0) - 1))

IF @MajorVersion < 11
BEGIN
    RAISERROR('ShowBlackBoxTraces requires SQL Server 2012 (11.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

---------------------------------------------------------------------
-- Parameters                                                      --
---------------------------------------------------------------------
IF @TopN IS NULL
    SET @TopN = 100

IF @TopN < 0
BEGIN
    RAISERROR('@TopN must be NULL (treated as 100), 0 (every matching event), or a positive row limit.', 16, 1)
    RETURN
END

SET @EventFilter = NULLIF(LTRIM(RTRIM(@EventFilter)), N'')
SET @DatabaseName = NULLIF(LTRIM(RTRIM(@DatabaseName)), N'')

SET @EventLike = CASE
                     WHEN @EventFilter IS NOT NULL
                      AND (CHARINDEX(N'%', @EventFilter) > 0 OR CHARINDEX(N'[', @EventFilter) > 0)
                     THEN 1
                     ELSE 0
                 END

SET @DatabaseLike = CASE
                        WHEN @DatabaseName IS NOT NULL
                         AND (CHARINDEX(N'%', @DatabaseName) > 0 OR CHARINDEX(N'[', @DatabaseName) > 0)
                        THEN 1
                        ELSE 0
                    END

SET @EventClassNumber = NULL
IF @EventFilter IS NOT NULL
   AND @EventLike = 0
   AND @EventFilter NOT LIKE N'%[^0-9]%'
   AND LEN(@EventFilter) BETWEEN 1 AND 9
    SET @EventClassNumber = TRY_CONVERT(int, @EventFilter)

SET @HasEventFilter = CASE WHEN @EventFilter IS NOT NULL THEN 1 ELSE 0 END

---------------------------------------------------------------------
-- Permission                                                      --
---------------------------------------------------------------------
IF ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, N'ALTER TRACE'), 0) <> 1
BEGIN
    SET @Message = N'ShowBlackBoxTraces needs ALTER TRACE on this server. '
                 + N'The current login cannot list sys.traces or read trace files. '
                 + N'Grant ALTER TRACE, then run the procedure again.'
    PRINT @Message
    SELECT Message = @Message
    RETURN
END

---------------------------------------------------------------------
-- Event-name filter, resolved once against the catalog           --
---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#EventClasses') IS NOT NULL
    DROP TABLE #EventClasses

CREATE TABLE #EventClasses
(
    EventClass int NOT NULL PRIMARY KEY
)

IF @HasEventFilter = 1
BEGIN
    INSERT INTO #EventClasses (EventClass)
    SELECT te.trace_event_id
      FROM sys.trace_events AS te
     WHERE (@EventLike = 1 AND te.name LIKE @EventFilter)
        OR (@EventLike = 0 AND @EventClassNumber IS NULL AND te.name = @EventFilter)
        OR (@EventClassNumber IS NOT NULL AND te.trace_event_id = @EventClassNumber)

    IF NOT EXISTS (SELECT 1 FROM #EventClasses)
    BEGIN
        SET @Message = N'No event in sys.trace_events matches @EventFilter = N'''
                     + REPLACE(@EventFilter, N'''', N'''''')
                     + N'''. Use an event name, a LIKE pattern such as N''%Auto Grow%'', '
                     + N'or an event-class number such as N''92''.'
        PRINT @Message
        SELECT Message = @Message
        RETURN
    END
END

---------------------------------------------------------------------
-- Choose traces                                                   --
---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Candidates') IS NOT NULL
    DROP TABLE #Candidates

CREATE TABLE #Candidates
(
    RowID              int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    TraceID            int NOT NULL,
    Status             int NOT NULL,
    TracePath          nvarchar(260) NULL,
    MaxFiles           int NULL,
    IsRowset           bit NOT NULL,
    IsRollover         bit NOT NULL,
    IsDefault          bit NOT NULL,
    IsBlackBox         bit NOT NULL,
    DroppedEventCount  int NULL,
    TraceStartTime     datetime NULL,
    LastEventTime      datetime NULL,
    TraceRole          nvarchar(20) NOT NULL,
    TraceStatus        nvarchar(10) NOT NULL
)

BEGIN TRY
    INSERT INTO #Candidates
    (
        TraceID,
        Status,
        TracePath,
        MaxFiles,
        IsRowset,
        IsRollover,
        IsDefault,
        IsBlackBox,
        DroppedEventCount,
        TraceStartTime,
        LastEventTime,
        TraceRole,
        TraceStatus
    )
    SELECT
        t.id,
        t.status,
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(260), t.path))), N''),
        t.max_files,
        CASE WHEN t.is_rowset = 1 OR NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(260), t.path))), N'') IS NULL
             THEN 1 ELSE 0 END,
        CASE WHEN t.is_rollover = 1 THEN 1 ELSE 0 END,
        CASE WHEN t.is_default = 1 THEN 1 ELSE 0 END,
        CASE
            WHEN fn.FileNameLower = N'blackbox.trc' THEN 1
            WHEN bb.BlackBoxSuffix IS NOT NULL
             AND bb.BlackBoxSuffix NOT LIKE N'%[^0-9]%'
            THEN 1
            ELSE 0
        END,
        t.dropped_event_count,
        t.start_time,
        t.last_event_time,
        N'File trace',
        CASE WHEN t.status = 1 THEN N'Running' ELSE N'Stopped' END
      FROM sys.traces AS t
     CROSS APPLY
     (
        SELECT FileNameLower =
            LOWER(
                CASE
                    WHEN t.path IS NULL THEN N''
                    WHEN CHARINDEX(N'\', REPLACE(t.path, N'/', N'\')) = 0 THEN CONVERT(nvarchar(260), t.path)
                    ELSE RIGHT(CONVERT(nvarchar(260), t.path), CHARINDEX(N'\', REVERSE(REPLACE(CONVERT(nvarchar(260), t.path), N'/', N'\'))) - 1)
                END
            )
     ) AS fn
     CROSS APPLY
     (
        -- CASE short-circuits, so the substring length is never negative.
        SELECT BlackBoxSuffix =
            CASE
                WHEN LEN(fn.FileNameLower) > 13
                 AND RIGHT(fn.FileNameLower, 4) = N'.trc'
                 AND LEFT(fn.FileNameLower, 9) = N'blackbox_'
                THEN SUBSTRING(fn.FileNameLower, 10, LEN(fn.FileNameLower) - 13)
                ELSE NULL
            END
     ) AS bb
     WHERE (@TraceID IS NOT NULL AND t.id = @TraceID)
        OR (@TraceID IS NULL AND t.status = 1)
     ORDER BY
        CASE WHEN t.is_default = 1 THEN 0 ELSE 1 END,
        t.id
END TRY
BEGIN CATCH
    SET @Message = N'Could not read sys.traces. ' + ERROR_MESSAGE()
                 + N' ShowBlackBoxTraces requires ALTER TRACE.'
    PRINT @Message
    SELECT Message = @Message
    RETURN
END CATCH

BEGIN TRY
    -- Property 1 is the sp_trace_create options mask. 8 = TRACE_PRODUCE_BLACKBOX.
    UPDATE c
       SET IsBlackBox = 1
      FROM #Candidates AS c
      INNER JOIN
      (
          SELECT
              g.traceid,
              TraceOptions = TRY_CONVERT(int, g.value)
            FROM sys.fn_trace_getinfo(DEFAULT) AS g
           WHERE g.property = 1
      ) AS opt
        ON opt.traceid = c.TraceID
     WHERE (opt.TraceOptions & 8) = 8
END TRY
BEGIN CATCH
    -- Filename detection above still marks a blackbox.trc path.
    SET @ErrNum = ERROR_NUMBER()
END CATCH

UPDATE #Candidates
   SET TraceRole = CASE
                       WHEN IsDefault = 1 THEN N'Default trace'
                       WHEN IsBlackBox = 1 THEN N'Black box'
                       ELSE N'File trace'
                   END

IF @TraceID IS NULL
    DELETE FROM #Candidates
     WHERE IsDefault = 0
       AND IsBlackBox = 0

IF @TraceID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #Candidates)
BEGIN
    SET @Message = N'Trace ' + CONVERT(nvarchar(11), @TraceID)
                 + N' was not found in sys.traces.'
    PRINT @Message
    SELECT Message = @Message
    RETURN
END

IF NOT EXISTS (SELECT 1 FROM #Candidates)
BEGIN
    SET @DefaultTraceEnabled = NULL

    BEGIN TRY
        SELECT @DefaultTraceEnabled = TRY_CONVERT(int, cfg.value_in_use)
          FROM sys.configurations AS cfg
         WHERE cfg.name = N'default trace enabled'
    END TRY
    BEGIN CATCH
        SET @DefaultTraceEnabled = NULL
    END CATCH

    SET @Message = N'No running default trace or black-box trace was found.'

    IF @DefaultTraceEnabled = 0
        SET @Message = @Message
                     + N' sys.configurations shows ''default trace enabled'' = 0.'
    ELSE IF @DefaultTraceEnabled = 1
        SET @Message = @Message
                     + N' ''default trace enabled'' is 1, but sys.traces has no running default trace.'
    ELSE IF EXISTS (SELECT 1 FROM sys.traces WHERE is_default = 1 AND status = 0)
        SET @Message = @Message + N' The default trace exists but is stopped.'

    SET @Message = @Message
                 + N' A black-box trace is a server-side trace created with option 8.'
                 + N' Pass @TraceID to read a specific file trace.'

    PRINT @Message
    SELECT Message = @Message
    RETURN
END

IF NOT EXISTS (SELECT 1 FROM #Candidates WHERE IsRowset = 0 AND TracePath IS NOT NULL)
BEGIN
    SELECT @Message = N'Trace ' + CONVERT(nvarchar(11), MIN(TraceID))
                    + N' is a rowset trace (sys.traces.path is NULL). '
                    + N'This procedure only reads file traces.'
      FROM #Candidates

    PRINT @Message
    SELECT Message = @Message
    RETURN
END

---------------------------------------------------------------------
-- Files to open, newest first within each trace                  --
---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#TraceFiles') IS NOT NULL
    DROP TABLE #TraceFiles

CREATE TABLE #TraceFiles
(
    FileID       int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    TraceID      int NOT NULL,
    ActivePath   nvarchar(260) NOT NULL,
    FilePath     nvarchar(260) NOT NULL,
    IsActiveFile bit NOT NULL,
    TraceRole    nvarchar(20) NOT NULL,
    TraceStatus  nvarchar(10) NOT NULL
)

SET @RowID = 0

WHILE 1 = 1
BEGIN
    SELECT @RowID = MIN(RowID)
      FROM #Candidates
     WHERE RowID > @RowID
       AND IsRowset = 0
       AND TracePath IS NOT NULL

    IF @RowID IS NULL
        BREAK

    SELECT
        @CurrentTraceID = TraceID,
        @ActivePath     = TracePath,
        @MaxFiles       = MaxFiles,
        @IsRollover     = IsRollover,
        @IsDefault      = IsDefault,
        @IsBlackBox     = IsBlackBox,
        @TraceRole      = TraceRole,
        @TraceStatus    = TraceStatus
      FROM #Candidates
     WHERE RowID = @RowID

    SET @PosBack = CHARINDEX(N'\', REVERSE(@ActivePath))
    SET @PosFwd = CHARINDEX(N'/', REVERSE(@ActivePath))

    IF @PosBack = 0
        SET @Pos = @PosFwd
    ELSE IF @PosFwd = 0
        SET @Pos = @PosBack
    ELSE IF @PosBack < @PosFwd
        SET @Pos = @PosBack
    ELSE
        SET @Pos = @PosFwd

    IF @Pos = 0
    BEGIN
        SET @Directory = N''
        SET @FileName = @ActivePath
    END
    ELSE
    BEGIN
        SET @FileName = RIGHT(@ActivePath, @Pos - 1)
        SET @Directory = LEFT(@ActivePath, LEN(@ActivePath) - @Pos + 1)
    END

    SET @Sequence = NULL
    SET @BaseStem = @FileName
    SET @Stem = @FileName

    IF LEN(@FileName) > 4 AND LOWER(RIGHT(@FileName, 4)) = N'.trc'
        SET @Stem = LEFT(@FileName, LEN(@FileName) - 4)

    SET @BaseStem = @Stem
    SET @RevUs = CHARINDEX(N'_', REVERSE(@Stem))

    IF @RevUs > 1
    BEGIN
        SET @Suffix = RIGHT(@Stem, @RevUs - 1)

        IF @Suffix NOT LIKE N'%[^0-9]%'
           AND LEN(@Suffix) BETWEEN 1 AND 9
            SET @Sequence = TRY_CONVERT(int, @Suffix)

        IF @Sequence IS NOT NULL
            SET @BaseStem = LEFT(@Stem, LEN(@Stem) - @RevUs)
    END

    IF @IsDefault = 1
        SET @FileWindow = COALESCE(NULLIF(@MaxFiles, 0), 5)
    ELSE IF @IsBlackBox = 1
        SET @FileWindow = COALESCE(NULLIF(@MaxFiles, 0), 2)
    ELSE IF @IsRollover = 1
    BEGIN
        SET @FileWindow = COALESCE(NULLIF(@MaxFiles, 0), 5)

        -- Walk back to the unnumbered base when the sequence is modest.
        -- Cap the walk so a trace that has rolled for a long time cannot
        -- turn one call into thousands of file opens. The default trace
        -- is handled above and stays at its small retained-file count.
        IF @MaxFiles IS NULL AND @Sequence IS NOT NULL
        BEGIN
            IF @Sequence + 1 < 256
                SET @FileWindow = @Sequence + 1
            ELSE
                SET @FileWindow = 256
        END
    END
    ELSE
        SET @FileWindow = 1

    IF @FileWindow > 256
        SET @FileWindow = 256

    IF @FileWindow < 1
        SET @FileWindow = 1

    INSERT INTO #TraceFiles
    (
        TraceID, ActivePath, FilePath, IsActiveFile, TraceRole, TraceStatus
    )
    VALUES
    (
        @CurrentTraceID, @ActivePath, @ActivePath, 1, @TraceRole, @TraceStatus
    )

    IF @Sequence IS NOT NULL AND @FileWindow > 1 AND LEN(@BaseStem) > 0
    BEGIN
        SET @Lowest = @Sequence - @FileWindow + 1
        IF @Lowest < 0
            SET @Lowest = 0

        SET @n = @Sequence - 1

        WHILE @n >= @Lowest
        BEGIN
            IF @n = 0
                SET @Candidate = @Directory + @BaseStem + N'.trc'
            ELSE
                SET @Candidate = @Directory + @BaseStem + N'_'
                               + CONVERT(nvarchar(11), @n) + N'.trc'

            IF @Candidate <> @ActivePath
               AND LOWER(@Candidate) <> LOWER(@ActivePath)
               AND NOT EXISTS (
                    SELECT 1
                      FROM #TraceFiles
                     WHERE TraceID = @CurrentTraceID
                       AND FilePath = @Candidate
               )
            BEGIN
                INSERT INTO #TraceFiles
                (
                    TraceID, ActivePath, FilePath, IsActiveFile, TraceRole, TraceStatus
                )
                VALUES
                (
                    @CurrentTraceID, @ActivePath, @Candidate, 0, @TraceRole, @TraceStatus
                )
            END

            SET @n = @n - 1
        END
    END
    ELSE IF @Sequence IS NULL AND @IsBlackBox = 1 AND @FileWindow > 1 AND LEN(@BaseStem) > 0
    BEGIN
        -- The other black-box file is older even when its suffix is higher.
        SET @n = 1

        WHILE @n < @FileWindow
        BEGIN
            SET @Candidate = @Directory + @BaseStem + N'_'
                           + CONVERT(nvarchar(11), @n) + N'.trc'

            IF NOT EXISTS (
                SELECT 1
                  FROM #TraceFiles
                 WHERE TraceID = @CurrentTraceID
                   AND FilePath = @Candidate
            )
            BEGIN
                INSERT INTO #TraceFiles
                (
                    TraceID, ActivePath, FilePath, IsActiveFile, TraceRole, TraceStatus
                )
                VALUES
                (
                    @CurrentTraceID, @ActivePath, @Candidate, 0, @TraceRole, @TraceStatus
                )
            END

            SET @n = @n + 1
        END
    END
END

IF EXISTS (SELECT 1 FROM #Candidates WHERE IsRowset = 1 OR TracePath IS NULL)
    PRINT 'A matching trace has no file path and was skipped. Rowset traces cannot be read with fn_trace_gettable.'

---------------------------------------------------------------------
-- Staging for decoded events                                      --
---------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Events') IS NOT NULL
    DROP TABLE #Events

CREATE TABLE #Events
(
    TraceID          int            NOT NULL,
    TraceRole        nvarchar(20)   NOT NULL,
    TraceStatus      nvarchar(10)   NOT NULL,
    SourceFile       nvarchar(260)  NOT NULL,
    EventClass       int            NULL,
    EventSubClass    int            NULL,
    TextData         nvarchar(max)  NULL,
    DatabaseID       int            NULL,
    DatabaseName     nvarchar(256)  NULL,
    ObjectName       nvarchar(256)  NULL,
    LoginName        nvarchar(256)  NULL,
    HostName         nvarchar(256)  NULL,
    ApplicationName  nvarchar(256)  NULL,
    SPID             int            NULL,
    Duration         bigint         NULL,
    CPU              int            NULL,
    Reads            bigint         NULL,
    Writes           bigint         NULL,
    RowCounts        bigint         NULL,
    StartTime        datetime       NULL,
    EndTime          datetime       NULL,
    EventSequence    bigint         NULL,
    Error            int            NULL,
    Severity         int            NULL,
    DatabaseFileName nvarchar(260)  NULL,
    IntegerData      bigint         NULL
)

INSERT INTO @ColumnMap (Ordinal, ColumnName, SqlType, Kind)
VALUES
    (1,  N'EventClass',       N'int',            N'number'),
    (2,  N'EventSubClass',    N'int',            N'number'),
    (3,  N'TextData',         N'nvarchar(max)',  N'string'),
    (4,  N'DatabaseID',       N'int',            N'number'),
    (5,  N'DatabaseName',     N'nvarchar(256)',  N'string'),
    (6,  N'ObjectName',       N'nvarchar(256)',  N'string'),
    (7,  N'LoginName',        N'nvarchar(256)',  N'string'),
    (8,  N'HostName',         N'nvarchar(256)',  N'string'),
    (9,  N'ApplicationName',  N'nvarchar(256)',  N'string'),
    (10, N'SPID',             N'int',            N'number'),
    (11, N'Duration',         N'bigint',         N'number'),
    (12, N'CPU',              N'int',            N'number'),
    (13, N'Reads',            N'bigint',         N'number'),
    (14, N'Writes',           N'bigint',         N'number'),
    (15, N'RowCounts',        N'bigint',         N'number'),
    (16, N'StartTime',        N'datetime',       N'time'),
    (17, N'EndTime',          N'datetime',       N'time'),
    (18, N'EventSequence',    N'bigint',         N'number'),
    (19, N'Error',            N'int',            N'number'),
    (20, N'Severity',         N'int',            N'number'),
    (21, N'FileName',         N'nvarchar(260)',  N'string'),
    (22, N'IntegerData',      N'bigint',         N'number')

SELECT @MaxOrdinal = MAX(Ordinal) FROM @ColumnMap

---------------------------------------------------------------------
-- Read each file                                                  --
-- #Raw is created only inside dynamic SQL so a missing rollover  --
-- file can be skipped without a compile error on the temp table. --
---------------------------------------------------------------------
SET @FileID = 0

WHILE 1 = 1
BEGIN
    SELECT @FileID = MIN(FileID)
      FROM #TraceFiles
     WHERE FileID > @FileID

    IF @FileID IS NULL
        BREAK

    SELECT
        @CurrentTraceID = TraceID,
        @CurrentFile    = FilePath,
        @IsActiveFile   = IsActiveFile,
        @TraceRole      = TraceRole,
        @TraceStatus    = TraceStatus
      FROM #TraceFiles
     WHERE FileID = @FileID

    IF @TopN > 0 AND @TraceRole <> N'Black box'
    BEGIN
        SELECT @LoadedForTrace = COUNT(*)
          FROM #Events
         WHERE TraceID = @CurrentTraceID

        IF @LoadedForTrace >= @TopN
            CONTINUE
    END

    EXEC sys.sp_executesql
        N'IF OBJECT_ID(N''tempdb..#Raw'') IS NOT NULL DROP TABLE #Raw;'

    BEGIN TRY
        SET @Sql = N'SELECT * INTO #Raw FROM sys.fn_trace_gettable(@FilePath, 1);'
        EXEC sys.sp_executesql
            @Sql,
            N'@FilePath nvarchar(260)',
            @FilePath = @CurrentFile
    END TRY
    BEGIN CATCH
        SET @ErrNum = ERROR_NUMBER()
        SET @ErrMsg = ERROR_MESSAGE()

        IF @IsActiveFile = 1
           OR (
                @ErrNum <> 567
                AND @ErrMsg NOT LIKE N'%does not exist%'
                AND @ErrMsg NOT LIKE N'%not a recognizable trace file%'
              )
        BEGIN
            INSERT INTO @FileErrors (TraceID, FilePath, ErrorNumber, ErrorMessage, IsActiveFile)
            VALUES (@CurrentTraceID, @CurrentFile, @ErrNum, @ErrMsg, @IsActiveFile)
        END
    END CATCH

    IF OBJECT_ID(N'tempdb..#Raw') IS NULL
        CONTINUE

    SET @Expr = N''
    SET @Ordinal = 1

    WHILE @Ordinal <= @MaxOrdinal
    BEGIN
        SELECT
            @ColName = ColumnName,
            @SqlType = SqlType,
            @Kind    = Kind
          FROM @ColumnMap
         WHERE Ordinal = @Ordinal

        IF EXISTS (
            SELECT 1
              FROM tempdb.sys.columns
             WHERE object_id = OBJECT_ID(N'tempdb..#Raw')
               AND name = @ColName
        )
        BEGIN
            IF @Kind = 'number'
                SET @Piece = N'TRY_CONVERT(' + @SqlType + N', ' + @ColName + N')'
            ELSE
                SET @Piece = N'CONVERT(' + @SqlType + N', ' + @ColName + N')'
        END
        ELSE
            SET @Piece = N'CONVERT(' + @SqlType + N', NULL)'

        IF @Expr = N''
            SET @Expr = @Piece
        ELSE
            SET @Expr = @Expr + N', ' + @Piece

        SET @Ordinal = @Ordinal + 1
    END

    SET @Where = N''

    IF @StartTime IS NOT NULL
    BEGIN
        IF EXISTS (
            SELECT 1
              FROM tempdb.sys.columns
             WHERE object_id = OBJECT_ID(N'tempdb..#Raw')
               AND name = N'StartTime'
        )
            SET @Where = @Where + N' AND StartTime >= @StartTime'
        ELSE
            SET @Where = @Where + N' AND 1 = 0'
    END

    IF @DatabaseName IS NOT NULL
    BEGIN
        IF EXISTS (
            SELECT 1
              FROM tempdb.sys.columns
             WHERE object_id = OBJECT_ID(N'tempdb..#Raw')
               AND name = N'DatabaseName'
        )
        BEGIN
            IF @DatabaseLike = 1
                SET @Where = @Where + N' AND DatabaseName LIKE @DatabaseName'
            ELSE
                SET @Where = @Where + N' AND DatabaseName = @DatabaseName'
        END
        ELSE
            SET @Where = @Where + N' AND 1 = 0'
    END

    IF @HasEventFilter = 1
    BEGIN
        IF EXISTS (
            SELECT 1
              FROM tempdb.sys.columns
             WHERE object_id = OBJECT_ID(N'tempdb..#Raw')
               AND name = N'EventClass'
        )
            SET @Where = @Where + N' AND EventClass IN (SELECT EventClass FROM #EventClasses)'
        ELSE
            SET @Where = @Where + N' AND 1 = 0'
    END

    SET @Sql = N'
INSERT INTO #Events
(
    TraceID, TraceRole, TraceStatus, SourceFile,
    EventClass, EventSubClass, TextData, DatabaseID, DatabaseName,
    ObjectName, LoginName, HostName, ApplicationName, SPID,
    Duration, CPU, Reads, Writes, RowCounts,
    StartTime, EndTime, EventSequence, Error, Severity,
    DatabaseFileName, IntegerData
)
SELECT
    @TraceID, @TraceRole, @TraceStatus, @FilePath, '
        + @Expr
        + N'
  FROM #Raw
 WHERE 1 = 1'
        + @Where

    BEGIN TRY
        EXEC sys.sp_executesql
            @Sql,
            N'@TraceID int, @TraceRole nvarchar(20), @TraceStatus nvarchar(10), @FilePath nvarchar(260), @StartTime datetime, @DatabaseName nvarchar(128)',
            @TraceID = @CurrentTraceID,
            @TraceRole = @TraceRole,
            @TraceStatus = @TraceStatus,
            @FilePath = @CurrentFile,
            @StartTime = @StartTime,
            @DatabaseName = @DatabaseName
    END TRY
    BEGIN CATCH
        INSERT INTO @FileErrors (TraceID, FilePath, ErrorNumber, ErrorMessage, IsActiveFile)
        VALUES (
            @CurrentTraceID,
            @CurrentFile,
            ERROR_NUMBER(),
            ERROR_MESSAGE(),
            @IsActiveFile
        )
    END CATCH

    EXEC sys.sp_executesql
        N'IF OBJECT_ID(N''tempdb..#Raw'') IS NOT NULL DROP TABLE #Raw;'
END

EXEC sys.sp_executesql
    N'IF OBJECT_ID(N''tempdb..#Raw'') IS NOT NULL DROP TABLE #Raw;'

---------------------------------------------------------------------
-- Nothing loaded                                                  --
---------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM #Events)
BEGIN
    IF EXISTS (SELECT 1 FROM @FileErrors)
    BEGIN
        PRINT 'ShowBlackBoxTraces could not read the trace file.'

        SELECT Message =
            N'Trace ' + CONVERT(nvarchar(11), TraceID)
            + N' could not be read from ' + FilePath
            + N'. ' + ErrorMessage
          FROM @FileErrors
         ORDER BY ErrorID
    END
    ELSE
    BEGIN
        SET @Message = N'The trace files were read, and no events matched.'

        IF @StartTime IS NOT NULL OR @EventFilter IS NOT NULL OR @DatabaseName IS NOT NULL
            SET @Message = @Message
                         + N' Clear @StartTime, @EventFilter, or @DatabaseName to widen the search.'

        PRINT @Message
        SELECT Message = @Message
    END

    RETURN
END

---------------------------------------------------------------------
-- Banner, then the newest matching rows                           --
---------------------------------------------------------------------
PRINT ' '
PRINT 'SHOW BLACK BOX TRACES'
PRINT '====================='

IF @TraceID IS NULL
   AND EXISTS (SELECT 1 FROM #Candidates WHERE IsBlackBox = 1)
   AND NOT EXISTS (SELECT 1 FROM #Candidates WHERE IsDefault = 1)
    PRINT 'No running default trace was included. Showing the black-box trace.'

PRINT ' '

SET @RowID = 0

WHILE 1 = 1
BEGIN
    SELECT @RowID = MIN(RowID)
      FROM #Candidates
     WHERE RowID > @RowID
       AND IsRowset = 0
       AND TracePath IS NOT NULL

    IF @RowID IS NULL
        BREAK

    SELECT @Banner =
        N'Trace ' + CONVERT(nvarchar(11), TraceID)
        + N' (' + TraceRole + N', ' + TraceStatus + N')  '
        + TracePath
        + CASE
              WHEN DroppedEventCount > 0
              THEN N'  (dropped events: ' + CONVERT(nvarchar(11), DroppedEventCount) + N')'
              ELSE N''
          END
      FROM #Candidates
     WHERE RowID = @RowID

    PRINT @Banner
END

SELECT @Loaded = COUNT(*) FROM #Events

IF @TopN = 0
    SET @Banner = N'Matching events loaded: ' + CONVERT(nvarchar(11), @Loaded)
                + N'. @TopN = 0, so every match is returned.'
ELSE
    SET @Banner = N'Matching events loaded: ' + CONVERT(nvarchar(11), @Loaded)
                + N'. Returning the newest ' + CONVERT(nvarchar(11), @TopN) + N'.'

IF @EventFilter IS NOT NULL
    SET @Banner = @Banner + N' Event filter: ' + @EventFilter + N'.'

IF @DatabaseName IS NOT NULL
    SET @Banner = @Banner + N' Database: ' + @DatabaseName + N'.'

PRINT @Banner

IF EXISTS (SELECT 1 FROM @FileErrors)
BEGIN
    SET @ErrorID = 0

    WHILE 1 = 1
    BEGIN
        SELECT @ErrorID = MIN(ErrorID)
          FROM @FileErrors
         WHERE ErrorID > @ErrorID

        IF @ErrorID IS NULL
            BREAK

        SELECT @Banner =
            N'Could not read ' + FilePath + N'. ' + ErrorMessage
          FROM @FileErrors
         WHERE ErrorID = @ErrorID

        PRINT @Banner
    END
END

PRINT ' '

IF @TopN = 0
    SET @RowLimit = 2147483647
ELSE
    SET @RowLimit = @TopN

SELECT TOP (@RowLimit)
    e.StartTime,
    EventName = te.name,
    EventCategory = tc.name,
    Subclass = sub.subclass_name,
    DatabaseName = COALESCE(NULLIF(e.DatabaseName, N''), DB_NAME(e.DatabaseID)),
    e.LoginName,
    e.HostName,
    e.ApplicationName,
    e.ObjectName,
    e.TextData,
    e.SPID,
    DurationMilliseconds = CONVERT(decimal(23, 3), CONVERT(float, e.Duration) / 1000e0),
    DurationSeconds = CONVERT(decimal(23, 6), CONVERT(float, e.Duration) / 1000000e0),
    DurationMicroseconds = e.Duration,
    CpuMilliseconds = e.CPU,
    e.Reads,
    e.Writes,
    e.RowCounts,
    FileGrowthMB = CASE
                       WHEN e.EventClass IN (92, 93) AND e.IntegerData IS NOT NULL
                       THEN CONVERT(decimal(18, 2), (CONVERT(float, e.IntegerData) * 8e0) / 1024e0)
                       ELSE NULL
                   END,
    e.DatabaseFileName,
    e.Error,
    e.Severity,
    e.TraceID,
    e.TraceRole,
    e.TraceStatus,
    e.EventClass,
    e.EventSubClass,
    e.EventSequence,
    e.SourceFile,
    e.IntegerData
  FROM #Events AS e
  LEFT JOIN sys.trace_events AS te
    ON te.trace_event_id = e.EventClass
  LEFT JOIN sys.trace_categories AS tc
    ON tc.category_id = te.category_id
 OUTER APPLY
 (
    SELECT TOP (1)
        tsv.subclass_name
      FROM sys.trace_subclass_values AS tsv
     WHERE tsv.trace_event_id = e.EventClass
       AND tsv.subclass_value = e.EventSubClass
       AND tsv.trace_column_id = 21
 ) AS sub
 ORDER BY
    e.StartTime DESC,
    e.EventSequence DESC,
    e.TraceID,
    e.SourceFile

GO

IF OBJECT_ID('dbo.ShowBlackBoxTraces') IS NOT NULL
    PRINT 'Procedure created'
ELSE
    PRINT 'Procedure NOT created'
GO
