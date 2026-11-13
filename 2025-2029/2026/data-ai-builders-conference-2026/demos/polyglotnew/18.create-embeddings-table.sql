-------------------------------------------------------------------------------
-- Create the vector embeddings table
-- Prerequisites:
--   qwen_embed EXTERNAL MODEL registered (Step 17)
-- Creates:
--   dbo.photo_embeddings  - temporal table, VECTOR(1024)
-- The vector dimension must match the embedding model:
--   qwen3-embedding:0.6b -> 1024d
-- Changing model with a different dimension requires dropping and recreating
-- the table (99.drop-all-tables.sql, or start again from 02.database-setup.sql).
-- Note: VECTOR INDEX (DiskANN) is commented out - see note below.
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- photo_embeddings (system-versioned temporal, tracks model changes over time)
-------------------------------------------------------------------------------
IF OBJECT_ID('dbo.photo_embeddings') IS NULL
BEGIN
    CREATE TABLE dbo.photo_embeddings
    (
        photo_id     INT             NOT NULL,
        embedding    VECTOR(1024)    NOT NULL,
        model_name   NVARCHAR(100)   NOT NULL CONSTRAINT DF_photo_embeddings_model DEFAULT N'qwen3-embedding:0.6b',

        SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
        SysEndTime   DATETIME2 GENERATED ALWAYS AS ROW END   NOT NULL,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),

        CONSTRAINT PK_photo_embeddings         PRIMARY KEY (photo_id),
        CONSTRAINT FK_photo_embeddings_photos  FOREIGN KEY (photo_id) REFERENCES dbo.photos (photo_id)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.photo_embeddings_history));
END;
GO

-- VECTOR INDEX (DiskANN approximate nearest neighbor) - production scaling only.
-- Not used by the demo queries: VECTOR_DISTANCE always does an exact brute-force
-- scan and never uses a vector index (only VECTOR_SEARCH does). Brute force is
-- instant up to tens of thousands of rows.
-- In SQL Server 2025 vector indexes are a preview feature (PREVIEW_FEATURES = ON
-- in Step 02) and, while one exists, the indexed table rejects new rows: the
-- live import in 22 (new photo -> usp_build_embeddings) fails with an error.
-- The demo does not create it. To show VECTOR_SEARCH: create it after 22,
-- query, then DROP it before the next run.
--
-- IF EXISTS (SELECT 1 FROM sys.indexes
--            WHERE  name = N'idx_photo_emb'
--              AND  object_id = OBJECT_ID('dbo.photo_embeddings'))
--     DROP INDEX idx_photo_emb ON dbo.photo_embeddings;
-- GO
-- CREATE VECTOR INDEX idx_photo_emb
-- ON dbo.photo_embeddings (embedding)
-- WITH (METRIC = 'COSINE');
-- GO
