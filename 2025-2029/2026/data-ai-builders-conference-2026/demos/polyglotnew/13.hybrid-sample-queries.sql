-------------------------------------------------------------------------------
-- 13 - Sample Queries: the polyglot stack end-to-end
--
-- Sections:
--   A. Metadata & EXIF analytics           - standard relational
--   B. Temporal audit trail                - system-versioned temporal tables
--   C. JSON exploration                    - native JSON type, JSON_VALUE, OPENJSON
--   D. Graph traversal                     - MATCH syntax, multi-hop
--   E. Geography & distance                - geography type, STDistance
-------------------------------------------------------------------------------

USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- A. Metadata & EXIF analytics
-------------------------------------------------------------------------------

-- A1. Camera inventory: make/model, photo count, active date range
SELECT
    camera_make,
    camera_model,
    COUNT(*)            AS photos,
    MIN(shot_date)      AS first_shot,
    MAX(shot_date)      AS last_shot
FROM dbo.photos
WHERE camera_model IS NOT NULL
GROUP BY camera_make, camera_model
ORDER BY photos DESC;
GO

-- A2. Monthly shooting rhythm
SELECT
    YEAR(shot_date)     AS yr,
    MONTH(shot_date)    AS mo,
    COUNT(*)            AS photos
FROM dbo.photos
WHERE shot_date IS NOT NULL
GROUP BY YEAR(shot_date), MONTH(shot_date)
ORDER BY yr, mo;
GO

-- A3. Weather distribution across the archive
SELECT
    weather_code,
    weather_desc,
    COUNT(*)            AS photos
FROM dbo.photos
WHERE weather_code IS NOT NULL
GROUP BY weather_code, weather_desc
ORDER BY photos DESC;
GO

-- A4. Flash vs no-flash ratio by camera
SELECT
    camera_model,
    COUNT(*)                                            AS total,
    SUM(CAST(flash_fired AS INT))                       AS with_flash,
    CAST(ROUND(SUM(CAST(flash_fired AS int)) * 100.0 / COUNT(*), 1) AS decimal (5,2)) AS pct_flash
FROM dbo.photos
WHERE camera_model IS NOT NULL
  AND flash_fired IS NOT NULL
GROUP BY camera_model
ORDER BY total DESC;
GO

-- A5. Focal length (35mm equivalent) × aperture: photos per combination (PIVOT)
--     Rows come from the data; columns must be listed: third-stop scale + f/1.9
--     (iPhone front) + f/2.3 (TG-6: its 2 apertures shift with zoom, f/2 -> f/4.9).
--     No aperture recorded (manual lenses) -> "n/a".
SELECT  focal_35,
        [1.2], [1.4], [1.6], [1.8], [1.9], [2], [2.2], [2.3], [2.5], [2.8], [3.2], [3.5],
        [4], [4.5], [5], [5.6], [6.3], [7.1], [8], [9], [10], [11], [13], [14], [16],
        [n/a]
FROM    (
            SELECT  CAST(COALESCE(focal_length_35, focal_length) AS INT)  AS focal_35,
                    CASE WHEN f_number IS NULL OR f_number = 0 THEN 'n/a'
                         ELSE CAST(CAST(f_number AS float) AS varchar(5))
                    END AS f_stop,
                    photo_id
            FROM    dbo.photos
            WHERE   COALESCE(focal_length_35, focal_length) > 0
        ) AS src
PIVOT   (COUNT(photo_id) FOR f_stop IN (
            [1.2], [1.4], [1.6], [1.8], [1.9], [2], [2.2], [2.3], [2.5], [2.8], [3.2], [3.5],
            [4], [4.5], [5], [5.6], [6.3], [7.1], [8], [9], [10], [11], [13], [14], [16],
            [n/a])) AS pv
ORDER BY focal_35;
GO

