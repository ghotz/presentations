-------------------------------------------------------------------------------
-- Core tables for the Photo Intelligence polyglot database
-- photos: system-versioned temporal for auditing and time travel queries
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- Main entity table (system-versioned temporal)
-------------------------------------------------------------------------------
CREATE TABLE dbo.photos
(
    photo_id            INT             IDENTITY(1,1),

    -- digiKam / DAM
    file_path           NVARCHAR(850)   NOT NULL,   -- limit for UNIQUE constraint
    dk_rating           TINYINT         NULL,       -- 0 = unrated, 1-5 stars (NULL if rejected)
    dk_rejected         BIT             NOT NULL DEFAULT 0,
    dk_comment          NVARCHAR(max)   NULL,
    dk_headline         NVARCHAR(max)   NULL,
    dk_title            NVARCHAR(max)   NULL,
    dk_tags             NVARCHAR(max)   NULL,       -- hierarchical paths, comma-separated
    dk_album            NVARCHAR(max)   NULL,

    -- Technical EXIF (sourced via v_dam_photos)
    shot_date           DATETIME2(0)    NULL,
    camera_make         NVARCHAR(256)   NULL,
    camera_model        NVARCHAR(512)   NULL,
    lens_model_raw      NVARCHAR(512)   NULL,
    lens_model_norm     NVARCHAR(512)   NULL,       -- REGEXP_REPLACE applied at ingestion
    focal_length        DECIMAL(6,1)    NULL,
    focal_length_35     DECIMAL(6,1)    NULL,       -- 35mm-equivalent; tells phone back cameras apart (Step 07)
    f_number            DECIMAL(4,1)    NULL,
    iso                 INT             NULL,
    exposure_time       DECIMAL(10,7)   NULL,
    flash_fired         BIT             NULL,
    gps_lat             DECIMAL(10,7)   NULL,
    gps_lon             DECIMAL(10,7)   NULL,

    -- taken from ICPT metadata (originally meant to be REST-enriched too)
    gps_city            NVARCHAR(128)   NULL,
    gps_country         NVARCHAR(128)   NULL,

    -- REST-enriched (Open-Meteo) - populated in Steps 08-09
    weather_code        SMALLINT        NULL,       -- WMO code
    weather_desc        NVARCHAR(100)   NULL,

    -- AI pipeline output
    vision_text         NVARCHAR(max)   NULL,       -- Qwen3-VL output (Steps 14-15)
    embedding_text      NVARCHAR(max)   NULL,       -- composed text for embedding (Steps 17-19)

    -- Temporal
    SysStartTime        DATETIME2       GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime          DATETIME2       GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),

    CONSTRAINT PK_photos        PRIMARY KEY (photo_id),
    CONSTRAINT UQ_photos_path   UNIQUE      (file_path)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.photos_history));
GO
