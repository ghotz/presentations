-------------------------------------------------------------------------------
-- Weather enrichment via Open-Meteo historical archive API
--
-- Prerequisite: 06.load-photos.sql must have run (gps_lat/lon populated)
-- Safe to run repeatedly - idempotent: skips photos already enriched
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- Procedure: call Open-Meteo for each photo with GPS but no weather yet
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_get_weather
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @photo_id   INT,
        @lat        DECIMAL(10,7),
        @lon        DECIMAL(10,7),
        @shot_date  DATETIME2,
        @url        NVARCHAR(MAX),
        @response   NVARCHAR(MAX),
        @ret        INT,
        @hour       INT,
        @wcode      SMALLINT,
        @wdesc      NVARCHAR(100),
        @enriched   INT = 0,
        @errors     INT = 0;

    DECLARE cur CURSOR FAST_FORWARD FOR
        SELECT photo_id, gps_lat, gps_lon, shot_date
        FROM   dbo.photos
        WHERE  gps_lat      IS NOT NULL
          AND  gps_lon      IS NOT NULL
          AND  shot_date    IS NOT NULL
          AND  weather_code IS NULL;       -- idempotent: skip already enriched

    OPEN cur;
    FETCH NEXT FROM cur INTO @photo_id, @lat, @lon, @shot_date;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -----------------------------------------------------------------------
        -- Build Open-Meteo archive URL
        -- Returns 24 hourly weather_code values for the requested day
        -----------------------------------------------------------------------
        SET @url = CONCAT(
            'https://archive-api.open-meteo.com/v1/archive',
            '?latitude=',   @lat,
            '&longitude=',  @lon,
            '&start_date=', FORMAT(@shot_date, 'yyyy-MM-dd'),
            '&end_date=',   FORMAT(@shot_date, 'yyyy-MM-dd'),
            '&hourly=weather_code',
            '&timezone=auto'
        );

        -----------------------------------------------------------------------
        -- Outbound REST call - SQL Server 2025 native, no OA procedure
        -- sp_invoke_external_rest_endpoint wraps the response in:
        --   { "response": { "status": {...}, "headers": {...} }, "result": {...} }
        -- The API body is under $.result; HTTP status under $.response.status.http.code
        -- Return code @ret: 0 = call succeeded, non-zero = SP/network failure
        -----------------------------------------------------------------------
        EXEC @ret = sp_invoke_external_rest_endpoint
            @url      = @url,
            @method   = 'GET',
            @timeout  = 30,
            @response = @response OUTPUT;

        -- @ret is the SP return code (0 = call succeeded), not the HTTP status
        -- HTTP status is embedded in the response at $.response.status.http.code
        IF @ret = 0
        BEGIN
            -------------------------------------------------------------------
            -- JSON_VALUE: extract scalar at a dynamic path
            -- Response body is under $.result (not $.response.body)
            -- Index into the hourly array at the shot hour -> WMO weather code
            -------------------------------------------------------------------
            SET @hour  = DATEPART(HOUR, @shot_date);
            SET @wcode = TRY_CAST(
                JSON_VALUE(@response,
                    CONCAT('$.result.hourly.weather_code[', @hour, ']'))
                AS SMALLINT
            );

            SET @wdesc = CASE @wcode
                WHEN 0  THEN 'Clear sky'
                WHEN 1  THEN 'Mainly clear'
                WHEN 2  THEN 'Partly cloudy'
                WHEN 3  THEN 'Overcast'
                WHEN 45 THEN 'Fog'
                WHEN 48 THEN 'Rime fog'
                WHEN 51 THEN 'Light drizzle'
                WHEN 53 THEN 'Moderate drizzle'
                WHEN 55 THEN 'Dense drizzle'
                WHEN 56 THEN 'Light freezing drizzle'
                WHEN 57 THEN 'Heavy freezing drizzle'
                WHEN 61 THEN 'Slight rain'
                WHEN 63 THEN 'Moderate rain'
                WHEN 65 THEN 'Heavy rain'
                WHEN 66 THEN 'Light freezing rain'
                WHEN 67 THEN 'Heavy freezing rain'
                WHEN 71 THEN 'Slight snow'
                WHEN 73 THEN 'Moderate snow'
                WHEN 75 THEN 'Heavy snow'
                WHEN 77 THEN 'Snow grains'
                WHEN 80 THEN 'Slight showers'
                WHEN 81 THEN 'Moderate showers'
                WHEN 82 THEN 'Violent showers'
                WHEN 85 THEN 'Slight snow showers'
                WHEN 86 THEN 'Heavy snow showers'
                WHEN 95 THEN 'Thunderstorm'
                WHEN 96 THEN 'Thunderstorm with hail'
                WHEN 99 THEN 'Thunderstorm with heavy hail'
                ELSE 'Unknown'
            END;

            -------------------------------------------------------------------
            -- CAST AS JSON: store raw response as native JSON type
            -- UPDATE on an existing row triggers temporal history automatically
            -------------------------------------------------------------------
            IF EXISTS (SELECT 1 FROM dbo.api_enrichment
                       WHERE photo_id = @photo_id AND api_name = 'OpenMeteo')
                UPDATE dbo.api_enrichment
                SET    response_raw = CAST(@response AS JSON),
                       request_url  = @url,
                       http_status  = @ret,
                       called_at    = SYSUTCDATETIME()
                WHERE  photo_id = @photo_id AND api_name = 'OpenMeteo';
            ELSE
                INSERT INTO dbo.api_enrichment
                    (photo_id, api_name, request_url, response_raw, http_status)
                VALUES
                    (@photo_id, 'OpenMeteo', @url, CAST(@response AS JSON), @ret);

            -- Propagate derived fields into photos
            UPDATE dbo.photos
            SET    weather_code = @wcode,
                   weather_desc = @wdesc
            WHERE  photo_id = @photo_id;

            SET @enriched += 1;
            RAISERROR('photo_id %d: %s (%d)', 0, 1, @photo_id, @wdesc, @wcode) WITH NOWAIT;
        END
        ELSE
        BEGIN
            SET @errors += 1;
            RAISERROR('photo_id %d: sp_invoke failed (ret=%d)', 0, 1, @photo_id, @ret) WITH NOWAIT;
            RAISERROR('%s', 0, 1, @response) WITH NOWAIT;
        END

        WAITFOR DELAY '00:00:01';
        FETCH NEXT FROM cur INTO @photo_id, @lat, @lon, @shot_date;
    END

    CLOSE cur;
    DEALLOCATE cur;

    RAISERROR('Enrichment complete - enriched: %d, errors: %d', 0, 1, @enriched, @errors)
        WITH NOWAIT;
END;
GO

-------------------------------------------------------------------------------
-- Execute
-------------------------------------------------------------------------------
--UPDATE dbo.photos SET weather_code = NULL, weather_desc = NULL;  -- reset for testing
--GO
EXEC dbo.usp_get_weather;
GO

-------------------------------------------------------------------------------
-- Verify: raw JSON response + derived fields side by side
-------------------------------------------------------------------------------
SELECT
    p.photo_id
,   p.shot_date
,   p.weather_code
,   p.weather_desc
    -- JSON_VALUE: scalar extraction from native JSON column
,   JSON_VALUE(ae.response_raw, '$.result.timezone')                        AS timezone
,   JSON_VALUE(ae.response_raw, '$.response.status.http.code')              AS http_code
    -- JSON_QUERY: extract the full hourly array as a JSON fragment
,   JSON_QUERY(ae.response_raw, '$.result.hourly.weather_code')             AS weather_code_array
,   p.file_path
    -- Raw data for debugging
,   ae.response_raw
FROM        dbo.photos          p
JOIN        dbo.api_enrichment  ae ON ae.photo_id = p.photo_id AND ae.api_name  = 'OpenMeteo'
WHERE       p.weather_code IS NOT NULL
ORDER BY    p.shot_date;
GO
