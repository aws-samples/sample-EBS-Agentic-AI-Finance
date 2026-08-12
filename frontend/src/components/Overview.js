import React, { useEffect, useRef, useState } from "react";
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell } from "recharts";
import { ensureSocket, onMessage, requestData } from "../socket";

function money(n) {
  if (n == null) return "-";
  const v = Number(n);
  if (Math.abs(v) >= 1e9) return "$" + (v / 1e9).toFixed(2) + "B";
  if (Math.abs(v) >= 1e6) return "$" + (v / 1e6).toFixed(1) + "M";
  if (Math.abs(v) >= 1e3) return "$" + (v / 1e3).toFixed(0) + "k";
  return "$" + v.toLocaleString(undefined, { maximumFractionDigits: 0 });
}
function num(n) { return Number(n || 0).toLocaleString(); }

// Single pane of glass: the working-capital overview. Combines cash-IN (AR / Collections)
// and cash-OUT (AP / Payables) on one screen so a finance lead sees the whole cycle,
// then drills into a side or hands a row to the docked AI Assistant.
export default function Overview({ onDrill, onAsk }) {
  const [risk, setRisk] = useState([]);
  const [p2p, setP2p] = useState(null);
  const [arReady, setArReady] = useState(false);
  const [apReady, setApReady] = useState(false);
  const [sim, setSim] = useState(null);
  const [simBusy, setSimBusy] = useState(false);
  const [plan, setPlan] = useState(null);
  const [down, setDown] = useState(false); // backend (DB/app tier) unavailable
  const kickoff = useRef(false);

  useEffect(() => {
    const off = onMessage((msg) => {
      if (msg.type === "dashboard") { setRisk(msg.data.risk_customers || []); setArReady(true); setDown(false); }
      else if (msg.type === "p2p_dashboard") { setP2p(msg.data); setApReady(true); setDown(false); }
      else if (msg.type === "p2p_simulate") { setSim(msg.data.simulation || null); setSimBusy(false); }
      else if (msg.type === "p2p_action_plan") { setPlan(msg.data.action_plan || []); }
      else if (msg.type === "error" && msg.code === "BACKEND_UNAVAILABLE") {
        // DB down: stop showing $0 as if it were real. Mark unavailable and clear "loading".
        setDown(true); setArReady(true); setApReady(true); setSimBusy(false);
        if (plan === null) setPlan([]);
      }
    });
    ensureSocket();
    // request both halves of the cycle + the action plan
    requestData("dashboard");
    requestData("p2p_dashboard", { top: 8 });
    requestData("p2p_action_plan", { top: 6 });
    kickoff.current = true;
    return off;
  }, []);

  function runSim() {
    setSimBusy(true);
    requestData("p2p_simulate", { top_ar: 10, tol_pct: 5 });
  }

  // AR side
  const totalOverdue = risk.reduce((s, r) => s + Number(r.total_overdue || 0), 0);
  const arTop = risk.slice(0, 5);

  // AP side
  const kpis = p2p?.kpis || [];
  const kpiVal = (re) => {
    const k = kpis.find((x) => re.test(x.metric_label || ""));
    return k ? Number(k.metric_value) : null;
  };
  const blocked = kpiVal(/blocked|value/i);
  const onHold = kpiVal(/hold/i);
  const awaiting = kpiVal(/approv/i);
  const apExceptions = (p2p?.exceptions || []).slice(0, 5);
  const holds = (p2p?.holds_by_type || []).slice(0, 5)
    .map((h) => ({ name: h.hold_type || "OTHER", amount: Number(h.amount || 0) }));

  return (
    <div className="overview">
      <div className="overview-head">
        <div>
          <h2>Working-Capital Overview</h2>
          <div className="muted">Live Oracle E-Business Suite (AR + AP) · Oracle 26ai — one pane for the whole cash cycle</div>
        </div>
      </div>

      {down && (
        <div className="data-unavailable-note">
          Live figures are unavailable right now — the data service may be under maintenance.
          Values are hidden rather than shown as zero.
        </div>
      )}

      {/* Headline: cash-in vs cash-out */}
      <div className="wc-balance">
        <button className="wc-side wc-in" onClick={() => onDrill && onDrill("dashboard")}>
          <div className="wc-side-label">CASH IN · Receivables</div>
          <div className="wc-side-value">{down ? "—" : (arReady ? money(totalOverdue) : "…")}</div>
          <div className="wc-side-sub">{down ? "unavailable" : `overdue across top risk accounts · ${num(risk.length)} flagged`}</div>
        </button>
        <div className="wc-mid">
          <div className="wc-mid-badge">CASH CYCLE</div>
          <div className="wc-mid-line" />
        </div>
        <button className="wc-side wc-out" onClick={() => onDrill && onDrill("payables")}>
          <div className="wc-side-label">CASH OUT · Payables</div>
          <div className="wc-side-value">{down ? "—" : (apReady ? money(blocked) : "…")}</div>
          <div className="wc-side-sub">{down ? "unavailable" : `blocked value · ${num(onHold)} invoices on hold`}</div>
        </button>
      </div>

      {/* Unified KPI strip across the cycle */}
      <div className="kpis kpis-4 overview-kpis">
        <button className="kpi kpi-click" onClick={() => onDrill && onDrill("dashboard")}>
          <div className="kpi-label">Overdue receivables (top risk)</div>
          <div className="kpi-value">{down ? "—" : (arReady ? money(totalOverdue) : "…")}</div>
          <div className="kpi-sub">{down ? "unavailable" : "cash to collect"}</div>
        </button>
        <button className="kpi kpi-click" onClick={() => onDrill && onDrill("payables")}>
          <div className="kpi-label">Blocked payables</div>
          <div className="kpi-value">{down ? "—" : (apReady ? money(blocked) : "…")}</div>
          <div className="kpi-sub">{down ? "unavailable" : "value stuck on holds"}</div>
        </button>
        <button className="kpi kpi-click" onClick={() => onDrill && onDrill("payables")}>
          <div className="kpi-label">Invoices on hold</div>
          <div className="kpi-value">{down ? "—" : (apReady ? num(onHold) : "…")}</div>
          <div className="kpi-sub">{down ? "unavailable" : "payables exceptions"}</div>
        </button>
        <button className="kpi kpi-click" onClick={() => onDrill && onDrill("payables")}>
          <div className="kpi-label">Awaiting approval</div>
          <div className="kpi-value">{down ? "—" : (apReady ? num(awaiting) : "…")}</div>
          <div className="kpi-sub">{down ? "unavailable" : "pending sign-off"}</div>
        </button>
      </div>

      {/* Action plan — the "agent runs your day" worklist */}
      <div className="card">
        <h3>Recommended action plan <span className="muted">— highest-value moves right now (AR + AP)</span></h3>
        {!plan && <div className="muted">loading…</div>}
        {plan && plan.length === 0 && <div className="muted">No actions recommended.</div>}
        {plan && plan.length > 0 && (
          <table className="grid">
            <thead>
              <tr><th>#</th><th>Side</th><th>Target</th><th>Value</th><th>Recommended</th><th>Policy</th><th></th></tr>
            </thead>
            <tbody>
              {plan.map((m, i) => (
                <tr key={i}>
                  <td>{m.rank}</td>
                  <td><span className="badge" style={{ background: m.domain === "AR" ? "#147a45" : "#b3290f" }}>{m.domain}</span></td>
                  <td>{m.name} <span className="muted">({m.ref_id})</span></td>
                  <td>{money(m.value)}</td>
                  <td>{(m.recommended_action || "").replace(/_/g, " ")}</td>
                  <td>{m.within_policy === "Y"
                    ? <span className="badge" style={{ background: "#1a9e5c" }}>within policy</span>
                    : <span className="badge" style={{ background: "#e07b00" }}>needs review</span>}</td>
                  <td>
                    <button className="link-btn" onClick={() => onAsk && onAsk(
                      m.domain === "AR"
                        ? `For customer ${m.name} (account ${m.ref_id}), recommend and prepare a ${(m.recommended_action || "").replace(/_/g, " ")} per our policy. Show me what you'll do before acting.`
                        : `For AP invoice ${m.ref_id} (invoice_id ${m.entity_id}): diagnose the hold, confirm it's within tolerance, and if so propose releasing it (I'll approve).`
                    )}>Act&nbsp;with&nbsp;AI</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <div className="muted" style={{ marginTop: 6 }}>
          The assistant proposes; you approve. Actions run through audited seeded EBS APIs.
        </div>
      </div>

      {/* Working-capital what-if simulator — the CFO money-shot */}
      <div className="card wc-sim">
        <h3>Working-capital what-if
          <span className="muted"> — project collecting the top 10 overdue + releasing in-tolerance holds</span>
          <button className="wc-sim-run" onClick={runSim} disabled={simBusy}>
            {simBusy ? "Simulating…" : "Run simulation"}</button>
        </h3>
        {!sim && !simBusy && (
          <div className="muted">Click "Run simulation" to project the impact on cash, DSO and DPO.</div>
        )}
        {sim && sim.status !== "error" && (
          <>
            <div className="wc-sim-grid">
              <div className="wc-sim-metric">
                <div className="wc-sim-label">Cash freed</div>
                <div className="wc-sim-value up">{money(sim.cash_freed)}</div>
                <div className="wc-sim-sub">collect {money(sim.cash_collected)} + release {money(sim.holds_released_value)}</div>
              </div>
              <div className="wc-sim-metric">
                <div className="wc-sim-label">AR open</div>
                <div className="wc-sim-value">{money(sim.before_ar_open)} → <b>{money(sim.after_ar_open)}</b></div>
                <div className="wc-sim-sub">receivables outstanding</div>
              </div>
              <div className="wc-sim-metric">
                <div className="wc-sim-label">Blocked payables</div>
                <div className="wc-sim-value">{money(sim.before_ap_blocked)} → <b>{money(sim.after_ap_blocked)}</b></div>
                <div className="wc-sim-sub">value unblocked</div>
              </div>
              <div className="wc-sim-metric">
                <div className="wc-sim-label">DSO (days)</div>
                <div className="wc-sim-value">{sim.before_dso_days} → <b>{sim.after_dso_days}</b>
                  {sim.dso_improvement_days > 0 &&
                    <span className="wc-delta"> −{sim.dso_improvement_days}d</span>}</div>
                <div className="wc-sim-sub">days sales outstanding</div>
              </div>
            </div>
            <div className="muted" style={{ marginTop: 8 }}>
              Projection only (estimate from live balances) — no action taken. Ask the assistant to
              "build the action plan for this" to execute it move-by-move.
            </div>
          </>
        )}
        {sim && sim.status === "error" && <div className="muted">Simulation error: {sim.message}</div>}
      </div>

      <div className="overview-grid">
        {/* CASH IN worklist */}
        <div className="card">
          <h3>Collect first <span className="muted">— highest-overdue customers</span></h3>
          {!arReady && <div className="muted">loading…</div>}
          <table className="grid">
            <thead><tr><th>Customer</th><th>Overdue</th><th>Days</th><th></th></tr></thead>
            <tbody>
              {arTop.map((r, i) => (
                <tr key={i}>
                  <td>{r.party_name}</td>
                  <td>{money(r.total_overdue)}</td>
                  <td>{r.max_days_overdue}</td>
                  <td>
                    <button className="link-btn" onClick={() =>
                      onAsk && onAsk(`For customer ${r.party_name} (account ${r.account_number}): summarise their overdue position and recommend the next collections action per our policy.`)}>
                      Ask&nbsp;AI
                    </button>
                  </td>
                </tr>
              ))}
              {arReady && arTop.length === 0 && <tr><td colSpan="4" className="muted">{down ? "Data unavailable — service under maintenance." : "No overdue accounts."}</td></tr>}
            </tbody>
          </table>
        </div>

        {/* CASH OUT worklist */}
        <div className="card">
          <h3>Unblock next <span className="muted">— top payables exceptions</span></h3>
          {!apReady && <div className="muted">loading…</div>}
          <table className="grid">
            <thead><tr><th>Invoice</th><th>Supplier</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {apExceptions.map((e, i) => (
                <tr key={i}>
                  <td>{e.invoice_num}</td>
                  <td>{e.vendor_name}</td>
                  <td>{money(e.invoice_amount)}</td>
                  <td>
                    <button className="link-btn" onClick={() =>
                      onAsk && onAsk(`Why is AP invoice ${e.invoice_num} (invoice_id ${e.invoice_id}) on hold? Use diagnose_match_exception and the knowledge base, then say whether releasing it is within policy.`)}>
                      Ask&nbsp;AI
                    </button>
                  </td>
                </tr>
              ))}
              {apReady && apExceptions.length === 0 && <tr><td colSpan="4" className="muted">{down ? "Data unavailable — service under maintenance." : "No exceptions — pipeline clear."}</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      {/* Where the cash-out is stuck */}
      <div className="card">
        <h3>Where payables are blocked <span className="muted">— by hold type</span></h3>
        {!apReady && <div className="muted">loading…</div>}
        <ResponsiveContainer width="100%" height={220}>
          <BarChart data={holds} layout="vertical" margin={{ left: 8, right: 48, top: 4, bottom: 4 }}>
            <XAxis type="number" tickFormatter={money} fontSize={11} />
            <YAxis type="category" dataKey="name" width={120} tick={{ fontSize: 11 }} interval={0} />
            <Tooltip formatter={(v) => money(v)} />
            <Bar dataKey="amount" cursor="pointer" onClick={() => onDrill && onDrill("payables")}>
              {holds.map((h, i) => (
                <Cell key={i} fill={["#d13212", "#ff9900", "#e07b00", "#8a4fff", "#0972d3"][i % 5]} />
              ))}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
