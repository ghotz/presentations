# PhotoIntelligence - Limiti dell'architettura corrente e roadmap di miglioramento

## Architettura corrente

### Indicizzazione (offline)

```text
immagine
  ├─ qwen3-vl:8b-instruct  ───────────────────► vision_text  (FTS + base testo)
  └─ embedding_text = metadati + vision_text
       └─ qwen3-embedding:0.6b  ──────────────► photo_embeddings  VECTOR(1024)
```

### Query (online, durante la demo)

```text
prompt utente
  └─ dbo.fn_embed_query()  (antepone "Instruct: ...\nQuery:")
       └─ qwen3-embedding:0.6b  ───────────────► query_vector  VECTOR(1024)
            │
            └─ VECTOR_DISTANCE(photo_embeddings)  ──► top-k (canale testuale)
            └─ FREETEXTTABLE(vision_text)         ──► top-k (FTS)
                     │
                     └─ score pesato (70% vector + 30% FTS)  ──► risultato finale
```

Modelli (tag fissati in `01.install-dependencies.bat`):

| Ruolo     | Modello Ollama         | Registrazione in SQL Server                         |
|-----------|------------------------|-----------------------------------------------------|
| Vision    | `qwen3-vl:8b-instruct` | nessuna: `sp_invoke_external_rest_endpoint`         |
| Embedding | `qwen3-embedding:0.6b` | `EXTERNAL MODEL qwen_embed`, 1024 dimensioni        |

Usare le varianti **Instruct** di Qwen3-VL, non i tag senza suffisso (`qwen3-vl:8b`):
questi puntano alla variante Thinking, che ragiona sempre prima di rispondere
ignorando `"think":false` (centinaia di token in più per ogni foto). La risposta
finale resta comunque in `$.result.response`, il ragionamento in `$.result.thinking`.

File chiave: `15.rest-recognize-images.sql`, `17.config-external-model.sql`,
`19.generate-embeddings.sql`, `20.hybrid-search.sql`, `21.hybrid-search-good-recall.sql`.

### Cambio modelli (da qwen2.5vl + nomic-embed-text)

La pipeline è stata migrata da `qwen2.5vl` + `nomic-embed-text` (768d) a
`qwen3-vl:8b-instruct` + `qwen3-embedding:0.6b` (1024d). Poiché cambia la dimensione del
vettore, si riparte da database vuoto:

1. `01.install-dependencies.bat` (pull dei nuovi modelli)
2. `02.database-setup.sql` -> `22.hybrid-search-fail-good.sql` in ordine
3. rieseguire le query 20-22 e aggiornare i commenti con rank/percentuali:
   quelli presenti sono stati misurati con i modelli precedenti
4. nuovo backup `backups/PhotoIntelligence-stable.bak`

---

## Problemi dell'architettura corrente

### 1. Divergenza degli embedding tra hardware diversi

Gli embedding delle foto vengono calcolati sull'HW di sviluppo (desktop RTX 4070) e
salvati nel backup `backups/PhotoIntelligence-stable.bak`.
Durante la demo su HW diverso, `AI_GENERATE_EMBEDDINGS` calcola il vettore del prompt
utente con la stessa istanza di Ollama locale.

**Il rischio reale**: il modello di embedding è deterministico per input identici, ma la
riproducibilità dipende da:

- la stessa versione del file modello (aggiornamenti Ollama cambiano il GGUF)
- la stessa quantizzazione (CPU vs GPU possono usare backend diversi con diverse
  istruzioni SIMD/CUDA, producendo piccole differenze floating-point)
- la stessa versione di Ollama

Se l'HW della demo ha una versione del modello anche leggermente diversa, lo spazio
vettoriale degli embedding pre-calcolati e quello del prompt al volo non coincidono
perfettamente: le distanze coseno rimangono ragionevoli, ma l'ordinamento del top-k
cambia in modo imprevedibile, soprattutto tra candidati con score ravvicinati.

**Mitigazione già in place**: i tag dei modelli sono fissati in
`01.install-dependencies.bat`, che al termine stampa `ollama list`. La colonna ID
(digest) di `qwen3-embedding:0.6b` deve essere identica su HW di sviluppo e HW demo.

**Soluzione immediata**: includere nel `bak` anche lo snapshot dell'embedding del
prompt di riferimento e verificare che corrisponda prima della demo. In alternativa,
ricalcolare tutti gli embedding sull'HW della demo prima del giorno della presentazione.

### 2. Spazio vettoriale: dove la critica è giusta e dove no

La critica "gli spazi vettoriali sono diversi" è parzialmente fondata.