-------------------------------------------------------------------------------
-- B. Temporal audit trail  (system-versioned temporal tables)
--
--    This pipeline writes the same row multiple times:
--      import -> lens normalization -> weather enrichment -> vision AI
--      -> embedding_text composition
--    Each UPDATE creates a new history entry. FOR SYSTEM_TIME ALL exposes the
--    full record - no application-level audit columns needed.
-------------------------------------------------------------------------------

-- B1. AI pipeline lifecycle for one photo: every version the engine ever stored,
--     annotated with which enrichment stages were complete at that moment.
--     The row "grows richer" with each pipeline step.
SELECT
    photo_id,
    SysStartTime                                        AS version_from,
    SysEndTime                                          AS version_to,
    IIF(lens_model_norm IS NOT NULL, N'yes', N'no')     AS lens_done,
    IIF(weather_code    IS NOT NULL, N'yes', N'no')     AS weather_done,
    IIF(vision_text     IS NOT NULL, N'yes', N'no')     AS vision_done,
    IIF(embedding_text  IS NOT NULL, N'yes', N'no')     AS embedding_done
FROM dbo.photos FOR SYSTEM_TIME ALL
WHERE photo_id = 1
ORDER BY SysStartTime;
GO

-- B2. Column-level diff: current version vs. the immediately preceding one.
--     Step 1 - find the SysStartTime of the most-recent history row (live row has SysEndTime = max).
--     Step 2 - serialize both snapshots to JSON, join OPENJSON on [key], return only changed pairs.
--     SysStartTime / SysEndTime are excluded: they always differ and carry no business meaning.
DECLARE @id         INT       = 1;
DECLARE @prev_start DATETIME2;

SELECT TOP 1 @prev_start = SysStartTime
FROM   dbo.photos FOR SYSTEM_TIME ALL
WHERE  photo_id   = @id
  AND  SysEndTime < '9999-12-31'       -- history rows only
ORDER BY SysStartTime DESC;            -- most-recent history version first

SELECT
    curr.[key]   AS column_name,
    curr.[value] AS current_value,
    prev.[value] AS previous_value
FROM   OPENJSON(
           (SELECT * FROM dbo.photos
            WHERE photo_id = @id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
       ) AS curr
JOIN   OPENJSON(
           (SELECT * FROM dbo.photos FOR SYSTEM_TIME AS OF @prev_start
            WHERE photo_id = @id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
       ) AS prev
  ON   curr.[key] = prev.[key]
WHERE  curr.[value] IS DISTINCT FROM prev.[value]   -- NULL-safe: catches NULL->value and value->NULL
  AND  curr.[key] NOT IN ('SysStartTime', 'SysEndTime');
GO

-- B3. Same diff as B2, but in a single query - no AS OF variable needed.
--     FOR SYSTEM_TIME AS OF requires a scalar known at run time, so it cannot
--     derive its argument from the same query's CTE. Solution: UNION ALL between
--     dbo.photos and dbo.photos_history, serialize each row to JSON via a
--     correlated subquery, then diff rn=1 (current) against rn=2 (predecessor).
DECLARE @id INT = 1;

WITH all_versions AS (
    SELECT photo_id, SysStartTime, SysEndTime,
           (SELECT p2.* FROM dbo.photos p2
            WHERE  p2.photo_id    = p1.photo_id
              AND  p2.SysStartTime = p1.SysStartTime
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) AS json_snap
    FROM   dbo.photos p1
    WHERE  p1.photo_id = @id
    UNION ALL
    SELECT photo_id, SysStartTime, SysEndTime,
           (SELECT h2.* FROM dbo.photos_history h2
            WHERE  h2.photo_id    = h1.photo_id
              AND  h2.SysStartTime = h1.SysStartTime
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) AS json_snap
    FROM   dbo.photos_history h1
    WHERE  h1.photo_id = @id
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY SysStartTime DESC) AS rn
    FROM   all_versions
)
SELECT
    c.[key]   AS column_name,
    c.[value] AS current_value,
    p.[value] AS previous_value
FROM   ranked curr
JOIN   ranked prev               ON prev.rn = curr.rn + 1
CROSS APPLY OPENJSON(curr.json_snap) AS c
CROSS APPLY OPENJSON(prev.json_snap) AS p
WHERE  curr.rn = 1
  AND  c.[key] = p.[key]
  AND  c.[value] IS DISTINCT FROM p.[value]
  AND  c.[key] NOT IN ('SysStartTime', 'SysEndTime');
GO

-- B4. Full change history for one photo: every consecutive version pair, every changed column.
--     Extends B3 by removing the curr.rn = 1 filter - all transitions are shown.
--     changed_at is the moment the new version was written by the pipeline.
DECLARE @id INT = 1;

WITH all_versions AS (
    SELECT photo_id, SysStartTime, SysEndTime,
           (SELECT p2.* FROM dbo.photos p2
            WHERE  p2.photo_id    = p1.photo_id
              AND  p2.SysStartTime = p1.SysStartTime
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) AS json_snap
    FROM   dbo.photos p1
    WHERE  p1.photo_id = @id
    UNION ALL
    SELECT photo_id, SysStartTime, SysEndTime,
           (SELECT h2.* FROM dbo.photos_history h2
            WHERE  h2.photo_id    = h1.photo_id
              AND  h2.SysStartTime = h1.SysStartTime
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) AS json_snap
    FROM   dbo.photos_history h1
    WHERE  h1.photo_id = @id
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY SysStartTime DESC) AS rn
    FROM   all_versions
)
SELECT
    curr.SysStartTime AS changed_at,
    c.[key]           AS column_name,
    c.[value]         AS new_value,
    p.[value]         AS old_value
