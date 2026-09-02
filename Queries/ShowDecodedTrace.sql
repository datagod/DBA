/*
  ShowDecodedTrace.sql
  Queries (ad-hoc)

  Date:    September 2, 2026
  Author:  Bill McEvoy

  Decode an imported SQL Trace table: EventClass / EventSubClass become names,
  Duration is microseconds, CPU is milliseconds. Times are returned in seconds.

  Primary source: dbo.PerformanceTraceResults (StopPerformanceTrace import).
  StopPerformanceTrace only imports event classes 10, 12, 45
  (RPC:Completed, SQL:BatchCompleted, SP:StmtCompleted).

  If the source is a raw fn_trace_gettable / Profiler Save-As-Table load, swap
  the table name, use TextData instead of QueryText, and EventSubClass instead
  of EventSubclass.

  Requires VIEW SERVER STATE (sys.trace_events).
*/

SELECT
    EventName       = te.name,
    EventCategory   = tc.name,
    Subclass        = tsv.subclass_name,
    ptr.StartTime,
    ptr.EndTime,
    DurationSeconds = ROUND(ptr.Duration / 1000000.0, 2),
    CpuSeconds      = ROUND(ptr.CPU / 1000.0, 2),
    ptr.Reads,
    ptr.Writes,
    ptr.RowCounts,
    ptr.DatabaseName,
    ptr.ObjectName,
    ptr.LoginName,
    ptr.HostName,
    ptr.ApplicationName,
    ptr.SPID,
    ptr.QueryText
FROM dbo.PerformanceTraceResults AS ptr
LEFT JOIN sys.trace_events AS te
    ON te.trace_event_id = ptr.EventClass
LEFT JOIN sys.trace_categories AS tc
    ON tc.category_id = te.category_id
LEFT JOIN sys.trace_subclass_values AS tsv
    ON tsv.trace_event_id = ptr.EventClass
   AND tsv.subclass_value = ptr.EventSubclass
   AND tsv.trace_column_id = 21  -- EventSubClass
ORDER BY ptr.Duration DESC;
