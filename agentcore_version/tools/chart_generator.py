"""
generate_chart — Generate matplotlib charts via the Amazon Bedrock AgentCore Code Interpreter.

Uses the bedrock-agentcore data-plane Code Interpreter (built-in identifier
aws.codeinterpreter.v1): start a session, run the user's matplotlib code with
name="executeCode", collect the rendered PNG (base64), upload it to S3, and
return a presigned URL. The agent calls this when asked to visualize data.
"""

import os
import io
import json
import time
import base64
import logging
import boto3

from strands import tool

logger = logging.getLogger(__name__)

CI_IDENTIFIER = os.environ.get("CODE_INTERPRETER_ID", "aws.codeinterpreter.v1")
REGION = os.environ.get("AWS_REGION_NAME", os.environ.get("AWS_REGION", "us-east-1"))
ARTIFACT_BUCKET = os.environ.get("CHART_BUCKET", "")  # falls back to inline base64 if unset

# ---------------------------------------------------------------------------------------
# Chart image side-channel.
# A rendered chart is a ~200KB base64 PNG. Feeding that back to the LLM as a tool result
# floods its context (the model receives the blob AND re-emits it in its reply), which on
# large charts sends the model into a retry loop (observed: 5+ minutes, repeated
# generate_chart calls). Instead, generate_chart returns a SHORT token to the model and
# stashes the real data URL here; the runtime host swaps the token for the inline image in
# the FINAL reply via resolve_charts(). The giant blob never enters the token stream.
_CHART_REGISTRY = {}
_CHART_REGISTRY_MAX = 64  # cap to bound memory if a token is ever orphaned (no reply match)


def resolve_charts(reply: str) -> str:
    """Replace [[CHART:<token>]] markers in a final agent reply with the inline PNG image.

    Called by the runtime hosts after the agent finishes. Consumes (pops) each token so the
    registry does not grow unbounded. Unknown/duplicate markers are dropped cleanly.
    """
    if not reply or "[[CHART:" not in reply:
        # Nothing to substitute; still opportunistically clear any stale entries.
        if len(_CHART_REGISTRY) > _CHART_REGISTRY_MAX:
            _CHART_REGISTRY.clear()
        return reply
    import re

    def _sub(m):
        token = m.group(1)
        data_url = _CHART_REGISTRY.pop(token, None)
        if not data_url:
            return ""  # unknown/already-consumed token → drop the marker
        return f"![chart]({data_url})"

    out = re.sub(r"\[\[CHART:([A-Za-z0-9\-]+)\]\]", _sub, reply)
    if len(_CHART_REGISTRY) > _CHART_REGISTRY_MAX:
        _CHART_REGISTRY.clear()
    return out


# Code the sandbox runs: execute the user's chart code, then emit the PNG as base64 on stdout.
_WRAPPER = """
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import base64

{user_code}

# Persist whatever figure the user code produced
import os
_path = "/tmp/chart.png"
if not os.path.exists(_path):
    plt.savefig(_path, bbox_inches="tight", dpi=120)
with open(_path, "rb") as _f:
    print("CHART_B64_START" + base64.b64encode(_f.read()).decode() + "CHART_B64_END")
"""


def _extract_text(stream) -> str:
    """Concatenate text from the invoke_code_interpreter event stream."""
    out = []
    for event in stream:
        # events arrive as {'result': {...}} with content blocks
        result = event.get("result") or {}
        for block in result.get("content", []) or []:
            if block.get("type") == "text" and "text" in block:
                out.append(block["text"])
        # some SDK versions surface stdout under 'structuredContent'
        sc = result.get("structuredContent") or {}
        if isinstance(sc, dict):
            for key in ("stdout", "output"):
                if sc.get(key):
                    out.append(sc[key])
    return "".join(out)