FROM   ranked curr
JOIN   ranked prev               ON prev.rn = curr.rn + 1
CROSS APPLY OPENJSON(curr.json_snap) AS c
CROSS APPLY OPENJSON(prev.json_snap) AS p
WHERE  c.[key] = p.[key]
  AND  c.[value] IS DISTINCT FROM p.[value]
  AND  c.[key] NOT IN ('SysStartTime', 'SysEndTime')
ORDER BY curr.SysStartTime DESC, c.[key];
GO

-------------------------------------------------------------------------------
-- C. JSON exploration  (native JSON type, SQL Server 2025)
-------------------------------------------------------------------------------

-- C1. Scalar extraction: timezone, elevation and HTTP status from Open-Meteo response
--     JSON_VALUE navigates to a scalar; the column type is JSON (not NVARCHAR)
SELECT
    p.photo_id,
    p.shot_date,
    JSON_VALUE(ae.response_raw, '$.result.timezone')                AS timezone,
    JSON_VALUE(ae.response_raw, '$.result.timezone_abbreviation')   AS tz_abbr,
    JSON_VALUE(ae.response_raw, '$.result.elevation')               AS elevation_m,
    JSON_VALUE(ae.response_raw, '$.response.status.http.code')      AS http_code,
    ae.response_raw -- demo reference
FROM dbo.photos p
JOIN dbo.api_enrichment ae ON ae.photo_id = p.photo_id
                           AND ae.api_name = 'OpenMeteo';
GO

-- C2. Array expansion: all 24 hourly weather codes for a single photo
--     OPENJSON shreds the JSON array into one row per element
SELECT
    p.photo_id,
    p.shot_date,
    CAST(h.[key]   AS TINYINT)  AS hour_of_day,
    CAST(h.value   AS SMALLINT) AS wmo_code,
    ae.response_raw -- demo reference
FROM dbo.photos p
JOIN dbo.api_enrichment ae ON ae.photo_id = p.photo_id
                           AND ae.api_name = 'OpenMeteo'
CROSS APPLY OPENJSON(ae.response_raw, '$.result.hourly.weather_code') h
WHERE p.photo_id = 1
ORDER BY hour_of_day;
GO

-------------------------------------------------------------------------------
-- D. Graph traversal  (MATCH syntax, SQL Server graph tables)
-------------------------------------------------------------------------------

-- D1. Camera + Lens pairings observed in the archive and their frequency
SELECT
    Camera.make
