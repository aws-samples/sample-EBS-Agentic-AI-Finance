import React, { useEffect, useState } from "react";
import { ensureSocket, onMessage, requestData } from "../socket";
import Markdown from "./Markdown";

// Policy library — surfaces the human-readable collections/AP policy, SOP and template
// documents that the agent reasons over. These are read from the SAME Oracle 26ai
// knowledge-base vector store (COLLECTIONS_KNOWLEDGE_BASE) that backs the agent's
// search_knowledge_base tool, so what a user reads here is exactly what the agent cites
// when it says "within policy". Read-only.
//
// Why this matters: EBS stores the ENFORCEMENT of policy (Payables tolerance templates,
// hold codes, dunning config) — not the narrative "why/who-approves" document. That
// narrative normally lives outside EBS; here it lives in the vector store, and this view
// makes it verifiable in one click for anyone approving an AI-recommended action.

const TYPE_LABELS = {
  policy: "Policy",
  sop: "SOP",
  template: "Template",
  correspondence: "Correspondence",
  faq: "FAQ",
};

function docSource(d) {
  try {
    const m = typeof d.metadata === "string" ? JSON.parse(d.metadata) : d.metadata;
    return (m && m.source) || "";
  } catch { return ""; }
}

function docTitle(d) {
  // The summary is the most distinct, human-readable label per row (rows can share a
  // source document, e.g. one policy PDF with several sections). Prefer it; fall back to
  // a cleaned-up source filename, then the id.
  if (d.summary && d.summary.trim()) return d.summary.trim().slice(0, 70);
  const src = docSource(d);
  if (src) {
    return src.replace(/\.(md|txt|pdf)$/i, "").replace(/[_-]+/g, " ")
      .replace(/\b\w/g, (c) => c.toUpperCase());
  }
  return `Document ${d.id}`;
}

