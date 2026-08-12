"""
p2p tools — Purchase-to-Pay invoice exception analysis + audited AP write-back.

Two Strands tools for the agent:
  • get_invoice_exceptions(...)   READ  — the exception queue (held/mismatched invoices)
  • diagnose_match_exception(...) READ  — per-invoice 2/3-way match variance detail
  • execute_p2p_action(action,..) WRITE — gated, audited AP actions via APPS.XX_P2P_AP_PKG

All DB access is via oracledb against the COLLECTIONS_AI views / the audited APPS package
— the SAME proven path the collections tools use (verified live 2026-06-30). Writes never
do direct DML from the agent; the definer-rights APPS package owns the mutation + audit.
Hold release is treated as approval-gated: the tool requires an explicit p_reason and the
agent is instructed to confirm with the user before calling it.
"""

import os
import json
import logging

import oracledb
import boto3
from strands import tool

from tools.authz import require, NotAuthorized, denial_json

logger = logging.getLogger(__name__)

_pool = None


def _get_db_credentials() -> dict:
    secret_name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    return json.loads(client.get_secret_value(SecretId=secret_name)["SecretString"])


def _get_pool() -> "oracledb.ConnectionPool":
    global _pool
    if _pool is None:
        creds = _get_db_credentials()
        host = os.environ.get("ORACLE_HOST") or creds.get("host")
        port = int(os.environ.get("ORACLE_PORT") or creds.get("port") or 1521)
        service = os.environ.get("ORACLE_SERVICE") or creds.get("service_name")
        if not host or not service:
            raise RuntimeError(
                "Oracle connection not configured: set ORACLE_HOST/ORACLE_SERVICE (env) or "
                "host/service_name in the Secrets Manager secret — no demo default is assumed."
            )
        _pool = oracledb.create_pool(
            user=creds.get("username", "COLLECTIONS_AI"),
            password=creds["password"],
            dsn=f"{host}:{port}/{service}",
            min=1, max=5, increment=1,
        )
    return _pool


def _call_clob(proc: str, args: list) -> dict:
    """Call an APPS.XX_P2P_AP_PKG proc whose last param is an OUT CLOB; return parsed JSON."""
    pool = _get_pool()
    with pool.acquire() as conn:
        with conn.cursor() as cur:
            # Apply VPD org scope for this session if configured (env P2P_ORG_SCOPE/P2P_ORG_CSV).
            # Defaults to ALL (aggregate) when unset, so behaviour is unchanged unless scoping is on.
            try:
                cur.callproc("COLLECTIONS_AI.XX_P2P_SEC_PKG.SET_IDENTITY",
                             [os.environ.get("P2P_USER", "agent"),
                              os.environ.get("P2P_ORG_CSV", ""),
                              os.environ.get("P2P_ORG_SCOPE", "ALL")])
            except Exception:
                pass  # VPD optional
            out = cur.var(oracledb.DB_TYPE_CLOB)
            cur.callproc(proc, args + [out])
            val = out.getvalue()
            txt = val.read() if hasattr(val, "read") else val
            try:
                return json.loads(txt) if txt else {}
            except (TypeError, ValueError):
                return {"raw": txt}


@tool
def get_invoice_exceptions(top_k: int = 25) -> str:
    """
    List Accounts Payable invoices stuck in exception (on hold or failing 2/3-way match),
    ranked by priority (invoice value weighted by how long it's been blocked).

    Use this to answer "what's blocking payments?", "show the AP exception queue", or to
    pick the highest-impact invoices to resolve first.

    Args:
        top_k: max rows to return (default 25).

    Returns:
        JSON string: list of exceptions with invoice_num, vendor_name, amount, hold_type,
        hold_age_days, exception_reason, priority_score.
    """
    try:
        data = _call_clob("APPS.XX_P2P_AP_PKG.GET_INVOICE_EXCEPTIONS", [])
        rows = data if isinstance(data, list) else data.get("raw", [])
        if isinstance(rows, list):
            rows = rows[:top_k]
        return json.dumps({"status": "success", "count": len(rows) if isinstance(rows, list) else 0,
                           "exceptions": rows}, default=str)
    except Exception as e:
        logger.exception("get_invoice_exceptions failed")
        return json.dumps({"status": "error", "error": str(e)})