,   Camera.[model]        AS camera
,   Lens.[model]          AS lens
,   COUNT(*)              AS photos
FROM  dbo.Photo, dbo.ShotWith, dbo.Camera, dbo.UsedLens, dbo.Lens
WHERE MATCH(Photo-(ShotWith)->Camera AND Photo-(UsedLens)->Lens)
GROUP BY Camera.make, Camera.[model], Lens.[model]
ORDER BY photos DESC;
GO

-- D2. Lenses paired with a specific camera body (via PairedWith co-occurrence edge)
--     co-occurrence edges are derived so we don't have to join through Photo;
--     this is a direct Lens -(PairedWith)-> Camera pattern
SET STATISTICS IO ON;
SELECT
    Camera.make
,   Camera.[model]        AS camera
,   Lens.[model]          AS lens
FROM dbo.Camera, dbo.PairedWith, dbo.Lens
WHERE MATCH(Camera-(PairedWith)->Lens);

SELECT
    Camera.make
,   Camera.[model]        AS camera
,   Lens.[model]          AS lens
FROM  dbo.Photo, dbo.ShotWith, dbo.Camera, dbo.UsedLens, dbo.Lens
WHERE MATCH(Photo-(ShotWith)->Camera AND Photo-(UsedLens)->Lens)
GROUP BY Camera.make, Camera.[model], Lens.[model];

SET STATISTICS IO OFF;
GO

-- D3. Lens × Weather: which conditions does each lens most often appear in?
--     Two-hop path: Lens <-(UsedLens)- Photo -(HadWeather)-> WeatherCondition
SELECT
    Lens.[model]                    AS lens,
    WeatherCondition.[description]  AS weather,
    COUNT(*)                        AS photos
FROM  dbo.Photo, dbo.UsedLens, dbo.Lens, dbo.HadWeather, dbo.WeatherCondition
WHERE MATCH(Lens<-(UsedLens)-Photo-(HadWeather)->WeatherCondition)
GROUP BY Lens.[model], WeatherCondition.[description]
ORDER BY Lens.[model], photos DESC;
GO

-- D3 (JOIN equivalent): same result without MATCH - joins on graph pseudo-columns.
--     $node_id identifies each node row; $from_id/$to_id on edges point to node IDs.
--     Pseudo-columns use the bare $name syntax (no square brackets) - SQL Server treats
--     them as reserved graph keywords; brackets would quote them as normal identifiers
--     (column not found). Available in JOIN predicates from SQL Server 2019 onward.
--     Compared to MATCH, traversal direction is implicit in the predicate - no arrows.
SELECT
    Lens.[model]                    AS lens,
    WeatherCondition.[description]  AS weather,
    COUNT(*)                        AS photos
FROM  dbo.Photo
JOIN  dbo.UsedLens         ON UsedLens.$from_id   = Photo.$node_id
JOIN  dbo.Lens             ON UsedLens.$to_id     = Lens.$node_id
JOIN  dbo.HadWeather       ON HadWeather.$from_id = Photo.$node_id
JOIN  dbo.WeatherCondition ON HadWeather.$to_id   = WeatherCondition.$node_id
GROUP BY Lens.[model], WeatherCondition.[description]
ORDER BY Lens.[model], photos DESC;
GO

-- D4. Camera pairs that have shot in the same city - "bowtie" pattern.
--     Two independent paths converge on the same Location node:
--       cam1 <-(sw1)- p1 -(ta1)-> Location <-(ta2)- p2 -(sw2)-> cam2
--     cam1.camera_id < cam2.camera_id keeps only the upper triangle (no self-pairs, no duplicates).
SELECT
    cam1.[model]          AS camera_a,
    cam2.[model]          AS camera_b,
    loc.city,
    loc.country,
    COUNT(*)            AS shared_photos
FROM dbo.Camera AS cam1,  dbo.ShotWith AS sw1,  dbo.Photo AS p1,
     dbo.TakenAt  AS ta1, dbo.[Location] AS loc,
     dbo.TakenAt  AS ta2, dbo.Photo AS p2,
     dbo.ShotWith AS sw2, dbo.Camera AS cam2
