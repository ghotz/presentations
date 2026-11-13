-------------------------------------------------------------------------------
-- Altro caso d'uso più generico: "animali" come categoria, negazioni, import live
-- Modelli: qwen3-vl:8b-instruct (vision_text del dataset; import live: 4b sul P51)
--          + qwen3-embedding:0.6b (vector)
-------------------------------------------------------------------------------
USE PhotoIntelligence;
GO

-------------------------------------------------------------------------------
-- PRIMA DELLA DEMO: riscaldamento modelli (eseguire qualche minuto prima)
-- Carica il modello vision e qwen3-embedding in memoria e ve li tiene per 60 minuti
-- ("keep_alive"), così l'import live più sotto non paga il caricamento a freddo.
-- Sul P51 si usa qwen3-vl:4b-instruct (l'8b è troppo lento per una demo live);
-- sul desktop si può usare l'8b (riga commentata). Stesso modello nell'import.
-------------------------------------------------------------------------------
DECLARE @resp NVARCHAR(MAX);
EXEC sp_invoke_external_rest_endpoint
    @url      = N'https://localhost:11435/api/generate',
    @method   = 'POST',
    --@payload  = N'{"model":"qwen3-vl:8b-instruct","prompt":"Reply with one word: ready.","stream":false,"think":false,"keep_alive":"60m"}',
    @payload  = N'{"model":"qwen3-vl:4b-instruct","prompt":"Reply with one word: ready.","stream":false,"think":false,"keep_alive":"60m"}',
    @timeout  = 230,
    @response = @resp OUTPUT;
SELECT JSON_VALUE(@resp, '$.result.response') AS vision_warmup;

SELECT AI_GENERATE_EMBEDDINGS(N'warm-up' USE MODEL qwen_embed) AS embedding_warmup;
GO

-- Baseline: le 3 foto di felini nel dataset (15=4 gattini, 16=kitten singolo, 26=gatto di strada)
SELECT  photo_id, CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos
WHERE   photo_id IN (15, 16, 26);
GO


-- se volessi includere qualunque animale con FTS, otterrei ESATTAMENTE IL CONTRARIO:
-- -> 21 righe, e NESSUNA è un felino: quasi tutte le foto tranne gli animali.
--   Il prompt dello script 15 chiede di nominare animali, veicoli, piante...: il modello
--   lo fa anche per escluderli ("No animals, vehicles, or architecture visible").
--   FTS trova la parola "animal" proprio nelle frasi negative, mentre i felini
--   sono descritti come "kitten"/"cat" e la parola "animal" non compare.
--   FTS è lessicale: non capisce né le categorie né la negazione.
SELECT  photo_id, CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos
WHERE   CONTAINS(vision_text, 'animal')
   OR   FREETEXT(vision_text, 'animal');
GO

-- con vector funziona: "kitten" e "cat" sono vicini al concetto di "animal".
-- -> I 3 felini ai primi posti: 16 (45.54%), 15 (40.98%), 26 (37.00%).
--   Poi hemerocallis 33.24% e rododendri 32.74%: gap di ~4 punti,
--   non troppo netto ma almeno c'è - e nessuna foto "No animals" in cima.
--
-- NOTA per la demo - foto 25 (rododendri), ALLUCINAZIONE lasciata di proposito:
--   "A dense, vibrant patch of Rhododendron 'Cunningham's White' in full bloom,
--    though mislabeled; actual flowers are bright red, not white."
--   Nella foto non c'è alcun cartellino. Il prompt dello script 15 chiede di nominare la
--   specie in modo specifico: il modello inventa con sicurezza il nome di una
--   varietà molto comune, poi vede che i fiori sono rossi e si contraddice da
--   solo nella stessa frase. Esempio concreto del perché vision_text va
--   trattato come dato generato, non come verità: è anche il motivo per cui
--   il canale visivo e il reranker sono in roadmap (vedi README).
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'photos with animals') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe ON pe.photo_id = p.photo_id
ORDER BY
    VECTOR_DISTANCE('cosine', pe.embedding, @q);
GO

-- riformulando con "at least one animal" il risultato è stabile:
-- -> 16 (46.94%), 15 (41.57%), 26 (39.84%), poi rododendri 35.50%, hemerocallis 34.84%.
--   Stessi 3 felini, stesso rumore, gap ~4.3 punti.
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'photos with at least one animal') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe ON pe.photo_id = p.photo_id
ORDER BY
    VECTOR_DISTANCE('cosine', pe.embedding, @q);
