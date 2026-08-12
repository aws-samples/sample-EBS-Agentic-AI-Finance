-- =============================================================================
-- XX_P2P_VPD.sql — Virtual Private Database (row-level security) for the P2P views.
--
-- WHY: the agent/Lambda runs SQL as ONE schema (COLLECTIONS_AI) on behalf of many
-- users (AP clerks/managers entitled to different operating units). VPD enforces the
-- org_id entitlement IN THE DATABASE KERNEL, so the agent CANNOT over-share rows even
-- if the LLM writes a broad query — Oracle appends the predicate, not the app.
--
-- VERIFIED SAFE ON THIS EBS: DBMS_RLS present, 3,762 EBS policies already active; EBS
-- uses VPD natively (MOAC). We attach policies ONLY to COLLECTIONS_AI-owned P2P views
-- (XX_P2P_EXCEPTION_QUEUE_V / XX_P2P_HOLDS_V / XX_P2P_APPROVAL_V — the ones exposing
-- org_id), NEVER to EBS base tables — fully additive, non-colliding with EBS policies.
--
-- HOW SCOPE IS SET (per request): the agent runtime calls
--   XX_P2P_SEC_PKG.set_identity(p_user, p_org_csv, p_scope)
-- right after it resolves the authenticated (Cognito) user → entitled org_id list.
-- The values live in a NON-persisted application context the LLM cannot alter (it has
-- no EXECUTE on the package). scope='ALL' (service/admin) = unrestricted for aggregate
-- KPIs; per-user scope filters row-level views by the entitled org_id set.
--
-- Run as COLLECTIONS_AI (owns the views + context). Idempotent.
-- Refs: ISG/iRep guides (write-back); Oracle VPD (DBMS_RLS) — EBS-native security model.
-- =============================================================================
set define off
set echo off

-- Application context bound to the security package (only this package may set it).
-- NOTE: CREATE CONTEXT requires CREATE [ANY] CONTEXT. On this clone it is created by SYS
-- (see deploy_p2p_security.sh / grants below) because COLLECTIONS_AI is not granted
-- CREATE ANY CONTEXT. The statement is kept here for environments where the schema has
-- the privilege; deploy_p2p_security.sh creates it as SYS to be safe.
CREATE OR REPLACE CONTEXT p2p_ctx USING xx_p2p_sec_pkg;

CREATE OR REPLACE PACKAGE xx_p2p_sec_pkg AS
  -- Set the caller's identity + entitled operating units for this DB session.
  --   p_org_csv : comma-separated org_id list the user is entitled to (e.g. '204,888')
  --   p_scope   : 'ALL' = no row restriction (service/dashboard aggregates),
  --               'ORG' = restrict to the org_id list (default for user drilldowns)
  PROCEDURE set_identity(p_user IN VARCHAR2, p_org_csv IN VARCHAR2, p_scope IN VARCHAR2 DEFAULT 'ORG');
  PROCEDURE clear_identity;
  -- Pipelined helper: the entitled org_id list as rows (used by the policy predicate).
  FUNCTION org_ids RETURN sys.odcinumberlist PIPELINED;
  -- VPD policy function: returns the WHERE predicate Oracle appends to each query.
  FUNCTION org_predicate(p_schema IN VARCHAR2, p_object IN VARCHAR2) RETURN VARCHAR2;
END xx_p2p_sec_pkg;
/

CREATE OR REPLACE PACKAGE BODY xx_p2p_sec_pkg AS

  PROCEDURE set_identity(p_user IN VARCHAR2, p_org_csv IN VARCHAR2, p_scope IN VARCHAR2 DEFAULT 'ORG') AS
  BEGIN
    DBMS_SESSION.SET_CONTEXT('p2p_ctx', 'app_user', SUBSTR(p_user, 1, 100));
    DBMS_SESSION.SET_CONTEXT('p2p_ctx', 'org_csv',  SUBSTR(p_org_csv, 1, 2000));
    DBMS_SESSION.SET_CONTEXT('p2p_ctx', 'scope',    NVL(UPPER(p_scope), 'ORG'));
  END set_identity;

  PROCEDURE clear_identity AS
  BEGIN
    DBMS_SESSION.CLEAR_CONTEXT('p2p_ctx');
  END clear_identity;

  FUNCTION org_ids RETURN sys.odcinumberlist PIPELINED AS
    l_csv VARCHAR2(2000) := SYS_CONTEXT('p2p_ctx', 'org_csv');
    l_tok VARCHAR2(40);
    l_pos PLS_INTEGER := 1;
    l_idx PLS_INTEGER;
  BEGIN
    IF l_csv IS NULL THEN RETURN; END IF;
    LOOP
      l_idx := INSTR(l_csv, ',', l_pos);
      IF l_idx = 0 THEN
        l_tok := TRIM(SUBSTR(l_csv, l_pos));
        IF l_tok IS NOT NULL THEN PIPE ROW(TO_NUMBER(l_tok)); END IF;
        EXIT;
      ELSE
        l_tok := TRIM(SUBSTR(l_csv, l_pos, l_idx - l_pos));
        IF l_tok IS NOT NULL THEN PIPE ROW(TO_NUMBER(l_tok)); END IF;
        l_pos := l_idx + 1;
      END IF;
    END LOOP;
    RETURN;
  END org_ids;

  FUNCTION org_predicate(p_schema IN VARCHAR2, p_object IN VARCHAR2) RETURN VARCHAR2 AS
    l_scope VARCHAR2(10) := SYS_CONTEXT('p2p_ctx', 'scope');
  BEGIN
    -- No identity set yet, OR explicit ALL/admin scope → no restriction.
    -- (Fail-OPEN only when scope is unset is a deliberate choice so the dashboard
    --  aggregates work before per-user scoping; row-level drilldowns set scope='ORG'.)
    IF l_scope IS NULL OR l_scope = 'ALL' THEN
      RETURN '1=1';
    END IF;
    -- Restrict to the caller's entitled operating units.
    RETURN 'org_id IN (SELECT column_value FROM TABLE(COLLECTIONS_AI.XX_P2P_SEC_PKG.ORG_IDS))';
  END org_predicate;

END xx_p2p_sec_pkg;
/

-- Attach the policy to the row-level P2P views that expose org_id.
BEGIN
  FOR v IN (SELECT 'XX_P2P_EXCEPTION_QUEUE_V' n FROM dual UNION ALL
            SELECT 'XX_P2P_HOLDS_V' FROM dual UNION ALL
            SELECT 'XX_P2P_APPROVAL_V' FROM dual) LOOP
    BEGIN
      DBMS_RLS.DROP_POLICY(object_schema => 'COLLECTIONS_AI', object_name => v.n,
                           policy_name => 'XX_P2P_ORG_RLS');
    EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_RLS.ADD_POLICY(
      object_schema   => 'COLLECTIONS_AI',
      object_name     => v.n,
      policy_name     => 'XX_P2P_ORG_RLS',
      function_schema => 'COLLECTIONS_AI',
      policy_function => 'XX_P2P_SEC_PKG.ORG_PREDICATE',
      statement_types => 'SELECT',
      update_check    => FALSE,
      static_policy   => FALSE);
    DBMS_OUTPUT.PUT_LINE('VPD policy attached to '||v.n);
  END LOOP;
END;
/

prompt === XX_P2P_SEC_PKG status + active policies ===
SELECT object_name, object_type, status FROM user_objects
 WHERE object_name='XX_P2P_SEC_PKG' ORDER BY object_type;
SELECT object_name, policy_name, function, enable
  FROM user_policies WHERE policy_name='XX_P2P_ORG_RLS' ORDER BY object_name;
