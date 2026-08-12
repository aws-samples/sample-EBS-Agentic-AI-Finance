#!/bin/bash
# =============================================================================
# deploy_ai_layer.sh — Deploy the 26ai AI/analytics layer to the COLLECTIONS_AI
# schema in PDB ERPUAT on the clone DB node, end-to-end via SSM.
#
# Deploys (idempotent): KB vector table, 6 deterministic views, xx_selectai_pkg,
# xx_kb_search_pkg, seeds 9 KB docs, then REFRESHES their content + re-embeds
# (XX_KB_REFRESH_26ai.sql — updates existing rows the insert-only seed can't reach, so
# content edits reach an already-seeded DB). Verifies every object compiles VALID.
#
# Usage:  bash collections_agent/scripts/deploy_ai_layer.sh
# Reads config from deploy-config.json. Default AWS creds (NO --profile).
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
# APPS creds — the audited AR write-back package (XX_COLLECTIONS_REST_PKG) is APPS-owned and is
# compiled below so a single ./deploy.sh provisions collections write-back end-to-end.
APPS_USER=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_ebs'].get('apps_user','APPS'))")
APPS_PWD=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_ebs']['apps_password'])")
EZ="//${DB_HOST}:${DB_PORT}/${SVC}"
SQL_DIR="$HERE/sql"

FILES=(
  "XX_KB_TABLE_SETUP_26ai.sql"
  "xx_collections_views.sql"
  "xx_selectai_pkg.sql"
  "xx_kb_search_pkg.sql"
  "XX_KB_SEED_26ai.sql"
  "XX_KB_REFRESH_26ai.sql"
)

ssm_run() {  # $1 = commands JSON array ; prints stdout
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

echo "=== 1. Transfer SQL files to DB host /tmp ==="
for f in "${FILES[@]}"; do
  b64=$(base64 -i "$SQL_DIR/$f" | tr -d '\n')
  ssm_run "[\"echo $b64 | base64 -d > /tmp/$f\",\"chmod 644 /tmp/$f\"]" >/dev/null
  echo "  staged $f"
done

echo "=== 2. Build master + run as $DB_USER@$SVC ==="
MASTER="set echo off feed off lines 200 pages 0 serveroutput on size unlimited\nset define off\nwhenever sqlerror continue\n"
for f in "${FILES[@]}"; do MASTER="$MASTER@/tmp/$f\n"; done
MASTER="${MASTER}prompt === OBJECT STATUS ===\ncol object_name format a30\ncol object_type format a14\nselect object_name,object_type,status from user_objects where object_type in ('VIEW','PACKAGE','PACKAGE BODY','TABLE') order by object_type,object_name;\nselect 'INVALID='||count(*) from user_objects where status='INVALID';\nexit\n"
B64M=$(printf "$MASTER" | base64 | tr -d '\n')
# NLS_LANG=...AL32UTF8 forces a UTF-8 client session so multibyte characters in the KB
# content (e.g. em dashes, currency/accented chars) insert cleanly instead of becoming
# mojibake (???). Keeps the seed robust regardless of the doc text — safe for customer deploys.
RUN="echo $B64M | base64 -d > /tmp/_ai_master.sql; chmod 644 /tmp/_ai_master.sql; su - oracle -c 'export NLS_LANG=AMERICAN_AMERICA.AL32UTF8; sqlplus -s ${DB_USER}/${DB_PWD}@${EZ} @/tmp/_ai_master.sql' > /tmp/_ai_deploy.out 2>&1; echo OUTSTART; tr -d '\\r' < /tmp/_ai_deploy.out; echo OUTEND"
AI_OUT=$(ssm_run "[\"$RUN\"]")
echo "$AI_OUT"

# Fail hard on a login failure instead of falsely reporting success. ORA-01017 means the
# COLLECTIONS_AI login was rejected — run './deploy.sh db-user' first (it creates the schema
# and syncs its password to deploy-config).
if echo "$AI_OUT" | grep -q "ORA-01017"; then
  echo "ERROR: COLLECTIONS_AI login denied (ORA-01017). Run './deploy.sh db-user' first, then re-run 'database'." >&2
  exit 1
fi
# Also surface invalid objects (non-zero INVALID= count) as a failure.
if echo "$AI_OUT" | grep -qE "INVALID=[1-9]"; then
  echo "ERROR: one or more COLLECTIONS_AI objects compiled INVALID (see status above)." >&2
  exit 1
fi

echo "=== 3. Audited AR write-back package as APPS (XX_COLLECTIONS_REST_PKG) ==="
# The AR write-back package (place/release credit hold, collections note, dunning) is APPS-owned
# and is called by the Collections Lambda over oracledb AS COLLECTIONS_AI. Historically it was only
# compiled by the app-tier deploy_all_rest_services.sh, so a standard ./deploy.sh left it missing and
# create_collections_note / credit-hold actions failed. Compile it here as APPS (the file also
# self-creates its apps.xx_collections_notes audit table) and grant EXECUTE to COLLECTIONS_AI, so a
# single ./deploy.sh provisions collections write-back end-to-end — no ISG/iRep app-tier step needed
# for the default (oracledb callproc) path.
CRP="XX_COLLECTIONS_REST_PKG.sql"
b64=$(base64 -i "$SQL_DIR/$CRP" | tr -d '\n')
ssm_run "[\"echo $b64 | base64 -d > /tmp/$CRP\",\"chmod 644 /tmp/$CRP\"]" >/dev/null
CRP_OUT=$(ssm_run "[\"su - oracle -c 'sqlplus -s ${APPS_USER}/${APPS_PWD}@${EZ} @/tmp/$CRP' > /tmp/_crp.out 2>&1; echo OUTSTART; tr -d \\\"\\r\\\" < /tmp/_crp.out | tail -30; echo OUTEND\"]")
echo "$CRP_OUT"

# Fail hard on a login failure or a package-body compilation error (either means write-back is broken).
if echo "$CRP_OUT" | grep -q "ORA-01017"; then
  echo "ERROR: APPS login denied (ORA-01017) — check oracle_ebs.apps_password in deploy-config.json." >&2
  exit 1
fi
if echo "$CRP_OUT" | grep -qi "compilation errors"; then
  echo "ERROR: APPS.XX_COLLECTIONS_REST_PKG compiled with errors — collections write-back will fail." >&2
  exit 1
fi

# Grant EXECUTE to the app schema (the Lambda connects as COLLECTIONS_AI and callprocs this package).
GRANT_SQL="whenever sqlerror continue\nGRANT EXECUTE ON APPS.XX_COLLECTIONS_REST_PKG TO ${DB_USER};\nprompt GRANT_DONE\nexit\n"
B64G=$(printf "$GRANT_SQL" | base64 | tr -d '\n')
GR_OUT=$(ssm_run "[\"echo $B64G | base64 -d > /tmp/_crp_grant.sql\",\"su - oracle -c 'sqlplus -s ${APPS_USER}/${APPS_PWD}@${EZ} @/tmp/_crp_grant.sql' 2>&1 | tr -d '\\r'\"]")
echo "$GR_OUT"
if ! echo "$GR_OUT" | grep -q "GRANT_DONE"; then
  echo "ERROR: could not GRANT EXECUTE on APPS.XX_COLLECTIONS_REST_PKG to ${DB_USER}." >&2
  exit 1
fi
echo "  ✓ XX_COLLECTIONS_REST_PKG compiled as APPS + EXECUTE granted to ${DB_USER}."
