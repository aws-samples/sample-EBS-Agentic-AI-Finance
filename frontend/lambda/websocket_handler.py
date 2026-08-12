"""
WebSocket handler Lambda for the 26ai collections React UI.

Routes (API Gateway WebSocket, route selection = $request.body.action):
  $connect      — store connectionId in DynamoDB
  $disconnect   — remove connectionId
  sendMessage   — invoke the AgentCore Runtime agent, post the reply back over the socket

Env:
  CONNECTIONS_TABLE  — DynamoDB table name
  AGENT_RUNTIME_ARN  — Bedrock AgentCore Runtime ARN (the agent host)
"""

import os
import json
import time
import uuid
import logging
import urllib.parse

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ddb = boto3.client("dynamodb")
lambda_client = boto3.client("lambda")

# S3 client pinned to SigV4. The invoice inbox bucket uses SSE-KMS default encryption, and
# SigV2 presigned URLs are REJECTED against a KMS-encrypted bucket with 400 InvalidArgument.
# The default signer can emit SigV2-style presigns in some runtimes, so force s3v4 here.
from botocore.config import Config as _BotoConfig
_s3v4 = boto3.client("s3", config=_BotoConfig(signature_version="s3v4"))

TABLE = os.environ.get("CONNECTIONS_TABLE", "websocket-connections-26ai")
COLLECTIONS_LAMBDA = os.environ.get("COLLECTIONS_LAMBDA_NAME", "ebs-collections-26ai")
P2P_LAMBDA = os.environ.get("P2P_LAMBDA_NAME", "ebs-p2p-26ai")
# sendMessage is served by the Bedrock AgentCore Runtime (VPC-attached container with the
# SQLcl MCP server + AgentCore Memory). Set by deploy.sh's `agentcore` stage.
AGENT_RUNTIME_ARN = os.environ.get("AGENT_RUNTIME_ARN", "")

# --- Cognito JWT verification (server-side; groups must not be client-spoofable) ---------
COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
COGNITO_APP_CLIENT_ID = os.environ.get("COGNITO_APP_CLIENT_ID", "")
COGNITO_REGION = os.environ.get("AWS_REGION", "us-east-1")
# Enforce RBAC on write actions. Set 0 only for local/dev.
AUTHZ_ENFORCE = os.environ.get("AUTHZ_ENFORCE", "1") == "1"

# Handler-side P2P write actions (these go directly through this Lambda, not the agent tools),
# and the Cognito group that authorizes them. Kept in sync with agentcore_version/tools/authz.py.
_AP_WRITE_HANDLER_ACTIONS = {"p2p_approve_review", "p2p_reject_review", "p2p_submit_import",
                             "policy_sync"}
_GROUP_ALLOWS_AP_WRITE = {"ap-managers"}
_GROUP_ALLOWS_AR_WRITE = {"ar-managers"}

_jwks_cache = None


def _get_jwks():
    """Fetch + cache the Cognito JWKS for signature verification."""
    global _jwks_cache
    if _jwks_cache is None and COGNITO_USER_POOL_ID:
        import urllib.request
        url = (f"https://cognito-idp.{COGNITO_REGION}.amazonaws.com/"
               f"{COGNITO_USER_POOL_ID}/.well-known/jwks.json")
        # Enforce https before opening so no file:// or custom scheme can ever be fetched.
        # The URL is built from a fixed Cognito host plus the configured pool id.
        if not url.startswith("https://"):
            raise ValueError("JWKS URL must be https")
        # URL is built from the fixed Cognito host + configured pool id (no user input) and
        # asserted https above, so there is no file:// / SSRF vector.
        with urllib.request.urlopen(url, timeout=5) as r:  # nosec B310  # nosemgrep: dynamic-urllib-use-detected
            _jwks_cache = json.loads(r.read())
    return _jwks_cache


