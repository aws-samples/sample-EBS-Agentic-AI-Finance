#!/bin/bash
# =============================================================================
# deploy.sh — Oracle EBS Collections Agent (26ai Edition)
#
# Deploys all components of the solution (staged; see the stage list below).
#
# Usage:
#   ./deploy.sh              # Deploy the default set: secrets db-user database onnx database-p2p infra lambda frontend rbac agentcore
#   ./deploy.sh secrets      # Single stage
#   ./deploy.sh infra lambda agent frontend   # Multiple stages
#
# Stages:
#   rbac             — Cognito groups + demo users (RBAC: group -> EBS responsibility)
#   rbac-ebs         — as 'rbac' plus the matching EBS FND_USER responsibilities (via SSM)
#   secrets          — Create Secrets Manager secret for the Oracle 26ai DB
#   db-user          — Create the COLLECTIONS_AI schema (prereq: user + privileges + AR
#                      base-table SELECT grants). Runs as SYSDBA via SSM. MUST precede 'database'.
#   database         — Collections AI layer (COLLECTIONS_AI): KB vector table, 6 reporting views,
#                      xx_selectai_pkg, xx_kb_search_pkg, 9 seed docs + idempotent content
#                      refresh/re-embed, PLUS the audited AR write-back package
#                      APPS.XX_COLLECTIONS_REST_PKG (compiled as APPS + EXECUTE to COLLECTIONS_AI)
#                      (deploy_ai_layer.sh)
#   onnx             — Load the in-DB ONNX embedding model (COLL_EMBED_MODEL) + embed the KB
#                      (staged from S3 via load_onnx_model.sh; auto-fetches the model if missing).
#                      Runs automatically right after 'database'; without it KB embedding hits
#                      ORA-40284 and semantic search falls back to keywords.
#   database-p2p     — P2P DB layer (AP/PO/RCV views + audited APPS.XX_P2P_AP_PKG + XX_P2P_INGEST_PKG
#                      + XX_P2P_ANOMALY_PKG + XX_WORKING_CAPITAL_PKG) (deploy_p2p_layer.sh)
#   database-p2p-sec — P2P VPD row-level security (XX_P2P_SEC_PKG + DBMS_RLS policies)
#   infra            — CloudFormation stack (S3, CloudFront, Cognito, API GW WebSocket, Lambdas,
#                      DynamoDB, S3 invoice inbox + CORS, IAM)
#   lambda           — Package/deploy Collections λ, P2P λ, P2P extract λ, WebSocket handler λ
#   agentcore        — Deploy the Strands agent to Bedrock AgentCore Runtime (in the default set;
#                      VPC-attached; SQLcl MCP bundled; auto-creates/reuses an AgentCore Memory and
#                      wires the runtime ARN into the WebSocket handler)
#   quick-mcp        — (optional) Deploy the EBS Finance MCP server to AgentCore Runtime
#                      (--protocol MCP + Cognito JWT auth) for Amazon Quick. See docs/QUICK_MCP_SETUP.md.
#   frontend         — Build React, sync to S3, invalidate CloudFront
#
# Optional (not in the default set): PL/SQL write-back on the EBS app tier via
# ./collections_agent/scripts/deploy_all_rest_services.sh; and 'quick-mcp' for Amazon Quick.
# deploy.sh prints a "Next steps" summary at the end listing anything still pending.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy-config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Read config helper
read_config() {
  # Tolerant of missing/optional keys: returns empty (exit 0) instead of raising, so a
  # `X=$(read_config "absent.key")` assignment can't trip `set -e` (e.g. agentcore.memory_id
  # is intentionally absent — auto-created by the agentcore stage).
  python3 -c "
import json, sys
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

# Ensure the agentcore CLI is available. Pip-installable, so auto-install into the active
# Python env if missing. Returns non-zero (without failing the script) if still unavailable.
ensure_agentcore_cli() {
  command -v agentcore &> /dev/null && return 0
  echo "  agentcore CLI not found — installing (bedrock-agentcore-starter-toolkit)..."
  python3 -m pip install --quiet --upgrade bedrock-agentcore-starter-toolkit 2>/dev/null \
    || pip install --quiet --upgrade bedrock-agentcore-starter-toolkit 2>/dev/null || true
  hash -r 2>/dev/null || true
  command -v agentcore &> /dev/null
}

# Preflight: verify host tools and install ALL deploy-time Python dependencies so a FRESH
# deploy environment (e.g. a new SageMaker notebook) works with no manual setup. Fail-soft on
# pip (prints a warning) but hard-fail on missing base tools (aws/python) that can't be
# auto-installed. Runs once, before any stage.
ensure_deploy_prereqs() {
  echo -e "${GREEN}[preflight] Checking deploy-time prerequisites...${NC}"
  # The pip `bedrock-agentcore-starter-toolkit` CLI prints a deprecation recommendation on every
  # invocation. It still functions; silence the noise so it doesn't clutter stage output.
  export AGENTCORE_SUPPRESS_RECOMMENDATION=1
  local missing=""
  command -v aws     >/dev/null 2>&1 || missing="${missing} aws-cli-v2"
  command -v python3 >/dev/null 2>&1 || missing="${missing} python3"
  ( command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1 || python3 -m pip --version >/dev/null 2>&1 ) \
    || missing="${missing} pip"
  if [ -n "${missing}" ]; then
    echo -e "  ${RED}Missing required host tools:${missing}${NC}"
    echo -e "  ${RED}These cannot be auto-installed here — install them and re-run.${NC}"
    exit 1
  fi

  # Frontend build needs Node/npm (host tool, not pip-installable) — warn only if that stage runs.
  if echo " ${STAGES} " | grep -q " frontend "; then
    command -v npm >/dev/null 2>&1 || echo -e "  ${YELLOW}⚠️  npm not found — the 'frontend' stage needs Node 18+/npm.${NC}"
  fi

  # AgentCore stages need the CLI + the bedrock-agentcore SDK (for memory auto-create) + uv
  # (used by the CodeBuild build path). Install them into the active env for a turn-key fresh run.
  if echo " ${STAGES} " | grep -qE "( agentcore | quick-mcp )"; then
    echo "  Installing AgentCore deploy libraries (bedrock-agentcore-starter-toolkit, bedrock-agentcore, uv)..."
    python3 -m pip install --quiet --upgrade bedrock-agentcore-starter-toolkit bedrock-agentcore uv 2>/dev/null \
      || pip install --quiet --upgrade bedrock-agentcore-starter-toolkit bedrock-agentcore uv 2>/dev/null \
      || echo -e "  ${YELLOW}⚠️  Could not install AgentCore libraries (check network/pip). The agentcore stage may fail.${NC}"
    hash -r 2>/dev/null || true
    command -v agentcore >/dev/null 2>&1 \
      && echo "  ✓ agentcore CLI present." \
      || echo -e "  ${YELLOW}⚠️  agentcore CLI still not on PATH after install.${NC}"
  fi
  echo -e "  ${GREEN}✓ Prerequisites ready.${NC}\n"
}

# Configuration
AWS_REGION=$(read_config "aws_region")
STACK_NAME=$(read_config "stack_name")
LAMBDA_NAME=$(read_config "lambda.function_name")
AGENT_NAME=$(read_config "agentcore.agent_name")
SECRET_NAME=$(read_config "oracle_26ai.secret_name")
FRONTEND_BUCKET=$(read_config "frontend.s3_bucket")

echo "============================================"
echo " Oracle EBS Collections Agent (26ai)"
echo " Deployment Script"
echo "============================================"
echo ""
echo " Stack:   ${STACK_NAME}"
echo " Region:  ${AWS_REGION}"
echo " Lambda:  ${LAMBDA_NAME}"
echo " Agent:   ${AGENT_NAME}"
echo ""

# Determine which stages to run
if [ $# -eq 0 ]; then
  # frontend BEFORE agentcore: the UI has no dependency on the agent runtime, so a problem in
  # the (CLI/CodeBuild-dependent) agentcore stage must never leave you without a deployed UI.
  STAGES="secrets db-user database onnx database-p2p infra lambda frontend rbac agentcore"
else
  STAGES="$@"
fi

# =========================================================================
# Stage 0: Secrets
# =========================================================================
deploy_secrets() {
  echo -e "\n${GREEN}[secrets] Creating Secrets Manager secret...${NC}"

  # Check if secret already exists (reuse, don't recreate — isolation-safe)
  if aws secretsmanager describe-secret --secret-id "${SECRET_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "  Secret '${SECRET_NAME}' already exists. Reusing (not modified)."
    return
  fi

  # Non-interactive: read everything from deploy-config.json (works in autonomous runs)
  DB_PASSWORD=$(read_config "oracle_26ai.db_password")
  DB_HOST=$(read_config "oracle_26ai.host")
  DB_SERVICE=$(read_config "oracle_26ai.service_name")
  DB_USER=$(read_config "oracle_26ai.db_user")
  EBS_PASSWORD=$(read_config "oracle_ebs.apps_password")

  echo "  Creating secret: ${SECRET_NAME} (host=${DB_HOST}, service=${DB_SERVICE})"
  aws secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --region "${AWS_REGION}" \
    --secret-string "{
      \"username\": \"${DB_USER}\",
      \"password\": \"${DB_PASSWORD}\",
      \"host\": \"${DB_HOST}\",
      \"port\": \"1521\",
      \"service_name\": \"${DB_SERVICE}\",
      \"ebs_username\": \"APPS\",
      \"ebs_password\": \"${EBS_PASSWORD}\"
    }" \
    --tags Key=Project,Value=ebs-collections-26ai

  echo -e "  ${GREEN}✓ Secret created.${NC}"
}

# =========================================================================
# Stage: Create the COLLECTIONS_AI application schema (prerequisite for `database`)
# =========================================================================
# Everything else connects AS COLLECTIONS_AI and assumes it exists. This stage
# creates it (as SYSDBA via SSM) with object-creation privileges, SELECT AI package
# grants, and SELECT on the AR base tables. Must run BEFORE `database`. Idempotent.
deploy_db_user() {
  echo -e "\n${GREEN}[db-user] Creating COLLECTIONS_AI schema (prerequisite)...${NC}"
  bash "${SCRIPT_DIR}/collections_agent/scripts/create_collections_ai_user.sh"
  echo -e "  ${GREEN}✓ COLLECTIONS_AI schema created/verified.${NC}"
}

# =========================================================================
# Stage 1: Database AI layer (COLLECTIONS_AI schema objects via SSM)
# =========================================================================
deploy_database() {
  echo -e "\n${GREEN}[database] Deploying Oracle 26ai AI layer (COLLECTIONS_AI schema)...${NC}"
  # Delegates to the SSM-based deployer: KB vector table, 6 deterministic views,
  # xx_selectai_pkg, xx_kb_search_pkg, 9 seed docs, then an idempotent content
  # refresh + re-embed (XX_KB_REFRESH_26ai.sql). Idempotent + verifies VALID.
  bash "${SCRIPT_DIR}/collections_agent/scripts/deploy_ai_layer.sh"
  echo -e "  ${GREEN}✓ AI layer + audited AR write-back package (APPS.XX_COLLECTIONS_REST_PKG) deployed.${NC}"
  echo -e "  ${YELLOW}  Note: the in-DB ONNX embedding model is loaded by the 'onnx' stage${NC}"
  echo -e "  ${YELLOW}  (runs automatically right after this stage).${NC}"
}

# =========================================================================
# Stage: Load the in-DB ONNX embedding model (COLL_EMBED_MODEL) + embed the KB
# =========================================================================
# Without this, KB embedding fails with ORA-40284 ("model does not exist") and
# semantic search silently falls back to keywords. The load is fully config-driven
# (bedrock.onnx_s3_uri / bedrock.onnx_model). The 133MB model must live in S3 first
# (the DB has no arbitrary internet egress); if it's missing we fetch Oracle's public
# prebuilt model to the deploy host and stage it to S3, so a fresh install is turn-key.
# Sets ONNX_DONE / ONNX_PENDING (read by the end-of-run summary). Idempotent.
ONNX_STATUS="skipped"
deploy_onnx() {
  echo -e "\n${GREEN}[onnx] Loading in-DB ONNX embedding model + embedding the KB...${NC}"
  local s3_uri onnx_model oracle_url
  s3_uri=$(read_config "bedrock.onnx_s3_uri")
  onnx_model=$(read_config "bedrock.onnx_model")
  oracle_url="https://objectstorage.us-ashburn-1.oraclecloud.com/n/adwc4pm/b/OML-Resources/o/all_MiniLM_L12_v2.onnx"

  if [ -z "${s3_uri}" ] || echo "${s3_uri}" | grep -q "<"; then
    echo -e "  ${YELLOW}⚠️  bedrock.onnx_s3_uri is not set in deploy-config.json — skipping ONNX load.${NC}"
    ONNX_STATUS="unconfigured"
    return
  fi

  # Ensure the model is present in S3 (the exact object load_onnx_model.sh pulls from).
  if aws s3 ls "${s3_uri}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "  ✓ ONNX model already staged in S3: ${s3_uri}"
  else
    echo "  Model not in S3 yet — fetching Oracle's prebuilt ${onnx_model} and staging it..."
    if curl -fsSL -o "/tmp/${onnx_model}.onnx" "${oracle_url}" 2>/dev/null \
       && aws s3 cp "/tmp/${onnx_model}.onnx" "${s3_uri}" --region "${AWS_REGION}" >/dev/null 2>&1; then
      echo "  ✓ staged model to ${s3_uri}"
      rm -f "/tmp/${onnx_model}.onnx" 2>/dev/null || true
    else
      echo -e "  ${YELLOW}⚠️  Could not auto-stage the ONNX model (no internet egress or URL changed).${NC}"
      echo -e "  ${YELLOW}    Upload it once, then re-run './deploy.sh onnx':${NC}"
      echo "      curl -fsSL -o /tmp/${onnx_model}.onnx \"${oracle_url}\""
      echo "      aws s3 cp /tmp/${onnx_model}.onnx ${s3_uri} --region ${AWS_REGION}"
      ONNX_STATUS="pending"
      return
    fi
  fi

  if bash "${SCRIPT_DIR}/collections_agent/scripts/load_onnx_model.sh"; then
    echo -e "  ${GREEN}✓ ONNX model loaded + KB embedded (verified).${NC}"
    ONNX_STATUS="done"
  else
    echo -e "  ${RED}✗ ONNX load FAILED — the model is not usable (see the ORA- errors above).${NC}"
    echo -e "  ${YELLOW}   Fix the cause, then re-run: ./deploy.sh onnx  (KB stays keyword-only until it succeeds).${NC}"
    ONNX_STATUS="pending"
  fi
}

# =========================================================================
# Stage: P2P database layer (AP/PO/RCV views + audited AP package)
# =========================================================================
deploy_database_p2p() {
  echo -e "\n${GREEN}[database-p2p] Deploying Purchase-to-Pay DB layer...${NC}"
  bash "${SCRIPT_DIR}/collections_agent/scripts/deploy_p2p_layer.sh"
  echo -e "  ${GREEN}✓ P2P DB layer deployed (grants + XX_P2P_*_V views + APPS.XX_P2P_AP_PKG${NC}"
  echo -e "  ${GREEN}  + XX_P2P_INGEST_PKG + XX_P2P_ANOMALY_PKG + XX_WORKING_CAPITAL_PKG).${NC}"
}

# =========================================================================
# Stage: P2P VPD security layer (row-level org scoping on the P2P views)
# =========================================================================
deploy_database_p2p_sec() {
  echo -e "\n${GREEN}[database-p2p-sec] Deploying P2P VPD (row-level security)...${NC}"
  bash "${SCRIPT_DIR}/collections_agent/scripts/deploy_p2p_security.sh"
  echo -e "  ${GREEN}✓ P2P VPD deployed (XX_P2P_SEC_PKG + DBMS_RLS policies, org-scoped).${NC}"
}

# =========================================================================
# Stage 1: Infrastructure (CloudFormation)
# =========================================================================
deploy_infra() {
  echo -e "\n${GREEN}[infra] Deploying CloudFormation stack: ${STACK_NAME}...${NC}"

  VPC_ID=$(read_config "vpc.vpc_id")
  SUBNET_IDS=$(read_config "vpc.subnet_ids")
  SG_ID=$(read_config "vpc.security_group_id")
  EBS_HOST=$(read_config "oracle_ebs.host")
  EBS_PORT=$(read_config "oracle_ebs.port")
  ORACLE_HOST=$(read_config "oracle_26ai.host")
  ORACLE_PORT=$(read_config "oracle_26ai.port")
  ORACLE_SERVICE=$(read_config "oracle_26ai.service_name")
  BEDROCK_MODEL=$(read_config "bedrock.model_id")
  SELECT_AI_PROFILE=$(read_config "oracle_26ai.select_ai_profile")
  ACCOUNT_ID=$(read_config "aws_account_id")

  # The template is larger than CloudFormation's 51,200-byte inline limit, so it must be
  # staged in S3. Ensure a hardened deploy bucket exists and pass it via --s3-bucket.
  CFN_BUCKET="${STACK_NAME}-cfndeploy-${ACCOUNT_ID}"
  if ! aws s3api head-bucket --bucket "${CFN_BUCKET}" --region "${AWS_REGION}" 2>/dev/null; then
    aws s3api create-bucket --bucket "${CFN_BUCKET}" --region "${AWS_REGION}" \
      $([ "${AWS_REGION}" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=${AWS_REGION}") >/dev/null 2>&1
    aws s3api put-public-access-block --bucket "${CFN_BUCKET}" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true --region "${AWS_REGION}" >/dev/null 2>&1
    aws s3api put-bucket-encryption --bucket "${CFN_BUCKET}" --region "${AWS_REGION}" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null 2>&1
    echo "  Created CloudFormation staging bucket: ${CFN_BUCKET}"
  fi

  aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/frontend/infrastructure-26ai.yaml" \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" \
    --s3-bucket "${CFN_BUCKET}" \
    --s3-prefix cfn \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      VpcId="${VPC_ID}" \
      SubnetIds="${SUBNET_IDS}" \
      SecurityGroupId="${SG_ID}" \
      EBSHost="${EBS_HOST}" \
      EBSPort="${EBS_PORT}" \
      OracleHost="${ORACLE_HOST}" \
      OraclePort="${ORACLE_PORT}" \
      OracleService="${ORACLE_SERVICE}" \
      OracleSecretName="${SECRET_NAME}" \
      SelectAIProfile="${SELECT_AI_PROFILE}" \
      BedrockModelId="${BEDROCK_MODEL}" \
    --tags \
      Project=ebs-collections-26ai \
      Environment=26ai

  echo -e "  ${GREEN}✓ Stack deployed.${NC}"
  
  # Print outputs
  echo ""
  echo "  Stack Outputs:"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

  # Open DB (1521) and EBS ISG (8000) reachability on the shared VPC SG. The Lambdas and the
  # AgentCore runtime attach to vpc.security_group_id; a self-referencing ingress rule lets
  # them reach the DB/EBS when those share this SG (the common single-SG setup). Idempotent:
  # a duplicate rule just returns InvalidPermission.Duplicate, which we ignore.
  if [ -n "${SG_ID}" ]; then
    echo "  Ensuring SG ${SG_ID} self-ingress for DB/EBS ports..."
    for p in "${ORACLE_PORT:-1521}" "${EBS_PORT:-8000}"; do
      aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
        --protocol tcp --port "${p}" --source-group "${SG_ID}" --region "${AWS_REGION}" >/dev/null 2>&1 \
        && echo "    ✓ tcp/${p} from ${SG_ID} added" \
        || echo "    • tcp/${p} already present or not permitted"
    done
    echo -e "  ${YELLOW}  NOTE: if the Oracle DB / EBS use a DIFFERENT security group, add an${NC}"
    echo -e "  ${YELLOW}  inbound rule there allowing tcp/1521 (and 8000) from ${SG_ID}.${NC}"
  fi
}

# =========================================================================
# Stage 2: Lambda
# =========================================================================
deploy_lambda() {
  echo -e "\n${GREEN}[lambda] Packaging and deploying Lambdas...${NC}"

  # --- Collections Lambda (ISG write-back + view reads; needs oracledb + requests) ---
  LAMBDA_DIR="${SCRIPT_DIR}/collections_agent/lambda"
  BUILD_DIR="/tmp/lambda-26ai-build"
  rm -rf "${BUILD_DIR}"; mkdir -p "${BUILD_DIR}"
  if [ -f "${LAMBDA_DIR}/requirements.txt" ]; then
    pip install -r "${LAMBDA_DIR}/requirements.txt" -t "${BUILD_DIR}" \
      --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 \
      --only-binary=:all: --upgrade --quiet 2>/dev/null || \
    pip install -r "${LAMBDA_DIR}/requirements.txt" -t "${BUILD_DIR}" --quiet
  fi
  cp "${LAMBDA_DIR}"/*.py "${BUILD_DIR}/"
  (cd "${BUILD_DIR}" && zip -r /tmp/lambda-26ai.zip . -q)
  aws lambda update-function-code --function-name "${LAMBDA_NAME}" \
    --zip-file fileb:///tmp/lambda-26ai.zip --region "${AWS_REGION}" >/dev/null 2>&1 \
    && echo "  ✓ ${LAMBDA_NAME} updated" \
    || echo "  ⚠️  ${LAMBDA_NAME} not found — deploy infra first."

  # Set SES email env vars for real dunning-letter/reminder delivery (merge, don't clobber).
  SES_SENDER=$(read_config "email.ses_sender")
  DEMO_RECIP=$(read_config "email.demo_recipient")
  SES_REGION=$(read_config "email.ses_region")
  if [ -n "${SES_SENDER}" ]; then
    # wait for the code update to settle, then merge env vars into the existing set
    aws lambda wait function-updated --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
    MERGED_ENV=$(aws lambda get-function-configuration --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" \
      --query 'Environment.Variables' --output json 2>/dev/null | \
      SES_SENDER="${SES_SENDER}" DEMO_RECIP="${DEMO_RECIP}" SES_REGION="${SES_REGION:-$AWS_REGION}" python3 -c "
import json, os, sys
env = json.load(sys.stdin) or {}
env['SES_SENDER'] = os.environ['SES_SENDER']
env['DUNNING_DEMO_RECIPIENT'] = os.environ['DEMO_RECIP']
env['SES_REGION'] = os.environ['SES_REGION']
print(json.dumps({'Variables': env}))")
    aws lambda update-function-configuration --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" \
      --environment "${MERGED_ENV}" >/dev/null 2>&1 \
      && echo "  ✓ ${LAMBDA_NAME} email env set (SES sender ${SES_SENDER})" \
      || echo "  ⚠️  ${LAMBDA_NAME} email env update failed."
  fi

  # --- P2P Lambda (same deps; p2p_index.handler over XX_P2P_*_V views) ---
  P2P_NAME=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`P2PLambdaName`].OutputValue' --output text 2>/dev/null || echo "ebs-p2p-26ai")
  if [ -n "${P2P_NAME}" ]; then
    aws lambda update-function-code --function-name "${P2P_NAME}" \
      --zip-file fileb:///tmp/lambda-26ai.zip --region "${AWS_REGION}" >/dev/null 2>&1 \
      && echo "  ✓ ${P2P_NAME} updated (P2P read views)" \
      || echo "  ⚠️  ${P2P_NAME} update failed — deploy infra first."
  fi

  # --- P2P extraction (ingest) Lambda (same deps; p2p_extract.handler) ---
  EXTRACT_NAME=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`P2PExtractLambdaName`].OutputValue' --output text 2>/dev/null || echo "ebs-p2p-extract-26ai")
  if [ -n "${EXTRACT_NAME}" ]; then
    aws lambda update-function-code --function-name "${EXTRACT_NAME}" \
      --zip-file fileb:///tmp/lambda-26ai.zip --region "${AWS_REGION}" >/dev/null 2>&1 \
      && echo "  ✓ ${EXTRACT_NAME} updated (invoice extraction/ingest)" \
      || echo "  ⚠️  ${EXTRACT_NAME} update failed — deploy infra first."
  fi

  # --- WebSocket handler (bundles PyJWT[crypto] for Cognito JWT verification at $connect) ---
  WS_NAME=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`WebSocketLambdaName`].OutputValue' --output text 2>/dev/null || echo "")
  WS_DIR="${SCRIPT_DIR}/frontend/lambda"
  if [ -n "${WS_NAME}" ] && [ -f "${WS_DIR}/websocket_handler.py" ]; then
    rm -f /tmp/ws-26ai.zip
    WS_BUILD="/tmp/ws-26ai-build"; rm -rf "${WS_BUILD}"; mkdir -p "${WS_BUILD}"
    if [ -f "${WS_DIR}/requirements.txt" ]; then
      pip install -r "${WS_DIR}/requirements.txt" -t "${WS_BUILD}" \
        --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 \
        --only-binary=:all: --upgrade --quiet 2>/dev/null || \
      pip install -r "${WS_DIR}/requirements.txt" -t "${WS_BUILD}" --quiet
    fi
    cp "${WS_DIR}/websocket_handler.py" "${WS_BUILD}/"
    (cd "${WS_BUILD}" && zip -qr /tmp/ws-26ai.zip .)
    aws lambda update-function-code --function-name "${WS_NAME}" \
      --zip-file fileb:///tmp/ws-26ai.zip --region "${AWS_REGION}" >/dev/null 2>&1 \
      && echo "  ✓ ${WS_NAME} updated (with JWT verify)" \
      || echo "  ⚠️  ${WS_NAME} update failed."
    rm -rf /tmp/ws-26ai.zip "${WS_BUILD}"
  fi

  rm -rf "${BUILD_DIR}" /tmp/lambda-26ai.zip
  echo -e "  ${GREEN}✓ Lambdas deployed.${NC}"
}

# =========================================================================
# Stage: AgentCore Runtime (container) WITH SQLcl 25.2+ MCP server
# =========================================================================
# Hosts the agent on Amazon Bedrock AgentCore Runtime (VPC-attached so it reaches
# the private Oracle DB on 1521) with the SQLcl MCP server bundled in the image
# (USE_SQLCL_MCP=1). AgentCore is container-native, so there is no zip-size limit
# and no separate "switch to image" step. This is the sole runtime home for the agent.
deploy_agentcore() {
  echo -e "\n${GREEN}[agentcore] Deploying agent to AgentCore Runtime (SQLcl MCP bundled)...${NC}"

  AGENT_DIR="${SCRIPT_DIR}/agentcore_version"
  ACCOUNT_ID=$(read_config "aws_account_id")
  ECR_REPO="ebs-collections-26ai-agentcore"
  ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
  RUNTIME_NAME="ebs_collections_agent_26ai"
  # Use the execution role from config if set; otherwise fall back to the convention name.
  EXEC_ROLE=$(read_config "agentcore.execution_role")
  [ -z "${EXEC_ROLE}" ] && EXEC_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/ebs-collections-26ai-agentcore-role"
  SUBNETS=$(read_config "vpc.subnet_ids")
  SG_ID=$(read_config "vpc.security_group_id")
  SECRET_NAME=$(read_config "oracle_26ai.secret_name")
  ORACLE_HOST=$(read_config "oracle_26ai.host")
  ORACLE_PORT=$(read_config "oracle_26ai.port")
  ORACLE_SERVICE=$(read_config "oracle_26ai.service_name")
  MODEL_ID=$(read_config "agentcore.model_id")
  MEMORY_ID=$(read_config "agentcore.memory_id")
  CHART_BUCKET=$(read_config "chart_bucket")

  # Ensure the chart bucket exists and the runtime role can put/get objects (charts are
  # returned to the browser as short presigned URLs, not inline base64 — see chart_generator).
  if [ -n "${CHART_BUCKET}" ]; then
    aws s3api head-bucket --bucket "${CHART_BUCKET}" --region "${AWS_REGION}" 2>/dev/null || \
      aws s3 mb "s3://${CHART_BUCKET}" --region "${AWS_REGION}" >/dev/null 2>&1
    aws iam put-role-policy --role-name "ebs-collections-26ai-agentcore-role" \
      --policy-name ChartBucketAccess \
      --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${CHART_BUCKET}/charts/*\"}]}" \
      >/dev/null 2>&1 && echo "  ✓ chart bucket policy set (${CHART_BUCKET})" || true
  fi

  # Prefer the agentcore CLI (handles CodeBuild ARM64 build → ECR → runtime; no local Docker).
  ensure_agentcore_cli || true

  # Auto-create (or reuse) an AgentCore Memory when none is configured, so memory_id never
  # has to be hand-entered. Best-effort + fail-open: if creation isn't possible the agent
  # still runs (memory features simply stay off). The SDK ships with the agentcore toolkit.
  if [ -z "${MEMORY_ID}" ]; then
    echo "  agentcore.memory_id empty — ensuring an AgentCore Memory exists..."
    set +e
    MEMORY_ID=$(MEM_NAME="${RUNTIME_NAME}_mem" MEM_REGION="${AWS_REGION}" python3 - <<'PY' 2>/dev/null
import os
try:
    from bedrock_agentcore.memory import MemoryClient
    c = MemoryClient(region_name=os.environ["MEM_REGION"])
    name = os.environ["MEM_NAME"]
    mid = ""
    try:                       # reuse an existing memory with this name if present
        for m in (c.list_memories() or []):
            hay = (m.get("name", "") or "") + (m.get("id", "") or "") + (m.get("memoryId", "") or "")
            if name in hay:
                mid = m.get("id") or m.get("memoryId") or ""
                break
    except Exception:
        pass
    if not mid:                # otherwise create one and wait until ACTIVE
        r = c.create_memory_and_wait(name=name, strategies=[])
        mid = r.get("id") or r.get("memoryId") or (r.get("memory") or {}).get("id", "")
    print(mid or "")
except Exception:
    print("")
PY
)
    set -e
    if [ -n "${MEMORY_ID}" ]; then
      echo "  ✓ AgentCore Memory ready: ${MEMORY_ID}"
      echo "    (optional: paste this into deploy-config.json → agentcore.memory_id to pin it)"
    else
      echo "  ⚠️  Could not auto-create AgentCore Memory — proceeding without it (memory features off)."
    fi
  fi

  if command -v agentcore &> /dev/null; then
    echo "  Using agentcore CLI (CodeBuild ARM64 build → ECR → runtime)."
    # The agentcore CLI reads .bedrock_agentcore.yaml from this dir, which the quick-mcp
    # stage repoints at the MCP server. Re-run configure (NON-INTERACTIVE — otherwise it
    # prompts and hangs) to repoint the active agent at the collections runtime + the agent
    # entrypoint before launching. Also ensure `Dockerfile` is the agent image (the quick-mcp
    # stage swaps in Dockerfile.mcp and restores after, but guard against an interrupted run).
    [ -f "${AGENT_DIR}/Dockerfile.agent.bak" ] && mv -f "${AGENT_DIR}/Dockerfile.agent.bak" "${AGENT_DIR}/Dockerfile"
    # `agentcore configure --ecr <name>` REQUIRES the repo to already exist (it resolves the
    # name to a full URI and errors if absent). A fresh account has no such repo — create it.
    AC_ECR_REPO="bedrock-agentcore-ebs_collections_agent_26ai"
    aws ecr describe-repositories --repository-names "${AC_ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
      || { aws ecr create-repository --repository-name "${AC_ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
             && echo "  ✓ created ECR repo ${AC_ECR_REPO}" \
             || echo -e "  ${YELLOW}⚠️  could not create ECR repo ${AC_ECR_REPO} — agentcore build will fail.${NC}"; }
    ( cd "${AGENT_DIR}" && \
      agentcore configure --create --non-interactive \
        --region "${AWS_REGION}" \
        --entrypoint agentcore_runtime.py \
        --name "${RUNTIME_NAME}" \
        --execution-role "${EXEC_ROLE}" \
        --ecr "${AC_ECR_REPO}" \
        --requirements-file requirements.txt \
        --vpc --subnets "${SUBNETS}" --security-groups "${SG_ID}" \
        --disable-otel 2>&1 | grep -vE "RequestsDependency|warnings.warn" || \
      echo -e "  ${YELLOW}(agentcore configure flags vary by CLI version — adjust if needed)${NC}" )
    # `set -o pipefail` so the pipeline reflects agentcore's REAL exit code, not grep's — the
    # earlier version reported a false "✓ launched" because grep (last in the pipe) returned 0.
    ( set -o pipefail; cd "${AGENT_DIR}" && AWS_REGION="${AWS_REGION}" agentcore launch --auto-update-on-conflict \
        --env USE_SQLCL_MCP=1 \
        --env ORACLE_SECRET_NAME="${SECRET_NAME}" \
        --env ORACLE_HOST="${ORACLE_HOST}" \
        --env ORACLE_PORT="${ORACLE_PORT}" \
        --env ORACLE_SERVICE="${ORACLE_SERVICE}" \
        --env MODEL_ID="${MODEL_ID}" \
        --env AGENTCORE_MEMORY_ID="${MEMORY_ID}" \
        --env CHART_BUCKET="${CHART_BUCKET}" \
        --env AWS_REGION="${AWS_REGION}" 2>&1 | grep -vE "RequestsDependency|warnings.warn" ) \
      && echo -e "  ${GREEN}✓ agentcore launch command completed.${NC}" \
      || echo -e "  ${RED}✗ agentcore launch FAILED — the runtime was not created (see output above).${NC}"
    echo -e "  ${YELLOW}NOTE: DB reachability on 1521 is opened by the infra stage via SG ${SG_ID}${NC}"
    echo -e "  ${YELLOW}  self-ingress. If the DB uses a different SG, allow 1521 from ${SG_ID} there.${NC}"

    # Wire the freshly-created AgentCore Runtime into the WebSocket handler so the UI routes
    # chat to it (memory + SQLcl MCP). Fetch the runtime ARN by name, then MERGE it into the
    # handler's env as AGENT_RUNTIME_ARN (the var websocket_handler.py reads). The chat UI
    # requires this to be set — there is no Lambda fallback.
    RT_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
      --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeArn | [0]" \
      --output text 2>/dev/null || echo "")
    WS_NAME=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
      --query 'Stacks[0].Outputs[?OutputKey==`WebSocketLambdaName`].OutputValue' --output text 2>/dev/null || echo "")
    if [ -n "${RT_ARN}" ] && [ "${RT_ARN}" != "None" ] && [ -n "${WS_NAME}" ]; then
      aws lambda wait function-updated --function-name "${WS_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
      MERGED_WS_ENV=$(aws lambda get-function-configuration --function-name "${WS_NAME}" --region "${AWS_REGION}" \
        --query 'Environment.Variables' --output json 2>/dev/null | \
        RT_ARN="${RT_ARN}" python3 -c "
import json, os, sys
env = json.load(sys.stdin) or {}
env['AGENT_RUNTIME_ARN'] = os.environ['RT_ARN']
print(json.dumps({'Variables': env}))")
      aws lambda update-function-configuration --function-name "${WS_NAME}" --region "${AWS_REGION}" \
        --environment "${MERGED_WS_ENV}" >/dev/null 2>&1 \
        && echo -e "  ${GREEN}✓ WebSocket handler wired to AgentCore runtime:${NC} ${RT_ARN}" \
        || echo -e "  ${YELLOW}⚠️  Could not update WS handler env — set AGENT_RUNTIME_ARN=${RT_ARN} on ${WS_NAME} manually.${NC}"
    else
      echo -e "  ${YELLOW}⚠️  Could not resolve the runtime ARN or WS handler name — the chat UI will be unconfigured until AGENT_RUNTIME_ARN is set on the WS handler.${NC}"
    fi
    return
  fi

  # Fallback: build/push the ARM64 image directly (requires local Docker buildx).
  echo "  agentcore CLI not found — building ARM64 image with docker buildx."
  aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null 2>&1
  docker buildx build --platform linux/arm64 \
    -f "${AGENT_DIR}/Dockerfile" -t "${ECR_URI}:latest" "${AGENT_DIR}" --push \
    || { echo -e "  ${RED}✗ buildx build/push failed (needs docker buildx)${NC}"; return 1; }
  echo -e "  ${GREEN}✓ Image pushed: ${ECR_URI}:latest${NC}"
  echo -e "  ${YELLOW}Create/update the AgentCore Runtime with this image + VPC config:${NC}"
  echo "    subnets=${SUBNETS} sg=${SG_ID} role=${EXEC_ROLE}"
  echo "    (use 'aws bedrock-agentcore-control create-agent-runtime' or the agentcore CLI)"
  echo -e "  ${YELLOW}NOTE: DB SG must allow inbound 1521 from the runtime's ENIs.${NC}"
}

# =========================================================================
# Stage: Quick MCP server (AgentCore Runtime, --protocol MCP, Cognito JWT auth)
# =========================================================================
# Hosts agentcore_version/mcp_server.py as a streamable-HTTP MCP server on AgentCore
# Runtime so Amazon Quick can discover + invoke the solution's governed ERP tools.
# Auth = Cognito OAuth client_credentials (the QuickMcpClient created by the CFN stack).
# Reuses the same VPC (to reach the private Oracle DB) and the S3 invoice inbox.
# After this runs, follow docs/QUICK_MCP_SETUP.md to connect Quick (console step).
deploy_quick_mcp() {
  echo -e "\n${GREEN}[quick-mcp] Deploying EBS Finance MCP server to AgentCore Runtime...${NC}"

  AGENT_DIR="${SCRIPT_DIR}/agentcore_version"
  ACCOUNT_ID=$(read_config "aws_account_id")
  RUNTIME_NAME="ebs_finance_mcp_26ai"
  ECR_REPO="ebs-finance-mcp-26ai"
  SUBNETS=$(read_config "vpc.subnet_ids")
  SG_ID=$(read_config "vpc.security_group_id")
  SECRET_NAME=$(read_config "oracle_26ai.secret_name")
  ORACLE_HOST=$(read_config "oracle_26ai.host")
  ORACLE_PORT=$(read_config "oracle_26ai.port")
  ORACLE_SERVICE=$(read_config "oracle_26ai.service_name")
  MODEL_ID=$(read_config "agentcore.model_id")

  # Pull the MCP runtime role + Cognito discovery URL + inbox bucket from the CFN stack.
  MCP_ROLE=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`QuickMcpRuntimeRoleArn`].OutputValue' --output text 2>/dev/null || echo "")
  DISCOVERY_URL=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`QuickMcpDiscoveryUrl`].OutputValue' --output text 2>/dev/null || echo "")
  CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`QuickMcpClientId`].OutputValue' --output text 2>/dev/null || echo "")
  INBOX_BUCKET=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`P2PInboxBucketName`].OutputValue' --output text 2>/dev/null || echo "")

  if [ -z "${MCP_ROLE}" ] || [ -z "${DISCOVERY_URL}" ]; then
    echo -e "  ${YELLOW}⚠️  MCP role / Cognito discovery URL not found in stack outputs.${NC}"
    echo -e "  ${YELLOW}   Deploy/redeploy infra first (adds QuickMcp* resources), then rerun.${NC}"
    return
  fi

  # Ensure the ECR repo exists (CodeBuild pushes here; the runtime role is scoped to pull it).
  aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1
  ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

  if ! ensure_agentcore_cli; then
    echo -e "  ${YELLOW}⚠️  agentcore CLI not found and auto-install failed.${NC}"
    echo -e "  ${YELLOW}   Install manually: pip install bedrock-agentcore-starter-toolkit, then rerun: ./deploy.sh quick-mcp${NC}"
    return
  fi

  echo "  Using agentcore CLI (CodeBuild ARM64 → ECR → runtime, --protocol MCP)."
  echo "  Inbound auth: Cognito JWT (client ${CLIENT_ID}); discovery ${DISCOVERY_URL}"

  # The agentcore CLI builds from a file named `Dockerfile` in the source dir. This dir
  # also holds the AGENT Dockerfile (port 8080, SQLcl). Temporarily install the MCP
  # Dockerfile (port 8000, /mcp) as `Dockerfile` for this build, then restore the agent's.
  DOCKERFILE_BACKED_UP=0
  if [ -f "${AGENT_DIR}/Dockerfile" ]; then
    cp "${AGENT_DIR}/Dockerfile" "${AGENT_DIR}/Dockerfile.agent.bak"
    DOCKERFILE_BACKED_UP=1
  fi
  cp "${AGENT_DIR}/Dockerfile.mcp" "${AGENT_DIR}/Dockerfile"
  _restore_dockerfile() {
    if [ "${DOCKERFILE_BACKED_UP}" = "1" ]; then
      mv -f "${AGENT_DIR}/Dockerfile.agent.bak" "${AGENT_DIR}/Dockerfile"
    else
      rm -f "${AGENT_DIR}/Dockerfile"
    fi
  }

  # Configure the MCP runtime: entrypoint = mcp_server.py, protocol MCP, JWT authorizer
  # bound to the Cognito pool (client_credentials client from the CFN stack).
  ( cd "${AGENT_DIR}" && \
    agentcore configure --create --non-interactive \
      --region "${AWS_REGION}" \
      --protocol MCP \
      --entrypoint mcp_server.py \
      --name "${RUNTIME_NAME}" \
      --execution-role "${MCP_ROLE}" \
      --requirements-file requirements-mcp.txt \
      --ecr "${ECR_URI}" \
      --authorizer-config "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"${DISCOVERY_URL}\",\"allowedClients\":[\"${CLIENT_ID}\"]}}" \
      --vpc --subnets "${SUBNETS}" --security-groups "${SG_ID}" \
      --disable-otel 2>&1 | grep -vE "RequestsDependency|warnings.warn" || \
    echo -e "  ${YELLOW}(agentcore configure flags vary by CLI version — adjust if needed)${NC}" )

  ( cd "${AGENT_DIR}" && AWS_REGION="${AWS_REGION}" agentcore launch --auto-update-on-conflict \
      --env ORACLE_SECRET_NAME="${SECRET_NAME}" \
      --env ORACLE_HOST="${ORACLE_HOST}" \
      --env ORACLE_PORT="${ORACLE_PORT}" \
      --env ORACLE_SERVICE="${ORACLE_SERVICE}" \
      --env MODEL_ID="${MODEL_ID}" \
      --env AWS_REGION="${AWS_REGION}" \
      --env P2P_INBOX_BUCKET="${INBOX_BUCKET}" 2>&1 | grep -vE "RequestsDependency|warnings.warn" ) \
    && echo -e "  ${GREEN}✓ EBS Finance MCP runtime launched.${NC}" \
    || echo -e "  ${YELLOW}⚠️  agentcore launch failed — see output above.${NC}"

  _restore_dockerfile

  echo -e "  ${YELLOW}NOTE: DB SG must allow inbound 1521 from the runtime's ENIs (SG ${SG_ID}).${NC}"
  echo -e "  ${GREEN}Next: connect Amazon Quick using docs/QUICK_MCP_SETUP.md (console step).${NC}"
  echo -e "  ${GREEN}  MCP endpoint = https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/<runtime-arn>/invocations${NC}"
}

# =========================================================================
# Stage 4: Frontend
# =========================================================================
deploy_frontend() {
  echo -e "\n${GREEN}[frontend] Building and deploying frontend...${NC}"

  FRONTEND_DIR="${SCRIPT_DIR}/frontend"

  # Get stack outputs for aws-config.js
  CF_URL=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontURL`].OutputValue' --output text 2>/dev/null || echo "")
  WS_URL=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`WebSocketURL`].OutputValue' --output text 2>/dev/null || echo "")
  POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text 2>/dev/null || echo "")
  CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[?OutputKey==`UserPoolClientId`].OutputValue' --output text 2>/dev/null || echo "")

  if [ -z "${CF_URL}" ]; then
    echo -e "  ${YELLOW}⚠️  Stack outputs not available. Deploy infra first.${NC}"
    return
  fi

  # Generate aws-config.js
  cat > "${FRONTEND_DIR}/src/aws-config.js" <<CONF
// Auto-generated by deploy.sh — do not edit manually
const awsConfig = {
  region: '${AWS_REGION}',
  userPoolId: '${POOL_ID}',
  userPoolClientId: '${CLIENT_ID}',
  websocketUrl: '${WS_URL}',
  cloudFrontUrl: '${CF_URL}',
};
export default awsConfig;
CONF

  # Build React app
  cd "${FRONTEND_DIR}"
  if [ -f "package.json" ]; then
    npm install --quiet
    npm run build --quiet
    
    # Sync to S3
    aws s3 sync build/ "s3://${FRONTEND_BUCKET}/" --delete --region "${AWS_REGION}"
    
    # Invalidate CloudFront
    DIST_ID=$(aws cloudfront list-distributions \
      --query "DistributionList.Items[?Origins.Items[0].DomainName=='${FRONTEND_BUCKET}.s3.${AWS_REGION}.amazonaws.com'].Id" \
      --output text 2>/dev/null || echo "")
    
    if [ -n "${DIST_ID}" ]; then
      aws cloudfront create-invalidation --distribution-id "${DIST_ID}" --paths '/*' --region "${AWS_REGION}" > /dev/null
      echo "  CloudFront invalidation created."
    fi

    echo -e "  ${GREEN}✓ Frontend deployed: ${CF_URL}${NC}"
  else
    echo -e "  ${YELLOW}⚠️  No package.json found in frontend/. Skipping build.${NC}"
  fi

  cd "${SCRIPT_DIR}"
}

# =========================================================================
# Execute requested stages
# =========================================================================
# =========================================================================
# Stage: RBAC — Cognito groups + demo users (and optionally EBS responsibilities).
# Maps Cognito groups to EBS responsibilities and gates agent write actions.
# =========================================================================
deploy_rbac() {
  echo -e "\n${GREEN}[RBAC] Provisioning Cognito groups + demo users...${NC}"
  bash "${SCRIPT_DIR}/collections_agent/scripts/setup_rbac.sh"
}

deploy_rbac_ebs() {
  echo -e "\n${GREEN}[RBAC] Provisioning Cognito RBAC + EBS FND_USER responsibilities...${NC}"
  bash "${SCRIPT_DIR}/collections_agent/scripts/setup_rbac.sh" --with-ebs
}

ensure_deploy_prereqs

for stage in ${STAGES}; do
  case "${stage}" in
    secrets)  deploy_secrets ;;
    db-user)  deploy_db_user ;;
    database) deploy_database ;;
    onnx)     deploy_onnx ;;
    database-p2p) deploy_database_p2p ;;
    database-p2p-sec) deploy_database_p2p_sec ;;
    infra)    deploy_infra ;;
    lambda)   deploy_lambda ;;
    agentcore) deploy_agentcore ;;
    quick-mcp) deploy_quick_mcp ;;
    frontend) deploy_frontend ;;
    rbac)     deploy_rbac ;;
    rbac-ebs) deploy_rbac_ebs ;;
    *)        echo -e "${RED}Unknown stage: ${stage}${NC}"; exit 1 ;;
  esac
done

echo ""
echo "============================================"
echo -e " ${GREEN}Deployment complete!${NC}"
echo "============================================"

# =========================================================================
# Next steps / status summary — so the operator never has to dig through the
# README to learn what ran and what (if anything) still needs a hand. Reflects
# the stages that actually ran in THIS invocation, and pulls the live URLs from
# the CloudFormation stack outputs when the infra stack exists.
# =========================================================================
ran() { echo " ${STAGES} " | grep -q " $1 "; }
stack_out() {  # $1 = OutputKey ; prints value or empty
  aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${AWS_REGION}" \
    --query "Stacks[0].Outputs[?OutputKey==\`$1\`].OutputValue" --output text 2>/dev/null | grep -v '^None$' || echo ""
}

echo ""
echo -e "${GREEN}Stages run this invocation:${NC} ${STAGES}"

# Pull the live endpoints from the CFN stack (present once 'infra' has ever run).
CF_URL=$(stack_out CloudFrontURL)
WS_URL=$(stack_out WebSocketURL)
UP_ID=$(stack_out UserPoolId)

# -------------------------------------------------------------------------
# ERRORS / attention (RED) — real problems that leave the solution incomplete.
# -------------------------------------------------------------------------
ERRORS=""
if ran onnx; then
  case "${ONNX_STATUS}" in
    done)         : ;;  # loaded fine — nothing to flag
    pending)      ERRORS="${ERRORS}\n  • ONNX model not loaded — KB semantic search falls back to keywords. Re-run: ./deploy.sh onnx (see the [onnx] output above)." ;;
    unconfigured) ERRORS="${ERRORS}\n  • bedrock.onnx_s3_uri is not set in deploy-config.json — set it, then re-run: ./deploy.sh onnx (KB stays keyword-only until then)." ;;
  esac
fi
if ran agentcore; then
  RT_ARN_CHK=$(aws bedrock-agentcore-control list-agent-runtimes --region "${AWS_REGION}" \
    --query "agentRuntimes[?agentRuntimeName=='ebs_collections_agent_26ai'].agentRuntimeArn | [0]" \
    --output text 2>/dev/null | grep -v '^None$' || echo "")
  [ -z "${RT_ARN_CHK}" ] && ERRORS="${ERRORS}\n  • AgentCore runtime not found — the chat UI has no agent to route to. Re-run: ./deploy.sh agentcore\n    (if the AZ is unsupported, fix vpc.subnet_ids first; if IAM 'role not ready', just re-run — propagation)."
fi

# -------------------------------------------------------------------------
# NEXT STEPS (BLUE) — what the customer still needs to DO after deploy.sh.
# Always useful; shown in blue on a clean run.
# -------------------------------------------------------------------------
NEXTSTEPS=""
if ran rbac; then
  NEXTSTEPS="${NEXTSTEPS}\n  1. Sign in — generic demo logins were created: demo-manager@example.com (AR+AP),\n     demo-ap-manager@example.com (AP only), and demo-sales@example.com (read-only). Use the\n     password you configured at rbac.demo_password. To sign in as yourself, add your own\n     Cognito user manually (see README)."
else
  NEXTSTEPS="${NEXTSTEPS}\n  1. Create a login: ./deploy.sh rbac (requires rbac.demo_password in deploy-config.json)."
fi
if ran onnx && [ "${ONNX_STATUS}" != "done" ]; then
  NEXTSTEPS="${NEXTSTEPS}\n  2. Finish the KB embedding model load:  ./deploy.sh onnx   (required for semantic search over policy/SOP docs)."
fi
NEXTSTEPS="${NEXTSTEPS}\n  • (Optional) Row-level security on P2P views:  ./deploy.sh database-p2p-sec   (VPD org-scoping; the app must set the P2P context)."
NEXTSTEPS="${NEXTSTEPS}\n  • (Optional) Map logins to EBS FND_USER responsibilities:  ./deploy.sh rbac-ebs."
NEXTSTEPS="${NEXTSTEPS}\n  • (Optional) Expose the governed ERP tools to Amazon Quick:  ./deploy.sh quick-mcp   then docs/QUICK_MCP_SETUP.md."
NEXTSTEPS="${NEXTSTEPS}\n  • (Optional) EBS app-tier PL/SQL write-back services:  ./collections_agent/scripts/deploy_all_rest_services.sh."

if [ -n "${ERRORS}" ]; then
  echo ""
  echo -e "${RED}⚠️  Completed, but the following need attention:${NC}"
  echo -e "${RED}${ERRORS}${NC}"
fi

echo ""
echo -e "${BLUE}Next steps (do these after deploy.sh):${NC}"
echo -e "${BLUE}${NEXTSTEPS}${NC}"

# -------------------------------------------------------------------------
# Access endpoints — CloudFront URL listed prominently at the very end.
# -------------------------------------------------------------------------
echo ""
echo -e "${BLUE}============================================${NC}"
if [ -n "${CF_URL}" ]; then
  echo -e "${BLUE} Open the app:${NC}  ${CF_URL}"
else
  echo -e "${YELLOW} App URL unavailable — run './deploy.sh infra frontend' to (re)create the CloudFront distribution.${NC}"
fi
[ -n "${WS_URL}" ] && echo -e "${BLUE} WebSocket API:${NC} ${WS_URL}"
[ -n "${UP_ID}"  ] && echo -e "${BLUE} Cognito pool:${NC}  ${UP_ID}"
echo -e "${BLUE}============================================${NC}"