@tool
def diagnose_match_exception(invoice_id: int) -> str:
    """
    Explain WHY a specific AP invoice is on hold / failing match: returns the per-line
    2/3-way match detail (invoice vs PO price, invoice qty vs ordered vs received) so the
    cause (price variance, over-receipt, over-order, no PO) is clear.

    Use this when asked "why is invoice X on hold?" before proposing or taking an action.
    Pair with search_knowledge_base to ground the resolution in AP tolerance/approval policy.

    Args:
        invoice_id: the AP invoice_id to diagnose.

    Returns:
        JSON string with the invoice's line-level match variance detail.
    """
    try:
        data = _call_clob("APPS.XX_P2P_AP_PKG.DIAGNOSE_MATCH_EXCEPTION", [invoice_id])
        return json.dumps({"status": "success", "diagnosis": data}, default=str)
    except Exception as e:
        logger.exception("diagnose_match_exception failed")
        return json.dumps({"status": "error", "invoice_id": invoice_id, "error": str(e)})


VALID_P2P_ACTIONS = ["release_ap_hold", "validate_invoice", "create_ap_note",
                     "manual_approve_invoice", "propose_payment"]


@tool
def simulate_working_capital(top_ar_customers: int = 10, price_tolerance_pct: float = 5) -> str:
    """
    Working-capital WHAT-IF simulator. Projects the cash + DSO/DPO impact of (a) collecting
    the top-N overdue customers and (b) releasing AP holds whose price variance is within
    tolerance. Read-only — computes a before/after projection, takes no action.

    Use for CFO-style questions like "if I collect the top 10 overdue and release the
    in-tolerance holds, what happens to my cash position and DSO this week?".

    Args:
        top_ar_customers: how many of the highest-overdue customers to assume collected.
        price_tolerance_pct: AP price-variance %% treated as within policy (safe to release).

    Returns:
        JSON with before/after ar_open, ap_blocked, dso_days, dpo_days, cash_freed, and the
        DSO improvement — a projection the agent should narrate as an estimate, not a promise.
    """
    try:
        data = _call_clob("COLLECTIONS_AI.XX_WORKING_CAPITAL_PKG.SIMULATE",
                          [int(top_ar_customers), float(price_tolerance_pct)])
        return json.dumps({"status": "success", "simulation": data}, default=str)
    except Exception as e:
        logger.exception("simulate_working_capital failed")
        return json.dumps({"status": "error", "error": str(e)})


@tool
def get_action_plan(top: int = 8) -> str:
    """
    Produce a ranked ACTION PLAN of the highest-value next moves across AR and AP right now:
    which overdue customers to chase (with the recommended dunning level) and which AP holds
    are within policy to release. Read-only — proposes the plan; execution stays gated behind
    execute_collections_action / execute_p2p_action after the user approves.

    Use for "what are the highest-impact actions I should take today?" or to drive a
    one-click "approve all / approve each" worklist.

    Args:
        top: number of ranked moves to return (default 8).

    Returns:
        JSON array of moves: rank, domain (AR/AP), action_type, ref_id, name, value, age_days,
        recommended_action, within_policy (Y/N), entity_id.
    """
    try:
        data = _call_clob("COLLECTIONS_AI.XX_WORKING_CAPITAL_PKG.ACTION_PLAN", [int(top)])
        rows = data if isinstance(data, list) else data.get("raw", data)
        return json.dumps({"status": "success",
                           "count": len(rows) if isinstance(rows, list) else 0,
                           "action_plan": rows}, default=str)
    except Exception as e:
        logger.exception("get_action_plan failed")
        return json.dumps({"status": "error", "error": str(e)})


@tool
def predict_customer_payment(top: int = 15) -> str:
    """
    Predict payment behaviour for customers with open receivables, from their PAID history:
    average days late, a risk band (LOW/MEDIUM/HIGH), and a predicted pay date for the next
    due item. Read-only. Use for proactive collections ("who is likely to slip?").

    Args:
        top: number of customers to return, ranked by expected lateness (default 15).

    Returns:
        JSON array: customer_id, party_name, account_number, open_amount, avg_days_late,
        paid_history, risk_band, predicted_pay_date.
    """
    try:
        data = _call_clob("COLLECTIONS_AI.XX_WORKING_CAPITAL_PKG.PREDICT_PAYMENT", [int(top)])
        rows = data if isinstance(data, list) else data.get("raw", data)
        return json.dumps({"status": "success",
                           "count": len(rows) if isinstance(rows, list) else 0,
                           "predictions": rows}, default=str)
    except Exception as e:
        logger.exception("predict_customer_payment failed")
        return json.dumps({"status": "error", "error": str(e)})


