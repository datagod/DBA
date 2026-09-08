/*
  ProcedureName.sql
  Performance Tuning Framework   -- or: Procedures / Queries (ad-hoc)

  Requires SQL Server ____ (__.x) or later on the instance.

  Deploy to the tool database, then execute:
    EXEC dbo.ProcedureName
         @Param1 = N'value'

  Short purpose paragraph here.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.ProcedureName') IS NOT NULL
BEGIN
    PRINT 'Dropping: ProcedureName'
    DROP PROCEDURE dbo.ProcedureName
END
GO

PRINT 'Creating: ProcedureName'
GO

CREATE PROCEDURE dbo.ProcedureName
(
    @Param1 sysname = NULL
)
AS
---------------------------------------------------------------------------------------------------
-- Date Created: Month DD, YYYY
-- Author:       Bill McEvoy
-- Description:  One or two sentences on what this procedure does, who it is for, and any hard
--               requirements (version, permissions). Say what it does not do if that avoids
--               confusion with a sibling procedure.
---------------------------------------------------------------------------------------------------
-- Version:      1.0
-- Date Revised: Month DD, YYYY
-- Author:       Bill McEvoy
-- Reason:       Initial release.
---------------------------------------------------------------------------------------------------
-- Version:      1.1
-- Date Revised: Month DD, YYYY
-- Author:       Bill McEvoy
-- Reason:       Describe the change. Prefer why over a file list. Note behavior that stayed
--               the same when that matters for callers.
---------------------------------------------------------------------------------------------------
SET NOCOUNT ON

-- Procedure body starts here.

GO

PRINT 'Procedure created successfully.'
GO
