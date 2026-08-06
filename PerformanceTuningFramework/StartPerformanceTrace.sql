/*
  StartPerformanceTrace.sql
  Performance Tuning Framework

  Deploy to the tool database after PerformanceTraceResults.sql.

  Path behavior:
    - When @TraceFilePath is NULL or empty, suggested trace locations are
      returned and no trace is created.
    - When @TraceFilePath is provided, the server-side trace is created.

  Optional filters:
    @DatabaseName, @MinReads, @MinWrites, @MinDuration,
    @LoginName, @HostName
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.StartPerformanceTrace
(
    @TraceName         sysname       = NULL,
    @DatabaseName      sysname       = NULL,
    @MinReads          bigint        = NULL,
    @MinWrites         bigint        = NULL,
    @MinDuration       bigint        = NULL,
    @LoginName         sysname       = NULL,
    @HostName          sysname       = NULL,
    @TraceFilePath     nvarchar(245) = NULL,
    @MaxFileSizeMB     bigint        = 100,
    @TraceControlID    int           = NULL OUTPUT
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Starts a server-side SQL Trace and records control metadata in the tool database.
--               Results are imported into PerformanceTraceResults when the trace is stopped.
--
--               If @TraceFilePath is not supplied, the procedure returns ranked path suggestions
--               and exits without creating a trace or writing any files.
---------------------------------------------------------------------------------------------------
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @TraceID               int,
        @ReturnCode            int,
        @TraceFileBase         nvarchar(245),
        @ResolvedPath          nvarchar(4000),
        @DefaultDataPath       nvarchar(260),
        @DefaultLogPath        nvarchar(260),
        @DefaultBackupPath     nvarchar(260),
        @ErrorLogFileName      nvarchar(260),
        @ErrorLogPath          nvarchar(260),
        @PathSeparator         nchar(1),
        @LastSeparatorPosition int,
        @StartTime             datetime,
        @EventID               int,
        @ColumnID              int,
        @FilterValue           nvarchar(256),
        @EventNumber           int,
        @EventCount            int,
        @ColumnNumber          int,
        @ColumnCount           int;

    SET @TraceControlID = NULL;
    SET @StartTime = GETDATE();

    IF @MaxFileSizeMB IS NULL
       OR @MaxFileSizeMB < 1
    BEGIN
        SET @MaxFileSizeMB = 100;
    END;

    /*
      Do not end the trace filename with underscore followed by digits.
      That pattern can interfere with rollover-file loading through
      sys.fn_trace_gettable.
    */
    IF NULLIF(LTRIM(RTRIM(@TraceName)), N'') IS NULL
    BEGIN
        SET @TraceName =
              N'PerfTrace-'
            + CONVERT(char(8), @StartTime, 112)
            + N'T'
            + REPLACE(CONVERT(char(12), @StartTime, 114), N':', N'');
    END;

    IF NULLIF(LTRIM(RTRIM(@TraceFilePath)), N'') IS NULL
    BEGIN
        SET @TraceFilePath = NULL;
    END;

    /*
      Collect SQL Server-owned path information.

      These values are only used to make suggestions. No folder, file,
      or trace is created in this branch.
    */
    SET @DefaultDataPath =
        CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultDataPath'));

    SET @DefaultLogPath =
        CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultLogPath'));

    SET @DefaultBackupPath =
        CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultBackupPath'));

    SET @ErrorLogFileName =
        CONVERT(nvarchar(260), SERVERPROPERTY('ErrorLogFileName'));

    /*
      Determine whether this instance uses Windows or Linux-style paths.
    */
    SET @PathSeparator =
        CASE
            WHEN COALESCE
                 (
                     @ErrorLogFileName,
                     @DefaultDataPath,
                     @DefaultLogPath,
                     @DefaultBackupPath
                 ) LIKE N'%/%'
                THEN N'/'
            ELSE N'\'
        END;

    /*
      Extract the directory containing the SQL Server error log.
    */
    IF @ErrorLogFileName IS NOT NULL
    BEGIN
        SET @LastSeparatorPosition =
            CHARINDEX(@PathSeparator, REVERSE(@ErrorLogFileName));

        IF @LastSeparatorPosition > 0
        BEGIN
            SET @ErrorLogPath =
                LEFT
                (
                    @ErrorLogFileName,
                    LEN(@ErrorLogFileName) - @LastSeparatorPosition + 1
                );
        END;
    END;

    /*
      No trace path was provided.

      Return suggested locations and exit before checking ALTER TRACE,
      checking the framework tables, or calling sp_trace_create.
    */
    IF @TraceFilePath IS NULL
    BEGIN
        ;WITH BasePaths AS
        (
            SELECT
                BaseOrder,
                BasePath,
                PathSource
            FROM
            (
                VALUES
                    (
                        10,
                        @DefaultDataPath,
                        CONVERT(nvarchar(128), N'InstanceDefaultDataPath')
                    ),
                    (
                        20,
                        @ErrorLogPath,
                        CONVERT(nvarchar(128), N'SQL Server error-log directory')
                    ),
                    (
                        30,
                        @DefaultLogPath,
                        CONVERT(nvarchar(128), N'InstanceDefaultLogPath')
                    ),
                    (
                        40,
                        @DefaultBackupPath,
                        CONVERT(nvarchar(128), N'InstanceDefaultBackupPath')
                    )
            ) AS p
            (
                BaseOrder,
                BasePath,
                PathSource
            )
            WHERE NULLIF(LTRIM(RTRIM(BasePath)), N'') IS NOT NULL
        ),
        NormalizedBasePaths AS
        (
            SELECT
                BaseOrder,
                DirectoryPath =
                    CASE
                        WHEN RIGHT(BasePath, 1) IN (N'\', N'/')
                            THEN CONVERT(nvarchar(4000), BasePath)
                        ELSE
                              CONVERT(nvarchar(4000), BasePath)
                            + @PathSeparator
                    END,
                PathSource
            FROM BasePaths
        ),
        CandidatePaths AS
        (
            /*
              A dedicated PerformanceTraces directory is preferred.
              The directory may need to be created manually.
            */
            SELECT
                CandidateOrder = BaseOrder,
                DirectoryPath =
                      DirectoryPath
                    + N'PerformanceTraces'
                    + @PathSeparator,
                PathSource =
                    PathSource + N' / dedicated PerformanceTraces directory',
                Recommendation =
                    CONVERT
                    (
                        nvarchar(256),
                        N'Preferred. Create this directory and grant the SQL Server service account write access.'
                    )
            FROM NormalizedBasePaths

            UNION ALL

            /*
              Existing SQL Server-owned directories are presented as fallbacks.
            */
            SELECT
                CandidateOrder = BaseOrder + 100,
                DirectoryPath,
                PathSource,
                Recommendation =
                    CONVERT
                    (
                        nvarchar(256),
                        N'Fallback. Verify that storing trace files in this existing directory is acceptable.'
                    )
            FROM NormalizedBasePaths
        ),
        DeduplicatedPaths AS
        (
            SELECT
                CandidateOrder,
                DirectoryPath,
                PathSource,
                Recommendation,
                DuplicateNumber =
                    ROW_NUMBER() OVER
                    (
                        PARTITION BY DirectoryPath
                        ORDER BY CandidateOrder
                    )
            FROM CandidatePaths
        )
        SELECT
            SuggestionRank =
                ROW_NUMBER() OVER
                (
                    ORDER BY CandidateOrder
                ),

            SuggestedTraceDirectory =
                DirectoryPath,

            SuggestedTraceFileBase =
                DirectoryPath + @TraceName,

            SuggestedParameterValue =
                DirectoryPath,

            PathSource,

            Recommendation,

            ValidationStatus =
                CONVERT
                (
                    nvarchar(128),
                    N'Not tested; no directory, file, or trace was created.'
                ),

            ExampleExecution =
                  N'EXEC dbo.StartPerformanceTrace'
                + N' @TraceName = N'''
                + REPLACE(@TraceName, N'''', N'''''')
                + N''', @TraceFilePath = N'''
                + REPLACE(DirectoryPath, N'''', N'''''')
                + N''';'
        FROM DeduplicatedPaths
        WHERE DuplicateNumber = 1
        ORDER BY CandidateOrder;

        RETURN;
    END;

    /*
      Everything below this point applies only when an explicit trace path
      was supplied.
    */
    IF OBJECT_ID(N'dbo.PerformanceTraceControl', N'U') IS NULL
       OR OBJECT_ID(N'dbo.PerformanceTraceResults', N'U') IS NULL
    BEGIN
        RAISERROR
        (
            'Performance trace tables do not exist. Run PerformanceTraceResults.sql first.',
            16,
            1
        );

        RETURN;
    END;

    IF ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE'), 0) = 0
    BEGIN
        RAISERROR
        (
            'ALTER TRACE permission is required to start a server-side trace.',
            16,
            1
        );

        RETURN;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.PerformanceTraceControl
        WHERE TraceName = @TraceName
          AND Status = 'Running'
    )
    BEGIN
        RAISERROR
        (
            'A performance trace named ''%s'' is already running.',
            16,
            1,
            @TraceName
        );

        RETURN;
    END;

    /*
      A path ending in a directory separator is treated as a directory.

      Otherwise, @TraceFilePath is treated as the complete trace-file base
      name. Do not include a .trc extension.
    */
    SET @ResolvedPath =
        CASE
            WHEN RIGHT(@TraceFilePath, 1) IN (N'\', N'/')
                THEN CONVERT(nvarchar(4000), @TraceFilePath) + @TraceName
            ELSE
                CONVERT(nvarchar(4000), @TraceFilePath)
        END;

    IF LEN(@ResolvedPath) > 245
    BEGIN
        RAISERROR
        (
            'The resolved trace file base path is %d characters. sp_trace_create allows at most 245 characters.',
            16,
            1,
            @ResolvedPath
        );

        RETURN;
    END;

    SET @TraceFileBase =
        CONVERT(nvarchar(245), @ResolvedPath);

    EXEC @ReturnCode = sys.sp_trace_create
        @traceid     = @TraceID OUTPUT,
        @options     = 2,
        @tracefile   = @TraceFileBase,
        @maxfilesize = @MaxFileSizeMB,
        @stoptime    = NULL;

    IF @ReturnCode <> 0
       OR @TraceID IS NULL
    BEGIN
        /*
          Normally sp_trace_create does not allocate a TraceID on failure.
          Clean it up defensively if it did.
        */
        IF @TraceID IS NOT NULL
        BEGIN
            BEGIN TRY
                EXEC sys.sp_trace_setstatus
                    @traceid = @TraceID,
                    @status  = 2;
            END TRY
            BEGIN CATCH
            END CATCH;
        END;

        RAISERROR
        (
            'sp_trace_create failed with return code %d for path ''%s''. Verify that the directory exists and that the SQL Server service account can write to it.',
            16,
            1,
            @ReturnCode,
            @TraceFileBase
        );

        RETURN;
    END;

    BEGIN TRY
        DECLARE @Events table
        (
            EventNumber int IDENTITY(1,1) NOT NULL PRIMARY KEY,
            EventID     int               NOT NULL
        );

        DECLARE @Columns table
        (
            ColumnNumber int IDENTITY(1,1) NOT NULL PRIMARY KEY,
            ColumnID     int               NOT NULL
        );

        INSERT INTO @Events
        (
            EventID
        )
        VALUES
            (10),  -- RPC:Completed
            (12),  -- SQL:BatchCompleted
            (45);  -- SP:StmtCompleted

        INSERT INTO @Columns
        (
            ColumnID
        )
        VALUES
            (1),   -- TextData
            (9),   -- ClientProcessID
            (10),  -- ApplicationName
            (11),  -- LoginName
            (12),  -- SPID
            (13),  -- Duration
            (14),  -- StartTime
            (15),  -- EndTime
            (16),  -- Reads
            (17),  -- Writes
            (18),  -- CPU
            (19),  -- Permissions
            (34),  -- ObjectName
            (35),  -- DatabaseName
            (48);  -- HostName

        SELECT @EventCount = COUNT(*)
        FROM @Events;

        SELECT @ColumnCount = COUNT(*)
        FROM @Columns;

        SET @EventNumber = 1;

        WHILE @EventNumber <= @EventCount
        BEGIN
            SELECT @EventID = EventID
            FROM @Events
            WHERE EventNumber = @EventNumber;

            SET @ColumnNumber = 1;

            WHILE @ColumnNumber <= @ColumnCount
            BEGIN
                SELECT @ColumnID = ColumnID
                FROM @Columns
                WHERE ColumnNumber = @ColumnNumber;

                EXEC @ReturnCode = sys.sp_trace_setevent
                    @traceid  = @TraceID,
                    @eventid  = @EventID,
                    @columnid = @ColumnID,
                    @on       = 1;

                IF @ReturnCode <> 0
                BEGIN
                    RAISERROR
                    (
                        'sp_trace_setevent failed for event %d, column %d, with return code %d.',
                        16,
                        1,
                        @EventID,
                        @ColumnID,
                        @ReturnCode
                    );
                END;

                SET @ColumnNumber += 1;
            END;

            SET @EventNumber += 1;
        END;

        IF @DatabaseName IS NOT NULL
        BEGIN
            SET @FilterValue =
                CONVERT(nvarchar(256), @DatabaseName);

            EXEC @ReturnCode = sys.sp_trace_setfilter
                @traceid            = @TraceID,
                @columnid           = 35,
                @logical_operator   = 0,
                @comparison_operator = 6,
                @value              = @FilterValue;

            IF @ReturnCode <> 0
            BEGIN
                RAISERROR
                (
                    'Database-name trace filter failed with return code %d.',
                    16,
                    1,
                    @ReturnCode
                );
            END;
        END;

        IF @MinReads IS NOT NULL
        BEGIN
            EXEC @ReturnCode = sys.sp_trace_setfilter
                @traceid             = @TraceID,
                @columnid            = 16,
                @logical_operator    = 0,
                @comparison_operator = 4,
                @value               = @MinReads;

            IF @ReturnCode <> 0
            BEGIN
                RAISERROR
                (
                    'Minimum-reads trace filter failed with return code %d.',
                    16,
                    1,
                    @ReturnCode
                );
            END;
        END;

        IF @MinWrites IS NOT NULL
        BEGIN
            EXEC @ReturnCode = sys.sp_trace_setfilter
                @traceid             = @TraceID,
                @columnid            = 17,
                @logical_operator    = 0,
                @comparison_operator = 4,
                @value               = @MinWrites;

            IF @ReturnCode <> 0
            BEGIN
                RAISERROR
                (
                    'Minimum-writes trace filter failed with return code %d.',
                    16,
                    1,
                    @ReturnCode
                );
            END;
        END;

        IF @MinDuration IS NOT NULL
        BEGIN
            EXEC @ReturnCode = sys.sp_trace_setfilter
                @traceid             = @TraceID,
                @columnid            = 13,
                @logical_operator    = 0,
                @comparison_operator = 4,
                @value               = @MinDuration;

            IF @ReturnCode <> 0
            BEGIN
                RAISERROR
                (
                    'Minimum-duration trace filter failed with return code %d.',
                    16,
                    1,
                    @ReturnCode
                );
            END;
        END;

        IF @LoginName IS NOT NULL
        BEGIN
            SET @FilterValue =
                CONVERT(nvarchar(256), @LoginName);

            EXEC @ReturnCode = sys.sp_trace_setfilter
                @traceid             = @TraceID,
                @columnid            = 11,
                @logical_operator    = 0,
                @comparison_operator = 6,
                @value               = @FilterValue;

            IF @ReturnCode <> 0
            BEGIN
                RAISERROR
                (
                    'Login-name trace filter failed with return code %d.',
                    16,
                    1,
                    @ReturnCode
                );
            END;
        END;

        IF @HostName IS NOT NULL
        BEGIN
            SET @FilterValue =
                CONVERT(nvarchar(256), @HostName);

            EXEC @ReturnCode = sys.sp_trace_setfilter
                @traceid             = @TraceID,
                @columnid            = 48,
                @logical_operator    = 0,
                @comparison_operator = 6,
                @value               = @FilterValue;

            IF @ReturnCode <> 0
            BEGIN
                RAISERROR
                (
                    'Host-name trace filter failed with return code %d.',
                    16,
                    1,
                    @ReturnCode
                );
            END;
        END;

        EXEC @ReturnCode = sys.sp_trace_setstatus
            @traceid = @TraceID,
            @status  = 1;

        IF @ReturnCode <> 0
        BEGIN
            RAISERROR
            (
                'sp_trace_setstatus start failed with return code %d.',
                16,
                1,
                @ReturnCode
            );
        END;

        INSERT INTO dbo.PerformanceTraceControl
        (
            TraceID,
            TraceName,
            TraceFilePath,
            Status,
            StartTime,
            FilterDatabaseName,
            FilterMinReads,
            FilterMinWrites,
            FilterMinDuration,
            FilterLoginName,
            FilterHostName,
            MaxFileSizeMB,
            StartedBy
        )
        VALUES
        (
            @TraceID,
            @TraceName,
            @TraceFileBase,
            'Running',
            @StartTime,
            @DatabaseName,
            @MinReads,
            @MinWrites,
            @MinDuration,
            @LoginName,
            @HostName,
            @MaxFileSizeMB,
            SUSER_SNAME()
        );

        SET @TraceControlID =
            CONVERT(int, SCOPE_IDENTITY());
    END TRY
    BEGIN CATCH
        /*
          Prevent an untracked or partially configured trace from remaining
          allocated when configuration or control-table insertion fails.
        */
        IF @TraceID IS NOT NULL
        BEGIN
            BEGIN TRY
                EXEC sys.sp_trace_setstatus
                    @traceid = @TraceID,
                    @status  = 0;
            END TRY
            BEGIN CATCH
            END CATCH;

            BEGIN TRY
                EXEC sys.sp_trace_setstatus
                    @traceid = @TraceID,
                    @status  = 2;
            END TRY
            BEGIN CATCH
            END CATCH;
        END;

        THROW;
    END CATCH;

    SELECT
        TraceControlID      = @TraceControlID,
        TraceID             = @TraceID,
        TraceName           = @TraceName,
        TraceFilePath       = @TraceFileBase,
        TracePathSource     = N'Explicit @TraceFilePath',
        Status              = 'Running',
        StartTime           = @StartTime,
        FilterDatabaseName  = @DatabaseName,
        FilterMinReads      = @MinReads,
        FilterMinWrites     = @MinWrites,
        FilterMinDuration   = @MinDuration,
        FilterLoginName     = @LoginName,
        FilterHostName      = @HostName,
        MaxFileSizeMB       = @MaxFileSizeMB;
END;
GO


delete from PerformanceTraceControl
truncate table PerformanceTraceResults

select * from PerformanceTraceResults
where databasename <> 'master'
and ApplicationName <> 'SQLExternalMonitoring'
order by reads


sp_help PerformanceTraceControl

EXEC StartPerformanceTrace @TraceControlID = 3, @TraceFilePath = 'E:\MSSQL16.DEV_RPT2_2022\MSSQL\Log\'
EXEC StopPerformanceTrace @TraceID = 2

select * from  PerformanceTraceControl
