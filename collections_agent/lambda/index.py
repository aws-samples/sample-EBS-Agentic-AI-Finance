"""
ebs-collections-26ai Lambda — collections write-back actions via ISG REST.

VPC-attached. Reaches the EBS app tier (ISG REST on :8000 / oafm :7601) and the
Oracle 26ai DB. Credentials come from Secrets Manager (oracle-26ai-collections-cred).

This is the SOX-compliant write path: all mutations go through ISG REST -> EBS
public APIs (audited), never direct DML. Read actions (overdue customers, customer
details) are served from the COLLECTIONS_AI reporting views via oracledb.

Invoked by the agent runtime (execute_collections_action tool) or directly.
Event shape: {"action": "<name>", "parameters": {...}}
"""

import os
import json
import logging

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_secret_cache = None

VALID_ACTIONS = [
    "get_overdue_customers",
    "get_customer_details",
    "get_policy_documents",
    "get_tolerance_reconciliation",
    "sync_policy_tolerance",
    "place_credit_hold",
    "release_credit_hold",
    "create_collections_note",
    "apply_order_holds",
    "release_order_holds",
    "create_collections_task",
    "send_dunning_letter",
    "send_payment_reminder",
]

READ_ACTIONS = {"get_overdue_customers", "get_customer_details", "get_policy_documents",
                "get_tolerance_reconciliation"}


def _get_secret() -> dict:
    global _secret_cache
    if _secret_cache is None:
        name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
        region = os.environ.get("AWS_REGION_NAME", os.environ.get("AWS_REGION", "us-east-1"))
        sm = boto3.client("secretsmanager", region_name=region)
        _secret_cache = json.loads(sm.get_secret_value(SecretId=name)["SecretString"])
    return _secret_cache


# ---------------------------------------------------------------------------
# READ actions — served from the COLLECTIONS_AI reporting views (oracledb)
# ---------------------------------------------------------------------------
def _db_query(sql: str, binds: dict = None) -> list:
    import oracledb
    s = _get_secret()
    dsn = f"{s['host']}:{s.get('port', 1521)}/{s['service_name']}"
    conn = oracledb.connect(user=s["username"], password=s["password"], dsn=dsn)
    try:
        with conn.cursor() as cur:
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


def _get_overdue_customers(params: dict) -> dict:
    top = int(params.get("top", 20))
    rows = _db_query(
        """SELECT customer_id, account_number, party_name, total_overdue,
                  max_days_overdue, open_invoices
           FROM COLLECTIONS_AI.XX_COLL_RISK_CUSTOMERS_V
           ORDER BY total_overdue DESC NULLS LAST
           FETCH FIRST :top ROWS ONLY""",
        {"top": top},
    )
    return {"customers": rows, "count": len(rows)}


def _get_policy_documents(params: dict) -> dict:
    """Return the human-readable policy / SOP / template docs from the SAME vector-store
    table the agent reasons over (COLLECTIONS_AI.COLLECTIONS_KNOWLEDGE_BASE), so the
    console "Policy library" is guaranteed consistent with what the agent cites.

    Read-only. Optional filters:
      doc_id   — return the full content of a single document (for the viewer pane).
      doc_type — filter the list by type ('policy','sop','template',...).
    Without doc_id the content CLOB is omitted from the list to keep the payload small;
    the viewer requests full content per doc_id on demand.
    """
    doc_id = params.get("doc_id")
    doc_type = params.get("doc_type")

    if doc_id is not None:
        rows = _db_query(
            """SELECT id, doc_type, summary, metadata, content,
                      TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI') AS updated_at
               FROM COLLECTIONS_AI.COLLECTIONS_KNOWLEDGE_BASE
               WHERE id = :id""",
            {"id": int(doc_id)},
        )
        return {"document": rows[0] if rows else None}

    # List view: no CONTENT clob (keeps the message small); title derived from metadata.source.
    # Two fully-static SQL literals selected by whether a doc_type filter was supplied; the
    # value itself is always bound. No string interpolation/concatenation into the SQL, so
    # there is no injection vector (Bandit B608).
    if doc_type:
        rows = _db_query(
            """SELECT id, doc_type, summary, metadata,
                      TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI') AS updated_at
               FROM COLLECTIONS_AI.COLLECTIONS_KNOWLEDGE_BASE
               WHERE doc_type = :dt
               ORDER BY doc_type, JSON_VALUE(metadata, '$.source') NULLS LAST, id""",
            {"dt": doc_type},
        )
    else:
        rows = _db_query(
            """SELECT id, doc_type, summary, metadata,
                      TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI') AS updated_at
               FROM COLLECTIONS_AI.COLLECTIONS_KNOWLEDGE_BASE
               ORDER BY doc_type, JSON_VALUE(metadata, '$.source') NULLS LAST, id""",
            {},
        )
    return {"documents": rows, "count": len(rows)}


