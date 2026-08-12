import React, { useEffect, useRef, useState } from "react";
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell } from "recharts";
import { ensureSocket, onMessage, onState, requestData, sendPrompt } from "../socket";

function money(n) {
  if (n == null) return "-";
  const v = Number(n);
  if (Math.abs(v) >= 1e6) return "$" + (v / 1e6).toFixed(1) + "M";
  if (Math.abs(v) >= 1e3) return "$" + (v / 1e3).toFixed(0) + "k";
  return "$" + v.toLocaleString(undefined, { maximumFractionDigits: 0 });
}

// Pipeline stages in flow order. The drop between stages is the "blockage".
const STAGES = [
  { key: "received", label: "Received" },
  { key: "extracted", label: "Extracted" },
  { key: "matched", label: "Matched" },
  { key: "approved", label: "Approved" },
  { key: "scheduled", label: "Scheduled" },
  { key: "paid", label: "Paid" },
];

const HOLD_COLORS = {
  PRICE: "#d13212", "QTY REC": "#ff9900", QTY_OVER_RECEIPT: "#ff9900",
  TAX: "#8a4fff", "QTY ORD": "#e07b00", "MAX RATE": "#0972d3",
};
function holdColor(t) { return HOLD_COLORS[t] || "#687078"; }

// Map a hold type to the pipeline stage where it blocks the invoice. Match/price/qty/tax
// holds block at "matched"; funds holds at "scheduled"; approval holds at "approved".
function holdStage(ht) {
  const t = (ht || "").toUpperCase();
  if (/FUND/.test(t)) return "scheduled";
  if (/APPROV|AWAIT/.test(t)) return "approved";
  if (/QTY|PRICE|VARIANCE|TAX|AMOUNT|RATE|LINE|RECEIPT|PO|MATCH|DIST|MAX/.test(t)) return "matched";
  return "matched";
}

