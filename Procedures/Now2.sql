USE dba
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

CREATE OR ALTER PROCEDURE dbo.Now2
(
    @WaitIfBlocked     bit     = 1,
    @WaitSeconds       tinyint = 3
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 18, 2026
-- Author:       Bill McEvoy
-- Description:  Modern current-activity report for SQL Server 2019+. Uses DMVs to show active
--               sessions, blocking, running SQL, input buffers, and pending file I/O. Output
--               format matches the original Now procedure (PRINT and SELECT result sets).
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion     tinyint,
    @Version          varchar(10),
    @ActiveSessions   int,
    @BlockedSessions  int,
    @TotalSessions    int,
    @session_id       int,
    @request_id       int,
    @is_blocker       bit,
    @input_buffer     nvarchar(max),
    @sql_text         nvarchar(max),
    @HadSessions      bit,
    @Delay            varchar(8)

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

IF @MajorVersion < 15
BEGIN
    RAISERROR('Now2 requires SQL Server 2019 (15.x) or later. This instance is version %d.', 16, 1, @MajorVersion)
    RETURN
END

SET @Version = '2.0'

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
    sql_text         nvarchar(max)  NULL,
    input_buffer     nvarchar(max)  NULL
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
    phys_io,
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
    ISNULL(conn.phys_io, 0),
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
        'loginame'     = LEFT(login_name, 20),
        'hostname'     = LEFT(host_name, 20),
        'database'     = LEFT(database_name, 25),
        'spid'         = STR(session_id, 4, 0),
        'block'        = STR(blocking_id, 5, 0),
        'phys_io'      = STR(phys_io, 8, 0),
        'cpu(mm:ss)'   = STR((cpu_time / 1000 / 60), 6) + ':'
                       + CASE
                             WHEN LEFT(STR(((cpu_time / 1000) % 60), 2), 1) = ' '
                                 THEN STUFF(STR(((cpu_time / 1000) % 60), 2), 1, 1, '0')
                             ELSE STR(((cpu_time / 1000) % 60), 2)
                         END,
        'mem(MB)'      = STR(memory_mb, 8, 2),
        'program_name' = LEFT(program_name, 50),
        'command'      = command,
        'lastwaittype' = LEFT(wait_type, 25),
        'login_time'   = CONVERT(char(19), login_time, 120),
        'last_batch'   = CONVERT(char(19), last_request, 120),
        'status'       = LEFT(status, 20)
      FROM #Sessions
     WHERE blocking_id > 0
END

DECLARE SessionCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    session_id,
    request_id,
    is_blocker,
    input_buffer,
    sql_text
FROM #Sessions
ORDER BY SortOrder

OPEN SessionCursor
FETCH NEXT FROM SessionCursor
 INTO @session_id, @request_id, @is_blocker, @input_buffer, @sql_text

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
        'loginame'     = LEFT(login_name, 30),
        'hostname'     = LEFT(host_name, 30),
        'database'     = LEFT(database_name, 30),
        'spid'         = STR(session_id, 4, 0),
        'block'        = STR(blocking_id, 5, 0),
        'phys_io'      = STR(phys_io, 8, 0),
        'cpu(mm:ss)'   = STR((cpu_time / 1000 / 60), 6) + ':'
                       + CASE
                             WHEN LEFT(STR(((cpu_time / 1000) % 60), 2), 1) = ' '
                                 THEN STUFF(STR(((cpu_time / 1000) % 60), 2), 1, 1, '0')
                             ELSE STR(((cpu_time / 1000) % 60), 2)
                         END,
        'mem(MB)'      = STR(memory_mb, 8, 2),
        'program_name' = LEFT(program_name, 50),
        'command'      = command,
        'lastwaittype' = LEFT(wait_type, 25),
        'login_time'   = CONVERT(char(19), login_time, 120),
        'last_batch'   = CONVERT(char(19), last_request, 120),
        'status'       = LEFT(status, 20)
      FROM #Sessions
     WHERE session_id = @session_id

    PRINT '----------------------'
    PRINT '-- DBCC INPUTBUFFER --'
    PRINT '----------------------'
    PRINT ' '

    IF @input_buffer IS NOT NULL AND LTRIM(RTRIM(@input_buffer)) <> ''
        PRINT @input_buffer
    ELSE
        PRINT '(no input buffer available)'

    PRINT ' '
    PRINT ' '

    IF @sql_text IS NOT NULL AND LTRIM(RTRIM(@sql_text)) <> ''
    BEGIN
        PRINT '------------------'
        PRINT '-- fn_get_sql() --'
        PRINT '------------------'
        PRINT ' '
        PRINT @sql_text
    END

    FETCH NEXT FROM SessionCursor
     INTO @session_id, @request_id, @is_blocker, @input_buffer, @sql_text
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

CLOSE SessionCursor
DEALLOCATE SessionCursor

PRINT '----------------------'
PRINT '-- Pending File I/O --'
PRINT '----------------------'
PRINT ' '

SELECT
    'Database'   = LEFT(DB_NAME(DatabaseID), 25),
    'FileName'   = LEFT(FileName, 30),
    'DBFileName' = LEFT(DBFileName, 50),
    FileID,
    IO_Pending
  FROM #PendingIO

IF @WaitIfBlocked = 1 AND @BlockedSessions > 0 AND @WaitSeconds > 0
BEGIN
    SET @Delay = CONVERT(varchar(8), DATEADD(second, @WaitSeconds, 0), 108)
    WAITFOR DELAY @Delay
END

GO

IF OBJECT_ID('dbo.Now2') IS NOT NULL
    PRINT 'Procedure Now2 created.'
ELSE
    PRINT 'Procedure Now2 NOT created.'
GO