"""
ebs-p2p-26ai Lambda — Purchase-to-Pay read actions for the AP Control Tower dashboard.

VPC-attached; reads the COLLECTIONS_AI XX_P2P_*_V views via oracledb (live EBS AP/PO/RCV).
Write actions go through the agent's execute_p2p_action tool → audited APPS.XX_P2P_AP_PKG,
not this Lambda (keeps the dashboard read path simple + fast).

Event shape: {"action": "<name>", "parameters": {...}}
Actions: p2p_dashboard (pipeline+KPIs+holds), p2p_exceptions, p2p_aging, p2p_vendor_summary.
"""

import os
import json
import logging

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_secret_cache = None

READ_ACTIONS = ["p2p_dashboard", "p2p_exceptions", "p2p_aging", "p2p_vendor_summary", "p2p_review_queue",
                "p2p_simulate", "p2p_action_plan", "p2p_predict", "p2p_interface_status"]

# Human-in-the-loop review WRITE actions (audited APPS.XX_P2P_INGEST_PKG over oracledb).
WRITE_ACTIONS = ["p2p_approve_review", "p2p_reject_review", "p2p_submit_import"]


def _get_secret() -> dict:
    global _secret_cache
    if _secret_cache is None:
        name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
        region = os.environ.get("AWS_REGION_NAME", os.environ.get("AWS_REGION", "us-east-1"))
        sm = boto3.client("secretsmanager", region_name=region)
        _secret_cache = json.loads(sm.get_secret_value(SecretId=name)["SecretString"])
    return _secret_cache


def _db_query(sql: str, binds: dict = None, identity: dict = None) -> list:
    import oracledb
    s = _get_secret()
    dsn = f"{s['host']}:{s.get('port', 1521)}/{s['service_name']}"
    conn = oracledb.connect(user=s["username"], password=s["password"], dsn=dsn)
    try:
        with conn.cursor() as cur:
            # VPD row-level security: set the caller's org scope for this session before
            # any read. The XX_P2P_SEC_PKG context drives the DBMS_RLS predicate on the
            # row-level views, so Oracle filters by org_id in the kernel. 'ALL' = aggregate
            # (dashboard) scope; an org list restricts to the user's entitled operating units.
            if identity is not None:
                try:
                    cur.callproc("COLLECTIONS_AI.XX_P2P_SEC_PKG.SET_IDENTITY",
                                 [identity.get("user", "agent"),
                                  identity.get("org_csv", ""),
                                  identity.get("scope", "ALL")])
                except Exception:
                    pass  # VPD optional; if not deployed, reads proceed unscoped
            cur.execute(sql, binds or {})
            cols = [c[0].lower() for c in cur.description]
            out = []
            for row in cur.fetchall():
                d = {}
                for k, v in zip(cols, row):
                    d[k] = v.read() if hasattr(v, "read") else v
                out.append(d)
            return out
    finally:
        conn.close()


def _pipeline() -> dict:
    rows = _db_query("SELECT received, extracted, matched, approved, scheduled, paid "
                     "FROM COLLECTIONS_AI.XX_P2P_PIPELINE_V")
    return rows[0] if rows else {}


def _kpis() -> list:
    return _db_query(
        "SELECT display_order, metric_label, metric_value, metric_subtext "
        "FROM COLLECTIONS_AI.XX_P2P_KPI_V ORDER BY display_order")


def _holds_by_type() -> list:
    return _db_query(
        "SELECT hold_type, COUNT(*) AS cnt, ROUND(SUM(invoice_amount)) AS amount "
        "FROM COLLECTIONS_AI.XX_P2P_HOLDS_V GROUP BY hold_type ORDER BY amount DESC NULLS LAST")


def _exceptions(top: int, identity: dict = None) -> list:
    return _db_query(
        "SELECT invoice_id, invoice_num, vendor_name, invoice_amount, currency, "
        "       hold_type, hold_reason, hold_count, hold_age_days, exception_reason, priority_score "
        "FROM COLLECTIONS_AI.XX_P2P_EXCEPTION_QUEUE_V "
        "ORDER BY priority_score DESC NULLS LAST FETCH FIRST :top ROWS ONLY",
        {"top": top}, identity=identity)


def _aging() -> list:
    return _db_query(
        "SELECT bucket_order, aging_bucket, invoice_count, total_amount "
        "FROM COLLECTIONS_AI.XX_P2P_AGING_V ORDER BY bucket_order")


def _vendor_summary(top: int) -> list:
    return _db_query(
        "SELECT vendor_id, vendor_name, total_invoices, open_invoices, open_amount, invoices_on_hold "
        "FROM COLLECTIONS_AI.XX_P2P_VENDOR_SUMMARY_V "
        "ORDER BY open_amount DESC NULLS LAST FETCH FIRST :top ROWS ONLY",
        {"top": top})


def _review_queue() -> list:
    # Invoices ingested with low extraction confidence, awaiting human review.
    return _db_query(
        "SELECT staging_id, vendor_name, invoice_num, invoice_amount, currency_code AS currency, "
        "       confidence, review_reason, source_uri, po_number, status "
        "FROM APPS.XX_P2P_STAGING WHERE status='NEEDS_REVIEW' "
        "ORDER BY created_at DESC FETCH FIRST 100 ROWS ONLY")


