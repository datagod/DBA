use dba
drop table IndexFragmentation


create table IndexFragmentation
(
  ID                  int identity constraint PK_IndexFragmentation primary key NOT NULL,
  CaptureDate         datetime default getdate(),
  ServerName          varchar(50),
  DatabaseName        varchar(50),
  TableName           varchar(100),
  IndexName           varchar(150),
  DatabaseID          smallint,
  ObjectID            int,
  IndexID             smallint,
  IndexType           varchar(30),
  AllocUnitType       varchar(30),
  IndexDepth          smallint,
  AvgFragPercent      smallint,
  FragmentCount       int,
  FragmentSizeInPages decimal(12,2),
  [PageCount]         int,
  RecordCount         int,
  DefragSQL           varchar(4000),
  
)
  
  
insert into IndexFragmentation
       (CaptureDate,
        ServerName, 
        DatabaseName,
        TableName,   
        IndexName,   
        DatabaseID,  
        ObjectID,    
        IndexID,     
        IndexType,   
        AllocUnitType,
        IndexDepth,   
        AvgFragPercent,
        FragmentCount, 
        FragmentSizeInPages,
        [PageCount],
        RecordCount,
        DefragSQL)  
select getdate(),
       @@ServerName,
       db_name(),
       so.Name,
       si.Name,
       db_id(),
       ips.object_id,
       ips.index_id,
       ips.index_type_desc,
       ips.alloc_unit_type_desc,
       ips.index_depth,
       ips.avg_fragmentation_in_percent,
       ips.fragment_count,
       avg_fragment_size_in_pages,
       ips.page_count,
       ips.record_count,
       case
         when ips.index_id = 0 then 'alter table ' + so.name + ' rebuild with (online = on)'
         else 'alter index ' + si.name + ' on ' + ss.name + '.' + so.name + ' rebuild with (online = on)'
       end
  from sys.dm_db_index_physical_stats(db_id(),null,null,null, 'sampled') ips
  join sys.objects so  on so.object_id = ips.object_id
  join sys.schemas ss  on ss.schema_id = so.schema_id
  join sys.indexes si  on si.object_id = ips.object_id
                      and si.index_id  = ips.index_id
--where si.index_id <> 0 -- ignore heaps
order by so.Name, ips.index_id

ips.page_count


select DefragSQL from IndexFragmentation
truncate table IndexFragmentation

select * from MyTable



2010-10-21 15:02:47.077