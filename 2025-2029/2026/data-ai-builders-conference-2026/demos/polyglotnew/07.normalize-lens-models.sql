-------------------------------------------------------------------------------
-- Lens model normalisation using SQL Server 2025 native REGEXP functions
-- Prerequisite: dbo.usp_load_photos must have run first (lens_model_raw populated)
--
-- Goal: normalise the FORMAT, do not invent what EXIF does not say.
-- The same kind of information arrives in different formats depending on the
-- camera/firmware: "50.0 mm f/1.8", "XF35mmF1.4 R", "OLYMPUS M.17mm F1.2",
-- "EF50mm f/1.8". Each rule below fixes one of these inconsistencies.
--
--   1. phones: which camera, not focal/aperture
--        "iPhone 15 Pro front TrueDepth camera 2.69mm f/1.9" -> "iPhone 15 Pro Front camera"
--        "iPhone 15 Pro back triple camera 6.86mm f/1.78"    -> "iPhone 15 Pro Main camera"
--      The back camera comes from the 35mm-equivalent focal length
--      (focal_length_35, from digiKam): < 20mm Ultra Wide, 20-60mm Main
--      (incl. the 2x crop at 48mm), > 60mm Telephoto. The real focal length in
--      the string is not usable: it varies for the same camera (6.86 / 6.765mm)
--      and overlaps across iPhone generations.
--   2. space after the mount code
--        "EF50mm" -> "EF 50mm", "XF35mm" -> "XF 35mm"
--   3. drop redundant ".0"
--        "24.0-85.0 mm f/2.8-4.0" -> "24-85 mm f/2.8-4"
--   4. no space before "mm"
--        "35 mm" -> "35mm"
--   5. uniform aperture notation
--        "mmF1.4", "mm F1.2" -> "mm f/1.4", "mm f/1.2"
--
-- Not done on purpose:
--   - no maker added: it is in the Camera graph node, and for adapted lenses
--     (Helios on a Canon body) EXIF does not know it. Camera <-> lens pairing is
--     shown by the PairedWith edges (Step 12).
--   - photos without EXIF lens (e.g. fixed-lens TG-6 exported by Lightroom)
--     stay NULL: no Lens node.
--   - designations (EF-S, XF, IS, USM, R LM OIS, AI...) are kept: they tell
--     physically different lenses apart.
--
-- The procedure recomputes ALL photos and updates only rows whose value
-- changes. After changing existing values:
--   - run dbo.usp_load_graph_tables (12): it removes stale Lens nodes/edges
--   - run dbo.usp_build_embeddings @force = 1 (19): "Lens:" is part of embedding_text
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- dbo.fn_normalize_lens: inline TVF, usable on any string (see test below)
-- REGEXP flags: 'i' = case-insensitive; omitted = case-sensitive (default 'c').
-------------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_normalize_lens
(
    @lens_raw         NVARCHAR(512),
    @focal_length_35  DECIMAL(6,1)
)
RETURNS TABLE
AS
RETURN
    SELECT  lens_model_norm = s5.v
    FROM    (VALUES (NULLIF(LTRIM(RTRIM(@lens_raw)), N''))) AS s0(v)
    -- 1. phones: "<device> back|front ... camera <focal> <aperture>" -> "<device> <camera> camera"
    CROSS APPLY (VALUES (
                CASE
                    WHEN REGEXP_LIKE(s0.v, N'\s(back|front)\s.*camera', 'i')
                    THEN CONCAT(
                            REGEXP_REPLACE(s0.v, N'\s+(back|front)\s.*$', N'', 1, 0, 'i'),
                            CASE
                                WHEN REGEXP_LIKE(s0.v, N'\sfront\s', 'i') THEN N' Front'
                                WHEN @focal_length_35 IS NULL             THEN N' Back'
                                WHEN @focal_length_35 <  20               THEN N' Ultra Wide'
                                WHEN @focal_length_35 <= 60               THEN N' Main'
                                ELSE                                           N' Telephoto'
                            END,
                            N' camera')
                    ELSE s0.v
                END)) AS s1(v)
    -- 2. space after mount code (case-sensitive: mount codes are upper case)
    CROSS APPLY (VALUES (REGEXP_REPLACE(s1.v, N'^(EF-S|EF-M|EF|RF-S|RF|XF|XC)(\d)', N'\1 \2'))) AS s2(v)
    -- 3. redundant ".0"
    CROSS APPLY (VALUES (REGEXP_REPLACE(s2.v, N'(\d)\.0\b', N'\1'))) AS s3(v)
    -- 4. no space before "mm"
    CROSS APPLY (VALUES (REGEXP_REPLACE(s3.v, N'(\d)\s+mm\b', N'\1mm', 1, 0, 'i'))) AS s4(v)
    -- 5. aperture notation
    CROSS APPLY (VALUES (REGEXP_REPLACE(s4.v, N'mm\s*F/?(\d)', N'mm f/\1', 1, 0, 'i'))) AS s5(v);
