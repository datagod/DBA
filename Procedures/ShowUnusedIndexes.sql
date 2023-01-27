

-- This one omits indexes that have NO usage!!
;with IndexUsage as
(
SELECT 
o.name AS TableName
, i.name AS IndexName
, i.index_id AS IndexID
, dm_ius.user_seeks AS UserSeek
, dm_ius.user_scans AS UserScans
, dm_ius.user_lookups AS UserLookups
, dm_ius.user_updates AS UserUpdates
, p.TableRows
, 'DROP INDEX ' + QUOTENAME(i.name)
+ ' ON ' + QUOTENAME(s.name) + '.' + QUOTENAME(OBJECT_NAME(dm_ius.OBJECT_ID)) AS 'drop statement'
FROM sys.dm_db_index_usage_stats dm_ius
INNER JOIN sys.indexes i ON i.index_id = dm_ius.index_id AND dm_ius.OBJECT_ID = i.OBJECT_ID
INNER JOIN sys.objects o ON dm_ius.OBJECT_ID = o.OBJECT_ID
INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
INNER JOIN (SELECT SUM(p.rows) TableRows, p.index_id, p.OBJECT_ID
FROM sys.partitions p GROUP BY p.index_id, p.OBJECT_ID) p
ON p.index_id = dm_ius.index_id AND dm_ius.OBJECT_ID = p.OBJECT_ID
WHERE OBJECTPROPERTY(dm_ius.OBJECT_ID,'IsUserTable') = 1
AND dm_ius.database_id = DB_ID()
AND i.type_desc = 'nonclustered'
AND i.is_primary_key = 0
AND i.is_unique_constraint = 0
)
select * 
  from IndexUsage order by tablerows desc
  
 where userSeek    = 0
   and UserScans   = 0
   and UserLookups = 0
order by TableRows desc



master..xp_fixeddrives

sp_spaceused




-- This one shows ALL indexes
SELECT PVT.TABLENAME, PVT.INDEXNAME, PVT.INDEX_ID, [1] AS COL1, [2] AS COL2, [3] AS COL3, 
       [4] AS COL4,  [5] AS COL5, [6] AS COL6, [7] AS COL7, B.USER_SEEKS, 
       B.USER_SCANS, B.USER_LOOKUPS 
FROM   (SELECT A.NAME AS TABLENAME, 
               A.OBJECT_ID, 
               B.NAME AS INDEXNAME, 
               B.INDEX_ID, 
               D.NAME AS COLUMNNAME, 
               C.KEY_ORDINAL 
        FROM   SYS.OBJECTS A 
               INNER JOIN SYS.INDEXES B 
                 ON A.OBJECT_ID = B.OBJECT_ID 
               INNER JOIN SYS.INDEX_COLUMNS C 
                 ON B.OBJECT_ID = C.OBJECT_ID 
                    AND B.INDEX_ID = C.INDEX_ID 
               INNER JOIN SYS.COLUMNS D 
                 ON C.OBJECT_ID = D.OBJECT_ID 
                    AND C.COLUMN_ID = D.COLUMN_ID 
        WHERE  A.TYPE <> 'S') P 
       PIVOT 
       (MIN(COLUMNNAME) 
        FOR KEY_ORDINAL IN ( [1],[2],[3],[4],[5],[6],[7] ) ) AS PVT 
       INNER JOIN SYS.DM_DB_INDEX_USAGE_STATS B 
         ON PVT.OBJECT_ID = B.OBJECT_ID 
            AND PVT.INDEX_ID = B.INDEX_ID 
            AND B.DATABASE_ID = DB_ID() 
UNION  
SELECT TABLENAME, INDEXNAME, INDEX_ID, [1] AS COL1, [2] AS COL2, [3] AS COL3, 
       [4] AS COL4, [5] AS COL5, [6] AS COL6, [7] AS COL7, 0, 0, 0 
FROM   (SELECT A.NAME AS TABLENAME, 
               A.OBJECT_ID, 
               B.NAME AS INDEXNAME, 
               B.INDEX_ID, 
               D.NAME AS COLUMNNAME, 
               C.KEY_ORDINAL 
        FROM   SYS.OBJECTS A 
               INNER JOIN SYS.INDEXES B 
                 ON A.OBJECT_ID = B.OBJECT_ID 
               INNER JOIN SYS.INDEX_COLUMNS C 
                 ON B.OBJECT_ID = C.OBJECT_ID 
                    AND B.INDEX_ID = C.INDEX_ID 
               INNER JOIN SYS.COLUMNS D 
                 ON C.OBJECT_ID = D.OBJECT_ID 
                    AND C.COLUMN_ID = D.COLUMN_ID 
        WHERE  A.TYPE <> 'S') P 
       PIVOT 
       (MIN(COLUMNNAME) 
        FOR KEY_ORDINAL IN ( [1],[2],[3],[4],[5],[6],[7] ) ) AS PVT 
WHERE  NOT EXISTS (SELECT OBJECT_ID, 
                          INDEX_ID 
                   FROM   SYS.DM_DB_INDEX_USAGE_STATS B 
                   WHERE  DATABASE_ID = DB_ID(DB_NAME()) 
                          AND PVT.OBJECT_ID = B.OBJECT_ID 
                          AND PVT.INDEX_ID = B.INDEX_ID) 
ORDER BY TABLENAME, INDEX_ID;