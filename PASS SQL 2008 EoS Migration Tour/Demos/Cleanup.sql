IF DB_NAME() != 'AdventureWorksDW2008R2' 
USE AdventureWorksDW2008R2
SET NOCOUNT ON
GO

EXECUTE sp_query_store_flush_db;
GO

DBCC FREEPROCCACHE;
ALTER DATABASE current SET COMPATIBILITY_LEVEL = 100
GO
