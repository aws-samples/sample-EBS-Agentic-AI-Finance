#!/bin/bash
# =============================================================================
# deploy_p2p_layer.sh — Deploy the Purchase-to-Pay (P2P) DB layer to PDB ERPUAT
# via SSM. Grants (SYS), 8 deterministic XX_P2P_*_V views (COLLECTIONS_AI), and
# the audited APPS.XX_P2P_AP_PKG write-back package. Verifies objects compile VALID.
#
# Usage: bash collections_agent/scripts/deploy_p2p_layer.sh
# Reads deploy-config.json. Default AWS creds (NO --profile). SSM, login shells.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$HERE/../deploy-config.json"
REGION=$(python3 -c "import json;print(json.load(open('$CFG'))['aws_region'])")
DB_INSTANCE=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_instance_id'])")
DB_USER=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_user'])")
DB_PWD=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_password'])")
DB_HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['host'])")
DB_PORT=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['port'])")
SVC=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['service_name'])")
PDB=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['pdb_name'])")
APPS_USER=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_ebs']['apps_user'])")
APPS_PWD=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_ebs']['apps_password'])")
EZ="//${DB_HOST}:${DB_PORT}/${SVC}"
SQL_DIR="$HERE/sql"

ssm_run() {  # $1 = commands JSON array ; prints StandardOutputContent
  local cid st
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_INSTANCE" \
    --document-name AWS-RunShellScript --timeout-seconds 400 \
    --parameters "commands=$1" --query "Command.CommandId" --output text) || return 1
  for _ in $(seq 1 70); do
    sleep 6
    st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
      --instance-id "$DB_INSTANCE" --query "Status" --output text 2>/dev/null)
    [ "$st" != "InProgress" ] && [ "$st" != "Pending" ] && break
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
    --instance-id "$DB_INSTANCE" --query "StandardOutputContent" --output text
}

stage() {  # $1 file ; $2 dest
  local b64; b64=$(base64 -i "$SQL_DIR/$1" | tr -d '\n')
  ssm_run "[\"echo $b64 | base64 -d > /tmp/$1\",\"chmod 644 /tmp/$1\"]" >/dev/null
  echo "  staged $1"
}

echo "=== 1. Stage P2P SQL files to DB host ==="
stage XX_P2P_GRANTS_26ai.sql
stage XX_P2P_VIEWS_26ai.sql
stage XX_P2P_AP_PKG.sql
stage XX_P2P_INGEST_PKG.sql
stage XX_P2P_ANOMALY_PKG.sql
stage XX_WORKING_CAPITAL_PKG.sql
stage XX_POLICY_SETTINGS_26ai.sql
stage XX_P2P_TOLERANCE_RECON_V.sql

echo "=== 2. Grants as SYSDBA (AP/PO/RCV SELECT to ${DB_USER}) ==="
GRANTS_OUT=$(ssm_run "[\"su - oracle -c 'sqlplus -s / as sysdba @/tmp/XX_P2P_GRANTS_26ai.sql ${PDB}' > /tmp/_p2p_grants.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_grants.out; echo OUTEND\"]")
echo "$GRANTS_OUT"
# GATE: a SKIP on any CORE base table means COLLECTIONS_AI cannot compile the views that
# read it (e.g. XX_P2P_HOLDS_V needs AP_HOLDS_ALL/AP_INVOICES_ALL/AP_SUPPLIERS). Stop NOW
# with the real reason instead of cascading into misleading ORA-00942 on the derived views.
CORE_GRANTS="AP.AP_INVOICES_ALL AP.AP_INVOICE_LINES_ALL AP.AP_HOLDS_ALL AP.AP_PAYMENT_SCHEDULES_ALL AP.AP_SUPPLIERS PO.PO_HEADERS_ALL PO.PO_LINES_ALL PO.RCV_TRANSACTIONS"
grant_fail=0
for t in $CORE_GRANTS; do
  if echo "$GRANTS_OUT" | grep -q "GRANT SKIP $t"; then
    echo "ERROR: required SELECT grant did not apply: $t" >&2
    grant_fail=1
  fi
done
if [ "$grant_fail" = "1" ]; then
  echo "Aborting: core AP/PO grants failed, so COLLECTIONS_AI cannot build the P2P views." >&2
  echo "Check the table exists under that owner in PDB ${PDB}, then re-run './deploy.sh database-p2p'." >&2
  exit 1
fi

