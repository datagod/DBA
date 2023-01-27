use dba
go
create or alter procedure OpenTransactions
as
select left(db_name(t.database_id),20) as 'Database',
       left(s.Host_Name,15) as 'Host',
       left(s.Login_name,25) as 'Login',
       st.session_id,
       Database_Transaction_Begin_Time as 'TxStart',
       database_transaction_log_record_count as 'TxLogRecordCount',
       database_transaction_log_bytes_used   as 'TxLogBytesUsed',
       status
       

from sys.dm_tran_database_transactions t
join sys.dm_tran_session_transactions st on t.transaction_id = st.transaction_id 
join sys.dm_exec_sessions s on s.session_id = st.session_id 
go

dba.dbo.OpenTransactions

