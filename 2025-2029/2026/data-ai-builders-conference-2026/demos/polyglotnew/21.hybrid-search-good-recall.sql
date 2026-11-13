-------------------------------------------------------------------------------
-- Hybrid Search: FTS semantico | vector | ibrido (contrappunto a 20)
-- Query di riferimento: "close-up portrait of a single cat or kitten"
-- Dataset: foto demo, tutte con vision_text e embeddings generati
-- Prerequisiti: step 16 (FTS catalog + index) e step 19 (embeddings)
-- Modelli: qwen3-vl:8b-instruct (vision_text) + qwen3-embedding:0.6b (vector)
--
-- Differenza con 20: qui la query contiene sia "cat" sia "kitten", quindi FTS
-- trova tutti i candidati rilevanti. In questo caso anche l'ibrido con
-- INNER JOIN funziona: il suo limite emerge solo quando FTS perde recall (20).
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-- Baseline: le 3 foto di felini nel dataset (15=4 gattini, 16=kitten singolo, 26=gatto di strada)
SELECT  photo_id, CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos
WHERE   photo_id IN (15, 16, 26);
GO

-- ============================================================================
-- (1/4) FTS - CONTAINS: corrispondenza esatta della parola
-- Cerca la parola esatta "kitten" senza espansione morfologica.
-- -> Atteso: solo foto 16 ("kitten" al singolare); foto 15 ("kittens") e
--   foto 26 ("cat") escluse. Già mostrato in 20, per questo è commentato.
-- ============================================================================
--SELECT  photo_id, CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
--FROM    dbo.photos
--WHERE   CONTAINS(vision_text, 'kitten');
--GO

-- ============================================================================
-- (2/4) FTS - FREETEXTTABLE: ricerca in linguaggio naturale con rank (0-1000)
-- -> Recall completo: le 3 foto di felini sono ai primi 3 posti.
--   Foto 16 (kitten singolo, rank 106) è nettamente prima, ma foto 15
--   (quattro gattini) e foto 26 (gatto singolo) sono a PARI MERITO (43):
--   FTS non distingue il gruppo dal singolo.
--   Rumore lessicale subito sotto: foto 21 (ciclamini, rank 30) per
--   "a close-up of the..." e foto 24 (rosa, rank 24) per "A single pink rose".
--   Il distacco tra felini e rumore è solo 43 -> 30.
-- ============================================================================
SELECT  TOP 5 photo_id, ft.RANK AS fts_rank
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    FREETEXTTABLE(dbo.photos, vision_text, 'close-up portrait of a single cat or kitten') AS ft
  ON    ft.[KEY] = p.photo_id
ORDER BY
        ft.RANK DESC;
GO

-- ============================================================================
-- (3/4) Vector distance: similitudine semantica tramite embeddings
-- La query viene codificata come vettore 1024-dim e confrontata per coseno.
-- -> Foto 16 (63.04%) > foto 26 (49.94%) > foto 15 (47.05%): il vettore
--   risolve il pareggio di FTS nel modo giusto, il gatto SINGOLO sopra il gruppo.
--   E il distacco dal rumore è molto più netto: ciclamini 32.07%,
--   Santorini 27.42% -> ~15 punti tra l'ultimo felino e il primo intruso.
-- ============================================================================
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'close-up portrait of a single cat or kitten') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe ON pe.photo_id = p.photo_id
ORDER BY
    VECTOR_DISTANCE('cosine', pe.embedding, @q);
GO

-- ============================================================================
-- (4/4) Hybrid search: INNER JOIN FREETEXTTABLE + vector (30%/70%)
-- Qui FTS ha già trovato tutti i candidati, quindi l'INNER JOIN non perde
-- nessun felino (a differenza di 20).
-- -> Foto 16 (0.4731) > foto 26 (0.3625) > foto 15 (0.3422): i due canali
--   si rinforzano e il pareggio FTS 15 = 26 è risolto dal vector.
--   Rumore: ciclamini 0.2335, rosa 0.1977 -> oltre 0.10 di distacco dai felini.
--   Con il LEFT JOIN di 20 (5/5) i primi 3 non cambierebbero.
-- ============================================================================
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'close-up portrait of a single cat or kitten') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id, ft.RANK AS fts_rank
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(
            (ft.RANK / 1000.0) * 0.3 +
            (1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 0.7
        AS DECIMAL(5,4)) AS combined_score
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    FREETEXTTABLE(dbo.photos, vision_text, 'close-up portrait of a single cat or kitten') AS ft
        ON ft.[KEY] = p.photo_id
JOIN    dbo.photo_embeddings AS pe
        ON pe.photo_id = p.photo_id
ORDER BY
    combined_score DESC;
GO