echo "=== 3. Views (created as SYSDBA into ${DB_USER} schema — deterministic) ==="
# Why SYSDBA + current_schema instead of connecting as COLLECTIONS_AI over SQL*Net:
# in the field, the CREATE OR REPLACE VIEW for XX_P2P_HOLDS_V was intermittently dropped on the
# COLLECTIONS_AI/SQL*Net path (its dependents then failed ORA-00942), even on a second pass —
# while running the IDENTICAL file as SYSDBA with current_schema set to the app schema creates all
# 8 views VALID every time. The views are still OWNED by ${DB_USER} (current_schema), so runtime
# access uses ${DB_USER}'s own grants exactly as before. This makes the P2P view build repeatable.
VWRAP="set define off\nset echo off\nwhenever sqlerror continue\nalter session set container=${PDB};\nalter session set current_schema=${DB_USER};\n@/tmp/XX_P2P_VIEWS_26ai.sql\nexit\n"
B64VW=$(printf "$VWRAP" | base64 | tr -d '\n')
ssm_run "[\"echo $B64VW | base64 -d > /tmp/_p2p_views_wrap.sql\",\"su - oracle -c 'sqlplus -s \\\"/ as sysdba\\\" @/tmp/_p2p_views_wrap.sql' > /tmp/_p2p_views.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_views.out; echo OUTEND\"]"

echo "=== 3b. GATE: all 8 core P2P views must exist and be VALID before building packages ==="
# Each statement is SELF-CONTAINED (the expected-view list is inlined in every query). A
# WITH clause in SQL*Plus only binds to the single statement that immediately follows it,
# so it must NOT be shared across statements. "Not ready" = missing OR not VALID.
VCHK="set lines 200 pages 0 feed off
SELECT 'NOT_READY='||e.n||' ('||NVL((SELECT o.status FROM user_objects o WHERE o.object_name=e.n AND o.object_type='VIEW'),'MISSING')||')'
FROM (SELECT 'XX_P2P_KPI_V' n FROM dual UNION ALL SELECT 'XX_P2P_HOLDS_V' FROM dual UNION ALL
      SELECT 'XX_P2P_MATCH_V' FROM dual UNION ALL SELECT 'XX_P2P_EXCEPTION_QUEUE_V' FROM dual UNION ALL
      SELECT 'XX_P2P_APPROVAL_V' FROM dual UNION ALL SELECT 'XX_P2P_VENDOR_SUMMARY_V' FROM dual UNION ALL
      SELECT 'XX_P2P_PIPELINE_V' FROM dual UNION ALL SELECT 'XX_P2P_AGING_V' FROM dual) e
WHERE NOT EXISTS (SELECT 1 FROM user_objects o WHERE o.object_name=e.n AND o.object_type='VIEW' AND o.status='VALID');
SELECT CASE WHEN (
  SELECT COUNT(*) FROM (SELECT 'XX_P2P_KPI_V' n FROM dual UNION ALL SELECT 'XX_P2P_HOLDS_V' FROM dual UNION ALL
      SELECT 'XX_P2P_MATCH_V' FROM dual UNION ALL SELECT 'XX_P2P_EXCEPTION_QUEUE_V' FROM dual UNION ALL
      SELECT 'XX_P2P_APPROVAL_V' FROM dual UNION ALL SELECT 'XX_P2P_VENDOR_SUMMARY_V' FROM dual UNION ALL
      SELECT 'XX_P2P_PIPELINE_V' FROM dual UNION ALL SELECT 'XX_P2P_AGING_V' FROM dual) e
  WHERE NOT EXISTS (SELECT 1 FROM user_objects o WHERE o.object_name=e.n AND o.object_type='VIEW' AND o.status='VALID')
) = 0 THEN 'GATE_OK' ELSE 'GATE_FAIL' END FROM dual;
exit"
B64VC=$(printf '%s' "$VCHK" | base64 | tr -d '\n')
VCHK_OUT=$(ssm_run "[\"echo $B64VC | base64 -d > /tmp/_p2p_vcheck.sql\",\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${EZ} @/tmp/_p2p_vcheck.sql' 2>&1 | tr -d '\\r'\"]")
echo "$VCHK_OUT"
if ! echo "$VCHK_OUT" | grep -q "GATE_OK"; then
  echo "ERROR: one or more P2P views are missing/invalid (see NOT_READY= lines above)." >&2
  echo "Not building packages on a broken base. Most common cause: XX_P2P_HOLDS_V failed to" >&2
  echo "compile (a required AP/PO grant, or a base object missing in PDB ${PDB}), which cascades" >&2
  echo "into its dependent views. Fix the flagged view's dependency, then re-run './deploy.sh database-p2p'." >&2
  exit 1
