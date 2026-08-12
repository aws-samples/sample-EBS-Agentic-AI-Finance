"""
ebs-p2p-extract-26ai Lambda — invoice ingest + extraction (P3).

FLOW (no screen-scraping):
  invoice PDF/image lands in S3 (via SES->S3 rule or direct upload)
    -> S3 ObjectCreated triggers this Lambda
    -> extract header + line items with Amazon Bedrock (Claude vision) and/or Textract
    -> compute an extraction confidence
    -> call the seeded-path ingest package APPS.XX_P2P_INGEST_PKG.stage_invoice over oracledb:
         confidence >= threshold -> staged to AP_INVOICES_INTERFACE (Payables Open Interface)
         confidence <  threshold -> XX_P2P_STAGING NEEDS_REVIEW (human-in-the-loop)

VPC-attached (reaches the private DB). Bedrock/Textract via the AWS API. Secrets from
Secrets Manager. Invoked by S3 event OR directly with {"bucket","key"} OR {"invoice":{...}}
for a pre-extracted payload (used by tests / the agent).

Env: ORACLE_* (DB), EXTRACT_MODEL (Bedrock vision model), CONFIDENCE_THRESHOLD,
     DEFAULT_ORG_ID (fallback operating unit when not extractable).
"""

import os
import io
import json
import base64
import logging

import boto3
import oracledb

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_secret = None

