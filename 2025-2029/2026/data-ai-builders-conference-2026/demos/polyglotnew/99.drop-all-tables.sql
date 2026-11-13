-------------------------------------------------------------------------------
-- Drop edge tables (reference nodes - must be dropped first)
-------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.PairedWith;
DROP TABLE IF EXISTS dbo.HadWeather;
DROP TABLE IF EXISTS dbo.TakenAt;
DROP TABLE IF EXISTS dbo.UsedLens;
DROP TABLE IF EXISTS dbo.ShotWith;
GO

-- Drop graph node tables
DROP TABLE IF EXISTS dbo.Photo;
DROP TABLE IF EXISTS dbo.Camera;
DROP TABLE IF EXISTS dbo.Lens;
DROP TABLE IF EXISTS dbo.[Location];
DROP TABLE IF EXISTS dbo.WeatherCondition;
GO

-- Drop tables created by other steps that have foreign key relationships
IF OBJECT_ID('dbo.api_enrichment') IS NOT NULL
BEGIN
    IF OBJECTPROPERTY(OBJECT_ID('dbo.api_enrichment'), 'TableTemporalType') = 2
        ALTER TABLE dbo.api_enrichment SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE dbo.api_enrichment;
END
DROP TABLE IF EXISTS dbo.api_enrichment_history;
GO

IF OBJECT_ID('dbo.photo_embeddings') IS NOT NULL
BEGIN
    IF OBJECTPROPERTY(OBJECT_ID('dbo.photo_embeddings'), 'TableTemporalType') = 2
        ALTER TABLE dbo.photo_embeddings SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE dbo.photo_embeddings;
END
DROP TABLE IF EXISTS dbo.photo_embeddings_history;
GO

-- Drop main table (temporal: must turn off versioning first)
IF OBJECT_ID('dbo.photos') IS NOT NULL
BEGIN
    IF OBJECTPROPERTY(OBJECT_ID('dbo.photos'), 'TableTemporalType') = 2
        ALTER TABLE dbo.photos SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE dbo.photos;
END
DROP TABLE IF EXISTS dbo.photos_history;
GO