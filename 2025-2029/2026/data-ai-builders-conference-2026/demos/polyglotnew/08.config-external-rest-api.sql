-------------------------------------------------------------------------------
-- Configure sp_invoke_external_rest_endpoint for Open-Meteo
-- Open-Meteo is free and unauthenticated - no DATABASE SCOPED CREDENTIAL required.
-- Endpoint: https://archive-api.open-meteo.com/v1/archive
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-- Enable REST endpoint feature (required once per database)
EXECUTE sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
GO

-------------------------------------------------------------------------------
-- Smoke test: verify Open-Meteo connectivity
-- Fetches weather for Milan (45.46, 9.19) for today.
-- Expected: JSON response with "hourly.weathercode" array, http_status 200.
-------------------------------------------------------------------------------
DECLARE @today NVARCHAR(10)  = CONVERT(NVARCHAR(10), GETDATE(), 23);
DECLARE @url   NVARCHAR(max) = N'https://archive-api.open-meteo.com/v1/archive'
    + N'?latitude=45.46&longitude=9.19'
    + N'&start_date=' + @today + N'&end_date=' + @today
    + N'&hourly=weathercode&timezone=auto';
DECLARE @resp NVARCHAR(max);

EXEC sp_invoke_external_rest_endpoint
    @url      = @url,
    @method   = 'GET',
    @timeout  = 10,
    @response = @resp OUTPUT;

SELECT
    JSON_VALUE(@resp, '$.response.status.http.code')        AS http_status,
    JSON_VALUE(@resp, '$.result.hourly.weathercode[12]')    AS weathercode_noon,
    CAST(@resp AS JSON)                                     AS raw_response;
GO
