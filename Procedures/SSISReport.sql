blocks

SSISReport 10

use dba
go
create or alter procedure SSISReport
(
  @NumRecPerObject INT = 5
)
as


--USE SSISDB;
WITH cteLastOperations
AS (SELECT operation_id
         , ROW_NUMBER() OVER (PARTITION BY object_id ORDER BY operation_id DESC) AS RowNum
         , object_name
         , object_id
         , (
               SELECT TOP (1)
                      CONCAT(ov.description, ' (', f.name, ')')
               FROM SSISDB.catalog.object_versions ov
                   LEFT JOIN SSISDB.catalog.projects p
                       ON p.project_id = ov.object_id
                   LEFT JOIN SSISDB.catalog.folders f
                       ON f.folder_id = p.folder_id
               WHERE ov.object_id = op.object_id
                     AND ov.created_time <= op.created_time
               ORDER BY ov.created_time DESC
           ) description
         , CASE status
               WHEN 1 THEN 'created'
               WHEN 2 THEN 'running'
               WHEN 3 THEN 'canceled'
               WHEN 4 THEN 'failed'
               WHEN 5 THEN 'pending'
               WHEN 6 THEN 'ended unexpectedly'
               WHEN 7 THEN 'succeeded'
               WHEN 8 THEN 'stopping'
               WHEN 9 THEN 'completed'
               ELSE '*Unknown'
           END AS status_name
         , CONVERT(VARCHAR(19), start_time, 20) job_start_time
         , CONVERT(VARCHAR(19), end_time, 20) job_end_time
         , LEFT(CONVERT(VARCHAR(10), DATEADD(ms, DATEDIFF(ms, start_time, end_time), CONVERT(DATETIME, '1/1/2000')), 8), 8) duration
    FROM SSISDB.catalog.operations op
    WHERE op.operation_type = 200
          AND object_id IS NOT NULL
          AND object_name LIKE 'CDW%')
SELECT object_id
     , object_name
     , @NumRecPerObject + 1 - RowNum RowNum
     , operation_id
     , description
     , status_name
     , job_start_time
     , job_end_time
     , duration
FROM cteLastOperations
WHERE RowNum <= @NumRecPerObject
ORDER BY object_name
       , RowNum DESC;
go




SSISReport


select top 100 * from ssisdb.catalog.event_messages
order by event_message_id desc

select top 100 * from SSISDB.catalog.operations 
order by operation_id desc


select top 100 * from ssisdb.catalog.event_message_context
order by context_id desc

select top 100 * from ssisdb.internal.execution_info
where folder_name = 'Foobar'
order by execution_id desc




