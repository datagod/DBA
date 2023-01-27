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
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------
set nocount on

---------------------------------------------------------------------
-- Validate input parameters                                       --
---------------------------------------------------------------------

IF (@EmailFrom is null or @EmailFrom = '')
  select  @EmailFrom = 'SQL_' + upper(@@SERVERNAME) + '@BOLDstreet.com'


---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------

declare @profile_name varchar(100)
select  @profile_name = [name] from msdb.dbo.sysmail_profile where profile_id = 1


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
