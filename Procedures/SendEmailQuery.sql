use DBA
IF (object_id('SendEmailQuery') IS NOT NULL)
BEGIN
  PRINT 'Dropping: SendEmailQuery'
  DROP PROCEDURE SendEmailQuery     
END
GO
PRINT 'Creating: SendEmailQuery'
GO
create procedure SendEmailQuery
(
  @EmailTo   varchar(500),
  @EmailFrom varchar(100) = '',
  @Subject   varchar(100),
  @Body      varchar(8000)='',
  @Query     varchar(8000)
)
as
 
---------------------------------------------------------------------------------------------------
-- Date Created: January 11, 2011
-- Author:       William McEvoy
--               
-- Description:  This stored procedure is used to send emails, but also supports Queries.
--               
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: August 13, 2026
-- Author:       Bill McEvoy
-- Reason:       Remove hardcoded company email domain; resolve @EmailFrom from Database Mail accounts
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------

-- Prefer Database Mail account address when @EmailFrom is not supplied (no hardcoded domain)
IF (@EmailFrom is null or @EmailFrom = '')
BEGIN
  SELECT TOP (1)
         @EmailFrom = a.email_address
    FROM msdb.dbo.sysmail_account AS a
   WHERE NULLIF(LTRIM(RTRIM(a.email_address)), '') IS NOT NULL
   ORDER BY a.account_id
END

IF (@EmailTo is null or @EmailTo = '' or @Subject is null or @Subject = '')
BEGIN
  RAISERROR('SendEmailQuery requires non-empty @EmailTo and @Subject.', 16, 1)
  RETURN
END

---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------

declare @profile_name varchar(100)
select  @profile_name = (select top 1 [name] from msdb.dbo.sysmail_profile order by profile_id)


---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
--                                                                 --
---------------------------------------------------------------------


exec msdb.dbo.sp_send_dbmail
    @profile_name = @profile_name,
    @from_address = @EmailFrom,
    @recipients   = @EmailTo,
    @subject      = @Subject,
    @Body         = @Body,
    @Body_Format  = 'HTML',
    @Query        = @Query,
    @Execute_Query_Database = 'DBA',
    @append_query_error = 1


GO
