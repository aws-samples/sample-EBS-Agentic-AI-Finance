#!/bin/bash
# =============================================================================
# destroy.sh — Teardown Oracle EBS Collections Agent (26ai Edition)
#
# Removes the solution's AWS resources (CloudFormation stack, buckets, agent).
#
# Usage:
#   ./destroy.sh                  # Interactive — prompts for confirmation
#   ./destroy.sh --force          # Skip confirmation
#   ./destroy.sh --delete-secrets # Also delete the Oracle 26ai credentials secret
#   ./destroy.sh --keep-user      # Keep the COLLECTIONS_AI schema. By DEFAULT destroy DROPS it
#                                 #   (DROP USER ... CASCADE, as SYSDBA via SSM) — it was created
#                                 #   by deploy.sh, so teardown removes it. Destructive + not reversible.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy-config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

read_config() {
  # Tolerant of missing/optional keys: returns empty (exit 0) so a `X=$(read_config ...)`
  # assignment can't trip `set -e`.
  python3 -c "
import json
with open('${CONFIG_FILE}') as f:
    config = json.load(f)
keys = '$1'.split('.')
val = config
try:
    for k in keys:
        val = val[k]
except (KeyError, TypeError, IndexError):
    val = ''
print(val)
" 2>/dev/null
}

# Run a shell command on the DB node via SSM (used only for --drop-user). Robust under set -e:
# every AWS call is guarded so a failure returns cleanly instead of aborting the teardown.
ssm_run() {  # $1 = commands JSON array ; prints StandardOutputContent
  local cid st
  cid=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$DB_INSTANCE" \
    --document-name AWS-RunShellScript --timeout-seconds 300 \
    --parameters "commands=$1" --query "Command.CommandId" --output text 2>/dev/null) || return 1
  for _ in $(seq 1 50); do
    sleep 6
    st=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cid" \
      --instance-id "$DB_INSTANCE" --query "Status" --output text 2>/dev/null) || true
    [ "$st" != "InProgress" ] && [ "$st" != "Pending" ] && break
  done
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cid" \
    --instance-id "$DB_INSTANCE" --query "StandardOutputContent" --output text 2>/dev/null || true
}

# Version-aware bucket empty. `aws s3 rm --recursive` only removes CURRENT versions; these
# buckets have versioning ON, so CloudFormation can't delete them until ALL object versions
# AND delete markers are gone. This loops delete-objects in batches until the bucket is empty.
empty_bucket() {
  local b="$1"
  [ -z "$b" ] || [ "$b" = "None" ] && return 0
  aws s3api head-bucket --bucket "$b" --region "$AWS_REGION" 2>/dev/null || { echo "  $b — not found, skipping."; return 0; }
  echo "  emptying $b (objects + versions + delete markers)..."
  while true; do
    aws s3api list-object-versions --bucket "$b" --region "$AWS_REGION" --max-items 1000 --output json 2>/dev/null \
      | python3 -c 'import json,sys
d=json.load(sys.stdin) or {}
o=[{"Key":x["Key"],"VersionId":x["VersionId"]} for k in ("Versions","DeleteMarkers") for x in (d.get(k) or [])]
sys.stdout.write(json.dumps({"Objects":o,"Quiet":True}) if o else "")' > /tmp/_empty_del.json
    [ -s /tmp/_empty_del.json ] || break
    aws s3api delete-objects --bucket "$b" --region "$AWS_REGION" --delete file:///tmp/_empty_del.json >/dev/null 2>&1 || break
  done
  rm -f /tmp/_empty_del.json
  echo "  $b — emptied."
}

AWS_REGION=$(read_config "aws_region")
STACK_NAME=$(read_config "stack_name")
AGENT_NAME=$(read_config "agentcore.agent_name")
SECRET_NAME=$(read_config "oracle_26ai.secret_name")
FRONTEND_BUCKET=$(read_config "frontend.s3_bucket")
LOGGING_BUCKET=$(read_config "frontend.logging_bucket")
DB_INSTANCE=$(read_config "oracle_26ai.db_instance_id")
DB_USER=$(read_config "oracle_26ai.db_user")
PDB=$(read_config "oracle_26ai.pdb_name")

FORCE=false
DELETE_SECRETS=false
DROP_USER=true   # deploy.sh creates COLLECTIONS_AI, so teardown drops it by default

for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=true ;;
    --delete-secrets) DELETE_SECRETS=true ;;
    --drop-user) DROP_USER=true ;;      # explicit (already the default)
    --keep-user) DROP_USER=false ;;     # opt out of dropping the schema
  esac
done

echo "============================================"
echo -e " ${RED}DESTROY${NC} — Oracle EBS Collections (26ai)"
echo "============================================"
echo ""
echo " Stack:   ${STACK_NAME}"
echo " Agent:   ${AGENT_NAME}"
echo " Region:  ${AWS_REGION}"
echo ""
echo -e "${YELLOW}⚠️  This tears down the solution's AWS resources for stack '${STACK_NAME}'.${NC}"
echo ""

