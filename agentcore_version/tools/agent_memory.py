"""
agent_memory — thin wrapper over Amazon Bedrock AgentCore Memory (short-term) for the
collections agent's multi-turn conversation continuity.

WHY THIS EXISTS
  The agent is built FRESH per request (concurrency design) and the WebSocket handler mints a
  UNIQUE runtimeSessionId per request (so a slow chart doesn't block the next message). That makes
  each invoke stateless, so conversation context ("reply 2 to a menu the agent just offered") must
  come from somewhere durable. Browser-carried history covers the fast path; this adds a
  server-side, refresh/device-durable store on top of it via AgentCore Memory.

KEYING (decoupled from the ephemeral runtimeSessionId, on purpose)
  actor_id   = the verified EBS username (falls back to Cognito user, then "anon")
  session_id = the WebSocket connectionId (a stable per-browser-session id)
  Neither is the runtimeSessionId, so concurrency (unique runtimeSessionId per call) is untouched
  while memory still accumulates per user+session.

FAIL-OPEN
  Every call is best-effort. If Memory is unconfigured (no MEMORY_ID) or the API errors, we log and
  return empty / no-op so the agent still answers (browser history remains the fallback).
"""

import os
import logging

logger = logging.getLogger(__name__)

_client = None


def _memory_id() -> str:
    return os.environ.get("AGENTCORE_MEMORY_ID", "").strip()


def enabled() -> bool:
    return bool(_memory_id())


def _get_client():
    """Lazily build the MemoryClient (only when a memory id is configured)."""
    global _client
    if _client is None:
        from bedrock_agentcore.memory import MemoryClient
        _client = MemoryClient(region_name=os.environ.get("AWS_REGION", "us-east-1"))
    return _client


def _norm_actor(auth: dict) -> str:
    auth = auth or {}
    return (auth.get("ebs_username") or auth.get("user") or "anon").strip() or "anon"


def _sanitize(s: str) -> str:
    """Coerce to the AgentCore Memory id charset [a-zA-Z0-9][a-zA-Z0-9-_]* ."""
    import re
    s = re.sub(r"[^a-zA-Z0-9-_]", "-", (s or "").strip())
    if not s:
        return ""
    if not re.match(r"[a-zA-Z0-9]", s):
        s = "s" + s
    return s[:255]


def _mem_session(auth: dict, session_id: str) -> str:
    """Derive the AgentCore Memory sessionId.

    Keyed on the STABLE verified user (ebs_username) + a UTC day bucket — NOT the WebSocket
    connectionId — so conversation memory SURVIVES a browser refresh/reconnect (a refresh mints
    a new connectionId, which would otherwise start a fresh, empty thread). The day bucket keeps
    a single user's memory thread from growing unbounded across many days while still spanning a
    normal working session. Falls back to the connectionId when there is no verified identity.
    Independent of the per-request runtimeSessionId, so agent concurrency is unaffected.
    """
    import datetime
    auth = auth or {}
    user = (auth.get("ebs_username") or auth.get("user") or "").strip()
    if user:
        day = datetime.datetime.utcnow().strftime("%Y%m%d")
        return _sanitize(f"u-{user}-{day}")
    return _sanitize(session_id)


def load_history(auth: dict, session_id: str, k: int = 12) -> list:
    """Return recent turns as [{"role":"user"|"agent","text":...}] for this user+session.

    Best-effort: returns [] if memory is disabled/unavailable. `k` counts conversation turns.
    """
    session_id = _mem_session(auth, session_id)
    if not enabled() or not session_id:
        return []
    try:
        turns = _get_client().get_last_k_turns(
            memory_id=_memory_id(),
            actor_id=_norm_actor(auth),
            session_id=session_id,
            k=k,
        )
    except Exception as e:
        logger.warning("memory load_history failed (continuing without): %s", e)
        return []

    out = []
    # turns = list[turn]; each turn = list[conversational payload dicts]
    for turn in turns or []:
        for msg in turn or []:
            try:
                role = (msg.get("role") or "").upper()
                text = ((msg.get("content") or {}).get("text") or "").strip()
            except AttributeError:
                continue
            if not text:
                continue
            out.append({"role": "agent" if role == "ASSISTANT" else "user", "text": text})
    return out


def save_turn(auth: dict, session_id: str, user_text: str, agent_text: str) -> None:
    """Persist one user+assistant turn to AgentCore Memory. Best-effort / fail-open."""
    session_id = _mem_session(auth, session_id)
    if not enabled() or not session_id:
        return
    msgs = []
    if (user_text or "").strip():
        msgs.append((user_text.strip(), "USER"))
    if (agent_text or "").strip():
        # Strip inline chart data URLs — never store the ~200KB base64 blob.
        import re
        clean = re.sub(r"data:image/png;base64,[A-Za-z0-9+/=]+", "[chart image]", agent_text)
        msgs.append((clean.strip(), "ASSISTANT"))
    if not msgs:
        return
    try:
        _get_client().create_event(
            memory_id=_memory_id(),
            actor_id=_norm_actor(auth),
            session_id=session_id,
            messages=msgs,
            extraction_mode="SKIP",  # short-term only; no long-term extraction configured
        )
    except Exception as e:
        logger.warning("memory save_turn failed (continuing): %s", e)
