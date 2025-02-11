------------------------------------------------------------------------
-- Copyright:   2016 Gianluca Hotz
-- License:     MIT License
--              Permission is hereby granted, free of charge, to any
--              person obtaining a copy of this software and associated
--              documentation files (the "Software"), to deal in the
--              Software without restriction, including without
--              limitation the rights to use, copy, modify, merge,
--              publish, distribute, sublicense, and/or sell copies of
--              the Software, and to permit persons to whom the
--              Software is furnished to do so, subject to the
--              following conditions:
--              The above copyright notice and this permission notice
--              shall be included in all copies or substantial portions
--              of the Software.
--              THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
--              ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
--              LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
--              FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
--              EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
--              FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
--              AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--              OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
--              OTHER DEALINGS IN THE SOFTWARE.
-- Credits:		
------------------------------------------------------------------------

-- CREATE DATABASE and enable Service Broker

IF EXISTS(SELECT * FROM sys.databases WHERE name = 'eventdb')
	DROP DATABASE eventdb
go
CREATE DATABASE eventdb
go
ALTER DATABASE eventdb SET ENABLE_BROKER;
go

USE eventdb

-- drop and create a table to hold event notification messages 
IF exists (select * from dbo.sysobjects where id = object_id(N'dbo.AuditLog') 
			and OBJECTPROPERTY(id, N'IsTable') = 1)
	DROP TABLE dbo.AuditLog
GO
CREATE TABLE AuditLog
	(EventType SYSNAME NULL,
	PostTime NVARCHAR(24),
	HostName NVARCHAR(100),
	LoginName NVARCHAR(100),
	EventData XML
	)
GO

--Procedure to process

CREATE PROCEDURE pr_procevent
AS
DECLARE		@messageTypeName NVARCHAR(256),
			@messageBody XML

;RECEIVE TOP(1) 
			@messageTypeName = message_type_name,
			@messageBody = message_body
		FROM dbo.NotifyQueue;

IF @@ROWCOUNT = 0
	RETURN


DECLARE @eventtype SYSNAME
DECLARE @posttime NVARCHAR(24)
DECLARE @spid NVARCHAR(6)
DECLARE @hostname NVARCHAR(100)
DECLARE @loginname NVARCHAR(100)
SET @eventtype = CONVERT(NVARCHAR(100),@messagebody.query('data(//EventType)'))
SET @posttime = CONVERT(NVARCHAR(24),@messagebody.query('data(//PostTime)'))
SET @spid = CONVERT(NVARCHAR(6),@messagebody.query('data(//SPID)'))
SET @hostname = HOST_NAME()
SET @loginname = SYSTEM_USER

INSERT INTO AuditLog(EventType,PostTime,HostName,LoginName,EventData)
VALUES(@eventtype, @posttime, @hostname, @loginname,@messageBody)
GO


-- create a queue
CREATE QUEUE NotifyQueue
WITH STATUS=ON,
ACTIVATION (PROCEDURE_NAME = pr_procevent,
			MAX_QUEUE_READERS = 5,
			EXECUTE AS OWNER);


-- create a service on the queue 
-- reference the Event Notification contract

CREATE SERVICE NotifyService
ON QUEUE NotifyQueue
(
	[http://schemas.microsoft.com/SQL/Notifications/PostEventNotification]
)
GO

--Which events exist

SELECT type_name, parent_type 
	FROM sys.event_notification_event_types
ORDER BY type_name

-- create the database event notification
CREATE EVENT NOTIFICATION Notify_Events
ON SERVER
FOR DEADLOCK_GRAPH
TO SERVICE 'NotifyService','current database' 


--check queue

SELECT * FROM NotifyQueue

--check log

SELECT * FROM AuditLog

--Query

SELECT PostTime, 
			eventdata.query('//deadlock-list') as DeadLockGraph
			FROM dbo.AuditLog
WHERE EventType = 'DEADLOCK_GRAPH'

-- Save as *.xdl and open in SSMS

-- clean up
DROP EVENT NOTIFICATION Notify_Events ON SERVER
DROP SERVICE NotifyService
DROP QUEUE NotifyQueue
DROP TABLE AuditLog
DROP PROCEDURE pr_procevent
GO
