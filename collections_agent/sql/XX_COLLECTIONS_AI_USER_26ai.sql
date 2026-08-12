-- =============================================================================
-- XX_COLLECTIONS_AI_USER_26ai.sql
-- Create the COLLECTIONS_AI application schema + its base privileges and the AR
-- base-table SELECT grants the collections views + SELECT AI profile depend on.
--
-- WHY THIS EXISTS
--   The rest of the deploy (deploy_ai_layer.sh, deploy_p2p_layer.sh, ...) connects
--   AS COLLECTIONS_AI and assumes the schema already exists — but nothing in the
--   repo created it. This script is that missing prerequisite. Run it ONCE, first.
--
-- SCOPE / SECURITY
--   * Read-only on EBS data: only SELECT is granted on the AR.* base tables below.
--     No INSERT/UPDATE/DELETE on EBS — every write goes through the audited APPS
--     packages (XX_P2P_AP_PKG / XX_COLLECTIONS_REST_PKG), consistent with the
--     solution's "LLM is never the security boundary" posture.
--   * AP/PO/RCV/HR SELECT grants are handled separately by XX_P2P_GRANTS_26ai.sql.
--   * VPD privileges (DBMS_RLS/DBMS_SESSION, context) are handled by
--     deploy_p2p_security.sh. ONNX/vector grants are handled by load_onnx_model.sh.
--
-- RUN AS: SYSDBA inside the CDB. This script switches container to PDB ERPUAT
--   (the AR/AP/PO tables live in the PDB, not CDB$ROOT).
--
-- USAGE (non-interactive):
--   sqlplus -s "/ as sysdba" @XX_COLLECTIONS_AI_USER_26ai.sql <DB_USER> <DB_PASSWORD> <PDB_NAME>
--
-- Idempotent: creates the user if missing, else re-syncs its password to the
--   deploy-config value; all GRANTs re-run safely.
-- =============================================================================
set echo off
set feedback off
set verify off
set pagesize 0
set serveroutput on size unlimited
whenever sqlerror continue

define v_user = &1
define v_pwd  = &2
define v_pdb  = &3

-- 1. Switch to the PDB. SYSDBA via OS auth ("/ as sysdba") connects to CDB$ROOT, and a
--    container switch is NOT reliable inside a PL/SQL block — so do it as a top-level
--    SQL*Plus statement (it persists for the rest of the script). The SELECT below
--    prints the resulting container so a wrong/closed PDB is obvious in the log.
ALTER SESSION SET CONTAINER=&v_pdb;
SELECT 'CONTAINER='||SYS_CONTEXT('USERENV','CON_NAME') FROM dual;

-- 2. Create the schema if missing; if it already exists, sync its password to the
--    deploy-config value so a stale password from a prior run cannot cause ORA-01017.
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = UPPER('&v_user');
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER "'||UPPER('&v_user')||'" IDENTIFIED BY "&v_pwd"';
    DBMS_OUTPUT.PUT_LINE('CREATE USER ok: &v_user');
  ELSE
    EXECUTE IMMEDIATE 'ALTER USER "'||UPPER('&v_user')||'" IDENTIFIED BY "&v_pwd"';
    DBMS_OUTPUT.PUT_LINE('User &v_user exists - password synced to deploy-config value.');
  END IF;
END;
/

-- 2b. Give the schema a DEDICATED ASSM tablespace with AUTOEXTEND as its default, and never
--     land COLLECTIONS_AI objects in an EBS tablespace (e.g. APPS_OMO). Two reasons:
--       * The ~133MB in-DB ONNX embedding model LOB (loaded later by load_onnx_model.sh) will
--         exhaust a fixed EBS tablespace → ORA-01652 "unable to grow lob ... in APPS_OMO".
--       * JSON/VECTOR columns require ASSM (ORA-43853 in MSSM tablespaces such as SYSTEM).
--     Create COLLECTIONS_AI_TS if missing (SYSDBA), reusing the datafile directory of an
--     existing datafile (filesystem DBs), then make it the schema's default with full quota.
DECLARE
  v_dir VARCHAR2(700);
