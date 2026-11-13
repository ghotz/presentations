-------------------------------------------------------------------------------
-- Abstraction layer: v_dam_photos
-- Encapsulates all digiKam-specific joins via Linked Server DIGIKAM.
-- Redefining this view is the only change needed to support a different DAM
-- (e.g. Lightroom Classic - see note at bottom of file).
-------------------------------------------------------------------------------

USE PhotoIntelligence;
GO

DROP VIEW IF EXISTS dbo.v_dam_photos;
GO

CREATE VIEW dbo.v_dam_photos AS
-------------------------------------------------------------------------------
-- First get all dataset through Linked Server and cast to the correct types
-- CAST to NVARCHAR: ODBC SQLite driver returns text columns as ntext (legacy type)
-- All string columns are normalized to DATABASE_DEFAULT collation here.
-- OPENQUERY returns columns with the server collation (SQL_Latin1_General_CP1_CI_AS),
-- which conflicts with the database collation (Latin1_General_100_CI_AS_SC_UTF8).
-------------------------------------------------------------------------------
WITH
    Albums AS (
    SELECT  id, albumRoot, CAST(relativePath AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS relativePath
    FROM    OPENQUERY(DIGIKAM, 'SELECT id, albumRoot, relativePath FROM Albums')
)
,   AlbumRoots AS (
    SELECT  id
            , CAST(identifier AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS identifier
            , CAST(specificPath AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS specificPath
    FROM    OPENQUERY(DIGIKAM, 'SELECT id, identifier, specificPath FROM AlbumRoots')
)
,   Images AS (
    SELECT  id, album, CAST([name] AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS [name]
    FROM    OPENQUERY(DIGIKAM, 'SELECT id, album, name FROM Images WHERE status = 1')
)
,   ImageComments AS (
    SELECT  imageid, type, CAST(comment AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS comment
    FROM    OPENQUERY(DIGIKAM, 'SELECT imageid, type, comment FROM ImageComments WHERE type BETWEEN 1 AND 3 AND language = ''x-default''')
)
,   ImageInformation AS (
    SELECT  imageid, rating, creationDate
    FROM    OPENQUERY(DIGIKAM, 'SELECT imageid, rating, creationDate FROM ImageInformation') 
)
,   ImageMetadata AS (
    SELECT  imageid
            , CAST(make AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS make
            , CAST([model] AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS [model]
            , CAST(lens AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS lens
            , focalLength, focalLength35, aperture, [sensitivity], exposureTime, flash
    FROM    OPENQUERY(DIGIKAM, 'SELECT imageid, make, model, lens, focalLength, focalLength35, aperture, sensitivity, exposureTime, flash FROM ImageMetadata')
)
,   ImagePositions AS (
    SELECT  imageid, latitudeNumber, longitudeNumber
    FROM    OPENQUERY(DIGIKAM, 'SELECT imageid, latitudeNumber, longitudeNumber FROM ImagePositions')
)
,   ImageProperties AS (
    SELECT  imageid
            , CAST(property AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS property
            , CAST([value] AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS [value]
    FROM    OPENQUERY(DIGIKAM, 'SELECT imageid, property, value FROM ImageProperties')
)
,   ImageTags AS (
    SELECT  imageid, tagid 
    FROM    OPENQUERY(DIGIKAM, 'SELECT imageid, tagid FROM ImageTags')
)
,   Tags AS (
    SELECT  id, pid, CAST([name] AS nvarchar(max)) COLLATE DATABASE_DEFAULT AS [name]
    FROM    OPENQUERY(DIGIKAM, 'SELECT id, pid, name FROM Tags')
)
-------------------------------------------------------------------------------
-- Tags paths and tags lists
-------------------------------------------------------------------------------
,   tag_paths AS (
    -- Anchor: root-level tags
    SELECT  r.id, r.pid, r.[name] AS full_path
    FROM    tags AS r
    WHERE   r.pid = 0
    UNION ALL
    -- Recursive: child tags
    SELECT  c.id, c.pid, p.full_path + '/' + c.[name]
    FROM    tags AS c
    JOIN    tag_paths p ON p.id = c.pid
)
,   photo_tags AS (
    SELECT  it.imageid, STRING_AGG(tp.full_path, ', ')AS tag_paths
    FROM    ImageTags AS it
    JOIN    tag_paths tp ON tp.id = it.tagid
    -- Exclude digiKam workflow tags (pick labels, face scan flags, color labels).
    WHERE   tp.full_path NOT LIKE '[_]Digikam[_]%'
    GROUP   BY it.imageid
)
-------------------------------------------------------------------------------
-- Album paths
-------------------------------------------------------------------------------
,   album_paths AS (
    -- Anchor: root-level albums
    SELECT  id, albumRoot, relativePath AS full_path
    FROM    Albums
    WHERE   id = 1 AND albumRoot = 1
    UNION ALL
    -- Recursive: child albums
    SELECT  c.id, c.albumRoot, CONCAT(NULLIF(p.full_path, '/'), c.relativePath) AS full_path
    FROM    Albums AS c
    JOIN    album_paths AS p ON p.id = c.albumRoot
    WHERE   c.id <> c.albumRoot -- Exclude self-referencing root album
)
-------------------------------------------------------------------------------
-- IPTC location fields stored in digiKam's ImageProperties key-value table.
-- Pivot here so consumers see named columns, not EAV rows.
-------------------------------------------------------------------------------
,   iptc_loc AS (
    SELECT
        imageid,
        MAX(CASE WHEN property = N'city'          THEN [value] END) AS iptc_city,
        MAX(CASE WHEN property = N'country'       THEN [value] END) AS iptc_country,
        MAX(CASE WHEN property = N'countryCode'   THEN [value] END) AS iptc_country_code,
        MAX(CASE WHEN property = N'provinceState' THEN [value] END) AS iptc_state,
        MAX(CASE WHEN property = N'location'      THEN [value] END) AS iptc_sublocation
    FROM ImageProperties AS raw_props
    GROUP BY imageid
)
-------------------------------------------------------------------------------
-- Final view: join all the above together
-------------------------------------------------------------------------------
SELECT
    -- digiKam stores the album root as a volume UUID + path without drive letter
    -- ("volumeid:?uuid=..."). The UUID changes from machine to machine (desktop
    -- vs P51): matching a specific UUID would give a path without "C:" on the
    -- other machine, and 06 would delete and re-insert every photo (new IDs).
    -- Demo assumption: the album root is on C: on every machine.
    CONCAT(
        CASE WHEN ar.identifier LIKE N'volumeid:%' THEN N'C:' END
    ,   ar.specificPath, a.full_path, i.[name]
    ) AS file_path
    
    -- Technical metadata
,   im.make             AS camera_make
,   im.[model]          AS camera_model
,   im.lens             AS lens_model_raw
,   im.focalLength      AS focal_length
,   im.focalLength35    AS focal_length_35  -- 35mm-equivalent (EXIF FocalLengthIn35mmFormat)
,   im.aperture         AS f_number
,   im.[sensitivity]    AS iso
,   im.exposureTime     AS exposure_time
,   im.flash            AS flash_fired -- EXIF bitmask: bit 0 = fired
    
    -- Dates
,   inf.creationDate        AS shot_date
    
    -- Ratings (digiKam uses -1 for "rejected"; split into two columns)
,   CASE WHEN inf.rating < 0 THEN NULL ELSE inf.rating END  AS dk_rating
,   CASE WHEN inf.rating < 0 THEN 1 ELSE 0 END              AS dk_rejected
    
    -- Comments (Digikam DatabaseComment::Type: UndefinedType = 0, Comment = 1, Headline = 2, Title = 3)
,   ic1.comment AS dk_comment -- mapped to JFIF comment, EXIF UserComment, IPTC Caption, Dublin Core e Photoshop Description
,   ic2.comment AS dk_headline
,   ic3.comment AS dk_title

    -- Tags as hierarchical comma-separated paths (e.g. "People/Family/Mario")
,   pt.tag_paths            AS dk_tags

    -- Album (relative path of the directory)
,   a.full_path             AS dk_album

    -- GPS (already decimal columns in ImagePositions)
,   pos.latitudeNumber      AS gps_lat
,   pos.longitudeNumber     AS gps_lon
    
    -- IPTC location (manually tagged, primary source for Location graph node)
,   loc.iptc_city            AS iptc_city
,   loc.iptc_country         AS iptc_country
,   loc.iptc_country_code    AS iptc_country_code
,   loc.iptc_state           AS iptc_state
,   loc.iptc_sublocation     AS iptc_sublocation

FROM        Images              AS i
JOIN        album_paths         AS a   ON a.id = i.album
JOIN        AlbumRoots          AS ar  ON ar.id = a.albumRoot
LEFT JOIN   ImageComments       AS ic1  ON ic1.imageid = i.id AND ic1.[type] = 1
LEFT JOIN   ImageComments       AS ic2  ON ic2.imageid = i.id AND ic2.[type] = 2
LEFT JOIN   ImageComments       AS ic3  ON ic3.imageid = i.id AND ic3.[type] = 3
LEFT JOIN   ImageInformation    AS inf ON inf.imageid = i.id
LEFT JOIN   ImageMetadata       AS im  ON im.imageid  = i.id
LEFT JOIN   ImagePositions      AS pos ON pos.imageid  = i.id
LEFT JOIN   photo_tags          AS pt  ON pt.imageid = i.id
LEFT JOIN   iptc_loc            AS loc ON loc.imageid = i.id
GO

-------------------------------------------------------------------------------
-- Explore data
-------------------------------------------------------------------------------
SELECT * FROM dbo.v_dam_photos;
GO

-------------------------------------------------------------------------------
-- Note: switching DAM
-- To support Lightroom Classic instead of digiKam, rewrite this view joining:
--   Adobe_images, AgLibraryFile, AgHarvestedExifMetadata, AgLibraryKeyword
-- The photos table, embedding pipeline, and graph queries are DAM-agnostic.
-------------------------------------------------------------------------------
