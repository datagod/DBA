
/****** Object:  View [dbo].[vRandom]    Script Date: 2014-04-28 1:44:12 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


go
IF (object_id('vRandom') IS NOT NULL)
BEGIN
  print 'Dropping view: vRandom'
  drop View vRandom
END
print 'Creating procedure: vRandom'
GO

CREATE VIEW [dbo].[vRandom]
AS
SELECT RAND() as RANDOM

GO





IF (object_id('fn_Random') IS NOT NULL)
BEGIN
  print 'Dropping function: fn_Random'
  drop function fn_Random
END
print 'Creating function: vRandom'
GO


Create FUNCTION [dbo].[fn_Random]
(
	@Low int,
	@High int
)
RETURNS	int
AS
---------------------------------------------------------------------------------------------------
-- Date Created: Aug 30, 2011
-- Author:       William McEvoy
--               
-- Description:  This function returns a random integer between 0 and the input value
--               
---------------------------------------------------------------------------------------------------
BEGIN

  ---- Create the variables for the random number generation
  DECLARE @Random INT;
  

  ---- This will create a random number between 1 and 999
  
  -- this method never makes it to HIGH, and if low is 1 and high is 1, it returns 0
  --SELECT @Random = ROUND(((@High - @Low -1) * RANDOM + @Low), 0)

  SELECT @Random = @Low + CONVERT(INT, (@High-@Low+1) * RANDOM)
    from vRandom
  return @Random
END

GO