if [ "${FORCE}" != "true" ]; then
  read -p "Are you sure you want to destroy all 26ai resources? (yes/no): " CONFIRM
  if [ "${CONFIRM}" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# Step: Remove AgentCore runtime(s) — by their REAL deployed names via the control-plane API.
# NOTE: the config's agentcore.agent_name (ebs-collections-agent-26ai, dashes) is NOT the
# deployed runtime name (ebs_collections_agent_26ai, underscores), and the `agentcore` CLI's
# local teardown context is unreliable — so delete by the actual runtime names via the API.
echo -e "\n${YELLOW}[agent] Removing AgentCore runtime(s)...${NC}"
for rn in ebs_collections_agent_26ai ebs_finance_mcp_26ai; do
  RID=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
    --query "agentRuntimes[?agentRuntimeName=='${rn}'].agentRuntimeId | [0]" --output text 2>/dev/null || echo "")
  if [ -n "${RID}" ] && [ "${RID}" != "None" ]; then
    aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "${RID}" --region "${AWS_REGION}" 2>/dev/null \
      && echo "  deleted runtime ${rn} (${RID})" \
      || echo "  ⚠️  could not delete runtime ${rn} — remove manually if it lingers."
  else
    echo "  runtime ${rn} not found (skip)."
  fi
done

# Step: Delete the AgentCore Memory the agentcore stage auto-created (name = <runtime>_mem).
# Done AFTER the runtime is removed so the memory isn't in use. Best-effort / fail-soft:
# uses the same bedrock-agentcore SDK the deploy used to create it (installed if missing).
echo -e "\n${YELLOW}[memory] Removing AgentCore Memory...${NC}"
python3 -c "import bedrock_agentcore" 2>/dev/null || {
  echo "  installing bedrock-agentcore SDK for memory teardown..."
  python3 -m pip install --quiet bedrock-agentcore 2>/dev/null || pip install --quiet bedrock-agentcore 2>/dev/null || true
}
set +e
MEM_OUT=$(MEM_NAME="ebs_collections_agent_26ai_mem" MEM_REGION="${AWS_REGION}" python3 - <<'PY' 2>/dev/null
import os
try:
    from bedrock_agentcore.memory import MemoryClient
    c = MemoryClient(region_name=os.environ["MEM_REGION"])
    name = os.environ["MEM_NAME"]
    found = False
    for m in (c.list_memories() or []):
        mid = m.get("id") or m.get("memoryId") or ""
        mname = m.get("name") or ""
        if mid and (mname == name or name in mid):
            found = True
            try:
                c.delete_memory(memory_id=mid)
            except TypeError:
                c.delete_memory(mid)
            print("deleted memory " + mid)
    if not found:
        print("no matching memory found (skip)")
except Exception as e:
    print("skip (memory teardown unavailable): " + str(e)[:120])
PY
)
set -e
echo "  ${MEM_OUT}"

# Step: Empty ALL stack-owned S3 buckets (version-aware) so CloudFormation can delete them.
echo -e "\n${YELLOW}[buckets] Emptying S3 buckets (all versions + delete markers)...${NC}"
ACCOUNT_ID=$(read_config "aws_account_id")
# Artifacts + inbox buckets are NOT in config — derive artifacts by convention and read the
# inbox name from the stack outputs (all four are emptied; missing ones are skipped).
ART_BUCKET="ebs-collections-26ai-artifacts-${ACCOUNT_ID}"
INBOX_BUCKET=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`P2PInboxBucketName`].OutputValue' --output text 2>/dev/null || echo "")
for b in "${FRONTEND_BUCKET}" "${LOGGING_BUCKET}" "${ART_BUCKET}" "${INBOX_BUCKET}"; do
  empty_bucket "$b"
done

# The CloudFormation staging bucket is created OUTSIDE the stack by deploy.sh's infra stage
# (to upload the >51KB template), so CloudFormation never deletes it. Empty AND delete it here
# — unlike the app buckets above (which CloudFormation removes once emptied), this one is ours.
CFN_BUCKET="${STACK_NAME}-cfndeploy-${ACCOUNT_ID}"
empty_bucket "${CFN_BUCKET}"
if aws s3api head-bucket --bucket "${CFN_BUCKET}" --region "${AWS_REGION}" 2>/dev/null; then
  aws s3api delete-bucket --bucket "${CFN_BUCKET}" --region "${AWS_REGION}" 2>/dev/null \
    && echo "  ${CFN_BUCKET} — deleted (CFN staging bucket)." \
    || echo "  ${CFN_BUCKET} — could not delete (remove manually if needed)."
fi

# Step: Delete CloudFormation stack (with re-empty + retry for the logging-bucket race).
# The LoggingBucket is the S3 access-log TARGET for the other buckets and CloudFront, so it
# keeps receiving NEW log objects while the stack deletes — it gets emptied above, refills
# mid-teardown, and then blocks deletion ("bucket is not empty" → DELETE_FAILED). On each
# failed attempt we re-empty every S3 bucket STILL in the stack (by its real physical name,
# so a config/name mismatch can't hide it) and retry. By the retry, the log producers are
# already gone, so the bucket stays empty and the delete succeeds.
echo -e "\n${YELLOW}[stack] Deleting CloudFormation stack: ${STACK_NAME}...${NC}"

