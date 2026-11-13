-------------------------------------------------------------------------------
-- Create database with 2025 compatibility level to use new features
-- UTF8 collation is not strictly required, but it is recommended
-------------------------------------------------------------------------------
USE master;
GO

DROP DATABASE IF EXISTS PhotoIntelligence;
GO

CREATE DATABASE PhotoIntelligence
    COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO

USE PhotoIntelligence;
GO
ALTER DATABASE PhotoIntelligence SET COMPATIBILITY_LEVEL = 170;
GO
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO