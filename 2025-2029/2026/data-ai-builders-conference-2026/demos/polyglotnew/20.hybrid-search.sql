-------------------------------------------------------------------------------
-- Hybrid Search: FTS esatto | FTS semantico | vector | ibrido (INNER vs LEFT JOIN)
-- Query di riferimento: "portrait focusing on the face of a single cat"
-- Dataset: foto demo, tutte con vision_text e embeddings generati
-- Prerequisiti: step 16 (FTS catalog + index) e step 19 (embeddings)
-- Modelli: qwen3-vl:8b-instruct (vision_text) + qwen3-embedding:0.6b (vector)
--
-- Nota sulle percentuali: qwen3-embedding produce similarità coseno su una scala
-- più bassa di nomic-embed-text (~50% per i match migliori). Non confrontare i
-- valori assoluti tra modelli: conta il distacco tra rilevanti e rumore.
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-- Baseline: le 3 foto di felini nel dataset (15=4 gattini, 16=kitten singolo, 26=gatto di strada)
SELECT  photo_id, CAST(LEFT(vision_text, 100) AS nvarchar(100)) AS vision_text_cut, file_path
FROM    dbo.photos
WHERE   photo_id IN (15, 16, 26);
GO

-- ============================================================================
-- (1/5) FTS - CONTAINS: corrispondenza esatta della parola
-- Cerca la parola esatta "cat" senza espansione morfologica.
-- -> 1 sola riga: foto 26, l'unica con "cat".
--   Foto 15 e 16 ("kittens"/"kitten") vengono escluse: il termine "cat" non
--   appare nei loro testi. Basso recall - le varianti lessicali sono invisibili.
-- ============================================================================
SELECT  photo_id, CAST(LEFT(vision_text, 100) AS nvarchar(100)) AS vision_text_cut, file_path
FROM    dbo.photos
WHERE   CONTAINS(vision_text, 'cat');
GO

-- solo 2 foto (16, 26): manca la 15 con "kittens" (al plurale)
SELECT  photo_id, CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos
WHERE   CONTAINS(vision_text, 'cat OR kitten');
GO

-- possiamo risolvere con FREETEXT in questo caso specifico: 15, 16, 26
SELECT  photo_id, CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos
WHERE   FREETEXT(vision_text, 'cat kitten');
GO

-- ============================================================================
-- (2/5) FTS - FREETEXTTABLE: ricerca in linguaggio naturale con rank (0-1000)
-- Con la frase completa, invece, FTS fallisce su due fronti:
-- -> Foto 26 (gatto, rank 48) è prima: unico testo con "cat".
--   FALSO POSITIVO al #2: foto 24 (rosa, rank 45) perché il testo recita
--   "A single pink rose" - "single" coincide con la query.
--   Il kitten 16 è solo 3° (rank 26), a pari merito con lo stagno (18) e il
--   caco (23, "A single ripe persimmon"): ancora "single".
--   I quattro gattini (15) SPARISCONO: nessuna parola della query nel testo,
--   e lo stemming non collega kitten -> cat.
-- ============================================================================
SELECT  TOP 5 p.photo_id, ft.RANK AS fts_rank
,       CAST(LEFT(vision_text, 100) AS nvarchar(100)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    FREETEXTTABLE(dbo.photos, vision_text,
            'portrait focusing on the face of a single cat') AS ft
  ON    ft.[KEY] = p.photo_id
ORDER BY ft.RANK DESC;
GO

-- ============================================================================
-- (3/5) Vector distance: similitudine semantica tramite embeddings
-- La query viene codificata come vettore 1024-dim e confrontata per coseno.
-- -> Le 3 foto di felini sono le prime 3, nell'ordine giusto:
--   foto 16 (kitten singolo in primo piano, 53.62%) > foto 26 (gatto, 48.28%)
--   > foto 15 (quattro gattini, 38.01%): singolo > gruppo.
--   Poi un salto di ~9 punti: ciclamini 28.63%, Santorini 27.07%.
--   I falsi positivi "single" (rosa, caco) non compaiono nemmeno nella top 5.
-- ============================================================================
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'portrait focusing on the face of a single cat') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(LEFT(vision_text, 100) AS nvarchar(100)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe ON pe.photo_id = p.photo_id
ORDER BY VECTOR_DISTANCE('cosine', pe.embedding, @q);
GO

-- ============================================================================
-- (4/5) Hybrid search ingenuo: INNER JOIN FREETEXTTABLE + vector (30%/70%)
-- L'INNER JOIN con FREETEXTTABLE agisce da FILTRO: entrano solo le foto che
-- FTS ha già trovato. L'ibrido eredita il problema di recall del punto 2.
-- -> Foto 16 (0.3832) e 26 (0.3524) in testa: trovate da entrambi i canali.
--   I quattro gattini (15), #3 nel vector, sono SPARITI: FTS non li aveva.
--   Al loro posto caco (0.1971), rosa (0.1926), lampione (0.1751): il vector
--   li spinge in basso, ma restano nella top 5 perché sono gli unici rimasti.
--   Lezione: combinare i punteggi non basta, conta COME si combinano i canali.
-- ============================================================================
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'portrait focusing on the face of a single cat') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id, ft.RANK AS fts_rank
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(
            (ft.RANK / 1000.0) * 0.3 +
            (1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 0.7
        AS DECIMAL(5,4)) AS combined_score
,       CAST(LEFT(vision_text, 100) AS nvarchar(100)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    FREETEXTTABLE(dbo.photos, vision_text,
            'portrait focusing on the face of a single cat') AS ft
        ON ft.[KEY] = p.photo_id
JOIN    dbo.photo_embeddings AS pe
        ON pe.photo_id = p.photo_id
ORDER BY combined_score DESC;
GO

-- ============================================================================
-- (5/5) Hybrid search corretto: LEFT JOIN FREETEXTTABLE + vector (30%/70%)
-- Il vector è il canale base (tutte le foto), FTS aggiunge solo un bonus:
-- se FTS non trova la foto, il suo contributo è 0 invece di escluderla.
-- -> Foto 16 (0.3832) > foto 26 (0.3524) > foto 15 (0.2661, solo vector,
--   fts_rank 0): le 3 foto di felini tornano ai primi 3 posti.
--   Poi ciclamini (0.2004, anch'essi senza FTS) e caco (0.1971).
--   La rosa, #2 in FTS, esce dalla top 5.
-- ============================================================================
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'portrait focusing on the face of a single cat') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id, ISNULL(ft.RANK, 0) AS fts_rank
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(
            (ISNULL(ft.RANK, 0) / 1000.0) * 0.3 +
            (1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 0.7
        AS DECIMAL(5,4)) AS combined_score
,       CAST(LEFT(vision_text, 100) AS nvarchar(100)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe
        ON pe.photo_id = p.photo_id
LEFT JOIN FREETEXTTABLE(dbo.photos, vision_text,
            'portrait focusing on the face of a single cat') AS ft
        ON ft.[KEY] = p.photo_id
ORDER BY combined_score DESC;
GO
