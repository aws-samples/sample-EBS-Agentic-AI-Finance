"""
pending_action — deterministic confirm-then-execute for write actions.

WHY THIS EXISTS
  Write actions are confirmation-gated: turn 1 the agent proposes ("Place a credit hold on
  1007 for 'demo'? (yes/no)"), turn 2 the user replies "yes". Because the agent is built
  FRESH and STATELESS per request (concurrency design), on the "yes" turn the model would
  sometimes narrate "Done — hold placed" WITHOUT re-invoking the write tool. The
  anti-hallucination guard then correctly overrode the reply with "I could not confirm…",
  so a genuinely-intended action appeared to fail. Pleading with the prompt did not make
  the model reliably re-emit the tool call.

THE FIX (deterministic, not prompt-based)
  When the agent asks a write confirmation it appends a hidden, machine-readable marker
  capturing the exact action + params:

      [[CONFIRM:{"domain":"collections","action":"release_credit_hold",
                 "params":{"customer_id":1007,"reason":"demo"}}]]

  The runtime strips the marker from the visible reply (like the [[CHART:…]] side-channel)
  but KEEPS it in the conversation history/memory. On the next turn, if the user affirms
  ("yes"/"y"/"confirm"/…), the runtime finds the most recent CONFIRM in history and executes
  that action IN CODE (run_collections_action / run_p2p_action) — same audited, RBAC-gated
  path the tools use — then returns the real tool result. The model is bypassed entirely for
  that step, so a bare "yes" can never produce a fabricated success and never a false
  "could not confirm".

SAFETY
  - Execution still goes through run_*_action → require() RBAC gate → audited APPS package.
  - Only fires on an explicit affirmation whose message is essentially JUST the affirmation
    (so "yes, but first show me the invoice" does NOT auto-execute — it goes to the model).
  - If the user says anything else (a new question, "no", "cancel"), no pending action runs.
"""

import json
import logging
import re

logger = logging.getLogger(__name__)

# Hidden marker the agent appends to a write-confirmation question. Non-greedy JSON body.
CONFIRM_RE = re.compile(r"\[\[CONFIRM:(\{.*?\})\]\]", re.DOTALL)

# A turn that is essentially only an affirmation (optional punctuation/politeness).
_AFFIRM_RE = re.compile(
    r"^\s*(yes|y|yep|yeah|yup|ok|okay|confirm(ed)?|go ahead|do it|proceed|approved?|"
    r"sure|please do|go|continue)\s*[.!]*\s*$",
    re.IGNORECASE,
)

_COLLECTIONS_ACTIONS = {
    "place_credit_hold", "release_credit_hold", "create_collections_note",
    "apply_order_holds", "release_order_holds", "create_collections_task",
    "send_dunning_letter", "send_payment_reminder",
}
_P2P_ACTIONS = {"release_ap_hold", "manual_approve_invoice", "create_ap_note",
                "propose_payment", "validate_invoice"}


def strip_confirm_marker(reply: str) -> str:
    """Remove any [[CONFIRM:...]] marker(s) from the visible reply text."""
    if not reply:
        return reply
    return CONFIRM_RE.sub("", reply).rstrip()


def is_affirmation(prompt: str) -> bool:
    """True if the user's message is essentially just 'yes' (and nothing more)."""
    return bool(prompt and _AFFIRM_RE.match(prompt.strip()))


def find_pending(history: list) -> dict | None:
    """Return the most recent pending CONFIRM action from agent history, or None.

    `history` is [{"role":"user"|"agent"|"assistant","text":...}] (the merged history the
    runtime already builds). We scan newest→oldest for an agent turn carrying a CONFIRM
    marker. If a later USER turn already answered it, that's fine — we only reach here when
    THIS turn is an affirmation, and the newest CONFIRM is the one being answered.
    """
    for h in reversed(history or []):
        role = (h.get("role") or "").lower()
        if role not in ("agent", "assistant"):
            continue
        m = CONFIRM_RE.search(h.get("text") or "")
        if not m:
            # An agent turn WITHOUT a marker between now and an older marker means the
            # older proposal was already resolved/superseded — stop looking.
            return None
        try:
            spec = json.loads(m.group(1))
        except (ValueError, TypeError):
            return None
        if spec.get("action"):
            return spec
    return None


def execute(spec: dict) -> str:
    """Run a captured action deterministically via the audited, RBAC-gated tool logic.

    Returns the tool's JSON result string (same shape the LLM would have gotten), or an
    error JSON if the spec is malformed / unknown.
    """
    action = (spec or {}).get("action")
    params = (spec or {}).get("params") or {}
    domain = (spec or {}).get("domain")

    if domain == "p2p" or action in _P2P_ACTIONS:
        from tools.p2p_query import run_p2p_action
        return run_p2p_action(action, params)
    if domain == "collections" or action in _COLLECTIONS_ACTIONS:
        from tools.collections_action import run_collections_action
        return run_collections_action(action, params)
    return json.dumps({"status": "error",
                       "error": f"Unknown pending action: {action!r}"})


def _summarize(action: str, result_json: str) -> str:
    """One-line, user-facing outcome from the tool's real result (no fabrication)."""
    try:
        res = json.loads(result_json)
    except (ValueError, TypeError):
        res = {}
    status = res.get("status")
    if status == "denied" or res.get("reason") == "not_authorized":
        return "That action was not performed — you don't have permission for it."
    if status != "success":
        err = res.get("error") or res.get("message") or "the backend reported an error"
        return f"That action was NOT performed — {err}."

    body = res.get("result") if isinstance(res.get("result"), dict) else {}
    note_id = body.get("note_id") or body.get("jtf_note_id") or body.get("x_jtf_note_id")
    verb = {
        "place_credit_hold": "Credit hold placed",
        "release_credit_hold": "Credit hold released",
        "create_collections_note": "Note recorded",
        "apply_order_holds": "Order hold applied",
        "release_order_holds": "Order hold released",
        "create_collections_task": "Task created",
        "send_dunning_letter": "Dunning letter processed",
        "send_payment_reminder": "Payment reminder processed",
        "release_ap_hold": "AP hold released",
        "manual_approve_invoice": "Invoice manually approved",
        "create_ap_note": "AP note recorded",
    }.get(action, "Action completed")
    line = f"Done — {verb.lower()}."
    if note_id:
        line = f"Done — {verb.lower()} (note #{note_id})."
    return line


def maybe_execute(prompt: str, history: list) -> str | None:
    """If the user affirmed a pending write, execute it deterministically and return a
    one-line reply. Otherwise return None (let the model handle the turn normally)."""
    if not is_affirmation(prompt):
        return None
    spec = find_pending(history)
    if not spec:
        return None
    logger.info("deterministic confirm-execute: action=%s domain=%s",
                spec.get("action"), spec.get("domain"))
    result_json = execute(spec)
    return _summarize(spec.get("action"), result_json)
