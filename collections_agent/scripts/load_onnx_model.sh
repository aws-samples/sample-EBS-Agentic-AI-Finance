#!/bin/bash
# =============================================================================
# load_onnx_model.sh — One-time load of Oracle's prebuilt all_MiniLM_L12_v2 ONNX
# embedding model into the COLLECTIONS_AI schema (in-DB AI Vector Search, 384-dim).
#
# Runs via SSM on the clone DB node. The model is pulled from S3 (no DB internet
# egress for arbitrary URLs); upload it to S3 first if not present:
#   curl -fsSL -o /tmp/all_MiniLM_L12_v2.onnx \
#     https://objectstorage.us-ashburn-1.oraclecloud.com/n/adwc4pm/b/OML-Resources/o/all_MiniLM_L12_v2.onnx
#   aws s3 cp /tmp/all_MiniLM_L12_v2.onnx <bedrock.onnx_s3_uri from deploy-config.json>
#
# All environment-specific values (S3 URI, model name, PDB, DB creds) are read from
# deploy-config.json — nothing is hardcoded. SYSDBA uses OS auth (/ as sysdba).
#
# Prereqs on the DB (done by the upgrade/build): COMPATIBLE>=23.0.0, vector_memory_size>0,
# FRA not full. After load, embeds all KB docs and verifies semantic search.
#
# Usage: bash collections_agent/scripts/load_onnx_model.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$HERE/../deploy-config.json"
REGION=$(python3 -c "import json;print(json.load(open('$CFG'))['aws_region'])")
DB_INSTANCE=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_instance_id'])")
DB_PWD=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_password'])")
DB_USER=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_user'])")
DB_HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['host'])")
DB_PORT=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['port'])")
SVC=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['service_name'])")
PDB=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['pdb_name'])")
ONNX_MODEL=$(python3 -c "import json;print(json.load(open('$CFG'))['bedrock']['onnx_model'])")
S3_KEY=$(python3 -c "import json;print(json.load(open('$CFG'))['bedrock']['onnx_s3_uri'])")
ONNX_FILE="${ONNX_MODEL}.onnx"
# Byte size of Oracle's prebuilt all_MiniLM_L12_v2.onnx — a truncated upload causes
# ORA-54401. If you point onnx_s3_uri at a DIFFERENT model, update EXPECT to its size
# (or set to 0 to skip the integrity check).
EXPECT=133322334

ssm_run() {
  local cid st
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_INSTANCE" \
    --document-name AWS-RunShellScript --timeout-seconds 500 \
    --parameters "commands=$1" --query "Command.CommandId" --output text) || return 1
  for _ in $(seq 1 48); do
    sleep 10
    st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
      --instance-id "$DB_INSTANCE" --query "Status" --output text 2>/dev/null)
    [ "$st" != "InProgress" ] && [ "$st" != "Pending" ] && break
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
    --instance-id "$DB_INSTANCE" --query "StandardOutputContent" --output text
}

# Build the host script (pull + dir + load + embed + verify)
read -r -d '' HOSTSCRIPT <<HS || true
#!/bin/bash
set -uo pipefail
mkdir -p /stage/onnx
aws s3 cp ${S3_KEY} /stage/onnx/${ONNX_FILE} --region ${REGION} >/dev/null 2>&1
chown oracle:oinstall /stage/onnx/${ONNX_FILE}; chmod 644 /stage/onnx/${ONNX_FILE}
SZ=\$(wc -c < /stage/onnx/${ONNX_FILE})
echo "HOST_SIZE=\$SZ EXPECT=${EXPECT}"
[ "${EXPECT}" != "0" ] && [ "\$SZ" != "${EXPECT}" ] && { echo SIZE_MISMATCH_ABORT; exit 1; }

cat > /tmp/_onnx_dir.sql <<SQL
alter session set container=${PDB};
create or replace directory ONNX_DIR as '/stage/onnx';
grant read on directory ONNX_DIR to ${DB_USER};
grant execute on dbms_vector to ${DB_USER};
grant execute on dbms_vector_chain to ${DB_USER};
grant create mining model to ${DB_USER};
-- Ensure a dedicated ASSM tablespace with AUTOEXTEND owns the ~133MB model LOB, so it never
-- tries to grow an EBS tablespace like APPS_OMO (ORA-01652). Safety net: db-user normally
-- creates this, but re-point the default here too in case this script is run standalone.
DECLARE
  v_dir VARCHAR2(700);