fi
echo "  GATE passed — all 8 core P2P views VALID; proceeding to packages."

echo "=== 4. Audited AP package as APPS ==="
ssm_run "[\"su - oracle -c 'sqlplus -s ${APPS_USER}/${APPS_PWD}@${EZ} @/tmp/XX_P2P_AP_PKG.sql' > /tmp/_p2p_pkg.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_pkg.out; echo OUTEND\"]"

echo "=== 4b. Register AI_AGENT_P2P SOURCE lookup + ingest package as APPS ==="
SRCSQL="set lines 120 pages 0 feed off serveroutput on\nDECLARE n NUMBER; l_rowid VARCHAR2(64); BEGIN\n  SELECT COUNT(*) INTO n FROM apps.ap_lookup_codes WHERE lookup_type='SOURCE' AND lookup_code='AI_AGENT_P2P';\n  IF n=0 THEN\n    FND_LOOKUP_VALUES_PKG.INSERT_ROW(x_rowid=>l_rowid,x_lookup_type=>'SOURCE',x_security_group_id=>0,x_view_application_id=>200,x_lookup_code=>'AI_AGENT_P2P',x_tag=>NULL,x_attribute_category=>NULL,x_attribute1=>NULL,x_attribute2=>NULL,x_attribute3=>NULL,x_attribute4=>NULL,x_enabled_flag=>'Y',x_start_date_active=>NULL,x_end_date_active=>NULL,x_territory_code=>NULL,x_attribute5=>NULL,x_attribute6=>NULL,x_attribute7=>NULL,x_attribute8=>NULL,x_attribute9=>NULL,x_attribute10=>NULL,x_attribute11=>NULL,x_attribute12=>NULL,x_attribute13=>NULL,x_attribute14=>NULL,x_attribute15=>NULL,x_meaning=>'AI Agent P2P',x_description=>'Invoices ingested by the P2P AI agent',x_creation_date=>SYSDATE,x_created_by=>0,x_last_update_date=>SYSDATE,x_last_updated_by=>0,x_last_update_login=>0);\n    COMMIT; DBMS_OUTPUT.PUT_LINE('SOURCE created');\n  ELSE DBMS_OUTPUT.PUT_LINE('SOURCE exists'); END IF;\nEXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('src '||SQLERRM); END;\n/\nexit\n"
B64SRC=$(printf "$SRCSQL" | base64 | tr -d '\n')
ssm_run "[\"echo $B64SRC | base64 -d > /tmp/_p2p_src.sql\",\"su - oracle -c 'sqlplus -s ${APPS_USER}/${APPS_PWD}@${EZ} @/tmp/_p2p_src.sql' 2>&1 | tr -d '\\r'\"]"
ssm_run "[\"su - oracle -c 'sqlplus -s ${APPS_USER}/${APPS_PWD}@${EZ} @/tmp/XX_P2P_INGEST_PKG.sql' > /tmp/_p2p_ing.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_ing.out | tail -8; echo OUTEND\"]"

echo "=== 4d. Duplicate/fraud anomaly package as APPS (reads AP + staging) ==="
ssm_run "[\"su - oracle -c 'sqlplus -s ${APPS_USER}/${APPS_PWD}@${EZ} @/tmp/XX_P2P_ANOMALY_PKG.sql' > /tmp/_p2p_anom.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_anom.out | tail -8; echo OUTEND\"]"

echo "=== 4e. Working-capital analytics package as ${DB_USER} (reads XX_COLL_*_V + XX_P2P_*_V) ==="
ssm_run "[\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${EZ} @/tmp/XX_WORKING_CAPITAL_PKG.sql' > /tmp/_p2p_wc.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_wc.out | tail -8; echo OUTEND\"]"

echo "=== 4e2. Policy-of-record settings table as ${DB_USER} (drives the recon view + Sync from EBS) ==="
ssm_run "[\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${EZ} @/tmp/XX_POLICY_SETTINGS_26ai.sql' > /tmp/_p2p_polset.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_polset.out | tail -10; echo OUTEND\"]"

echo "=== 4f. Policy-vs-EBS tolerance reconciliation view as ${DB_USER} (needs AP tolerance grants + settings table) ==="
ssm_run "[\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${EZ} @/tmp/XX_P2P_TOLERANCE_RECON_V.sql' > /tmp/_p2p_tolrecon.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_tolrecon.out | tail -8; echo OUTEND\"]"

