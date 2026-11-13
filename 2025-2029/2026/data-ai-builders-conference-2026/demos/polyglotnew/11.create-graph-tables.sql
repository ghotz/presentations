-------------------------------------------------------------------------------
-- Graph tables for the Photo Intelligence polyglot database (not temporal)
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Create Graph Node Tables
-------------------------------------------------------------------------------
-- Thin graph proxy - mirrors photos(photo_id)
CREATE TABLE dbo.Photo
(
    photo_id        INT             NOT NULL,
    file_path       NVARCHAR(850)   NOT NULL,       -- redundant for graph node, but useful for demos
    CONSTRAINT PK_Photo             PRIMARY KEY (photo_id),
    CONSTRAINT FK_Photo_photos      FOREIGN KEY (photo_id) REFERENCES dbo.photos (photo_id)
) AS NODE;
GO

CREATE TABLE dbo.Camera
(
    camera_id       INT             IDENTITY(1,1),
    make            NVARCHAR(256)   NULL,
    [model]         NVARCHAR(512)   NULL,
    CONSTRAINT PK_Camera    PRIMARY KEY (camera_id),
    CONSTRAINT UQ_Camera    UNIQUE      (make, [model])
) AS NODE;
GO

CREATE TABLE dbo.Lens
(
    lens_id         INT             IDENTITY(1,1),
    [model]         NVARCHAR(512)   NOT NULL,
    focal_min       DECIMAL(6,1)    NULL,
    focal_max       DECIMAL(6,1)    NULL,
    CONSTRAINT PK_Lens  PRIMARY KEY (lens_id),
    CONSTRAINT UQ_Lens  UNIQUE      ([model])
) AS NODE;
GO

CREATE TABLE dbo.Location
(
    location_id     INT             IDENTITY(1,1),
    city            NVARCHAR(128)   NOT NULL,
    country         NVARCHAR(128)   NOT NULL,
    CONSTRAINT PK_Location  PRIMARY KEY (location_id),
    CONSTRAINT UQ_Location  UNIQUE      (city, country)
) AS NODE;
GO

CREATE TABLE dbo.WeatherCondition
(
    wc_id           INT             IDENTITY(1,1),
    code            SMALLINT        NOT NULL,
    [description]   NVARCHAR(100)   NOT NULL,
    CONSTRAINT PK_WeatherCondition  PRIMARY KEY (wc_id),
    CONSTRAINT UQ_WeatherCondition  UNIQUE      (code)
) AS NODE;
GO

-------------------------------------------------------------------------------
-- Create Graph Edge Tables
-------------------------------------------------------------------------------
CREATE TABLE dbo.ShotWith   AS EDGE;    -- Photo -> Camera
GO
CREATE TABLE dbo.UsedLens   AS EDGE;    -- Photo -> Lens
GO
CREATE TABLE dbo.TakenAt    AS EDGE;    -- Photo -> Location
GO
CREATE TABLE dbo.HadWeather AS EDGE;    -- Photo -> WeatherCondition
GO
CREATE TABLE dbo.PairedWith AS EDGE;    -- Camera <-> Lens, co-occurrence
GO
