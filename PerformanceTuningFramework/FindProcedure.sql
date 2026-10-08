/*
    Find stored procedures by name across every database.

    Lives in the tools database. Name pattern is a LIKE pattern:
        N'usp_Case%'     starts with
        N'%IndexUsage%'  contains
        N'%_IDX'         ends with  (_ is a single-char wildcard; escape with [@] or use ESCAPE)
        N'Collect_Full_Index_Usage'   exact, if you pass no wildcards

    Caller needs access to each database (HAS_DBACCESS) and permission
    to read sys.procedures there. Offline, restoring, and suspect
    databases are skipped. A single database that errors is logged
    in the second result set and does not abort the search.

    Deploy:
        USE Tools;
        GO
        -- paste and execute this script
*/
CREATE OR ALTER PROCEDURE dbo.FindProcedure
    @NamePattern            nvarchar(256),
    @IncludeSystemDatabases bit = 0,          -- 0 = skip master/model/msdb/tempdb
    @IncludeDefinition      bit = 0           -- 1 = return OBJECT_DEFINITION (can be large)
AS
BEGIN
    SET NOCOUNT ON;

    IF @NamePattern IS NULL OR LEN(LTRIM(RTRIM(@NamePattern))) = 0
        THROW 50001, N'Pass a procedure name or LIKE pattern. Example: N''%Case34%''.', 1;

    DECLARE @Pattern nvarchar(256) = LTRIM(RTRIM(@NamePattern));

    CREATE TABLE #Hits
    (
        DatabaseName     sysname        NOT NULL,
        SchemaName       sysname        NOT NULL,
        ProcedureName    sysname        NOT NULL,
        ProcedureType    nvarchar(60)   NOT NULL,
        IsEncrypted      bit            NOT NULL,
        CreateDate       datetime       NOT NULL,
        ModifyDate       datetime       NOT NULL,
        DefinitionText   nvarchar(max)  NULL
    );

    CREATE TABLE #Skipped
    (
        DatabaseName sysname       NOT NULL,
        Reason       nvarchar(400) NOT NULL
    );

    DECLARE
        @DbName sysname,
        @Sql    nvarchar(max);

    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE state = 0                              -- online
          AND user_access = 0                        -- multi-user (read-only is fine)
          AND HAS_DBACCESS(name) = 1
          AND (
                @IncludeSystemDatabases = 1
                OR database_id > 4
              )
        ORDER BY name;

    OPEN dbs;
    FETCH NEXT FROM dbs INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'
            INSERT INTO #Hits
            (
                DatabaseName, SchemaName, ProcedureName, ProcedureType,
                IsEncrypted, CreateDate, ModifyDate, DefinitionText
            )
            SELECT
                DatabaseName   = @DbName,
                SchemaName     = s.name,
                ProcedureName  = p.name,
                ProcedureType  = p.type_desc,
                IsEncrypted    = CONVERT(bit, OBJECTPROPERTY(p.object_id, ''IsEncrypted'')),
                CreateDate     = p.create_date,
                ModifyDate     = p.modify_date,
                DefinitionText = CASE
                                    WHEN @IncludeDefinition = 1
                                     AND OBJECTPROPERTY(p.object_id, ''IsEncrypted'') = 0
                                        THEN OBJECT_DEFINITION(p.object_id)
                                    ELSE NULL
                                 END
            FROM ' + QUOTENAME(@DbName) + N'.sys.procedures AS p
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
                ON s.schema_id = p.schema_id
            WHERE p.name LIKE @Pattern
              AND p.is_ms_shipped = 0;';

        BEGIN TRY
            EXEC sys.sp_executesql
                @Sql,
                N'@DbName sysname, @Pattern nvarchar(256), @IncludeDefinition bit',
                @DbName = @DbName,
                @Pattern = @Pattern,
                @IncludeDefinition = @IncludeDefinition;
        END TRY
        BEGIN CATCH
            INSERT INTO #Skipped (DatabaseName, Reason)
            VALUES (@DbName, ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM dbs INTO @DbName;
    END;

    CLOSE dbs;
    DEALLOCATE dbs;

    /* Databases we did not even try */
    INSERT INTO #Skipped (DatabaseName, Reason)
    SELECT
        d.name,
        CASE
            WHEN d.state <> 0 THEN N'Skipped: state = ' + d.state_desc
            WHEN d.user_access <> 0 THEN N'Skipped: user_access = ' + d.user_access_desc
            WHEN HAS_DBACCESS(d.name) = 0 THEN N'Skipped: caller has no access'
            ELSE N'Skipped'
        END
    FROM sys.databases AS d
    WHERE (
            @IncludeSystemDatabases = 1
            OR d.database_id > 4
          )
      AND (
            d.state <> 0
            OR d.user_access <> 0
            OR HAS_DBACCESS(d.name) = 0
          )
      AND NOT EXISTS (SELECT 1 FROM #Skipped AS s WHERE s.DatabaseName = d.name);

    SELECT
        DatabaseName,
        SchemaName,
        ProcedureName,
        ThreePartName = QUOTENAME(DatabaseName) + N'.' + QUOTENAME(SchemaName) + N'.' + QUOTENAME(ProcedureName),
        ProcedureType,
        IsEncrypted,
        CreateDate,
        ModifyDate,
        DefinitionText
    FROM #Hits
    ORDER BY DatabaseName, SchemaName, ProcedureName;

    SELECT
        DatabaseName,
        Reason
    FROM #Skipped
    ORDER BY DatabaseName;
END;
GO
