"""
EBS Finance MCP server — exposes the solution's governed ERP tools to Amazon Quick
(and any MCP client) over streamable HTTP, hosted on Amazon Bedrock AgentCore Runtime.

WHY THIS EXISTS
  Amazon Quick is a *user-facing* agentic workspace (chat, connectors to Outlook / Slack /
  SharePoint, scheduled automations). Quick includes an MCP *client*: you publish a remote
  MCP server endpoint and Quick discovers the tools and lets its agents/automations invoke
  them using the customer's own authentication and governance. This module is that MCP
  server for the EBS Finance solution. It lets Quick, for example:
    • run scheduled/ad-hoc ERP analytics ("what's blocking payments this morning?"),
    • pull the working-capital action plan into an email/Slack digest,
    • turn an emailed/Slack'd invoice attachment into a document in the AP capture inbox
      (submit_invoice_to_inbox) — the existing extract→Payables Open Interface pipeline then
      processes it, exactly like the in-app drag-and-drop path.

DESIGN
  This server is deliberately SELF-CONTAINED and decoupled from the Strands agent
  (agent_strands.py) — it does NOT import strands. It calls the SAME audited Oracle PL/SQL
  packages, the SAME collections Lambda, and the SAME S3 invoice inbox that the agent uses,
  so all mutations stay on the audited, seeded-API path (no direct DML, no new business
  logic — the logic lives in the DB packages). Because the agent path is untouched, the
  live UI / AgentCore agent runtime is unaffected by anything here.

AGENTCORE MCP CONTRACT (per AWS docs)
  AgentCore Runtime with --protocol MCP expects the server at 0.0.0.0:8000/mcp over
  streamable-HTTP. FastMCP provides exactly that. stateless_http=True is the recommended
  default. Tool inputSchemas are generated from the type hints + docstrings as JSON Schema
  Draft 7 (Quick validates Draft 7; `required` is emitted as an array, which FastMCP does).
  Auth is handled by AgentCore's inbound OAuth authorizer (Cognito JWT); Quick uses the
  OAuth 2.0 client_credentials (service-to-service) flow to obtain the bearer token.

ENV
  ORACLE_SECRET_NAME / ORACLE_HOST / ORACLE_PORT / ORACLE_SERVICE — DB connection (Secrets
  Manager holds the password). P2P_INBOX_BUCKET — the invoice capture bucket. MODEL_ID /
  AWS_REGION — Bedrock model for NL->SQL. P2P_ORG_SCOPE / P2P_ORG_CSV / P2P_USER — optional
  VPD org scoping (defaults to ALL, unchanged behaviour).
"""

import os
import re
import json
import uuid
import base64
import logging

import boto3
import oracledb
from mcp.server.fastmcp import FastMCP

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ebs-finance-mcp")

# AgentCore MCP contract: bind 0.0.0.0, stateless streamable-HTTP. The default FastMCP
# path is /mcp on port 8000 — matching what AgentCore Runtime expects for --protocol MCP.
# Binding 0.0.0.0 is required by AgentCore Runtime; the container network boundary is the
# isolation and access is Cognito-authenticated.
mcp = FastMCP(host="0.0.0.0", stateless_http=True)  # nosec B104

_pool = None


# ---------------------------------------------------------------------------
# Shared DB access (same connection pattern the agent tools use; the audited
# PL/SQL packages own all mutation + audit — nothing here does direct DML).
# ---------------------------------------------------------------------------
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
        logger.info("Oracle pool created (%s:%s/%s)", host, port, service)
    return _pool


def _apply_vpd(cur) -> None:
    """Apply the VPD org scope for this session (defaults to ALL — unchanged behaviour)."""
    try:
        cur.callproc("COLLECTIONS_AI.XX_P2P_SEC_PKG.SET_IDENTITY",
                     [os.environ.get("P2P_USER", "quick"),
                      os.environ.get("P2P_ORG_CSV", ""),
                      os.environ.get("P2P_ORG_SCOPE", "ALL")])
    except Exception:
        pass  # VPD is optional