def _verify_token(token: str) -> dict:
    """Verify a Cognito ID token's signature/claims. Returns claims dict or {} on failure.

    Fail-closed: any verification error yields {} (no identity → writes later denied).
    """
    if not token or not COGNITO_USER_POOL_ID:
        return {}
    try:
        import jwt  # PyJWT
        from jwt import PyJWKClient
        jwks = _get_jwks()
        headers = jwt.get_unverified_header(token)
        kid = headers.get("kid")
        key = None
        for k in (jwks or {}).get("keys", []):
            if k.get("kid") == kid:
                from jwt.algorithms import RSAAlgorithm
                key = RSAAlgorithm.from_jwk(json.dumps(k))
                break
        if key is None:
            logger.warning("JWT kid not found in JWKS")
            return {}
        issuer = f"https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}"
        opts = {"verify_aud": bool(COGNITO_APP_CLIENT_ID)}
        claims = jwt.decode(
            token, key, algorithms=["RS256"], issuer=issuer,
            audience=COGNITO_APP_CLIENT_ID if COGNITO_APP_CLIENT_ID else None,
            options=opts,
        )
        return claims
    except Exception as e:
        logger.warning("JWT verification failed: %s", e)
        return {}


def _identity_from_claims(claims: dict) -> dict:
    """Extract the identity we persist server-side from verified claims."""
    return {
        "user": claims.get("email") or claims.get("cognito:username") or "",
        "ebs_username": claims.get("custom:ebs_username") or "",
        "groups": claims.get("cognito:groups") or [],
    }


def _load_identity(conn_id: str) -> dict:
    """Read the verified identity persisted for this connection at $connect."""
    try:
        item = ddb.get_item(TableName=TABLE, Key={"connectionId": {"S": conn_id}}).get("Item", {})
        raw = item.get("identity", {}).get("S")
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


def _deny(api, conn_id, action, needed):
    msg = (f"You don't have permission to perform '{action}'. It requires {needed}. "
           f"Your access is read-only here — please ask an authorised manager to perform it, "
           f"or request the responsibility be added to your EBS account.")
    api.post_to_connection(ConnectionId=conn_id,
                           Data=json.dumps({"type": "error", "text": msg}).encode())


def _invoke_agent_runtime(prompt: str, session_id: str, identity: dict = None,
                          history: list = None) -> str:
    """Invoke the AgentCore Runtime and return the agent's reply text.

    AgentCore allows only ONE in-flight request per runtimeSessionId ("Concurrent invocations
    are not supported"). If we reused the WebSocket connectionId as the session id, a slow
    request (e.g. a Code-Interpreter chart, ~90s) would block the next message on that
    connection. So we mint a UNIQUE session id per request. Because that makes each invoke a
    fresh session (and the agent is rebuilt per request), conversational context would be lost
    between turns — so the browser sends the recent `history` and we pass it through; the agent
    seeds itself with it. This keeps context (e.g. replying "2" to a menu) without reusing a
    session. Session id must be >= 33 chars for InvokeAgentRuntime.
    """
    client = boto3.client("bedrock-agentcore")
    # 64 hex chars — unique per request, comfortably over the 33-char minimum.
    rsid = uuid.uuid4().hex + uuid.uuid4().hex
    resp = client.invoke_agent_runtime(
        agentRuntimeArn=AGENT_RUNTIME_ARN,
        runtimeSessionId=rsid,
        payload=json.dumps({"prompt": prompt, "session_id": session_id,
                            "auth": identity or {}, "history": history or []}).encode(),
        contentType="application/json",
        accept="application/json",
    )
    body = resp.get("response")
    raw = body.read() if hasattr(body, "read") else body
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    try:
        data = json.loads(raw)
        return data.get("reply") or data.get("text") or raw
    except Exception:
        return raw


def _invoke(fn: str, payload: dict) -> dict:
    resp = lambda_client.invoke(
        FunctionName=fn, InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode(),
    )
    out = json.loads(resp["Payload"].read())
    if isinstance(out, dict) and "body" in out:
        try:
            return json.loads(out["body"])
        except Exception:
            return out
    return out


class BackendUnavailable(Exception):
    """Raised when a downstream (DB / app tier) is unreachable or returned an error,
    so the socket handler can tell the browser 'unavailable' instead of sending empty data.
    A dead database must NOT look like 'zero overdue' in the UI."""


def _check(out: dict, what: str) -> dict:
    """Validate a downstream Lambda response; raise BackendUnavailable on error/empty.

    The collections/p2p Lambdas return {"status":"error", ...} when the DB connect or query
    fails. Treat that (and a missing result envelope) as unavailable rather than as no data."""
    if not isinstance(out, dict):
        raise BackendUnavailable(f"{what}: unexpected response")
    if out.get("status") == "error":
        raise BackendUnavailable(out.get("error") or f"{what}: backend error")
    if "result" not in out and "status" not in out:
        # Some read paths return the payload directly; only flag a truly empty/missing envelope.
        if not out:
            raise BackendUnavailable(f"{what}: empty response")
    return out


