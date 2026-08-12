-- =============================================================================
-- xx_kb_search_pkg.sql
-- AI Vector Search over COLLECTIONS_KNOWLEDGE_BASE for the APEX KB page.
-- Run as COLLECTIONS_AI in the ERPUAT PDB.
--
-- EMBEDDING-PROVIDER DECISION (verified live 2026-06-24, with doc references):
--
--   SELECT AI (DBMS_CLOUD_AI, Claude via Bedrock) works in-DB — the headline
--   NL->SQL feature. But that path is NOT reusable for *embeddings*:
--     * DBMS_VECTOR(_CHAIN).UTL_TO_EMBEDDING has NO "aws"/Bedrock provider — only
--       cohere/ocigenai/googleai/huggingface/openai/vertexai/mistralai/ollama/
--       privateai/database.  (26ai VECSE: Supported Third-Party Providers)
--       https://docs.oracle.com/en/database/oracle/oracle-database/26/vecse/supported-third-party-provider-operations-and-endpoints.html
--     * DBMS_CLOUD.SEND_REQUEST only auto-signs for OCI and Azure native APIs, so a
--       direct Bedrock embeddings call returns ORA-20403 (Authorization failed).
--       https://docs.oracle.com/en/cloud/paas/autonomous-database/dedicated/adbaa/dbmscloud-rest-apis.html
--
--   => CHOSEN PRIMARY PATH: in-database ONNX embedding model (provider "database").
--      Fully in-DB, zero egress, deterministic, and load-time + query-time vectors
--      are guaranteed to share the same vector space. DBMS_VECTOR.LOAD_ONNX_MODEL
--      and DBMS_VECTOR_CHAIN are present/VALID on this DB.
--      UTL_TO_EMBEDDING database-provider:
--      https://docs.oracle.com/en/database/oracle/oracle-database/26/vecse/utl_to_embedding-and-utl_to_embeddings-dbms_vector_chain.html
--      ONNX import: xx_load_onnx_model.sql (load ALL_MINILM_L12_V2 -> 384-dim).
--
--   Modes exposed here:
--     1. search()      — semantic. Embeds the query with the in-DB ONNX model and
--                        ranks by COSINE distance. Used when an ONNX model is loaded
--                        AND rows have embeddings.
--     2. search_kw()   — keyword token-overlap. Zero dependency fallback; always
--                        works (e.g. before the ONNX model/embeddings are loaded).
--     search() auto-falls back to search_kw() if embeddings/model aren't ready, so
--     the APEX KB page calls ONE function and always returns results.
--
--   NOTE: the COLLECTIONS_KNOWLEDGE_BASE.embedding column is declared VECTOR
--   (unconstrained dims) so it accepts the ONNX model's native dimensionality.
-- =============================================================================

CREATE OR REPLACE PACKAGE xx_kb_search_pkg AS

  -- In-DB ONNX embedding model name (loaded by xx_load_onnx_model.sql)
  c_onnx_model CONSTANT VARCHAR2(60) := 'COLL_EMBED_MODEL';

  TYPE t_kb_row IS RECORD (
    id         NUMBER,
    doc_type   VARCHAR2(50),
    summary    VARCHAR2(500),
    content    VARCHAR2(4000),
    similarity NUMBER
  );
  TYPE t_kb_tab IS TABLE OF t_kb_row;

  -- Generate a query embedding using the in-DB ONNX model.
  FUNCTION embed(p_text IN VARCHAR2) RETURN VECTOR;

  -- True if the ONNX model is loaded and at least one row has an embedding.
  FUNCTION semantic_ready RETURN BOOLEAN;

  -- Default search the APEX page calls. Semantic if ready, else keyword.
  FUNCTION search(p_query IN VARCHAR2, p_top_k IN NUMBER DEFAULT 5)
    RETURN t_kb_tab PIPELINED;

  -- Explicit semantic search by query vector (same space as the loader).
  FUNCTION search_vec(p_qvec IN VECTOR, p_top_k IN NUMBER DEFAULT 5)
    RETURN t_kb_tab PIPELINED;

  -- Keyword token-overlap fallback (no embedding dependency).
  FUNCTION search_kw(p_query IN VARCHAR2, p_top_k IN NUMBER DEFAULT 5)
    RETURN t_kb_tab PIPELINED;

  FUNCTION embedded_count RETURN NUMBER;
  FUNCTION model_loaded   RETURN BOOLEAN;

END xx_kb_search_pkg;
/