def _call_clob(proc: str, args: list) -> object:
    """Call a package proc whose last param is an OUT CLOB; return parsed JSON."""
    pool = _get_pool()
    with pool.acquire() as conn:
        with conn.cursor() as cur:
            _apply_vpd(cur)
            out = cur.var(oracledb.DB_TYPE_CLOB)
            cur.callproc(proc, args + [out])
            val = out.getvalue()
            txt = val.read() if hasattr(val, "read") else val
            try:
                return json.loads(txt) if txt else {}
            except (TypeError, ValueError):
                return {"raw": txt}


# ---------------------------------------------------------------------------
# NL -> SQL (compact, views-only grounding — the recommended read path)
# ---------------------------------------------------------------------------
_SCHEMA_PROMPT = """You generate ONE read-only Oracle SELECT for an E-Business Suite finance
assistant, using ONLY these COLLECTIONS_AI reporting views over live EBS 12.2 data:

AR (receivables):
  XX_COLL_KPI_V(display_order, metric_label, metric_value, metric_subtext)
  XX_COLL_AGING_V(bucket_order, aging_bucket, total_amount)
  XX_COLL_RISK_CUSTOMERS_V(customer_id, account_number, party_name, total_overdue, max_days_overdue, open_invoices)
  XX_COLL_OPEN_INVOICES_V(customer_id, invoice_number, due_date, amount_due_remaining, days_overdue)
AP (payables):
  XX_P2P_KPI_V(display_order, metric_label, metric_value, metric_subtext)
  XX_P2P_EXCEPTION_QUEUE_V(invoice_id, invoice_num, vendor_name, invoice_amount, hold_type, hold_age_days, exception_reason, priority_score)
  XX_P2P_AGING_V(bucket_order, aging_bucket, invoice_count, total_amount)
  XX_P2P_VENDOR_SUMMARY_V(vendor_id, vendor_name, total_invoices, open_invoices, open_amount, invoices_on_hold)

RULES: output ONE SELECT only (no DML/DDL/PLSQL, no semicolon, no markdown). Cap rows with
FETCH FIRST n ROWS ONLY (default 50) unless asked for a single total. Return only the SQL."""


def _bedrock_sql(question: str) -> str:
    region = os.environ.get("AWS_REGION", "us-east-1")
    model_id = os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
    client = boto3.client("bedrock-runtime", region_name=region)
    resp = client.converse(
        modelId=model_id,
        system=[{"text": _SCHEMA_PROMPT}],
        messages=[{"role": "user", "content": [{"text": question}]}],
        inferenceConfig={"maxTokens": 600, "temperature": 0.0},
    )
    text = resp["output"]["message"]["content"][0]["text"].strip()
    text = re.sub(r"```sql", "", text, flags=re.I).replace("```", "").strip().rstrip(";").strip()
    return text


def _is_safe_select(sql: str) -> bool:
    s = sql.strip().lower()
    if not (s.startswith("select") or s.startswith("with")):
        return False
    forbidden = (" insert ", " update ", " delete ", " merge ", " drop ", " alter ",
                 " create ", " grant ", " truncate ", "begin ", " call ")
    if any(tok in f" {s} " for tok in forbidden):
        return False
    if ";" in sql.strip().rstrip(";"):
        return False
    return True


