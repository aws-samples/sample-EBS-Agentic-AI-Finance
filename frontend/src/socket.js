// Shared singleton WebSocket for the single-pane-of-glass UI.
// One connection is multiplexed across the Overview, the drill-down views, and the
// always-docked AI Assistant. Consumers subscribe to messages and send actions;
// the socket auto-reconnects and replays a small queue of unsent messages.
import awsConfig from "./aws-config";

let ws = null;
let state = "idle"; // idle | connecting | open | closed
const listeners = new Set(); // fn(msg)
const stateListeners = new Set(); // fn(state)
let queue = [];
let reconnectTimer = null;
let retry = 0;

function setState(s) {
  state = s;
  stateListeners.forEach((fn) => fn(s));
}

// --- Backend (data) health -------------------------------------------------
// Distinct from socket state: the WebSocket can be OPEN while the database / app tier
// behind it is down (e.g. during a backup). The handler now sends {type:"health"} and
// {type:"error", code:"BACKEND_UNAVAILABLE"} so we can show a clear banner instead of $0.
// health: "unknown" | "healthy" | "unavailable"
let backendHealth = "unknown";
let backendReason = "";
const healthListeners = new Set(); // fn({health, reason})

function setBackendHealth(h, reason) {
  if (h === backendHealth && (reason || "") === backendReason) return;
  backendHealth = h;
  backendReason = reason || "";
  healthListeners.forEach((fn) => fn({ health: backendHealth, reason: backendReason }));
}

export function onHealth(fn) {
  healthListeners.add(fn);
  fn({ health: backendHealth, reason: backendReason });
  return () => healthListeners.delete(fn);
}

export function backendHealthState() {
  return { health: backendHealth, reason: backendReason };
}

// Ask the backend for a definitive up/down signal.
export function checkHealth() {
  return send({ action: "health" });
}

// Interpret every inbound message for health: an explicit health probe, a
// BACKEND_UNAVAILABLE error → unavailable; any successful data/reply → healthy.
function observeHealth(msg) {
  if (!msg) return;
  if (msg.type === "health") {
    const ok = msg.data && msg.data.healthy;
    setBackendHealth(ok ? "healthy" : "unavailable",
                     ok ? "" : (msg.data && msg.data.reason) || "Data backend unavailable");
  } else if (msg.type === "error" && msg.code === "BACKEND_UNAVAILABLE") {
    setBackendHealth("unavailable", msg.text || "Data backend unavailable");
  } else if (msg.type === "dashboard" || msg.type === "reply"
             || (typeof msg.type === "string" && msg.type.startsWith("p2p_"))) {
    // A real data/reply payload arrived → backend is serving again.
    setBackendHealth("healthy", "");
  }
}

// The current Cognito ID token, set by the app after login. Appended to the WS URL as
// ?token=… so the $connect Lambda can verify it server-side and derive the user's groups
// (WebSocket clients can't send Authorization headers).
let authToken = null;
export function setAuthToken(t) {
  const next = t || null;
  const changed = next !== authToken;
  authToken = next;
  // The token is set by App AFTER login, but a view may have already opened the socket
  // (React runs child effects before parent effects). A socket opened WITHOUT the token
  // makes $connect persist an EMPTY identity for the whole connection → all writes denied
  // even though the user is signed in. So when the token first arrives (or changes), force
  // a reconnect so $connect re-runs carrying ?token= and re-verifies the identity.
  if (next && changed && ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    const old = ws;
    ws = null;              // detach so onclose's auto-reconnect is a no-op for the old socket
    clearTimeout(reconnectTimer);
    try { old.onclose = null; old.close(); } catch {}
    connect();              // reconnect immediately WITH the token
  }
}

function connect() {
  if (!awsConfig.websocketUrl) {
    setState("closed");
    return;
  }
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

  setState("connecting");
  const url = authToken
    ? `${awsConfig.websocketUrl}?token=${encodeURIComponent(authToken)}`
    : awsConfig.websocketUrl;
  ws = new WebSocket(url);

  ws.onopen = () => {
    retry = 0;
    setState("open");
    const pending = queue;
    queue = [];
    pending.forEach((m) => send(m));
    // Probe the data backend on connect so the UI shows an accurate banner immediately
    // (the socket being open does NOT mean the database behind it is up).
    checkHealth();
  };

  ws.onmessage = (evt) => {
    let msg;
    try {
      msg = JSON.parse(evt.data);
    } catch {
      msg = { type: "reply", text: evt.data };
    }
    observeHealth(msg);
    listeners.forEach((fn) => fn(msg));
  };

  ws.onclose = () => {
    setState("closed");
    // exponential backoff reconnect (capped)
    const delay = Math.min(1000 * 2 ** retry, 15000);
    retry += 1;
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, delay);
  };

  ws.onerror = () => {
    try { ws.close(); } catch {}
  };
}

export function ensureSocket() {
  if (state === "idle" || state === "closed") connect();
  return state;
}

export function socketState() {
  return state;
}

export function onMessage(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function onState(fn) {
  stateListeners.add(fn);
  fn(state);
  return () => stateListeners.delete(fn);
}

export function send(obj) {
  const data = typeof obj === "string" ? obj : JSON.stringify(obj);
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(data);
    return true;
  }
  // buffer until the socket opens
  queue.push(data);
  ensureSocket();
  return false;
}

// Convenience: send a data request (dashboard / p2p_*) once the socket is open.
export function requestData(action, parameters) {
  return send(parameters ? { action, parameters } : { action });
}

// Convenience: send a prompt to the agent. `history` is an optional array of prior turns
// [{role:"user"|"agent", text}] so the agent can keep conversational context (e.g. when the
// user replies "2" to a menu the agent just offered). The agent is stateless per invoke, so
// context must ride with each message.
export function sendPrompt(prompt, history) {
  const msg = { action: "sendMessage", prompt };
  if (history && history.length) msg.history = history;
  return send(msg);
}
