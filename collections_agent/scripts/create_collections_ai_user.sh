#!/bin/bash
# =============================================================================
# create_collections_ai_user.sh — Create the COLLECTIONS_AI application schema in
# PDB ERPUAT via SSM, as SYSDBA, BEFORE the AI/analytics layer is deployed.
#
# This fills the one prerequisite the rest of the deploy assumes but never creates:
# the COLLECTIONS_AI user, its object-creation privileges, the SELECT AI package
# grants, and SELECT on the AR base tables the collections views + SELECT AI read.
# (AP/PO/RCV/HR grants -> XX_P2P_GRANTS_26ai.sql; VPD -> deploy_p2p_security.sh;
#  ONNX/vector grants -> load_onnx_model.sh.)
#
# Usage:  bash collections_agent/scripts/create_collections_ai_user.sh
# Reads deploy-config.json. Default AWS creds (NO --profile). SSM, login shells.
# Idempotent: re-running reuses an existing user and re-grants safely.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$HERE/../deploy-config.json"
REGION=$(python3 -c "import json;print(json.load(open('$CFG'))['aws_region'])")
DB_INSTANCE=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_instance_id'])")
DB_USER=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_user'])")
DB_PWD=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_password'])")
PDB=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['pdb_name'])")
DB_HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['host'])")
DB_PORT=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['port'])")
SVC=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['service_name'])")
EZ="//${DB_HOST}:${DB_PORT}/${SVC}"
SQL_DIR="$HERE/sql"
SQL_FILE="XX_COLLECTIONS_AI_USER_26ai.sql"

ssm_run() {  # $1 = commands JSON array ; prints StandardOutputContent
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

echo "=== 1. Stage ${SQL_FILE} to DB host /tmp ==="
b64=$(base64 -i "$SQL_DIR/$SQL_FILE" | tr -d '\n')
ssm_run "[\"echo $b64 | base64 -d > /tmp/$SQL_FILE\",\"chmod 644 /tmp/$SQL_FILE\"]" >/dev/null
echo "  staged $SQL_FILE"

echo "=== 2. Create user + grants as SYSDBA (switches to PDB ERPUAT) ==="
# Args are positional SQL*Plus params: &1=user, &2=password, &3=PDB name — so none
# are embedded in the SQL file. Single-quoted inside su -c to keep the shell out of it.
ssm_run "[\"su - oracle -c 'sqlplus -s \\\"/ as sysdba\\\" @/tmp/$SQL_FILE ${DB_USER} ${DB_PWD} ${PDB}' > /tmp/_create_user.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_create_user.out; echo OUTEND\"]"

echo "=== 3. Verify the schema exists (in PDB ${PDB}) ==="
VERIFY="set lines 160 pages 0 feed off\nalter session set container=${PDB};\nSELECT 'USER_EXISTS='||COUNT(*) FROM dba_users WHERE username='${DB_USER}';\nexit\n"
B64V=$(printf "$VERIFY" | base64 | tr -d '\n')
VERIFY_OUT=$(ssm_run "[\"echo $B64V | base64 -d > /tmp/_create_user_verify.sql\",\"su - oracle -c 'sqlplus -s \\\"/ as sysdba\\\" @/tmp/_create_user_verify.sql' 2>&1 | tr -d '\\r'\"]")
echo "$VERIFY_OUT"

echo "=== 4. Verify ${DB_USER} can CONNECT via ${EZ} (the exact path the deploy uses) ==="
CONNTEST="set pages 0 feed off\nSELECT 'CONNECT_OK' FROM dual;\nexit\n"
B64C=$(printf "$CONNTEST" | base64 | tr -d '\n')
CONN_OUT=$(ssm_run "[\"echo $B64C | base64 -d > /tmp/_conn_test.sql\",\"su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@${EZ} @/tmp/_conn_test.sql' 2>&1 | tr -d '\\r'\"]")
echo "$CONN_OUT"

# Halt the deployment unless the schema BOTH exists AND can log in with the config password
# on the deploy's easy-connect path. This stops any DB credential/connection issue here
# instead of cascading into ORA-01017 on the 'database' stage.
if echo "$VERIFY_OUT" | grep -q "USER_EXISTS=1" && echo "$CONN_OUT" | grep -q "CONNECT_OK"; then
  echo "=== COLLECTIONS_AI provisioned and connectivity verified ==="
else
  echo "ERROR: ${DB_USER} is not usable — existence and/or login check failed." >&2
  echo "       USER_EXISTS must be 1 and a login as ${DB_USER}@${EZ} must return CONNECT_OK." >&2
  echo "       See the output above (ORA- errors, CONTAINER=, account_status). Deployment halted." >&2
  exit 1
fi