# ===========================================================================
# MCP TOOLS  (each becomes a Quick "action" after discovery)
# ===========================================================================
@mcp.tool()
def query_ebs_finance(question: str) -> str:
    """Answer a natural-language question about live Oracle EBS finance data (receivables and
    payables). The question is translated to a single read-only SELECT over governed reporting
    views and executed against the live 26ai database — no data warehouse, no replication lag.

    Examples: "What is our total outstanding and overdue?", "Top 10 customers by overdue amount",
    "Which vendors have the most invoices on hold?".

    Args:
        question: A natural-language finance/analytics question.

    Returns:
        JSON with the generated SQL, columns and rows (or an error).
    """
    sql = None
    try:
        sql = _bedrock_sql(question)
        if not _is_safe_select(sql):
            return json.dumps({"status": "error", "question": question,
                               "error": "Generated SQL failed the read-only guard.",
                               "generated_sql": sql})
        pool = _get_pool()
        with pool.acquire() as conn:
            with conn.cursor() as cur:
                cur.execute(sql)
                cols = [c[0].lower() for c in cur.description]
                rows = []
                for r in cur.fetchall():
                    rows.append({k: (v.read() if hasattr(v, "read") else v)
                                 for k, v in zip(cols, r)})
        return json.dumps({"status": "success", "question": question,
                           "generated_sql": sql, "row_count": len(rows), "rows": rows},
                          default=str)
    except Exception as e:
        logger.exception("query_ebs_finance failed")
        return json.dumps({"status": "error", "question": question,
                           "error": str(e), "generated_sql": sql}, default=str)


@mcp.tool()
def search_finance_knowledge_base(query: str, top_k: int = 5) -> str:
    """Semantic search over the finance knowledge base (collections policies, SOPs, and
    dunning templates) using in-database AI Vector Search. Use this to ground a decision in
    policy before recommending an escalation, or to fetch the right template/SOP.

    Args:
        query: What to look for, in natural language.
        top_k: Number of results to return (default 5).

    Returns:
        JSON with matched documents (doc_type, summary, content, similarity).
    """
    try:
        pool = _get_pool()
        with pool.acquire() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT doc_type, summary, content, similarity "
                    "FROM TABLE(xx_kb_search_pkg.search(:q, :k))",
                    {"q": query, "k": int(top_k)},
                )
                cols = [c[0].lower() for c in cur.description]
                rows = [{k: (v.read() if hasattr(v, "read") else v)
                         for k, v in zip(cols, r)} for r in cur.fetchall()]
        return json.dumps({"status": "success", "query": query,
                           "results_count": len(rows), "results": rows}, default=str)
    except Exception as e:
        logger.exception("search_finance_knowledge_base failed")
        return json.dumps({"status": "error", "query": query, "error": str(e)})


@mcp.tool()
def get_ap_invoice_exceptions(top_k: int = 25) -> str:
    """List Accounts Payable invoices stuck in exception (on hold or failing 2/3-way match),
    ranked by priority (value weighted by how long they've been blocked). Use this for
    "what's blocking payments?" digests and morning reviews.

    Args:
        top_k: Maximum rows to return (default 25).

    Returns:
        JSON list of exceptions (invoice_num, vendor_name, amount, hold_type, hold_age_days,
        exception_reason, priority_score).
    """
    try:
        data = _call_clob("APPS.XX_P2P_AP_PKG.GET_INVOICE_EXCEPTIONS", [])
        rows = data if isinstance(data, list) else data.get("raw", [])
        if isinstance(rows, list):
            rows = rows[:int(top_k)]
        return json.dumps({"status": "success",
                           "count": len(rows) if isinstance(rows, list) else 0,
                           "exceptions": rows}, default=str)
    except Exception as e:
        logger.exception("get_ap_invoice_exceptions failed")
        return json.dumps({"status": "error", "error": str(e)})


@mcp.tool()
def get_working_capital_action_plan(top: int = 8) -> str:
    """Return a ranked ACTION PLAN of the highest-value next moves across receivables and
    payables right now: which overdue customers to chase (with a recommended dunning level)
    and which AP holds are within policy to release. Read-only — proposes the plan; any
    execution stays gated behind human approval. Ideal for a scheduled digest to a manager.

    Args:
        top: Number of ranked moves to return (default 8).

    Returns:
        JSON array of moves (rank, domain AR/AP, action_type, ref_id, name, value, age_days,
        recommended_action, within_policy).
    """
    try:
        data = _call_clob("COLLECTIONS_AI.XX_WORKING_CAPITAL_PKG.ACTION_PLAN", [int(top)])
        rows = data if isinstance(data, list) else data.get("raw", data)
        return json.dumps({"status": "success",
                           "count": len(rows) if isinstance(rows, list) else 0,
                           "action_plan": rows}, default=str)
    except Exception as e:
        logger.exception("get_working_capital_action_plan failed")
        return json.dumps({"status": "error", "error": str(e)})


