-------------------------------------------------------------------------------
-- Recognize images via Ollama vision model (qwen3-vl:8b-instruct)
-- Reads each image from the filesystem, encodes it to Base64 (SQL Server 2025
-- BASE64_ENCODE()), and sends it to Ollama /api/generate via the Caddy TLS
-- proxy (https://localhost:11435).
--
-- FILE PERMISSIONS: OPENROWSET(BULK ...) reads the image files with the
-- SQL Server service account, not with your Windows user. Grant it read access
-- to the photo folders (photos and test, on every machine), e.g. for the named
-- instance SQL2025 from an elevated prompt:
--   icacls "C:\Users\gianl\repos\personal\T-SQL-Temp\polyglotnew\photos" /grant "NT Service\MSSQL$SQL2025:(OI)(CI)RX" /T
--   icacls "C:\Users\gianl\repos\personal\T-SQL-Temp\polyglotnew\test"   /grant "NT Service\MSSQL$SQL2025:(OI)(CI)RX" /T
-- The service account also needs to traverse the parent folders (under
-- C:\Users\<user> it usually does not by default). Without access the batch
-- prints "Cannot bulk load ... Access is denied" for each photo.
--
-- Use Instruct tags (qwen3-vl:*-instruct): the untagged qwen3-vl:8b / :4b are
-- the Thinking variants, which always reason and ignore "think":false.
-- The description is read from $.result.response; any reasoning would end up
-- in $.result.thinking. "think":false is kept as a safeguard.
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-- OPENROWSET(BULK ...) requires Ad Hoc Distributed Queries (advanced option)
EXECUTE sp_configure 'show advanced options', 1;
RECONFIGURE WITH OVERRIDE;
EXECUTE sp_configure 'Ad Hoc Distributed Queries', 1;
RECONFIGURE WITH OVERRIDE;
GO

-------------------------------------------------------------------------------
-- usp_recognize_images
-- Idempotent: skips photos that already have vision_text unless @force = 1.
-- Processes photos one at a time; errors on single photos are caught and logged
-- without stopping the batch.
-------------------------------------------------------------------------------
-- @vision_model: default qwen3-vl:8b-instruct, on both machines.
-- On the demo laptop (Quadro M2200, 4 GB VRAM) the 8B model runs mostly on CPU:
-- ~43 s warm, ~74 s cold, under the 180 s @timeout below (230 s is the maximum
-- allowed by sp_invoke_external_rest_endpoint). qwen3-vl:4b-instruct (~22 s warm)
-- is the fallback: since only photos with vision_text NULL are processed, a
-- second call with @vision_model = N'qwen3-vl:4b-instruct' retries just the
-- photos the 8B model failed on (see 22.hybrid-search-fail-good.sql).
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_recognize_images
    @force            BIT            = 0,                -- 1 = reprocess photos that already have vision_text
    @filter_photo_id  INT            = NULL,             -- when set, process only this specific photo
    @vision_model     NVARCHAR(100)  = N'qwen3-vl:8b-instruct' -- Ollama vision model tag
AS
BEGIN
    SET NOCOUNT ON;

    -- Enable REST calls for this session
    EXECUTE sp_configure 'external rest endpoint enabled', 1;
    RECONFIGURE WITH OVERRIDE;

    DECLARE @photo_id       INT;
    DECLARE @file_path      NVARCHAR(500);
    DECLARE @resolved_path  NVARCHAR(500);
    DECLARE @img_blob       VARBINARY(MAX);
    DECLARE @img_b64        NVARCHAR(MAX);
    DECLARE @payload        NVARCHAR(MAX);
    DECLARE @resp           NVARCHAR(MAX);
    DECLARE @vision_text    NVARCHAR(MAX);
    DECLARE @rows_done      INT = 0;
    DECLARE @rows_err       INT = 0;
    DECLARE @sql            NVARCHAR(MAX);

    DECLARE @prompt NVARCHAR(MAX) =
        N'Describe this photo for semantic search indexing. '
      + N'Be specific: name animal species/breeds, vehicle makes, plant species, '
      + N'architectural styles, and recognizable landmarks or named locations only if clearly identifiable. '
      + N'Include: main subjects (named specifically), activity or event, scene type, '
      + N'lighting, mood, dominant colors, season or weather if determinable. '
      + N'Max 150 words. Plain text, no markdown.';

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT photo_id, file_path
        FROM   dbo.photos
        WHERE  file_path IS NOT NULL
          AND  (@filter_photo_id IS NULL OR photo_id = @filter_photo_id)
          AND  (@force = 1 OR vision_text IS NULL);

    OPEN cur;
    FETCH NEXT FROM cur INTO @photo_id, @file_path;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            -- Read image bytes from filesystem.
            -- OPENROWSET BULK does not accept variables, so dynamic SQL is required.
            -- Single quotes in the path are escaped by doubling them.
            SET @sql =
                N'SELECT @b = BulkColumn'
              + N' FROM OPENROWSET(BULK N''' + REPLACE(@file_path, N'''', N'''''') + N''', SINGLE_BLOB) AS x';

            EXEC sp_executesql @sql, N'@b VARBINARY(MAX) OUTPUT', @b = @img_blob OUTPUT;

            -- BASE64_ENCODE() is new in SQL Server 2025 - no XML trick needed.
            SET @img_b64 = BASE64_ENCODE(@img_blob);

            -- Build the Ollama /api/generate payload.
            -- STRING_ESCAPE(..., 'json') handles quotes, newlines, and other
            -- special characters inside the prompt string.
            SET @payload =
                N'{"model":"' + STRING_ESCAPE(@vision_model, 'json') + N'","stream":false,"think":false'
              + N',"prompt":"'  + STRING_ESCAPE(@prompt, 'json') + N'"'
              + N',"images":["' + @img_b64 + N'"]}';

            EXEC sp_invoke_external_rest_endpoint
                @url      = N'https://localhost:11435/api/generate',
                @method   = 'POST',
                @payload  = @payload,
                @timeout  = 180,
                @response = @resp OUTPUT;

            SET @vision_text = JSON_VALUE(@resp, '$.result.response');

            IF @vision_text IS NOT NULL
            BEGIN
                UPDATE dbo.photos
                SET    vision_text = @vision_text
                WHERE  photo_id    = @photo_id;

                SET @rows_done += 1;
            END
            ELSE
                PRINT CONCAT(N'WARNING photo_id ', @photo_id,
                             N': empty response - ', LEFT(@resp, 500));

        END TRY
        BEGIN CATCH
            SET @rows_err += 1;
            PRINT CONCAT(N'ERROR photo_id ', @photo_id, N': ', ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM cur INTO @photo_id, @file_path;
    END;

    CLOSE cur;
    DEALLOCATE cur;

    SELECT @rows_done AS processed, @rows_err AS errors;
END;
GO

-------------------------------------------------------------------------------
-- Smoke test: run on the first unprocessed photo only
-------------------------------------------------------------------------------
DECLARE @photo_id  INT;
DECLARE @file_path NVARCHAR(500);

SELECT TOP 1 @photo_id = photo_id, @file_path = file_path
FROM dbo.photos
WHERE vision_text IS NULL AND file_path IS NOT NULL;

IF @photo_id IS NULL
BEGIN
    PRINT 'No unprocessed photos found - use EXEC dbo.usp_recognize_images @force = 1 to reprocess.';
END
ELSE
BEGIN
    PRINT CONCAT(N'Smoke test on photo_id ', @photo_id, N': ', @file_path);
    EXEC dbo.usp_recognize_images @filter_photo_id = @photo_id;

    SELECT photo_id, LEFT(vision_text, 300) AS vision_preview
    FROM   dbo.photos
    WHERE  photo_id = @photo_id;
END;
GO

-------------------------------------------------------------------------------
-- process all unprocessed photos (or all photos if @force = 1)
-------------------------------------------------------------------------------
EXEC dbo.usp_recognize_images 0, NULL;  -- process only photos without vision_text
GO

-------------------------------------------------------------------------------
-- What was populated: one description per photo
-- vision_text NULL = not processed yet (or failed: run the EXEC again).
-- words: approximate count, to check the "Max 150 words" of the prompt.
-- -> 27/27 described, 90-115 words each: the limit is respected with margin.
--
-- NOTE - invented places: photos 4, 7, 9 are "Lake Como, Italy" and photo 3
--   shows the "Castello di Vignola". All wrong: they are lakes in the province
--   of Varese, and the castle is the Rocca di Angera. The prompt says "only if
--   clearly identifiable", yet the model names the most famous lake nearby.
--   The GPS knows where the photo was taken; vision_text says where the model
--   THINKS it was (see the query below). Same lesson as photo 25 in 22.
-------------------------------------------------------------------------------
SELECT  photo_id,
        LEN(vision_text) - LEN(REPLACE(vision_text, N' ', N'')) + 1   AS words,
        CAST(LEFT(vision_text, 200) AS nvarchar(200))                 AS vision_preview,
        file_path
FROM    dbo.photos
ORDER BY photo_id;
GO

-- Where the model thinks the photo was taken vs. where the GPS says it was
SELECT  photo_id, gps_city,
        CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_preview
FROM    dbo.photos
WHERE   vision_text LIKE N'%Como%'
   OR   vision_text LIKE N'%Castello%';
GO