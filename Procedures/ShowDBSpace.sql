use dba
go



create or alter  PROCEDURE dbo.ShowDBSpace
(
  @ShrinkCode      char(1) = 'N',
  @MBFreeThreshold int     = 500,  -- generate shrink code if DB has more than X MB free space
  @DBName          varchar(100) = '%'
  
)
as

declare @SQL varchar(5000)

IF EXISTS (SELECT NAME FROM tempdb..sysobjects WHERE NAME = '##Results')    
DROP TABLE ##Results    


create table #DriveSpace
(
  Drive varchar(2),
  MBFree int
)
insert into #DriveSpace
exec xp_fixeddrives

      
CREATE TABLE ##Results ([DBName] sysname, 
[FileName] sysname, 
[Physical Name] NVARCHAR(260),
[File Type] VARCHAR(4), 
[Total Size in MB] INT, 
[Available Space in MB] INT, 
[Growth Units] VARCHAR(15), 
[Max File Size in MB] INT)   

SELECT @SQL =    
'USE [?] INSERT INTO ##Results([DBName], [FileName], [Physical Name],    
[File Type], [Total Size in MB], [Available Space in MB],    
[Growth Units], [Max File Size in MB])    
SELECT DB_NAME(),   
[name] AS [FileName],    
physical_name AS [Physical Name],    
[File Type] =    
CASE type   
WHEN 0 THEN ''Data'''    
+   
           'WHEN 1 THEN ''Log'''   
+   
       'END,   
[Total Size in MB] =   
CASE ceiling([size]/128)    
WHEN 0 THEN 1   
ELSE ceiling([size]/128)   
END,   
[Available Space in MB] =    
CASE ceiling([size]/128)   
WHEN 0 THEN (1 - CAST(FILEPROPERTY([name], ''SpaceUsed''' + ') as int) /128)   
ELSE (([size]/128) - CAST(FILEPROPERTY([name], ''SpaceUsed''' + ') as int) /128)   
END,   
[Growth Units]  =    
CASE [is_percent_growth]    
WHEN 1 THEN CAST(growth AS varchar(20)) + ''%'''   
+   
           'ELSE CAST(growth*8/1024 AS varchar(20)) + '' MB'''   
+   
       'END,   
[Max File Size in MB] =    
CASE [max_size]   
WHEN -1 THEN NULL   
WHEN 268435456 THEN NULL   
ELSE [max_size]   
END   
FROM sys.database_files   
ORDER BY [File Type], [file_id]'   

--Print the command to be issued against all databases   
--PRINT @SQL   

--Run the command against each database   
EXEC sp_MSforeachdb @SQL   

--UPDATE ##Results SET [Free Space %] = [Available Space in MB]/[Total Size in MB] * 100   


IF (@ShrinkCode <> 'Y')
BEGIN
;with TheReport as
(
  SELECT 
      [DBName],   
      [FileName],   
      left([FileName],50) as 'LogicalFileName',
      [Physical Name],   
      [File Type],   
      [Total Size in MB] AS [Size (MB)],   
      [Available Space in MB],   
      CEILING(CAST([Available Space in MB] AS decimal(10,1)) / [Total Size in MB]*100) AS [Free Space %],   
      [Growth Units],   
      [Max File Size in MB] AS [MaxSize(MB)],
      ds.MBFree as 'DiskFreeMB',
      ShrinkTarget = [Total Size in MB] - [Available Space in MB]

    
  FROM ##Results r    
  left join #DriveSpace ds on ds.Drive = left(r.[Physical Name],1)
)
  select left([DBName],30) as 'DBName',
         
         case 
           when len([Physical Name]) > 40 then left([Physical Name],3) + '...' + right([Physical Name],34)
           else left([Physical Name],40)
         end as 'FileName',
         [File Type] as 'FileType',
         [Size (MB)] as 'Size(MB)',
         [Available Space in MB] as [SpaceFree(MB)],
         left([Free Space %],3) as 'FreeSpace%',
         [Growth Units] as 'GrowthUnits',
         [MaxSize(MB)],
         DiskFreeMB,
         'Alert' = case
                     when (DiskFreeMB < 2500) then 'Critical'
                     when (DiskFreeMB < 5000) then 'Warning'
                     when ([Free Space %] <= 10 and DiskFreeMB < 5000) then 'Critical'
                     when ([Free Space %] <= 20 and DiskFreeMB < 5000) then 'Warning'
                     else 'Good'
                  end

                  
  from TheReport   tr
  where DBName like @DBName 
order by DBName
END
ELSE

BEGIN

;with ShrinkCommands as
(
  SELECT 
      [DBName],   
      [FileName],   
      left([FileName],50) as 'LogicalFileName',
      [Physical Name],   
      [File Type],   
      [Total Size in MB] AS [Size (MB)],   
      [Available Space in MB],   
      CEILING(CAST([Available Space in MB] AS decimal(10,1)) / [Total Size in MB]*100) AS [Free Space %],   
      [Growth Units],   
      [Max File Size in MB] AS [MaxSize(MB)],
      ds.MBFree as 'DiskFreeMB',
      ShrinkTarget = [Total Size in MB] - [Available Space in MB]

    
  FROM ##Results r    
  left join #DriveSpace ds on ds.Drive = left(r.[Physical Name],1)
)
  select'ShrinkCommand' = 'use ' + DBName 
                        + char(13) + char(10)
                        + '-- SizeMB: ' + convert(varchar(15),[Size (MB)])
                        + char(13) + char(10)
                        + '-- FreeMB: ' + convert(varchar(15),[Available Space in MB])
                        + char(13) + char(10)
                        + 'checkpoint' + char(13) + char(10) + 'checkpoint'
                        + char(13) + char(10)
                        + 'DBCC SHRINKFILE ([' +  LogicalFileName + '], ' 
                        + convert(varchar(15),ShrinkTarget)+ ',TRUNCATEONLY)'
                        + char(13) + char(10)
                        + 'checkpoint' + char(13) + char(10) + 'checkpoint'
                        + char(13) + char(10)
                        + 'DBCC SHRINKFILE ([' + LogicalFileName + '], ' 
                        + convert(varchar(15),ShrinkTarget)+ ');'
                        + char(13) + char(10)
                        + char(13) + char(10)
   from ShrinkCommands
  where [Available Space in MB] >= @MBFreeThreshold
    and DBName <> 'TempDB'
END


DROP TABLE ##Results   
GO
