-------------------------------------------------------------------------------
-- Register qwen3-embedding as EXTERNAL MODEL
-- Prerequisites:
--   Caddy proxy running (HTTPS localhost:11435 -> Ollama localhost:11434)
--   ollama pull qwen3-embedding:0.6b
-- Registers:
--   qwen_embed           : qwen3-embedding:0.6b, 1024d, used by AI_GENERATE_EMBEDDINGS
--   dbo.fn_embed_query() : wraps a user query with the retrieval instruction
-- Idempotent: DROP IF EXISTS before CREATE
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- External Model: qwen3-embedding via Ollama native API
-- Ollama does not require authentication; CREDENTIAL is omitted.
-- LOCATION must be HTTPS - run Ollama behind a local TLS proxy on port 11435.
-- See: https://techcommunity.microsoft.com/blog/coreinfrastructureandsecurityblog/
--      ollama-on-https-for-sql-server/4458309
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'qwen_embed')
    DROP EXTERNAL MODEL qwen_embed;
GO

CREATE EXTERNAL MODEL qwen_embed
WITH (
    LOCATION   = N'https://localhost:11435/api/embed',
    API_FORMAT = 'Ollama',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = N'qwen3-embedding:0.6b'
);
GO

-------------------------------------------------------------------------------
-- Asymmetric retrieval: documents vs queries
-- Qwen3-Embedding is instruction-aware. Documents (embedding_text) are embedded
-- as-is; queries are prefixed with a one-line task instruction:
--   Instruct: <task>\nQuery:<user query>
-- Omitting the instruction on the query side costs a few points of retrieval
-- quality (per the model authors). Write the instruction in English even when
-- the query is in another language.
-------------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_embed_query (@query NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN N'Instruct: Given a photo search query, retrieve descriptions of photos that match the query'
         + NCHAR(10) + N'Query:' + @query;
END;
GO

-------------------------------------------------------------------------------
-- Smoke test: verify embedding model responds
-- Expected: a VECTOR(1024) value, non-null
-------------------------------------------------------------------------------
SELECT AI_GENERATE_EMBEDDINGS(N'smoke test' USE MODEL qwen_embed) AS sample_embedding;
GO

SELECT AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'a cat') USE MODEL qwen_embed) AS sample_query_embedding;
GO
