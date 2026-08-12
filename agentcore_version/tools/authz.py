"""
authz — deterministic, group-based authorization for agent write actions.

SECURITY MODEL
  The LLM is NEVER the security boundary. Authorization is decided here, in plain code,
  from the caller's *verified* Cognito group membership (the WebSocket $connect handler
  validates the JWT signature against the Cognito JWKS and persists the derived groups
  server-side in DynamoDB; they are not client-supplied per message). Every write tool
  calls `require(action)` before it touches the DB / EBS API.

MAPPING (Cognito group -> EBS responsibility -> allowed actions)
  ar-managers  → AR Collections Manager   : all AR write actions
  ar-analysts  → AR Enquiry (read-only)    : no writes
  ap-managers  → AP Manager                : all AP write actions
  ap-clerks    → AP read-only              : no writes
  (a user may hold several groups; permissions are the union)

Reads (queries, charts, KB, diagnosis, proposals-only) are open to any authenticated
user and are NOT gated here.
"""

import os
import json
import logging
import contextvars

logger = logging.getLogger(__name__)

# --- Write actions grouped by the responsibility that authorizes them -------------
AR_WRITE_ACTIONS = {
    "place_credit_hold",
    "release_credit_hold",
    "create_collections_note",
    "apply_order_holds",
    "release_order_holds",
    "create_collections_task",
    "send_dunning_letter",
    "send_payment_reminder",
}

AP_WRITE_ACTIONS = {
    "release_ap_hold",
    "manual_approve_invoice",
    "create_ap_note",
    "approve_staged",       # p2p_approve_review
    "reject_staged",        # p2p_reject_review
    "submit_import",        # p2p_submit_import
    # NOTE: propose_payment is proposal-only (no money movement) → READ, not gated.
    # NOTE: validate_invoice recomputes/report holds and takes no business action → READ, not gated.
}

# Cognito group -> set of write actions it grants.
GROUP_ACTIONS = {
    "ar-managers": AR_WRITE_ACTIONS,
    "ap-managers": AP_WRITE_ACTIONS,
    "ar-analysts": set(),   # read-only
    "ap-clerks": set(),     # read-only
}

# Actions that are always allowed (reads / proposals). Not exhaustive — anything NOT in
# AR_WRITE_ACTIONS ∪ AP_WRITE_ACTIONS is treated as a read and allowed.
ALL_WRITE_ACTIONS = AR_WRITE_ACTIONS | AP_WRITE_ACTIONS

# Per-invocation identity, set by the runtime before the agent runs.
#   {"user": "demo-manager@example.com", "ebs_username": "SYSADMIN",
#    "groups": ["ar-managers","ap-managers"]}
_auth_ctx: "contextvars.ContextVar[dict]" = contextvars.ContextVar("auth_ctx", default=None)


def set_auth_context(ctx: dict) -> None:
    """Called by the runtime (per request) with the VERIFIED identity."""
    _auth_ctx.set(ctx or {})


def get_auth_context() -> dict:
    return _auth_ctx.get() or {}


def allowed_actions(groups) -> set:
    groups = groups or []
    out = set()
    for g in groups:
        out |= GROUP_ACTIONS.get(g, set())
    return out


def is_write_action(action: str) -> bool:
    return action in ALL_WRITE_ACTIONS


def decide(action: str, groups=None) -> tuple:
    """Return (allowed: bool, message: str) for `action` given `groups`.

    Reads are always allowed. Writes require a group that grants the action.
    """
    if not is_write_action(action):
        return True, ""
    granted = allowed_actions(groups)
    if action in granted:
        return True, ""
    # Deny — craft a role-aware, escalation-oriented message.
    domain = "AP" if action in AP_WRITE_ACTIONS else "AR"
    needed = "an AP responsibility (AP Manager)" if domain == "AP" \
             else "an AR responsibility (AR Collections Manager)"
    return False, (
        f"You don't have permission to perform '{action}'. This action requires {needed}. "
        f"Your current access is read-only for {domain}. Please ask an authorised manager to perform it, "
        f"or request the responsibility be added to your EBS account."
    )


class NotAuthorized(Exception):
    """Raised (or serialised to JSON) when a write action is denied."""


def require(action: str) -> None:
    """Enforce authorization for a write action using the current auth context.

    Raises NotAuthorized(message) if denied. Reads pass through.

    Fail-closed policy for WRITES: if no verified identity is present at all
    (auth context missing), writes are denied. This prevents an unauthenticated
    path from silently gaining write access. Set AUTHZ_ENFORCE=0 to disable
    enforcement entirely (dev/local only).
    """
    if os.environ.get("AUTHZ_ENFORCE", "1") != "1":
        return
    if not is_write_action(action):
        return
    ctx = get_auth_context()
    groups = ctx.get("groups")
    if groups is None:
        # No verified identity attached → deny writes (fail closed).
        raise NotAuthorized(
            f"'{action}' is a write action and requires an authenticated user with the "
            f"appropriate EBS responsibility. No verified identity was provided."
        )
    ok, msg = decide(action, groups)
    if not ok:
        raise NotAuthorized(msg)


def denial_json(action: str, message: str) -> str:
    """Standard denial payload a tool can return to the agent."""
    return json.dumps({
        "status": "denied",
        "action": action,
        "reason": "not_authorized",
        "message": message,
    })


if __name__ == "__main__":
    # Self-test (pure logic, no AWS/DB).
    tests = [
        # (action, groups, expect_allowed)
        ("place_credit_hold",   ["ar-managers"], True),
        ("place_credit_hold",   ["ar-analysts"], False),
        ("place_credit_hold",   ["ap-managers"], False),   # AP group can't do AR write
        ("release_ap_hold",     ["ap-managers"], True),
        ("release_ap_hold",     ["ap-clerks"],   False),
        ("release_ap_hold",     ["ar-managers"], False),   # AR group can't do AP write
        ("release_ap_hold",     ["ar-managers", "ap-managers"], True),  # union
        ("get_overdue_customers", ["ar-analysts"], True),  # read always allowed
        ("propose_payment",     ["ap-clerks"],   True),    # proposal-only = read
        ("submit_import",       ["ap-managers"], True),
        ("submit_import",       [],              False),
    ]
    passed = 0
    for action, groups, expect in tests:
        got, _ = decide(action, groups)
        ok = got == expect
        passed += ok
        print(f"{'PASS' if ok else 'FAIL'}  decide({action!r}, {groups}) = {got} (want {expect})")
    # require() fail-closed test
    os.environ["AUTHZ_ENFORCE"] = "1"
    set_auth_context({})  # no groups key
    try:
        require("place_credit_hold")
        print("FAIL  require with no identity should have raised")
    except NotAuthorized:
        passed += 1
        print("PASS  require() fails closed with no verified identity")
    set_auth_context({"groups": ["ar-managers"]})
    try:
        require("place_credit_hold")
        print("PASS  require() allows ar-managers place_credit_hold")
        passed += 1
    except NotAuthorized:
        print("FAIL  require() wrongly denied ar-managers")
    print(f"\n{passed}/{len(tests)+2} checks passed")