def _dashboard_data() -> dict:
    """Structured dashboard data from the collections Lambda read actions."""
    risk = _check(
        _invoke(COLLECTIONS_LAMBDA, {"action": "get_overdue_customers", "parameters": {"top": 10}}),
        "dashboard",
    )
    return {
        "risk_customers": (risk.get("result") or {}).get("customers", []),
    }


def _healthcheck() -> dict:
    """Cheap up/down probe for the data backend. Runs a single read (top 1) against the
    collections Lambda; success => DB reachable. Used by the UI on load to show a clear
    'system unavailable' banner instead of inferring it from empty datasets."""
    out = _invoke(COLLECTIONS_LAMBDA, {"action": "get_overdue_customers", "parameters": {"top": 1}})
    if isinstance(out, dict) and out.get("status") == "success":
        return {"healthy": True}
    reason = (out or {}).get("error") if isinstance(out, dict) else "unknown"
    return {"healthy": False, "reason": reason or "backend unavailable"}


def _selftest(identity: dict = None, session_id: str = "selftest") -> dict:
    """End-to-end self-test the user can run from the UI. Exercises each major subsystem
    with a real call and returns a pass/fail line per check. Read-only / non-destructive:
    it never writes to EBS (no holds, notes, payments). Returns
    {"checks":[{name, ok, detail}], "passed":N, "total":M}.
    """
    checks = []

    def add(name, ok, detail=""):
        checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:200]})

    # 1) AR reads (Collections Lambda over the reporting views)
    try:
        r = _invoke(COLLECTIONS_LAMBDA, {"action": "get_overdue_customers", "parameters": {"top": 3}})
        cust = ((r or {}).get("result") or {}).get("customers", [])
        add("AR analytics (overdue customers)", (r or {}).get("status") == "success",
            f"{len(cust)} customer(s) returned")
    except Exception as e:
        add("AR analytics (overdue customers)", False, e)

    # 2) AP reads (P2P Lambda over the AP/PO/RCV views)
    try:
        r = _invoke(P2P_LAMBDA, {"action": "p2p_dashboard", "parameters": {}})
        ok = isinstance(r, dict) and ("result" in r or "kpis" in r)
        add("AP Control Tower (dashboard)", ok, "KPIs returned" if ok else "no data")
    except Exception as e:
        add("AP Control Tower (dashboard)", False, e)

    # 3) Knowledge base (vector search) via the collections Lambda policy read
    try:
        r = _invoke(COLLECTIONS_LAMBDA, {"action": "get_policy_documents", "parameters": {}})
        docs = ((r or {}).get("result") or {}).get("documents", [])
        add("Knowledge base (policy docs)", len(docs) > 0, f"{len(docs)} document(s)")
    except Exception as e:
        add("Knowledge base (policy docs)", False, e)

    # 4) Policy-vs-EBS tolerance reconciliation
    try:
        r = _invoke(COLLECTIONS_LAMBDA, {"action": "get_tolerance_reconciliation", "parameters": {}})
        res = (r or {}).get("result") or {}
        rows = res.get("rows", [])
        add("Policy vs EBS reconciliation", len(rows) > 0,
            f"{len(rows)} OU · {res.get('drift_count', 0)} drift")
    except Exception as e:
        add("Policy vs EBS reconciliation", False, e)

    # 5) Agent round-trip + conversation context (only if the AgentCore runtime is wired)
    if AGENT_RUNTIME_ARN:
        try:
            hist = [
                {"role": "user", "text": "For this self-test, remember the code word is FALCON."},
                {"role": "agent", "text": "Understood, the code word is FALCON."},
            ]
            reply = _invoke_agent_runtime("What is the code word? Answer with one word.",
                                          "selftest-" + (conn_hint or "x"), identity, hist)
            ok = "falcon" in (reply or "").lower()
            add("AI agent + conversation memory", ok,
                "recalled context" if ok else "no recall: " + (reply or "")[:80])
        except Exception as e:
            add("AI agent + conversation memory", False, e)
    else:
        add("AI agent + conversation memory", False, "AGENT_RUNTIME_ARN not set (skipped)")

    passed = sum(1 for c in checks if c["ok"])
    return {"checks": checks, "passed": passed, "total": len(checks)}


