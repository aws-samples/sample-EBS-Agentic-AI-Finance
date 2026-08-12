"""
AgentCore Runtime entrypoint — hosts the Strands collections/P2P agent on Amazon
Bedrock AgentCore Runtime (container, VPC-attached).

WHY AGENTCORE RUNTIME
  AgentCore Runtime is a containerized agent host with VPC connectivity (ENIs in your
  subnets + security groups), so it reaches the private Oracle 26ai DB on 1521 directly.
  Because it runs a container, it is also the natural home for the SQLcl 25.2+ MCP server
  (bundled in the image, spawned locally over stdio by tools/sqlcl_mcp.py) without
  fighting the Lambda 250MB zip limit. It is the sole host for the agent.

CONTRACT
  AgentCore Runtime invokes an HTTP server in the container: POST /invocations and
  GET /ping on port 8080. The bedrock-agentcore SDK's BedrockAgentCoreApp implements
  that contract; we just register an @app.entrypoint that calls the same Strands agent
  used everywhere else (agent_strands.create_agent), so behaviour is identical across
  Lambda and AgentCore hosts.

PAYLOAD
  Invoke with {"prompt": "...", "session_id": "..."} (same shape the WebSocket handler
  already sends). Returns {"reply": "<agent text>"}.
"""

import json
import logging
import re

from bedrock_agentcore.runtime import BedrockAgentCoreApp

from agent_strands import create_agent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = BedrockAgentCoreApp()

# --- Deterministic anti-hallucination guard --------------------------------------------
# The model is instructed never to claim a write it didn't perform, but instructions are
# not a guarantee — it has repeatedly emitted "Credit hold placed" / "note created (ID: 123)"
# without calling the tool. This guard is code, not prompt: after the agent runs we inspect
# the actual tool calls it made THIS turn. If the reply claims a write happened but no
# matching write-tool call returned success, we replace the reply with an honest message.

# Write action names as they appear in the tool `action` argument (collections + p2p).
_WRITE_ACTIONS = {
    "place_credit_hold", "release_credit_hold", "create_collections_note",
    "apply_order_holds", "release_order_holds", "create_collections_task",
    "send_dunning_letter", "send_payment_reminder",
    "release_ap_hold", "manual_approve_invoice", "create_ap_note",
    "approve_staged", "reject_staged", "submit_import",
}
# Tools that are themselves a write (no action arg needed).
_WRITE_TOOLS = {"ingest_invoice"}

# Phrases in a reply that assert a write COMPLETED (past tense / done).
_CLAIM_RE = re.compile(
    r"\b("
    r"credit hold (placed|released)|hold (placed|released|has been (placed|released))|"
    r"note (created|added|recorded|saved)|note\s*#?\s*\d|note \(id|"
    r"(dunning )?letter sent|reminder sent|(invoice )?approved|"
    r"payment reminder sent|task created|import submitted|"
    r"done\s*[—\-:]|✅"
    r")",
    re.IGNORECASE,
)


def _iter_content(messages):
    for m in messages or []:
        content = m.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    yield block


def _successful_writes(messages) -> set:
    """Return the set of write actions/tools that actually SUCCEEDED this turn.

    Walks Strands messages: collects toolUse blocks (name + action) and their matching
    toolResult blocks (by toolUseId), and keeps only those whose result JSON is a success
    and not a denial.
    """
    uses = {}      # toolUseId -> action-or-toolname (only for write tools)
    for blk in _iter_content(messages):
        tu = blk.get("toolUse")
        if not tu:
            continue
        name = tu.get("name") or ""
        inp = tu.get("input") or {}
        if isinstance(inp, str):
            try:
                inp = json.loads(inp)
            except Exception:
                inp = {}
        if name in _WRITE_TOOLS:
            uses[tu.get("toolUseId")] = name
        else:
            action = (inp or {}).get("action")
            if action in _WRITE_ACTIONS:
                uses[tu.get("toolUseId")] = action

    done = set()
    for blk in _iter_content(messages):
        tr = blk.get("toolResult")
        if not tr:
            continue
        tuid = tr.get("toolUseId")
        if tuid not in uses:
            continue
        # Flatten the result content to text.
        txt = ""
        for c in tr.get("content") or []:
            if isinstance(c, dict):
                txt += c.get("text") or (json.dumps(c.get("json")) if c.get("json") else "")
        low = txt.lower()
        # Lenient success: the write tool was actually invoked and its result is NOT an
        # explicit error/denial. (The high-confidence fabrication catch is "no write tool
        # invoked at all" — where `uses` is empty — so we bias toward NOT overriding a real
        # write that merely has an unfamiliar success payload.)
        is_error = tr.get("status") == "error" or '"status": "error"' in low or '"status":"error"' in low
        is_denied = '"status": "denied"' in low or '"status":"denied"' in low or '"reason": "not_authorized"' in low
        if not is_error and not is_denied:
            done.add(uses[tuid])
    return done