@mcp.tool()
def predict_customer_payment(top: int = 15) -> str:
    """Predict, from paid history, which customers with open receivables are likely to pay
    late (average days late, a risk band, and a predicted pay date). Read-only. Use for
    proactive collections outreach driven from Quick.

    Args:
        top: Number of customers to return, ranked by expected lateness (default 15).

    Returns:
        JSON array (customer_id, party_name, account_number, open_amount, avg_days_late,
        risk_band, predicted_pay_date).
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


@mcp.tool()
def get_invoice_review_queue() -> str:
    """List invoices awaiting human review because their AI extraction confidence was below
    the straight-through threshold (the human-in-the-loop queue for ingested invoices).

    Returns:
        JSON with the review queue (staging_id, vendor_name, invoice_num, amount, confidence).
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


@mcp.tool()
def create_ap_note(invoice_id: int, note_text: str) -> str:
    """Attach an audited note to an AP invoice via the seeded, audited APPS package (no direct
    DML). Use when Quick needs to record context on an invoice (for example, a summary of an
    email thread or a follow-up commitment).

    Args:
        invoice_id: The AP invoice_id to annotate.
        note_text: The note content.

    Returns:
        JSON with the note result.
    """
    try:
        res = _call_clob("APPS.XX_P2P_AP_PKG.CREATE_AP_NOTE", [int(invoice_id), note_text])
        return json.dumps({"status": "success", "result": res}, default=str)
    except Exception as e:
        logger.exception("create_ap_note failed")
        return json.dumps({"status": "error", "error": str(e)})


@mcp.tool()
def submit_invoice_to_inbox(filename: str, content_base64: str) -> str:
    """Drop an invoice document (PDF or image) into the AP capture inbox so the existing
    extraction pipeline processes it. This is how Amazon Quick turns an emailed or Slack'd
    invoice attachment into an EBS invoice: Quick base64-encodes the attachment and calls this
    tool; the object lands in the S3 inbox under incoming/, which triggers the extract Lambda
    (Bedrock vision -> anomaly check -> seeded Payables Open Interface, or the human review
    queue if confidence is low). This tool only STAGES the document for capture — it never pays
    or approves anything.

    Args:
        filename: Original file name (used to preserve the extension, for example "acme.pdf").
        content_base64: The file contents, base64-encoded.

    Returns:
        JSON with the S3 key the document was written to and next-step guidance.
    """
    bucket = os.environ.get("P2P_INBOX_BUCKET")
    if not bucket:
        return json.dumps({"status": "error", "error": "P2P_INBOX_BUCKET is not configured."})
    try:
        raw = base64.b64decode(content_base64, validate=False)
    except Exception as e:
        return json.dumps({"status": "error", "error": f"content_base64 is not valid base64: {e}"})
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", (filename or "invoice").strip()) or "invoice"
    key = f"incoming/quick-{uuid.uuid4().hex[:12]}-{safe}"
    ext = safe.rsplit(".", 1)[-1].lower() if "." in safe else ""
    ctype = {"pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg",
             "jpeg": "image/jpeg", "tif": "image/tiff", "tiff": "image/tiff"}.get(ext,
             "application/octet-stream")
    try:
        s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"))
        s3.put_object(Bucket=bucket, Key=key, Body=raw, ContentType=ctype)
        return json.dumps({"status": "success", "bucket": bucket, "key": key,
                           "bytes": len(raw),
                           "note": "Staged to the AP capture inbox. Extraction runs "
                                   "automatically (~15s); check the review queue if the "
                                   "invoice was low-confidence."}, default=str)
    except Exception as e:
        logger.exception("submit_invoice_to_inbox failed")
        return json.dumps({"status": "error", "error": str(e)})


if __name__ == "__main__":
    # Streamable-HTTP MCP server on 0.0.0.0:8000/mcp (AgentCore --protocol MCP contract).
    mcp.run(transport="streamable-http")