@tool
def check_invoice_anomaly(vendor_name: str, invoice_num: str,
                          invoice_amount: float, invoice_date: str) -> str:
    """
    Duplicate / fraud / anomaly check for an invoice BEFORE ingest. Flags exact duplicates
    (same vendor+number already in AP — dup-payment risk), near-duplicates (same vendor+amount
    within a few days), already-staged scans, and amount outliers vs the vendor's history.
    Read-only. Call this before ingest_invoice; if the verdict is BLOCK/REVIEW, route the
    invoice to human review rather than straight-through.

    Args:
        vendor_name: supplier name as extracted.
        invoice_num: invoice number as extracted.
        invoice_amount: invoice total.
        invoice_date: 'YYYY-MM-DD'.

    Returns:
        JSON: verdict (CLEAR|REVIEW|BLOCK), flags, and detail (duplicate counts, vendor amount profile).
    """
    try:
        pool = _get_pool()
        with pool.acquire() as conn:
            with conn.cursor() as cur:
                out = cur.var(oracledb.DB_TYPE_CLOB)
                cur.callproc("APPS.XX_P2P_ANOMALY_PKG.CHECK_INVOICE",
                             [vendor_name, invoice_num, float(invoice_amount),
                              invoice_date, out])
                val = out.getvalue()
                txt = val.read() if hasattr(val, "read") else val
                return json.dumps({"status": "success",
                                   "check": json.loads(txt) if txt else {}}, default=str)
    except Exception as e:
        logger.exception("check_invoice_anomaly failed")
        return json.dumps({"status": "error", "error": str(e)})


@tool
def get_invoice_review_queue() -> str:
    """
    List invoices awaiting human review because their AI extraction confidence was below
    the straight-through threshold (the human-in-the-loop queue for ingested invoices).

    Use when asked "what invoices need review?" or before approving a staged invoice.

    Returns:
        JSON string with the review queue (staging_id, vendor_name, invoice_num, amount, confidence).
    """
    try:
        data = _call_clob("APPS.XX_P2P_INGEST_PKG.GET_REVIEW_QUEUE", [])
        rows = data if isinstance(data, list) else data.get("raw", [])
        return json.dumps({"status": "success",
                           "count": len(rows) if isinstance(rows, list) else 0,
                           "review_queue": rows}, default=str)
    except Exception as e:
        logger.exception("get_invoice_review_queue failed")
        return json.dumps({"status": "error", "error": str(e)})


@tool
def ingest_invoice(invoice: dict, source_uri: str = "manual://agent") -> str:
    """
    Stage an already-extracted invoice into Oracle EBS via the SEEDED Payables Open
    Interface (AP_INVOICES_INTERFACE). High-confidence invoices stage straight through;
    low-confidence go to the human review queue. Does NOT pay or approve the invoice.

    Args:
        invoice: dict with vendor_name, invoice_num, invoice_date ('YYYY-MM-DD'),
                 invoice_amount, currency, org_id, po_number, lines [{amount,quantity,
                 unit_price,description,po_line_number}], confidence (0..1).
        source_uri: where the invoice came from (e.g. an S3 URI).

    Returns:
        JSON string with the staging result (staging_id, lifecycle STAGED|NEEDS_REVIEW).
    """
    try:
        pool = _get_pool()
        with pool.acquire() as conn:
            with conn.cursor() as cur:
                out = cur.var(oracledb.DB_TYPE_CLOB)
                cur.callproc("APPS.XX_P2P_INGEST_PKG.STAGE_INVOICE", [
                    source_uri, invoice.get("vendor_name"), invoice.get("invoice_num"),
                    invoice.get("invoice_date"), float(invoice.get("invoice_amount") or 0),
                    invoice.get("currency", "USD"), int(invoice.get("org_id") or 204),
                    invoice.get("po_number"), json.dumps(invoice.get("lines", [])),
                    float(invoice.get("confidence") or 0), None, out,
                ])
                val = out.getvalue()
                txt = val.read() if hasattr(val, "read") else val
                return json.dumps({"status": "success",
                                   "result": json.loads(txt) if txt else {}}, default=str)
    except Exception as e:
        logger.exception("ingest_invoice failed")
        return json.dumps({"status": "error", "error": str(e)})


