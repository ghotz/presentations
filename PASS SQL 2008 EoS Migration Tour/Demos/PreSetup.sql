IF DB_NAME() != 'AdventureWorksDW2008R2' 
USE [AdventureWorksDW2008R2]
SET NOCOUNT ON
GO

DBCC FREEPROCCACHE;
ALTER DATABASE current SET COMPATIBILITY_LEVEL = 100
ALTER DATABASE current SET QUERY_STORE (OPERATION_MODE = READ_WRITE, DATA_FLUSH_INTERVAL_SECONDS = 60, INTERVAL_LENGTH_MINUTES = 1)
ALTER DATABASE current SET QUERY_STORE CLEAR ALL;
ALTER DATABASE current SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = OFF);
GO
