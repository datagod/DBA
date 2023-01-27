IF (object_id('dbo.GetErrorInfo') IS NOT NULL)
BEGIN
  print 'Dropping function: GetErrorInfo'
  drop function dbo.GetErrorInfo
END
print 'Creating function: GetErrorInfo'
go
CREATE FUNCTION dbo.GetErrorInfo
()
RETURNS varchar(1000)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: January 19, 2011
-- Author:       William McEvoy
--               
-- Description:  This function formats a string with the current error information and should
--               be called from within a CATCH bloack of a TRY..CATCH construct.
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: September 16, 2011
-- Author:       William McEvoy
-- Reason:       Added ISNULL logic to prevent the output string from being truncated.
---------------------------------------------------------------------------------------------------
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------


BEGIN
  declare @output varchar(2000)
  
   
  select  @output =  ' (ERROR: ' + isnull(CAST(ERROR_NUMBER()   AS VARCHAR(10)),'(UNKNOWN ERROR)')
                  +  ','         + isnull(CAST(ERROR_SEVERITY() AS VARCHAR(10)),'(UNKNOWN SEVERITY)')
                  +  ','         + isnull(CAST(ERROR_STATE()    AS VARCHAR(10)),'(UNKOWN ERROR_STATE)')
                  +  ' Msg: '    + isnull(ERROR_MESSAGE(),                      '(UNKNOWN ERROR_MESSAGE)')
                  +  ' Line: '   + isnull(CAST(ERROR_LINE()     AS VARCHAR),    '(UNKNOWN ERROR_LINE)')
                  +  ' Proc: '   + isnull(ERROR_PROCEDURE(),                    '(UNKNOWN ERROR_PROCEDURE)')
                  + ') '
  RETURN @output

END
GO

IF (object_id('dbo.GetErrorInfo') IS NOT NULL)
  print 'Function created'
ELSE
  print 'Function NOT created'
go

