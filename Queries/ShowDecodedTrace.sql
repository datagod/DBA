/*
  ShowDecodedTrace.sql
  Queries (ad-hoc)

  Date Revised: September 2, 2026
  Author:       Bill McEvoy

  Decode a generic imported SQL Trace table produced by fn_trace_gettable
  or Profiler Save As Table. Set @TraceTable below to your imported table
  (schema.table).

  This is NOT for dbo.PerformanceTraceResults (StopPerformanceTrace import).
  That table uses QueryText / EventSubclass instead of TextData / EventSubClass.

  Duration is stored in microseconds; CPU is stored in milliseconds.
  Output times are returned in seconds.

  Requires VIEW SERVER STATE (sys.trace_events).
*/

-- Set this to the schema.table of your imported trace.
DECLARE @TraceTable nvarchar(261) = N'dbo.TraceTable';

DECLARE @Schema sysname = PARSENAME(@TraceTable, 2);
DECLARE @Object sysname = PARSENAME(@TraceTable, 1);
DECLARE @TwoPartName nvarchar(517);
DECLARE @sql nvarchar(max);
DECLARE @msg nvarchar(400);

IF PARSENAME(@TraceTable, 3) IS NOT NULL
   OR @Object IS NULL
BEGIN
    RAISERROR('@TraceTable must be a one- or two-part name (schema.table). Set it to your imported table.', 16, 1);
END
ELSE
BEGIN
    IF @Schema IS NULL
        SET @Schema = N'dbo';

    SET @TwoPartName = QUOTENAME(@Schema) + N'.' + QUOTENAME(@Object);

    IF OBJECT_ID(@TwoPartName, N'U') IS NULL
    BEGIN
        SET @msg = N'Trace table ' + @TwoPartName + N' does not exist. Set @TraceTable to your imported table.';
        RAISERROR(@msg, 16, 1);
    END
    ELSE
    BEGIN
        SET @sql = N'
SELECT
    EventName       = te.name,
    EventCategory   = tc.name,
    Subclass        = tsv.subclass_name,
    tr.StartTime,
    tr.EndTime,
    DurationSeconds = ROUND(tr.Duration / 1000000.0, 2),
    CpuSeconds      = ROUND(tr.CPU / 1000.0, 2),
    tr.Reads,
    tr.Writes,
    tr.RowCounts,
    tr.DatabaseName,
    tr.ObjectName,
    tr.LoginName,
    tr.HostName,
    tr.ApplicationName,
    tr.SPID,
    tr.TextData
FROM ' + @TwoPartName + N' AS tr
LEFT JOIN sys.trace_events AS te
    ON te.trace_event_id = tr.EventClass
LEFT JOIN sys.trace_categories AS tc
    ON tc.category_id = te.category_id
LEFT JOIN sys.trace_subclass_values AS tsv
    ON tsv.trace_event_id = tr.EventClass
   AND tsv.subclass_value = tr.EventSubClass
   AND tsv.trace_column_id = 21  -- EventSubClass
ORDER BY tr.Duration DESC;
';

        EXEC sys.sp_executesql @sql;
    END
END