WHERE MATCH(cam1<-(sw1)-p1-(ta1)->loc AND p2-(ta2)->loc AND p2-(sw2)->cam2)
  AND cam1.camera_id < cam2.camera_id
GROUP BY cam1.[model], cam2.[model], loc.city, loc.country
HAVING COUNT(*) > 1
ORDER BY shared_photos DESC;
GO

-------------------------------------------------------------------------------
-- E. Geography & distance  (geography type - available since SQL Server 2008)
--    All photos with GPS coords can be queried with great-circle distances.
--    SRID (Spatial Reference ID) 4326 = WGS 84 (World Geodetic System 1984)
--    used by GPS, Google Maps, OpenStreetMap etc.
-------------------------------------------------------------------------------

-- E1. Photos nearest to a reference point (great-circle distance via STDistance)
--     Change lat/lon to any place of interest
DECLARE @ref geography = geography::Point(45.8833, 8.5667, 4326);  -- Leggiuno (VA)

SELECT TOP 10
    p.photo_id,
    p.file_path,
    p.shot_date,
    ROUND(
        @ref.STDistance(geography::Point(p.gps_lat, p.gps_lon, 4326)) / 1000.0,
    2)                  AS km_from_ref
FROM dbo.photos p
WHERE p.gps_lat IS NOT NULL
  AND p.gps_lon IS NOT NULL
ORDER BY km_from_ref;
GO

-- E2. Closest pairs: which two geotagged photos were taken nearest each other?
SELECT TOP 20
    p1.photo_id         AS photo_a,
    p2.photo_id         AS photo_b,
    CAST(
        geography::Point(p1.gps_lat, p1.gps_lon, 4326).STDistance(
        geography::Point(p2.gps_lat, p2.gps_lon, 4326)) / 1000.0
    AS DECIMAL(10,3))   AS km
FROM dbo.photos p1
JOIN dbo.photos p2 ON p2.photo_id > p1.photo_id  -- upper triangle only
WHERE p1.gps_lat IS NOT NULL
  AND p2.gps_lat IS NOT NULL
ORDER BY km;
GO