export default function ControlTower({ onAsk }) {
  const [data, setData] = useState(null);
  const [status, setStatus] = useState("loading");
  const [stageFilter, setStageFilter] = useState(null);
  const [holdFilter, setHoldFilter] = useState(null);
  const [diag, setDiag] = useState(null); // { invoice, text }
  const [review, setReview] = useState([]);
  const [reviewMsg, setReviewMsg] = useState(null);
  const [iface, setIface] = useState(null); // AP Open Interface status (pending + imported)
  const [ifaceOpen, setIfaceOpen] = useState(false);
  const [drag, setDrag] = useState(false);
  const [uploads, setUploads] = useState([]); // {name, state}
  const diagRef = useRef(null);
  const diagWaiting = useRef(null);
  const pendingFile = useRef(null); // file awaiting its presigned URL
  const reviewCountRef = useRef(0); // latest review-queue length (for upload polling)
  const ifaceOpenRef = useRef(false); // latest interface-panel open state (for upload polling)

  useEffect(() => {
    const offMsg = onMessage((msg) => {
      if (msg.type === "p2p_dashboard") { setData(msg.data); setStatus("ready"); }
      else if (msg.type === "error" && msg.code === "BACKEND_UNAVAILABLE") { setStatus("unavailable"); }
      else if (msg.type === "p2p_review_queue") {
        const q = msg.data.review_queue || [];
        setReview(q);
        reviewCountRef.current = q.length;
      }
      else if (msg.type === "p2p_upload_url" && pendingFile.current) {
        doUpload(msg.data.url, pendingFile.current);
        pendingFile.current = null;
      } else if (msg.type === "p2p_view_url") {
        if (msg.data && msg.data.url) window.open(msg.data.url, "_blank", "noopener");
        else setReviewMsg(msg.data?.message || "No source document available for this invoice.");
      } else if (msg.type === "p2p_approve_review") {
        const r = (msg.data && msg.data.approve) || {};
        setReviewMsg(r.message || "Approved and staged to Payables Open Interface.");
        requestData("p2p_review_queue");
      } else if (msg.type === "p2p_reject_review") {
        const r = (msg.data && msg.data.reject) || {};
        setReviewMsg(r.message || "Invoice rejected.");
        requestData("p2p_review_queue");
      } else if (msg.type === "p2p_submit_import") {
        const r = (msg.data && msg.data.import) || {};
        if (r.request_id)
          setReviewMsg(`Payables Open Interface Import (APXIIMPT) submitted — concurrent request ${r.request_id} (source ${r.source || "AI_AGENT_P2P"}, group ${r.group_id || "-"}).`);
        else
          setReviewMsg("Import submit: " + (r.message || "no request id returned"));
        // Refresh the interface view so the demo can watch rows move to imported.
        if (ifaceOpen) requestData("p2p_interface_status", { top: 25 });
      } else if (msg.type === "p2p_interface_status") {
        setIface((msg.data && msg.data.interface) || {});
      } else if (msg.type === "reply" && diagWaiting.current) {
        setDiag({ invoice: diagWaiting.current, text: msg.text });
        diagWaiting.current = null;
      } else if (msg.type === "error") setStatus("error: " + msg.text);
    });
    const offState = onState((s) => { if (s === "closed") setStatus("offline"); });
    ensureSocket();
    requestData("p2p_dashboard", { top: 30 });
    requestData("p2p_review_queue");
    return () => { offMsg(); offState(); };
  }, []);

  function setUpload(name, state) {
    setUploads((u) => {
      const others = u.filter((x) => x.name !== name);
      return [{ name, state }, ...others].slice(0, 5);
    });
  }

  // Ask the backend for a presigned PUT URL, then upload the file straight to the S3 inbox
  // (which triggers the extract Lambda → Bedrock vision → seeded Payables Open Interface).
  function startUpload(file) {
    if (!file) return;
    setUpload(file.name, "requesting");
    pendingFile.current = file;
    requestData("p2p_upload_url", { filename: file.name, content_type: file.type || "application/octet-stream" });
  }

  async function doUpload(url, file) {
    try {
      setUpload(file.name, "uploading");
      // The presigned URL is NOT signed with a Content-Type, so the PUT must send none.
      // A File/Blob body makes fetch auto-add Content-Type (→ SignatureDoesNotMatch 403),
      // so send an ArrayBuffer, which sends no Content-Type header.
      const bytes = await file.arrayBuffer();
      const res = await fetch(url, { method: "PUT", body: bytes });
      if (!res.ok) throw new Error("PUT " + res.status);
      setUpload(file.name, "processing");
      // The extract Lambda runs on the S3 trigger (Bedrock vision → stage). We don't know
      // exactly when it finishes, so silently poll the review queue + dashboard a few times
      // so a newly-ingested invoice appears on its own — no manual refresh needed.
      const startCount = reviewCountRef.current;
      let tries = 0;
      const poll = () => {
        tries += 1;
        requestData("p2p_review_queue");
        requestData("p2p_dashboard", { top: 30 });
        if (ifaceOpenRef.current) requestData("p2p_interface_status", { top: 25 });
        // Mark done once the queue grows (new row landed) or after the polling window.
        if (reviewCountRef.current > startCount) { setUpload(file.name, "done"); return; }
        if (tries >= 8) { setUpload(file.name, "done"); return; }
        setTimeout(poll, 5000); // poll ~every 5s for ~40s
      };
      setTimeout(poll, 8000); // first check ~8s after upload (extraction takes a few seconds)
    } catch (e) {
      setUpload(file.name, "failed: " + e.message);
    }
  }

  // Ask the backend for a short-lived presigned GET URL to view the original invoice
  // document (opens in a new tab). Only S3-sourced rows have a viewable file.
  function viewInvoice(r) {
    requestData("p2p_view_url", { staging_id: r.staging_id, source_uri: r.source_uri });
  }

  // Approve a reviewed invoice (optionally correcting the amount) → AP Open Interface.
  function approveInvoice(r) {
    const amt = window.prompt(
      `Approve invoice ${r.invoice_num || ""} from ${r.vendor_name || "vendor"} and send to Payables.\n` +
      `Confirm/correct the amount (blank = keep ${money(r.invoice_amount)}):`,
      r.invoice_amount != null ? String(r.invoice_amount) : "");
    if (amt === null) return; // cancelled
    setReviewMsg("Approving…");
    requestData("p2p_approve_review", {
      staging_id: r.staging_id,
      invoice_amount: amt.trim() === "" ? undefined : amt.trim(),
    });
  }

  // Reject a reviewed invoice (won't enter Payables).
  function rejectInvoice(r) {
    const reason = window.prompt(`Reject invoice ${r.invoice_num || ""}? Enter a reason:`, "");
    if (reason === null) return;
    setReviewMsg("Rejecting…");
    requestData("p2p_reject_review", { staging_id: r.staging_id, reason: reason || "Rejected in review" });
  }

  // Submit the seeded Payables Open Interface Import (APXIIMPT); returns a request id.
  function runImport() {
    setReviewMsg("Submitting Payables Open Interface Import…");
    requestData("p2p_submit_import", { org_id: 204 });
  }

  // Toggle the read-only AP Open Interface viewer (pending in interface vs imported into
  // Payables) so a demo can see what's staged and confirm a clean invoice actually imported.
  function toggleInterface() {
    const open = !ifaceOpen;
    setIfaceOpen(open);
    ifaceOpenRef.current = open;
    if (open) { setIface(null); requestData("p2p_interface_status", { top: 25 }); }
  }

  function onDrop(e) {
    e.preventDefault(); setDrag(false);
    const files = Array.from(e.dataTransfer.files || []);
    files.forEach(startUpload);
  }
  function onPick(e) {
    Array.from(e.target.files || []).forEach(startUpload);
    e.target.value = "";
  }

  function askWhy(inv) {
    const prompt = `Why is AP invoice ${inv.invoice_num} (invoice_id ${inv.invoice_id}) on hold? `
      + `Use diagnose_match_exception and the knowledge base, then give a one-paragraph `
      + `plain-English explanation and whether releasing the hold is within policy.`;
    // If the docked assistant is available, hand it there (single pane); otherwise
    // fall back to the inline diagnosis panel.
    if (onAsk) { onAsk(prompt); return; }
    diagWaiting.current = inv.invoice_num;
    setDiag({ invoice: inv.invoice_num, text: "Analyzing… (diagnose_match_exception + policy search)" });
    setTimeout(() => diagRef.current && diagRef.current.scrollIntoView({ behavior: "smooth", block: "center" }), 50);
    sendPrompt(prompt);
  }

  const pipeline = data?.pipeline || {};
  const kpis = data?.kpis || [];
  const holds = data?.holds_by_type || [];
  const aging = data?.aging || [];
  const allExceptions = data?.exceptions || [];

  // Apply the active filters to the exception queue (stage funnel + hold-type bar).
  let exceptions = allExceptions;
  if (stageFilter) exceptions = exceptions.filter((e) => holdStage(e.hold_type) === stageFilter);
  if (holdFilter) exceptions = exceptions.filter((e) => (e.hold_type || "") === holdFilter);
  const filterLabel = [stageFilter && `stage: ${stageFilter}`, holdFilter && `hold: ${holdFilter}`]
    .filter(Boolean).join(" · ");

  const maxStage = Math.max(1, ...STAGES.map((s) => Number(pipeline[s.key] || 0)));
  // Top hold types by blocked value (there can be ~15 — cap so labels stay readable).
  const holdChart = holds
    .map((h) => ({ name: h.hold_type || "OTHER", amount: Number(h.amount || 0), cnt: h.cnt }))
    .sort((a, b) => b.amount - a.amount)
    .slice(0, 8);
  const holdChartHeight = Math.max(200, holdChart.length * 34 + 40); // ~34px per bar
  const agingChart = aging.map((a) => ({ name: a.aging_bucket, amount: Number(a.total_amount || 0), order: a.bucket_order }));

  const down = status === "unavailable";

  return (
    <div className="tower">
      {down && (
        <div className="data-unavailable-note">
          Live payables data is unavailable — the data service may be under maintenance.
          Figures are hidden rather than shown as zero.
        </div>
      )}
      {/* KPI strip */}
      <div className="kpis kpis-5">
        {kpis.map((k) => (
          <div className="kpi" key={k.display_order}>
            <div className="kpi-label">{k.metric_label}</div>
            <div className="kpi-value">
              {/\bamount|value\b/i.test(k.metric_label) ? money(k.metric_value) : Number(k.metric_value).toLocaleString()}
            </div>
            <div className="kpi-sub">{k.metric_subtext}</div>
          </div>
        ))}
        {kpis.length === 0 && <div className="muted">{status}</div>}
      </div>

      {/* Pipeline funnel — the hero / blockage view */}
      <div className="card">
        <h3>Invoice pipeline <span className="muted">— click a stage to focus the queue</span></h3>
        <div className="pipeline">
          {STAGES.map((s, i) => {
            const val = Number(pipeline[s.key] || 0);
            const prev = i === 0 ? val : Number(pipeline[STAGES[i - 1].key] || 0);
            const drop = prev - val;
            const dropClass = drop <= 0 ? "" : drop > prev * 0.15 ? "drop-red" : "drop-amber";
            return (
              <React.Fragment key={s.key}>
                <button
                  className={"stage " + (stageFilter === s.key ? "stage-active " : "") + dropClass}
                  onClick={() => setStageFilter(stageFilter === s.key ? null : s.key)}
                  style={{ height: 60 + 80 * (val / maxStage) }}
                  title={`${s.label}: ${val.toLocaleString()}`}
                >
                  <span className="stage-val">{val.toLocaleString()}</span>
                  <span className="stage-label">{s.label}</span>
                </button>
                {i < STAGES.length - 1 && (
                  <div className="stage-arrow">
                    ›{drop > 0 && <span className={dropClass}>−{drop.toLocaleString()}</span>}
                  </div>
                )}
              </React.Fragment>
            );
          })}
        </div>
      </div>

      <div className="tower-grid">
        {/* Holds by type */}
        <div className="card">
          <h3>Blocked value by hold type <span className="muted">— click a bar to filter the queue</span></h3>
          <ResponsiveContainer width="100%" height={holdChartHeight}>
            <BarChart data={holdChart} layout="vertical" margin={{ left: 8, right: 48, top: 4, bottom: 4 }}>
              <XAxis type="number" tickFormatter={money} fontSize={11} />
              <YAxis type="category" dataKey="name" width={130} tick={{ fontSize: 11 }} interval={0} />
              <Tooltip formatter={(v, n) => (n === "amount" ? money(v) : v)} />
              <Bar dataKey="amount" cursor="pointer"
                   onClick={(d) => d && setHoldFilter(holdFilter === d.name ? null : d.name)}>
                {holdChart.map((h, i) => (
                  <Cell key={i} fill={holdColor(h.name)}
                        fillOpacity={holdFilter && holdFilter !== h.name ? 0.35 : 1} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>

        {/* Aging of blocked $ */}
        <div className="card">
          <h3>Payables aging</h3>
          <ResponsiveContainer width="100%" height={220}>
            <BarChart data={agingChart} margin={{ left: 16, right: 16, top: 4, bottom: 4 }}>
              <XAxis dataKey="name" fontSize={11} />
              <YAxis tickFormatter={money} width={70} tick={{ fontSize: 11 }} />
              <Tooltip formatter={(v) => money(v)} />
              <Bar dataKey="amount">
                {agingChart.map((a, i) => (
                  <Cell key={i} fill={["#1a9e5c", "#9acb3c", "#ff9900", "#e07b00", "#d13212"][a.order - 1] || "#687078"} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Exception queue — the worklist */}
      <div className="card">
        <h3>Exception queue <span className="muted">— ranked by value × age{filterLabel ? ` · ${filterLabel}` : ""}</span>
          {(stageFilter || holdFilter) && (
            <button className="link-btn" style={{ marginLeft: 10 }}
              onClick={() => { setStageFilter(null); setHoldFilter(null); }}>clear filter</button>
          )}
        </h3>
        {status !== "ready" && <div className="muted">{status}</div>}
        <div className="muted" style={{ marginBottom: 6 }}>
          Showing {exceptions.length} of {allExceptions.length} loaded (top by priority).
        </div>
        <table className="grid">
          <thead>
            <tr>
              <th>Invoice</th><th>Supplier</th><th>Amount</th><th>Hold</th>
              <th>Age</th><th>Reason</th><th></th>
            </tr>
          </thead>
          <tbody>
            {exceptions.map((e, i) => (
              <tr key={i}>
                <td>{e.invoice_num}</td>
                <td>{e.vendor_name}</td>
                <td>{money(e.invoice_amount)}</td>
                <td>
                  <span className="badge" style={{ background: holdColor(e.hold_type) }}>{e.hold_type}</span>
                  {Number(e.hold_count) > 1 && (
                    <span className="hold-count" title={`${e.hold_count} active holds on this invoice`}>
                      ×{e.hold_count}
                    </span>
                  )}
                </td>
                <td>{e.hold_age_days}d</td>
                <td className="reason">{e.exception_reason}</td>
                <td><button className="link-btn" onClick={() => askWhy(e)}>Why?</button></td>
              </tr>
            ))}
            {exceptions.length === 0 && status === "ready" && (
              <tr><td colSpan="7" className="muted">No exceptions — pipeline is clear.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Invoice intake — drag & drop into the S3 inbox → Bedrock vision → seeded interface */}
      <div className="card">
        <h3>Ingest an invoice <span className="muted">— drop a PDF/PNG; AI extracts it and stages to Payables (or routes low-confidence to review)</span></h3>
        <div
          className={"dropzone " + (drag ? "dropzone-over" : "")}
          onDragOver={(e) => { e.preventDefault(); setDrag(true); }}
          onDragLeave={() => setDrag(false)}
          onDrop={onDrop}
          onClick={() => document.getElementById("invoice-file-input").click()}
        >
          <div className="dropzone-icon">⬆</div>
          <div><b>Drag &amp; drop an invoice here</b> or click to choose a file</div>
          <div className="muted">PDF, PNG or JPG — extracted by Bedrock vision, then staged via the seeded Payables Open Interface.</div>
          <input id="invoice-file-input" type="file" accept=".pdf,.png,.jpg,.jpeg,image/*,application/pdf"
                 multiple style={{ display: "none" }} onChange={onPick} />
        </div>
        {uploads.length > 0 && (
          <ul className="upload-list">
            {uploads.map((u, i) => (
              <li key={i}>
                <span className="upl-name">{u.name}</span>
                <span className={"upl-state upl-" + (u.state.startsWith("failed") ? "failed" : u.state)}>
                  {u.state === "requesting" && "preparing…"}
                  {u.state === "uploading" && "uploading…"}
                  {u.state === "processing" && "extracting (AI)…"}
                  {u.state === "done" && "✓ processed — check the queue below"}
                  {u.state.startsWith("failed") && u.state}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* Invoice ingest — human review queue (low-confidence extractions) */}
      <div className="card">
        <div className="row-between">
          <h3>Invoice review queue <span className="muted">— AI-ingested invoices below the confidence threshold (human-in-the-loop)</span></h3>
          <div style={{ display: "flex", gap: 8 }}>
            <button className="btn-secondary" onClick={toggleInterface}
                    title="View the Payables Open Interface: what's staged (pending) and what has imported into Payables">
              {ifaceOpen ? "Hide interface" : "View interface"}
            </button>
            <button className="btn-primary" onClick={runImport}
                    title="Submit the seeded Payables Open Interface Import (APXIIMPT) for approved invoices">
              Run Payables import
            </button>
          </div>
        </div>
        {reviewMsg && <div className="review-msg">{reviewMsg}</div>}

        {ifaceOpen && (
          <div className="iface-panel">
            {!iface && <div className="muted">Loading interface…</div>}
            {iface && iface.status === "error" && (
              <div className="data-unavailable-note">Interface read failed: {iface.message}</div>
            )}
            {iface && iface.status !== "error" && (
              <>
                <div className="iface-stats">
                  <span className="iface-pill iface-pending">{iface.pending_count ?? 0} pending in interface</span>
                  {Number(iface.rejected_count) > 0 &&
                    <span className="iface-pill iface-rejected">{iface.rejected_count} rejected</span>}
                  <span className="iface-pill iface-imported">{iface.imported_count ?? 0} imported to Payables</span>
                  <button className="link-btn" style={{ marginLeft: 6 }}
                          onClick={() => requestData("p2p_interface_status", { top: 25 })}>refresh</button>
                </div>
                <div className="tower-grid" style={{ marginTop: 10 }}>
                  <div>
                    <h4 style={{ margin: "4px 0" }}>Pending — AP_INVOICES_INTERFACE
                      <span className="muted"> (source AI_AGENT_P2P)</span></h4>
                    <table className="grid">
                      <thead><tr><th>Invoice</th><th>Vendor</th><th>Amount</th><th>Status</th></tr></thead>
                      <tbody>
                        {(iface.pending || []).map((r, i) => (
                          <tr key={i}>
                            <td>{r.invoice_num}</td>
                            <td>{r.vendor_name}</td>
                            <td>{money(r.invoice_amount)}</td>
                            <td><span className="badge" style={{ background: r.status === "REJECTED" ? "#d13212" : "#e07b00" }}>{r.status}</span></td>
                          </tr>
                        ))}
                        {(iface.pending || []).length === 0 &&
                          <tr><td colSpan="4" className="muted">Interface is empty — nothing staged.</td></tr>}
                      </tbody>
                    </table>
                  </div>
                  <div>
                    <h4 style={{ margin: "4px 0" }}>Imported — AP_INVOICES_ALL
                      <span className="muted"> (landed in Payables)</span></h4>
                    <table className="grid">
                      <thead><tr><th>Invoice</th><th>Amount</th><th>Date</th><th>Status</th></tr></thead>
                      <tbody>
                        {(iface.imported || []).map((r, i) => (
                          <tr key={i}>
                            <td>{r.invoice_num}</td>
                            <td>{money(r.invoice_amount)}</td>
                            <td>{r.invoice_date}</td>
                            <td><span className="badge" style={{ background: "#1a9e5c" }}>{r.status}</span></td>
                          </tr>
                        ))}
                        {(iface.imported || []).length === 0 &&
                          <tr><td colSpan="4" className="muted">None imported yet — run the import.</td></tr>}
                      </tbody>
                    </table>
                  </div>
                </div>
                <div className="muted" style={{ marginTop: 6, fontSize: 12 }}>
                  Approve stages a row into AP_INVOICES_INTERFACE (pending). "Run Payables import"
                  submits APXIIMPT, which validates and moves rows into AP_INVOICES_ALL (imported).
                </div>
              </>
            )}
          </div>
        )}
        {review.length === 0 ? (
          <div className="muted">No invoices awaiting review.</div>
        ) : (
          <table className="grid">
            <thead>
              <tr><th>Vendor</th><th>Invoice #</th><th>Amount</th><th>Confidence</th><th>Why review</th><th>Document</th><th>Decision</th></tr>
            </thead>
            <tbody>
              {review.map((r, i) => (
                <tr key={i}>
                  <td>{r.vendor_name}</td>
                  <td>{r.invoice_num}</td>
                  <td>{money(r.invoice_amount)}</td>
                  <td><span className="badge" style={{ background: Number(r.confidence) < 0.5 ? "#d13212" : "#e07b00" }}>
                    {(Number(r.confidence) * 100).toFixed(0)}%</span></td>
                  <td className="why-review">{r.review_reason || "Below auto-post threshold"}</td>
                  <td>
                    {(r.source_uri || "").startsWith("s3://")
                      ? <button className="link-btn" onClick={() => viewInvoice(r)}>View invoice</button>
                      : <span className="muted">no file</span>}
                  </td>
                  <td className="decision-cell">
                    <button className="btn-approve" onClick={() => approveInvoice(r)}>Approve</button>
                    <button className="btn-reject" onClick={() => rejectInvoice(r)}>Reject</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <div className="muted" style={{ marginTop: 8, fontSize: 12 }}>
          Approve stages the invoice to the seeded AP Open Interface (AP_INVOICES_INTERFACE);
          "Run Payables import" submits the seeded APXIIMPT concurrent program and returns its request id.
        </div>
      </div>

      {/* Agent diagnosis panel */}
      {diag && (
        <div className="card diag" ref={diagRef}>
          <h3>AI diagnosis · invoice {diag.invoice}
            <button className="link-btn close" onClick={() => setDiag(null)}>close</button></h3>
          <div className="diag-text">{diag.text}</div>
        </div>
      )}
    </div>
  );
}
