-------------------------------------------------------------------------------
-- Generic table to store API call results for photo metadata enrichment
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-- api_enrichment: raw REST responses as native JSON, with temporal audit trail
CREATE TABLE dbo.api_enrichment
(
    enrichment_id   INT             IDENTITY(1,1),
    photo_id        INT             NOT NULL REFERENCES dbo.photos(photo_id),
    api_name        NVARCHAR(50)    NOT NULL,
    request_url     NVARCHAR(MAX)   NOT NULL,
    response_raw    JSON            NOT NULL,   -- native JSON type (SQL Server 2025)
    http_status     SMALLINT        NOT NULL,
    called_at       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    SysStartTime    DATETIME2       GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime      DATETIME2       GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),
    CONSTRAINT PK_api_enrichment    PRIMARY KEY (enrichment_id),
    CONSTRAINT UQ_api_enrichment    UNIQUE      (photo_id, api_name)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.api_enrichment_history));
GO
