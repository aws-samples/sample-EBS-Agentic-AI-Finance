"""
execute_oracle_ai_query — Natural-language analytics over live Oracle EBS AR data.

NL->SQL PATH (non-Autonomous 26ai):
  In-database SELECT AI (DBMS_CLOUD_AI) is configured (profile EBS_COLLECTIONS) but the
  23.26.2 DBMS_CLOUD_AI Bedrock signer scopes SigV4 as `s3://` and fails (ORA-20401 / hung
  session). Confirmed an engine RU nuance, not config. So per the design's documented primary
  path for non-Autonomous, this tool does NL->SQL in the AGENT:
    1. Bedrock (boto3, Claude) generates a single read-only SELECT from a curated EBS AR schema
       prompt (the same object_list SELECT AI would use), grounded on the deterministic views.
    2. The SQL is guard-railed (single statement, SELECT-only) and executed via oracledb.
    3. Rows are returned as JSON.

  Bedrock IAM keys are the same long-lived creds proven working via CLI converse.
  If a future DB RU fixes the aws signer, set USE_IN_DB_SELECT_AI=1 to switch back to
  DBMS_CLOUD_AI.GENERATE without changing the agent.
"""

import os
import re
import json
import logging
import oracledb
import boto3

from strands import tool

logger = logging.getLogger(__name__)

_pool = None

# Curated EBS AR schema + the deterministic views, given to the model as grounding.
SCHEMA_PROMPT = """You generate Oracle SQL for an E-Business Suite AR (Accounts Receivable) collections
assistant. Use ONLY these objects (live EBS 12.2 data in the configured Oracle PDB):

Pre-built reporting VIEWS owned by COLLECTIONS_AI (PREFER these — they are correct and fast):
  XX_COLL_KPI_V(display_order, metric_label, metric_value, metric_subtext, icon_class)
  XX_COLL_AGING_V(bucket_order, aging_bucket, total_amount)
  XX_COLL_RISK_CUSTOMERS_V(customer_id, account_number, party_name, total_overdue, max_days_overdue, open_invoices)
  XX_COLL_TREND_V(period_label, period_order, overdue_amount)
  XX_COLL_CUSTOMER_SUMMARY_V(customer_id, party_name, account_number, total_overdue, credit_hold_flag, open_invoices)
  XX_COLL_OPEN_INVOICES_V(customer_id, invoice_number, due_date, amount_due_remaining, days_overdue)

Base AR tables (only if a view does not cover the question):
  AR.AR_PAYMENT_SCHEDULES_ALL(customer_id, amount_due_remaining, due_date, status='OP' for open, customer_trx_id)
  AR.HZ_CUST_ACCOUNTS(cust_account_id, account_number, party_id)
  AR.HZ_PARTIES(party_id, party_name)
  AR.HZ_CUSTOMER_PROFILES(cust_account_id, credit_hold, site_use_id)
  AR.RA_CUSTOMER_TRX_ALL(customer_trx_id, trx_number)

Purchase-to-Pay (AP/PO) reporting VIEWS owned by COLLECTIONS_AI (PREFER these for payables questions):
  XX_P2P_KPI_V(display_order, metric_label, metric_value, metric_subtext)
  XX_P2P_HOLDS_V(invoice_id, invoice_num, vendor_name, hold_type, hold_reason, invoice_amount, hold_age_days)
  XX_P2P_MATCH_V(invoice_id, invoice_num, line_number, po_number, match_status, invoice_unit_price, po_unit_price, price_variance_pct, quantity_invoiced, po_quantity, qty_received)
  XX_P2P_EXCEPTION_QUEUE_V(invoice_id, invoice_num, vendor_name, invoice_amount, hold_type, hold_age_days, exception_reason, priority_score)
  XX_P2P_APPROVAL_V(invoice_id, invoice_num, vendor_name, invoice_amount, wfapproval_status, age_days)
  XX_P2P_AGING_V(bucket_order, aging_bucket, invoice_count, total_amount)
  XX_P2P_VENDOR_SUMMARY_V(vendor_id, vendor_name, total_invoices, open_invoices, open_amount, invoices_on_hold)
  XX_P2P_PIPELINE_V(received, extracted, matched, approved, scheduled, paid)

RULES:
- Output ONE single SELECT statement only. No DML/DDL, no PL/SQL, no semicolon, no markdown fences.
- Open items: status='OP' AND amount_due_remaining>0. Overdue: due_date < TRUNC(SYSDATE).
- Always cap rows with FETCH FIRST n ROWS ONLY (default 50) unless the user asks for a single total.
- Return only the SQL text."""