@tool
def generate_chart(code: str, description: str = "") -> str:
    """
    Generate a data visualization chart using Python (matplotlib) in a secure sandbox.

    Provide matplotlib/pandas code that builds a figure. You do NOT need to call
    plt.savefig — the sandbox saves and returns the rendered PNG automatically.
    Available libraries: matplotlib, pandas, numpy.

    Args:
        code: Python code that builds a matplotlib chart (e.g. plt.bar(...)).
        description: Short description of what the chart shows (for accessibility).

    Returns:
        On success, a small JSON object containing a `chart_marker` like
        `[[CHART:ab12cd34]]`. You MUST place that exact marker on its own line in your
        reply where the chart should appear — the runtime replaces it with the rendered
        image before the user sees it. Do NOT ask for the image data or call this tool
        again for the same chart; one successful call per chart is enough. On failure,
        returns a JSON object with status="error".
    """
    client = boto3.client("bedrock-agentcore", region_name=REGION)
    session_id = None
    try:
        session_id = client.start_code_interpreter_session(
            codeInterpreterIdentifier=CI_IDENTIFIER,
            name="collections-chart",
            sessionTimeoutSeconds=300,
        )["sessionId"]

        resp = client.invoke_code_interpreter(
            codeInterpreterIdentifier=CI_IDENTIFIER,
            sessionId=session_id,
            name="executeCode",
            arguments={"language": "python", "code": _WRAPPER.format(user_code=code)},
        )
        text = _extract_text(resp.get("stream", []))

        if "CHART_B64_START" not in text:
            return json.dumps({
                "status": "error",
                "error": "Code Interpreter did not return an image.",
                "output": text[:1000],
            })

        b64 = text.split("CHART_B64_START", 1)[1].split("CHART_B64_END", 1)[0].strip()
        png = base64.b64decode(b64)
        data_url = "data:image/png;base64," + b64

        # Upload the PNG to S3 and prefer a SHORT presigned URL as the render source. The
        # inline base64 data URL is ~200KB, which blows past API Gateway's 128KB WebSocket
        # frame limit → the final reply fails to POST with a 413. A presigned https URL is a
        # few hundred bytes, so the reply stays well under the frame limit and the browser
        # loads the image directly from S3. Fall back to the inline data URL only if there is
        # no bucket or the upload fails.
        import uuid
        render_src = data_url
        chart_key = None
        if ARTIFACT_BUCKET:
            try:
                key = f"charts/chart-{int(time.time())}-{uuid.uuid4().hex[:8]}.png"
                s3 = boto3.client("s3", region_name=REGION)
                s3.put_object(Bucket=ARTIFACT_BUCKET, Key=key, Body=png, ContentType="image/png")
                render_src = s3.generate_presigned_url(
                    "get_object",
                    Params={"Bucket": ARTIFACT_BUCKET, "Key": key,
                            "ResponseContentType": "image/png"},
                    ExpiresIn=86400)  # 24h — comfortably covers a demo/session
                chart_key = key
            except Exception:
                logger.warning("chart S3 upload/presign failed; falling back to inline data URL")
                render_src = data_url

        # Stash the render source in the side-channel and hand the model only a SHORT marker.
        # This keeps the blob out of the LLM token stream (which previously caused a
        # multi-minute chart retry loop) while the runtime swaps the marker for the image in
        # the FINAL reply via resolve_charts().
        token = uuid.uuid4().hex[:8]
        _CHART_REGISTRY[token] = render_src
        if len(_CHART_REGISTRY) > _CHART_REGISTRY_MAX:
            # Drop the oldest entries to bound memory (dict preserves insertion order).
            for old in list(_CHART_REGISTRY.keys())[:-_CHART_REGISTRY_MAX]:
                _CHART_REGISTRY.pop(old, None)

        result = {
            "status": "success",
            "description": description,
            "chart_marker": f"[[CHART:{token}]]",
            "render_hint": ("Put the chart_marker on its own line in your reply where the "
                            "chart should appear. The runtime substitutes the image. Do not "
                            "regenerate this chart."),
        }
        if chart_key:
            result["chart_s3_key"] = chart_key  # reference only; not required for rendering
        return json.dumps(result)

    except Exception as e:
        logger.exception("chart generation failed")
        return json.dumps({"status": "error", "error": str(e),
                           "hint": "Provide matplotlib code that builds a figure; savefig is automatic."})
    finally:
        if session_id:
            try:
                client.stop_code_interpreter_session(
                    codeInterpreterIdentifier=CI_IDENTIFIER, sessionId=session_id)
            except Exception:
                pass
