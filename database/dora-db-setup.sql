-- =============================================================================
-- DORA Contract Intelligence - Database Setup
-- PostgreSQL 14 + pgvector 0.8.2
-- Server: 10.1.4.14 (LAB-POSTGRES01)
--
-- Koer som postgres bruger:
--   PGPASSWORD=<pw> psql -h 10.1.4.14 -U postgres -f dora-db-setup.sql
--
-- Idempotent: kan koeres flere gange uden fejl
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Database
-- -----------------------------------------------------------------------------
SELECT 'CREATE DATABASE dora'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'dora'
)\gexec


-- -----------------------------------------------------------------------------
-- 2. Skift til dora databasen
-- -----------------------------------------------------------------------------
\connect dora


-- -----------------------------------------------------------------------------
-- 3. Extensions
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";


-- -----------------------------------------------------------------------------
-- 4. Applikationsbruger (laese/skrive, ikke superuser)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dora_app') THEN
        CREATE ROLE dora_app LOGIN PASSWORD 'DoraApp@Lab1';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE dora TO dora_app;


-- -----------------------------------------------------------------------------
-- 5. Schema
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS dora AUTHORIZATION dora_app;
SET search_path TO dora, public;


-- -----------------------------------------------------------------------------
-- 6. Fil-sporingstabel
--    En raekke per fil i en kontrakt-pakke.
--    Bruges af front-office robotten til change detection via SHA256.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dora.contract_files (
    contract_id     TEXT        NOT NULL,
    -- Relativ sti fra kontrakt-mappen, f.eks. "bilag-03-sla.pdf"
    file_path       TEXT        NOT NULL,
    -- SHA256 hex af filindhold
    file_hash       TEXT        NOT NULL,
    file_size       BIGINT,
    -- Tidspunkt for seneste indeksering af denne fil-version
    indexed_at      TIMESTAMPTZ,
    -- Opdateres hver gang robotten ser filen (ogsaa uden aendring)
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (contract_id, file_path)
);

COMMENT ON TABLE dora.contract_files IS
    'Sporing af indekserede filer per kontrakt. '
    'Change detection via SHA256 hash.';

GRANT SELECT, INSERT, UPDATE, DELETE ON dora.contract_files TO dora_app;


-- -----------------------------------------------------------------------------
-- 7. Chunk-tabel med embeddings
--    En raekke per tekst-chunk.
--    Embedding-dimension: 768 (nomic-embed-text via Ollama)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dora.contract_chunks (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id     TEXT        NOT NULL,
    -- Relativ filsti - matcher contract_files.file_path
    file_path       TEXT        NOT NULL,
    -- SHA256 af filen paa indekseringstidspunktet
    file_hash       TEXT        NOT NULL,
    -- Intern raekkefoelge inden for filen
    chunk_index     INTEGER     NOT NULL,
    -- Selve teksten - vises som citation-uddrag til brugeren
    chunk_text      TEXT        NOT NULL,
    -- Embedding vector (nomic-embed-text = 768 dimensioner)
    embedding       VECTOR(768) NOT NULL,

    -- Citation-metadata
    page_start      INTEGER,    -- PDF: foerste side i chunk
    page_end        INTEGER,    -- PDF: sidste side (hvis sphaender over flere)
    section_heading TEXT,       -- Word/PDF: naermeste overskrift
    char_offset     INTEGER,    -- Fallback: tegn-offset fra dokumentstart

    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_file
        FOREIGN KEY (contract_id, file_path)
        REFERENCES dora.contract_files (contract_id, file_path)
        ON DELETE CASCADE
);

COMMENT ON TABLE dora.contract_chunks IS
    'Tekst-chunks med vector embeddings. '
    'Citation via page_start/page_end og section_heading. '
    'chunk_text vises direkte som fremhaevet uddrag til brugeren.';

COMMENT ON COLUMN dora.contract_chunks.embedding IS
    'nomic-embed-text, 768 dim. '
    'Genereret via Ollama: http://ollama.ollama.svc.cluster.local:11434';

GRANT SELECT, INSERT, UPDATE, DELETE ON dora.contract_chunks TO dora_app;


-- -----------------------------------------------------------------------------
-- 8. Indexes
-- -----------------------------------------------------------------------------

-- Vector similarity search (cosine distance)
-- ivfflat lists=100 passer til op mod ~1M chunks
-- Koer ANALYZE efter bulk-indeksering
CREATE INDEX IF NOT EXISTS idx_chunks_embedding
    ON dora.contract_chunks
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- Filtrering paa kontrakt-ID
CREATE INDEX IF NOT EXISTS idx_chunks_contract_id
    ON dora.contract_chunks (contract_id);

-- Til sletning ved re-indeksering af aendret fil
CREATE INDEX IF NOT EXISTS idx_chunks_contract_file
    ON dora.contract_chunks (contract_id, file_path);

-- Change detection opslag
CREATE INDEX IF NOT EXISTS idx_files_hash
    ON dora.contract_files (contract_id, file_hash);


-- -----------------------------------------------------------------------------
-- 9. Funktion: slet chunks for en fil (bruges ved re-indeksering)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dora.delete_file_chunks(
    p_contract_id TEXT,
    p_file_path   TEXT
) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM dora.contract_chunks
    WHERE contract_id = p_contract_id
      AND file_path   = p_file_path;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

COMMENT ON FUNCTION dora.delete_file_chunks IS
    'Slet alle chunks for en fil inden re-indeksering. '
    'Returnerer antal slettede raekker.';

GRANT EXECUTE ON FUNCTION dora.delete_file_chunks TO dora_app;


-- -----------------------------------------------------------------------------
-- 10. Funktion: similarity search (bruges af BYOVD API Workflow)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dora.search_chunks(
    p_contract_id   TEXT,
    p_query_vector  VECTOR(768),
    p_limit         INTEGER DEFAULT 6
)
RETURNS TABLE (
    id              UUID,
    contract_id     TEXT,
    file_path       TEXT,
    chunk_text      TEXT,
    page_start      INTEGER,
    page_end        INTEGER,
    section_heading TEXT,
    similarity      FLOAT
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
        c.contract_id,
        c.file_path,
        c.chunk_text,
        c.page_start,
        c.page_end,
        c.section_heading,
        1 - (c.embedding <=> p_query_vector) AS similarity
    FROM dora.contract_chunks c
    WHERE c.contract_id = p_contract_id
    ORDER BY c.embedding <=> p_query_vector
    LIMIT p_limit;
END;
$$;

COMMENT ON FUNCTION dora.search_chunks IS
    'Similarity search til BYOVD API Workflow. '
    'Returnerer top-K chunks med cosine similarity og citation-felter.';

GRANT EXECUTE ON FUNCTION dora.search_chunks TO dora_app;


-- -----------------------------------------------------------------------------
-- 11. Verificering
-- -----------------------------------------------------------------------------
SELECT tablename FROM pg_tables WHERE schemaname = 'dora' ORDER BY tablename;
SELECT routine_name FROM information_schema.routines WHERE routine_schema = 'dora' ORDER BY routine_name;
