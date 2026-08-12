import React, { useEffect, useRef, useState } from "react";
import { ensureSocket, onMessage, onState, sendPrompt } from "../socket";
import Markdown from "./Markdown";

// Chart extraction (markdown image, presigned S3 URL, or inline data: URL).
function extractChart(text) {
  if (!text) return null;
  const data = text.match(/data:image\/png;base64,[A-Za-z0-9+/=]+/);
  if (data) return data[0];
  const md = text.match(/\((https:\/\/[^)\s]+chart[^)\s]*\.png[^)\s]*)\)/i);
  if (md) return md[1];
  const url = text.match(/https:\/\/\S+charts\/\S+\.png\S*/i);
  return url ? url[0] : null;
}

const SUGGESTIONS = [
  "What is our total outstanding and overdue right now?",
  "Show the top 5 highest-risk customers by overdue amount.",
  "If I collect the top 10 overdue and release in-tolerance holds, how much cash is freed and what happens to DSO?",
  "Draw a bar chart of blocked payables by hold type.",
  "What is our policy for placing a customer on credit hold?",
  "Which customers are most likely to pay late?",
];

// Always-docked AI Assistant — one panel available on every screen. It shares the
// single app socket so it stays in context while the user browses the overview / drill-downs.
// `pendingPrompt` lets other panes push a question in (e.g. a row's "Ask AI" button).
function greeting(identity) {
  const first = identity && (identity.name || identity.email || "").split(/[@ ]/)[0];
  const who = first ? first.charAt(0).toUpperCase() + first.slice(1) : null;
  const role = identity && identity.role ? ` You're signed in as **${identity.role}**.` : "";
  const hi = who ? `Hi ${who} — ` : "Hi — ";
  return hi + "I'm your finance assistant. Ask about receivables, payables, or request an action. "
       + "Actions run through audited EBS APIs (ISG REST / seeded packages)." + role;
}

export default function AssistantDock({ open, onToggle, pendingPrompt, onConsumed, identity }) {
  // The message list is genuinely stateful (it accumulates chat turns), so it must live in
  // state; `identity` only seeds the initial greeting and the effect below refreshes it once
  // identity resolves. This is intentional, not an ignored prop copy.
  // nosemgrep: react-props-in-state
  const [messages, setMessages] = useState([
    { role: "agent", text: greeting(identity) },
  ]);

  // Refresh the greeting once identity resolves (token decode is async on first load).
  useEffect(() => {
    setMessages((m) => (m.length === 1 && m[0].role === "agent"
      ? [{ role: "agent", text: greeting(identity) }] : m));
  }, [identity]);
  const [input, setInput] = useState("");
  const [state, setStateLocal] = useState("connecting");
  const [busy, setBusy] = useState(false);
  const [zoom, setZoom] = useState(null); // chart src shown full-size in the lightbox
  const endRef = useRef(null);

  useEffect(() => {
    const offMsg = onMessage((msg) => {
      if (msg.type === "reply" || (msg.type === undefined && msg.text)) {
        setBusy(false);
        setMessages((m) => [...m, { role: "agent", text: msg.text }]);
      } else if (msg.type === "error") {
        setBusy(false);
        setMessages((m) => [...m, { role: "agent", text: "Error: " + msg.text }]);
      }
    });
    const offState = onState(setStateLocal);
    ensureSocket();
    return () => { offMsg(); offState(); };
  }, []);

  useEffect(() => {
    endRef.current && endRef.current.scrollIntoView({ behavior: "smooth" });
  }, [messages, open]);

  // When another pane requests a question, open the dock and fire it.
  useEffect(() => {
    if (pendingPrompt) {
      fire(pendingPrompt);
      onConsumed && onConsumed();
    }
  }, [pendingPrompt]);

  function fire(text) {
    const t = (text || "").trim();
    if (!t) return;
    // Capture recent conversation BEFORE adding this turn, and send it with the prompt so
    // the (stateless-per-invoke) agent keeps context — e.g. replying "2" to a menu it just
    // offered. messages[0] is the seeded greeting → skip it. Strip inline chart data URLs
    // (huge base64) from history text so the payload stays small. Cap to the last 12 turns.
    const history = messages
      .slice(1, )
      .slice(-12)
      .map((m) => ({
        role: m.role,
        text: (m.text || "").replace(/data:image\/png;base64,[A-Za-z0-9+/=]+/g, "[chart image]"),
      }));
    setMessages((m) => [...m, { role: "user", text: t }]);
    const ok = sendPrompt(t, history);
    setBusy(ok);
    if (!ok) setMessages((m) => [...m, { role: "agent", text: "Connecting… your message will send once the agent is online." }]);
  }

  function submit(e) {
    e.preventDefault();
    fire(input);
    setInput("");
  }

  return (
    <aside className={"dock " + (open ? "dock-open" : "dock-collapsed")}>
      <button className="dock-tab" onClick={onToggle} title={open ? "Hide assistant" : "Ask AI"}>
        {open ? "›" : "AI"}
      </button>

      {open && (
        <div className="dock-body">
          <div className="dock-head">
            <span className="dock-title">AI Assistant</span>
            <span className={"dot " + (state === "open" ? "dot-on" : "dot-off")} title={state} />
          </div>

          <div className="dock-log">
            {messages.map((m, i) => {
              const chart = extractChart(m.text);
              return (
                <div key={i} className={`bubble ${m.role}`}>
                  {m.role === "agent" ? <Markdown text={m.text} /> : m.text}
                  {chart && (
                    <div className="chart-wrap">
                      <img className="chart-img" src={chart} alt="Generated chart"
                           onClick={() => setZoom(chart)} title="Click to enlarge" />
                      <button className="chart-expand" onClick={() => setZoom(chart)}>⤢ Enlarge</button>
                    </div>
                  )}
                </div>
              );
            })}
            {busy && <div className="bubble agent typing">…thinking</div>}
            <div ref={endRef} />
          </div>

          {messages.length <= 1 && (
            <div className="dock-suggest">
              {SUGGESTIONS.map((s, i) => (
                <button key={i} className="chip" onClick={() => fire(s)}>{s}</button>
              ))}
            </div>
          )}

          <form className="dock-input" onSubmit={submit}>
            <input value={input} onChange={(e) => setInput(e.target.value)}
                   placeholder="Ask about AR/AP, or request an action…" />
            <button type="submit" disabled={busy}>Send</button>
          </form>
        </div>
      )}

      {/* Full-size chart lightbox — click any chart to enlarge */}
      {zoom && (
        <div className="lightbox" onClick={() => setZoom(null)}>
          <div className="lightbox-inner" onClick={(e) => e.stopPropagation()}>
            <button className="lightbox-close" onClick={() => setZoom(null)}>✕</button>
            <img src={zoom} alt="Chart (enlarged)" />
          </div>
        </div>
      )}
    </aside>
  );
}
