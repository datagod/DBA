-- Created by ChatGPT
-- Jan 29, 2023

CREATE PROCEDURE ShowBlackBoxTraces
AS
BEGIN
    SET NOCOUNT ON;

    SELECT * 
    FROM sys.fn_trace_getinfo(NULL) AS trace_info 
    CROSS APPLY sys.fn_trace_gettable(trace_info.path, DEFAULT) AS trace_events
    ORDER BY trace_events.EventSequence DESC
    OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY;
END;