**Dove è sbagliata**: per il canale testuale, lo stesso modello di embedding processa
sia i documenti (index time) sia il prompt (query time) -> lo spazio vettoriale è
unico e coerente. È il funzionamento normale di qualsiasi retrieval basato su dense
embeddings.

**Dove è fondata**: l'`embedding_text` indicizzato è un documento strutturato
("Camera: Nikon D700\nLens: 50mm\nScene: ..."), molto diverso per distribuzione da un
prompt naturale ("ritratto ravvicinato di un gatto").

**Come è stata mitigata**: `qwen3-embedding` è addestrato per retrieval asimmetrico.
I documenti vengono embeddati così come sono; le query passano da
`dbo.fn_embed_query()`, che antepone l'istruzione di task
(`Instruct: Given a photo search query, ...\nQuery:<prompt>`). Il modello è inoltre
multilingue, quindi il prompt può essere in italiano anche se `vision_text` è in
inglese. Il passo successivo resta un modello multimodale come Qwen3-VL-Embedding.

**Dove è assolutamente giusta** (canale visivo): se si aggiungesse un canale di embedding
dell'immagine con un modello diverso da quello testuale, i due vettori sarebbero in spazi
incompatibili. La critca in questo caso è del tutto corretta.

### 3. Assenza del canale visivo

Il canale di retrieval testuale opera sulla descrizione generata da Qwen3-VL:
se la descrizione è imprecisa o incompleta, la similarità vettoriale degrada.
Non esiste un canale che confronti direttamente le feature visive delle immagini.

Un modello vision-embedding (es. `nomic-embed-vision`, o `Qwen3-VL-Embedding` in
modalità immagine) produrrebbe vettori che catturano il contenuto visivo indipendentemente
dalla descrizione testuale, fornendo un secondo segnale di recupero.

### 4. Assenza di reranker

La combinazione FTS + vector usa uno **score pesato fisso** (70% / 30%). Questo approccio:

- richiede calibrazione manuale dei pesi per ogni dataset
- non sfrutta la comprensione semantica fine-grained che un modello cross-encoder
  (reranker) applica confrontando query e documento insieme, non separatamente
- può produrre ranking subottimali su dataset eterogenei

---

## Architettura migliorata: pipeline unificata con Qwen3-VL

La versione migliorata usa un unico modello (`Qwen3-VL`) per tutte le operazioni,
eliminando le divergenze di spazio vettoriale tra canali.

### Indicizzazione (migliorata)

```text
immagine + metadati
  ├─ Qwen3-VL  ──────────────────────────────────────► vision_text  (FTS + database)
  ├─ Qwen3-VL-Embedding(immagine)  ──────────────────► VECTOR(N)  [canale visivo]
  └─ Qwen3-VL-Embedding(immagine + metadati)  ────────► VECTOR(N)  [canale contestuale]
```

### Query (migliorata)

```text
prompt utente
  └─ Qwen3-VL-Embedding(testo)  ──────────────────────► query_vector
       │
       ├─ VECTOR_DISTANCE(embedding visivi)    ────────► top-100
       ├─ VECTOR_DISTANCE(embedding contestuali)  ──────► top-100
       └─ FREETEXTTABLE(vision_text)  ───────────────────► top-100
                    │
                    └─ RRF  ──────────────────────────► top-20
                                │
                                └─ Qwen3-VL-Reranker  ──► risultato finale
```

**Vantaggi**:

- unico modello per descrizione, embedding visivo, embedding contestuale e reranking ->
  spazi vettoriali allineati per costruzione
- RRF (Reciprocal Rank Fusion) invece dello score pesato: più robusto, non richiede
  calibrazione manuale dei pesi
- il reranker cross-encoder confronta query e documento insieme, affinando il ranking
  finale su una finestra ristretta (top-20)
- canale visivo puro: cattura feature che la descrizione testuale può omettere

---

## Vincoli T-SQL e soluzioni

### Vincolo 1: `CREATE EXTERNAL MODEL` supporta solo `MODEL_TYPE = EMBEDDINGS`

In SQL Server 2025, solo i modelli di embedding possono essere registrati come
`EXTERNAL MODEL` e usati con `AI_GENERATE_EMBEDDINGS`. I modelli vision, chat e
reranker non sono registrabili - vanno invocati via `sp_invoke_external_rest_endpoint`
con payload JSON esplicito.

### Vincolo 2: `AI_GENERATE_EMBEDDINGS` accetta solo testo

La funzione T-SQL accetta parametri di tipo carattere. Per passare un'immagine
si può usare `BASE64_ENCODE()` (SQL Server 2025), ma dipende da come il modello
espone l'API: l'endpoint Ollama `/api/embed` non supporta immagini in base64.

### Soluzione: wrapper Python FastAPI

