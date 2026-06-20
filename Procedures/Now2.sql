
GO

/*
  Now2.sql
  Modern replacement for Now.sql for SQL Server 2019 and later.

  Deploy to the DBA tool database, then execute:
    EXEC dbo.Now2
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER FUNCTION dbo.Now2_FormatMs
(
    @Milliseconds int
)
RETURNS varchar(12)
AS
BEGIN
    DECLARE @Seconds int = ISNULL(@Milliseconds, 0) / 1000
    DECLARE @Minutes int = @Seconds / 60
    DECLARE @Remainder int = @Seconds % 60

    RETURN CAST(@Minutes AS varchar(10)) + ':'
         + RIGHT('0' + CAST(@Remainder AS varchar(2)), 2)
END
GO

CREATE OR ALTER PROCEDURE dbo.Now2
(
    @ReportWidth       tinyint = 120,
    @WaitIfBlocked     bit     = 1,
    @WaitSeconds       tinyint = 3
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Modern current-activity report for SQL Server 2019+. Uses DMVs to show active
--               sessions, blocking, running SQL, input buffers, and pending file I/O in a
--               fixed-width text report.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion     tinyint,
    @ProductVersion   varchar(30),
    @ServerName       sysname,
    @ReportTime       varchar(19),
    @Divider          varchar(120),
    @HeaderRule       varchar(120),
    @BlankLine        varchar(120),
    @LineNo           int,
    @ActiveSessions   int,
    @BlockedSessions  int,
    @RunningRequests  int,
    @TotalSessions    int,
    @PendingIO        int,
    @Line             varchar(200),
    @session_id       int,
    @blocking_id      int,
    @is_blocker       bit,
    @login_name       nvarchar(128),
    @host_name        nvarchar(128),
    @database_name    sysname,
    @status           nvarchar(30),
    @command          nvarchar(32),
    @wait_type        nvarchar(60),
    @cpu_time         int,
    @elapsed_time     int,
    @phys_io          bigint,
    @reads            bigint,
    @writes           bigint,
    @logical_reads    bigint,
    @memory_mb        decimal(12, 2),
    @program_name     nvarchar(128),
    @login_time       varchar(19),
    @last_request     varchar(19),
    @sql_text         nvarchar(max),
    @input_buffer     nvarchar(max),
    @chunk            nvarchar(max)

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 15
BEGIN
    RAISERROR('Now2 requires SQL Server 2019 (15.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SET @ReportWidth = 120
SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))
SET @ServerName     = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')
SET @ReportTime     = CONVERT(varchar(19), GETDATE(), 120)
SET @Divider        = REPLICATE('-', @ReportWidth)
SET @HeaderRule     = REPLICATE('=', @ReportWidth)
SET @BlankLine      = REPLICATE(' ', @ReportWidth)

IF OBJECT_ID('tempdb..#Sessions') IS NOT NULL
    DROP TABLE #Sessions

CREATE TABLE #Sessions
(
    SortOrder        int            NOT NULL,
    session_id       int            NOT NULL,
    request_id       int            NOT NULL,
    blocking_id      int            NOT NULL,
    is_blocker       bit            NOT NULL,
    login_name       nvarchar(128)  NULL,
    host_name        nvarchar(128)  NULL,
    database_name    sysname        NULL,
    status           nvarchar(30)   NULL,
    command          nvarchar(32)   NULL,
    wait_type        nvarchar(60)   NULL,
    cpu_time         int            NOT NULL,
    elapsed_time     int            NOT NULL,
    phys_io          bigint         NOT NULL,
    reads            bigint         NOT NULL,
    writes           bigint         NOT NULL,
    logical_reads    bigint         NOT NULL,
    memory_mb        decimal(12, 2) NOT NULL,
    program_name     nvarchar(128)  NULL,
    login_time       datetime       NULL,
    last_request     datetime       NULL,
    sql_text         nvarchar(max)  NULL,
    input_buffer     nvarchar(max)  NULL
)

IF OBJECT_ID('tempdb..#PendingIO') IS NOT NULL
    DROP TABLE #PendingIO

CREATE TABLE #PendingIO
(
    database_name sysname        NOT NULL,
    file_name     sysname        NOT NULL,
    file_path     nvarchar(260)  NOT NULL,
    file_id       int            NOT NULL,
    io_pending    bit            NOT NULL
)

IF OBJECT_ID('tempdb..#Report') IS NOT NULL
    DROP TABLE #Report

CREATE TABLE #Report
(
    [LineNo]     int          NOT NULL,
    ReportLine   varchar(200) NOT NULL
)

;WITH ActiveSessionIds AS
(
    SELECT DISTINCT SessionId = x.session_id
    FROM (
        SELECT r.session_id
          FROM sys.dm_exec_requests AS r
         WHERE r.session_id > 50
           AND r.session_id <> @@SPID
           AND r.status NOT IN ('sleeping', 'background')

        UNION

        SELECT r.session_id
          FROM sys.dm_exec_requests AS r
         WHERE r.blocking_session_id > 0

        UNION

        SELECT r.blocking_session_id
          FROM sys.dm_exec_requests AS r
         WHERE r.blocking_session_id > 0
    ) AS x
    WHERE x.session_id IS NOT NULL
)
INSERT INTO #Sessions
(
    SortOrder,
    session_id,
    request_id,
    blocking_id,
    is_blocker,
    login_name,
    host_name,
    database_name,
    status,
    command,
    wait_type,
    cpu_time,
    elapsed_time,
    phys_io,
    reads,
    writes,
    logical_reads,
    memory_mb,
    program_name,
    login_time,
    last_request,
    sql_text,
    input_buffer
)
SELECT
    SortOrder = ROW_NUMBER() OVER (ORDER BY ISNULL(r.cpu_time, 0) DESC, a.SessionId),
    s.session_id,
    ISNULL(r.request_id, 0),
    ISNULL(r.blocking_session_id, 0),
    CASE
        WHEN EXISTS (
            SELECT 1
              FROM sys.dm_exec_requests AS b
             WHERE b.blocking_session_id = s.session_id
        ) THEN 1
        ELSE 0
    END,
    s.login_name,
    s.host_name,
    DB_NAME(COALESCE(r.database_id, s.database_id)),
    COALESCE(r.status, s.status),
    r.command,
    COALESCE(r.wait_type, r.last_wait_type),
    ISNULL(r.cpu_time, 0),
    ISNULL(r.total_elapsed_time, 0),
    ISNULL(conn.phys_io, 0),
    ISNULL(r.reads, 0),
    ISNULL(r.writes, 0),
    ISNULL(r.logical_reads, 0),
    CAST(s.memory_usage * 8192.0 / 1024 / 1024 AS decimal(12, 2)),
    s.program_name,
    s.login_time,
    s.last_request_end_time,
    st.[text],
    ib.event_info
FROM ActiveSessionIds AS a
INNER JOIN sys.dm_exec_sessions AS s
    ON s.session_id = a.SessionId
OUTER APPLY (
    SELECT TOP (1) r.*
      FROM sys.dm_exec_requests AS r
     WHERE r.session_id = s.session_id
     ORDER BY r.cpu_time DESC, r.request_id DESC
) AS r
OUTER APPLY (
    SELECT TOP (1)
        phys_io = (
            SELECT SUM(c2.num_reads + c2.num_writes)
              FROM sys.dm_exec_connections AS c2
             WHERE c2.session_id = s.session_id
        ),
        c.most_recent_sql_handle
      FROM sys.dm_exec_connections AS c
     WHERE c.session_id = s.session_id
     ORDER BY c.connect_time DESC
) AS conn
OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, conn.most_recent_sql_handle)) AS st
OUTER APPLY sys.dm_exec_input_buffer(s.session_id, ISNULL(r.request_id, 0)) AS ib

INSERT INTO #PendingIO
(
    database_name,
    file_name,
    file_path,
    file_id,
    io_pending
)
SELECT
    DB_NAME(mf.database_id),
    mf.name,
    mf.physical_name,
    mf.file_id,
    ior.io_pending
FROM sys.dm_io_pending_io_requests AS ior
INNER JOIN sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
    ON vfs.file_handle = ior.io_handle
INNER JOIN sys.master_files AS mf
    ON mf.database_id = vfs.database_id
   AND mf.file_id = vfs.file_id

SELECT @ActiveSessions  = COUNT(*) FROM #Sessions
SELECT @BlockedSessions = COUNT(*) FROM #Sessions WHERE blocking_id > 0
SELECT @RunningRequests = COUNT(*) FROM #Sessions WHERE status = 'running'
SELECT @TotalSessions   = COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1 AND session_id > 50
SELECT @PendingIO       = COUNT(*) FROM #PendingIO

SET @LineNo = 0

INSERT INTO #Report ([LineNo], ReportLine)
SELECT @LineNo, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 1, LEFT('= CURRENT ACTIVITY =' + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 2, LEFT(@HeaderRule, @ReportWidth)
UNION ALL
SELECT @LineNo + 3, LEFT(@ReportTime + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 4, LEFT(' Version 2.0  |  Server: ' + @ServerName + '  |  SQL Server ' + @ProductVersion + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 5, LEFT(@BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 6,
       LEFT(' Active SPIDs: ' + CAST(@ActiveSessions AS varchar(10))
            + '  |  Blocked SPIDs: ' + CAST(@BlockedSessions AS varchar(10))
            + '  |  Running: ' + CAST(@RunningRequests AS varchar(10))
            + @BlankLine, @ReportWidth)
UNION ALL
SELECT @LineNo + 7,
       LEFT(' Total SPIDs: ' + CAST(@TotalSessions AS varchar(10))
            + '  |  Pending file I/O: ' + CAST(@PendingIO AS varchar(10))
            + @BlankLine, @ReportWidth)

SET @LineNo = 8

IF @BlockedSessions > 0
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT @LineNo, LEFT(@BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 1, LEFT(' Blocked Process Summary' + @BlankLine, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 2, LEFT(@Divider, @ReportWidth)
    UNION ALL
    SELECT @LineNo + 3,
           LEFT(
                  LEFT('LOGIN', 20)
                + ' ' + LEFT('HOST', 20)
                + ' ' + LEFT('DATABASE', 25)
                + ' ' + LEFT('SPID', 5)
                + ' ' + LEFT('BLOCK', 6)
                + ' ' + LEFT('PHYS_IO', 8)
                + ' ' + LEFT('CPU', 8)
                + ' ' + LEFT('MEM(MB)', 8),
                @ReportWidth)
    UNION ALL
    SELECT @LineNo + 4, LEFT(@Divider, @ReportWidth)

    SET @LineNo = @LineNo + 5

    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT
        @LineNo + ROW_NUMBER() OVER (ORDER BY s.blocking_id DESC, s.session_id) - 1,
        LEFT(
              LEFT(ISNULL(s.login_name, '') + @BlankLine, 20)
            + ' ' + LEFT(ISNULL(s.host_name, '') + @BlankLine, 20)
            + ' ' + LEFT(ISNULL(s.database_name, '') + @BlankLine, 25)
            + ' ' + RIGHT(REPLICATE(' ', 5) + CAST(s.session_id AS varchar(10)), 5)
            + ' ' + RIGHT(REPLICATE(' ', 6) + CAST(s.blocking_id AS varchar(10)), 6)
            + ' ' + RIGHT(REPLICATE(' ', 8) + CAST(s.phys_io AS varchar(12)), 8)
            + ' ' + RIGHT(REPLICATE(' ', 8) + dbo.Now2_FormatMs(s.cpu_time), 8)
            + ' ' + RIGHT(REPLICATE(' ', 8) + CAST(s.memory_mb AS varchar(12)), 8),
            @ReportWidth)
      FROM #Sessions AS s
     WHERE s.blocking_id > 0

    SELECT @LineNo = ISNULL(MAX([LineNo]), @LineNo) + 1 FROM #Report
    INSERT INTO #Report ([LineNo], ReportLine) VALUES (@LineNo, LEFT(@BlankLine, @ReportWidth))
    SET @LineNo = @LineNo + 1
END

IF @ActiveSessions = 0
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES
        (@LineNo, LEFT(@BlankLine, @ReportWidth)),
        (@LineNo + 1, LEFT(' No active user sessions reported.' + @BlankLine, @ReportWidth))
    SET @LineNo = @LineNo + 2
END

DECLARE SessionCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    session_id,
    blocking_id,
    is_blocker,
    login_name,
    host_name,
    database_name,
    status,
    command,
    wait_type,
    cpu_time,
    elapsed_time,
    phys_io,
    reads,
    writes,
    logical_reads,
    memory_mb,
    program_name,
    CONVERT(varchar(19), login_time, 120),
    CONVERT(varchar(19), last_request, 120),
    sql_text,
    input_buffer
FROM #Sessions
ORDER BY SortOrder

OPEN SessionCursor
FETCH NEXT FROM SessionCursor INTO
    @session_id, @blocking_id, @is_blocker, @login_name, @host_name, @database_name,
    @status, @command, @wait_type, @cpu_time, @elapsed_time, @phys_io, @reads, @writes,
    @logical_reads, @memory_mb, @program_name, @login_time, @last_request,
    @sql_text, @input_buffer

WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES
        (@LineNo, LEFT(@BlankLine, @ReportWidth)),
        (@LineNo + 1, LEFT(@BlankLine, @ReportWidth)),
        (@LineNo + 2, LEFT('O' + REPLICATE('x', @ReportWidth - 2) + 'O', @ReportWidth)),
        (@LineNo + 3, LEFT('O' + REPLICATE('x', @ReportWidth - 2) + 'O', @ReportWidth))

    SET @LineNo = @LineNo + 4

    IF @is_blocker = 1
    BEGIN
        INSERT INTO #Report ([LineNo], ReportLine)
        SELECT @LineNo, LEFT(@HeaderRule, @ReportWidth)
        UNION ALL
        SELECT @LineNo + 1, LEFT('=== BLOCKER ===' + @BlankLine, @ReportWidth)
        UNION ALL
        SELECT @LineNo + 2, LEFT(@HeaderRule, @ReportWidth)
        UNION ALL
        SELECT @LineNo + 3, LEFT(@BlankLine, @ReportWidth)

        SET @LineNo = @LineNo + 4
    END

    SET @Line =
          LEFT(ISNULL(@login_name, '') + @BlankLine, 30)
        + ' ' + LEFT(ISNULL(@host_name, '') + @BlankLine, 30)
        + ' ' + LEFT(ISNULL(@database_name, '') + @BlankLine, 30)

    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES (@LineNo, LEFT(@Line + @BlankLine, @ReportWidth))

    SET @Line =
          RIGHT(REPLICATE(' ', 5) + CAST(@session_id AS varchar(10)), 5)
        + ' ' + RIGHT(REPLICATE(' ', 6) + CAST(@blocking_id AS varchar(10)), 6)
        + ' ' + RIGHT(REPLICATE(' ', 10) + CAST(@phys_io AS varchar(12)), 10)
        + ' ' + RIGHT(REPLICATE(' ', 10) + dbo.Now2_FormatMs(@cpu_time), 10)
        + ' ' + RIGHT(REPLICATE(' ', 8) + CAST(@memory_mb AS varchar(12)), 8)
        + ' ' + LEFT(ISNULL(@program_name, '') + @BlankLine, 50)

    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES (@LineNo + 1, LEFT(@Line + @BlankLine, @ReportWidth))

    SET @Line =
          LEFT(ISNULL(@command, '') + @BlankLine, 20)
        + ' ' + LEFT(ISNULL(@wait_type, '') + @BlankLine, 25)
        + ' ' + LEFT(ISNULL(@status, '') + @BlankLine, 20)

    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES (@LineNo + 2, LEFT(@Line + @BlankLine, @ReportWidth))

    SET @Line =
        ' login time: ' + ISNULL(@login_time, '')
        + '  last batch: ' + ISNULL(@last_request, '')
        + '  reads: ' + CAST(@reads AS varchar(12))
        + '  writes: ' + CAST(@writes AS varchar(12))

    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES (@LineNo + 3, LEFT(@Line + @BlankLine, @ReportWidth))

    SET @LineNo = @LineNo + 4

    IF @input_buffer IS NOT NULL AND LTRIM(RTRIM(@input_buffer)) <> ''
    BEGIN
        INSERT INTO #Report ([LineNo], ReportLine)
        VALUES (@LineNo, LEFT(@Divider, @ReportWidth))

        INSERT INTO #Report ([LineNo], ReportLine)
        VALUES (@LineNo + 1, LEFT(' -- INPUT BUFFER --' + @BlankLine, @ReportWidth))

        SET @LineNo = @LineNo + 2
        SET @chunk = REPLACE(REPLACE(@input_buffer, CHAR(13), ' '), CHAR(10), ' ')

        WHILE LEN(@chunk) > 0
        BEGIN
            INSERT INTO #Report ([LineNo], ReportLine)
            VALUES (@LineNo, LEFT('   ' + LEFT(@chunk, @ReportWidth - 3), @ReportWidth))

            SET @chunk = SUBSTRING(@chunk, @ReportWidth - 2, LEN(@chunk))
            SET @LineNo = @LineNo + 1
        END
    END

    IF @sql_text IS NOT NULL AND LTRIM(RTRIM(@sql_text)) <> ''
    BEGIN
        INSERT INTO #Report ([LineNo], ReportLine)
        VALUES (@LineNo, LEFT(@Divider, @ReportWidth))

        INSERT INTO #Report ([LineNo], ReportLine)
        VALUES (@LineNo + 1, LEFT(' -- CURRENT SQL --' + @BlankLine, @ReportWidth))

        SET @LineNo = @LineNo + 2
        SET @chunk = REPLACE(REPLACE(@sql_text, CHAR(13), ' '), CHAR(10), ' ')

        WHILE LEN(@chunk) > 0
        BEGIN
            INSERT INTO #Report ([LineNo], ReportLine)
            VALUES (@LineNo, LEFT('   ' + LEFT(@chunk, @ReportWidth - 3), @ReportWidth))

            SET @chunk = SUBSTRING(@chunk, @ReportWidth - 2, LEN(@chunk))
            SET @LineNo = @LineNo + 1
        END
    END

    FETCH NEXT FROM SessionCursor INTO
        @session_id, @blocking_id, @is_blocker, @login_name, @host_name, @database_name,
        @status, @command, @wait_type, @cpu_time, @elapsed_time, @phys_io, @reads, @writes,
        @logical_reads, @memory_mb, @program_name, @login_time, @last_request,
        @sql_text, @input_buffer
END

CLOSE SessionCursor
DEALLOCATE SessionCursor

IF @ActiveSessions > 0
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES
        (@LineNo, LEFT(@BlankLine, @ReportWidth)),
        (@LineNo + 1, LEFT(@BlankLine, @ReportWidth)),
        (@LineNo + 2, LEFT('O' + REPLICATE('x', @ReportWidth - 2) + 'O', @ReportWidth)),
        (@LineNo + 3, LEFT('O' + REPLICATE('x', @ReportWidth - 2) + 'O', @ReportWidth))

    SET @LineNo = @LineNo + 4
END

INSERT INTO #Report ([LineNo], ReportLine)
VALUES (@LineNo, LEFT(@Divider, @ReportWidth))

SET @LineNo = @LineNo + 1

INSERT INTO #Report ([LineNo], ReportLine)
VALUES (@LineNo, LEFT(' -- Pending File I/O --' + @BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 1

INSERT INTO #Report ([LineNo], ReportLine)
VALUES (@LineNo, LEFT(@BlankLine, @ReportWidth))

SET @LineNo = @LineNo + 1

IF @PendingIO = 0
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    VALUES (@LineNo, LEFT(' No pending file I/O reported.' + @BlankLine, @ReportWidth))
    SET @LineNo = @LineNo + 1
END
ELSE
BEGIN
    INSERT INTO #Report ([LineNo], ReportLine)
    SELECT
        @LineNo + ROW_NUMBER() OVER (ORDER BY p.database_name, p.file_name) - 1,
        LEFT(
              LEFT(p.database_name + @BlankLine, 25)
            + ' ' + LEFT(p.file_name + @BlankLine, 30)
            + ' ' + LEFT(p.file_path + @BlankLine, 50)
            + ' ' + RIGHT(REPLICATE(' ', 5) + CAST(p.file_id AS varchar(10)), 5)
            + ' ' + CASE WHEN p.io_pending = 1 THEN 'Y' ELSE 'N' END,
            @ReportWidth)
      FROM #PendingIO AS p

    SELECT @LineNo = ISNULL(MAX([LineNo]), @LineNo) + 1 FROM #Report
END

INSERT INTO #Report ([LineNo], ReportLine)
VALUES (@LineNo, LEFT(@HeaderRule, @ReportWidth))

SELECT ReportLine
  FROM #Report
 ORDER BY [LineNo]

IF @WaitIfBlocked = 1 AND @BlockedSessions > 0 AND @WaitSeconds > 0
BEGIN
   declare @Delay varchar(8) = CONVERT(varchar(8), DATEADD(second, @WaitSeconds, 0), 108)
   WAITFOR DELAY @Delay
END

GO

IF OBJECT_ID('dbo.Now2') IS NOT NULL
    PRINT 'Procedure Now2 created.'
ELSE
    PRINT 'Procedure Now2 NOT created.'
GO

IF OBJECT_ID('dbo.Now2_FormatMs') IS NOT NULL
    PRINT 'Function Now2_FormatMs created.'
ELSE
    PRINT 'Function Now2_FormatMs NOT created.'
GO