echo "=== 4c. Grant EXECUTE on P2P packages to ${DB_USER} (agent/Lambda caller) ==="
GR="BEGIN EXECUTE IMMEDIATE 'GRANT EXECUTE ON APPS.XX_P2P_AP_PKG TO ${DB_USER}'; EXECUTE IMMEDIATE 'GRANT EXECUTE ON APPS.XX_P2P_INGEST_PKG TO ${DB_USER}'; EXECUTE IMMEDIATE 'GRANT EXECUTE ON APPS.XX_P2P_ANOMALY_PKG TO ${DB_USER}'; EXECUTE IMMEDIATE 'GRANT SELECT ON APPS.XX_P2P_STAGING TO ${DB_USER}'; END;\n/\nexit\n"
B64GR=$(printf "$GR" | base64 | tr -d '\n')
ssm_run "[\"echo $B64GR | base64 -d > /tmp/_p2p_grant.sql\",\"su - oracle -c 'sqlplus -s ${APPS_USER}/${APPS_PWD}@${EZ} @/tmp/_p2p_grant.sql' 2>&1 | tr -d '\\r'\"]"

echo "=== 4g. Self-heal: re-run views (idempotent) + recompile dependent packages ==="
# The P2P view DDL is order-sensitive — XX_P2P_EXCEPTION_QUEUE_V and XX_P2P_VENDOR_SUMMARY_V
# select FROM XX_P2P_HOLDS_V, and the packages read those views. A single missed CREATE (seen
# in the field) therefore cascades into ORA-00942/ORA-04063 in the packages and the UI. Re-running
# the views file (CREATE OR REPLACE = idempotent) recreates anything that missed, then we recompile
# the two dependent packages. This makes the layer converge to VALID even after a transient miss.
ssm_run "[\"su - oracle -c 'sqlplus -s \\\"/ as sysdba\\\" @/tmp/_p2p_views_wrap.sql' > /tmp/_p2p_views2.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_p2p_views2.out | tail -4; echo OUTEND\"]"
RECOMP="set lines 200 pages 0 feed off\nalter session set container=${PDB};\nalter package APPS.XX_P2P_AP_PKG compile body;\nalter package ${DB_USER}.XX_WORKING_CAPITAL_PKG compile body;\nexit\n"
B64RC=$(printf "$RECOMP" | base64 | tr -d '\n')
ssm_run "[\"echo $B64RC | base64 -d > /tmp/_p2p_recomp.sql\",\"su - oracle -c 'sqlplus -s \\\"/ as sysdba\\\" @/tmp/_p2p_recomp.sql' 2>&1 | tr -d '\\r'\"]"

echo "=== 5. Final object status ==="
VERIFY="set lines 200 pages 0 feed off
prompt --- COLLECTIONS_AI P2P views ---
select object_name||' '||status from all_objects where owner='COLLECTIONS_AI' and object_name like 'XX_P2P%' order by 1;
prompt --- APPS P2P package ---
select object_name||' '||object_type||' '||status from all_objects where owner='APPS' and object_name in ('XX_P2P_AP_PKG','XX_P2P_INGEST_PKG','XX_P2P_ANOMALY_PKG') order by 1,2;
prompt --- COLLECTIONS_AI working-capital package ---
select object_name||' '||object_type||' '||status from all_objects where owner='COLLECTIONS_AI' and object_name='XX_WORKING_CAPITAL_PKG' order by 2;
prompt --- health (both MUST be 0 for a working P2P layer) ---
select 'MISSING_VIEWS='||count(*) from (select 'XX_P2P_KPI_V' n from dual union all select 'XX_P2P_HOLDS_V' from dual union all select 'XX_P2P_MATCH_V' from dual union all select 'XX_P2P_EXCEPTION_QUEUE_V' from dual union all select 'XX_P2P_APPROVAL_V' from dual union all select 'XX_P2P_VENDOR_SUMMARY_V' from dual union all select 'XX_P2P_PIPELINE_V' from dual union all select 'XX_P2P_AGING_V' from dual) e where not exists (select 1 from all_objects o where o.owner='COLLECTIONS_AI' and o.object_name=e.n);
select 'INVALID_P2P='||count(*) from all_objects where object_name like 'XX_P2P%' and status='INVALID';
select 'INVALID_WCAP='||count(*) from all_objects where owner='COLLECTIONS_AI' and object_name='XX_WORKING_CAPITAL_PKG' and status='INVALID';
exit"
B64V=$(printf '%s' "$VERIFY" | base64 | tr -d '\n')
ssm_run "[\"echo $B64V | base64 -d > /tmp/_p2p_verify.sql\",\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${EZ} @/tmp/_p2p_verify.sql' 2>&1 | tr -d '\\r'\"]"

echo "=== P2P DB layer deploy complete ==="