CREATE OR REPLACE PACKAGE BODY xx_kb_search_pkg AS

  FUNCTION model_loaded RETURN BOOLEAN AS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM user_mining_models
     WHERE model_name = c_onnx_model;
    RETURN l_n > 0;
  END model_loaded;

  FUNCTION embedded_count RETURN NUMBER AS
    l_n NUMBER;
  BEGIN
    -- COUNT(embedding) is unsupported on VECTOR; count via NULL test instead.
    SELECT COUNT(*) INTO l_n
    FROM   collections_knowledge_base
    WHERE  embedding IS NOT NULL;
    RETURN l_n;
  END embedded_count;

  FUNCTION semantic_ready RETURN BOOLEAN AS
  BEGIN
    RETURN model_loaded AND embedded_count > 0;
  END semantic_ready;

  FUNCTION embed(p_text IN VARCHAR2) RETURN VECTOR AS
    l_params CLOB := '{"provider":"database","model":"'||c_onnx_model||'"}';
  BEGIN
    RETURN DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDING(p_text, JSON(l_params));
  END embed;

  FUNCTION search_vec(p_qvec IN VECTOR, p_top_k IN NUMBER DEFAULT 5)
    RETURN t_kb_tab PIPELINED AS
  BEGIN
    FOR r IN (
      SELECT id, doc_type, summary,
             SUBSTR(content,1,900) content,
             ROUND(1 - VECTOR_DISTANCE(embedding, p_qvec, COSINE), 4) similarity
      FROM   collections_knowledge_base
      WHERE  embedding IS NOT NULL
      ORDER  BY VECTOR_DISTANCE(embedding, p_qvec, COSINE)
      FETCH  FIRST p_top_k ROWS ONLY
    ) LOOP
      PIPE ROW (t_kb_row(r.id, r.doc_type, r.summary, r.content, r.similarity));
    END LOOP;
    RETURN;
  END search_vec;

  FUNCTION search_kw(p_query IN VARCHAR2, p_top_k IN NUMBER DEFAULT 5)
    RETURN t_kb_tab PIPELINED AS
    l_q VARCHAR2(4000) := LOWER(NVL(p_query,''));
  BEGIN
    IF l_q IS NULL THEN RETURN; END IF;
    FOR r IN (
      WITH toks AS (
        SELECT DISTINCT TRIM(REGEXP_SUBSTR(l_q, '[a-z0-9]{3,}', 1, LEVEL)) tok
        FROM   dual
        CONNECT BY REGEXP_SUBSTR(l_q, '[a-z0-9]{3,}', 1, LEVEL) IS NOT NULL
      ),
      tok_list AS (SELECT tok FROM toks WHERE tok IS NOT NULL),
      scored AS (
        SELECT kb.id, kb.doc_type, kb.summary,
               SUBSTR(kb.content,1,900) content,
               (SELECT COUNT(*) FROM tok_list t
                 WHERE INSTR(LOWER(kb.content), t.tok) > 0
                    OR INSTR(LOWER(NVL(kb.summary,'')), t.tok) > 0) hits,
               (SELECT COUNT(*) FROM tok_list) total_toks
        FROM   collections_knowledge_base kb
      )
      SELECT id, doc_type, summary, content,
             CASE WHEN total_toks = 0 THEN 0 ELSE ROUND(hits/total_toks,4) END similarity
      FROM   scored
      WHERE  hits > 0
      ORDER  BY hits DESC, id
      FETCH  FIRST p_top_k ROWS ONLY
    ) LOOP
      PIPE ROW (t_kb_row(r.id, r.doc_type, r.summary, r.content, r.similarity));
    END LOOP;
    RETURN;
  END search_kw;

  FUNCTION search(p_query IN VARCHAR2, p_top_k IN NUMBER DEFAULT 5)
    RETURN t_kb_tab PIPELINED AS
    l_qvec VECTOR;
  BEGIN
    IF p_query IS NULL THEN RETURN; END IF;

    IF semantic_ready THEN
      BEGIN
        l_qvec := embed(p_query);
        FOR r IN (
          SELECT id, doc_type, summary,
                 SUBSTR(content,1,900) content,
                 ROUND(1 - VECTOR_DISTANCE(embedding, l_qvec, COSINE), 4) similarity
          FROM   collections_knowledge_base
          WHERE  embedding IS NOT NULL
          ORDER  BY VECTOR_DISTANCE(embedding, l_qvec, COSINE)
          FETCH  FIRST p_top_k ROWS ONLY
        ) LOOP
          PIPE ROW (t_kb_row(r.id, r.doc_type, r.summary, r.content, r.similarity));
        END LOOP;
        RETURN;
      EXCEPTION WHEN OTHERS THEN
        NULL;  -- fall through to keyword search on any embedding error
      END;
    END IF;

    -- Fallback: keyword search
    FOR r IN (SELECT * FROM TABLE(xx_kb_search_pkg.search_kw(p_query, p_top_k))) LOOP
      PIPE ROW (t_kb_row(r.id, r.doc_type, r.summary, r.content, r.similarity));
    END LOOP;
    RETURN;
  END search;

END xx_kb_search_pkg;
/
