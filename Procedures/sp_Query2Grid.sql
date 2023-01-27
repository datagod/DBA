use master
IF (object_id('sp_Query2Grid') IS NOT NULL)
BEGIN
  PRINT 'Dropping: sp_Query2Grid'
  DROP PROCEDURE sp_Query2Grid     
END
GO
PRINT 'Creating: sp_Query2Grid'
GO
create procedure sp_Query2Grid
(
  @SQL        varchar(8000),
  @CellSpacer varchar(255) = ' '
)
as
 
---------------------------------------------------------------------------------------------------
-- Date Created: September 28, 2006
-- Author:       William McEvoy
--               
-- Description:  This procedure is used to generate a grid-style report.  The input SQL statement
--               should be structured as follows:
--               
--               select SideRowItems,
--                      TopRowItems,
--                      IntersectionValue
--                 from YourTableViewEtc
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


---------------------------------------------------------------------
-- Declare and initialize local variables                          --
---------------------------------------------------------------------

declare @SideRow       varchar(255),
        @SideRowValue  varchar(255),
        @TopRow        varchar(255),
        @TopRowValue   varchar(255),
        @GridValue     varchar(255),
        @PrintLine     varchar(7000),
        @EmptySideCell varchar(255),
        @EmptyTopCell  varchar(255),
        @EmptyGridCell varchar(255),
        @SideCellWidth int,
        @TopCellWidth  int,
        @GridCellWidth int
        
select  @PrintLine     = '',
        @EmptySideCell = '',
        @EmptyTopCell  = '',
        @EmptyGridCell = '',
        @SideCellWidth = 0,
        @TopCellWidth  = 0,
        @GridCellWidth = 0

---------------------------------------------------------------------
-- M A I N   P R O C E S S I N G                                   --
---------------------------------------------------------------------
--                                                                 --
--                                                                 --
---------------------------------------------------------------------


-- Create temp tables
if object_id('tempdb..#Grid') is not null
   drop table #Grid

create table #Grid 
(
  GridID         int identity,
  SideRow        varchar(255), 
  SideRowDisplay varchar(255), 
  TopRow         varchar(255), 
  TopRowDisplay  varchar(255), 
  GridValue      varchar(255)
)

/*
if object_id('tempdb..#Results') is not null
   drop table #Results

create table #Results
(
  SideRowValue varchar(255),
  GridValue    varchar(255),
  PrintLine  varchar(7000)
)
*/

insert into #Grid (SideRow, TopRow, GridValue)
execute(@SQL)

-- Remove NULLS
update #Grid 
   set SideRow   = isnull(SideRow,  '??'),
       TopRow    = isnull(TopRow,   '??'),
       GridValue = isnull(GridValue,'??')
       
-- Add Indexes
Create clustered Index ci_Grid1 on #Grid(TopRow)
Create           Index ci_Grid2 on #Grid(SideRow,GridValue)



-- Determine Cell Widths
select @SideCellWidth = max(len(SideRow)) +1 ,
       @TopCellWidth  = max(len(TopRow))  ,
       @GridCellWidth = max(len(GridValue))
  from #Grid
 
-- Stuff the cells with spaces for sorting purposes

update #Grid
   set TopRowDisplay   = stuff(replicate(' ',@TopCellWidth)   ,@TopCellWidth  - len(TopRow)  + 1, len(TopRow) ,TopRow),
       SideRowDisplay  = stuff(replicate(' ',@SideCellWidth-1),@SideCellWidth - len(SideRow) , len(SideRow),SideRow)

 
DECLARE TopRow_Cursor CURSOR  SCROLL FOR
select distinct TopRowDisplay, TopRow
  from #grid
 order by TopRow
  
 
DECLARE SideRow_Cursor CURSOR SCROLL FOR
select distinct SideRowDisplay, SideRow
  from #Grid
 order by SideRow
 
OPEN TopRow_Cursor
OPEN SideRow_Cursor


FETCH NEXT
 FROM SideRow_Cursor
 INTO @SideRowValue,
      @SideRow



------------------------
-- Print Header Lines --
------------------------


IF (@TopCellWidth > @GridCellWidth)
  select @GridCellWidth = @TopCellWidth

--select @TopCellWidth, @GridCellWidth

-- Prepare Empty Cells
select @EmptySideCell = replicate(' ',@SideCellWidth),
       @EmptyGridCell = replicate(' ',@GridCellWidth)
       

-- Create Header row
select @PrintLine = @EmptySideCell + ' ' + @CellSpacer

--select @PrintLine = @PrintLine + isnull(stuff(@EmptyGridCell,@GridCellWidth + 1 - len(TopRow),len(TopRow),TopRow),TopRow) + @CellSpacer
--  from (select distinct top 100 percent rtrim(TopRow) 'TopRow' from #Grid order by TopRow) as G

select @PrintLine = @PrintLine + isnull(stuff(@EmptyGridCell,1,len(TopRow),TopRow),TopRow) + @CellSpacer
  from (select distinct top 100 percent rtrim(TopRow) 'TopRow' from #Grid order by TopRow) as G order by TopRow

print @PrintLine

-- Print separator
select @PrintLine =  replicate(' ',@SideCellWidth) + '-' + replicate('-',len(@PrintLine) - @SideCellWidth)
print @PrintLine




WHILE (@@FETCH_STATUS <> -1)
BEGIN

  -- Prepare Row Title
  select @PrintLine = ''
  select @PrintLine = stuff(@EmptySideCell,@SideCellWidth - len(@SideRowValue),len(@SideRowValue),@SideRowValue) + '|' + @CellSpacer

  FETCH FIRST
   FROM TopRow_Cursor
   INTO @TopRowValue,
        @TopRow


  WHILE (@@FETCH_STATUS <> -1)
  BEGIN


    select @GridValue = ''
        select @GridValue = isnull(GridValue,'?')
      from #Grid
     where TopRow  = @TopRowValue
       and SideRow = @SideRowValue
    
    -- Print GridValues for the entire row
    select @PrintLine = @PrintLine + isnull(Stuff(@EmptyGridCell, @GridCellWidth - len(@Gridvalue), len(@GridValue),@GridValue),isnull(@GridValue,' ')) + @CellSpacer
         
--    print 'TopRow:    ' + @TopRowValue
--    print 'SideRow:   ' + @SideRowValue
--    print 'GridValue: ' + isnull(convert(varchar(10),@Gridvalue),0)

    FETCH NEXT 
     FROM TopRow_Cursor
     INTO @TopRowValue,
          @TopRow
  END

  print @PrintLine

  FETCH NEXT 
   FROM SideRow_Cursor
   INTO @SideRowValue,
        @SideRow
END



close TopRow_Cursor
close SideRow_Cursor

deallocate TopRow_Cursor
deallocate SideRow_Cursor
go

IF (object_id('sp_Query2Grid') IS NOT NULL)
  PRINT 'Procedure created.'
ELSE
  PRINT 'Procedure NOT created.'
GO


