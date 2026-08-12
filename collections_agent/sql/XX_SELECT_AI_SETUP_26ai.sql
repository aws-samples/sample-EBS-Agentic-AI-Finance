-- =============================================================================
-- XX_SELECT_AI_SETUP_26ai.sql  (VERIFIED WORKING — 2026-06-24)
-- Complete, repeatable SELECT AI setup for a NON-Autonomous Oracle 26ai PDB.
--
-- Prerequisites (run once, see docs/DETAILED_DESIGN.md Part I §6):
--   1. DBMS_CLOUD installed under C##CLOUD$SERVICE via catclouduser.sql THEN
--      dbms_cloud_install.sql (catcon.pl, --force_pdb_mode 'READ WRITE').
--   2. SSL wallet created at /fd01/ERPUAT/dbms_cloud_wallet with CA certs.
--   3. At CDB$ROOT: HOST ACE + WALLET ACE for C##CLOUD$SERVICE; 
--      ALTER DATABASE PROPERTY SET ssl_wallet='file:/fd01/ERPUAT/dbms_cloud_wallet';
--   4. IAM user with long-lived keys (AKIA...) + bedrock:InvokeModel/Converse.
--
-- Run this connected AS the app schema (e.g. COLLECTIONS_AI) in the PDB.
-- Replace <AKIA...> / <SECRET> with the IAM user's long-lived key/secret.
-- =============================================================================

-- Bedrock credential (long-lived keys ONLY — temp STS ASIA... keys will fail)
BEGIN
  BEGIN DBMS_CLOUD.DROP_CREDENTIAL('AWS_BEDROCK_CRED'); EXCEPTION WHEN OTHERS THEN NULL; END;
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'AWS_BEDROCK_CRED',
    username        => '<AKIA...>',
    password        => '<SECRET>');
END;
/

-- SELECT AI profile — Claude Sonnet 4.5 inference profile (currently active model)
-- Alternatives: us.anthropic.claude-haiku-4-5-20251001-v1:0 ; amazon.nova-pro-v1:0
BEGIN
  BEGIN DBMS_CLOUD_AI.DROP_PROFILE('EBS_COLLECTIONS', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
  DBMS_CLOUD_AI.CREATE_PROFILE(
    profile_name => 'EBS_COLLECTIONS',
    attributes   => '{
      "provider":"aws",
      "credential_name":"AWS_BEDROCK_CRED",
      "model":"us.anthropic.claude-sonnet-4-5-20250929-v1:0",
      "comments":"true",
      "object_list":[
        {"owner":"AR","name":"HZ_PARTIES"},
        {"owner":"AR","name":"HZ_CUST_ACCOUNTS"},
        {"owner":"AR","name":"AR_PAYMENT_SCHEDULES_ALL"},
        {"owner":"AR","name":"RA_CUSTOMER_TRX_ALL"},
        {"owner":"AR","name":"HZ_CUSTOMER_PROFILES"}
      ]
    }');
END;
/

-- Quick verification (expects a JSON row count)
SET SERVEROUTPUT ON
DECLARE
  l CLOB;
BEGIN
  l := DBMS_CLOUD_AI.GENERATE(prompt=>'how many parties are there',
        profile_name=>'EBS_COLLECTIONS', action=>'runsql');
  DBMS_OUTPUT.PUT_LINE('SELECT AI test: '||SUBSTR(l,1,200));
END;
/

-- NOTE: the AR.* tables must be SELECT-granted to this schema (run as SYS):
--   GRANT SELECT ON AR.HZ_PARTIES TO COLLECTIONS_AI;  (etc.)
-- and table/column comments improve SQL generation quality.