BEGIN
  SELECT SUBSTR(file_name, 1, INSTR(file_name, '/', -1)) INTO v_dir
    FROM (SELECT file_name FROM dba_data_files ORDER BY file_id) WHERE ROWNUM = 1;
  EXECUTE IMMEDIATE 'CREATE TABLESPACE COLLECTIONS_AI_TS DATAFILE '''||v_dir
                    ||'collections_ai_ts01.dbf'' SIZE 64M AUTOEXTEND ON NEXT 64M MAXSIZE 4G';
  DBMS_OUTPUT.PUT_LINE('Created tablespace COLLECTIONS_AI_TS at '||v_dir);
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1543 THEN                 -- ORA-01543: tablespace already exists → reuse
    DBMS_OUTPUT.PUT_LINE('Tablespace COLLECTIONS_AI_TS already exists - reusing.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('WARN: could not create COLLECTIONS_AI_TS: '||SQLERRM);
  END IF;
END;
/
-- Set it as the default (runs whether the tablespace was just created or already existed).
ALTER USER "&v_user" DEFAULT TABLESPACE COLLECTIONS_AI_TS QUOTA UNLIMITED ON COLLECTIONS_AI_TS;

-- 3. System privileges needed to build the AI/analytics layer.
--    (CREATE MINING MODEL + DBMS_VECTOR* are granted by load_onnx_model.sh; not here.)
GRANT CREATE SESSION       TO &v_user;
GRANT CREATE TABLE         TO &v_user;
GRANT CREATE VIEW          TO &v_user;
GRANT CREATE PROCEDURE     TO &v_user;
GRANT CREATE SEQUENCE      TO &v_user;
-- Demo convenience; for production, replace with a bounded quota on a named tablespace:
--   ALTER USER <user> QUOTA 500M ON <tablespace>;
GRANT UNLIMITED TABLESPACE TO &v_user;

-- 4. SELECT AI packages (best-effort — requires DBMS_CLOUD/DBMS_CLOUD_AI already
--    installed under C##CLOUD$SERVICE per the DETAILED_DESIGN prerequisites). These
--    let xx_selectai_pkg compile VALID and the EBS_COLLECTIONS profile be created.
BEGIN EXECUTE IMMEDIATE 'GRANT EXECUTE ON DBMS_CLOUD TO &v_user';
EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('DBMS_CLOUD grant skip: '||SQLERRM); END;
/
BEGIN EXECUTE IMMEDIATE 'GRANT EXECUTE ON DBMS_CLOUD_AI TO &v_user';
EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('DBMS_CLOUD_AI grant skip: '||SQLERRM); END;
/

-- 5. SELECT on the AR base tables the deterministic collections views and the
--    SELECT AI object_list read (see xx_collections_views.sql / XX_SELECT_AI_SETUP_26ai.sql).
BEGIN
  FOR r IN (
    SELECT 'AR' owner, 'HZ_PARTIES'              tab FROM dual UNION ALL
    SELECT 'AR',       'HZ_CUST_ACCOUNTS'            FROM dual UNION ALL
    SELECT 'AR',       'AR_PAYMENT_SCHEDULES_ALL'    FROM dual UNION ALL
    SELECT 'AR',       'RA_CUSTOMER_TRX_ALL'         FROM dual UNION ALL
    SELECT 'AR',       'HZ_CUSTOMER_PROFILES'        FROM dual
  ) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'GRANT SELECT ON '||r.owner||'.'||r.tab||' TO &v_user';
      DBMS_OUTPUT.PUT_LINE('GRANT OK   '||r.owner||'.'||r.tab);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('GRANT SKIP '||r.owner||'.'||r.tab||' -> '||SQLERRM);
    END;
  END LOOP;
END;
/

prompt === COLLECTIONS_AI schema provisioning complete ===
exit