def _get_db_credentials() -> dict:
    secret_name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])


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
        dsn = f"{host}:{port}/{service}"
        _pool = oracledb.create_pool(
            user=creds.get("username", "COLLECTIONS_AI"),
            password=creds["password"],
            dsn=dsn,
            min=1,
            max=5,
            increment=1,
        )
        logger.info(f"Oracle connection pool created: {dsn}")
    return _pool


def _bedrock_generate_sql(question: str) -> str:
    """Generate a single read-only SELECT from the question via Bedrock Claude."""
    region = os.environ.get("AWS_REGION", "us-east-1")
    model_id = os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
    client = boto3.client("bedrock-runtime", region_name=region)

    resp = client.converse(
        modelId=model_id,
        system=[{"text": SCHEMA_PROMPT}],
        messages=[{"role": "user", "content": [{"text": question}]}],
        inferenceConfig={"maxTokens": 600, "temperature": 0.0},
    )
    text = resp["output"]["message"]["content"][0]["text"].strip()
    # strip markdown fences / stray semicolons if the model added them
    text = re.sub(r"```sql", "", text, flags=re.I)
    text = text.replace("```", "").strip().rstrip(";").strip()
    return text


def _is_safe_select(sql: str) -> bool:
    s = sql.strip().lower()
    if not s.startswith("select") and not s.startswith("with"):
        return False
    forbidden = (" insert ", " update ", " delete ", " merge ", " drop ",
                 " alter ", " create ", " grant ", " truncate ", "begin ", " call ")
    padded = f" {s} "
    if any(tok in padded for tok in forbidden):
        return False
    if ";" in sql.strip().rstrip(";"):  # only a single statement
        return False
    return True


@tool
def execute_oracle_ai_query(question: str) -> str:
    """
    Answer a natural-language question about live Oracle EBS AR data.

    The question is translated to a single read-only Oracle SELECT (grounded on the
    COLLECTIONS_AI reporting views over live EBS) and executed against the 26ai database.
    No data warehouse or replication — this queries the source of truth directly.

    Args:
        question: A natural language question about AR/collections data. Examples:
                  - "What is our total outstanding and overdue?"
                  - "Show me the top 10 highest risk customers by overdue amount"
                  - "What are the AR aging buckets?"
                  - "List open invoices for customer 1007 over 90 days overdue"

    Returns:
        JSON string with the generated SQL, column names and rows, or an error message.
    """
    # Optional switch back to in-DB SELECT AI if a future RU fixes the AWS signer.
    use_in_db = os.environ.get("USE_IN_DB_SELECT_AI", "0") == "1"
    profile = os.environ.get("SELECT_AI_PROFILE", "EBS_COLLECTIONS")

    try:
        sql = None
        if not use_in_db:
            sql = _bedrock_generate_sql(question)
            if not _is_safe_select(sql):
                return json.dumps({
                    "status": "error",
                    "question": question,
                    "error": "Generated SQL failed the read-only single-statement guard.",
                    "generated_sql": sql,
                })

        pool = _get_pool()
        with pool.acquire() as conn:
            with conn.cursor() as cursor:
                if use_in_db:
                    # Bind the profile name instead of f-string concatenation (avoids SQL
                    # injection via the SELECT_AI_PROFILE env var / any future dynamic source).
                    cursor.execute(
                        "BEGIN DBMS_CLOUD_AI.SET_PROFILE(:prof); END;",
                        {"prof": profile},
                    )
                    cursor.execute(
                        "SELECT DBMS_CLOUD_AI.GENERATE(:p, :prof, 'runsql') FROM dual",
                        {"p": question, "prof": profile},
                    )
                    row = cursor.fetchone()
                    out = row[0].read() if row and hasattr(row[0], "read") else (row[0] if row else None)
                    return json.dumps({"status": "success", "question": question, "result": out})

                cursor.execute(sql)
                columns = [c[0].lower() for c in cursor.description]
                rows = []
                for r in cursor.fetchall():
                    d = {}
                    for k, v in zip(columns, r):
                        d[k] = v.read() if hasattr(v, "read") else v
                    rows.append(d)
                return json.dumps({
                    "status": "success",
                    "question": question,
                    "generated_sql": sql,
                    "row_count": len(rows),
                    "rows": rows,
                }, default=str)

    except oracledb.Error as e:
        logger.error(f"Oracle error: {e}")
        return json.dumps({"status": "error", "question": question,
                           "error": str(e), "generated_sql": sql})
    except Exception as e:
        logger.error(f"NL->SQL error: {e}")
        return json.dumps({"status": "error", "question": question, "error": str(e)})