-- E3. SSMS Spatial Results: Province of Varese boundary + photo GPS points
--     Province polygon: OpenStreetMap via Nominatim, simplified with geometry.Reduce(0.005)
--     In SSMS: switch to "Spatial results" tab, select 'shape' as spatial column,
--     'colore' as colour column (provincia = one colour, foto = another)
--     E3 and E4 run as one batch: both use @prov.
DECLARE @prov geometry = geometry::STGeomFromText('POLYGON ((8.552246 45.7880388, 8.5945506 45.7297714, 8.6428681 45.7231552, 8.6534342 45.7139709, 8.6409018 45.6765341, 8.6812011 45.6764016, 8.6698345 45.6614235, 8.6881849 45.6369928, 8.6786452 45.633627, 8.6656575 45.6428786, 8.658939 45.6377463, 8.6630877 45.6220341, 8.682133 45.6203425, 8.703148 45.600057, 8.7044406 45.5883142, 8.6933449 45.5777808, 8.7055279 45.569154, 8.7068786 45.5583143, 8.7225318 45.5737857, 8.729915 45.5610299, 8.74963 45.5644435, 8.7421188 45.5716488, 8.7665048 45.5760588, 8.7692865 45.5873156, 8.7823186 45.586594, 8.7860682 45.6026856, 8.815678 45.597666, 8.8136622 45.5864513, 8.8338494 45.583125, 8.8365172 45.5681376, 8.8624619 45.5740681, 8.8746755 45.5805824, 8.8677779 45.5920709, 8.8720282 45.5976158, 8.9153552 45.6071276, 8.936523 45.6235147, 8.9292245 45.6355431, 8.9396758 45.6434829, 8.9587597 45.6338135, 8.9543294 45.6257832, 8.965756 45.6303202, 8.9786229 45.6148321, 8.9674404 45.6085316, 8.9741433 45.5866711, 8.9837601 45.5910516, 9.0027574 45.5737967, 9.0241889 45.5882713, 9.046271 45.5770514, 9.064241 45.5816374, 9.0662784 45.5973036, 9.050576 45.6304751, 9.0625967 45.6380788, 9.0571822 45.6460115, 9.0396863 45.6393854, 9.0270876 45.6492901, 8.9810885 45.6457517, 8.9874614 45.6766779, 8.9791654 45.6798278, 8.9689701 45.6659027, 8.9333437 45.6518515, 8.9208299 45.6715255, 8.8949062 45.6824676, 8.9171641 45.6881657, 8.9326722 45.6969467, 8.9311722 45.7065497, 8.9514147 45.7128336, 8.95194 45.7297462, 8.9387579 45.7364724, 8.94271 45.7447101, 8.9296905 45.746972, 8.9184443 45.7668369, 8.9061359 45.7715989, 8.9008713 45.7850517, 8.9091378 45.793152, 8.8965882 45.8113871, 8.9069271 45.8147155, 8.914226 45.8422289, 8.9453151 45.8670214, 8.9337815 45.8703345, 8.9215352 45.8957726, 8.9241547 45.905663, 8.8933121 45.9311849, 8.8986014 45.9462586, 8.8936571 45.958982, 8.8682985 45.9606214, 8.8313229 45.988016, 8.7858834 45.9890766, 8.7930889 46.0081018, 8.8354651 46.0437922, 8.8284874 46.0465254, 8.8441833 46.0485063, 8.8545039 46.0615864, 8.8520348 46.0756306, 8.8060228 46.1013511, 8.7830083 46.0940992, 8.7602819 46.1014911, 8.7423429 46.1223112, 8.7078501 46.0908138, 8.7054756 46.0819336, 8.7287635 46.0292321, 8.7264298 46.0179672, 8.5706383 45.9000335, 8.5952008 45.833614, 8.5816471 45.8136582, 8.5582768 45.8035638, 8.552246 45.7880388))', 0);

SELECT
    N'Provincia di Varese'  AS nome,
    N'provincia'            AS colore,
    @prov                   AS shape
UNION ALL
SELECT
    CAST(p.photo_id AS NVARCHAR(10))          AS nome,
    N'foto'                                   AS colore,
    geometry::Point(p.gps_lon, p.gps_lat, 0).STBuffer(0.004) AS shape
FROM dbo.photos p
WHERE p.gps_lat BETWEEN 45.5 AND 46.2
  AND p.gps_lon BETWEEN  8.5 AND  9.2;

