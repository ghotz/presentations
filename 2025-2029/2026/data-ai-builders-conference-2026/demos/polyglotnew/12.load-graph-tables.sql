-------------------------------------------------------------------------------
-- Incremental load: all graph nodes + all edges
-- Prerequisites:
--   1. dbo.usp_load_photos must have run (Camera and Photo nodes populated there)
--   2. Weather enrichment must have run (weather_code/weather_desc populated)
-- Safe to run repeatedly - idempotent
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

CREATE OR ALTER PROCEDURE dbo.usp_load_graph_tables
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @rc INT;

    ---------------------------------------------------------------------------
    -- 1 Photo graph nodes: mirror of photos table
    ---------------------------------------------------------------------------
    INSERT INTO dbo.Photo (photo_id, file_path)
    SELECT p.photo_id, p.file_path
    FROM dbo.photos p
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.Photo n WHERE n.photo_id = p.photo_id
    );

    RAISERROR('Photo nodes synced', 0, 1) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 2. Camera nodes: insert new distinct camera bodies
    ---------------------------------------------------------------------------
    INSERT INTO dbo.Camera (make, model)
    SELECT DISTINCT camera_make, camera_model
    FROM dbo.photos
    WHERE camera_model IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.Camera c
            WHERE c.make  = photos.camera_make
              AND c.model = photos.camera_model
      );

    RAISERROR('Camera nodes synced', 0, 1) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 3a. Lens cleanup: lens_model_norm can change for existing photos
    --     (07 recomputes all rows). Remove edges pointing to a lens name the
    --     photo no longer has, then Lens nodes no photo refers to any more.
    --     Edges first: no CONNECTION constraints, so nothing would stop a node
    --     delete from leaving dangling edges.
    ---------------------------------------------------------------------------
    DELETE FROM dbo.UsedLens
    WHERE EXISTS (
        SELECT 1
        FROM   dbo.Photo  n
        JOIN   dbo.photos p ON p.photo_id = n.photo_id
        CROSS JOIN dbo.Lens l
        WHERE  n.$node_id = dbo.UsedLens.$from_id
          AND  l.$node_id = dbo.UsedLens.$to_id
          AND  p.lens_model_norm IS DISTINCT FROM l.[model]
    );

    SET @rc = @@ROWCOUNT;
    RAISERROR('UsedLens edges - stale removed: %d', 0, 1, @rc) WITH NOWAIT;

    DELETE FROM dbo.PairedWith
    WHERE NOT EXISTS (
        SELECT 1
        FROM   dbo.photos p
        JOIN   dbo.Camera c ON c.make  = p.camera_make
                           AND c.model = p.camera_model
        JOIN   dbo.Lens   l ON l.model = p.lens_model_norm
        WHERE  c.$node_id = dbo.PairedWith.$from_id
          AND  l.$node_id = dbo.PairedWith.$to_id
    );

    SET @rc = @@ROWCOUNT;
    RAISERROR('PairedWith edges - stale removed: %d', 0, 1, @rc) WITH NOWAIT;

    DELETE FROM dbo.Lens
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.photos p WHERE p.lens_model_norm = dbo.Lens.[model]
    );

    SET @rc = @@ROWCOUNT;
    RAISERROR('Lens nodes - orphans removed: %d', 0, 1, @rc) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 3b. Lens nodes: distinct normalised models; derive focal range from photos
    --     UPDATE handles the case where a new photo extends the observed range
    ---------------------------------------------------------------------------
    DECLARE @lens_changes TABLE (action NVARCHAR(10) NOT NULL);
    DECLARE @lens_ins INT, @lens_upd INT;

    MERGE dbo.Lens AS tgt
    USING (
        SELECT
            lens_model_norm             AS [model],
            MIN(focal_length)           AS focal_min,
            MAX(focal_length)           AS focal_max
        FROM dbo.photos
        WHERE lens_model_norm IS NOT NULL
        GROUP BY lens_model_norm
    ) AS src ON tgt.[model] = src.[model]
    WHEN NOT MATCHED BY TARGET THEN
        INSERT ([model], focal_min, focal_max)
        VALUES (src.[model], src.focal_min, src.focal_max)
    WHEN MATCHED AND (
           tgt.focal_min IS DISTINCT FROM src.focal_min
        OR tgt.focal_max IS DISTINCT FROM src.focal_max
    ) THEN
        UPDATE SET
            focal_min = src.focal_min,
            focal_max = src.focal_max
    OUTPUT $action INTO @lens_changes (action);

    SELECT
        @lens_ins = SUM(CASE WHEN action = 'INSERT' THEN 1 ELSE 0 END),
        @lens_upd = SUM(CASE WHEN action = 'UPDATE' THEN 1 ELSE 0 END)
    FROM @lens_changes;

    RAISERROR('Lens nodes - inserted: %d, updated: %d', 0, 1, @lens_ins, @lens_upd) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 4. Location nodes: distinct city / country pairs from photos with location data
    ---------------------------------------------------------------------------
    INSERT INTO dbo.Location (city, country)
    SELECT DISTINCT gps_city, gps_country
    FROM dbo.photos
    WHERE gps_city    IS NOT NULL
      AND gps_country IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.Location loc
            WHERE loc.city    = photos.gps_city
              AND loc.country = photos.gps_country
      );

    SET @rc = @@ROWCOUNT;
    RAISERROR('Location nodes - inserted: %d', 0, 1, @rc) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 5. WeatherCondition nodes: distinct WMO codes from weather-enriched photos
    ---------------------------------------------------------------------------
    INSERT INTO dbo.WeatherCondition (code, description)
    SELECT DISTINCT weather_code, weather_desc
    FROM dbo.photos
    WHERE weather_code IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.WeatherCondition wc
            WHERE wc.code = photos.weather_code
      );

    SET @rc = @@ROWCOUNT;
    RAISERROR('WeatherCondition nodes - inserted: %d', 0, 1, @rc) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 6. ShotWith edges: Photo -> Camera
    --    Each photo has at most one camera body
    ---------------------------------------------------------------------------
    INSERT INTO dbo.ShotWith ($from_id, $to_id)
    SELECT n.$node_id, c.$node_id
    FROM dbo.Photo       n
    JOIN dbo.photos      p ON p.photo_id = n.photo_id
    JOIN dbo.Camera      c ON c.make     = p.camera_make
                          AND c.model    = p.camera_model
    WHERE p.camera_model IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.ShotWith e
            WHERE e.$from_id = n.$node_id
              AND e.$to_id   = c.$node_id
      );

    SET @rc = @@ROWCOUNT;
    RAISERROR('ShotWith edges - inserted: %d', 0, 1, @rc) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 7. UsedLens edges: Photo -> Lens
    --    Each photo has at most one lens (after normalisation)
    ---------------------------------------------------------------------------
    INSERT INTO dbo.UsedLens ($from_id, $to_id)
    SELECT n.$node_id, l.$node_id
    FROM dbo.Photo       n
    JOIN dbo.photos      p ON p.photo_id = n.photo_id
    JOIN dbo.Lens        l ON l.model    = p.lens_model_norm
    WHERE p.lens_model_norm IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.UsedLens e
            WHERE e.$from_id = n.$node_id
              AND e.$to_id   = l.$node_id
      );

    SET @rc = @@ROWCOUNT;
    RAISERROR('UsedLens edges - inserted: %d', 0, 1, @rc) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 8. TakenAt edges: Photo -> Location
    --    Only photos that have location data (gps_city populated)
    ---------------------------------------------------------------------------
    INSERT INTO dbo.TakenAt ($from_id, $to_id)
    SELECT n.$node_id, loc.$node_id
    FROM dbo.Photo       n
    JOIN dbo.photos      p   ON p.photo_id   = n.photo_id
    JOIN dbo.Location    loc ON loc.city      = p.gps_city
                            AND loc.country   = p.gps_country
    WHERE p.gps_city IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.TakenAt e
            WHERE e.$from_id = n.$node_id
              AND e.$to_id   = loc.$node_id
      );

    SET @rc = @@ROWCOUNT;
    RAISERROR('TakenAt edges - inserted: %d', 0, 1, @rc) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 9. HadWeather edges: Photo -> WeatherCondition
    --    Only photos that have been weather-enriched (weather_code populated)
    ---------------------------------------------------------------------------
    INSERT INTO dbo.HadWeather ($from_id, $to_id)
    SELECT n.$node_id, wc.$node_id
    FROM dbo.Photo              n
    JOIN dbo.photos             p  ON p.photo_id = n.photo_id
    JOIN dbo.WeatherCondition   wc ON wc.code    = p.weather_code
    WHERE p.weather_code IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.HadWeather e
            WHERE e.$from_id = n.$node_id
              AND e.$to_id   = wc.$node_id
      );

    SET @rc = @@ROWCOUNT;
    RAISERROR('HadWeather edges - inserted: %d', 0, 1, @rc) WITH NOWAIT;

    ---------------------------------------------------------------------------
    -- 10. PairedWith edges: Camera <-> Lens co-occurrence
    --     One directed edge per distinct (camera, lens) pair observed in photos
    ---------------------------------------------------------------------------
    INSERT INTO dbo.PairedWith ($from_id, $to_id)
    SELECT DISTINCT c.$node_id, l.$node_id
    FROM dbo.photos  p
    JOIN dbo.Camera  c ON c.make  = p.camera_make
                      AND c.model = p.camera_model
    JOIN dbo.Lens    l ON l.model = p.lens_model_norm
    WHERE p.camera_model    IS NOT NULL
      AND p.lens_model_norm IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM dbo.PairedWith e
            WHERE e.$from_id = c.$node_id
              AND e.$to_id   = l.$node_id
      );

    SET @rc = @@ROWCOUNT;
    RAISERROR('PairedWith edges - inserted: %d', 0, 1, @rc) WITH NOWAIT;

END;
GO

-------------------------------------------------------------------------------
-- Run to update graph tables
-------------------------------------------------------------------------------
EXEC dbo.usp_load_graph_tables;
GO
