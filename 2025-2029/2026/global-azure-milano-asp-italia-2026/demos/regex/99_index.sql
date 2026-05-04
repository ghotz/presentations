USE AdventureWorks;
GO
ALTER DATABASE AdventureWorks SET COMPATIBILITY_LEVEL = 170;
GO

-- compare execution plans

-- Index Seek (dyanic seek)
SELECT	*
FROM	[Person].[EmailAddress]
WHERE	[EmailAddress] LIKE 'jenny%'
GO

-- Index Scan (full scan)
SELECT	*
FROM	[Person].[EmailAddress]
WHERE	REGEXP_LIKE([EmailAddress], '^jenny')
GO

-- of course we can use more advanced regexes to find more specific patterns, but they will all result in scans
SELECT	*
FROM	[Person].[EmailAddress]
WHERE	REGEXP_LIKE([EmailAddress], '^jenny\d{2}')
GO

-- in some cases a mixed strategy could work
SELECT	*
FROM	[Person].[EmailAddress]
WHERE	[EmailAddress] LIKE 'jenny%'
  AND	REGEXP_LIKE([EmailAddress], '^jenny\d{2}')
GO
