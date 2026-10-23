SET NOCOUNT ON
DECLARE @stamp varchar(20) = CONVERT(varchar(8), GETDATE(), 112) + '_' + REPLACE(CONVERT(varchar(8), GETDATE(), 108), ':', '')
DECLARE @db sysname, @path nvarchar(400)
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
  SELECT name FROM sys.databases WHERE state = 0 AND name <> 'tempdb' AND name <> 'DSHMemory' ORDER BY name
OPEN cur
FETCH NEXT FROM cur INTO @db
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @path = N'D:\backup\estate\' + @db + N'_' + @stamp + N'.bak'   -- ← 改成你自己的备份目录
  BEGIN TRY
    BACKUP DATABASE @db TO DISK = @path WITH INIT, COMPRESSION, CHECKSUM, STATS = 10, NAME = N'DSH estate backup'
    RESTORE VERIFYONLY FROM DISK = @path WITH CHECKSUM
    PRINT 'OK   ' + @db;
  END TRY
  BEGIN CATCH
    PRINT 'FAIL ' + @db + ' : ' + ERROR_MESSAGE();
    THROW;
  END CATCH
  FETCH NEXT FROM cur INTO @db
END
CLOSE cur
DEALLOCATE cur
DECLARE @cutoff datetime = DATEADD(day, -14, GETDATE())
EXEC master.sys.xp_delete_file 0, N'D:\backup\estate', N'bak', @cutoff   -- ← 改成你自己的目录
PRINT 'estate backup finished; retention 14 days applied';