stack_status() {
  aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "GONE"
}
empty_stack_buckets() {  # re-empty every bucket the stack still owns, by physical id
  local buckets b
  buckets=$(aws cloudformation list-stack-resources --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query "StackResourceSummaries[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")
  for b in ${buckets}; do empty_bucket "${b}"; done
  # Also re-empty the config-known buckets in case the stack listing is unavailable.
  for b in "${FRONTEND_BUCKET}" "${LOGGING_BUCKET}" "${ART_BUCKET}" "${INBOX_BUCKET}"; do
    empty_bucket "${b}"
  done
}

DELETED="false"
for attempt in 1 2 3; do
  aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
  echo "  Waiting for stack deletion (attempt ${attempt}/3)..."
  if aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
    DELETED="true"; break
  fi
  ST=$(stack_status)
  if [ "${ST}" = "GONE" ]; then DELETED="true"; break; fi
  echo -e "  ${YELLOW}Stack status: ${ST} — re-emptying buckets that refilled during teardown, then retrying...${NC}"
  empty_stack_buckets
done

# The WebSocket access-log group is stack-owned (DeletionPolicy defaults to Delete), but a
# partial/failed stack delete can leave it behind — and CloudFormation early-validation then
# blocks the NEXT deploy with "Resource of type 'AWS::Logs::LogGroup' ... already exists".
# Delete it by name so a redeploy is always clean. Best-effort; never fails teardown.
echo -e "\n${YELLOW}[logs] Removing WebSocket access-log group (if it lingered)...${NC}"
aws logs delete-log-group --log-group-name "/aws/apigateway/ebs-collections-26ai-ws" \
  --region "${AWS_REGION}" 2>/dev/null \
  && echo "  deleted /aws/apigateway/ebs-collections-26ai-ws" \
  || echo "  /aws/apigateway/ebs-collections-26ai-ws not present (skip)."

if [ "${DELETED}" = "true" ]; then
  echo -e "  ${GREEN}✓ Stack deleted.${NC}"
else
  echo -e "  ${RED}✗ Stack could not be fully deleted (status: $(stack_status)).${NC}"
  echo -e "  ${YELLOW}  A bucket may still be refilling from delayed CloudFront log delivery.${NC}"
  echo -e "  ${YELLOW}  Wait a few minutes for log delivery to stop, then re-run ./destroy.sh — it is idempotent.${NC}"
fi

# Step: Optionally delete secrets
if [ "${DELETE_SECRETS}" == "true" ]; then
  echo -e "\n${YELLOW}[secrets] Deleting Secrets Manager secret: ${SECRET_NAME}...${NC}"
  aws secretsmanager delete-secret \
    --secret-id "${SECRET_NAME}" \
    --force-delete-without-recovery \
    --region "${AWS_REGION}" 2>/dev/null || echo "  Secret not found."
  echo -e "  ${GREEN}✓ Secret deleted.${NC}"
else
  echo -e "\n[secrets] Skipping secret deletion (use --delete-secrets to remove)."
fi

# Step: Optionally drop the COLLECTIONS_AI schema (created by deploy.sh db-user).
# DROP USER ... CASCADE removes the schema and every object we deployed into it
# (views, packages, KB vector table). It does NOT touch the EBS AR/AP/PO/RCV base
# schemas or the APPS packages. Destructive + not reversible. Runs by DEFAULT (it was
# created by deploy.sh); pass --keep-user to skip. Gated by the confirmation prompt above.
if [ "${DROP_USER}" == "true" ]; then
  echo -e "\n${YELLOW}[db-user] Dropping COLLECTIONS_AI schema (${DB_USER}) via SSM...${NC}"
  DROP_SQL="whenever sqlerror continue\nalter session set container=${PDB};\nDROP USER ${DB_USER} CASCADE;\nSELECT 'REMAINING='||COUNT(*) FROM dba_users WHERE username=UPPER('${DB_USER}');\nexit\n"
  B64D=$(printf "$DROP_SQL" | base64 | tr -d '\n')
  ssm_run "[\"echo $B64D | base64 -d > /tmp/_drop_user.sql\",\"su - oracle -c 'sqlplus -s \\\"/ as sysdba\\\" @/tmp/_drop_user.sql' 2>&1 | tr -d '\\r'\"]" \
    || echo "  ⚠️  SSM drop command failed (check SSM access to ${DB_INSTANCE} / SYSDBA)."
  echo -e "  ${GREEN}✓ COLLECTIONS_AI drop attempted (see 'REMAINING=0' above to confirm).${NC}"
else
  echo -e "\n[db-user] Keeping COLLECTIONS_AI schema (--keep-user was passed)."
fi

echo ""
echo "============================================"
echo -e " ${GREEN}Teardown complete.${NC}"
echo ""
echo " NOT touched:"
echo "   - The EBS instance and its Oracle database"
echo "   - EBS-side PL/SQL packages on the app server (if you ran deploy_all_rest_services.sh)"
echo "   (COLLECTIONS_AI schema is DROPPED by default — pass --keep-user to preserve it)"
echo "============================================"
