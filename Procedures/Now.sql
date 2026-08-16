/*
  Now.sql
  Current-activity report for SQL Server 2012 (11.x) and later.

  Deploy to the tool database, then execute:
    EXEC dbo.Now
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.Now') IS NOT NULL
BEGIN
    PRINT 'Dropping procedure: Now'
    DROP PROCEDURE dbo.Now
END
GO

PRINT 'Creating procedure: Now (2026-08-16)'
GO

CREATE PROCEDURE dbo.Now
AS
---------------------------------------------------------------------------------------------------
-- Date Created: February 11, 2007
-- Author:       Bill McEvoy
-- Description:  Current-activity report. Lists active sessions, blockers, the SQL they are
--               running, and pending file I/O.
---------------------------------------------------------------------------------------------------
-- Version:      1.1
-- Date Revised: April 22, 2014
-- Author:       Bill McEvoy
-- Reason:       Wrap database names in square brackets.
---------------------------------------------------------------------------------------------------
-- Version:      1.2
-- Date Revised: August 16, 2026
-- Author:       Bill McEvoy
-- Reason:       Replace sysprocesses, ::fn_get_sql, and the 20-byte sql_handle with DMVs that
--               exist on SQL Server 2012 and later. Keep the original PRINT / SELECT layout.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion     tinyint,
    @Version          varchar(10),
    @ActiveSessions   int,
    @BlockedSessions  int,
    @TotalSessions    int,
    @session_id       int,
    @is_blocker       bit,
    @sql_handle       varbinary(64),
    @input_buffer     nvarchar(max),
    @sql_text         nvarchar(max),
    @HadSessions      bit,
    @InputBufferSql   nvarchar(200)

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 11
BEGIN
    RAISERROR('Now requires SQL Server 2012 (11.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SET @Version = '1.2'

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
    phys_io          bigint         NOT NULL,
    memory_mb        decimal(12, 2) NOT NULL,
    program_name     nvarchar(128)  NULL,
    login_time       datetime       NULL,
    last_request     datetime       NULL,
    sql_handle       varbinary(64)  NULL
)

IF OBJECT_ID('tempdb..#DBCCResults') IS NOT NULL
    DROP TABLE #DBCCResults

CREATE TABLE #DBCCResults
(
    EventType  nvarchar(30)   NULL,
    Parameters int            NULL,
    EventInfo  nvarchar(max)  NULL
)

IF OBJECT_ID('tempdb..#PendingIO') IS NOT NULL
    DROP TABLE #PendingIO

CREATE TABLE #PendingIO
(
    DatabaseID   int            NOT NULL,
    FileName     sysname        NOT NULL,
    DBFileName   nvarchar(260)  NOT NULL,
    FileID       int            NOT NULL,
    IO_Pending   bit            NOT NULL
)

;WITH ActiveSessionIds AS
(
    SELECT DISTINCT SessionId = x.session_id
    FROM (
        SELECT r.session_id
          FROM sys.dm_exec_requests AS r
         WHERE r.session_id > 50
           AND r.session_id <> @@SPID
           AND r.status NOT IN (N'sleeping', N'background')

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
    phys_io,
    memory_mb,
    program_name,
    login_time,
    last_request,
    sql_handle
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
    ISNULL(conn.phys_io, 0),
    CAST(s.memory_usage * 8192.0 / 1024.0 / 1024.0 AS decimal(12, 2)),
    s.program_name,
    s.login_time,
    s.last_request_end_time,
    COALESCE(r.sql_handle, conn.most_recent_sql_handle)
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

INSERT INTO #PendingIO
(
    DatabaseID,
    FileName,
    DBFileName,
    FileID,
    IO_Pending
)
SELECT
    mf.database_id,
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
SELECT @TotalSessions   = COUNT(*) FROM sys.dm_exec_sessions

PRINT '===================='
PRINT '= CURRENT ACTIVITY ='
PRINT '===================='
PRINT CONVERT(char(19), GETDATE(), 120)
PRINT 'Version ' + @Version
PRINT ' '
PRINT 'Active  SPIDs: ' + CONVERT(varchar(8), @ActiveSessions)
PRINT 'Blocked SPIDs: ' + CONVERT(varchar(8), @BlockedSessions)
PRINT 'Total   SPIDs: ' + CONVERT(varchar(8), @TotalSessions)

IF @BlockedSessions > 0
BEGIN
    PRINT ' '
    PRINT ' '
    PRINT 'Blocked Process Summary'
    PRINT '-----------------------'
    PRINT ' '
    SELECT
        [loginame]     = LEFT(login_name, 20),
        [hostname]     = LEFT(host_name, 20),
        [database]     = LEFT(database_name, 25),
        [spid]         = STR(session_id, 4, 0),
        [block]        = STR(blocking_id, 5, 0),
        [phys_io]      = STR(phys_io, 8, 0),
        [cpu(mm:ss)]   = STR((cpu_time / 1000 / 60), 6) + ':'
                       + CASE
                             WHEN LEFT(STR(((cpu_time / 1000) % 60), 2), 1) = ' '
                                 THEN STUFF(STR(((cpu_time / 1000) % 60), 2), 1, 1, '0')
                             ELSE STR(((cpu_time / 1000) % 60), 2)
                         END,
        [mem(MB)]      = STR(memory_mb, 8, 2),
        [program_name] = LEFT(program_name, 50),
        [command]      = command,
        [lastwaittype] = LEFT(wait_type, 25),
        [login_time]   = CONVERT(char(19), login_time, 120),
        [last_batch]   = CONVERT(char(19), last_request, 120),
        [status]       = LEFT(status, 20)
      FROM #Sessions
     WHERE blocking_id > 0
END

DECLARE ActiveSpids_Cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    session_id,
    is_blocker,
    sql_handle
FROM #Sessions
ORDER BY SortOrder

OPEN ActiveSpids_Cursor
FETCH NEXT FROM ActiveSpids_Cursor
 INTO @session_id, @is_blocker, @sql_handle

SET @HadSessions = 0

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @HadSessions = 1

    PRINT ' '
    PRINT ' '
    PRINT 'O' + REPLICATE('x', 120) + 'O'
    PRINT 'O' + REPLICATE('x', 120) + 'O'
    PRINT ' '
    PRINT ' '
    PRINT ' '

    IF @is_blocker = 1
    BEGIN
        PRINT '================'
        PRINT '=== BLOCKER ===='
        PRINT '================'
        PRINT ' '
    END

    SELECT
        [loginame]     = LEFT(login_name, 30),
        [hostname]     = LEFT(host_name, 30),
        [database]     = LEFT(database_name, 30),
        [spid]         = STR(session_id, 4, 0),
        [block]        = STR(blocking_id, 5, 0),
        [phys_io]      = STR(phys_io, 8, 0),
        [cpu(mm:ss)]   = STR((cpu_time / 1000 / 60), 6) + ':'
                       + CASE
                             WHEN LEFT(STR(((cpu_time / 1000) % 60), 2), 1) = ' '
                                 THEN STUFF(STR(((cpu_time / 1000) % 60), 2), 1, 1, '0')
                             ELSE STR(((cpu_time / 1000) % 60), 2)
                         END,
        [mem(MB)]      = STR(memory_mb, 8, 2),
        [program_name] = LEFT(program_name, 50),
        [command]      = command,
        [lastwaittype] = LEFT(wait_type, 25),
        [login_time]   = CONVERT(char(19), login_time, 120),
        [last_batch]   = CONVERT(char(19), last_request, 120),
        [status]       = LEFT(status, 20)
      FROM #Sessions
     WHERE session_id = @session_id

    PRINT '----------------------'
    PRINT '-- DBCC INPUTBUFFER --'
    PRINT '----------------------'
    PRINT ' '

    TRUNCATE TABLE #DBCCResults
    SET @InputBufferSql = N'DBCC INPUTBUFFER(' + CONVERT(nvarchar(12), @session_id) + N') WITH NO_INFOMSGS'
    BEGIN TRY
        INSERT INTO #DBCCResults (EventType, Parameters, EventInfo)
        EXEC (@InputBufferSql)
        SELECT @input_buffer = EventInfo FROM #DBCCResults
    END TRY
    BEGIN CATCH
        SET @input_buffer = NULL
    END CATCH

    IF @input_buffer IS NOT NULL AND LTRIM(RTRIM(@input_buffer)) <> N''
        PRINT @input_buffer
    ELSE
        PRINT '(no input buffer available)'

    PRINT ' '
    PRINT ' '

    SET @sql_text = NULL
    IF @sql_handle IS NOT NULL AND @sql_handle <> 0x
    BEGIN
        SELECT @sql_text = st.[text]
          FROM sys.dm_exec_sql_text(@sql_handle) AS st
    END

    IF @sql_text IS NOT NULL AND LTRIM(RTRIM(@sql_text)) <> N''
    BEGIN
        PRINT '------------------'
        PRINT '-- dm_exec_sql_text --'
        PRINT '------------------'
        PRINT ' '
        PRINT @sql_text
    END

    FETCH NEXT FROM ActiveSpids_Cursor
     INTO @session_id, @is_blocker, @sql_handle
END

IF @HadSessions = 1
BEGIN
    PRINT ' '
    PRINT ' '
    PRINT 'O' + REPLICATE('x', 120) + 'O'
    PRINT 'O' + REPLICATE('x', 120) + 'O'
    PRINT ' '
    PRINT ' '
    PRINT ' '
END

CLOSE ActiveSpids_Cursor
DEALLOCATE ActiveSpids_Cursor

PRINT '----------------------'
PRINT '-- Pending File I/O --'
PRINT '----------------------'
PRINT ' '

SELECT
    [Database]   = LEFT(DB_NAME(DatabaseID), 25),
    [FileName]   = LEFT(FileName, 30),
    [DBFileName] = LEFT(DBFileName, 50),
    FileID,
    IO_Pending
  FROM #PendingIO

IF @BlockedSessions > 0
    WAITFOR DELAY '00:00:03'

GO

IF OBJECT_ID('dbo.Now') IS NOT NULL
    PRINT 'Procedure created'
ELSE
    PRINT 'Procedure NOT created'
GO
