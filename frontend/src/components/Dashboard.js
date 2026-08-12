import React, { useEffect, useState } from "react";
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer } from "recharts";
import { ensureSocket, onMessage, onState, requestData } from "../socket";

function money(n) {
  if (n == null) return "-";
  return "$" + Number(n).toLocaleString(undefined, { maximumFractionDigits: 0 });
}

export default function Dashboard({ onAsk }) {
  const [risk, setRisk] = useState([]);
  const [status, setStatus] = useState("loading");

  useEffect(() => {
    const offMsg = onMessage((msg) => {
      if (msg.type === "dashboard") {
        setRisk(msg.data.risk_customers || []);
        setStatus("ready");
      } else if (msg.type === "error" && msg.code === "BACKEND_UNAVAILABLE") {
        setRisk([]);
        setStatus("unavailable");
      } else if (msg.type === "error") {
        setStatus("error: " + msg.text);
      }
    });
    const offState = onState((s) => { if (s === "closed") setStatus("offline"); });
    ensureSocket();
    requestData("dashboard");
    return () => { offMsg(); offState(); };
  }, []);

  const down = status === "unavailable";
  const totalOverdue = risk.reduce((s, r) => s + Number(r.total_overdue || 0), 0);
  const chartData = risk.slice(0, 8).map((r) => ({
    name: (r.party_name || r.account_number || "").slice(0, 18),
    overdue: Number(r.total_overdue || 0),
  }));

  return (
    <div className="dashboard">
      {down && (
        <div className="data-unavailable-note">
          Live receivables data is unavailable — the data service may be under maintenance.
          Figures are hidden rather than shown as zero.
        </div>
      )}
      <div className="kpis">
        <div className="kpi">
          <div className="kpi-label">Top-10 Overdue (sum)</div>
          <div className="kpi-value">{down ? "—" : money(totalOverdue)}</div>
        </div>
        <div className="kpi">
          <div className="kpi-label">High-risk customers</div>
          <div className="kpi-value">{down ? "—" : risk.length}</div>
        </div>
        <div className="kpi">
          <div className="kpi-label">Data source</div>
          <div className="kpi-value small">{down ? "unavailable" : "Live EBS AR (26ai)"}</div>
        </div>
      </div>

      <div className="card">
        <h3>Top overdue customers</h3>
        {status !== "ready" && <div className="muted">{status}</div>}
        <ResponsiveContainer width="100%" height={280}>
          <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 64, top: 4, bottom: 4 }}>
            <XAxis type="number" tickFormatter={money} fontSize={11} />
            <YAxis type="category" dataKey="name" width={150} tick={{ fontSize: 11 }} interval={0} />
            <Tooltip formatter={(v) => money(v)} />
            <Bar dataKey="overdue" fill="#ff9900" />
          </BarChart>
        </ResponsiveContainer>
      </div>

      <div className="card">
        <h3>Risk customers</h3>
        <table className="grid">
          <thead>
            <tr><th>Account</th><th>Customer</th><th>Overdue</th><th>Max days</th><th>Open inv.</th><th></th></tr>
          </thead>
          <tbody>
            {risk.map((r, i) => (
              <tr key={i}>
                <td>{r.account_number}</td>
                <td>{r.party_name}</td>
                <td>{money(r.total_overdue)}</td>
                <td>{r.max_days_overdue}</td>
                <td>{r.open_invoices}</td>
                <td>
                  <button className="link-btn" onClick={() =>
                    onAsk && onAsk(`For customer ${r.party_name} (account ${r.account_number}): summarise their overdue position and recommend the next collections action per our policy. If a credit hold or dunning letter is warranted, propose it (I'll approve before you act).`)}>
                    Ask&nbsp;AI
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
