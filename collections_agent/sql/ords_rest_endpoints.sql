-- =============================================================================
-- ords_rest_endpoints.sql
-- Publishes SELECT AI as REST endpoints via ORDS (programmatic, scriptable).
-- Run as COLLECTIONS_AI in the ERPUAT PDB.
--
-- Endpoints (base: https://<host>:8443/ords/collections_ai/ai/ ):
--   POST  ai/ask        body {"q":"...", "action":"runsql|showsql|narrate|chat"}
--   GET   ai/dashboard  -> cash position summary (SELECT AI runsql)
--
-- This is the enterprise-grade, UI-agnostic surface: APEX, React, curl, or the
-- Strands agent can all call it. ORDS handles auth (configurable).
-- =============================================================================

BEGIN
  -- Enable the schema for ORDS REST (idempotent)
  ORDS.ENABLE_SCHEMA(
    p_enabled             => TRUE,
    p_schema              => 'COLLECTIONS_AI',
    p_url_mapping_type    => 'BASE_PATH',
    p_url_mapping_pattern => 'collections_ai',
    p_auto_rest_auth      => FALSE);

  -- Module
  ORDS.DEFINE_MODULE(
    p_module_name    => 'collections.ai',
    p_base_path      => '/ai/',
    p_items_per_page => 25,
    p_status         => 'PUBLISHED',
    p_comments       => 'SELECT AI endpoints for EBS Collections');

  -- POST /ai/ask  — natural language to SQL/answer
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'collections.ai',
    p_pattern     => 'ask');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'collections.ai',
    p_pattern     => 'ask',
    p_method      => 'POST',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'[
      DECLARE
        l_q      VARCHAR2(4000) := :q;
        l_action VARCHAR2(30)   := NVL(:action, 'runsql');
        l_out    CLOB;
      BEGIN
        l_out := xx_selectai_pkg.runsql(l_q);
        IF l_action = 'showsql' THEN l_out := xx_selectai_pkg.showsql(l_q);
        ELSIF l_action = 'narrate' THEN l_out := xx_selectai_pkg.narrate(l_q);
        ELSIF l_action = 'chat' THEN l_out := xx_selectai_pkg.chat(l_q);
        END IF;
        :status_code := 200;
        HTP.P(l_out);
      END;
    ]');

  -- GET /ai/dashboard — prebuilt cash-position question
  ORDS.DEFINE_TEMPLATE(
    p_module_name => 'collections.ai',
    p_pattern     => 'dashboard');

  ORDS.DEFINE_HANDLER(
    p_module_name => 'collections.ai',
    p_pattern     => 'dashboard',
    p_method      => 'GET',
    p_source_type => ORDS.source_type_plsql,
    p_source      => q'[
      BEGIN
        :status_code := 200;
        HTP.P(xx_selectai_pkg.runsql(
          'total amount due remaining grouped by customer for open invoices, top 10 by amount'));
      END;
    ]');

  COMMIT;
END;
/
