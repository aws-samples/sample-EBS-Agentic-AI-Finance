---
title: "EBS Finance Assistant"
subtitle: "User Guide, Business Case & Demo Walkthrough"
date: "Oracle 26ai · AR + P2P"
---

# Overview

| | |
|---|---|
| **Application** | EBS Finance Assistant (Oracle 26ai) |
| **URL** | Use the `CloudFrontURL` output from your deployment |
| **Login** | Use an account and password provisioned for your deployment (see the repository README) |
| **Region / Account** | Your configured AWS Region and account |
| **Data source** | Live Oracle E-Business Suite 12.2 (AR + AP/PO/RCV) on Oracle Database 26ai — no replication, no data warehouse |

This one guide covers the **whole system**: the business problem, the value proposition, every part
of the UI (Collections / cash flow, AP Control Tower, and Ask AI with Code-Interpreter charts), and
end-to-end **test cases** you can run to learn what it does.

---

## 1. The business problem we're solving

Finance teams running Oracle EBS sit on rich data but interact with it through slow, rigid channels:

- **Analytics** typically runs against a separate reporting layer that's refreshed on a schedule, so
  answers reflect the last load and each new question is a fresh report request.
- **Collections (AR)** and **payables exceptions (AP)** are judgement-heavy queues that pile up:
  chasing overdue customers, and unblocking invoices stuck on price/quantity/tax holds.
- **RPA bots** (e.g. a UiPath P2P bot) automate the *keystrokes* of clean cases but hand every
  exception to a human and break whenever a screen changes.

The result: throughput is capped by human exception-handling, insight is delayed, and the tooling is
brittle and expensive.

## 2. What this solution is (the narrative)

**An AI assistant that sits directly on live EBS and both *answers* and *acts*.** It:

- Replaces the Redshift/Zero-ETL data-movement pattern with **Oracle 26ai native AI** (natural-language querying + in-database vector search).
- Adds an **agent** (Amazon Bedrock, Strands SDK) that reasons over the data and takes governed actions through **seeded EBS APIs**.

One conversational surface spans two finance functions:

- **Collections (AR)** — cash position, aging, risk, and collections actions (credit holds, notes,
  dunning) — the "cash flow" side.
- **AP Control Tower (P2P)** — invoice pipeline, exception diagnosis, AI invoice ingest, and
  payables actions — the payables side.
## 3. Value proposition

| Dimension | Before | With EBS Finance Assistant |
|---|---|---|
| Analytics latency | scheduled load to a reporting layer | **live** in-DB NL→SQL, no load lag |
| Cost | separate warehouse + replication (~$3k/mo) | not required here (~$2,950/mo) — uses the DB you already own |
| Exceptions | humans clear the queue | agent **reasons** about each exception + proposes/executes a fix |
| Invoice entry | manual keying / brittle RPA | AI extraction → seeded Payables Open Interface, confidence-gated |
| Robustness | RPA breaks on screen change | **API/PL-SQL** integration — no bot to maintain |
| Security | app-tier only | **row-level security in the database kernel** (VPD) |
| Licensing | SOA Suite / extra tooling | **seeded EBS** (core Payables/Receivables), no extra licence |
| Governance | varies | every write goes through **audited** EBS APIs; risky actions gated |

**One-line pitch:** *Ask your EBS anything and let it act — live, governed, and secured in the
database — instead of exporting data and babysitting bots.*

---

## 4. Architecture in one picture

![Figure 1 — EBS Finance Assistant architecture topology (Oracle 26ai)](architecture-26ai-topology.png)

**Data flow (numbered):**

1. **Browser** (React on CloudFront + S3, Cognito auth) → **API Gateway WebSocket** → **WebSocket handler λ**.
2. `dashboard` / `p2p_*` actions → **Collections λ** / **P2P λ** → live EBS reporting views via oracledb.
3. `sendMessage` → **Agent runtime** (Strands + Bedrock Claude) → tools: NL→SQL, vector RAG, write-back, invoice ingest, chart generation.
4. **S3 invoice inbox** → **Invoice Extract λ** (Bedrock vision) → seeded Payables Open Interface, or the human review queue.
5. **Oracle 26ai** (PDB ERPUAT): reporting views, in-DB ONNX vectors, VPD row security, audited APPS packages → seeded EBS public APIs.
6. **EBS 12.2 app tier** exposes ISG REST for audited write-back.
7. **Agent host** — the live WebSocket chat runs on the **AgentCore Runtime** (container,
   VPC-attached) with the **SQLcl 25.2 MCP server**.
   - So the browser Assistant can list connections, connect, and run governed SQL.

---

## 5. The system, component by component — what each part is & how it works

The platform is a **single pane of glass**: one **Overview** home that unifies receivables (cash-in)
and payables (cash-out), two drill-down views, and an **AI Assistant docked on every screen**. It is
built from eleven components across four layers (UI · agent · data · security). Each row below says
**what it is** and **how it works**; Section 6 has a runnable test for every one.

| # | Component | Layer | What it is | How it works |
|---|---|---|---|---|
| C0 | Working-Capital Overview | UI | Single-pane home: cash-in vs cash-out balance, unified KPIs, "collect first" + "unblock next" worklists | One shared WebSocket requests `dashboard` + `p2p_dashboard`; tiles/rows drill down or hand a prompt to the docked assistant |
| C1 | Collections dashboard | UI | AR "cash flow" drill-down: KPI cards, top-overdue chart, risk table | React → WebSocket `dashboard` → Collections λ → deterministic `XX_COLL_*_V` views on live EBS AR (oracledb) |
| C2 | AP Control Tower | UI | P2P drill-down: KPI strip, pipeline funnel, holds/aging charts, exception + review queues | React → WebSocket `p2p_*` → P2P λ → `XX_P2P_*_V` views on live EBS AP/PO/RCV |
| C3 | AI Assistant (docked) | UI/agent | Persistent right-hand chat on every screen; answers and acts | Shared socket → agent (Strands + Bedrock Claude) picks tools, replies; rows push prompts into it via `onAsk` |
| C4 | NL→SQL analytics | agent tool | Natural-language questions over live EBS | `execute_oracle_ai_query`: Bedrock generates a guard-railed single SELECT over the COLLECTIONS_AI views, executed via oracledb |
| C5 | Knowledge base (RAG) | agent tool | Semantic policy/SOP/template lookup | `search_knowledge_base` → in-DB ONNX `all_MiniLM_L12_v2` (384-dim) COSINE vector search, no egress |
| C6 | Code-Interpreter charts | agent tool | Chart drawing from plain English | `generate_chart` runs matplotlib in the Bedrock AgentCore Code Interpreter sandbox; PNG rendered inline in the dock |
| C7 | Collections write-back | agent tool | Audited AR actions | `execute_collections_action` → **ISG REST → seeded EBS public APIs** (HZ/JTF/OE): holds, notes, dunning, reminders |
| C8 | AP exception + actions | agent tool | Diagnose holds; gated payables actions | `get_invoice_exceptions` / `diagnose_match_exception` / `execute_p2p_action` → `APPS.XX_P2P_AP_PKG` (seeded `AP_HOLDS_PKG`) |
| C9 | AI invoice ingest | agent + λ | Document → structured invoice → EBS | S3 inbox → Extract λ (Bedrock vision) → `XX_P2P_INGEST_PKG` → seeded Payables Open Interface; confidence-gated + review queue |
| C9a | Invoice review actions | UI + λ | Human approve/reject + run import from the review queue | `p2p_approve_review`/`p2p_reject_review`/`p2p_submit_import` → `XX_P2P_INGEST_PKG` (approve→AP interface, reject→REJECTED, submit→APXIIMPT returns a concurrent request id) |
| C10 | VPD row security | data/security | Row-level org scoping in the DB kernel | `XX_P2P_SEC_PKG` + `DBMS_RLS` policy adds an org_id predicate the LLM cannot bypass |
| C11 | Working-capital what-if | agent + λ + UI | Projects cash/DSO/DPO if you collect top-N AR + release in-tolerance holds | `XX_WORKING_CAPITAL_PKG.SIMULATE` → `simulate_working_capital` tool / `p2p_simulate` / Overview panel |
| C12 | Agent action plan | agent + λ + UI | Ranked highest-value AR+AP moves with within-policy flag | `XX_WORKING_CAPITAL_PKG.ACTION_PLAN` → `get_action_plan` / `p2p_action_plan` / Overview table |
| C13 | Payment prediction | agent + λ | Predicts who pays late (avg days late, risk band) from paid history | `XX_WORKING_CAPITAL_PKG.PREDICT_PAYMENT` → `predict_customer_payment` / `p2p_predict` |
| C14 | Duplicate/fraud check | agent + λ | Flags duplicate / near-dup / outlier invoices before ingest | `XX_P2P_ANOMALY_PKG.CHECK_INVOICE` → `check_invoice_anomaly`; wired into the extract Lambda |
| C15 | Policy library + drift check + sync | UI + λ | Read the policies the agent cites; live "policy vs. EBS enforcement" reconciliation; one-click reconcile of a drift (AP-manager gated) | `policy_docs` → `get_policy_documents` reads the SAME `COLLECTIONS_KNOWLEDGE_BASE` the agent uses; `policy_recon` → `get_tolerance_reconciliation` over `XX_P2P_TOLERANCE_RECON_V` flags tolerance drift; `policy_sync` → `sync_policy_tolerance` updates the app-owned `XX_POLICY_SETTINGS` policy-of-record to match EBS (never writes EBS) |