Esporre i modelli non supportati come endpoint HTTPS locali, chiamati da T-SQL via
`sp_invoke_external_rest_endpoint`. Mantenendo questa architettura, il flusso
della demo T-SQL rimane invariato - si aggiunge solo la chiamata al wrapper.

```text
T-SQL sp_invoke_external_rest_endpoint
    │
    └─► FastAPI (localhost, HTTPS via Caddy)
             │
             ├─ /rerank    -> sentence-transformers cross-encoder
             └─ /embed/image -> Qwen3-VL-Embedding o nomic-embed-vision
```

Setup consigliato: **venv Python** per isolare le dipendenze; nessun container
necessario per una demo locale. Un container Docker con accesso GPU è la scelta
corretta per un deployment più solido.

---

## Roadmap pratica

### Short-term: reranker e canale visivo con wrapper minimali

1. **Reranker** - piano dettagliato in [`docs/polyglot_reranker_plan.md`](docs/polyglot_reranker_plan.md):
   - `llama-server` (llama.cpp) con `--reranking` ed endpoint `/v1/rerank`, senza
     Python; alternativa FastAPI + sentence-transformers
   - modello `Qwen3-Reranker-0.6B` o `bge-reranker-v2-m3`
   - chiamato da T-SQL sui top-20 dell'ibrido con `LEFT JOIN`
   - File SQL da aggiungere: `23.hybrid-search-reranked.sql`

2. **Canale visivo** - piano dettagliato in [`docs/polyglot_visual_channel_plan.md`](docs/polyglot_visual_channel_plan.md):
   - modello multimodale (`Qwen3-VL-Embedding`, SigLIP 2, `nomic-embed-vision`):
     la query del canale visivo va calcolata con la torre testo dello **stesso** modello
   - wrapper FastAPI: `/v1/embeddings` (formato OpenAI, registrabile come `EXTERNAL MODEL`)
     e `/embed/image` (base64, via `sp_invoke_external_rest_endpoint`)
   - tabella separata `dbo.photo_image_embeddings` e fusione dei tre canali con RRF

### Short-term: lettura da database thumbnail digiKam

digiKam mantiene i thumbnail in `thumbnails-digikam.db` (SQLite, accessibile via
Linked Server ODBC come `digikam4.db`). Sostituire `OPENROWSET(BULK ...)` con una
lettura diretta dal database dei thumbnail eliminerebbe la dipendenza dal filesystem
e ridurrebbe la dimensione del dato trasferito a SQL Server durante la vision inference.

**Caveat**: la risoluzione dei thumbnail digiKam (256 × 256 px o 512 × 512 px) può
essere insufficiente per il riconoscimento di dettagli fini (testo, razze animali
poco comuni, elementi architettonici di sfondo). La qualità della `vision_text`
degraderebbe rispetto all'immagine originale.

**Perché non è stato implementato nel pipeline T-SQL**: a quel punto la logica
(aprire un database SQLite, estrarre il blob compresso, decomprimerlo, passarlo al
modello) diventa più pratica in uno script Python esterno che in T-SQL puro con
`OPENROWSET BULK`. Il guadagno architetturale non giustifica la perdita della
narrativa "tutto in T-SQL" - che è il punto della demo. Se il vincolo del T-SQL
viene già allentato aggiungendo wrapper FastAPI, la lettura dei thumbnail diventa
un'ottimizzazione ragionevole da gestire direttamente nello stesso script Python.

### Short-term: prompt di descrizione senza frasi negative

Il prompt di `15.rest-recognize-images.sql` elenca categorie da nominare (animali,
veicoli, piante, architettura...). Qwen3-VL risponde anche per escluderle:
"No animals, vehicles, or architecture visible". Effetti misurati:

- FTS su `'animal'` restituisce tutte le foto **tranne** quelle con animali
  (usato volutamente come esempio in `22.hybrid-search-fail-good.sql`)
- le frasi negative entrano anche in `embedding_text`: "No animals" porta comunque
  il concetto "animal" nel vettore, riducendo il distacco tra foto rilevanti e
  rumore nelle query per categoria (~4 punti in 22)

Lo stesso prompt causa anche **allucinazioni sulle specie**: chiedendo di nominare
specie e varietà "in modo specifico", il modello inventa quando non è sicuro. Caso
reale, foto 25: "Rhododendron 'Cunningham's White' in full bloom, though mislabeled;
actual flowers are bright red, not white" - nella foto non c'è alcun cartellino; il
modello propone una varietà comune e poi si contraddice. Lasciata di proposito come
esempio nella demo (`22.hybrid-search-fail-good.sql`).