-- E4. Same map exported as an SVG image, built in T-SQL
--     - province: WKT -> SVG path with 3 REPLACE ("POLYGON ((x y, x y" -> "M x y L x y")
--     - photos: one <circle> per point with STRING_AGG
--     - SVG's Y axis points down: scale(1,-1) flips it, so the viewBox uses -max_lat
--     - CAST AS XML: in SSMS click the cell, then File -> Save As... "map.svg"
--     Planar degrees like E3 (SRID 0): the map looks slightly stretched east-west.
DECLARE @prov geometry = geometry::STGeomFromText('POLYGON ((8.552246 45.7880388, 8.5945506 45.7297714, 8.6428681 45.7231552, 8.6534342 45.7139709, 8.6409018 45.6765341, 8.6812011 45.6764016, 8.6698345 45.6614235, 8.6881849 45.6369928, 8.6786452 45.633627, 8.6656575 45.6428786, 8.658939 45.6377463, 8.6630877 45.6220341, 8.682133 45.6203425, 8.703148 45.600057, 8.7044406 45.5883142, 8.6933449 45.5777808, 8.7055279 45.569154, 8.7068786 45.5583143, 8.7225318 45.5737857, 8.729915 45.5610299, 8.74963 45.5644435, 8.7421188 45.5716488, 8.7665048 45.5760588, 8.7692865 45.5873156, 8.7823186 45.586594, 8.7860682 45.6026856, 8.815678 45.597666, 8.8136622 45.5864513, 8.8338494 45.583125, 8.8365172 45.5681376, 8.8624619 45.5740681, 8.8746755 45.5805824, 8.8677779 45.5920709, 8.8720282 45.5976158, 8.9153552 45.6071276, 8.936523 45.6235147, 8.9292245 45.6355431, 8.9396758 45.6434829, 8.9587597 45.6338135, 8.9543294 45.6257832, 8.965756 45.6303202, 8.9786229 45.6148321, 8.9674404 45.6085316, 8.9741433 45.5866711, 8.9837601 45.5910516, 9.0027574 45.5737967, 9.0241889 45.5882713, 9.046271 45.5770514, 9.064241 45.5816374, 9.0662784 45.5973036, 9.050576 45.6304751, 9.0625967 45.6380788, 9.0571822 45.6460115, 9.0396863 45.6393854, 9.0270876 45.6492901, 8.9810885 45.6457517, 8.9874614 45.6766779, 8.9791654 45.6798278, 8.9689701 45.6659027, 8.9333437 45.6518515, 8.9208299 45.6715255, 8.8949062 45.6824676, 8.9171641 45.6881657, 8.9326722 45.6969467, 8.9311722 45.7065497, 8.9514147 45.7128336, 8.95194 45.7297462, 8.9387579 45.7364724, 8.94271 45.7447101, 8.9296905 45.746972, 8.9184443 45.7668369, 8.9061359 45.7715989, 8.9008713 45.7850517, 8.9091378 45.793152, 8.8965882 45.8113871, 8.9069271 45.8147155, 8.914226 45.8422289, 8.9453151 45.8670214, 8.9337815 45.8703345, 8.9215352 45.8957726, 8.9241547 45.905663, 8.8933121 45.9311849, 8.8986014 45.9462586, 8.8936571 45.958982, 8.8682985 45.9606214, 8.8313229 45.988016, 8.7858834 45.9890766, 8.7930889 46.0081018, 8.8354651 46.0437922, 8.8284874 46.0465254, 8.8441833 46.0485063, 8.8545039 46.0615864, 8.8520348 46.0756306, 8.8060228 46.1013511, 8.7830083 46.0940992, 8.7602819 46.1014911, 8.7423429 46.1223112, 8.7078501 46.0908138, 8.7054756 46.0819336, 8.7287635 46.0292321, 8.7264298 46.0179672, 8.5706383 45.9000335, 8.5952008 45.833614, 8.5816471 45.8136582, 8.5582768 45.8035638, 8.552246 45.7880388))', 0);
DECLARE @env geometry = @prov.STEnvelope();          -- bounding box: point 1 = min, point 3 = max
DECLARE @min_x float = @env.STPointN(1).STX, @min_y float = @env.STPointN(1).STY,
        @max_x float = @env.STPointN(3).STX, @max_y float = @env.STPointN(3).STY;

SELECT CAST(CONCAT(
    N'<svg xmlns="http://www.w3.org/2000/svg" width="800" height="800" viewBox="',
        @min_x, N' ', -@max_y, N' ', @max_x - @min_x, N' ', @max_y - @min_y, N'">',
    N'<g transform="scale(1,-1)">',
    N'<path fill="#dde8f0" stroke="#3a6a8a" stroke-width="2" vector-effect="non-scaling-stroke" d="M',
        REPLACE(REPLACE(REPLACE(@prov.STAsText(), N'POLYGON ((', N''), N'))', N''), N', ', N' L '),
        N' Z"/>',
    (SELECT STRING_AGG(CONCAT(N'<circle cx="', p.gps_lon, N'" cy="', p.gps_lat,
                              N'" r="0.006" fill="#d33"/>'), N'')
     FROM   dbo.photos p
     WHERE  p.gps_lat BETWEEN 45.5 AND 46.2
       AND  p.gps_lon BETWEEN  8.5 AND  9.2),
    N'</g></svg>') AS XML) AS svg;
GO
