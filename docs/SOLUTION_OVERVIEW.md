# Oracle EBS Collections Agent — Oracle 26ai Edition

## Solution Overview

An AI-powered collections management platform for Oracle E-Business Suite that uses Oracle Database 26ai native AI capabilities (SELECT AI, AI Vector Search, DBMS_CLOUD_AI) to eliminate the need for Amazon Redshift, Zero ETL, and external data warehousing — querying live EBS data directly using natural language.

> **Now two workspaces — "EBS Finance Assistant":** **Collections** (AR — original) and **AP Control
> Tower** (Purchase-to-Pay — added 2026-06-30). The P2P module is a natural extension of the same
> three-layer architecture (deterministic views + agent tools + audited write-back) re-pointed at
> AP/PO/RCV, plus invoice ingest/extraction and a Virtual Private Database (VPD) row-level security
> layer. Full P2P detail: `docs/DETAILED_DESIGN.md` (Part II).
>
> **P2P build (all verified live on the clone):**
>
> - **AP Control Tower dashboard** — invoice pipeline funnel (the "blockage" view), holds-by-type,
>   payables aging, and a $-×-age ranked **exception queue**; live data (2,131 holds / $439M blocked
>   / 145K-invoice pipeline). React, same WebSocket stack.
> - **Agent P2P tools** — get_invoice_exceptions, diagnose_match_exception (per-line 2/3-way variance),
>   execute_p2p_action (release_ap_hold via seeded `AP_HOLDS_PKG`, validate_invoice,
>   manual_approve_invoice, propose_payment), ingest_invoice, get_invoice_review_queue.
> - **The "Why?" button (read-only + audited).** On any exception-queue row, "Why?" runs
>   `diagnose_match_exception` → the audited `APPS.XX_P2P_AP_PKG.DIAGNOSE_MATCH_EXCEPTION` package,
>   which reconciles **invoice vs PO vs goods-receipt** per line (classifying PRICE_VARIANCE /
>   QTY_OVER_RECEIPT / QTY_OVER_ORDER / NO_PO_MATCH from `XX_P2P_MATCH_V`), then does in-DB vector
>   search of the **tolerance policy** and returns a **within-/outside-policy verdict**. Diagnosis
>   changes nothing; releasing the hold is a separate RBAC-gated action that still needs human approval.
> - **Invoice ingest/extraction + interactive review** — S3/SES invoice → Bedrock vision → seeded
>   **Payables Open Interface** (`AP_INVOICES_INTERFACE` + `APXIIMPT`), with a confidence gate + an
>   **interactive human-in-the-loop review queue** in the UI: per-row **Why review** rationale
>   (Bedrock-vision reason + anomaly flags), **View invoice** (presigned document view),
>   **Approve**/**Reject**, and **Run Payables import** (submits seeded APXIIMPT, returns the
>   concurrent request id). **Upload PNG/JPEG images** (Bedrock vision path); **PDF is not supported
>   by the deployed extract Lambda** — enabling it needs a Textract/PDF→image branch (see
>   `DETAILED_DESIGN.md` Part II section 5).
> - **VPD row-level security** — `XX_P2P_SEC_PKG` + `DBMS_RLS` policies scope rows by operating unit
>   in the database kernel; the agent cannot over-share (proven: org-204 clerk sees 412 rows / 1 org
>   vs all 25 orgs). EBS-native (3,762 existing VPD policies).
> - **License-clean:** uses seeded EBS (AP_HOLDS_PKG, Payables Open Interface, FND_REQUEST/APXIIMPT,
>   DBMS_RLS, ISG REST) — core Payables, no SOA Suite.

## Business case (narrative + value)

**Problem.** Finance teams on EBS get analytics through nightly ETL to Redshift (stale, ticket-driven)
and clear AR collections + AP payables exceptions by hand; RPA bots automate only clean cases and
break on screen changes. Throughput is capped by human exception-handling and insight is delayed.

**Solution.** One AI assistant on **live** EBS that both answers and acts: Oracle 26ai native AI
(NL→SQL + in-DB vector search) replaces the data warehouse, and a Bedrock/Strands agent reasons over
the data and takes **governed actions through seeded EBS APIs** — across Collections (AR/cash flow)
and the AP Control Tower (P2P).

**Value.**

- Live analytics with zero ETL lag.
- ~$2,950/mo of Redshift/DMS eliminated.
- The agent *reasons about exceptions* instead of punting them to a human.
- AI invoice ingest via the seeded Payables Open Interface.
- API/PL-SQL robustness — no bot to maintain.
- Row-level security in the database kernel (VPD).
- Uses core EBS — no SOA Suite licence.

**Pitch:** *ask your EBS anything and let it act — live, governed, secured in the database.*

> **Full walkthrough, per-feature UI explanation, and runnable test cases:** `docs/USER_GUIDE.md`.

### Agent host: Bedrock AgentCore Runtime
The agent (Strands SDK) runs on the **Amazon Bedrock AgentCore Runtime**
(`ebs_collections_agent_26ai`) as the sole host for the UI chat:

- A VPC-attached container that reaches the private Oracle DB on 1521.
- Bundles the **SQLcl 25.2 MCP server**, so the browser Assistant gets governed SQL tools (connect / run-sql) alongside NL→SQL, RAG, write-back, and charts.
- Adds **AgentCore Memory** for durable multi-turn conversation continuity.
- The WebSocket handler invokes it via `InvokeAgentRuntime` (env `AGENT_RUNTIME_ARN`, set by the `agentcore` deploy stage).

**Concurrency + conversation memory.** A Strands `Agent` is single-flight (rejects a second in-flight
call) and accumulates history on the instance, so the runtime builds a **fresh, lightweight Agent per
request** over a **cached** tool list — no collisions between concurrent messages, no cross-user
history bleed. Because each invoke is therefore stateless, conversation context is preserved by
**Amazon Bedrock AgentCore Memory** (short-term): the runtime loads the last ~12 turns on invoke and
stores each turn after replying, keyed on the verified user + WebSocket connection (decoupled from the
per-request `runtimeSessionId`, so concurrency is untouched) — durable across refresh/device. The
browser also carries recent turns as a fast-path fallback, and the two are merged. So multi-turn
context works (e.g. replying "2" to a numbered menu the assistant just offered). Chart PNGs are passed
via a runtime side-channel (a short `[[CHART:…]]` marker), keeping the large image out of the model
context so chart requests don't loop. See DETAILED_DESIGN §5.4.

### How charts work (AgentCore Code Interpreter)
When a user asks for a visualization in **Ask AI** (e.g. "bar chart of the top 5 overdue customers"),
the agent's `generate_chart` tool runs matplotlib in the **Amazon Bedrock AgentCore Code Interpreter**
sandbox, which returns a rendered PNG (base64 / S3). The React chat detects the image in the reply
and renders it inline — the user writes no code.

## How to Access

Use the CloudFront URL printed by `deploy.sh` or returned in the stack's `CloudFrontURL` output.
Sign in with an account provisioned for your deployment. The optional demonstration accounts are
created by `./deploy.sh rbac` and use the customer-supplied password at `rbac.demo_password` in
`deploy-config.json`; no live password is published in this document.

After signing in, use **Dashboard** (KPIs and top overdue customers) and **Ask AI**
(natural-language questions and collections actions). Do not reuse demonstration credentials in a
production environment; integrate Cognito with your organizational identity provider and policies.

![Architecture Diagram](architecture-26ai-topology.png)

## Architecture

```
See the architecture topology image above (`architecture-26ai-topology.png`) for the full component
and data-flow view. Text summary of the flow:
- Browser (React on CloudFront+S3, Cognito auth) → API Gateway WebSocket → WebSocket handler λ.
- `dashboard`/`p2p_*` actions → Collections λ / P2P λ → live EBS reporting views (oracledb).
- `sendMessage` → Agent runtime (Strands, Bedrock Claude) → tools: NL→SQL, vector RAG, write-back,
  invoice ingest, chart generation.
- Invoice files land in an S3 inbox → Invoice Extract λ (Bedrock vision) → seeded Payables Open
  Interface or the human review queue.
- Oracle 26ai (PDB ERPUAT) holds the reporting views, in-DB ONNX vectors, VPD row security, and the
  audited APPS packages that call seeded EBS public APIs; the EBS app tier exposes ISG REST.
```

> **Frontend = React** (CloudFront + S3 + Cognito + WebSocket API), per the original design spec.
> APEX was evaluated and **dropped** as the product UI (2026-06-29).
>
> **Agent host — Bedrock AgentCore Runtime:**
>
> - The Oracle DB and EBS app tier are in **private subnets**.
> - The UI chat runs on the **Amazon Bedrock AgentCore Runtime** (`ebs_collections_agent_26ai`), a VPC-attached container that reaches the private Oracle DB on 1521, Bedrock, and ISG REST. It bundles the SQLcl 25.2 MCP server for governed in-browser SQL and AgentCore Memory for conversation continuity.
>
> **NL→SQL runs in the agent via boto3 Bedrock** (Claude Sonnet 4.5), not in-DB SELECT AI:
>
> - On this 26ai 23.26.2 build `DBMS_CLOUD_AI.GENERATE` to Bedrock fails (SigV4 scoped `s3://` → ORA-20401).
> - The agent generates a guard-railed single SELECT over the reporting views and runs it via oracledb.
> - The `EBS_COLLECTIONS` SELECT AI profile stays configured for when a future DB RU fixes the signer.

## Key Innovation: What Oracle 26ai Replaces

| Original Architecture (Redshift) | 26ai Architecture | Benefit |
|---|---|---|
| Zero ETL (DMS CDC → Redshift) | SELECT AI on live EBS | No replication, zero lag |
| Amazon Redshift cluster | Oracle 26ai (already paid for) | ~$3,000/mo savings |
| Agent writes SQL, calls Redshift Data API | SELECT AI generates + executes SQL | Faster, simpler |
| No RAG capability | AI Vector Search + knowledge base | Smarter decisions |
| React + S3 + CloudFront + Cognito | Same React stack, wired to the agent via WebSocket | Familiar enterprise UI |
| WebSocket API + handler Lambda | Agent chat + dashboard over one socket | Real-time chat |
| 6 analytical Redshift views | 6 deterministic EBS views + agent NL→SQL | No replication; live data |

## Components

### 1. React Frontend (CloudFront + S3 + Cognito + WebSocket)
- **Dashboard** — KPIs, top risk customers, and an overdue bar chart (recharts). Data comes over the
  WebSocket `dashboard` action → WebSocket handler Lambda → Collections Lambda → the deterministic
  `XX_COLL_*_V` reporting views on live EBS AR.
- **Ask AI chat** — Conversational interface to the Strands agent over the WebSocket API
  (`sendMessage`). Multi-step reasoning, tool use, NL→SQL, knowledge-base retrieval.
- **Auth** — Amazon Cognito (amazon-cognito-identity-js, no Amplify dependency).
> APEX is NOT the product UI (dropped 2026-06-29). ORDS is optional — the React app talks to the
> agent/Lambdas, which connect to Oracle directly via the `oracledb` thick driver.

### 2. Strands Agent (Bedrock AgentCore Runtime)
- **Framework**: Strands Agents SDK (Python), hosted on Bedrock AgentCore Runtime (`ebs_collections_agent_26ai`)
- **Model**: Claude **Sonnet 4.5** (`us.anthropic.claude-sonnet-4-5-20250929-v1:0`) via Amazon Bedrock
- **Tools**:
  - `execute_oracle_ai_query` — **boto3 Bedrock NL→SQL**: generates a guard-railed single SELECT over
    the reporting views, executes it via `oracledb` on Oracle 26ai, returns rows
  - `execute_collections_action` — ISG REST write-back (10 EBS actions) via the Collections Lambda
  - `search_knowledge_base` — in-DB ONNX AI Vector Search (`xx_kb_search_pkg.search`)
  - `generate_chart` — AgentCore Code Interpreter for matplotlib visualizations
> Env switch `USE_IN_DB_SELECT_AI=1` flips `execute_oracle_ai_query` back to in-DB
> `DBMS_CLOUD_AI.GENERATE` (SELECT AI) if a future DB RU fixes the AWS signer — no agent code change.

### 3. Oracle 26ai Database Features
- **Reporting views** — 6 deterministic `XX_COLL_*_V` views over live EBS AR (KPIs, aging, risk,
  trend, customer summary, open invoices) — the fast, demo-safe dashboard data layer
- **AI Vector Search** — in-DB **ONNX** embedding model `COLL_EMBED_MODEL` (all_MiniLM_L12_v2,
  **384-dim**), COSINE similarity over the knowledge base; zero network egress
- **SELECT AI (DBMS_CLOUD_AI)** — installed + `EBS_COLLECTIONS` profile configured (in-DB Bedrock
  call blocked by a 23.26.2 signer bug; NL→SQL runs in the agent meanwhile)
- **VECTOR datatype** — native vector storage (requires `COMPATIBLE>=23.0.0` + `vector_memory_size`)

### 4. EBS Write-Back (audited APPS package)
Collections actions run through the audited `APPS.XX_COLLECTIONS_REST_PKG` (definer-rights). The
Collections Lambda calls the package over its `oracledb` VPC connection:

- No direct DML from the Lambda.
- Avoids the cosmetic OHS `:8000` `/webservices` routing issue (set `USE_ISG_REST_HTTP=1` to force the HTTP ISG REST path instead).

Verified working + reversible:
1. get_overdue_customers (reporting view)
2. get_customer_details (reporting views)
3. place_credit_hold / release_credit_hold (HZ_CUSTOMER_PROFILES.credit_hold)
4. create_collections_note (audited APPS.XX_COLLECTIONS_NOTES)
5. send_dunning_letter / send_payment_reminder — generates the letter from the KB template merged with
   live customer data, records an audited note in `APPS.XX_COLLECTIONS_NOTES` (returns the real note_id),
   and emails it via **Amazon SES** (returns the SES MessageId). The tool reports exactly what happened
   and only claims "sent" when SES accepted the message.
> apply/release_order_holds + create_collections_task return a clean "not available" until the
> XxOrderHoldsPkg / XxCollectionsTaskPkg packages are deployed.

### 5. Knowledge Base (RAG)
Embedded documents providing policy context to the agent (9 docs seeded, all embedded in-DB):
- Collections policies (credit holds, dunning levels, payment plan authorization)
- SOPs (disputed invoices, new customer handling, payment plan setup)
- Dunning templates (Level 1/2/3)
- Stored as `VECTOR` in the table `COLLECTIONS_AI.COLLECTIONS_KNOWLEDGE_BASE` in Oracle 26ai,
  embedded with the in-DB ONNX model (384-dim), COSINE search via `xx_kb_search_pkg.search`
  (auto keyword fallback if embeddings/model absent)

> **Content is synthetic/illustrative, not extracted from EBS.** EBS has no built-in collections
> policy/SOP document store — these 9 docs (and their `metadata.source` citations) were authored for
> the demo so RAG has realistic content. Treat the specific thresholds ($10k, 60/90 days, plan
> limits) as placeholders and replace with your organization's real policy before production.
>
> **To update the KB:** edit `collections_agent/sql/XX_KB_SEED_26ai.sql` (source markdown also in
> `knowledge_base/`), re-run `./deploy.sh database`, then re-embed via
> `./collections_agent/scripts/load_onnx_model.sh`. For a full refresh, `TRUNCATE
> collections_knowledge_base` first (the seed skips if rows exist). Any changed `content` **must be
> re-embedded** (null the `embedding`, re-run the embed step) or semantic search ranks stale text.

### 5a. Policy library + drift check (UI "Policy" tab)

Because the agent grounds decisions in these documents ("within policy"), the console makes them
**visible and verifiable**:

- **Policy library** — a reader that lists and opens the policy/SOP/template docs, read from the
  **same `COLLECTIONS_KNOWLEDGE_BASE`** the agent's `search_knowledge_base` uses. What a user reads is
  exactly what the agent cites — no separate copy to drift.
- **Where policy lives (important distinction).** EBS stores the **enforcement mechanics** — Payables
  tolerance templates, hold codes, AME approval hierarchies, dunning config — as numbers it enforces.
  It does **not** store the **narrative policy** (the "why/who-approves" document); that normally lives
  outside EBS and here lives in the vector store. The UI states this inline (with an ⓘ tooltip).
- **Policy vs. live EBS enforcement (drift check).** A reconciliation panel reads the tolerance
  Payables actually enforces per operating unit (`AP_SYSTEM_PARAMETERS_ALL` → `AP_TOLERANCE_TEMPLATES`,
  via `XX_P2P_TOLERANCE_RECON_V`) and flags any **DRIFT** from the narrative *policy of record*
  (stored in `XX_POLICY_SETTINGS.PRICE_TOL_PCT`). This catches the compliance trap where a written
  policy silently diverges from what the system enforces.
- **Sync from EBS (one-click reconcile).** When drift is flagged, an AP manager can click **Sync from
  EBS** to update the app's documented policy of record to match what Payables actually enforces. The
  direction is **one-way and safe**: it writes ONLY the app-owned `XX_POLICY_SETTINGS` row (in the
  `COLLECTIONS_AI` schema) — it never changes EBS financial config; EBS stays the system of record.
  The action is RBAC-gated to AP managers, shows a confirmation of exactly what it changes, and records
  the acting identity in an audit column.

Wiring: WS `policy_docs` / `policy_recon` → collections Lambda `get_policy_documents` /
`get_tolerance_reconciliation` (read-only); WS `policy_sync` → `sync_policy_tolerance` (AP-manager
RBAC-gated, writes only `XX_POLICY_SETTINGS`). Component `frontend/src/components/PolicyLibrary.js`.

## Deployment

### Prerequisites
- Oracle 26ai database (CDB CERPUAT / PDB ERPUAT, 23.26.2) — the upgraded clone
- EBS 12.2.x with ISG REST enabled (validated: provider/isActive healthy)
- AWS account with Bedrock access (Claude Sonnet 4.5 + in-DB ONNX embeddings)
- Network: VPC connectivity to the EBS app/DB nodes

### Quick Start
```bash
# 1. Configure (already set to clone reality)
vi deploy-config.json

# 2. Create the DB secret + deploy the DB AI layer (schema COLLECTIONS_AI, via SSM)
./deploy.sh secrets database
#    database stage runs collections_agent/scripts/deploy_ai_layer.sh:
#    KB vector table, 6 reporting views, xx_selectai_pkg, xx_kb_search_pkg, 9 seed docs (verifies VALID)

# 3. One-time: load the in-DB ONNX embedding model + embed the KB
./collections_agent/scripts/load_onnx_model.sh
#    (pulls all_MiniLM_L12_v2.onnx from S3 — 133,322,334 bytes — loads COLL_EMBED_MODEL, embeds 9 docs)

# 4. Deploy AWS infra + Lambda code + the agent runtime + React UI
./deploy.sh infra lambda agent frontend
#    infra   → CFN: S3/CloudFront, Cognito, DynamoDB, WebSocket API+routes, 3 Lambdas, IAM
#    lambda  → Collections Lambda (oracledb) + WebSocket handler
#    agent   → VPC agent runtime Lambda (Strands + tools, large pkg via artifacts bucket)
#    frontend→ React build → S3 → CloudFront invalidate (generates src/aws-config.js from outputs)

# Or all at once:
./deploy.sh        # secrets database infra lambda agent frontend

# 5. (optional) PL/SQL write-back packages on the EBS app server
./collections_agent/scripts/deploy_all_rest_services.sh
```

> **DB prerequisites for the AI layer (post-upgrade, mandatory):** `COMPATIBLE>=23.0.0` +
> `vector_memory_size>0` (enables the VECTOR datatype) and a non-full FRA. See
> `docs/UPGRADE_RUNBOOK.md` Stage 6. Both are one-time and were applied on this clone.

### Deployment Isolation
Deploys with **new or reused 26ai-prefixed resources** in account 339712993582. The original
Redshift/Zero-ETL build and the **19c source** are untouched. Reuse existing 26ai resources where
present (Cognito pool, IAM roles, DynamoDB) rather than recreating; never modify the 19c build.

## Live Deployment State (clone, 2026-06-30)

### Target Environment (verified)
| Item | Value |
|---|---|
| AWS Account | 339712993582 (default CLI credentials, no profile) |
| Region | us-east-1 |
| EBS App Node | i-0be4e60b1cd89c892 (erpapp01 / 10.0.1.194) — ISG REST :8000 / oafm :7601 |
| DB Node | i-0bb4baee0eb31d27f (erpuatdb01 / 10.0.1.13) |
| Database | CDB **CERPUAT**, PDB **ERPUAT** — Oracle **26ai 23.26.2**, NON-Autonomous |
| Gold AMIs | app ami-04e7bf58cdeb311ac, db ami-0f20430614ad06871 (2026-06-30) |

### Important Finding: Non-Autonomous Database
The target is a **non-Autonomous** Oracle 26ai database. The "managed AI" features are
Autonomous Database (ADB) features, NOT Exadata/version features:

| Feature | On ERPUAT | Notes |
|---|---|---|
| AI Vector Search (DBMS_VECTOR) | ✅ present | Engine feature — works natively |
| SELECT AI (DBMS_CLOUD_AI) | manual install | ADB-managed elsewhere; installed manually here |
| Managed MCP endpoint | ❌ absent | ADB-only; use **SQLcl MCP server** (`sql -mcp`) + custom MCP |
| DBMS_CLOUD_AI_AGENT tools | ❌ ADB-only | build a **custom MCP server** for equivalent tools |
| EBS schema (AR/AP/GL/PO) | ✅ present | Real EBS 12.2 data |

### MCP & AI capability strategy (non-Autonomous, EC2)
| Capability | Approach on this clone | Reference |
|---|---|---|
| MCP server | **Built + agent-consumed**: agent spawns **SQLcl 25.2+ MCP server** (`sql -mcp`) locally over stdio (`tools/sqlcl_mcp.py`, `USE_SQLCL_MCP=1`, container image) | [start/manage SQLcl MCP](https://docs.oracle.com/en/database/oracle/sql-developer-command-line/25.2/sqcug/starting-and-managing-sqlcl-mcp-server.html) · [how it works](https://docs.oracle.com/en/database/oracle/sql-developer-command-line/25.2/sqcug/how-sqlcl-mcp-server-works.html) |
| MCP tools (DBMS_CLOUD_AI_AGENT) | **Custom MCP server** exposing equivalent tools (SELECT AI, vector search, ISG write-back) | [DBMS_CLOUD_AI_AGENT ARPLS](https://docs.oracle.com/en/database/oracle/oracle-database/26/arpls/dbms_cloud_ai_agent1.html) · [ADB Select AI Agent](https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/getting-started-select-ai-agent.html) |
| SELECT AI (DBMS_CLOUD_AI) | Manual install + Bedrock credential + EBS_COLLECTIONS profile | [DBMS_CLOUD_AI](https://docs.oracle.com/en/database/oracle/oracle-database/26/arpls/dbms_cloud_ai1.html) |
| JSON Duality Views | Standard 23ai/26ai DDL | [Duality Views guide](https://docs.oracle.com/en/database/oracle/oracle-database/23/jsnvu/) |
| Vector Search + ONNX | Manual ONNX import + vector index | [AI Vector Search guide](https://docs.oracle.com/en/database/oracle/oracle-database/23/vecse/) |
| MongoDB API | ORDS deployment + config | [ORDS](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/) · [MongoDB API](https://docs.oracle.com/en/database/oracle/mongodb-api/mgapi/overview-oracle-database-api-mongodb.html) |

### AgentCore runtime
Uses **Amazon Bedrock AgentCore** (Strands SDK agent) with the **Code Interpreter** tool for chart/
analysis generation, plus tools: `execute_oracle_ai_query` (SELECT AI), `search_knowledge_base`
(vector), `execute_collections_action` (ISG REST write-back), `generate_chart` (Code Interpreter).

### AWS Resources (26ai stack `cash-flow-analytics-26ai` — deployed 2026-06-30; 19c build untouched)
| Resource | Value |
|---|---|
| CloudFront (React UI) | https://d1vj6wa8y41whs.cloudfront.net |
| WebSocket API | wss://y7fd93n4i2.execute-api.us-east-1.amazonaws.com/prod |
| Cognito User Pool / Client | us-east-1_Rw3FcXtxs / 3iua1rvqbhcuj69u5kurg8aet4 |
| Demo login | Customer-provisioned; optional accounts are created by `./deploy.sh rbac` |
| Collections Lambda (VPC) | ebs-collections-26ai (oracledb reads + ISG REST writes) |
| Agent runtime | AgentCore Runtime ebs_collections_agent_26ai (Strands + tools, Sonnet 4.5) |
| WebSocket handler Lambda | ebs-collections-26ai-ws-handler |
| DynamoDB | websocket-connections-26ai |
| S3 frontend | ebs-analytics-frontend-26ai-339712993582 |
| S3 lambda artifacts | ebs-collections-26ai-artifacts-339712993582 |
| AgentCore role | arn:aws:iam::339712993582:role/ebs-collections-26ai-agentcore-role |

### Verified live end-to-end (2026-06-30)
| Path | Result |
|---|---|
| Agent NL→SQL ("total outstanding/overdue") | $1,100,280,237.62 from live EBS ✅ |
| Agent KB ("disputed invoice policy") | retrieved Disputed Invoices SOP via in-DB ONNX vector ✅ |
| Agent write-back (create note / place + release credit hold) | audited APPS package, reversible (hold→N) ✅ |
| Agent Code Interpreter ("bar chart of top 5 overdue") | matplotlib PNG (1424×826) in S3, rendered in chat ✅ |
| WebSocket `dashboard` action | top risk customers (General Technologies $368M, Hilman $289M) ✅ |
| WebSocket `sendMessage` ("top 3 risk customers") | Bedrock NL→SQL → oracledb → live markdown table ✅ |
| In-DB semantic KB search (9 docs, 384-dim) | dispute→SOP 0.59, payment-plan→SOP 0.61 ✅ |

All four agent tools are operational: `execute_oracle_ai_query`, `search_knowledge_base`,
`execute_collections_action` (audited write-back), `generate_chart` (AgentCore Code Interpreter).

### Credentials

Customer passwords are supplied at deployment time through the gitignored `deploy-config.json`.
Runtime application/database credentials are copied to **AWS Secrets Manager**, and application
components retrieve them there. The local configuration file still contains plaintext credentials,
and some prototype deployment scripts interpolate database passwords into SQL*Plus commands sent
through SSM Run Command. Protect and remove the local file as described in the README, and replace
that deployment mechanism with organization-approved secret retrieval, rotation, and audit controls
before production. No live password is published in this document.

| Account | Password |
|---|---|
| APPS / APPLSYS | &lt;set at deploy&gt; |
| APPLSYSPUB | &lt;set at deploy&gt; |
| SYS / SYSTEM / EBS_SYSTEM | &lt;set at deploy&gt; |
| WEBLOGIC | &lt;set at deploy&gt; |
| COLLECTIONS_AI (app schema) | &lt;set at deploy&gt; |


## Cost Comparison

| Resource | Original (monthly) | 26ai (monthly) | Savings |
|---|---|---|---|
| Amazon Redshift (2-node ra3.xlplus) | ~$2,500 | $0 (eliminated) | $2,500 |
| DMS serverless replication | ~$350 | $0 (eliminated) | $350 |
| S3 + CloudFront (frontend) | ~$50 | ~$50 (React) | $0 |
| Cognito | ~$10 | ~$10 | $0 |
| API Gateway WebSocket | ~$20 | ~$20 | $0 |
| WebSocket Lambda | ~$15 | $0 | $15 |
| DynamoDB (connections) | ~$5 | $0 | $5 |
| **Bedrock (Claude + Titan)** | ~$200 | ~$200 | $0 |
| **AgentCore** | ~$50 | ~$50 | $0 |
| **Collections Lambda** | ~$20 | ~$20 | $0 |
| **Total** | **~$3,220** | **~$270** | **~$2,950/mo** |

Oracle 26ai on ODB@AWS is included in the existing Exadata subscription — no additional database licensing cost.

## Performance & Scalability (enterprise concerns)

### Will AI workloads overload the database? (Exadata AI Smart Scan)
On Exadata (ExaDB-D on Oracle Database@AWS), AI Vector Search is automatically accelerated by
**AI Smart Scan** — no code changes. Vector distance computation and top-k filtering are
**offloaded to the Exadata storage cells**, not run on the database nodes; only results return.
This delivers up to **30x faster** vector queries and frees DB-node CPU for OLTP/analytics.
Enhancements include Adaptive Top-K Filtering (up to 4.7x less data to the DB node), distance
projection (up to 24x less data transferred), INT8/BINARY vector formats (4x–32x smaller/faster),
and included columns in IVF indexes (eliminate base-table I/O). The NL→SQL analytics path is
ordinary SQL and benefits from standard Exadata Smart Scan exactly like any EBS report.
- On **EC2 (non-Exadata)** vector search works but distance runs on DB-node CPU (no storage
  offload) — fine for MVP/demo; ExaDB-D is recommended for production scale.
- Refs: [Exadata AI Smart Scan Deep Dive](https://blogs.oracle.com/exadata/post/exadata-ai-smart-scan-deep-dive),
  [Why Use Oracle AI Vector Search?](https://docs.oracle.com/en/database/oracle/oracle-database/26/vecse/why-use-vector-search-instead-other-vector-databases.html)

### Keeping load off production: Active Data Guard standby
The read-only AI workload (SELECT AI analytics + Vector Search/RAG) can run on an **Oracle Active
Data Guard standby** via **Real-Time Query**, so the production primary stays focused on OLTP.
**DML Redirection** transparently routes incidental writes (e.g. chat logging) back to the
primary with full ACID semantics. EBS write-back (holds, notes, dunning) stays on the primary
path via ISG REST. Use **Global Data Services** for lag-/location-aware routing across multiple
standbys, or **Oracle True Cache** for read-only vector offload without a full standby copy.
- Note: this applies to **non-Autonomous / Exadata** Data Guard; *Autonomous* Data Guard standbys
  are not openable for read-only offload.
- Refs: [AI Scalability with Active Data Guard](https://blogs.oracle.com/maa/application-and-ai-scalability-with-oracle-active-data-guard),
  [Autonomous Data Guard Notes](https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-data-guard-notes.html)

See `DETAILED_DESIGN.md` Part I section 7A for the full technical treatment.

## Security

- **Authentication**: Amazon Cognito (React UI) + ISG REST EBS auth for write-back
- **Authorization**: Oracle DB privileges control which tables SELECT AI can access; VPD enforces per-org row-level scoping in the kernel
- **Secrets**: AWS Secrets Manager for DB credentials and API keys
- **Encryption at rest (KMS)**: a customer-managed CMK (`alias/ebs-collections-26ai`, auto-rotation) encrypts the invoice inbox (SSE-KMS), DynamoDB, and all Lambda env vars. Frontend + logging buckets use SSE-S3/AES256 by design (CloudFront OAI origin and the log-delivery sink cannot use SSE-KMS)
- **S3**: all buckets have public-access-block, versioning, and SSL-only policies; server access logging on the frontend + invoice-inbox buckets → central logging bucket
- **Network**: **all five Lambdas** (collections, P2P, extract, agent, WebSocket handler) are VPC-attached to the private subnets — no public internet exposure for the data path
- **Audit**: agent interactions + all Lambda logs in CloudWatch; S3 + CloudFront access logs; DynamoDB point-in-time recovery
- **Data**: analytics SQL executes in-DB; vector embeddings/search run in-DB (ONNX, no egress)

### Role-based access control (agent write actions)

The agent's **write** actions are gated by the signed-in user's role, mirroring the EBS
responsibility model in the AI layer. The LLM is **never** the security boundary — enforcement is
deterministic code on a **server-verified** identity.

- **How identity is trusted:** the browser passes its Cognito **ID token** on the WebSocket
  `$connect`; the handler Lambda **verifies the JWT signature** against the Cognito JWKS and
  persists the derived groups server-side. Per-message claims are never trusted.
- **Mapping (Cognito group → EBS responsibility → allowed actions):**

  | Cognito group | EBS responsibility | Can do |
  |---|---|---|
  | `ar-managers` | AR Collections Manager | AR writes (credit holds, notes, dunning) |
  | `ap-managers` | AP Manager | AP writes (release hold, approve, run import) |
  | `ar-analysts` | AR Enquiry | read-only (queries, charts, KB) |
  | `ap-clerks` | AP read-only | read-only |

- **Enforcement points:** `execute_collections_action` / `execute_p2p_action` (agent tools) and the
  handler-side P2P write actions each call a deterministic check *before* any DB/EBS call. Reads and
  proposal-only actions (`propose_payment`) are open; denied writes return an "escalate to your
  manager" message. **Fail-closed:** no verified identity ⇒ writes denied.
- **Provisioning:** `./deploy.sh rbac` (Cognito groups + demo users) or `rbac-ebs` (also the matching
  EBS `FND_USER` responsibilities). Toggle with the `AUTHZ_ENFORCE` env var.
- **Production identity (roadmap, not wired):** federate the customer IdP (Azure AD / Okta / Oracle
  Access Manager) into Cognito via **SAML/OIDC** — users keep corporate SSO, no user copying. Map the
  federated identity to `custom:ebs_username` so EBS audit columns (`LAST_UPDATED_BY`) show the real
  person instead of the shared service account. Deeper EBS-native options (live
  `FND_USER_RESP_GROUPS` lookups, ISG named grants, MOAC row scoping) are documented in
  `DETAILED_DESIGN.md` Part I §8.1.

### Agent SQL access (SQLcl MCP) — is it safe to let the agent run SQL?

Yes. The agent can *compose* SQL, but the **database enforces the boundary** — the account SQLcl
connects as (`COLLECTIONS_AI`) is **read-only on EBS data and cannot write to it**:

- **No direct DML.** `COLLECTIONS_AI` has **zero INSERT/UPDATE/DELETE grants** on any EBS table
  (verified live). Its object grants are read-only (SELECT/READ) on the AR/AP views + EXECUTE on the
  audited packages. Its system privileges are self-schema DDL only — **no `ANY` privileges, no DBA,
  no roles**. So the worst an injected/erroneous query can do is read data the account is already
  entitled to; it cannot change EBS data.
- **Writes never use free-form SQL.** All EBS mutations go through `execute_collections_action` /
  `execute_p2p_action` → audited `APPS.XX_*_PKG` → EBS public APIs, and are gated by the RBAC check
  above. SQLcl MCP is a separate, read-scoped path that does **not** bypass it.
- **Not network-exposed.** `sql -mcp` runs as a co-located **stdio subprocess** inside the VPC agent
  container — no listening port, no bastion; the DB stays in a private subnet. It authenticates from
  the Secrets Manager credential (KMS-encrypted), and logs its activity to a `SQLCL_MCP` log table.
- **Off by default** (`USE_SQLCL_MCP`); enable only where a governed agent-SQL surface is wanted.
- **Hardening note:** `COLLECTIONS_AI` also holds `ADMINISTER DATABASE TRIGGER`, unused by any
  shipped object — recommend revoking it for least-privilege in customer deployments.

Full privilege table + reviewer Q&A: `DETAILED_DESIGN.md` Part I §5.6 "SQLcl MCP — security posture".

## Technology Stack

| Layer | Technology |
|---|---|
| Frontend | React 18 + recharts + amazon-cognito-identity-js (CloudFront + S3 + Cognito + WebSocket API) |
| Agent Framework | Strands Agents SDK (Python), hosted on Bedrock AgentCore Runtime |
| LLM | Claude Sonnet 4.5 (Amazon Bedrock, `us.anthropic.claude-sonnet-4-5-20250929-v1:0`) |
| NL-to-SQL | boto3 Bedrock (agent) → guard-railed SELECT → `oracledb` on Oracle 26ai |
| Embeddings | in-DB ONNX `all_MiniLM_L12_v2` (384-dim) — no external embedding calls |
| Database | Oracle 26ai 23.26.2 (non-Autonomous, EC2) |
| Vector Search | Oracle AI Vector Search (VECTOR datatype, COSINE) |
| EBS Write-back | ISG REST via custom PL/SQL + iRep (Collections Lambda) |
| Email | Amazon SES |
| Secrets | AWS Secrets Manager |
| IaC | AWS CloudFormation |
| Agent Runtime | Bedrock AgentCore Runtime (VPC-attached; SQLcl MCP + AgentCore Memory bundled) |
| Chart/analysis | Amazon Bedrock AgentCore Code Interpreter (`generate_chart` tool) |