def handler(event, context):
    rc = event.get("requestContext", {})
    route = rc.get("routeKey")
    conn_id = rc.get("connectionId")

    if route == "$connect":
        # Verify the Cognito ID token passed as a query string param (?token=...).
        # WebSocket clients can't set Authorization headers, so the token rides the
        # $connect query string; we verify its signature here and persist the derived
        # identity (email, ebs_username, groups) so per-message actions are gated against
        # a SERVER-VERIFIED identity, never client-supplied claims.
        qs = (event.get("queryStringParameters") or {})
        token = qs.get("token") or qs.get("access_token") or ""
        claims = _verify_token(token)
        identity = _identity_from_claims(claims) if claims else {}
        item = {
            "connectionId": {"S": conn_id},
            "ttl": {"N": str(int(time.time()) + 7200)},
            "identity": {"S": json.dumps(identity)},
        }
        # If enforcement is on and the token didn't verify, still allow the socket to open
        # (so reads/UI work), but with NO groups → all write actions will be denied downstream.
        if not identity:
            logger.info("connect without a verified identity (conn=%s) — writes will be denied", conn_id)
        ddb.put_item(TableName=TABLE, Item=item)
        return {"statusCode": 200}

    if route == "$disconnect":
        ddb.delete_item(TableName=TABLE, Key={"connectionId": {"S": conn_id}})
        return {"statusCode": 200}

    # sendMessage (or default)
    domain = rc.get("domainName")
    stage = rc.get("stage")
    api = boto3.client("apigatewaymanagementapi",
                       endpoint_url=f"https://{domain}/{stage}")

    body = json.loads(event.get("body") or "{}")
    action = body.get("action")

    # Health probe — definitive up/down for the data backend so the UI can show a clear
    # 'system unavailable' banner rather than inferring it from empty datasets.
    if action == "health":
        try:
            h = _healthcheck()
        except Exception as e:
            logger.exception("healthcheck failed")
            h = {"healthy": False, "reason": str(e)}
        api.post_to_connection(
            ConnectionId=conn_id,
            Data=json.dumps({"type": "health", "data": h}).encode(),
        )
        return {"statusCode": 200}

    # Policy library — read the human-readable policy/SOP/template docs from the SAME
    # knowledge-base vector store the agent reasons over (collections Lambda read action),
    # so the console shows exactly what the agent cites. Read-only, open to all users.
    # policy_recon = live reconciliation of the narrative policy vs the tolerance EBS enforces.
    if action in ("policy_docs", "policy_recon"):
        try:
            la = "get_policy_documents" if action == "policy_docs" else "get_tolerance_reconciliation"
            data = _invoke(COLLECTIONS_LAMBDA,
                           {"action": la, "parameters": body.get("parameters", {})})
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": action, "data": data.get("result", data)}).encode(),
            )
            return {"statusCode": 200}
        except Exception as e:
            logger.exception("%s failed", action)
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "text": str(e)}).encode(),
            )
            return {"statusCode": 500}

    # Policy sync — reconcile the app's documented policy-of-record to the tolerance EBS
    # actually enforces (EBS → app KB only; never writes EBS config). This CHANGES a
    # governing value, so it is RBAC-gated to AP managers. The verified identity is passed
    # through as updated_by for the audit column.
    if action == "policy_sync":
        if AUTHZ_ENFORCE:
            ident = _load_identity(conn_id)
            groups = set(ident.get("groups") or [])
            if not (groups & _GROUP_ALLOWS_AP_WRITE):
                _deny(api, conn_id, action, "an AP responsibility (AP Manager)")
                return {"statusCode": 200}
        try:
            ident = _load_identity(conn_id)
            params = dict(body.get("parameters", {}) or {})
            params.setdefault("updated_by", ident.get("ebs_username") or ident.get("user") or "ui")
            data = _invoke(COLLECTIONS_LAMBDA,
                           {"action": "sync_policy_tolerance", "parameters": params})
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "policy_sync", "data": data.get("result", data)}).encode(),
            )
            return {"statusCode": 200}
        except Exception as e:
            logger.exception("policy_sync failed")
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "text": str(e)}).encode(),
            )
            return {"statusCode": 500}

    # Dashboard data request — call the collections Lambda read actions directly (fast, structured).
    if action == "dashboard":
        try:
            payload = _dashboard_data()
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "dashboard", "data": payload}).encode(),
            )
            return {"statusCode": 200}
        except BackendUnavailable as e:
            # DB / app tier down: tell the UI explicitly so it shows 'unavailable', not $0.
            logger.warning("dashboard unavailable: %s", e)
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "code": "BACKEND_UNAVAILABLE",
                                 "scope": "dashboard", "text": str(e)}).encode(),
            )
            return {"statusCode": 200}
        except Exception as e:
            logger.exception("dashboard failed")
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "code": "BACKEND_UNAVAILABLE",
                                 "scope": "dashboard", "text": str(e)}).encode(),
            )
            return {"statusCode": 500}

    # Invoice upload: hand the browser a presigned S3 PUT URL for the inbox `incoming/`
    # prefix. The browser PUTs the file directly to S3, which triggers the extract Lambda
    # (Bedrock vision → seeded Payables Open Interface). Keeps large files off the socket.
    if action == "p2p_upload_url":
        try:
            import uuid
            bucket = os.environ.get("P2P_INBOX_BUCKET", "ebs-p2p-inbox-26ai-339712993582")
            # The browser sends {filename} under `parameters` (requestData wraps it there);
            # also accept it at the top level for direct callers. Preserving the real filename
            # keeps the object key's extension (e.g. .png) so downstream stays tidy.
            p = body.get("parameters") or {}
            fname = (p.get("filename") or body.get("filename") or "invoice.png").replace("/", "_")
            key = f"incoming/ui-{uuid.uuid4().hex[:12]}-{fname}"
            # Do NOT sign Content-Type: signing it makes content-type a required signed
            # header, so any mismatch with the browser's PUT header (charset/casing/empty
            # file.type) fails with SignatureDoesNotMatch (403). The S3 trigger + extract
            # Lambda key off the object key, not its content-type, so this is safe.
            # Use the SigV4 client — the inbox bucket is SSE-KMS and rejects SigV2 presigns (400).
            url = _s3v4.generate_presigned_url(
                "put_object",
                Params={"Bucket": bucket, "Key": key},
                ExpiresIn=300,
            )
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "p2p_upload_url", "data": {"url": url, "key": key}}).encode(),
            )
            return {"statusCode": 200}
        except Exception as e:
            logger.exception("upload url failed")
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "text": str(e)}).encode(),
            )
            return {"statusCode": 500}

    # Invoice view: hand the browser a short-lived presigned GET URL for the original
    # document in the inbox so a reviewer can see the actual invoice image while deciding.
    if action == "p2p_view_url":
        try:
            vp = body.get("parameters") or body
            src = vp.get("source_uri") or ""
            # Only S3-sourced documents are viewable (manual://agent rows have no file).
            if not src.startswith("s3://"):
                api.post_to_connection(
                    ConnectionId=conn_id,
                    Data=json.dumps({"type": "p2p_view_url",
                                     "data": {"url": None, "staging_id": vp.get("staging_id"),
                                              "message": "No source document for this row"}}).encode())
                return {"statusCode": 200}
            without = src[len("s3://"):]
            bkt, _, obj_key = without.partition("/")
            # Open the document INLINE in the browser (not a download) so it's easy to demo.
            # Detect the content type from the file's MAGIC BYTES, not the key extension —
            # UI uploads land as keys with no extension (ui-<hash>-invoice), so an
            # extension check falls back to octet-stream and the browser downloads it.
            ctype = "application/octet-stream"
            k = obj_key.lower()
            try:
                head = _s3v4.get_object(Bucket=bkt, Key=obj_key, Range="bytes=0-15")["Body"].read()
                if head.startswith(b"\x89PNG"):
                    ctype = "image/png"
                elif head.startswith(b"\xff\xd8\xff"):
                    ctype = "image/jpeg"
                elif head.startswith(b"%PDF"):
                    ctype = "application/pdf"
                elif head.startswith(b"GIF8"):
                    ctype = "image/gif"
                elif head[:4] == b"RIFF" and head[8:12] == b"WEBP":
                    ctype = "image/webp"
            except Exception:
                # Fall back to the extension if the sniff read fails.
                ctype = ("image/png" if k.endswith(".png")
                         else "image/jpeg" if (k.endswith(".jpg") or k.endswith(".jpeg"))
                         else "application/pdf" if k.endswith(".pdf")
                         else "application/octet-stream")
            url = _s3v4.generate_presigned_url(
                "get_object",
                Params={"Bucket": bkt, "Key": obj_key,
                        "ResponseContentDisposition": "inline",
                        "ResponseContentType": ctype},
                ExpiresIn=300)
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "p2p_view_url",
                                 "data": {"url": url, "staging_id": vp.get("staging_id")}}).encode())
            return {"statusCode": 200}
        except Exception as e:
            logger.exception("view url failed")
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "text": str(e)}).encode())
            return {"statusCode": 500}

    # P2P (AP Control Tower) data requests — served by the P2P Lambda read views.
    if action in ("p2p_dashboard", "p2p_exceptions", "p2p_aging", "p2p_vendor_summary", "p2p_review_queue",
                  "p2p_simulate", "p2p_action_plan", "p2p_predict", "p2p_interface_status",
                  "p2p_approve_review", "p2p_reject_review", "p2p_submit_import"):
        # RBAC gate for the handler-side P2P WRITE actions (approve/reject/import).
        # Reads (dashboard/exceptions/aging/etc.) are open.
        if AUTHZ_ENFORCE and action in _AP_WRITE_HANDLER_ACTIONS:
            ident = _load_identity(conn_id)
            groups = set(ident.get("groups") or [])
            if not (groups & _GROUP_ALLOWS_AP_WRITE):
                _deny(api, conn_id, action, "an AP responsibility (AP Manager)")
                return {"statusCode": 200}
        try:
            data = _check(
                _invoke(P2P_LAMBDA, {"action": action, "parameters": body.get("parameters", {})}),
                action,
            )
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": action, "data": data.get("result", data)}).encode(),
            )
            return {"statusCode": 200}
        except BackendUnavailable as e:
            logger.warning("p2p unavailable (%s): %s", action, e)
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "code": "BACKEND_UNAVAILABLE",
                                 "scope": action, "text": str(e)}).encode(),
            )
            return {"statusCode": 200}
        except Exception as e:
            logger.exception("p2p data failed")
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "code": "BACKEND_UNAVAILABLE",
                                 "scope": action, "text": str(e)}).encode(),
            )
            return {"statusCode": 500}

    try:
        prompt = body.get("prompt", "")
        # Recent conversation turns from the browser so the (stateless-per-invoke) agent keeps
        # context. Shape: [{"role":"user"|"agent","text":"..."}]. Bounded client-side.
        history = body.get("history") or []
        # Attach the server-verified identity so the agent's write tools can enforce RBAC.
        identity = _load_identity(conn_id)

        if AGENT_RUNTIME_ARN:
            # Bedrock AgentCore Runtime — the only agent host (VPC-attached container with
            # AgentCore Memory + SQLcl MCP). Set by deploy.sh's `agentcore` stage.
            reply = _invoke_agent_runtime(prompt, conn_id, identity, history)
        else:
            reply = ("Agent runtime not configured: AGENT_RUNTIME_ARN is unset. "
                     "Run './deploy.sh agentcore' to create the AgentCore runtime and wire it in.")

        api.post_to_connection(
            ConnectionId=conn_id,
            Data=json.dumps({"type": "reply", "text": reply}).encode(),
        )
        return {"statusCode": 200}

    except Exception as e:
        logger.exception("sendMessage failed")
        msg = str(e)
        # AgentCore serialises requests per session. With a unique session id per request this
        # should not happen, but if the runtime is briefly saturated, give a friendly retry hint.
        if "already processing" in msg.lower() or "concurrent" in msg.lower():
            msg = "The assistant is still finishing your previous request. Give it a few seconds and try again."
        try:
            api.post_to_connection(
                ConnectionId=conn_id,
                Data=json.dumps({"type": "error", "text": msg}).encode(),
            )
        except Exception:
            pass
        return {"statusCode": 500}
