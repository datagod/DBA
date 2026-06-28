
/*
  ShowServerIP.sql

  Deploy to the DBA tool database, then execute:
    EXEC dbo.ShowServerIP
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ShowServerIP') IS NOT NULL
BEGIN
    PRINT 'Dropping: ShowServerIP'
    DROP PROCEDURE dbo.ShowServerIP
END
GO

PRINT 'Creating: ShowServerIP'
GO

CREATE PROCEDURE dbo.ShowServerIP
AS
---------------------------------------------------------------------------------------------------
-- Date Created: June 26, 2026
-- Author:       Bill McEvoy
-- Description:  Displays SQL Server listener IP addresses and TCP ports for this instance.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

DECLARE
    @MajorVersion   tinyint,
    @SqlInstance    sysname,
    @MachineName    sysname,
    @HasNetworkInfo bit

SET @MajorVersion = CONVERT(tinyint,
    LEFT(CAST(SERVERPROPERTY('ProductVersion') AS varchar(30)),
         NULLIF(CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))), 0) - 1))

SET @SqlInstance = CAST(@@SERVERNAME AS sysname)
SET @MachineName = CAST(SERVERPROPERTY('MachineName') AS sysname)
                      + ISNULL('\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(30)), '')

SET @HasNetworkInfo = CASE
    WHEN EXISTS (
        SELECT 1
          FROM sys.system_objects AS o
         WHERE o.name = N'dm_os_network_info'
           AND o.type = N'V'
    ) THEN 1
    ELSE 0
END

PRINT ' '
PRINT ' '
PRINT 'SERVER IP ADDRESSES'
PRINT '==================='
PRINT ' '

SELECT
    'SQL Instance' = @SqlInstance,
    'Machine Name' = @MachineName,
    'Report Time'  = CONVERT(varchar(19), GETDATE(), 120)

PRINT ' '
PRINT 'Listener endpoints (from active connections)'
PRINT '--------------------------------------------'
PRINT ' '

SELECT DISTINCT
    'IP Address' = CONVERT(varchar(45), c.local_net_address),
    'TCP Port'   = c.local_tcp_port,
    'Protocol'   = LEFT(c.net_transport, 20)
  FROM sys.dm_exec_connections AS c
 WHERE c.local_net_address IS NOT NULL
 ORDER BY c.local_tcp_port,
          c.local_net_address

IF @@ROWCOUNT = 0
BEGIN
    PRINT 'No listener addresses found in sys.dm_exec_connections.'
    PRINT 'Connect to this instance and run again, or check network configuration.'
    PRINT ' '
END

IF @HasNetworkInfo = 1
BEGIN
    PRINT 'Registered network interfaces (sys.dm_os_network_info)'
    PRINT '----------------------------------------------------'
    PRINT ' '

    EXEC (N'
    SELECT
        ''IP Address'' = CONVERT(varchar(45), n.ip_address),
        ''Subnet''     = CONVERT(varchar(45), n.ip_subnet_mask),
        ''Family''     = CASE n.family WHEN 2 THEN ''IPv4'' WHEN 23 THEN ''IPv6'' ELSE CAST(n.family AS varchar(10)) END,
        ''Active''     = CASE WHEN n.is_ipv6 = 1 THEN ''IPv6'' ELSE ''IPv4'' END
      FROM sys.dm_os_network_info AS n
     ORDER BY n.family,
              n.ip_address')
END
ELSE
BEGIN
    PRINT 'sys.dm_os_network_info is not available on this SQL Server version.'
    PRINT 'Listener addresses above come from sys.dm_exec_connections only.'
END

PRINT ' '

GO

IF OBJECT_ID('dbo.ShowServerIP') IS NOT NULL
    PRINT 'Procedure created'
ELSE
    PRINT 'Procedure NOT created'
GO