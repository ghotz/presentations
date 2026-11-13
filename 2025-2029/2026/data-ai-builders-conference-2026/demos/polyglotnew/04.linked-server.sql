-------------------------------------------------------------------------------
-- Linked Server: DIGIKAM (SQLite via ODBC)
-- Prerequisite: SQLite ODBC driver (Christian Werner) installed on the server
-- IMPORTANT: always use a COPY of digikam4.db - never the live file
-------------------------------------------------------------------------------

USE PhotoIntelligence;
GO

-- Drop linked server if it already exists (droplogins removes associated logins)
IF EXISTS (SELECT 1 FROM sys.servers WHERE name = N'DIGIKAM')
    EXEC sp_dropserver @server = N'DIGIKAM', @droplogins = 'droplogins';
GO

EXEC sp_addlinkedserver
    @server     = N'DIGIKAM',
    @srvproduct = N'SQLite',
    @provider   = N'MSDASQL',
    @datasrc    = N'',
    @provstr    = N'Driver={SQLite3 ODBC Driver};Database=C:\Users\gianl\repos\personal\T-SQL-Temp\polyglotnew\digikam\digikam4.db';
GO

EXEC sp_addlinkedsrvlogin
    @rmtsrvname  = N'DIGIKAM',
    @useself     = 'FALSE',
    @locallogin  = NULL,
    @rmtuser     = NULL,
    @rmtpassword = NULL;
GO