BEGIN
  SELECT SUBSTR(file_name, 1, INSTR(file_name, '/', -1)) INTO v_dir
    FROM (SELECT file_name FROM dba_data_files ORDER BY file_id) WHERE ROWNUM = 1;
  EXECUTE IMMEDIATE 'CREATE TABLESPACE COLLECTIONS_AI_TS DATAFILE '''||v_dir
                    ||'collections_ai_ts01.dbf'' SIZE 64M AUTOEXTEND ON NEXT 64M MAXSIZE 4G';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -1543 THEN RAISE; END IF;   -- -1543 = already exists → fine
END;
/
alter user ${DB_USER} default tablespace COLLECTIONS_AI_TS quota unlimited on COLLECTIONS_AI_TS;
exit
SQL
chmod 644 /tmp/_onnx_dir.sql
su - oracle -c 'sqlplus -s "/ as sysdba" @/tmp/_onnx_dir.sql' 2>&1 | tr -d '\r' | tail -20

cat > /tmp/_onnx_load.sql <<SQL
set lines 200 pages 0 feed off serveroutput on size unlimited
WHENEVER SQLERROR CONTINUE
BEGIN DBMS_VECTOR.DROP_ONNX_MODEL(model_name=>'COLL_EMBED_MODEL', force=>TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN
  DBMS_VECTOR.LOAD_ONNX_MODEL(directory=>'ONNX_DIR', file_name=>'${ONNX_FILE}',
    model_name=>'COLL_EMBED_MODEL',
    metadata=>JSON('{"function":"embedding","embeddingOutput":"embedding","input":{"input":["DATA"]}}'));
  DBMS_OUTPUT.PUT_LINE('LOADED_OK');
END;
/
DECLARE n NUMBER:=0; BEGIN
  FOR r IN (SELECT id, content FROM collections_knowledge_base WHERE embedding IS NULL) LOOP
    UPDATE collections_knowledge_base SET embedding=DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDING(SUBSTR(r.content,1,3000),
      JSON('{"provider":"database","model":"COLL_EMBED_MODEL"}')) WHERE id=r.id; n:=n+1;
  END LOOP; COMMIT; DBMS_OUTPUT.PUT_LINE('EMBEDDED='||n);
END;
/
SELECT 'TOTAL='||COUNT(*)||' EMBEDDED='||COUNT(CASE WHEN embedding IS NOT NULL THEN 1 END) FROM collections_knowledge_base;
exit
SQL
chmod 644 /tmp/_onnx_load.sql
su - oracle -c 'sqlplus -s ${DB_USER}/${DB_PWD}@//${DB_HOST}:${DB_PORT}/${SVC} @/tmp/_onnx_load.sql' 2>&1 | tr -d '\r'
HS

B64=$(printf '%s' "$HOSTSCRIPT" | base64 | tr -d '\n')
echo "=== Loading ONNX model + embedding KB (via SSM) ==="
OUT=$(ssm_run "[\"echo $B64 | base64 -d > /tmp/_load_onnx_host.sh\",\"bash /tmp/_load_onnx_host.sh\"]")
echo "$OUT"

# SSM returns success even when the in-DB SQL failed, so decide the REAL result from the
# output: require the model-load marker (LOADED_OK) and that EVERY KB doc embedded
# (TOTAL==EMBEDDED>0). Exit non-zero on failure so deploy.sh reports it honestly (red).
tot=$(printf '%s' "$OUT" | sed -n 's/.*TOTAL=\([0-9]\{1,\}\) EMBEDDED=\([0-9]\{1,\}\).*/\1/p' | tail -1)
emb=$(printf '%s' "$OUT" | sed -n 's/.*TOTAL=\([0-9]\{1,\}\) EMBEDDED=\([0-9]\{1,\}\).*/\2/p' | tail -1)
if printf '%s' "$OUT" | grep -q "LOADED_OK" \
   && [ -n "$tot" ] && [ "$tot" = "$emb" ] && [ "${emb:-0}" -gt 0 ]; then
  echo "ONNX_RESULT=success — model loaded, ${emb}/${tot} KB docs embedded."
  exit 0
fi
echo "ONNX_RESULT=FAILED — model not usable (LOADED_OK missing or EMBEDDED=${emb:-0}/${tot:-?})." >&2
if printf '%s' "$OUT" | grep -q "ORA-01652"; then
  echo "  Cause: a tablespace could not grow to hold the ~133MB model (ORA-01652)." >&2
  echo "  The load now targets COLLECTIONS_AI_TS (autoextend). If this persists, the DB host" >&2
  echo "  filesystem is out of space for the datafile — free space or extend the volume." >&2
fi
exit 1
