# PhotoIntelligence - Versione precedente

Questa cartella conserva la prima versione della demo PhotoIntelligence.
Per la versione attuale, cerca la nuova demo nelle nuove presentazioni.

## Architettura precedente

La demo combina dati fotografici importati da digiKam, descrizioni generate
localmente e ricerca full-text e vettoriale in SQL Server:

1. `qwen2.5vl`, tramite Ollama, genera una descrizione testuale delle immagini.
2. Metadati e descrizione formano il testo indicizzato.
3. `nomic-embed-text` genera embedding testuali a 768 dimensioni, sia per le
   foto sia per le query.
4. Le query confrontano ricerca full-text, similarità vettoriale e una
   combinazione pesata dei due segnali.

Non è presente un canale di embedding direttamente sulle immagini: la ricerca
vettoriale dipende quindi anche dalla qualità delle descrizioni generate.

## Passaggio alla versione attuale

La nuova demo usa `qwen3-vl:8b-instruct` per le
descrizioni e `qwen3-embedding:0.6b` per gli embedding testuali a 1024
dimensioni. Le query ricevono inoltre un'istruzione specifica per il retrieval.

Gli embedding delle due versioni non sono intercambiabili: cambiando modello e
dimensione dei vettori, la migrazione richiede la rigenerazione degli embedding.
Gli script in questa cartella sono conservati come riferimento storico.
