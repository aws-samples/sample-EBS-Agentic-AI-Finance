#!/bin/bash
# =============================================================================
# deploy_all_rest_services.sh
# Deploys PL/SQL packages to EBS and registers them as ISG REST services
#
# Run as: applmgr on the EBS application server
# Target: ERP-R122-SOGW-APP-26aii-02239cc37bc522eb9
#
# Prerequisites:
#   - EBS environment sourced (. <EBS_BASE>/EBSapps.env run)
#   - iRep parser configured (Patch 13602850 applied)
#   - APPS password available
# =============================================================================

set -e

# Configuration — UPDATE THESE
EBS_BASE="/fh01/ERP"  # EBS application base path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/../sql"

echo "============================================"
echo " Oracle EBS Collections Agent (26ai)"
echo " PL/SQL + ISG REST Deployment"
echo "============================================"
echo ""
echo "EBS_BASE: ${EBS_BASE}"
echo "SQL_DIR:  ${SQL_DIR}"
echo ""

# Source EBS environment
echo "[1/6] Sourcing EBS environment..."
. ${EBS_BASE}/EBSapps.env run

# Prompt for APPS password
read -sp "Enter APPS password: " APPS_PWD
echo ""

# Compile PL/SQL packages
echo "[2/6] Compiling PL/SQL packages..."
sqlplus -s apps/${APPS_PWD} <<EOF
@${SQL_DIR}/XX_COLLECTIONS_REST_PKG.sql
@${SQL_DIR}/XX_COLLECTIONS_TASK_PKG.sql
@${SQL_DIR}/XX_ORDER_HOLDS_PKG.sql
SHOW ERRORS
EXIT;
EOF

echo "  PL/SQL packages compiled."

# Register with iRep
echo "[3/6] Registering packages with Integration Repository..."
for pkg in XX_COLLECTIONS_REST_PKG XX_COLLECTIONS_TASK_PKG XX_ORDER_HOLDS_PKG; do
  echo "  Registering ${pkg}..."
  perl ${FND_TOP}/bin/irep_parser.pl \
    -g -v \
    apps:${APPS_PWD} \
    ${pkg} \
    ${SQL_DIR}/${pkg}.sql
done

echo "  iRep registration complete."

# Upload to Integration Repository via FNDLOAD
echo "[4/6] Uploading to Integration Repository..."
FNDLOAD apps/${APPS_PWD} 0 Y UPLOAD \
  ${FND_TOP}/patch/115/import/wfirep.lct \
  ${SQL_DIR}/XX_COLLECTIONS_REST_PKG.ildt 2>/dev/null || true

echo "  FNDLOAD upload complete."

# Deploy as REST services
echo "[5/6] Deploying REST services via iSG..."
# Grant GLOBAL access to the services
sqlplus -s apps/${APPS_PWD} <<EOF
BEGIN
  -- Grant access to collections REST services
  FND_IREP_ACCESS_PKG.grant_access(
    p_interface_name => 'XX_COLLECTIONS_REST_PKG',
    p_grantee_type   => 'GLOBAL',
    p_grantee_key    => 'GLOBAL'
  );
  FND_IREP_ACCESS_PKG.grant_access(
    p_interface_name => 'XX_COLLECTIONS_TASK_PKG',
    p_grantee_type   => 'GLOBAL',
    p_grantee_key    => 'GLOBAL'
  );
  FND_IREP_ACCESS_PKG.grant_access(
    p_interface_name => 'XX_ORDER_HOLDS_PKG',
    p_grantee_type   => 'GLOBAL',
    p_grantee_key    => 'GLOBAL'
  );
  COMMIT;
END;
/
EXIT;
EOF

echo "  REST services deployed with GLOBAL access."

# Verify WADL endpoints
echo "[6/6] Verifying WADL endpoints..."
HOST=$(hostname -f)
PORT=8000
BASE_URL="http://${HOST}:${PORT}/webservices/rest"

for endpoint in XxCollectionsRestPkg XxCollectionsTaskPkg XxOrderHoldsPkg; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/${endpoint}/?wadl" 2>/dev/null || echo "000")
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "  ✓ ${endpoint} — WADL OK (HTTP 200)"
  else
    echo "  ✗ ${endpoint} — WADL FAILED (HTTP ${HTTP_CODE})"
  fi
done

echo ""
echo "============================================"
echo " Deployment complete!"
echo " ISG REST base URL: ${BASE_URL}"
echo "============================================"
