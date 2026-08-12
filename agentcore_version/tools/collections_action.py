"""
execute_collections_action — audited collections write-back on Oracle EBS.

PATH (verified live): the agent invokes the VPC collections Lambda `ebs-collections-26ai`,
which executes the action through the **audited APPS package** `APPS.XX_COLLECTIONS_REST_PKG`
over oracledb (definer-rights → EBS public APIs: HZ customer profiles, JTF notes, OE holds,
etc.). This is the SOX-compliant path that ships — no direct DML from the agent, and it does
NOT depend on the ISG REST HTTP surface (which is stale on this clone and returns 400 /
ISG_SERVICE_EXECUTION_ERROR).

The Lambda itself can still be flipped to the ISG REST HTTP path with USE_ISG_REST_HTTP=1, so
the SOX story (all mutations via audited EBS APIs) is unchanged — this tool just calls the
Lambda and lets it choose the working path.

Set COLLECTIONS_LAMBDA_NAME to override the target function (default ebs-collections-26ai).
"""

import os
import json
import logging

import boto3
from strands import tool

from tools.authz import require, NotAuthorized, denial_json

logger = logging.getLogger(__name__)

VALID_ACTIONS = [
    "get_overdue_customers",
    "get_customer_details",
    "place_credit_hold",
    "release_credit_hold",
    "create_collections_note",
    "apply_order_holds",
    "release_order_holds",
    "create_collections_task",
    "send_dunning_letter",
    "send_payment_reminder",
]


@tool
def execute_collections_action(action: str, parameters: dict) -> str:
    """
    Execute a collections action on Oracle EBS through the audited APPS package
    (via the ebs-collections-26ai Lambda over oracledb → EBS public APIs).

    Available actions:
    - get_overdue_customers: list overdue customers (params: {top})
    - get_customer_details: invoice detail for a customer (params: {customer_id})
    - place_credit_hold: place a credit hold (params: {customer_id, reason})
    - release_credit_hold: release a credit hold (params: {customer_id, reason})
    - create_collections_note: audited note on the account (params: {customer_id, note_text})
    - apply_order_holds / release_order_holds: order holds (params: {customer_id, reason})
    - create_collections_task: follow-up task (params: {customer_id, subject, due_date})
    - send_dunning_letter: AI-generated letter + audited note (params: {customer_id, level, tone})
    - send_payment_reminder: payment reminder (params: {customer_id})

    Args:
        action: one of the actions above.
        parameters: action-specific parameters.

    Returns:
        JSON string with the action result or an error message.
    """
    return run_collections_action(action, parameters)


def run_collections_action(action: str, parameters: dict) -> str:
    """Plain (non-@tool) implementation of a collections action.

    Kept separate from the Strands @tool wrapper so the runtime's deterministic
    confirm-then-execute path (tools.pending_action) can invoke the SAME audited logic
    — including the RBAC gate below — without going through the LLM. Both callers get
    identical enforcement and result shape.
    """
    if action not in VALID_ACTIONS:
        return json.dumps({
            "status": "error",
            "error": f"Invalid action: {action}. Valid actions: {VALID_ACTIONS}",
        })

    # Deterministic RBAC gate — deny write actions the caller's Cognito group(s) don't
    # grant, BEFORE any Lambda/DB/EBS call. Reads pass through. The LLM cannot bypass this.
    try:
        require(action)
    except NotAuthorized as na:
        logger.info("collections action denied by RBAC: %s", action)
        return denial_json(action, str(na))

    fn = os.environ.get("COLLECTIONS_LAMBDA_NAME", "ebs-collections-26ai")
    region = os.environ.get("AWS_REGION", "us-east-1")
    try:
        client = boto3.client("lambda", region_name=region)
        resp = client.invoke(
            FunctionName=fn,
            InvocationType="RequestResponse",
            Payload=json.dumps({"action": action, "parameters": parameters or {}}).encode(),
        )
        payload = json.loads(resp["Payload"].read())
        # Lambda returns {statusCode, body}; unwrap body to the tool result.
        if isinstance(payload, dict) and "body" in payload:
            try:
                body = json.loads(payload["body"])
            except (TypeError, ValueError):
                body = {"raw": payload["body"]}
            ok = payload.get("statusCode", 200) < 400 and body.get("status") != "error"
            return json.dumps({
                "status": "success" if ok else "error",
                "action": action,
                "result": body,
            }, default=str)
        return json.dumps({"status": "success", "action": action, "result": payload}, default=str)
    except Exception as e:
        logger.exception("collections action failed")
        return json.dumps({"status": "error", "action": action, "error": str(e)})
