-------------------------------------------------------------------------------
-- Incremental load: photos + Camera nodes + Photo graph nodes
-- Source: dbo.v_dam_photos (Linked Server DIGIKAM)
-- Safe to run repeatedly - idempotent MERGE logic
--
-- Scope of this step:
--   photos        -> INSERT new, UPDATE changed DAM metadata
--                   gps_city/country populated from IPTC when available
--   dbo.Camera    -> INSERT new distinct camera bodies
--   dbo.Photo     -> INSERT new graph proxy nodes
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- Migration for databases created before focal_length_35 was added to 03
-- (no-op on a fresh database). Adding a nullable column to a system-versioned
-- table also adds it to the history table.
-------------------------------------------------------------------------------
IF COL_LENGTH('dbo.photos', 'focal_length_35') IS NULL
    ALTER TABLE dbo.photos ADD focal_length_35 DECIMAL(6,1) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_load_photos
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @changes TABLE (action NVARCHAR(10) NOT NULL);
    DECLARE @inserted INT, @updated INT, @deleted INT;

    ---------------------------------------------------------------------------
    -- 1. Merge photos
    ---------------------------------------------------------------------------
    MERGE dbo.photos AS tgt
    USING (
        SELECT
            file_path,
            shot_date,
            camera_make,
            camera_model,
            lens_model_raw,
            focal_length,
            focal_length_35,
            f_number,
            iso,
            exposure_time,
            -- flash is an EXIF bitmask integer: bit 0 = fired
            CASE WHEN TRY_CAST(flash_fired AS INT) & 1 = 1 THEN 1 ELSE 0 END AS flash_fired,
            gps_lat,
            gps_lon,
            iptc_city,
            iptc_country,
            dk_rating,
            dk_rejected,
            dk_comment, 
            dk_headline,
            dk_title,
            dk_tags,
            dk_album
        FROM dbo.v_dam_photos
        WHERE file_path IS NOT NULL
    ) AS src ON tgt.file_path = src.file_path

    -- New photo: full insert; gps_city/country seeded from IPTC when available
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            file_path,
            shot_date,   camera_make,    camera_model,  lens_model_raw,
            focal_length, focal_length_35, f_number,    iso,           exposure_time,  flash_fired,
            gps_lat,      gps_lon,       gps_city,      gps_country,
            dk_rating,    dk_rejected,   dk_comment,      dk_headline,  dk_title,   dk_tags,        dk_album
        )
        VALUES (
            src.file_path,
            src.shot_date,   src.camera_make,   src.camera_model,  src.lens_model_raw,
            src.focal_length, src.focal_length_35, src.f_number, src.iso,         src.exposure_time,  src.flash_fired,
            src.gps_lat,      src.gps_lon,      src.iptc_city,     src.iptc_country,
            src.dk_rating,    src.dk_rejected,  dk_comment,      dk_headline,  dk_title,    src.dk_tags,        src.dk_album
        )

    -- Existing photo: update DAM metadata + IPTC location (both can be edited in digiKam)
    -- IPTC update uses ISNULL so a newly-removed tag never wipes a prior OpenCage result.
    -- IS DISTINCT FROM handles NULLs correctly without sentinel values (SS2022+)
    WHEN MATCHED AND (
           tgt.dk_rating    IS DISTINCT FROM src.dk_rating
        OR tgt.dk_rejected  IS DISTINCT FROM src.dk_rejected
        OR tgt.dk_title     IS DISTINCT FROM src.dk_title
        OR tgt.dk_comment   IS DISTINCT FROM src.dk_comment 
        OR tgt.dk_headline  IS DISTINCT FROM src.dk_headline
        OR tgt.dk_title     IS DISTINCT FROM src.dk_title
        OR tgt.dk_tags      IS DISTINCT FROM src.dk_tags
        OR tgt.dk_album     IS DISTINCT FROM src.dk_album
        OR (src.iptc_city    IS NOT NULL AND tgt.gps_city    IS DISTINCT FROM src.iptc_city)
        OR (src.iptc_country IS NOT NULL AND tgt.gps_country IS DISTINCT FROM src.iptc_country)
        -- backfill of a column added later (used by 07 to tell phone back cameras apart)
        OR tgt.focal_length_35 IS DISTINCT FROM src.focal_length_35
    ) THEN
        UPDATE SET
            dk_rating    = src.dk_rating,
            dk_rejected  = src.dk_rejected,
            dk_comment   = src.dk_comment,
            dk_headline  = src.dk_headline,
            dk_title     = src.dk_title,
            dk_tags      = src.dk_tags,
            dk_album     = src.dk_album,
            gps_city     = ISNULL(src.iptc_city,    tgt.gps_city),
            gps_country  = ISNULL(src.iptc_country, tgt.gps_country),
            focal_length_35 = src.focal_length_35

    OUTPUT $action INTO @changes (action);

    SELECT
        @inserted = SUM(CASE WHEN action = 'INSERT' THEN 1 ELSE 0 END),
        @updated  = SUM(CASE WHEN action = 'UPDATE' THEN 1 ELSE 0 END)
    FROM @changes;

    ---------------------------------------------------------------------------
    -- 2. Remove photos deleted from digiKam (must clean dependents first)
    --    Tables created in later steps may not exist yet - use dynamic SQL
    ---------------------------------------------------------------------------
    CREATE TABLE #to_delete (photo_id INT NOT NULL PRIMARY KEY);

    INSERT INTO #to_delete (photo_id)
    SELECT p.photo_id
    FROM   dbo.photos p
    WHERE  NOT EXISTS (
        SELECT 1 FROM dbo.v_dam_photos s WHERE s.file_path = p.file_path
    );

    IF EXISTS (SELECT 1 FROM #to_delete)
    BEGIN
        -- Graph edges (step 11+): all originate from Photo nodes, check Photo first
        IF OBJECT_ID('dbo.Photo', 'U') IS NOT NULL
        BEGIN
            IF OBJECT_ID('dbo.ShotWith',   'U') IS NOT NULL
                EXEC sp_executesql N'DELETE FROM dbo.ShotWith   WHERE $from_id IN (SELECT $node_id FROM dbo.Photo WHERE photo_id IN (SELECT photo_id FROM #to_delete))';
            IF OBJECT_ID('dbo.UsedLens',   'U') IS NOT NULL
                EXEC sp_executesql N'DELETE FROM dbo.UsedLens   WHERE $from_id IN (SELECT $node_id FROM dbo.Photo WHERE photo_id IN (SELECT photo_id FROM #to_delete))';
            IF OBJECT_ID('dbo.TakenAt',    'U') IS NOT NULL
                EXEC sp_executesql N'DELETE FROM dbo.TakenAt    WHERE $from_id IN (SELECT $node_id FROM dbo.Photo WHERE photo_id IN (SELECT photo_id FROM #to_delete))';
            IF OBJECT_ID('dbo.HadWeather', 'U') IS NOT NULL
                EXEC sp_executesql N'DELETE FROM dbo.HadWeather WHERE $from_id IN (SELECT $node_id FROM dbo.Photo WHERE photo_id IN (SELECT photo_id FROM #to_delete))';
            EXEC sp_executesql N'DELETE FROM dbo.Photo WHERE photo_id IN (SELECT photo_id FROM #to_delete)';
        END;

        -- Optional enrichment tables (steps 09+ and 18+)
        IF OBJECT_ID('dbo.api_enrichment',   'U') IS NOT NULL
            EXEC sp_executesql N'DELETE FROM dbo.api_enrichment   WHERE photo_id IN (SELECT photo_id FROM #to_delete)';
        IF OBJECT_ID('dbo.photo_embeddings', 'U') IS NOT NULL
            EXEC sp_executesql N'DELETE FROM dbo.photo_embeddings WHERE photo_id IN (SELECT photo_id FROM #to_delete)';

        -- Main table last (temporal - deleted rows go to history)
        DELETE FROM dbo.photos WHERE photo_id IN (SELECT photo_id FROM #to_delete);
        SET @deleted = @@ROWCOUNT;
    END;
    ELSE
        SET @deleted = 0;

    DROP TABLE #to_delete;

    RAISERROR('photos - inserted: %d, updated: %d, deleted: %d', 0, 1, @inserted, @updated, @deleted) WITH NOWAIT;
END;
GO

-------------------------------------------------------------------------------
-- Run to import new photos
-------------------------------------------------------------------------------
EXEC dbo.usp_load_photos;
GO

-------------------------------------------------------------------------------
-- check imported data
-------------------------------------------------------------------------------
SELECT * FROM dbo.photos;
GO