**Navigation:** the top bar has four tabs — **Overview** (home), **Collections**, **AP Control
Tower**, **Policy** — and the **AI Assistant is docked on the right of all of them** (click the
vertical **AI** tab to expand/collapse). One WebSocket connection is shared across every view and the dock.

**Where the agent runs (two interchangeable hosts, same `agent_strands.py`):**

- **AgentCore Runtime** (`ebs_collections_agent_26ai-WUMDbr71r7`) — **the live host for the UI chat**:
  containerized, VPC-attached, with the **SQLcl 25.2 MCP server** bundled (`USE_SQLCL_MCP=1`). The
  WebSocket handler calls it via `InvokeAgentRuntime`, so the browser Assistant has the governed SQLcl
  tools (`connections_list` → `connect` → `sql_run`) alongside every other tool. Those run under the
  COLLECTIONS_AI connection's own grants and never bypass the audited write-back path.

### 5.0 Working-Capital Overview (C0) — the single pane of glass

![Figure 2 — Working-Capital Overview, annotated. (1) Cash-IN vs Cash-OUT tiles drill into AR/AP; (2) agent-ranked action plan with within-policy tags and Act-with-AI; (3) the docked AI Assistant, on every screen, remembers context and renders charts inline.](assets/ui-overview-annotated.png)

The home screen. It shows the whole cash cycle at once:

- **Cash-in vs cash-out balance** — a green "CASH IN · Receivables" panel (overdue $) and a red
  "CASH OUT · Payables" panel (blocked $), with a "cash cycle" divider. Click either to drill down.
- **Unified KPI strip** — overdue receivables, blocked payables, invoices on hold, awaiting approval.
- **"Collect first"** — top overdue customers, each with an **Ask AI** button.
- **"Unblock next"** — top payables exceptions, each with an **Ask AI** button.
- **Recommended action plan (C12)** — a ranked table of the highest-value next moves across AR + AP,
  each tagged **within policy** or **needs review**, with an **Act with AI** button that hands the
  move to the docked assistant (execution stays gated behind your approval).
- **Working-capital what-if (C11)** — a purple panel with a **Run simulation** button; projects the
  cash / DSO / DPO impact of collecting the top overdue + releasing in-tolerance holds (projection
  only, no action taken).
- **"Where payables are blocked"** — blocked value by hold type.

Every **Ask AI** / **Act with AI** button opens the docked assistant pre-loaded with a
context-specific question, so you go from *seeing* a number to *acting* on it without leaving the pane.

### 5.1 Collections dashboard (C1)

- **KPI cards** — top-10 overdue (sum), high-risk customer count, data-source note.
- **Top overdue customers** — horizontal bar chart (recharts) of the biggest overdue balances.
- **Risk customers table** — account, customer, overdue amount, max days overdue, open invoices, **Ask AI**.

### 5.2 AP Control Tower (C2)

![Figure 3 — AP Control Tower, annotated. (1) The invoice pipeline funnel is the "blockage" view; (2) the exception queue is the worklist — "Why?" runs a read-only, audited diagnosis that reconciles invoice vs PO vs goods-receipt inside Oracle, checks your tolerance policy, and gives a within-/outside-policy verdict (a human still approves any release); (3) drag-and-drop invoice ingest → Bedrock vision → seeded Payables Open Interface, with a human-in-the-loop review queue.](assets/ui-control-tower-annotated.png)

1. **KPI strip** — invoices in flight, on hold, $ blocked, awaiting approval, unpaid value.
2. **Invoice pipeline funnel** — Received → Extracted → Matched → Approved → Scheduled → Paid. The
   number between blocks is the **drop** (the blockage); amber/red flags large drops.
   *Click a stage* to filter the exception queue to invoices blocked there.
3. **Blocked value by hold type** — bar chart by EBS hold code. *Click a bar* to filter the queue.
4. **Payables aging** — open payables by age bucket (green→red).
5. **Exception queue** — held/mismatched invoices ranked by **value × age**. Each row has a
   **Why?** button → AI diagnosis (opens in the docked assistant). **What "Why?" actually does is
   read-only and audited:** the agent calls `diagnose_match_exception`, which runs an audited Oracle
   package (`APPS.XX_P2P_AP_PKG.DIAGNOSE_MATCH_EXCEPTION`) that reconciles three sources of truth for
   each invoice line — the **invoice** (what the vendor billed), the **purchase order** (what you
   agreed to buy), and the **goods receipt** (what actually arrived) — and classifies the mismatch as
   `PRICE_VARIANCE` (billed price above the PO), `QTY_OVER_RECEIPT` (billed more than was received —
   the 3-way check), `QTY_OVER_ORDER` (billed more than ordered), or `NO_PO_MATCH` (no PO at all). It
   then does an in-database vector search of your written **tolerance policy** and returns one
   plain-English paragraph with a **within-policy / outside-policy** verdict. No hold is touched —
   releasing is a separate, RBAC-gated action that still requires a human's explicit approval.
