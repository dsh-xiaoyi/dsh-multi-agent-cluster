SET NOCOUNT ON
DECLARE @db sysname, @sql nvarchar(max)
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
  SELECT name FROM sys.databases WHERE state = 0 AND name <> 'tempdb' ORDER BY name
OPEN cur
FETCH NEXT FROM cur INTO @db
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @sql = N'DBCC CHECKDB(' + QUOTENAME(@db) + N') WITH NO_INFOMSGS'
  BEGIN TRY
    EXEC sp_executesql @sql
    PRINT 'CHECKDB OK   ' + @db;
  END TRY
  BEGIN CATCH
    PRINT 'CHECKDB FAIL ' + @db + ' : ' + ERROR_MESSAGE();
    THROW;
  END CATCH
  FETCH NEXT FROM cur INTO @db
END
CLOSE cur
DEALLOCATE cur
PRINT 'weekly CHECKDB finished';