GO

-- se cerco di eliminare le persone mettendo "but no person" nel prompt, la
-- negazione non funziona nemmeno con il vector: "no person" AGGIUNGE il concetto
-- di persona alla query invece di toglierlo.
-- -> 15 (49.75%), 16 (48.70%), poi la statua della strega (8, 48.22%) che
--   SUPERA il gatto 26 (47.04%); quinto un paesaggio di lago (42.44%).
--   Le percentuali salgono per tutti, ma il rumore sale di più: la statua
--   (una figura umana) entra tra i felini. Il gap è sparito.
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'photos with at least one animal but no person') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe ON pe.photo_id = p.photo_id
ORDER BY
    VECTOR_DISTANCE('cosine', pe.embedding, @q);
GO

-- in questo caso, meglio filtrare le persone con FTS, ma è solo un esempio:
-- la negazione va espressa come predicato (WHERE NOT ...), non nel prompt.
-- -> Stessa top 5 della query "at least one animal": la statua sparisce,
--   il gap torna a ~4.3 punti.
--   Nota: il filtro NON esclude il kitten 16 ("held by human hands"):
--   FTS è lessicale, "person" non trova "human". Il filtro è preciso quanto
--   le parole che gli dai.
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'photos with at least one animal') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe ON pe.photo_id = p.photo_id
WHERE   NOT FREETEXT(vision_text, 'person')
ORDER BY
    VECTOR_DISTANCE('cosine', pe.embedding, @q);
GO

-------------------------------------------------------------------------------
-- Importiamo un foto nuova con un animale diverso
-------------------------------------------------------------------------------
 --BACKUP DATABASE PhotoIntelligence
 --TO DISK = 'C:\Users\gianl\repos\personal\T-SQL-Temp\polyglotnew\backups\PhotoIntelligence.bak'
 --WITH INIT, COMPRESSION, CHECKSUM, STATS=5;
--
-- spostare la foto 20250511-165836-GH01C43-S00 dal folder test a photos e
-- fare refresh con Digikam per inserirla nel catalogo

-- Descrizione con qwen3-vl:4b-instruct sul P51 (4 GB VRAM): ~20 s a caldo,
-- ~40 s a freddo; l'8b, usato per il resto del dataset, ci mette ~45/75 s.
-- Sul desktop si può usare l'8b (riga commentata). Scaldare prima il modello
-- scelto (blocco "PRIMA DELLA DEMO" in testa al file).
-- usp_recognize_images elabora solo le foto con vision_text NULL: qui solo il cigno.
EXEC dbo.usp_load_photos;
EXEC dbo.usp_normalize_lens_models;
EXEC dbo.usp_get_weather;
EXEC dbo.usp_load_graph_tables;
--EXEC dbo.usp_recognize_images @vision_model = N'qwen3-vl:8b-instruct';
EXEC dbo.usp_recognize_images @vision_model = N'qwen3-vl:4b-instruct';
EXEC dbo.usp_build_embeddings;
GO

-- ora ritorna anche il Cigno, senza toccare la query né lo schema:
-- -> foto 28 (cigno reale, Cygnus olor) entra al 3° posto con 38.23% (descritto con l'8b),
--   tra i quattro gattini 15 (40.98%) e il gatto 26 (37.00%).
--   I 4 animali occupano i primi 4 posti; le hemerocallis (33.24%) restano 5e,
--   i rododendri escono dalla top 5.
--   Gli altri valori sono identici alla prima esecuzione di questa query:
--   i vettori esistenti non cambiano, si è aggiunta solo una riga.
DECLARE @q VECTOR(1024) =
    AI_GENERATE_EMBEDDINGS(dbo.fn_embed_query(N'photos with animals') USE MODEL qwen_embed);

SELECT  TOP 5 p.photo_id
,       CAST((1 - VECTOR_DISTANCE('cosine', pe.embedding, @q)) * 100 AS DECIMAL(5,2)) AS similarity_pct
,       CAST(LEFT(vision_text, 150) AS nvarchar(150)) AS vision_text_cut, file_path
FROM    dbo.photos AS p
JOIN    dbo.photo_embeddings AS pe ON pe.photo_id = p.photo_id
ORDER BY
    VECTOR_DISTANCE('cosine', pe.embedding, @q);
GO

-- eliminare la foto 20250511-165836-GH01C43-S00 da digikam e rifare
-- il refresh per rimuoverla dal catalogo, poi per cancellarla
EXEC dbo.usp_load_photos;
GO