6. **Ingest an invoice (drag-and-drop)** — drop a PDF/PNG (or click to choose). The file uploads
   straight to the S3 invoice inbox via a short-lived presigned URL, which triggers **Bedrock vision**
   extraction → confidence gate → **staged** to the seeded Payables Open Interface (clear) or routed
   to the review queue (low-confidence). A per-file status shows *uploading → extracting (AI) → ✓
   processed*, then the review queue refreshes.
7. **Invoice review queue** — AI-ingested invoices with **confidence < 0.80**, held for a human.
   Each row shows the vendor, invoice #, amount, a confidence badge, a **Why review** rationale
   (the vision model's reason — e.g. "blurred scan — totals illegible" — plus any duplicate/anomaly
   flag), a **View invoice** link (opens the original document via a short-lived presigned URL), and
   a **Decision** cell:
   - **Approve** — optionally correct the amount, then push the invoice to the seeded
     `AP_INVOICES_INTERFACE` (Payables Open Interface) via `XX_P2P_INGEST_PKG.approve_staged`.
   - **Reject** — mark it REJECTED with a reason so it never enters Payables.
   A **Run Payables import** button submits the seeded **APXIIMPT** (Payables Open Interface Import)
   concurrent program and reports the returned **concurrent request id** in the status banner.

**Is drag-and-drop realistic for an enterprise?** Yes — as a *secondary* channel, not the bulk path.

- In production, high-volume invoices arrive **automatically**: structured suppliers via **XML Gateway / EDI / iSupplier** go straight into the Payables Open Interface (no OCR needed), and PDF/scanned invoices arrive via an **email-to-capture** mailbox (e.g. `invoices@example.com` → auto-extraction).
- The same backend pipeline here (S3 inbox → Bedrock vision → seeded interface) is exactly what an email flow (SES→S3) would feed.
- Manual **drag-and-drop is the "long tail" channel** every capture product ships — for one-off supplier PDFs, a scan a clerk received directly, or a corrected/re-submitted invoice.
- It's also how we make the AI-extraction pipeline visible in a demo without standing up email/DNS.

*(The key point for a demo: everything behind the **Why?** button is **read-only and audited**. The
agent explains the hold by reconciling invoice vs PO vs goods receipt inside Oracle, checks it against
your written tolerance policy, and gives a within-policy / outside-policy verdict — but a human still
has to approve the actual release. Under the hood it runs `diagnose_match_exception` + policy RAG;
nothing is changed just by asking "Why?".)*

### How invoices arrive in the real world (intake channels)

| Channel | Format | Path | Where it fits |
|---|---|---|---|
| **XML Gateway / EDI (e-Commerce Gateway)** | structured XML / EDI 810 | straight into the Payables Open Interface — **no OCR** | high-volume, EDI-capable suppliers |
| **iSupplier Portal** | keyed / uploaded | supplier submits → AP interface | suppliers on the portal |
| **Email-to-capture** (e.g. SES→S3) | PDF / scan | mailbox → S3 inbox → Bedrock vision → seeded interface | the **bulk unstructured** path (most PDFs) |
| **Drag-and-drop (this app)** | PDF / scan | browser → S3 inbox → Bedrock vision → seeded interface | the **long tail**: one-offs, re-submits, ad-hoc |

The AI-extraction pipeline in this app is the **capture step for unstructured invoices** (PDFs, scans, emails) — historically manual keying or products like Oracle Forms Recognition / Kofax / ABBYY. Key points:

- Structured EDI/XML suppliers bypass extraction entirely and go straight to the interface, so this **complements** XML Gateway rather than replacing it.
- In production, email-to-capture handles volume and drag-and-drop handles exceptions.
- Both feed the *same* seeded Payables Open Interface.

### 5.3 AI Assistant — docked on every screen (C3)

A persistent chat panel on the right of every tab (click the vertical **AI** tab to expand/collapse).
Type a question or instruction, or click any **Ask AI** / **Why?** button in the Overview / dashboards
to send a context-specific prompt into it. The agent decides which tools (C4–C9) to call and replies
in place — all without leaving the current view. It can:

- Answer analytics (NL→SQL over live EBS).
- Retrieve policy (RAG).
- Take audited, gated actions (AR + AP).
- Ingest invoices.
- Draw charts.

First-time users get suggested starter questions as one-click chips.

**Multi-turn context:** the assistant remembers the recent conversation, so you can answer its
follow-ups naturally — e.g. if it offers a numbered menu ("1. send dunning… 2. place a hold…"), just
reply **"2"** and it acts on that option. Context is held in **AgentCore Memory** (short-term), keyed
to your user + session, so it persists even across a page refresh; recent turns are also sent with
each message as a fallback.

### 5.4 Charts via AgentCore Code Interpreter (C6) — how it works

When you ask for a visual ("bar chart of the top 5 overdue customers"), the agent calls
**`generate_chart`**, which runs Python (matplotlib/pandas/numpy) in the **Amazon Bedrock AgentCore
Code Interpreter** — a secure sandbox:

1. The agent writes matplotlib code and sends it to the sandbox.
2. The sandbox executes it, renders a PNG, and returns it (base64 / uploaded to S3).
3. The reply carries the image; the **docked assistant detects it** (`data:image/png` or a
   `…/charts/….png` URL) and renders it inline as an image.

You don't write code — just ask for the chart in words.

### 5.5 Policy library + drift check (C15) — the "Policy" tab

![Figure 4 — Policy library, annotated. (A) The drift check compares the written policy of record against the tolerance Payables actually enforces (live from EBS) and flags divergence; (B) "Sync from EBS" lets an AP manager reconcile a drift in one click — updating the app's documented policy only, never EBS; (C) the documents are read from the same knowledge base the agent cites, rendered with headings, bold, and lists; (D) EBS "tolerance templates" are the enforced limits (e.g. allow price up to 10% over PO) attached to an operating unit, while the "TEMPLATE" docs here are the dunning-letter wording the app sends.](assets/ui-policy-annotated.png)

The **Policy** tab makes the rules the assistant reasons over **visible and verifiable**.

- **Document library** — a two-pane reader. On the left, the policies, SOPs and dunning-letter
  templates grouped by type; click any one to read it in full on the right. These are read **from the
  same Oracle 26ai knowledge base (`COLLECTIONS_KNOWLEDGE_BASE`) that backs the agent's
  `search_knowledge_base` tool** — so what you read here is exactly what the assistant cites when it
  says "within policy". This is the *policy of record*. (Note: the **TEMPLATE** group here holds the
  *dunning-letter templates* — the wording the app sends at each escalation level. Don't confuse these
  with an EBS *tolerance template*, described below, which is an enforcement limit, not letter text.)
- **Why does policy live here and not in EBS?** — hover the small **ⓘ** on the note at the top for a
  plain-English explanation. Short version: **EBS stores the settings that block a payment**
  (tolerance limits, hold codes, dunning steps) as numbers it enforces automatically; it does **not**
  store the written policy that explains *why* a rule exists or *who* can approve an exception. That
  narrative document normally lives outside EBS — here it lives in the AI knowledge base.
- **What is a "tolerance template" (for non-EBS readers)?** In E-Business Suite, a *tolerance
  template* is a named set of numeric limits — for example "allow an invoice price up to **10%** over
  the purchase-order price" and "allow quantity up to **5%** over what was received" — that is
  attached to an operating unit. When an invoice arrives, Payables matches it against the PO and the
  goods receipt; if it's **within** the template's limits the invoice flows through, and if it's
  **outside** them EBS automatically places the invoice **on hold**. In other words, the template is
  the switch EBS uses to decide, automatically, whether an invoice can be paid. The *policy* documents
  in this library are the human-readable rules that explain those numbers (the *why* and *who
  approves*); EBS stores the enforced number, this app stores the narrative.
- **Policy vs. live EBS enforcement (drift check)** — a reconciliation panel compares the narrative
  price-variance tolerance (the *policy of record*) against the tolerance **Payables actually
  enforces per operating unit**, read live from EBS (`AP_SYSTEM_PARAMETERS_ALL` →
  `AP_TOLERANCE_TEMPLATES`). Operating units whose enforced value differs from the written policy are
  flagged **DRIFT** so you reconcile the document or the Payables template.
- **Sync from EBS (reconcile a drift)** — when the panel shows **DRIFT**, an **AP manager** sees an
  active **Sync from EBS** button. Clicking it (after a confirmation that spells out the change, e.g.
  "update the documented policy from 5% to 10%") updates the app's *documented* policy of record to
  match what Payables actually enforces, and the panel flips to **in sync**. What it does and doesn't
  do:
  - It updates **only** the app's own stored policy value (`XX_POLICY_SETTINGS` in the `COLLECTIONS_AI`
    schema) — the document side of the comparison.
  - It **never** changes any EBS configuration. **EBS remains the system of record** for the enforced
    tolerance; the button only makes the written policy agree with it.
  - It is **role-gated**: analysts and other read-only users don't get the action (the button is
    disabled when there's no drift, and the request is denied server-side without an AP responsibility).
  - The acting user is recorded in an audit column on the setting.

