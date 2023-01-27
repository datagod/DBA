use dba
IF (object_id('dbo.fn_ScrapeText') IS NOT NULL)
BEGIN
  PRINT 'Dropping: dbo.fn_ScrapeText'
  DROP function dbo.fn_ScrapeText
END
GO
PRINT 'Creating: dbo.fn_ScrapeText'
GO
CREATE FUNCTION dbo.fn_ScrapeText 
(
  @string varchar(max)
) 
returns varchar(max)

AS
BEGIN
---------------------------------------------------------------------------------------------------
-- Title:        fn_ScrapeText
--               
-- Date Created: April 4, 2006
--               
-- Author:       William McEvoy
--               
-- Description:  This function will attempt to remove markup language formatting from a string. This is 
--               accomplished by concetenating all text contained between greater than and less 
--               than signs within the formatted text.  
--               
-- Example:      <P>This text will be parsed and returned but not the P's</P>
--               
---------------------------------------------------------------------------------------------------
-- Date Revised: March 22, 2015
-- Author:       William McEvoy
-- Reason:       Updating to handle large XML blobs.
---------------------------------------------------------------------------------------------------
-- Date Revised: 
-- Author:       
-- Reason:       
---------------------------------------------------------------------------------------------------

declare @text  varchar(max),
        @PenDown char(1),
        @char  char(1),
        @len   int,
        @count int

select  @count = 0,
        @len   = 0,
        @text  = ''


---------------------------------------------------------------------------------------------------
-- M A I N   P R O C E S S I N G
---------------------------------------------------------------------------------------------------

-- Add tokens
select @string = '>' + @string + '<'

-- Replace Special Characters
select @string = replace(@string,'&nbsp;',' ')

-- Parse out the formatting codes
select @len = len(@string)
while (@count <= @len)
begin
  select @char = substring(@string,@count,1)

  if (@char = '>')
     select @PenDown = 'Y'
  else 
  if (@char = '<')
    select @PenDown = 'N'
  else  
  if (@PenDown = 'Y')
    select @text = @text + @char

  select @count = @count + 1
end

RETURN @text
END
GO
IF (object_id('dbo.fn_ScrapeText') IS NOT NULL)
  PRINT 'Function created.'
ELSE
  PRINT 'Function NOT created.'
GO





