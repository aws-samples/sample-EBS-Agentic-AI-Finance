"""
Agent runtime Lambda (VPC-attached) — FALLBACK host for the Strands collections agent.

Primary host is the Amazon Bedrock AgentCore Runtime (VPC-connected). AWS added VPC
connectivity to AgentCore Runtime, so the managed runtime reaches the private-subnet
Oracle 26ai DB (10.0.1.13) and EBS app tier (10.0.1.194) directly and is the live host.
This VPC-attached Lambda runs the SAME agent_strands.py as a drop-in fallback that can also
reach Bedrock (NL->SQL) via the AWS API, oracledb to the DB, and ISG REST to the EBS app
tier — used when AGENT_RUNTIME_ARN is unset on the WebSocket handler.

Invoked by the WebSocket handler with {"prompt": "...", "session_id": "..."}.
Returns {"reply": "<agent text>"}.
"""

import os
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    prompt = event.get("prompt") or event.get("question") or ""
    if not prompt:
        return {"statusCode": 400, "reply": "No prompt provided."}

    # Set the server-verified identity for deterministic RBAC in the write tools.
    # The WebSocket handler verified the Cognito JWT and passes {user, ebs_username, groups}.
    try:
        from tools.authz import set_auth_context
        set_auth_context(event.get("auth") or {})
    except Exception:
        pass

    # Deterministic confirm-then-execute (mirrors agentcore_runtime): if the user is
    # affirming ("yes") a write the agent proposed last turn (hidden [[CONFIRM:...]] marker
    # in history), run that action in code via the audited/RBAC-gated tool logic instead of
    # the model — so a bare "yes" can't fabricate success or wrongly report failure.
    try:
        from tools import pending_action
        det = pending_action.maybe_execute(prompt, event.get("history"))
    except Exception:
        logger.exception("pending-action confirm-execute failed (falling back to model)")
        det = None
    if det is not None:
        return {"statusCode": 200, "reply": det}

    try:
        # Build a fresh Agent per invocation (the expensive SQLcl MCP tool list is cached
        # inside agent_strands.get_tools()). A Strands Agent is stateful and single-flight:
        # sharing one across a warm Lambda's invocations both risks a ConcurrencyException
        # and leaks conversation history between callers. Fresh Agent = clean state; the
        # cached tools mean we don't re-pay the JVM/MCP cold start.
        from agent_strands import create_agent
        agent = create_agent(event.get("history"))
        result = agent(prompt)
        # Strands Agent returns an object whose str() is the assistant text.
        # Swap any [[CHART:...]] markers for the inline PNG (kept out of the LLM context).
        from tools.chart_generator import resolve_charts
        reply = resolve_charts(str(result))
        return {"statusCode": 200, "reply": reply}
    except Exception as e:
        logger.exception("agent invocation failed")
        return {"statusCode": 500, "reply": f"Agent error: {e}"}