def _call_clob(proc: str, args: list, trailing: list = None):
    """Call a package proc whose OUT CLOB follows `args`; optional `trailing` params come
    after the OUT CLOB (e.g. APPROVE_STAGED's corrected-field DEFAULT args). Returns JSON."""
    import oracledb
    s = _get_secret()
    dsn = f"{s['host']}:{s.get('port', 1521)}/{s['service_name']}"
    conn = oracledb.connect(user=s["username"], password=s["password"], dsn=dsn)
    try:
        with conn.cursor() as cur:
            out = cur.var(oracledb.DB_TYPE_CLOB)
            cur.callproc(proc, args + [out] + (trailing or []))
            val = out.getvalue()
            txt = val.read() if hasattr(val, "read") else val
            return json.loads(txt) if txt else None
    finally:
        conn.close()


def handler(event, context):
    action = event.get("action")
    params = event.get("parameters", {}) or {}
    # Optional VPD identity for row-level org scoping (from the authenticated caller).
    # Default scope=ALL (dashboard aggregates). A real deployment maps the Cognito user
    # → entitled org_id CSV and passes {"user","org_csv","scope":"ORG"}.
    identity = event.get("identity") or {"user": "agent", "org_csv": "", "scope": "ALL"}
    if action not in READ_ACTIONS and action not in WRITE_ACTIONS:
        return _resp(400, {"error": f"Invalid action: {action}", "valid": READ_ACTIONS + WRITE_ACTIONS})
    try:
        # --- Human review WRITE actions (audited ingest package) ---
        if action == "p2p_approve_review":
            # Approve (optionally with corrected fields) -> push to AP Open Interface.
            result = {"approve": _call_clob(
                "APPS.XX_P2P_INGEST_PKG.APPROVE_STAGED",
                [int(params["staging_id"]), params.get("reviewer", "ui-reviewer")],
                trailing=[params.get("vendor_name"), params.get("invoice_num"),
                          (float(params["invoice_amount"]) if params.get("invoice_amount") not in (None, "") else None),
                          params.get("invoice_date"), params.get("currency"), params.get("po_number")])}
            return _resp(200, {"status": "success", "action": action, "result": result})
        if action == "p2p_reject_review":
            result = {"reject": _call_clob(
                "APPS.XX_P2P_INGEST_PKG.REJECT_STAGED",
                [int(params["staging_id"]), params.get("reviewer", "ui-reviewer"),
                 params.get("reason", "Rejected in review")])}
            return _resp(200, {"status": "success", "action": action, "result": result})
        if action == "p2p_submit_import":
            # Submit the seeded Payables Open Interface Import (APXIIMPT); returns request_id.
            result = {"import": _call_clob(
                "APPS.XX_P2P_INGEST_PKG.SUBMIT_IMPORT",
                [int(params.get("org_id", 204)), params.get("group_id")])}
            return _resp(200, {"status": "success", "action": action, "result": result})

        if action == "p2p_dashboard":
            result = {
                "pipeline": _pipeline(),
                "kpis": _kpis(),
                "holds_by_type": _holds_by_type(),
                "aging": _aging(),
                "exceptions": _exceptions(int(params.get("top", 25)), identity=identity),
            }
        elif action == "p2p_exceptions":
            result = {"exceptions": _exceptions(int(params.get("top", 50)), identity=identity)}
        elif action == "p2p_aging":
            result = {"aging": _aging()}
        elif action == "p2p_review_queue":
            result = {"review_queue": _review_queue()}
        elif action == "p2p_interface_status":
            # Read-only view of the AP Open Interface pipeline (pending vs imported) for the
            # AI-ingested source — lets the UI show what's in the interface and confirm import.
            result = {"interface": _call_clob(
                "APPS.XX_P2P_INGEST_PKG.GET_INTERFACE_STATUS", [], trailing=[int(params.get("top", 25))])}
        elif action == "p2p_simulate":
            result = {"simulation": _call_clob(
                "COLLECTIONS_AI.XX_WORKING_CAPITAL_PKG.SIMULATE",
                [int(params.get("top_ar", 10)), float(params.get("tol_pct", 5))])}
        elif action == "p2p_action_plan":
            result = {"action_plan": _call_clob(
                "COLLECTIONS_AI.XX_WORKING_CAPITAL_PKG.ACTION_PLAN",
                [int(params.get("top", 8))]) or []}
        elif action == "p2p_predict":
            result = {"predictions": _call_clob(
                "COLLECTIONS_AI.XX_WORKING_CAPITAL_PKG.PREDICT_PAYMENT",
                [int(params.get("top", 15))]) or []}
        else:  # p2p_vendor_summary
            result = {"vendors": _vendor_summary(int(params.get("top", 20)))}
        return _resp(200, {"status": "success", "action": action, "result": result})
    except Exception as e:
        logger.exception("p2p action failed")
        return _resp(500, {"status": "error", "action": action, "error": str(e)})


def _resp(code: int, body: dict) -> dict:
    return {"statusCode": code, "body": json.dumps(body, default=str)}
