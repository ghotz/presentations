-------------------------------------------------------------------------------
-- Full-text search on AI-generated vision descriptions
-- Creates a full-text catalog + index on photos.vision_text only.
-- FTS enables natural-language queries on visual content that was previously
-- unsearchable without manual tagging.
-- Prerequisites: vision_text populated via usp_recognize_images.
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- Full-text catalog
-------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ft_photos')
    CREATE FULLTEXT CATALOG ft_photos AS DEFAULT;
GO

-------------------------------------------------------------------------------
-- Full-text index on vision_text
-- KEY INDEX: primary key on photo_id
-- CHANGE_TRACKING AUTO: index stays in sync as vision_text is updated
-------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.fulltext_indexes
    WHERE  object_id = OBJECT_ID('dbo.photos'))
    CREATE FULLTEXT INDEX ON dbo.photos (vision_text LANGUAGE 'English')
    KEY INDEX PK_photos
    ON ft_photos
    WITH CHANGE_TRACKING AUTO;
GO

-------------------------------------------------------------------------------
-- Smoke test: verify the index is active
-------------------------------------------------------------------------------
SELECT
    OBJECT_NAME(fi.object_id)       AS table_name,
    fc.name                         AS catalog_name,
    fi.change_tracking_state_desc,
    fi.has_crawl_completed
FROM sys.fulltext_indexes   fi
JOIN sys.fulltext_catalogs  fc ON fc.fulltext_catalog_id = fi.fulltext_catalog_id
WHERE fi.object_id = OBJECT_ID('dbo.photos');
GO

-------------------------------------------------------------------------------
-- What is inside the index: the most frequent words in vision_text
-- (stopwords like "the", "a" are already excluded by the index).
-- Population is asynchronous: if empty, wait for has_crawl_completed = 1.
-- The searches (CONTAINS, FREETEXT, FREETEXTTABLE) are shown in 20-22.
--
-- -> The top words describe the PROMPT of 15, not the photos: mood, scene (28),
--   colors, dominant (27), landmarks (21), vehicles (20), animals (18),
--   identifiable (17), named (15). The model answers every point of the prompt,
--   also to say what is missing: "No identifiable landmarks, vehicles or animals".
--   This is the trap shown in 22: FTS finds "animals" in the negative phrases.
-------------------------------------------------------------------------------
SELECT  TOP 20
        display_term,
        document_count                  -- photos containing the word
FROM    sys.dm_fts_index_keywords(DB_ID(), OBJECT_ID('dbo.photos'))
WHERE   display_term <> N'END OF FILE'
  AND   display_term NOT LIKE N'%[0-9]%'
ORDER BY document_count DESC;
GO