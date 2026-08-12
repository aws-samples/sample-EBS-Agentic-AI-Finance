#!/bin/bash
# =============================================================================
# setup_rbac.sh — provision the RBAC demo: Cognito groups + custom attribute +
# demo users, and (optionally) the matching EBS FND_USER responsibilities.
#
# Idempotent: safe to re-run. Reads pool id from the CFN stack outputs.
#
# Cognito group -> EBS responsibility -> allowed agent actions:
#   ar-managers  = AR Collections Manager : AR write actions
#   ar-analysts  = AR Enquiry (read-only)  : no writes
#   ap-managers  = AP Manager              : AP write actions
#   ap-clerks    = AP read-only            : no writes
#
# Usage:
#   bash collections_agent/scripts/setup_rbac.sh            # Cognito only
#   bash collections_agent/scripts/setup_rbac.sh --with-ebs # also EBS responsibilities
# Reads deploy-config.json for region/stack. Default AWS creds (no --profile).
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$HERE/.."
CFG="$ROOT/deploy-config.json"
REGION=$(python3 -c "import json;print(json.load(open('$CFG'))['aws_region'])")
STACK=$(python3 -c "import json;print(json.load(open('$CFG'))['stack_name'])")
DEMO_PW=$(python3 -c "import json;print(json.load(open('$CFG')).get('rbac', {}).get('demo_password', ''))")
if [ -z "$DEMO_PW" ] || [[ "$DEMO_PW" == \<*\> ]]; then
  echo "ERROR: set rbac.demo_password in deploy-config.json before running the RBAC stage."
  exit 1
fi

POOL=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text 2>/dev/null)
if [ -z "$POOL" ] || [ "$POOL" = "None" ]; then
  echo "ERROR: could not resolve UserPoolId from stack $STACK"; exit 1
fi
echo "User pool: $POOL"

echo "=== 1. custom:ebs_username attribute (ignored if it already exists) ==="
aws cognito-idp add-custom-attributes --user-pool-id "$POOL" --region "$REGION" \
  --custom-attributes '[{"Name":"ebs_username","AttributeDataType":"String","Mutable":true,"StringAttributeConstraints":{"MinLength":"0","MaxLength":"100"}}]' \
  2>/dev/null && echo "  added custom:ebs_username" || echo "  (already present)"

echo "=== 2. groups ==="
create_group() {  # name, description
  aws cognito-idp create-group --user-pool-id "$POOL" --region "$REGION" \
    --group-name "$1" --description "$2" >/dev/null 2>&1 && echo "  created $1" || echo "  exists  $1"
}
create_group ar-managers "AR Collections Manager - full AR write (credit holds, notes, dunning)"
create_group ap-managers "AP Manager - full AP write (release holds, approve, run import)"
create_group ar-analysts "AR Enquiry - read-only (queries + charts + KB); writes denied"
create_group ap-clerks   "AP Clerk - read-only exception queue; writes denied"

echo "=== 3. demo users (username = email) + ebs_username + groups ==="
# user_email  ebs_username  groups(space-sep)
ensure_user() {
  local email="$1" ebs="$2"; shift 2; local groups="$*"
  if aws cognito-idp admin-get-user --user-pool-id "$POOL" --region "$REGION" --username "$email" >/dev/null 2>&1; then
    echo "  exists  $email"
  else
    aws cognito-idp admin-create-user --user-pool-id "$POOL" --region "$REGION" \
      --username "$email" \
      --user-attributes Name=email,Value="$email" Name=email_verified,Value=true "Name=custom:ebs_username,Value=$ebs" \
      --message-action SUPPRESS >/dev/null 2>&1 && echo "  created $email"
  fi
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --region "$REGION" \
    --username "$email" --password "$DEMO_PW" --permanent >/dev/null 2>&1
  for g in $groups; do
    aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --region "$REGION" \
      --username "$email" --group-name "$g" >/dev/null 2>&1 && echo "    -> $g"
  done
}
# Generic demo personas on the RFC-2606 example.com dummy domain (no real identities).
# They power the RBAC demo:
#   demo-manager     — AR + AP Manager (all write actions allowed)
#   demo-ap-manager  — AP Manager only (AP writes allowed; AR writes DENIED — the cross-domain beat)
#   demo-sales       — AR Analyst, read-only (all writes denied — the "escalate" path)
# NOTE: these are the only logins the deploy creates, on purpose — no personal email is used.
# To sign in as yourself, add your own Cognito user manually (see README "Add your own login").
ensure_user "demo-manager@example.com"    "SYSADMIN" ar-managers ap-managers
ensure_user "demo-ap-manager@example.com" "SYSADMIN" ap-managers
ensure_user "demo-sales@example.com"      ""         ar-analysts

echo "=== 4. verify group membership ==="
for g in ar-managers ap-managers ar-analysts ap-clerks; do
  printf "  %-12s: " "$g"
  aws cognito-idp list-users-in-group --user-pool-id "$POOL" --region "$REGION" \
    --group-name "$g" --query 'Users[].Attributes[?Name==`email`]|[].Value' --output text 2>/dev/null
done

if [ "${1:-}" = "--with-ebs" ]; then
  echo "=== 5. EBS FND_USER responsibilities (via SSM, seeded fnd_user_pkg APIs) ==="
  SQLF="$HERE/sql/XX_RBAC_DEMO_USERS.sql"
  DB_INSTANCE=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['db_instance_id'])")
  DB_HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['host'])")
  DB_PORT=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['port'])")
  SVC=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_26ai']['service_name'])")
  APPS_PWD=$(python3 -c "import json;print(json.load(open('$CFG'))['oracle_ebs']['apps_password'])")
  EZ="//${DB_HOST}:${DB_PORT}/${SVC}"
  if [ ! -f "$SQLF" ]; then echo "  SKIP: $SQLF not found."; else
    b64=$(base64 -i "$SQLF" | tr -d '\n')
    RUN="echo $b64 | base64 -d > /tmp/_rbac.sql; chmod 644 /tmp/_rbac.sql; su - oracle -c \"sqlplus -s apps/${APPS_PWD}@${EZ} @/tmp/_rbac.sql\" > /tmp/_rbac.out 2>&1; echo OUTSTART; tr -d '\r' < /tmp/_rbac.out; echo OUTEND"
    python3 -c "import json,sys;print(json.dumps({'commands':[sys.argv[1]]}))" "$RUN" > /tmp/_rbac_params.json
    cid=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_INSTANCE" \
      --document-name AWS-RunShellScript --timeout-seconds 300 \
      --parameters file:///tmp/_rbac_params.json --query "Command.CommandId" --output text) && {
      for _ in $(seq 1 60); do sleep 5; st=$(aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cid" --instance-id "$DB_INSTANCE" --query "Status" --output text 2>/dev/null); \
        [ "$st" != "InProgress" ] && [ "$st" != "Pending" ] && break; done
      aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
        --instance-id "$DB_INSTANCE" --query "StandardOutputContent" --output text; }
    rm -f /tmp/_rbac_params.json
  fi
fi

echo "Done. Demo users were provisioned with the password configured at rbac.demo_password."
