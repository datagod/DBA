-- Make a test table to compare with original


DECLARE
    @SourceSchema sysname = N'dbo',
    @SourceTable  sysname = N'blah',
    @DestSchema   sysname = N'dbo',
    @DestTable    sysname = N'blah_02';


DECLARE
    @Src   nvarchar(517) = QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable),
    @Dst   nvarchar(517) = QUOTENAME(@DestSchema)   + N'.' + QUOTENAME(@DestTable),
    @SrcId int,
    @sql   nvarchar(max);

SET @SrcId = OBJECT_ID(@Src);

IF @SrcId IS NULL
    THROW 50001, 'Source table not found.', 1;
IF OBJECT_ID(@Dst, 'U') IS NOT NULL
    THROW 50002, 'Destination table already exists.', 1;

SET @sql = N'SELECT TOP (0) * INTO ' + @Dst + N' FROM ' + @Src + N';';

-- Computed columns: SELECT INTO turns them into regular columns; drop and re-add
SELECT @sql = @sql + ISNULL((
    SELECT
        N' ALTER TABLE ' + @Dst + N' DROP COLUMN ' + QUOTENAME(cc.name) + N';' +
        N' ALTER TABLE ' + @Dst + N' ADD ' + QUOTENAME(cc.name) +
        N' AS ' + cc.definition +
        CASE WHEN cc.is_persisted = 1 THEN N' PERSISTED' ELSE N'' END + N';'
    FROM sys.computed_columns AS cc
    WHERE cc.object_id = @SrcId
    FOR XML PATH(''), TYPE
).value(N'.[1]', N'nvarchar(max)'), N'');

-- Defaults
SELECT @sql = @sql + ISNULL((
    SELECT
        N' ALTER TABLE ' + @Dst + N' ADD CONSTRAINT ' +
        QUOTENAME(LEFT(dc.name + N'_' + @DestTable, 128)) +
        N' DEFAULT ' + dc.definition +
        N' FOR ' + QUOTENAME(c.name) + N';'
    FROM sys.default_constraints AS dc
    JOIN sys.columns AS c
      ON c.object_id = dc.parent_object_id
     AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = @SrcId
    FOR XML PATH(''), TYPE
).value(N'.[1]', N'nvarchar(max)'), N'');

-- Check constraints
SELECT @sql = @sql + ISNULL((
    SELECT
        N' ALTER TABLE ' + @Dst + N' ADD CONSTRAINT ' +
        QUOTENAME(LEFT(cc.name + N'_' + @DestTable, 128)) +
        N' CHECK ' + cc.definition + N';'
    FROM sys.check_constraints AS cc
    WHERE cc.parent_object_id = @SrcId
    FOR XML PATH(''), TYPE
).value(N'.[1]', N'nvarchar(max)'), N'');

-- PK / unique constraints / indexes (clustered first)
SELECT @sql = @sql + ISNULL((
    SELECT x.stmt
    FROM (
        SELECT
            CASE WHEN i.is_primary_key = 1 THEN 0
                 WHEN i.type = 1 THEN 1
                 ELSE 2 END AS sort_ord,
            i.index_id,
            CASE
                WHEN i.is_primary_key = 1 THEN
                    N' ALTER TABLE ' + @Dst + N' ADD CONSTRAINT ' +
                    QUOTENAME(LEFT(i.name + N'_' + @DestTable, 128)) +
                    N' PRIMARY KEY ' + CASE WHEN i.type = 1 THEN N'CLUSTERED' ELSE N'NONCLUSTERED' END +
                    N' (' + key_cols.cols + N');'
                WHEN i.is_unique_constraint = 1 THEN
                    N' ALTER TABLE ' + @Dst + N' ADD CONSTRAINT ' +
                    QUOTENAME(LEFT(i.name + N'_' + @DestTable, 128)) +
                    N' UNIQUE ' + CASE WHEN i.type = 1 THEN N'CLUSTERED' ELSE N'NONCLUSTERED' END +
                    N' (' + key_cols.cols + N');'
                ELSE
                    N' CREATE ' + CASE WHEN i.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END +
                    CASE WHEN i.type = 1 THEN N'CLUSTERED' ELSE N'NONCLUSTERED' END +
                    N' INDEX ' + QUOTENAME(i.name) + N' ON ' + @Dst +
                    N' (' + key_cols.cols + N')' +
                    ISNULL(N' INCLUDE (' + incl_cols.cols + N')', N'') +
                    ISNULL(N' WHERE ' + i.filter_definition, N'') +
                    N' WITH (PAD_INDEX = ' + CASE WHEN i.is_padded = 1 THEN N'ON' ELSE N'OFF' END +
                    CASE WHEN i.fill_factor > 0
                         THEN N', FILLFACTOR = ' + CONVERT(varchar(3), i.fill_factor)
                         ELSE N'' END +
                    N', IGNORE_DUP_KEY = ' + CASE WHEN i.ignore_dup_key = 1 THEN N'ON' ELSE N'OFF' END +
                    N', ALLOW_ROW_LOCKS = ' + CASE WHEN i.allow_row_locks = 1 THEN N'ON' ELSE N'OFF' END +
                    N', ALLOW_PAGE_LOCKS = ' + CASE WHEN i.allow_page_locks = 1 THEN N'ON' ELSE N'OFF' END +
                    N');'
            END AS stmt
        FROM sys.indexes AS i
        CROSS APPLY (
            SELECT STUFF((
                SELECT N', ' + QUOTENAME(c.name)
                     + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
                FROM sys.index_columns AS ic
                JOIN sys.columns AS c
                  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                WHERE ic.object_id = i.object_id
                  AND ic.index_id  = i.index_id
                  AND ic.is_included_column = 0
                ORDER BY ic.key_ordinal
                FOR XML PATH(''), TYPE).value(N'.[1]', N'nvarchar(max)'), 1, 2, N'')
        ) AS key_cols(cols)
        OUTER APPLY (
            SELECT STUFF((
                SELECT N', ' + QUOTENAME(c.name)
                FROM sys.index_columns AS ic
                JOIN sys.columns AS c
                  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                WHERE ic.object_id = i.object_id
                  AND ic.index_id  = i.index_id
                  AND ic.is_included_column = 1
                ORDER BY ic.index_column_id
                FOR XML PATH(''), TYPE).value(N'.[1]', N'nvarchar(max)'), 1, 2, N'')
        ) AS incl_cols(cols)
        WHERE i.object_id       = @SrcId
          AND i.type            IN (1, 2)
          AND i.is_hypothetical = 0
          AND i.is_disabled     = 0
    ) AS x
    ORDER BY x.sort_ord, x.index_id
    FOR XML PATH(''), TYPE
).value(N'.[1]', N'nvarchar(max)'), N'');

SELECT @sql AS GeneratedSQL;   -- review this
EXEC sys.sp_executesql @sql;   -- comment out if you only want the script


