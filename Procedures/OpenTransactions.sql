CREATE or alter PROCEDURE OpenTransactions
AS
BEGIN
    SELECT 
        LEFT(DB_NAME(t.database_id), 20) AS 'Database',
        LEFT(s.Host_Name, 15) AS 'Host',
        LEFT(s.Login_name, 25) AS 'Login',
        st.session_id,
        t.Database_Transaction_Begin_Time AS 'TxStart',
        t.database_transaction_log_record_count AS 'TxLogRecordCount',
        t.database_transaction_log_bytes_used AS 'TxLogBytesUsed',
        CASE 
            WHEN DATEDIFF(SECOND, t.Database_Transaction_Begin_Time, GETDATE()) > 0 
            THEN t.database_transaction_log_record_count / DATEDIFF(SECOND, t.Database_Transaction_Begin_Time, GETDATE())
            ELSE 0 
        END AS RecsPerSec,
        s.status AS 'SessionStatus'
    FROM 
        sys.dm_tran_database_transactions t
    JOIN 
        sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id 
    JOIN 
        sys.dm_exec_sessions s ON s.session_id = st.session_id;
END
 
