-- =============================================================================
-- XX_KB_TABLE_SETUP_26ai.sql
-- Knowledge-base vector table for the 26ai clone (non-Autonomous).
-- Run as COLLECTIONS_AI in the ERPUAT PDB. Idempotent.
--
-- The embedding column is declared as unconstrained VECTOR so it accepts either:
--   * in-DB ONNX all_MiniLM_L12_v2 (384-dim, provider "database"), OR
--   * Bedrock Titan v2 (1536-dim) loaded via knowledge_base/loader.py.
-- xx_kb_search_pkg.search() does semantic search when embeddings + ONNX model are
-- present, else auto-falls back to keyword token-overlap (always returns results).
-- =============================================================================

DECLARE
  e_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_exists, -955);  -- name already used
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE collections_knowledge_base (
      id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      content     CLOB NOT NULL,
      summary     VARCHAR2(500),
      doc_type    VARCHAR2(50) NOT NULL,
      metadata    JSON,
      embedding   VECTOR,
      created_at  TIMESTAMP DEFAULT SYSTIMESTAMP,
      updated_at  TIMESTAMP DEFAULT SYSTIMESTAMP,
      CONSTRAINT chk_kb_doc_type CHECK (doc_type IN ('policy','sop','template','correspondence','faq'))
    )]';
EXCEPTION WHEN e_exists THEN NULL;
END;
/

DECLARE
  e_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_exists, -955);
BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX idx_kb_doc_type ON collections_knowledge_base(doc_type)';
EXCEPTION WHEN e_exists THEN NULL;
END;
/
