# dora-sample

Demo-implementation af DORA Contract Intelligence på UiPath Automation Suite.

## Arkitektur

```
Kontrakt-mappe (PC)
  → FrontOfficeRobot  (UiPath Desktop, lokal robot)
      - Opdager nye/ændrede filer via SHA256 hash
      - Chunker PDF/Word filer
      - Genererer embeddings via Ollama (nomic-embed-text)
      - Gemmer chunks i pgvector med citation-metadata
  → pgvector (10.1.4.14, database: dora)
  → ApiWorkflow  (UiPath Integration Service)
      - BYOVD: modtager query + contract_id
      - Embedder query via Ollama
      - Similarity search i pgvector
      - Returnerer chunks med citations som JSON
  → DORA-Contract-Analyzer agent (llama4:scout-lab)
  → Maestro: DORA-Compliance-Solution
```

## Indhold

```
dora-sample/
  database/
    dora-db-setup.sql       SQL setup script (idempotent)
  contracts/
    sample-001/             Testkontrakt 1 (komplet, DORA-konform)
    sample-002/             Testkontrakt 2 (med bevidste DORA-mangler)
  uipath/
    FrontOfficeRobot/       Studio Desktop projekt (lokal robot)
    ApiWorkflow/            Integration Service workflow (BYOVD)
```

## Database

- **Host:** 10.1.4.14 (LAB-POSTGRES01)
- **Database:** dora
- **Bruger:** dora_app
- **pgvector:** 0.8.2
- **Embedding model:** nomic-embed-text (768 dim) via Ollama

Opret database:
```bash
PGPASSWORD=<postgres-pw> psql -h 10.1.4.14 -U postgres -f database/dora-db-setup.sql
```

## Infrastruktur

- Ollama: http://ollama.ollama.svc.cluster.local:11434
- Maestro: https://uipath.apps.ocp.lab.carve.local/default/DefaultTenant/maestro_/home
- pgvector: 10.1.4.14, port 5432