def _guard_reply(reply: str, messages) -> str:
    """If the reply claims a write but no write tool succeeded this turn, correct it."""
    if not reply or not _CLAIM_RE.search(reply):
        return reply
    if _successful_writes(messages):
        return reply  # a real successful write backs the claim — allow it
    logger.warning("anti-hallucination guard: reply claimed a write with no successful "
                   "write-tool call this turn; overriding. reply=%r", reply[:200])
    return ("I could not confirm that action was carried out — it was not recorded in the "
            "system, so I've not reported it as done. Please try again, and if it keeps "
            "failing it may be a permissions or connection issue.")

# The EXPENSIVE, shareable part (the SQLcl MCP JVM subprocess + tool list) is built lazily
# ONCE and cached inside agent_strands.get_tools(). The Agent object itself is cheap and
# STATEFUL/single-flight — a Strands Agent raises ConcurrencyException if invoked while a
# prior call is still running, and accumulates conversation history on the instance. The
# AgentCore container serves concurrent HTTP invocations, so we must NOT share one Agent
# across requests. Instead we build a fresh Agent PER invocation (reusing the cached tools),
# which gives each request its own concurrency controller and clean conversation state.
#
# Startup stays fast (nothing built at import): the one-time tool/MCP build happens on the
# first request, comfortably inside the runtime init budget since /ping is served immediately.


def _merge_history(mem_hist: list, browser_hist: list) -> list:
    """Choose the conversation history to seed the agent with, dedup, keep last 12.

    The BROWSER history is the source of truth for the current session: the UI sends the
    exact visible turns, in order, on every message — so it always reflects what the user
    just saw. We prefer it whenever it has content. AgentCore Memory is the durable fallback
    (survives a browser refresh / different device) used only when the browser sent nothing.

    (Earlier this preferred Memory, but if Memory returned turns in an unexpected order the
    pre-loaded messages could be mis-ordered and the model would lose the thread on a
    follow-up — e.g. answering "what's the hold type?" as if it were a brand-new question.)

    De-dups identical adjacent (role,text) pairs so a turn isn't doubled.
    """
    base = (browser_hist or []) if (browser_hist or []) else (mem_hist or [])
    deduped = []
    for h in base:
        if deduped and deduped[-1].get("role") == h.get("role") \
                and deduped[-1].get("text") == h.get("text"):
            continue
        deduped.append(h)
    return deduped[-12:]


@app.entrypoint
def invoke(payload: dict) -> dict:
    """AgentCore Runtime entrypoint. payload = {"prompt","session_id","auth","history"}."""
    payload = payload or {}
    prompt = payload.get("prompt") or payload.get("question") or ""
    if not prompt:
        return {"reply": "No prompt provided."}
    auth = payload.get("auth") or {}
    session_id = payload.get("session_id") or ""
    # Set the server-verified identity for deterministic RBAC in the write tools.
    try:
        from tools.authz import set_auth_context
        set_auth_context(auth)
    except Exception:
        pass

    # Conversation continuity: prefer durable AgentCore Memory (keyed on user+connection,
    # NOT the ephemeral runtimeSessionId), fall back to the browser-carried history.
    from tools import agent_memory
    mem_hist = agent_memory.load_history(auth, session_id, k=12)
    history = _merge_history(mem_hist, payload.get("history"))

    # Deterministic confirm-then-execute: if the user is affirming ("yes") a write the
    # agent proposed last turn (carried as a hidden [[CONFIRM:...]] marker in history),
    # execute that action IN CODE via the same audited/RBAC-gated tool logic — never via
    # the model — so a bare "yes" can't produce a fabricated success or a false
    # "could not confirm". Falls through to the model for anything else.
    try:
        from tools import pending_action
        det = pending_action.maybe_execute(prompt, history)
    except Exception:
        logger.exception("pending-action confirm-execute failed (falling back to model)")
        det = None
    if det is not None:
        agent_memory.save_turn(auth, session_id, prompt, det)
        return {"reply": det}

    try:
        # Fresh Agent per request (cached tools) — no shared single-flight instance, so
        # concurrent chart/data requests on the same warm container don't collide. Seed it
        # with the merged history so context survives across turns (stateless invoke).
        agent = create_agent(history)
        result = agent(prompt)
        # Swap any [[CHART:...]] markers for the inline PNG (kept out of the LLM context).
        from tools.chart_generator import resolve_charts
        reply = resolve_charts(str(result))
        # Deterministic guard: never let a "success" reply stand unless a matching write
        # tool actually succeeded this turn (defends against fabricated confirmations).
        try:
            reply = _guard_reply(reply, getattr(agent, "messages", None))
        except Exception:
            logger.exception("anti-hallucination guard failed (leaving reply unchanged)")
    except Exception as e:  # surface errors to the caller + logs
        logger.exception("agent invocation failed")
        return {"reply": f"Agent error: {e}"}

    # Persist this turn for future requests (best-effort; fail-open). The reply keeps its
    # hidden [[CONFIRM:...]] marker in BOTH memory and the returned text so the next-turn
    # "yes" can find + execute the captured action deterministically regardless of whether
    # history comes from memory or the browser. The marker is stripped at render time
    # (frontend Markdown) so the user never sees it.
    agent_memory.save_turn(auth, session_id, prompt, reply)
    return {"reply": reply}


if __name__ == "__main__":
    # Starts the HTTP server (POST /invocations, GET /ping) on port 8080.
    app.run()
