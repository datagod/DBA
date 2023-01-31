-- Created with ChatGPT Jan 2023

WITH cte AS (
  SELECT 
    qs.execution_count,
    qs.total_worker_time/qs.execution_count AS avg_worker_time,
    qs.last_execution_time,
    qt.text,
    db_name(qt.dbid) AS database_name,
    object_name(qt.objectid) AS procedure_name
  FROM 
    sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
)
SELECT 
  execution_count,
  avg_worker_time,
  last_execution_time,
  text,
  database_name,
  procedure_name
FROM 
  cte
WHERE 
  avg_worker_time > 1000
ORDER BY 
  last_execution_time DESC;