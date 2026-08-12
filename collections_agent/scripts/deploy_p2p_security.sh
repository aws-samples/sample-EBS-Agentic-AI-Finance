#!/bin/bash
# =============================================================================
# deploy_p2p_security.sh — Deploy the P2P Virtual Private Database (VPD) layer.
#
# Steps (idempotent, via SSM):
#   1. SYS grants to COLLECTIONS_AI: EXECUTE on DBMS_RLS + DBMS_SESSION,
#      ADMINISTER DATABASE TRIGGER. (NOT EXEMPT ACCESS POLICY — that would bypass VPD.)
#   2. SYS creates the application context P2P_CTX bound to COLLECTIONS_AI.XX_P2P_SEC_PKG
#      (COLLECTIONS_AI is not granted CREATE ANY CONTEXT, so SYS creates it).
#   3. COLLECTIONS_AI deploys XX_P2P_VPD.sql (package body + DBMS_RLS policies on the
#      row-level P2P views: EXCEPTION_QUEUE_V, HOLDS_V, APPROVAL_V).
#   4. Verify: policies enabled + a live enforcement test (scope 204 -> 1 org).
#
# Run as: bash collections_agent/scripts/deploy_p2p_security.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$HERE/../deploy-config.json"
REGION=$(python3 -c "import json;print(json.load(open('$CFG'))['aws_region'])")
DB_INSTANCE=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_instance_id'])")
DB_USER=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_user'])")
DB_PWD=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_password'])")
SVC=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['service_name'])")
PDB=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['pdb_name'])")
SQL_DIR="$HERE/sql"

ssm_run() {
  local cid st
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_INSTANCE" \
    --document-name AWS-RunShellScript --timeout-seconds 300 \
    --parameters "commands=$1" --query "Command.CommandId" --output text) || return 1
  for _ in $(seq 1 50); do
    sleep 6
    st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
      --instance-id "$DB_INSTANCE" --query "Status" --output text 2>/dev/null)
    [ "$st" != "InProgress" ] && [ "$st" != "Pending" ] && break
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
    --instance-id "$DB_INSTANCE" --query "StandardOutputContent" --output text
}

echo "=== 1+2. SYS grants + create context (in PDB ${PDB}) ==="
SYSSQL="alter session set container=${PDB};\nGRANT EXECUTE ON DBMS_RLS TO ${DB_USER};\nGRANT EXECUTE ON DBMS_SESSION TO ${DB_USER};\nGRANT ADMINISTER DATABASE TRIGGER TO ${DB_USER};\nCREATE OR REPLACE CONTEXT p2p_ctx USING ${DB_USER}.xx_p2p_sec_pkg;\nSELECT 'CTX '||schema||'.'||package FROM dba_context WHERE namespace='P2P_CTX';\nexit\n"
B64S=$(printf "$SYSSQL" | base64 | tr -d '\n')
ssm_run "[\"echo $B64S | base64 -d > /tmp/_p2psec_sys.sql\",\"su - oracle -c 'sqlplus -s \\\"/ as sysdba\\\" @/tmp/_p2psec_sys.sql' 2>&1 | tr -d '\\r'\"]"

echo "=== 3. Deploy VPD package + policies as ${DB_USER} ==="
b64=$(base64 -i "$SQL_DIR/XX_P2P_VPD.sql" | tr -d '\n')
ssm_run "[\"echo $b64 | base64 -d > /tmp/XX_P2P_VPD.sql\",\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${SVC} @/tmp/XX_P2P_VPD.sql' 2>&1 | tr -d '\\r' | tail -10\"]"

echo "=== 4. Enforcement test (scope 204 must show 1 org) ==="
TEST="set lines 140 pages 0 feed off\nSELECT 'unscoped='||COUNT(DISTINCT org_id) FROM xx_p2p_exception_queue_v;\nEXEC xx_p2p_sec_pkg.set_identity('clerk','204','ORG');\nSELECT 'scoped204_orgs='||COUNT(DISTINCT org_id)||' rows='||COUNT(*) FROM xx_p2p_exception_queue_v;\nEXEC xx_p2p_sec_pkg.set_identity('svc','','ALL');\nSELECT 'ALL='||COUNT(DISTINCT org_id) FROM xx_p2p_exception_queue_v;\nexit\n"
B64T=$(printf "$TEST" | base64 | tr -d '\n')
ssm_run "[\"echo $B64T | base64 -d > /tmp/_p2psec_test.sql\",\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${SVC} @/tmp/_p2psec_test.sql' 2>&1 | tr -d '\\r'\"]"

echo "=== P2P VPD security deploy complete ==="
