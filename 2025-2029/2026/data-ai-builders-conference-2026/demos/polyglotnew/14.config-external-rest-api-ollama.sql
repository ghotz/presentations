-------------------------------------------------------------------------------
-- Configure sp_invoke_external_rest_endpoint for Ollama
-- Ollama has no authentication - no DATABASE SCOPED CREDENTIAL required.
-- All calls go through the Caddy TLS proxy (Step 01):
--   https://localhost:11435  ->  http://localhost:11434 (Ollama)
-- The Caddy root CA must be in LocalMachine\Root (handled by 01.install-dependencies.bat).
-- Endpoints used:
--   /api/generate  - vision model (qwen3-vl:8b-instruct), called via sp_invoke_external_rest_endpoint
-- Use the Instruct variant (qwen3-vl:8b-instruct): the untagged qwen3-vl:8b is
-- the Thinking variant, which always reasons and ignores "think":false
-- (check $.result.thinking and eval_count in raw_response). "think":false is
-- kept as a safeguard for hybrid models.
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-- Enable REST endpoint feature (required once per database)
EXECUTE sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
GO

-- For authenticated APIs (Bearer token, API key, Basic auth) add:
--
--   CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong_password>';
--
--   CREATE DATABASE SCOPED CREDENTIAL <CredentialName>
--     WITH IDENTITY = 'HTTPEndpointHeaders',
--          SECRET = '{"Authorization":"Bearer <API_KEY>"}';
--
-- Then pass @credential = <CredentialName> to sp_invoke_external_rest_endpoint.

-------------------------------------------------------------------------------
-- Smoke test: verify Caddy proxy -> Ollama connectivity
-- Expected: JSON response with "response" field containing a short answer.
-- stream:false required - sp_invoke_external_rest_endpoint does not support streaming.
-------------------------------------------------------------------------------
DECLARE @url  NVARCHAR(MAX) = N'https://localhost:11435/api/generate';
--DECLARE @body NVARCHAR(MAX) = N'{"model":"qwen3-vl:8b-instruct","prompt":"Reply with one word: hello.","stream":false,"think":false}';
DECLARE @body NVARCHAR(MAX) = N'{"model":"qwen3-vl:4b-instruct","prompt":"Reply with one word: hello.","stream":false,"think":false}';
DECLARE @resp NVARCHAR(MAX);

EXEC sp_invoke_external_rest_endpoint
    @url      = @url,
    @method   = 'POST',
    @payload  = @body,
    @timeout  = 60,
    @response = @resp OUTPUT;

SELECT
    JSON_VALUE(@resp, '$.result.response')  AS ollama_reply,
    JSON_VALUE(@resp, '$.result.model')     AS model,
    CAST(@resp AS JSON)                     AS raw_response;
GO