export default function PolicyLibrary() {
  const [docs, setDocs] = useState(null);
  const [selected, setSelected] = useState(null); // full document (with content)
  const [loadingDoc, setLoadingDoc] = useState(false);
  const [down, setDown] = useState(false);
  const [recon, setRecon] = useState(null); // tolerance reconciliation result
  const [syncing, setSyncing] = useState(false);
  const [syncMsg, setSyncMsg] = useState(null); // { ok, text }

  useEffect(() => {
    const off = onMessage((msg) => {
      if (msg.type === "policy_docs") {
        const d = msg.data || {};
        if (d.document !== undefined) {
          // single-doc response (viewer pane)
          setSelected(d.document || null);
          setLoadingDoc(false);
        } else {
          setDocs(d.documents || []);
          setDown(false);
        }
      } else if (msg.type === "policy_recon") {
        setRecon(msg.data || {});
      } else if (msg.type === "policy_sync") {
        const r = msg.data || {};
        const ok = r.status === "synced" || r.status === "in_sync";
        setSyncMsg({ ok, text: r.message || "Sync complete." });
        setSyncing(false);
        // Refresh the reconciliation so the table reflects the new (in-sync) state.
        requestData("policy_recon");
      } else if (msg.type === "error" && msg.code === "BACKEND_UNAVAILABLE") {
        setDown(true);
        if (docs === null) setDocs([]);
      } else if (msg.type === "error" && syncing) {
        // A denied/failed sync comes back as a generic error while we're waiting on one.
        setSyncMsg({ ok: false, text: msg.text || "Sync failed." });
        setSyncing(false);
      }
    });
    ensureSocket();
    requestData("policy_docs");
    requestData("policy_recon");
    return off;
  }, []);

  // Reconcile the documented policy-of-record to the tolerance EBS actually enforces.
  // One-way and safe: this updates ONLY the app's stored policy value, never EBS config.
  function syncFromEbs() {
    if (syncing) return;
    const enforced = recon && recon.rows && recon.rows[0]
      ? recon.rows[0].enforced_price_pct : null;
    const policy = recon ? recon.policy_price_pct : null;
    const ok = window.confirm(
      "Sync the documented policy from E-Business Suite?\n\n" +
      "This updates the app's price-variance policy of record" +
      (policy != null && enforced != null ? ` from ${policy}% to ${enforced}%` : "") +
      " so it matches the tolerance Payables actually enforces.\n\n" +
      "It changes only the policy document value in this app — it does NOT change any " +
      "EBS configuration. EBS stays the system of record."
    );
    if (!ok) return;
    setSyncing(true);
    setSyncMsg(null);
    requestData("policy_sync", {});
  }

  function openDoc(d) {
    setSelected({ ...d, content: null }); // show title immediately
    setLoadingDoc(true);
    requestData("policy_docs", { doc_id: d.id });
  }

  // Group docs by type for a tidy list.
  const groups = {};
  (docs || []).forEach((d) => {
    const t = d.doc_type || "other";
    (groups[t] = groups[t] || []).push(d);
  });
  const order = ["policy", "sop", "template", "correspondence", "faq"];
  const groupKeys = Object.keys(groups).sort(
    (a, b) => (order.indexOf(a) + 1 || 99) - (order.indexOf(b) + 1 || 99)
  );

  const contentText = selected && (
    typeof selected.content === "object" && selected.content !== null && "read" in selected.content
      ? "" : selected.content
  );

  return (
    <div className="policy-lib">
      <div className="overview-head">
        <div>
          <h2>Policy library</h2>
          <div className="muted">
            The operating policies, SOPs and letter templates the assistant reasons over —
            read from the live Oracle 26ai knowledge base. This is the "policy of record"
            behind every <b>within policy</b> / <b>needs review</b> decision.
          </div>
        </div>
      </div>

      <div className="policy-note muted">
        Note: EBS enforces the numeric rules (Payables invoice tolerances, hold codes,
        dunning configuration). These documents are the human-readable policy that explains
        and governs those rules; where a value is enforced in EBS it is called out in the text.
        <span className="info-badge" tabIndex={0}
          aria-label="Why policy lives here and not in EBS">
          i
          <span className="info-pop" role="tooltip">
            <b>Why does policy live here, not in EBS?</b>
            EBS stores the <b>settings that block a payment</b> — tolerance limits, hold
            codes, dunning steps — as numbers it enforces automatically. It does not store
            the written policy that explains <i>why</i> a rule exists or <i>who</i> can
            approve an exception. That document normally lives outside EBS (SharePoint, a PDF).
            Here it lives in the AI knowledge base — the same source the assistant reads — so
            the reason behind every decision is one click away.
          </span>
        </span>
      </div>

      {down && (
        <div className="data-unavailable-note">
          Policy documents are unavailable right now — the data service may be under maintenance.
        </div>
      )}

      {/* Live reconciliation: narrative policy vs the tolerance EBS actually enforces. */}
      {recon && recon.rows && recon.rows.length > 0 && (
        <div className="card recon-card">
          <div className="row-between">
            <h3 style={{ margin: 0 }}>
              Policy vs. live EBS enforcement <span className="muted">— price-variance tolerance</span>
              {recon.drift_count > 0
                ? <span className="recon-pill recon-pill-drift">{recon.drift_count} drifting</span>
                : <span className="recon-pill recon-pill-sync">all in sync</span>}
            </h3>
            <button
              className="btn-primary"
              onClick={syncFromEbs}
              disabled={syncing || recon.drift_count === 0}
              title={recon.drift_count === 0
                ? "Already in sync with EBS — nothing to reconcile."
                : "Update the documented policy of record to match the tolerance EBS enforces (does not change EBS)."}
            >
              {syncing ? "Syncing…" : "Sync from EBS"}
            </button>
          </div>
          <div className="muted" style={{ marginBottom: 10, marginTop: 8 }}>
            The written <b>policy of record</b> is <b>{recon.policy_price_pct}%</b>. The table shows
            what Payables actually enforces for your operating unit (live from EBS). <b>In sync</b>
            means the document matches the system; <b>DRIFT</b> means they differ and one should be
            reconciled. <b>Sync from EBS</b> updates the documented policy in this app to match what
            Payables enforces — it never changes EBS configuration.
          </div>
          {syncMsg && (
            <div className={syncMsg.ok ? "review-msg" : "data-unavailable-note"}
                 style={{ marginBottom: 10 }}>
              {syncMsg.text}
            </div>
          )}
          <table className="grid">
            <thead>
              <tr><th>Operating unit</th><th>Policy %</th><th>EBS enforces %</th><th>Status</th></tr>
            </thead>
            <tbody>
              {recon.rows.slice(0, 12).map((r, i) => (
                <tr key={i} className={r.recon_status === "DRIFT" ? "recon-drift" : ""}>
                  <td>{r.operating_unit}</td>
                  <td>{r.policy_price_pct}%</td>
                  <td>{r.enforced_price_pct == null ? "—" : r.enforced_price_pct + "%"}</td>
                  <td>
                    {r.recon_status === "DRIFT" &&
                      <span className="badge" style={{ background: "#c0392b" }}>DRIFT</span>}
                    {r.recon_status === "IN_SYNC" &&
                      <span className="badge" style={{ background: "#1a9e5c" }}>in sync</span>}
                    {r.recon_status === "UNKNOWN" &&
                      <span className="badge" style={{ background: "#7a8794" }}>no template</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="policy-grid">
        <div className="policy-list card">
          {!docs && <div className="muted">loading…</div>}
          {docs && docs.length === 0 && !down && (
            <div className="muted">No policy documents found in the knowledge base.</div>
          )}
          {groupKeys.map((t) => (
            <div key={t} className="policy-group">
              <div className="policy-group-label">{TYPE_LABELS[t] || t}</div>
              {groups[t].map((d) => (
                <button
                  key={d.id}
                  className={"policy-item" + (selected && selected.id === d.id ? " active" : "")}
                  onClick={() => openDoc(d)}
                >
                  <div className="policy-item-title">{docTitle(d)}</div>
                  {docSource(d) && <div className="policy-item-sub">source: {docSource(d)}</div>}
                </button>
              ))}
            </div>
          ))}
        </div>

        <div className="policy-viewer card">
          {!selected && <div className="muted">Select a document to read it.</div>}
          {selected && (
            <>
              <div className="policy-viewer-head">
                <span className="badge" style={{ background: "#5b6b7a" }}>
                  {TYPE_LABELS[selected.doc_type] || selected.doc_type}
                </span>
                <h3>{docTitle(selected)}</h3>
                <div className="muted">
                  {docSource(selected) && <>Source: {docSource(selected)} · </>}
                  {selected.updated_at && <>Last updated {selected.updated_at}</>}
                </div>
              </div>
              {loadingDoc && <div className="muted">loading document…</div>}
              {!loadingDoc && contentText && <Markdown text={contentText} />}
              {!loadingDoc && !contentText && (
                <div className="muted">No content available for this document.</div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
