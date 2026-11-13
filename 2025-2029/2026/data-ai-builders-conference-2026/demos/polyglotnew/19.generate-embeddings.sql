-------------------------------------------------------------------------------
-- Build embedding_text and generate vector embeddings
-- Prerequisites:
--   vision_text populated via usp_recognize_images
--   qwen_embed EXTERNAL MODEL registered (Step 17)
--   dbo.photo_embeddings created (Step 18)
-- Documents are embedded WITHOUT the query instruction (asymmetric retrieval:
-- only queries go through dbo.fn_embed_query, see Step 17).
-- Creates:
--   dbo.usp_build_embeddings
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- usp_build_embeddings
-- Step 1: compose embedding_text from all semantic fields.
-- Step 2: call AI_GENERATE_EMBEDDINGS (USE MODEL qwen_embed) and store.
-- Idempotent: skips photos already processed unless @force = 1.
-- Set-based embedding insert - no cursor needed (much lighter than vision).
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_build_embeddings
    @force           BIT = 0,    -- 1 = rebuild embedding_text and regenerate all embeddings
    @filter_photo_id INT = NULL  -- when set, process only this specific photo
AS
BEGIN
    SET NOCOUNT ON;

    -- Step 1: compose embedding_text for photos that have vision_text.
    -- CONCAT_WS(CHAR(10), ...) skips NULLs automatically.
    -- Each line uses NULLIF or CASE to suppress empty/irrelevant values.
    UPDATE dbo.photos
    SET embedding_text = CONCAT_WS(CHAR(10),

        -- Equipment
        NULLIF(CONCAT('Camera: ', camera_make, ' ', camera_model), 'Camera:  '),
        NULLIF(CONCAT('Lens: ',   lens_model_norm),                 'Lens: '),

        -- Time
        NULLIF(CONCAT('Date: ',   FORMAT(shot_date, 'yyyy-MM-dd')), 'Date: '),
        NULLIF(CONCAT('Time: ',   FORMAT(shot_date, 'HH:mm')),      'Time: '),

        -- Flash: only meaningful when it fired; silence "No Flash" noise
        CASE WHEN flash_fired = 1 THEN N'Flash: Fired' END,

        -- Location (IPTC-tagged in digiKam)
        NULLIF(CONCAT('Location: ', gps_city, ', ', gps_country),   'Location: , '),

        -- Weather (Open-Meteo enrichment)
        NULLIF(CONCAT('Weather: ',  weather_desc),                   'Weather: '),

        -- DAM metadata (internal digiKam tags filtered in v_dam_photos for future loads;
        -- existing rows in photos.dk_tags may still contain _Digikam_Internal_Tags_ entries)
        NULLIF(CONCAT('Tags: ',     dk_tags),                        'Tags: '),
        -- Rating: exclude 0 (unrated); NULL means rejected (already dk_rejected = 1)
        CASE WHEN dk_rating > 0 THEN CONCAT('Rating: ', dk_rating, ' stars') END,
        NULLIF(CONCAT('Comment: ',  dk_comment),                     'Comment: '),
        NULLIF(CONCAT('Headline: ', dk_headline),                    'Headline: '),
        NULLIF(CONCAT('Title: ',    dk_title),                       'Title: '),
        NULLIF(CONCAT('Album: ',    dk_album),                       'Album: '),

        -- AI vision description (independent scene analysis, Step 15)
        NULLIF(CONCAT('Scene: ',    vision_text),                    'Scene: ')
    )
    WHERE vision_text IS NOT NULL
      AND (@force = 1 OR embedding_text IS NULL)
      AND (@filter_photo_id IS NULL OR photo_id = @filter_photo_id);

    DECLARE @text_updated INT = @@ROWCOUNT;

    -- Step 2: if forcing, remove existing embeddings so they can be regenerated.
    -- DELETE on a temporal table moves rows to history with correct timestamps.
    IF @force = 1
        DELETE FROM dbo.photo_embeddings
        WHERE photo_id IN (
            SELECT photo_id FROM dbo.photos
            WHERE  embedding_text IS NOT NULL
              AND  (@filter_photo_id IS NULL OR photo_id = @filter_photo_id)
        );

    -- Step 3: generate embeddings and insert (set-based).
    -- AI_GENERATE_EMBEDDINGS calls qwen3-embedding via the Caddy TLS proxy.
    INSERT INTO dbo.photo_embeddings (photo_id, embedding)
    SELECT
        photo_id,
        AI_GENERATE_EMBEDDINGS(embedding_text USE MODEL qwen_embed)
    FROM dbo.photos
    WHERE embedding_text IS NOT NULL
      AND photo_id NOT IN (SELECT photo_id FROM dbo.photo_embeddings)
      AND (@filter_photo_id IS NULL OR photo_id = @filter_photo_id);

    DECLARE @emb_inserted INT = @@ROWCOUNT;

    SELECT @text_updated AS embedding_text_updated,
           @emb_inserted AS embeddings_generated;
END;
GO

-------------------------------------------------------------------------------
-- Smoke test: run on the first photo without an embedding only
-------------------------------------------------------------------------------
DECLARE @photo_id INT;

SELECT TOP 1 @photo_id = p.photo_id
FROM       dbo.photos          p
LEFT JOIN  dbo.photo_embeddings pe ON pe.photo_id = p.photo_id
WHERE      p.vision_text IS NOT NULL
  AND      pe.photo_id IS NULL;

IF @photo_id IS NULL
BEGIN
    PRINT 'No unprocessed photos found - use EXEC dbo.usp_build_embeddings @force = 1 to reprocess.';
END
ELSE
BEGIN
    PRINT CONCAT(N'Smoke test on photo_id ', @photo_id);
    EXEC dbo.usp_build_embeddings @filter_photo_id = @photo_id;

    SELECT
        p.photo_id,
        LEFT(p.embedding_text, 400)                        AS embedding_text_preview,
        LEFT(CAST(pe.embedding AS NVARCHAR(MAX)), 100)     AS embedding_head,
        pe.model_name
    FROM       dbo.photos          p
    JOIN       dbo.photo_embeddings pe ON pe.photo_id = p.photo_id
    WHERE      p.photo_id = @photo_id;
END;
GO

-------------------------------------------------------------------------------
-- Process all unprocessed photos (or all if @force = 1)
-------------------------------------------------------------------------------
EXEC dbo.usp_build_embeddings @force = 0;
GO