This closes the trust gap: an approver signing off an AI-recommended hold release can, in one click,
read the policy behind the "within policy" badge, confirm it still matches what the system enforces,
and — if it has drifted — reconcile it on the spot.

---

## 6. Test suite — one quick test per feature

Format for every test: **Where** (which tab/panel) · **Do** (click or paste this) · **Expect** (what
you should see). Tags: **[UI]** browser · **[AI]** the docked AI Assistant (right side, every screen).
Live numbers are from the current clone and drift over time. Everything below is done from the browser
and the docked AI Assistant — no terminal or commands required.

### TC. Overview loads **[UI]**
- **Where:** sign in → **Overview** tab.
- **Expect:** green **CASH IN** ($ overdue) and red **CASH OUT** ($ blocked ≈ $439M) panels, KPI strip,
  "Collect first" + "Unblock next" lists, and the AI Assistant docked on the right.

### TC2. Row → Assistant hand-off **[UI + AI]**
- **Do:** on Overview, click **Ask AI** on the top "Collect first" row.
- **Expect:** the dock opens and auto-asks a question about that customer; the agent replies.

### T1. Collections dashboard **[UI]**
- **Where:** **Collections** tab.
- **Expect:** KPI cards, top-overdue bar chart, and a risk table populate from live AR.

### T2. AP Control Tower dashboard **[UI]**
- **Where:** **AP Control Tower** tab.
- **Expect:** pipeline funnel (~145K → ~130K paid), KPIs (~2,131 on hold / ~$439M), holds + aging charts.

### T3. Dashboard filters + Why? **[UI]**
- **Where:** AP Control Tower.
- **Do:** click the **INSUFFICIENT FUNDS** bar; then a pipeline stage; then **Why?** on any row.
- **Expect:** the queue actually re-filters ("Showing X of Y" + clear filter); **Why?** opens the
  Assistant with the hold explanation.

### T4. Ask a question (NL→SQL) **[AI]**
- **Do:** `What is our total outstanding and overdue right now?`
- **Expect:** a live figure (≈ $1.1B) that matches the dashboard.

### T5. Ask about policy (RAG) **[AI]**
- **Do:** `What is our policy for placing a customer on credit hold?`
- **Expect:** an answer grounded in the seeded policy docs.

### T6. Draw a chart **[AI]**
- **Do:** `Draw a bar chart of the top 5 customers by overdue amount.`
- **Expect:** a chart image rendered inline in the dock.

### T7. Take an AR action (safe) **[AI]**
- **Do:** `Place a credit hold on customer 1007 with reason "demo test".` (then release it to revert).
- **Expect:** the agent confirms via the **seeded** `HZ_CUSTOMER_PROFILE_V2PUB` API (reply shows the
  API name). `Create a collections note on customer 1007: "..."` also works (audited note).

### T8. Diagnose an AP hold **[AI]**
- **Do:** `Show me the top AP exceptions, then diagnose the first one.`
- **Expect:** a ranked list, then a plain-English price/qty variance explanation. No hold released.

### T9. Release a hold (gated) **[AI]**
- **Do:** `Release the hold on invoice <id from T8>.`
- **Expect:** the agent asks for approval + reason and checks policy first; it won't release silently.

### T10. Ingest a clean invoice **[AI]**
- **Do:** `Ingest this invoice: vendor Office Max, number DEMO-CLEAN-1, amount 930, date 2026-06-30, currency USD, confidence 0.95`
- **Expect:** reply **STAGED** to the Payables Open Interface (high confidence).

### T11. Ingest a blurry invoice **[AI + UI]**
- **Do:** `Ingest this invoice: vendor Smudged Print Co, number DEMO-BLUR-1, amount 500, date 2026-06-30, currency USD, confidence 0.4`
  then open **AP Control Tower → Invoice review queue**.
- **Expect:** reply **NEEDS_REVIEW**; it appears in the review queue at 40%.

### T12. Ingest a real document **[UI]**
- **Where:** **AP Control Tower** → **Ingest an invoice** panel.
- **Do:** drag a **PNG/JPEG** invoice onto the dropzone (or click to choose a file). *(PDF is not
  supported by the deployed extractor — it uses Bedrock vision; see `DETAILED_DESIGN.md` Part II §5.)*
- **Expect:** status shows uploading → extracting (AI) → ✓ processed; ~15s later it's staged to
  Payables (clear) or shows in the **Invoice review queue** below (blurry/low-confidence). The file
  uploads straight to the S3 inbox via a presigned URL, which triggers Bedrock-vision extraction.