def _get_tolerance_reconciliation(params: dict) -> dict:
    """Reconcile the narrative "policy of record" price-variance tolerance against the
    tolerance Payables ACTUALLY enforces per operating unit (live from EBS config).
    Surfaces DRIFT so an approver never trusts a policy doc that has diverged from the
    system. Read-only. Sorted so drifting operating units appear first.
    """
    rows = _db_query(
        """SELECT org_id, operating_unit, tolerance_name,
                  policy_price_pct, enforced_price_pct, enforced_qty_pct,
                  recon_status, recon_note
           FROM COLLECTIONS_AI.XX_P2P_TOLERANCE_RECON_V"""
    )
    drift = sum(1 for r in rows if r.get("recon_status") == "DRIFT")
    in_sync = sum(1 for r in rows if r.get("recon_status") == "IN_SYNC")
    return {
        "rows": rows,
        "count": len(rows),
        "drift_count": drift,
        "in_sync_count": in_sync,
        "policy_price_pct": rows[0]["policy_price_pct"] if rows else None,
    }


def _db_execute(sql: str, binds: dict = None) -> int:
    """Run a DML statement in the COLLECTIONS_AI app schema and commit. Returns rowcount.
    Used only for app-owned settings (XX_POLICY_SETTINGS); never for EBS base tables."""
    import oracledb
    s = _get_secret()
    dsn = f"{s['host']}:{s.get('port', 1521)}/{s['service_name']}"
    conn = oracledb.connect(user=s["username"], password=s["password"], dsn=dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(sql, binds or {})
            rc = cur.rowcount
        conn.commit()
        return rc
    finally:
        conn.close()


def _sync_policy_tolerance(params: dict) -> dict:
    """Reconcile the app's price-variance *policy of record* to what Payables ACTUALLY
    enforces (EBS → app). This is the "Sync from EBS" action behind the Policy library
    button.

    Direction is one-way and safe: EBS is the system of record for the enforced tolerance;
    this updates ONLY the app-owned XX_POLICY_SETTINGS row (COLLECTIONS_AI schema). It does
    NOT write any EBS financial config. After it runs, the reconciliation view reports
    IN_SYNC for the operating unit whose enforced value we adopted.

    params:
      org_id     — operating unit to take the enforced value from (default 204, Vision Ops).
      updated_by — identity performing the sync (for the audit column).
    """
    org_id = int(params.get("org_id", 204))
    updated_by = str(params.get("updated_by") or "ui")[:120]

    # Read the CURRENT reconciliation to find the enforced value + whether we're drifting.
    recon = _get_tolerance_reconciliation({})
    rows = recon.get("rows", [])
    target = next((r for r in rows if r.get("org_id") == org_id), rows[0] if rows else None)
    if not target:
        return {"status": "noop", "message": "No reconciliation rows available to sync from."}

    enforced = target.get("enforced_price_pct")
    old_policy = target.get("policy_price_pct")
    ou = target.get("operating_unit")

    if enforced is None:
        return {"status": "noop", "operating_unit": ou,
                "message": f"{ou} has no tolerance template in Payables — nothing to sync to."}

    if old_policy is not None and float(old_policy) == float(enforced):
        return {"status": "in_sync", "operating_unit": ou,
                "policy_price_pct": enforced,
                "message": f"Already in sync — policy of record and Payables both enforce {enforced}%."}

    # Adopt the EBS-enforced value as the new policy of record (app schema only).
    new_val = str(int(enforced) if float(enforced).is_integer() else enforced)
    _db_execute(
        """MERGE INTO XX_POLICY_SETTINGS t
           USING (SELECT 'PRICE_TOL_PCT' AS k FROM dual) s
           ON (t.setting_key = s.k)
           WHEN MATCHED THEN UPDATE SET setting_value = :v, source = 'EBS_SYNC',
                                        updated_by = :u, updated_at = SYSDATE
           WHEN NOT MATCHED THEN
             INSERT (setting_key, setting_value, source, updated_by, updated_at)
             VALUES ('PRICE_TOL_PCT', :v, 'EBS_SYNC', :u, SYSDATE)""",
        {"v": new_val, "u": updated_by},
    )
    return {
        "status": "synced",
        "operating_unit": ou,
        "old_policy_price_pct": old_policy,
        "policy_price_pct": enforced,
        "message": (f"Policy of record updated from {old_policy}% to {enforced}% to match what "
                    f"Payables enforces for {ou}. The documented tolerance now matches EBS."),
    }


def _fmt_money(v) -> str:
    try:
        return "$" + format(float(v or 0), ",.2f")
    except (TypeError, ValueError):
        return str(v)


def _customer_for_letter(cid: int) -> dict:
    """Header fields for the dunning/reminder merge (name, account, overdue, days, email)."""
    rows = _db_query(
        """SELECT party_name, account_number, total_overdue, max_days_overdue
           FROM COLLECTIONS_AI.XX_COLL_RISK_CUSTOMERS_V WHERE customer_id = :cid""",
        {"cid": cid},
    )
    if not rows:
        rows = _db_query(
            """SELECT party_name, account_number, total_overdue, 0 AS max_days_overdue
               FROM COLLECTIONS_AI.XX_COLL_CUSTOMER_SUMMARY_V WHERE customer_id = :cid""",
            {"cid": cid},
        )
    return rows[0] if rows else {}


def _dunning_template(level: int) -> dict:
    """Fetch the level-appropriate dunning template from the SAME knowledge base the agent
    cites (COLLECTIONS_KNOWLEDGE_BASE), so the sent letter matches the policy of record."""
    rows = _db_query(
        """SELECT content, summary
           FROM COLLECTIONS_AI.COLLECTIONS_KNOWLEDGE_BASE
           WHERE doc_type = 'template'
             AND JSON_VALUE(metadata, '$.level') = :lvl
           FETCH FIRST 1 ROWS ONLY""",
        {"lvl": str(level)},
    )
    return rows[0] if rows else {}


def _merge_letter(template_body: str, cust: dict, level: int) -> str:
    """Substitute the template placeholders with live customer values."""
    body = template_body or (
        "Dear CUSTOMER_NAME,\n\nOur records show TOTAL_AMOUNT outstanding on account "
        "ACCOUNT_NUMBER, overdue by DAYS days. Please arrange payment.\n")
    repl = {
        "CUSTOMER_NAME": str(cust.get("party_name") or "Customer"),
        "ACCOUNT_NUMBER": str(cust.get("account_number") or ""),
        "TOTAL_AMOUNT": _fmt_money(cust.get("total_overdue")),
        "DAYS": str(int(cust.get("max_days_overdue") or 0)),
    }
    for k, v in repl.items():
        body = body.replace(k, v)
    return body


def _send_email(recipient: str, subject: str, body_text: str) -> dict:
    """Send an email via Amazon SES. Sender/region from env (set at deploy). In SES sandbox
    both sender and recipient must be verified identities."""
    sender = os.environ.get("SES_SENDER")
    region = os.environ.get("SES_REGION", os.environ.get("AWS_REGION", "us-east-1"))
    if not sender:
        return {"emailed": False, "reason": "SES_SENDER not configured"}
    ses = boto3.client("ses", region_name=region)
    resp = ses.send_email(
        Source=sender,
        Destination={"ToAddresses": [recipient]},
        Message={
            "Subject": {"Data": subject[:200], "Charset": "UTF-8"},
            "Body": {"Text": {"Data": body_text, "Charset": "UTF-8"}},
        },
    )
    return {"emailed": True, "message_id": resp.get("MessageId"), "recipient": recipient, "sender": sender}


def _record_note(cid: int, text: str) -> int:
    """Write an audited collections note via the APPS package; return the real note_id."""
    res = _db_write("create_collections_note", {"customer_id": cid, "note_text": text})
    try:
        return int(res.get("note_id")) if isinstance(res, dict) else None
    except (TypeError, ValueError):
        return None


def _send_dunning_letter(params: dict) -> dict:
    """Generate a dunning letter from the KB template + live customer data, record it as an
    audited collections note, and email it via SES. Returns exactly what happened (no claim
    of an email unless SES actually accepted it)."""
    cid = int(params.get("customer_id"))
    level = int(params.get("level", 1))
    tone = params.get("tone", "professional")
    cust = _customer_for_letter(cid)
    if not cust:
        return {"status": "error", "message": f"Customer {cid} not found."}

    tmpl = _dunning_template(level)
    body = _merge_letter(tmpl.get("content", ""), cust, level)
    subject = f"Account {cust.get('account_number','')} — "
    subject += {1: "Payment Reminder", 2: "Past Due Notice", 3: "FINAL NOTICE"}.get(level, "Payment Notice")

    # Recipient: customer email if we have one, else the demo recipient (SES sandbox-safe).
    recipient = params.get("recipient") or os.environ.get("DUNNING_DEMO_RECIPIENT")

    note_id = _record_note(cid, f"[Dunning L{level}/{tone}] {subject}\n\n{body}")

    email_res = {"emailed": False, "reason": "no recipient"}
    if recipient:
        try:
            email_res = _send_email(recipient, subject, body)
        except Exception as e:
            logger.exception("SES send failed")
            email_res = {"emailed": False, "reason": str(e)}

    return {
        "status": "success",
        "level": level,
        "tone": tone,
        "customer_id": cid,
        "customer_name": cust.get("party_name"),
        "account_number": cust.get("account_number"),
        "subject": subject,
        "note_id": note_id,
        "note_recorded": note_id is not None,
        "email": email_res,
        "letter_preview": body[:400],
    }


def _send_payment_reminder(params: dict) -> dict:
    """A softer reminder: uses the level-1 template, records an audited note, emails via SES."""
    p = dict(params)
    p["level"] = 1
    p["tone"] = "friendly"
    res = _send_dunning_letter(p)
    if res.get("status") == "success":
        res["type"] = "payment_reminder"
    return res


def _get_customer_details(params: dict) -> dict:
    cid = params.get("customer_id")
    summary = _db_query(
        """SELECT customer_id, party_name, account_number, total_overdue,
                  credit_hold_flag, open_invoices
           FROM COLLECTIONS_AI.XX_COLL_CUSTOMER_SUMMARY_V
           WHERE customer_id = :cid""",
        {"cid": cid},
    )
    invoices = _db_query(
        """SELECT invoice_number, due_date, amount_due_remaining, days_overdue
           FROM COLLECTIONS_AI.XX_COLL_OPEN_INVOICES_V
           WHERE customer_id = :cid
           ORDER BY days_overdue DESC
           FETCH FIRST 100 ROWS ONLY""",
        {"cid": cid},
    )
    return {"summary": summary[0] if summary else None, "open_invoices": invoices}


# ---------------------------------------------------------------------------
# WRITE actions — ISG REST -> EBS public APIs (audited)
# ---------------------------------------------------------------------------
def _isg_rest(endpoint: str, method: str, payload: dict = None) -> dict:
    import requests
    s = _get_secret()
    host = os.environ.get("EBS_HOST", s.get("host"))
    port = os.environ.get("EBS_PORT", "8000")
    url = f"http://{host}:{port}/webservices/rest/{endpoint}"
    auth = (s.get("ebs_username", "SYSADMIN"), s.get("ebs_password", "apps"))
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if method.upper() == "GET":
        r = requests.get(url, auth=auth, headers=headers, timeout=30)
        r.raise_for_status()
    else:
        r = requests.post(url, auth=auth, headers=headers, json=payload, timeout=30)
        r.raise_for_status()
    try:
        return r.json()
    except ValueError:
        return {"raw": r.text}


_WRITE_MAP = {
    "place_credit_hold":       ("XxCollectionsRestPkg/place_credit_hold/", "POST"),
    "release_credit_hold":     ("XxCollectionsRestPkg/release_credit_hold/", "POST"),
    "create_collections_note": ("XxCollectionsRestPkg/create_collections_note/", "POST"),
    "apply_order_holds":       ("XxOrderHoldsPkg/apply_order_holds/", "POST"),
    "release_order_holds":     ("XxOrderHoldsPkg/release_order_holds/", "POST"),
    "create_collections_task": ("XxCollectionsTaskPkg/create_collections_task/", "POST"),
    "send_dunning_letter":     ("XxCollectionsRestPkg/send_dunning_letter/", "POST"),
    "send_payment_reminder":   ("XxCollectionsRestPkg/send_payment_reminder/", "POST"),
}

# Write actions are executed by calling the audited APPS.XX_COLLECTIONS_REST_PKG over the
# existing oracledb VPC connection (definer-rights package → EBS public APIs). This avoids the
# cosmetic OHS :8000 mod_wl routing issue for /webservices, while keeping the SOX-compliant path
# (no direct DML from the Lambda; the APPS package owns the mutation + audit).
# Set USE_ISG_REST_HTTP=1 to force the HTTP ISG REST path instead.
def _db_write(action: str, params: dict) -> dict:
    import oracledb
    s = _get_secret()
    dsn = f"{s['host']}:{s.get('port', 1521)}/{s['service_name']}"
    conn = oracledb.connect(user=s["username"], password=s["password"], dsn=dsn)
    try:
        with conn.cursor() as cur:
            out = cur.var(oracledb.DB_TYPE_CLOB)
            cid = int(params.get("customer_id"))
            if action == "place_credit_hold":
                cur.callproc("APPS.XX_COLLECTIONS_REST_PKG.PLACE_CREDIT_HOLD",
                             [cid, params.get("reason", "Collections action"), out])
            elif action == "release_credit_hold":
                cur.callproc("APPS.XX_COLLECTIONS_REST_PKG.RELEASE_CREDIT_HOLD",
                             [cid, params.get("reason", "Collections action"), out])
            elif action == "create_collections_note":
                cur.callproc("APPS.XX_COLLECTIONS_REST_PKG.CREATE_COLLECTIONS_NOTE",
                             [cid, params.get("note_text", ""), out])
            elif action == "send_dunning_letter":
                cur.callproc("APPS.XX_COLLECTIONS_REST_PKG.SEND_DUNNING_LETTER",
                             [cid, int(params.get("level", 1)),
                              params.get("tone", "professional"), out])
            elif action == "send_payment_reminder":
                cur.callproc("APPS.XX_COLLECTIONS_REST_PKG.SEND_PAYMENT_REMINDER", [cid, out])
            else:
                raise ValueError(f"Action {action} not available via DB package")
            val = out.getvalue()
            txt = val.read() if hasattr(val, "read") else val
            try:
                return json.loads(txt)
            except (TypeError, ValueError):
                return {"raw": txt}
    finally:
        conn.close()


def handler(event, context):
    action = event.get("action")
    params = event.get("parameters", {}) or {}

    if action not in VALID_ACTIONS:
        return _resp(400, {"error": f"Invalid action: {action}", "valid": VALID_ACTIONS})

    try:
        if action == "get_overdue_customers":
            return _resp(200, {"status": "success", "action": action, "result": _get_overdue_customers(params)})
        if action == "get_customer_details":
            return _resp(200, {"status": "success", "action": action, "result": _get_customer_details(params)})
        if action == "get_policy_documents":
            return _resp(200, {"status": "success", "action": action, "result": _get_policy_documents(params)})
        if action == "get_tolerance_reconciliation":
            return _resp(200, {"status": "success", "action": action, "result": _get_tolerance_reconciliation(params)})
        if action == "sync_policy_tolerance":
            return _resp(200, {"status": "success", "action": action, "result": _sync_policy_tolerance(params)})

        # Dunning + reminder: real letter generation + audited note + SES email (handled here,
        # not the DB stub, so the delivery claim is truthful and verifiable).
        if action == "send_dunning_letter":
            return _resp(200, {"status": "success", "action": action, "result": _send_dunning_letter(params)})
        if action == "send_payment_reminder":
            return _resp(200, {"status": "success", "action": action, "result": _send_payment_reminder(params)})

        # Other WRITE actions: default to the audited APPS package over oracledb; optional HTTP ISG REST.
        if os.environ.get("USE_ISG_REST_HTTP", "0") == "1" and action in _WRITE_MAP:
            endpoint, method = _WRITE_MAP[action]
            result = _isg_rest(endpoint, method, params)
        else:
            result = _db_write(action, params)
        return _resp(200, {"status": "success", "action": action, "result": result})

    except Exception as e:
        logger.exception("action failed")
        return _resp(500, {"status": "error", "action": action, "error": str(e)})


def _resp(code: int, body: dict) -> dict:
    return {"statusCode": code, "body": json.dumps(body, default=str)}