GO

-------------------------------------------------------------------------------
-- dbo.usp_normalize_lens_models: apply the function to all photos
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_normalize_lens_models
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE  p
    SET     lens_model_norm = n.lens_model_norm
    FROM    dbo.photos AS p
    CROSS APPLY dbo.fn_normalize_lens(p.lens_model_raw, p.focal_length_35) AS n
    WHERE   p.lens_model_norm IS DISTINCT FROM n.lens_model_norm;   -- only real changes

    DECLARE @rc INT = @@ROWCOUNT;
    RAISERROR('lens_model_norm - rows changed: %d', 0, 1, @rc) WITH NOWAIT;
END;
GO

-------------------------------------------------------------------------------
-- Test: real values from the demo dataset + common formats not in it.
-- "ok" must be 1 on every row.
-------------------------------------------------------------------------------
--SELECT  t.lens_raw, t.f35, n.lens_model_norm, t.expected,
--        CASE WHEN n.lens_model_norm IS NOT DISTINCT FROM t.expected THEN 1 ELSE 0 END AS ok
--FROM    (VALUES
--            (N'EF50mm f/1.8',                                      NULL,  N'EF 50mm f/1.8'),
--            (N'XF35mmF1.4 R',                                      53.0,  N'XF 35mm f/1.4 R'),
--            (N'XF18-55mmF2.8-4 R LM OIS',                          61.0,  N'XF 18-55mm f/2.8-4 R LM OIS'),
--            (N'50.0 mm f/1.8',                                     75.0,  N'50mm f/1.8'),
--            (N'24.0-85.0 mm f/2.8-4.0',                            24.0,  N'24-85mm f/2.8-4'),
--            (N'OLYMPUS M.17mm F1.2',                               34.0,  N'OLYMPUS M.17mm f/1.2'),
--            (N'Helios 44-2 58mm f/2',                              58.0,  N'Helios 44-2 58mm f/2'),
--            (N'iPhone 15 Pro back triple camera 6.86mm f/1.78',    24.0,  N'iPhone 15 Pro Main camera'),
--            (N'iPhone 15 Pro back triple camera 6.765mm f/1.78',   48.0,  N'iPhone 15 Pro Main camera'),       -- 2x crop
--            (N'iPhone 15 Pro back triple camera 2.22mm f/2.2',     13.0,  N'iPhone 15 Pro Ultra Wide camera'),
--            (N'iPhone 15 Pro back triple camera 9mm f/2.8',        77.0,  N'iPhone 15 Pro Telephoto camera'),
--            (N'iPhone 15 Pro back triple camera 6.86mm f/1.78',    NULL,  N'iPhone 15 Pro Back camera'),       -- no 35mm equiv.
--            (N'iPhone 15 Pro front TrueDepth camera 2.69mm f/1.9', 23.0,  N'iPhone 15 Pro Front camera'),
--            (N'EF-S18-55mm f/3.5-5.6 IS STM',                      NULL,  N'EF-S 18-55mm f/3.5-5.6 IS STM'),
--            (N'RF24-105mm F4 L IS USM',                            NULL,  N'RF 24-105mm f/4 L IS USM'),
--            (NULL,                                                 25.0,  NULL)                               -- TG-6: no EXIF lens
--        ) AS t(lens_raw, f35, expected)
--CROSS APPLY dbo.fn_normalize_lens(t.lens_raw, t.f35) AS n;
--GO

-------------------------------------------------------------------------------
-- Run on the dataset and show raw vs normalised values
-------------------------------------------------------------------------------
EXEC    dbo.usp_normalize_lens_models;
GO

SELECT  DISTINCT camera_make, camera_model, lens_model_raw, focal_length_35, lens_model_norm
FROM    dbo.photos
ORDER BY lens_model_norm;
GO