### T12a. See why an invoice needs review + view the document **[UI]**
- **Where:** **AP Control Tower → Invoice review queue**.
- **Do:** read the **Why review** column; click **View invoice** on a row.
- **Expect:** a plain-English rationale for the low confidence (e.g. "blurred scan — totals
  illegible"), and the original document opens in a new tab via a short-lived presigned URL.

### T12b. Approve a reviewed invoice → Payables **[UI]**
- **Where:** review queue.
- **Do:** click **Approve** on a row; confirm/correct the amount in the prompt.
- **Expect:** a banner "Approved + staged to AP interface (group P2P_…)"; the row leaves the queue.
  The invoice is now in the seeded `AP_INVOICES_INTERFACE`, ready for import.

### T12c. Reject a reviewed invoice **[UI]**
- **Do:** click **Reject** on a row; enter a reason.
- **Expect:** a banner confirming rejection; the row leaves the queue and will not enter Payables.

### T12d. Run the Payables Open Interface Import **[UI]**
- **Do:** click **Run Payables import** (top of the review queue).
- **Expect:** a banner "Payables Open Interface Import (APXIIMPT) submitted — concurrent request
  <id> …". The seeded APXIIMPT program picks up the approved/staged invoices for that group.
- **Note:** APXIIMPT argument positions are instance-specific — validate against your Payables setup
  before relying on a live import batch.

### T13. Propose a payment **[AI]**
- **Do:** `Propose a payment for invoice 43907.`
- **Expect:** a proposal (amount/due/holds) labelled **PROPOSAL ONLY — no payment created**.

### T14. Row-level security (VPD) **[AI]**
- **Do:** `As an org-204 clerk, how many exception rows can I see, and how many across all orgs?`
- **Expect:** scoped to org 204 you see ~412 rows / 1 org; unscoped shows all 25 orgs — the limit is
  enforced in the database kernel, so the agent cannot over-share.

### T15. AgentCore Runtime host **[AI]**
- **Do:** `How many customers are on credit hold?`
- **Expect:** a one-sentence answer from live EBS (the same agent runs on the container host).

### T16. SQLcl MCP server **[AI]**
- **Do:** `List your SQLcl connections, connect to EBS_COLLECTIONS, then count my tables.`
- **Expect:** it connects (Oracle 23.26.2) and returns a table count via the governed SQLcl MCP tools.

### T17. Working-capital what-if **[UI + AI]**
- **Where:** Overview → purple **Working-capital what-if** panel.
- **Do:** click **Run simulation** (or ask: `If I collect the top 10 overdue and release in-tolerance
  holds, how much cash is freed and what happens to DSO?`).
- **Expect:** cards show **cash freed** (≈ $2.3B), AR/blocked before→after, and DSO before→after —
  labelled a projection, no action taken.

### T18. Action plan **[UI + AI]**
- **Where:** Overview → **Recommended action plan** table.
- **Do:** read the ranked moves; click **Act with AI** on the top row.
- **Expect:** highest-value AR+AP moves with a **within policy / needs review** badge; **Act with AI**
  opens the Assistant with that move, gated on your approval.

### T19. Payment prediction **[AI]**
- **Do:** `Which customers are most likely to pay late, and by how many days?`
- **Expect:** a list with average days late, a risk band (LOW/MEDIUM/HIGH), and a predicted date.

### T20. Duplicate/fraud check **[AI]**
- **Do:** `Check this invoice for duplicates before ingest: vendor <existing supplier>, number
  <existing invoice number>, amount <its amount>, date <its date>.`
- **Expect:** verdict **BLOCK** with `DUPLICATE`; a genuinely new invoice returns **CLEAR**.

### T21. RBAC — analyst is denied a write **[AI]**
- **Where:** sign in as `demo@collections-26ai.aws` (AR Analyst, read-only).
- **Do:** `Place a credit hold on customer 1007 with reason "test".`
- **Expect:** a polite **refusal** — "you don't have permission… requires an AR Collections Manager…
  escalate to a manager." No hold is placed. (Queries and charts still work for this user.)

### T22. RBAC — manager is allowed / cross-domain is denied **[AI]**
- **Where:** sign in as `demo-ap-manager@example.com` (AP Manager).
- **Do:** `Propose a payment for invoice 43907.` (allowed — proposal only) then
  `Place a credit hold on customer 1007.` (an AR action).
- **Expect:** the payment proposal succeeds; the **credit hold is denied** (AP role can't do AR
  writes). Sign in as `demo-manager@example.com` (AR+AP) to see both allowed.

### T23. Policy library + drift check **[UI]**
- **Where:** top bar → **Policy** tab.
- **Do:** read the **Policy vs. live EBS enforcement** panel, then open a document from the list; hover
  the **ⓘ** on the top note.
- **Expect:** the drift panel lists operating units with **DRIFT** where the enforced tolerance differs
  from the 5% policy of record (e.g. *Vision Operations* = 10%); the document opens in the reader; the
  tooltip explains why policy lives in the knowledge base and not in EBS. This is the same
  `COLLECTIONS_KNOWLEDGE_BASE` the agent cites.

### 6.1 Ask AI — example questions to try

Paste any of these into the docked **AI Assistant** (right side, every screen). They exercise the
full range of tools — analytics, policy, charts, actions, ingest, and the working-capital intelligence.

**Analytics (NL→SQL over live EBS):**

- `What is our total outstanding and overdue right now?`
- `Who are the top 10 customers by overdue amount?`
- `How much are we blocking in payables, and by which hold type?`
- `What's our payables aging — how much is over 90 days?`
- `How many invoices are on hold versus awaiting approval?`

**Policy & knowledge base (RAG):**

- `What is our policy for placing a customer on credit hold?`
- `How should a disputed invoice be handled?`
- `What are the steps to set up a payment plan?`
- `When do we escalate to a Level 3 final notice?`

**Charts (Code Interpreter):**

- `Draw a bar chart of the top 5 customers by overdue amount.`
- `Chart blocked payables value by hold type.`
- `Show payables aging as a bar chart.`

**Collections actions (AR, audited):**

- `Create a collections note on customer 1007: "Called AP, promised payment Friday."`
- `Place customer 1007 on credit hold` (then) `release the credit hold on customer 1007.`
- `Send a Level 3 dunning letter to customer 1007.` — generates the letter from the KB template + live
  balances, records an **audited note** (returns a real note ID you can verify), and **emails it via
  Amazon SES** (returns a MessageId). The agent only says "sent" when SES actually accepted it.
- `Draft a friendly payment reminder for the top overdue customer.` — same path at Level 1 (softer tone).

**AP exceptions & actions (gated):**

- `Show me the top AP exceptions, then diagnose the first one.`
- `Why is invoice <id> on hold, and is releasing it within policy?`
- `Release the hold on invoice <id>.` (agent asks for approval + reason first)
- `Propose a payment for invoice 43907.` (proposal only — no money moves)

**Invoice ingest:**

- `Ingest this invoice: vendor Office Max, number DEMO-CLEAN-1, amount 930, date 2026-06-30, currency USD, confidence 0.95`
- `Ingest this invoice: vendor Smudged Print Co, number DEMO-BLUR-1, amount 500, date 2026-06-30, currency USD, confidence 0.4`
- `Check this invoice for duplicates before ingest: vendor <existing supplier>, number <existing invoice number>, amount <its amount>, date <its date>.`

**Working-capital intelligence:**

- `If I collect the top 10 overdue and release in-tolerance holds, how much cash is freed and what happens to DSO?`
- `What are the highest-value next moves across AR and AP right now?`
- `Which customers are most likely to pay late, and by how many days?`

### Coverage map
| Tests | Cover |
|---|---|
| TC, TC2 | Overview (single pane) + Assistant hand-off |
| T1–T3 | Dashboards + interactivity (AR, AP) |
| T4–T6 | Ask AI: analytics, policy, charts |
| T7–T9, T13 | Actions: note, diagnose, gated release, propose payment |
| T10–T12, T20 | Invoice ingest + duplicate/fraud check |
| T12a–T12d | Invoice review: rationale, view doc, approve/reject, run import |
| T14 | Row-level security (VPD) |
| T15–T16 | AgentCore Runtime + SQLcl MCP |
| T17–T19 | Working-capital: what-if, action plan, prediction |
| T21–T22 | RBAC: role-gated write actions (deny/allow, cross-domain) |

---

## 7. Demo talk-track (60 seconds)
"This is one AI assistant sitting directly on live E-Business Suite — no data warehouse, no ETL. On
the **cash-flow side** I can ask for our overdue position, get the answer from live AR, have it draw
a chart, and take a collections action — all in chat. On the **payables side**, the AP Control Tower
shows exactly where invoices are stuck; the AI tells me *why* an invoice is on hold and whether
releasing it is within policy, then acts through audited Payables APIs. Clean invoices flow straight
through via the seeded Open Interface; blurry ones are held for a human. It's secured row-by-row in
the database, uses core EBS — no extra licence, no bot to maintain — and it replaces roughly
$3k/month of Redshift/ETL with features of the database we already own."

---

## 8. Capability summary (what's built)

**Single pane of glass:** a **Working-Capital Overview** home unifying cash-in (AR) + cash-out (AP),
two drill-down tabs, and an **AI Assistant docked on every screen** (one shared WebSocket).

**Collections (AR):** live NL→SQL analytics, KPI/aging/risk dashboard, knowledge-base RAG,
Code-Interpreter charts, audited write-back via **seeded EBS public APIs over ISG REST** (credit
holds, notes, dunning, reminders).

**AP Control Tower (P2P):** pipeline funnel + KPIs + holds/aging charts + exception queue;
`diagnose_match_exception` (2/3-way variance), `release_ap_hold` (seeded `AP_HOLDS_PKG`),
`validate_invoice`, `manual_approve_invoice`, `propose_payment`; AI invoice ingest (Bedrock vision
→ seeded Payables Open Interface) with confidence gate + **interactive human review queue**
(per-row **Why review** rationale, **View invoice**, **Approve**/**Reject**, and **Run Payables
import** which submits the seeded APXIIMPT and returns its concurrent request id).

**Working-capital intelligence (AR + AP):** a **what-if simulator** (project cash/DSO/DPO from a
collect + release plan), a ranked **agent action plan** (highest-value next moves with a within-policy
flag), **payment prediction** (who pays late, from history), and a **duplicate/fraud check** on invoice
ingest — all read-only analytics over the live views; actions still route through the audited seeded APIs.

**Platform:** Oracle 26ai (SELECT AI profile, in-DB ONNX vector search), Bedrock Claude agent
(Strands). The **live UI chat runs on the AgentCore Runtime** (container, VPC-attached) with the
**SQLcl 25.2 MCP server** available in-browser. Plus
AgentCore Code Interpreter, VPD row-level security, and seeded ISG REST / Payables interfaces (no
SOA Suite licence).

---

## 8a. Who can do what — roles & permissions

The assistant enforces your **EBS responsibility** in the AI layer. Anyone can ask questions, run
analytics, pull policy, and draw charts. **Actions that change EBS are gated by your role** — the
same permission model you already have in EBS, applied to the AI.

| Your group (role) | You can… | You cannot… |
|---|---|---|
| **AR Manager** (`ar-managers`) | place/release credit holds, add notes, send dunning/reminders | AP actions (release AP holds, approve invoices) |
| **AP Manager** (`ap-managers`) | release AP holds, approve invoices, run Payables import, add AP notes | AR actions (credit holds, dunning) |
| **AR Analyst** (`ar-analysts`) | everything read-only: queries, charts, policy | any write action |
| **AP Clerk** (`ap-clerks`) | read-only exception queue + analytics | any write action |

If you ask for an action your role doesn't allow, the assistant **won't do it** — it replies with a
clear "you don't have permission… please escalate to a manager" message instead of failing silently.
Reads and **payment *proposals*** (which never move money) are always available.

**Talk-track answers to the common questions:**
- *"How do we stop a junior collector placing credit holds?"* — They're in the `ar-analysts` group,
  so the agent refuses write actions and tells them to escalate. Same model as EBS, enforced in the AI too.
- *"Can people log in with corporate credentials?"* — Yes: Cognito supports SAML/OIDC federation
  (Azure AD, Okta, Oracle Access Manager). Users get normal SSO; their identity maps to their EBS user.
- *"Who shows in the EBS audit trail?"* — In this demo, the shared service account. In production,
  each action is logged against the individual's `FND_USER` via the `custom:ebs_username` mapping —
  the audit trail looks exactly like they did it in the EBS forms.

**Demo logins (clone):**

| Login | Role | Use it to show |
|---|---|---|
| `demo-manager@example.com` | AR + AP Manager | every action allowed |
| `demo-ap-manager@example.com` | AP Manager | AP actions allowed; AR denied |
| `demo-sales@example.com` | AR Analyst | the **denied / escalate** path |

*The optional demo accounts use the customer-supplied password configured at
`rbac.demo_password` in `deploy-config.json`. They are non-production accounts on a clone; do not
reuse production credentials, and rotate or remove the accounts after the demonstration.*

---

## 9. Honest limitations
- **The AI Assistant** shows the final reply (not streaming step-by-step); complex asks take a few
  seconds. It's docked on every screen and shares one WebSocket with the dashboards.
- **AP queue filters** operate on the top ~30 loaded exceptions (can be made server-side).
- **Approval** uses the supported `MANUALLY APPROVED` status; full AME workflow isn't configured on
  this clone (production upgrade path in `DETAILED_DESIGN.md`, Part II section P5).
- **Payments** are proposal-only (no money movement).
- **VPD** defaults to "see all" until Cognito→operating-unit mapping is wired (kernel enforcement proven).
- **Working-capital what-if** is a projection from live balances (collect top-N + release in-tolerance
  holds); it takes no action. On this clone AR is historical so absolute **DSO is very high** — the
  *before→after delta* is the point, not the absolute day count.
- **Payment prediction** is a historical heuristic (average days-late + risk band from paid history),
  not a trained ML model; predicted dates reflect the clone's historical data. Use the risk ranking,
  not the absolute date.
- **Duplicate/fraud check** matches on vendor + invoice number / amount + date and vendor amount
  profile; it's a strong dup-payment guard, not a full forensic-fraud engine.
- The seeded **APXIIMPT** import argument positions should be validated against your Payables setup
  before a live import batch (staging into the interface is proven).
- The **UI chat runs on the Bedrock AgentCore Runtime** (VPC-attached; SQLcl MCP + AgentCore Memory
  in the browser). The WebSocket handler invokes it via `AGENT_RUNTIME_ARN`, set by `deploy.sh agentcore`.
  AgentCore has a slightly higher cold-start on the first message after idle (then warm).
- **Role-based access control** is enforced on write actions from a **server-verified** Cognito
  group (see §8a). It's demo-scoped: a small set of hand-provisioned users/groups, mapped to EBS
  responsibilities. Production would **federate** the corporate IdP (SAML/OIDC) rather than
  hand-create users, and map each identity to its `FND_USER` for EBS-native audit. Row-level (MOAC)
  scoping per operating unit is built as VPD (Part II §6) but the Cognito→org mapping isn't wired.
- These are **non-production demo credentials** on a clone — rotate before any real use.

---

## 9a. Optional: using this from Amazon Quick

If your organisation uses **Amazon Quick**, the solution can be connected to it so you can work with
the ERP from Quick chat and automations (alongside your Outlook / Slack / SharePoint connectors):

- **Ask the ERP in Quick chat** — "what's our overdue total?", "which vendors have the most invoices
  on hold?", "give me the working-capital action plan."
- **Scheduled digests** — e.g. "every weekday 8am, summarise the AP exceptions and email the AP
  manager" — authored as a Quick automation.
- **Email/Slack an invoice → EBS** — a Quick automation can take an invoice attachment and drop it
  into the AP capture inbox; the normal extraction pipeline then processes it (clear invoices stage
  to Payables, low-confidence ones go to the review queue). This is the Quick equivalent of the
  in-app drag-and-drop upload.

This is an **optional integration**: it needs an Amazon Quick Enterprise subscription and a one-time
setup by a Quick administrator (Quick is your own SaaS workspace, so it's connected in the Quick
console rather than auto-deployed). Full steps: `docs/QUICK_MCP_SETUP.md`. No tool pays or approves
an invoice — writes stay on the same audited path as the rest of the solution.

---

## 10. Related docs
- `docs/SOLUTION_OVERVIEW.md` — architecture, deployment, live resource inventory.
- `docs/DETAILED_DESIGN.md` — full technical design (Part I Collections/AR + Part II Purchase-to-Pay).
- `docs/QUICK_MCP_SETUP.md` — connect Amazon Quick to the EBS Finance MCP server (optional integration).
- `PROGRESS.md` — build log / current state / verified tests.

---

## Appendix A — 15-minute demo script

A tight, repeatable run that shows the whole story: live analytics, an AI that acts, the payables
control tower, security, and the working-capital pay-off. Timings are a guide — the whole thing fits
in 15 minutes with a little room for questions.

**Audience framing:** one AI assistant on *live* Oracle E-Business Suite that both **answers** and
**acts** — governed, and secured inside the database. Two sides of the cash cycle: Collections (cash
in) and the AP Control Tower (cash out).

### Before you start (2 min, off the clock)
- Sign in as **`demo-manager@example.com`** (AR + AP Manager — can do everything), using the
  customer-supplied password configured at `rbac.demo_password` in `deploy-config.json`.
- Open a second browser tab signed in as **`demo-sales@example.com`** (AR Analyst, read-only) using
  the same customer-configured password, ready for the security beat so you don't burn time logging
  in mid-demo.
- Land on the **Overview** tab. Confirm the dashboards populated (green CASH IN / red CASH OUT panels).
- Have one **PNG/JPEG** invoice file on the desktop for the ingest beat (optional).
- One-liner to open with: *"Everything you'll see runs off the live ERP — no data warehouse, no nightly copy."*

### Minute-by-minute

**0:00–1:30 — The one-pane overview (the hook)**
- **Show:** the **Overview** tab. Point to **CASH IN** (overdue receivables) next to **CASH OUT**
  (blocked payables), the KPI strip, and the docked **AI Assistant** on the right.
- **Say:** "This is the whole working-capital cycle on one screen — money owed to us on the left, money
  we're holding on the right — and an assistant that's on every screen."

**1:30–4:00 — Ask the ERP anything (live analytics + a chart)**
- **In the Assistant, paste:** `What is our total outstanding and overdue right now?`
  → live figure (≈ $1.1B), straight from EBS, no warehouse.
- **Then:** `Draw a bar chart of the top 5 customers by overdue amount.`
  → a chart renders inline in the chat.
- **Then (RAG):** `What is our policy for placing a customer on credit hold?`
  → an answer grounded in the seeded policy documents.
- **Say:** "Plain-English questions become live SQL; it charts inline; and when it talks policy it's
  reading our actual policy library, not guessing."

**4:00–6:30 — An AI that acts (governed write-back)**
- **Paste:** `Create a collections note on customer 1007: "Called AP, promised payment Friday."`
  → confirms via the seeded EBS API (audited).
- **Then:** `Place a credit hold on customer 1007 with reason "demo".` → the agent performs it through
  the seeded Customer Profile API. *(Optionally: `release the credit hold on customer 1007.` to revert.)*
- **Say:** "This is the difference from a read-only chatbot — it can act. But every action goes through
  Oracle's official, audited APIs, and it's gated by your role. It proposes; a person approves; Oracle logs it."

**6:30–10:00 — AP Control Tower (reason about exceptions)**
- **Go to:** the **AP Control Tower** tab. Point to the **pipeline** (where invoices get stuck), the
  **blocked-value-by-hold-type** chart, and the **exception queue**.
- **Do:** click a **hold-type bar** to filter the queue, then click **Why?** on the top row.
  → the assistant diagnoses the 2/3-way match variance (price/qty vs the PO and receipt) and says
  whether releasing is within tolerance.
- **Optional ingest beat:** drag a **PNG/JPEG** invoice onto the **Ingest an invoice** panel → watch
  uploading → extracting (AI) → staged, and note that low-confidence ones drop into the review queue.
- **Say:** "RPA bots skip the messy cases; here the AI *reasons* about them — it tells me why an invoice
  is stuck and whether policy allows releasing it. Clean invoices flow straight through; unclear ones
  wait for a human."

**10:00–12:00 — Trust: policy drift + security (the reviewer's question)**
- **Go to:** the **Policy** tab. Show the **Policy vs. live EBS enforcement** panel — the written policy
  compared to the tolerance Payables actually enforces, flagged **in sync / DRIFT**. Mention the
  **Sync from EBS** button reconciles a drift (AP-manager only; updates the doc, never EBS).
- **Security beat (switch to the second browser tab — the read-only analyst login, not an in-app tab):** as `demo-sales@example.com`, paste
  `Place a credit hold on customer 1007 with reason "test".`
  → a polite **refusal** ("you don't have permission… escalate to a manager"). Reads still work.
- **Say:** "Two things reviewers always ask. One — do the docs match the system? The drift check answers
  that live. Two — can the AI go rogue? No: the database account it uses can only *read* finance data
  (it's called `COLLECTIONS_AI` and was never granted write access), every change goes through audited
  APIs, and write actions are gated by your EBS role — as you just saw, the analyst is refused."

**12:00–13:30 — The pay-off (working-capital what-if)**
- **Back on Overview:** click **Run simulation** on the purple **Working-capital what-if** panel (or
  ask: `If I collect the top 10 overdue and release in-tolerance holds, how much cash is freed and what
  happens to DSO?`).
- **Show:** cash freed, AR/blocked before→after, DSO before→after — labelled a projection, no action taken.
- **Say:** "This turns the analytics into a decision: here's the cash we'd free and the DSO impact —
  a projection, no money moves until someone approves the plan."

**13:30–15:00 — Close + the ask**
- **Say:** "So: live working-capital intelligence with no ETL lag; an agent that *acts* through governed,
  audited APIs; and it's license-clean and security-reviewed. It replaces roughly $3k/month of
  Redshift/ETL with features of the database we already own."
- **The ask:** "Let's run a pilot on a copy of a customer's EBS environment — it's a staged, repeatable
  deploy, so standing it up is configuration, not a rebuild."

### If you only have 5 minutes (cut-down)
Overview hook (30s) → one analytics question + chart (1.5m) → one AP **Why?** diagnosis (1.5m) →
the analyst **refusal** security beat (1m) → the what-if pay-off (30s).

### If asked for more depth
- **Row-level security:** `As an org-204 clerk, how many exception rows can I see, and how many across
  all orgs?` → scoped ~412 rows / 1 org vs all 25 (enforced in the DB kernel).
- **Payment prediction:** `Which customers are most likely to pay late, and by how many days?`
- **Duplicate/fraud guard, invoice review queue (Approve/Reject/Run import), SQLcl MCP** — see the
  full test suite in §6.

### Demo hygiene
- If you place a credit hold on **customer 1007**, **release it** afterwards to leave the clone clean.
- Ingest uses obviously fake vendors (e.g. `DEMO-CLEAN-1`) so demo data is easy to spot.
- Numbers drift as the clone changes — quote them as "about", not exact.
- First message after idle has a slightly longer cold-start on AgentCore, then it's warm — fire one
  throwaway question during the intro if you want it warm for the live beats.

---

## Appendix B — 20-minute demo checklist (click + copy-paste)

A run-list for a ~20-minute live demo. No talk track — just what to click and the exact prompts to
paste into the docked **AI Assistant**. Work top to bottom; each ▸ is a prompt you can copy verbatim.

### Setup (once, before you start)
- Sign in as **`demo-manager@example.com`** (AR + AP Manager — full access), using the
  customer-supplied password configured at `rbac.demo_password` in `deploy-config.json`.
- Open a **second tab** signed in as **`demo-sales@example.com`** (AR Analyst, read-only), using the
  same customer-configured password for the security beat.
- **Warm the agent:** paste `how many customers are on credit hold?` once so the first live reply
  isn't a cold start.
- Have the two demo invoices handy (in `docs/assets/`):
  `demo-invoice-tt-services.png` (clean) and `demo-invoice-tt-services-blurry.png` (low-confidence).
- Browser zoom **110–125%** so text is legible.

### 1. Overview — the whole cash cycle (~2 min)
- **Overview** tab. Point at **CASH IN** (receivables) vs **CASH OUT** (payables) and the docked assistant.
- ▸ `What is our total outstanding and overdue right now?`
- ▸ `How many customers are on credit hold and what's the total value?`

### 2. Ask the ERP — live NL→SQL analytics + charts (~4 min)
- ▸ `Show me the top 10 customers by overdue amount.`
- ▸ `Draw a bar chart of the top 5 customers by overdue amount.`  *(chart renders inline)*
- ▸ `Which customers have the worst average days-late based on their payment history?`
- ▸ `Break down the AR aging into current, 1-30, 31-60, 61-90 and 90+ day buckets.`
- ▸ `Who is most likely to pay late next, and when do you predict they'll pay?`  *(payment prediction)*

### 3. Policy RAG — grounded, not guessing (~2 min)
- ▸ `What is our policy for placing a customer on credit hold?`
- ▸ `What are the dunning escalation levels and when does each apply?`
- ▸ `What price and quantity tolerances allow an AP invoice hold to be released?`

### 4. An AI that acts — governed, audited write-back (~3 min)
- ▸ `Create a collections note on customer 1007: "Called AP, promised payment Friday."`  *(returns a note ID)*
- ▸ `Place a credit hold on customer 1007 with reason "demo".`  → confirm when it asks *(writes to the EBS customer profile via HZ_CUSTOMER_PROFILE_V2PUB)*
- ▸ `Send a Level 2 dunning letter to customer 1007.`  → confirm when it asks *(logs an audited note + emails via SES)*
- Point out: the agent **proposes**, a human **approves**, Oracle **logs** it — nothing auto-fires.

**Prove it in the database (optional — run as `apps/apps`).** After placing the hold, this query
shows customer 1007's account-level credit-hold flag flip to `Y` (the credit hold lives on the EBS
customer profile — `HZ_CUSTOMER_PROFILES.CREDIT_HOLD`). The account-level profile is the row with
`SITE_USE_ID` NULL:

```sql
SELECT ca.cust_account_id,
       ca.account_number,
       p.party_name AS customer_name,
       cp.credit_hold,
       TO_CHAR(cp.last_update_date,'YYYY-MM-DD HH24:MI:SS') AS last_update
FROM   ar.hz_cust_accounts     ca
JOIN   ar.hz_parties           p  ON p.party_id = ca.party_id
JOIN   ar.hz_customer_profiles cp ON cp.cust_account_id = ca.cust_account_id
WHERE  ca.cust_account_id = 1007
  AND  cp.site_use_id IS NULL;   -- account-level profile (not a site profile)
```

Expect `CREDIT_HOLD = Y` with a `LAST_UPDATE` matching when the agent placed it. To verify the note
went into the standard EBS notes framework (visible in Advanced Collections), run:

```sql
SELECT jtf_note_id, source_object_code, source_object_id,
       TO_CHAR(creation_date,'YYYY-MM-DD HH24:MI:SS') dt, SUBSTR(notes,1,60) notes
FROM   jtf_notes_vl
WHERE  source_object_code = 'IEX_CUSTOMER' AND source_object_id = 1007
ORDER  BY jtf_note_id DESC FETCH FIRST 5 ROWS ONLY;
```

### 5. AP Control Tower — reason about exceptions (~4 min)
- Click the **AP Control Tower** tab. Point at the **pipeline** (where invoices stall), the
  **blocked-value-by-hold-type** chart (click a bar to filter), and the **exception queue**.
- Click **Why?** on the top row (or paste the prompt below), then drill in with the follow-ups:
- ▸ `Why is AP invoice ERS-17-JUN-09-192620 (invoice_id 245820) on hold? Use diagnose_match_exception and the knowledge base, then give a one-paragraph plain-English explanation and whether releasing the hold is within policy.`
- ▸ `Can you tell me what the hold type is?`
- ▸ `How much is the goods receipt for this invoice, and what was the PO quantity and price?`
- ▸ `Is the price variance within our tolerance policy — can this be released, and who has to approve it?`
- Point out: this is **read-only and audited** — it reconciles invoice vs PO vs goods-receipt inside
  Oracle and checks the tolerance policy; a human still approves the actual release.

### 6. Invoice ingest — AI vision + human-in-the-loop (~3 min)
- Scroll to **Ingest an invoice**. Drag **`demo-invoice-tt-services.png`** onto the dropzone.
  Watch the status run *uploading → extracting (AI) → processed* (queue auto-refreshes).
- Click **View interface** (next to **Run Payables import**) → show the new row in **AP_INVOICES_INTERFACE**.
- Drag **`demo-invoice-tt-services-blurry.png`** → it lands in the **Invoice review queue**
  (low confidence). Read the **Why review** rationale, click **View invoice** (opens inline), then **Approve**.

### 7. The pay-off (~1 min)
- Back on the manager tab → **Overview** → **Run simulation** on the **Working-capital what-if** panel.
  Show cash freed + DSO before→after (projection only — no money moves until approved).
- ▸ `If I collect the top 10 overdue customers and release the in-tolerance AP holds, what happens to my cash position and DSO this week?`

### Reset + gotchas
- If you placed a credit hold on **1007**, release it afterwards (`release the credit hold on customer
  1007`) to leave the clone clean — re-run the query above to confirm `CREDIT_HOLD` flips back to `N`.
- First reply after idle is slower (cold start) — that's why you warm the agent up front.
- Numbers drift as the clone changes — quote approximate figures.
- A slow chart/reply is the live DB round-trip, not a hang.

### Optional: record it as an MP4
- Use QuickTime (macOS: File → New Screen Recording), Loom, or OBS at **1920×1080**, headset mic,
  Do-Not-Disturb on. Trim with `ffmpeg -i raw.mov -ss 00:00:03 -to 00:20:00 -c copy demo.mp4`.