@tool
def execute_p2p_action(action: str, parameters: dict) -> str:
    """
    Execute an audited Purchase-to-Pay action on Oracle EBS via the APPS.XX_P2P_AP_PKG
    package (audited; no direct DML).

    Actions:
    - validate_invoice   (params: {invoice_id}) — report live validation/hold state. SAFE/read-like.
    - create_ap_note     (params: {invoice_id, note_text}) — attach an audited note.
    - propose_payment    (params: {invoice_id, pay_date?}) — DRAFT a payment proposal only; never
                         pays or selects the invoice. Reports amount/due/holds for human authorization.
    - manual_approve_invoice (params: {invoice_id, reason}) — GATED: set the invoice to MANUALLY
                         APPROVED (real EBS status). Only after the user approves and holds/exceptions
                         are resolved. Audited.
    - release_ap_hold    (params: {invoice_id, hold_type, reason}) — RELEASE a hold. GATED:
                         only call after the user has explicitly approved releasing the hold,
                         and only when the variance is within policy/tolerance. Always include
                         a clear reason. Reversible/audited.

    Args:
        action: one of the actions above.
        parameters: action-specific parameters.

    Returns:
        JSON string with the action result.
    """
    return run_p2p_action(action, parameters)


def run_p2p_action(action: str, parameters: dict) -> str:
    """Plain (non-@tool) implementation of a P2P action.

    Separated from the Strands @tool wrapper so the runtime's deterministic
    confirm-then-execute path (tools.pending_action) can call the SAME audited, RBAC-gated
    logic without routing through the LLM.
    """
    parameters = parameters or {}
    if action not in VALID_P2P_ACTIONS:
        return json.dumps({"status": "error",
                           "error": f"Invalid action: {action}. Valid: {VALID_P2P_ACTIONS}"})

    # Deterministic RBAC gate — deny AP write actions the caller's Cognito group(s) don't
    # grant, BEFORE any DB/EBS call. propose_payment/validate_invoice are read-like and pass.
    try:
        require(action)
    except NotAuthorized as na:
        logger.info("p2p action denied by RBAC: %s", action)
        return denial_json(action, str(na))

    try:
        inv = int(parameters.get("invoice_id"))
        if action == "validate_invoice":
            res = _call_clob("APPS.XX_P2P_AP_PKG.VALIDATE_INVOICE", [inv])
        elif action == "create_ap_note":
            res = _call_clob("APPS.XX_P2P_AP_PKG.CREATE_AP_NOTE",
                             [inv, parameters.get("note_text", "")])
        elif action == "manual_approve_invoice":
            # Approval-gated: only after the user approves and exceptions are resolved.
            reason = parameters.get("reason")
            if not reason:
                return json.dumps({"status": "error",
                                   "error": "manual_approve_invoice requires a 'reason' (gated action)."})
            res = _call_clob("APPS.XX_P2P_AP_PKG.MANUAL_APPROVE_INVOICE", [inv, reason])
        elif action == "propose_payment":
            # Proposal only — never pays. Safe to call.
            res = _call_clob("APPS.XX_P2P_AP_PKG.PROPOSE_PAYMENT",
                             [inv, parameters.get("pay_date")])
        else:  # release_ap_hold (gated)
            reason = parameters.get("reason")
            if not reason:
                return json.dumps({"status": "error",
                                   "error": "release_ap_hold requires a 'reason' (approval-gated action)."})
            res = _call_clob("APPS.XX_P2P_AP_PKG.RELEASE_AP_HOLD",
                             [inv, parameters.get("hold_type"), reason])
        return json.dumps({"status": "success", "action": action, "result": res}, default=str)
    except Exception as e:
        logger.exception("execute_p2p_action failed")
        return json.dumps({"status": "error", "action": action, "error": str(e)})