EXTRACT_MODEL = os.environ.get("EXTRACT_MODEL", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
THRESHOLD = float(os.environ.get("CONFIDENCE_THRESHOLD", "0.80"))
DEFAULT_ORG_ID = int(os.environ.get("DEFAULT_ORG_ID", "204"))
REGION = os.environ.get("AWS_REGION_NAME", os.environ.get("AWS_REGION", "us-east-1"))

EXTRACT_PROMPT = """You are an accounts-payable invoice extraction engine. From the supplied
invoice document, extract STRICT JSON only (no prose) with this shape:
{
  "vendor_name": str,
  "invoice_num": str,
  "invoice_date": "YYYY-MM-DD",
  "invoice_amount": number,
  "currency": str (ISO code, default "USD"),
  "po_number": str or null,
  "lines": [ {"description": str, "quantity": number, "unit_price": number, "amount": number,
              "po_line_number": number or null} ],
  "confidence": number,  // 0..1, YOUR honest confidence in the extraction overall
  "review_reason": str   // ONE short phrase (<=120 chars) explaining what makes this
                         // uncertain, e.g. "blurred scan - totals illegible",
                         // "handwritten amount", "vendor name partly obscured". Empty "" if clean.
}
If a field is not present, use null. Confidence must reflect document legibility and completeness.
Always fill review_reason with a concise, human-readable rationale for the confidence."""


def _get_secret() -> dict:
    global _secret
    if _secret is None:
        name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
        sm = boto3.client("secretsmanager", region_name=REGION)
        _secret = json.loads(sm.get_secret_value(SecretId=name)["SecretString"])
    return _secret


def _extract_with_bedrock(doc_bytes: bytes, media_type: str) -> dict:
    """Use Bedrock Claude vision to extract structured invoice data from a document image."""
    client = boto3.client("bedrock-runtime", region_name=REGION)
    # Claude vision via converse: send the document as an image block.
    resp = client.converse(
        modelId=EXTRACT_MODEL,
        system=[{"text": EXTRACT_PROMPT}],
        messages=[{
            "role": "user",
            "content": [
                {"text": "Extract this invoice as the specified JSON."},
                {"image": {"format": media_type, "source": {"bytes": doc_bytes}}},
            ],
        }],
        inferenceConfig={"maxTokens": 1500, "temperature": 0.0},
    )
    text = resp["output"]["message"]["content"][0]["text"].strip()
    # strip code fences if present
    if text.startswith("```"):
        text = text.split("```", 2)[1].lstrip("json").strip() if "```" in text else text
    return json.loads(text)


def _media_type(key: str) -> str:
    k = key.lower()
    if k.endswith(".png"): return "png"
    if k.endswith(".jpg") or k.endswith(".jpeg"): return "jpeg"
    if k.endswith(".gif"): return "gif"
    if k.endswith(".webp"): return "webp"
    # PDFs are sent to Textract path in a full build; for vision, callers convert to image.
    return "png"


def _anomaly_check(cur, inv: dict) -> dict:
    """Duplicate/fraud/outlier pre-check via the seeded-path anomaly package (read-only)."""
    out = cur.var(oracledb.DB_TYPE_CLOB)
    cur.callproc("APPS.XX_P2P_ANOMALY_PKG.CHECK_INVOICE", [
        inv.get("vendor_name"), inv.get("invoice_num"),
        float(inv.get("invoice_amount") or 0), inv.get("invoice_date"), out,
    ])
    val = out.getvalue()
    txt = val.read() if hasattr(val, "read") else val
    return json.loads(txt) if txt else {}


def _stage(inv: dict, source_uri: str) -> dict:
    """Anomaly-check, then call the seeded-path ingest package over oracledb.

    A BLOCK verdict (exact duplicate) or REVIEW verdict (near-dup / outlier) forces the
    invoice to the human review queue by capping the effective confidence below threshold,
    even if extraction confidence was high — dup-payment / fraud guard on the ingest path.
    """
    s = _get_secret()
    dsn = f"{s['host']}:{s.get('port', 1521)}/{s['service_name']}"
    conn = oracledb.connect(user=s["username"], password=s["password"], dsn=dsn)
    try:
        with conn.cursor() as cur:
            anomaly = {}
            try:
                anomaly = _anomaly_check(cur, inv)
            except Exception as ae:  # never let the guard break ingest
                logger.warning("anomaly check failed (continuing): %s", ae)
            verdict = (anomaly or {}).get("verdict", "CLEAR")
            eff_conf = float(inv.get("confidence") or 0)
            reason = (inv.get("review_reason") or "").strip()
            if verdict in ("BLOCK", "REVIEW"):
                eff_conf = min(eff_conf, THRESHOLD - 0.01)  # force NEEDS_REVIEW
                # anomaly "flags" is a comma-separated STRING (e.g. "DUPLICATE,NEAR_DUP"),
                # not a list — normalise without splitting into characters.
                raw_flags = (anomaly or {}).get("flags")
                if isinstance(raw_flags, list):
                    flags = ", ".join(raw_flags)
                else:
                    flags = ", ".join(f.strip() for f in str(raw_flags or "").split(",") if f.strip())
                flags = flags or verdict
                dup_note = f"Anomaly check: {verdict} ({flags})"
                reason = f"{dup_note}. {reason}".strip() if reason else dup_note

            out = cur.var(oracledb.DB_TYPE_CLOB)
            cur.callproc("APPS.XX_P2P_INGEST_PKG.STAGE_INVOICE", [
                source_uri,
                inv.get("vendor_name"),
                inv.get("invoice_num"),
                inv.get("invoice_date"),
                float(inv.get("invoice_amount") or 0),
                inv.get("currency", "USD"),
                int(inv.get("org_id") or DEFAULT_ORG_ID),
                inv.get("po_number"),
                json.dumps(inv.get("lines", [])),
                eff_conf,
                THRESHOLD,
                out,
                (reason or None),
            ])
            val = out.getvalue()
            txt = val.read() if hasattr(val, "read") else val
            result = json.loads(txt) if txt else {}
            result["anomaly"] = anomaly  # surface the fraud/dup verdict to the caller
            return result
    finally:
        conn.close()


def handler(event, context):
    try:
        # Path A: a pre-extracted invoice payload (tests / agent) — skip extraction.
        if event.get("invoice"):
            inv = event["invoice"]
            src = event.get("source_uri", "manual://agent")
            return _resp(200, {"status": "success", "mode": "preextracted",
                               "result": _stage(inv, src)})

        # Path B: S3 event (or explicit bucket/key) -> fetch doc -> Bedrock vision extract.
        if "Records" in event:
            rec = event["Records"][0]["s3"]
            bucket, key = rec["bucket"]["name"], rec["object"]["key"]
        else:
            bucket, key = event.get("bucket"), event.get("key")
        if not bucket or not key:
            return _resp(400, {"status": "error", "error": "no invoice payload or S3 object"})

        s3 = boto3.client("s3", region_name=REGION)
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        inv = _extract_with_bedrock(body, _media_type(key))
        result = _stage(inv, f"s3://{bucket}/{key}")
        return _resp(200, {"status": "success", "mode": "extracted",
                           "extracted": {k: inv.get(k) for k in
                                         ("vendor_name", "invoice_num", "invoice_amount", "confidence")},
                           "result": result})
    except Exception as e:
        logger.exception("extraction failed")
        return _resp(500, {"status": "error", "error": str(e)})


def _resp(code: int, body: dict) -> dict:
    return {"statusCode": code, "body": json.dumps(body, default=str)}