Correzione: aggiungere al prompt "Describe only what is visible; do not mention
what is absent", "name species or varieties only if clearly identifiable, otherwise
use the genus or a common name" (e "do not comment on watermarks or on the indexing
task"), poi rieseguire 15 e 19 con `@force = 1` e rimisurare 20-22. Rimandata per non
perdere gli esempi della demo.

Confronto con metadati separati, reranker e canale visivo, proposta di prompt e
bullet per la presentazione: [`docs/polyglot_search_quality_analysis.md`](docs/polyglot_search_quality_analysis.md).

### Long-term: pipeline unificata Qwen3-VL

La generazione delle descrizioni usa già `qwen3-vl:8b-instruct` (famiglia Qwen3-VL, rilasciata
a settembre-ottobre 2025). Il passo successivo è adottare anche
`Qwen3-VL-Embedding` e `Qwen3-VL-Reranker` (rilasciati a gennaio 2026), che
proiettano testo e immagini nello stesso spazio:

- generazione descrizione: `qwen3-vl:8b-instruct` in modalità chat - **fatto**
- embedding visivo: `Qwen3-VL-Embedding(image)` -> wrapper FastAPI
- embedding contestuale: `Qwen3-VL-Embedding(image, text)` -> stesso wrapper
- reranker: `Qwen3-VL` in modalità reranker o modello dedicato della stessa famiglia

Tutti e tre gli endpoint possono convivere nello stesso processo FastAPI.
Se il wrapper espone anche un endpoint `/v1/embeddings` in formato OpenAI, può essere
registrato come `EXTERNAL MODEL` con `API_FORMAT = 'OpenAI'`: le query testuali
continuano a usare `AI_GENERATE_EMBEDDINGS` e la narrativa "tutto in T-SQL" resta.
Verificare prima se Ollama distribuisce già Qwen3-VL-Embedding nativamente.
Il vantaggio principale è l'allineamento degli spazi vettoriali: immagine, testo e
prompt utente sono tutti proiettati dallo stesso modello nello stesso spazio.

---

## Note hardware

- **HW sviluppo**: desktop con RTX 4070 (12 GB VRAM) - inference locale con Ollama
- **HW demo**: Lenovo ThinkPad P51 (GPU: Quadro M2200, 4 GB VRAM)
- `backups/PhotoIntelligence-stable.bak` contiene il dataset completo con embedding
  pre-calcolati. Restaurare il bak sull'HW della demo e verificare che l'ID di
  `qwen3-embedding:0.6b` in `ollama list` sia identico a quello usato per il calcolo
  degli embedding, prima di eseguire le query di ricerca dal vivo.
- Misure sul P51 (foto del cigno, prompt di `15.rest-recognize-images.sql`),
  fatte con i tag senza suffisso, cioè le varianti **Thinking** (da rimisurare con
  le Instruct, che non generano il ragionamento e dovrebbero essere più veloci):

  | Modello                | Processore (`ollama ps`) | Freddo | Caldo       |
  |------------------------|--------------------------|--------|-------------|
  | `qwen3-vl:8b`          | 73%/27% CPU/GPU          | 252 s  | 110-218 s   |
  | `qwen3-vl:4b`          | 48%/52% CPU/GPU          | 99 s   | 46 s        |
  | `qwen3-embedding:0.6b` | 100% GPU                 | 6 s    | da misurare |

  Con le varianti **Instruct** (nessun ragionamento) le misure sul P51 sono:

  | Modello                | Processore (`ollama ps`) | Freddo | Caldo |
  |------------------------|--------------------------|--------|-------|
  | `qwen3-vl:8b-instruct` | 73%/27% CPU/GPU          | 74 s   | 43 s  |
  | `qwen3-vl:4b-instruct` | 48%/52% CPU/GPU          | 40 s   | 22 s  |

  L'import live di `22.hybrid-search-fail-good.sql` usa quindi
  `qwen3-vl:8b-instruct`, lo stesso modello del resto del dataset, ben sotto il
  timeout di 180 s di `15.rest-recognize-images.sql`. Subito dopo, una seconda
  chiamata con `@vision_model = N'qwen3-vl:4b-instruct'` fa da fallback: elabora
  solo le foto rimaste senza `vision_text`, quindi interviene solo se l'8b è
  andato in timeout o in errore.
- Prima della demo eseguire il blocco "PRIMA DELLA DEMO" in testa a `22`: carica i
  modelli con `keep_alive` di 60 minuti. Portatile collegato alla corrente e profilo
  energetico "prestazioni elevate": l'inferenza è per lo più su CPU.
- Dataset per la demo: ~500-1000 foto sono sufficienti per rendere tutte le query
  istantanee anche senza DiskANN (brute-force `VECTOR_DISTANCE`).
