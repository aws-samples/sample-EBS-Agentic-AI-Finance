# EBS Agentic AI — Finance (Oracle 26ai)

AI-powered Accounts Receivable **and** Accounts Payable assistant for Oracle E-Business Suite,
built on Oracle Database 26ai (SELECT AI, AI Vector Search) + Amazon Bedrock / Strands on
AgentCore Runtime. One "single pane of glass" React UI over the working-capital cycle:
live NL→SQL analytics, RAG over policy, audited write-back through seeded EBS APIs, invoice
ingest, and a governed agent.

> Full docs: `docs/SOLUTION_OVERVIEW.md`, `docs/DETAILED_DESIGN.md`, `docs/USER_GUIDE.md`,
> `docs/UPGRADE_RUNBOOK.md`, `docs/QUICK_MCP_SETUP.md`.

## What it does

Finance teams on EBS live with two problems: analytics arrive a day late from a nightly ETL
into a data warehouse, and clearing AR collections / AP payables exceptions is manual work that
brittle RPA bots can't handle. This solution puts one AI assistant on **live** EBS that both
**answers** and **acts** across the whole cash cycle:

- **Ask your ERP anything** — natural-language analytics over live EBS data (NL→SQL), no data
  warehouse and no ETL lag.
- **Both halves of working capital** — Collections (AR / cash-in) and an AP Control Tower
  (purchase-to-pay / cash-out) under one app.
- **An agent that acts, not just chats** — it reasons about exceptions and takes *governed*
  actions: place/release a credit hold, send dunning, diagnose a match hold, ingest an invoice —
  always through seeded EBS public APIs, never direct SQL.
- **Grounded and verifiable** — RAG over your policy library (AI Vector Search, in-database),
  plus a live drift check that flags when a written policy disagrees with what EBS actually
  enforces.

### Value proposition

Two things change for a finance team. First, analytics run against **live** EBS instead of a
day-old warehouse copy, so a receivables or payables question is answered from the current ledger,
not last night's extract. Second, the assistant can **act** on the exceptions it surfaces — place
or release a credit hold, send dunning, diagnose a match hold — through EBS's own audited APIs,
so the cases that normally sit in a queue waiting for a human get moved.

The boundary is the ERP's existing security model, not the model's judgment. The agent's database
account is read-only on EBS data, every write goes through a seeded public API, a deterministic
role check runs before any action, and VPD scopes rows by operating unit. Nothing the assistant
does can step outside what EBS already permits for that user.

In the app itself, this maps to who you're signed in as and where you are:

- **You sign in as an EBS role** (Cognito identity mapped to responsibilities like AR Collections
  Manager, AP Manager, or read-only). Your role badge is shown in the top bar, and it decides which
  actions the assistant will actually execute for you — a read-only user can ask anything but can't
  release a hold.
- **You navigate the cash cycle by screen**: *Overview* (the CFO view of cash-in vs cash-out with a
  ranked action plan), *Collections* (AR / cash-in), *AP Control Tower* (purchase-to-pay / cash-out),
  and *Policy* (the documents the agent cites, plus a live drift check against what EBS enforces).
- **The AI Assistant is docked on every screen**, so you can ask about what you're looking at and,
  where your role allows, hand it an action without leaving the view. Actions that change EBS still
  require an explicit human approval step.

It runs on **core EBS only** (no SOA Suite) and deploys as configuration rather than a rebuild, so a
pilot on a customer clone is low-risk and repeatable.

| | |
|---|---|
| **Live, not stale** | Analytics run against live EBS via SELECT AI, so there's no nightly ETL lag and no separate Redshift + DMS warehouse to run (~$2,950/mo in the reference build). |
| **Acts on exceptions** | The agent works the exception cases that RPA hands back to a person, through audited APIs — so throughput isn't capped by screen automation. |
| **AI where the data lives** | SELECT AI (NL→SQL) and AI Vector Search run inside Oracle 26ai; data doesn't leave EBS for analytics, and RAG has no egress. |
| **Governed by design** | The LLM isn't the security boundary: read-only DB grants, a deterministic role check before any write, VPD row security, and every action through seeded EBS packages. |
| **Core EBS, repeatable** | Uses core EBS only (AP_HOLDS_PKG, Payables Open Interface, DBMS_RLS, ISG REST) — no SOA Suite — deployed by a staged, secrets-externalised `deploy.sh`. |

## Architecture

![EBS Agentic AI — two-VPC topology on Oracle 26ai + AWS](docs/assets/architecture-26ai-topology.png)

**Two VPCs, connected over the ODB@AWS network:**

- **Application / AI VPC (left)**
  - React UI on CloudFront / S3 / Cognito
  - WebSocket API + handler Lambda
  - Strands agent on AgentCore Runtime (with SQLcl MCP and AgentCore Memory)
- **EBS / Oracle VPC (right)**
  - Oracle 26ai — reporting views, in-DB ONNX vectors for RAG, VPD row security, audited APPS packages
  - EBS 12.2 app tier exposing ISG REST

**Three layers:**

1. **Reporting views** — deterministic, fast dashboards straight off live EBS
2. **Agent tools** — NL analytics + governed actions
3. **Audited write-back** — through seeded EBS public APIs

> The agent runs on **Bedrock AgentCore Runtime** — a VPC-attached container that reaches the
> private Oracle DB directly, with AgentCore Memory and the SQLcl MCP server.

## Screens

Annotated views of the single-pane UI (callouts label what each area does).

**Working-Capital Overview** — the CFO view of the whole cash cycle: cash-IN (receivables) vs cash-OUT
(payables), an agent-ranked action plan, and the docked AI Assistant on every screen.

![Working-Capital Overview, annotated](docs/assets/ui-overview-annotated.png)

**AP Control Tower (Purchase-to-Pay)** — where invoices get stuck and why: the pipeline blockage view,
blocked-value-by-hold-type, the exception queue, and "Why?" hold diagnosis grounded in policy.
Everything behind the **Why?** button is **read-only and audited**: the agent reconciles invoice vs PO
vs goods-receipt inside Oracle, checks it against your written tolerance policy, and gives a
within-/outside-policy verdict — but a human still has to approve the actual release.

![AP Control Tower, annotated](docs/assets/ui-control-tower-annotated.png)

**Policy library + drift check** — the policies the agent cites, plus a live check that the written
policy still matches the tolerance EBS actually enforces (with one-click **Sync from EBS**).

![Policy library + drift check, annotated](docs/assets/ui-policy-annotated.png)

> More annotated screens and a full per-feature walkthrough: `docs/USER_GUIDE.md`.

## Layout

| Path | What |
|---|---|
| `frontend/` | React single-pane UI (CloudFront/S3/Cognito/WebSocket) + WS handler Lambda |
| `agentcore_version/` | Strands agent, tools, AgentCore runtime + MCP server, Dockerfiles |
| `collections_agent/` | Collections/P2P Lambdas, SQL (views, packages, KB), deploy scripts |
| `knowledge_base/` | Policy / SOP / template source docs + loader |
| `docs/` | Solution overview, detailed design, user guide, runbooks |
| `deploy.sh` | Staged deployer (secrets, db-user, database, onnx, database-p2p, infra, lambda, frontend, rbac, agentcore) |

## Configuration & secrets

**Do not commit customer secrets.** Real environment values live in `deploy-config.json`, which is
**gitignored** (never tracked by git). The repo ships `deploy-config.example.json`, a template whose
customer-specific values are placeholders in the form `<REPLACE_ME>` — copy it and fill in values
from your environment. The repository also contains a demonstration EBS user password in
`collections_agent/sql/XX_RBAC_DEMO_USERS.sql`; change that value before running `rbac-ebs`, as
described below.

> ## Deployment at a glance — do these in order
>
> Deployment is linear. Each item below has full detail further down; follow them top to bottom.
>
> 1. **Prerequisites** — stand up the platform once: EBS 12.2.x, Oracle 26ai on an **SSM-managed EC2**, the VPC/subnets/SG, and the deploy-host toolchain. See [Prerequisites](#prerequisites).
> 2. **Configure** — `cp deploy-config.example.json deploy-config.json` and fill it in (Config Steps 1–2).
> 3. **Deploy everything with one command** — `./deploy.sh`. The default set runs end to end:
>    `secrets → db-user → database → onnx → database-p2p → infra → lambda → frontend → rbac → agentcore`
>    (this pushes secrets, builds the DB + P2P layers, loads the embedding model, deploys the stack/Lambdas/UI,
>    creates your Cognito login, and deploys the agent — no separate scripts to run).
> 4. **Open** the `CloudFrontURL` printed at the end of `./deploy.sh` and sign in as your own
>    email or `demo-manager@example.com`, using the password you configured at `rbac.demo_password`.
>
> Optional add-ons (not required for a working demo): `./deploy.sh database-p2p-sec` (VPD row security),
> `./deploy.sh rbac-ebs` (EBS FND_USER responsibilities), `./deploy.sh quick-mcp` (Amazon Quick).

### Step 1 — create your config

```bash
cp deploy-config.example.json deploy-config.json
```

### Step 2 — replace every `<...>` placeholder with a value from *your* environment

Open `deploy-config.json` and edit the fields below. Anything wrapped in `< >` **must** be replaced;
the non-bracketed values (region defaults, names, ports) can be left as-is unless you have a reason to
change them.

> **Credential-handling warning:** `deploy-config.json` contains plaintext passwords used during
> deployment. It is gitignored, but that alone does not protect it. Restrict file access (for example,
> `chmod 600 deploy-config.json` where supported), keep it out of logs, tickets, chat, email, backups,
> and build artifacts, and securely delete it when it is no longer required. For production, store,
> retrieve, rotate, and audit secrets in accordance with your organization's policies, using an
> approved service such as **AWS Secrets Manager** rather than retaining plaintext configuration.
>
> **Known prototype limitation — address before production:** deployment scripts including
> `collections_agent/scripts/setup_rbac.sh` and `deploy_p2p_security.sh` interpolate APPS/database
> passwords into SQL*Plus command strings sent through SSM Run Command. Those values can be retained
> in SSM command documents/history, local temporary parameter files, process arguments, captured
> output, or logs, and this design makes password rotation difficult. The production implementation
> must retrieve credentials securely at execution time and must verify that credentials are absent
> from command history and logs. Also, before running `./deploy.sh rbac-ebs`, change the demonstration
> `x_unencrypted_password` value in `collections_agent/sql/XX_RBAC_DEMO_USERS.sql` to a unique,
> customer-approved password; the SQL script currently passes that value directly to
> `fnd_user_pkg.createuser`.

**Do not commit `deploy-config.json`.**

| Field (path in JSON) | Replace with | Where to find it |
|---|---|---|
| `aws_account_id` | Your 12-digit AWS account id | `aws sts get-caller-identity --query Account` |
| `aws_region` | Deploy region (default `us-east-1`) | your choice; region must offer the configured Bedrock model |
| `rbac.demo_password` | Unique password for the optional non-production Cognito demo users | you choose it; it must satisfy the Cognito user-pool password policy and must not be reused elsewhere |
| `oracle_26ai.host` | Oracle 26ai DB **private IP** | EC2 console / DBA |
| `oracle_26ai.service_name` | PDB service name (e.g. `ebs_ERPUAT`) | DBA / `lsnrctl services` |
| `oracle_26ai.pdb_name` / `cdb_name` | PDB and CDB names | DBA |
| `oracle_26ai.db_password` | Password for the `COLLECTIONS_AI` DB user | you choose it — `deploy.sh db-user` creates the schema with it |
| `oracle_26ai.app_instance_id` | EBS **app tier** EC2 instance id (`i-…`) | EC2 console |
| `oracle_26ai.db_instance_id` | DB node EC2 instance id (`i-…`) | EC2 console |
| `oracle_26ai.ords_url` | ORDS base URL (swap in the DB private IP) | your ORDS host |
| `oracle_ebs.host` | EBS **app server** private IP | EC2 console / EBS admin |
| `oracle_ebs.apps_password` | EBS `APPS` schema password | EBS admin |
| `oracle_ebs.ebs_system_password` | EBS `SYSTEM` password | EBS admin |
| `oracle_ebs.weblogic_password` | WebLogic admin password | EBS admin |
| `email.ses_sender` | A **verified** SES sender identity | Amazon SES console |
| `email.demo_recipient` | Verified recipient (SES sandbox) | Amazon SES console |
| `bedrock.onnx_s3_uri` | S3 URI where the `onnx` stage stages/loads `all_MiniLM_L12_v2.onnx` | any S3 bucket/key you own; the `onnx` stage auto-stages the model there if absent |
| `chart_bucket` | S3 bucket name for rendered chart PNGs | reuse the artifacts bucket name |
| `vpc.vpc_id` | VPC id (`vpc-…`) reaching the DB + EBS | VPC console |
| `vpc.subnet_ids` | Two **private** subnet ids, comma-separated. ⚠️ **Must be in AgentCore-supported AZs** (`us-east-1`: `use1-az1`/`use1-az2`/`use1-az4`) — see the [AgentCore AZ note](#3-aws-account). | VPC console (different, supported AZs) |
| `vpc.security_group_id` | SG allowing outbound to DB 1521 + EBS 8000 | VPC console |
| `frontend.s3_bucket` | Frontend hosting bucket name | your choice (globally unique) |
| `frontend.logging_bucket` | Central S3 access-log bucket name | your choice (globally unique) |

> Runtime application/database credentials are copied to **AWS Secrets Manager**, and the app and
> Lambdas retrieve them there. Deployment-time scripts also read `deploy-config.json` directly; see
> the credential-handling and SQL*Plus/SSM warning above before considering production use.

### Step 3 — push secrets

```bash
./deploy.sh secrets     # writes DB/EBS passwords into AWS Secrets Manager
```

`frontend/src/aws-config.js` is generated at deploy time from CloudFormation stack outputs (gitignored).

## Deploy — run in this order

Prerequisites (below) must be in place first. Each step is idempotent (safe to re-run).

```bash
# ONE command does it all: secrets, DB + P2P layers, in-DB embedding model, stack, Lambdas,
# UI, Cognito logins, and the AgentCore agent. No separate scripts to run afterwards.
#   Stage order: secrets → db-user → database → onnx → database-p2p → infra → lambda → frontend → rbac → agentcore
./deploy.sh

# When it finishes, deploy.sh prints your CloudFront app URL and demo usernames. Open it and
# sign in with the password configured at rbac.demo_password in deploy-config.json.
```

> The `onnx` stage auto-loads the in-DB embedding model — it even stages the ~133MB model to your
> S3 bucket (`bedrock.onnx_s3_uri`) if it isn't there yet. No manual model upload is needed for a
> fresh install; until it completes, KB search uses keyword fallback.

**Run a single stage** any time, e.g. `./deploy.sh database`, `./deploy.sh frontend`,
`./deploy.sh agentcore` (re-runnable; `database` needs `db-user` to have run first).

## Prerequisites

`deploy.sh` provisions the AWS stack and the `COLLECTIONS_AI` database layer — including **creating
the `COLLECTIONS_AI` schema itself** (the `db-user` stage) using the `db_password` from
`deploy-config.json` — but it assumes the **platform below already exists**. These are environment
prerequisites you (or a DBA / EBS admin) set up once — they are **not** created by the deploy scripts.

### 1. Oracle E-Business Suite 12.2.x (the ERP)
- A running **EBS 12.2.x** instance (this build was validated on 12.2 with the Oracle 26ai database).
- **Integrated SOA Gateway (ISG)** installed and enabled, exposing **REST** on the app tier
  (default `:8000`). This is what the agent's write-back calls (credit holds, notes, dunning, AP
  hold release) go through — no SOA Suite licence is required, ISG is core EBS.
  - The **iRep parser** must be configured (Patch 13602850) so custom PL/SQL can be registered and
    deployed as REST services.
  - Network: the app tier's ISG port must be reachable from the agent's VPC (private path).
- **EBS responsibilities / `FND_USER`s** for the roles you want to demo (AR Collections Manager, AP
  Manager, read-only). `./deploy.sh rbac-ebs` can seed the demo ones, but the responsibilities must
  exist on the instance.

### 2. Oracle Database 26ai (the ERP database, with AI features)
- **Oracle Database 26ai** (23ai/26ai family; validated on **23.26.2**), **non-Autonomous**,
  reachable from the VPC on **1521**. On AWS this is **Oracle Database@AWS (ODB@AWS)** so the DB sits
  next to the workloads on a private link.
- **The DB must run on an EC2 instance that is managed by AWS Systems Manager (SSM).** Every
  database-layer stage (`db-user`, `database`, `database-p2p`, `database-p2p-sec`, `rbac-ebs`, and the
  ONNX model load) executes SQL by shelling into the DB host with `aws ssm send-command` (as the
  `oracle` OS user / `/ as sysdba`) — **not** over SQL\*Net. So the DB EC2 instance
  (`oracle_26ai.db_instance_id`) needs the **SSM Agent running** and an **IAM instance profile with
  `AmazonSSMManagedInstanceCore`**, and must show up under SSM *Fleet Manager → Managed instances*.
  A database without OS/SSM shell access (fully-managed Autonomous, RDS, etc.) **cannot** be
  provisioned by these scripts — they require a shell on the DB host.
- **`COMPATIBLE >= 23.0.0`** and **`vector_memory_size > 0`** (required for AI Vector Search / the
  in-DB ONNX embedding model).

> [!IMPORTANT]
> ### ⚠️ If your EBS DB uses Oracle Net valid node checking, invite the App/AI subnets
>
> The Lambdas and the AgentCore agent connect to Oracle over the network (SQL\*Net, port 1521). If the
> DB's `sqlnet.ora` has `tcp.validnode_checking = yes` (common on EBS), the listener **resets** any
> connection whose source IP isn't in `tcp.invited_nodes`, and the app fails with
> `DPY-4011: … connection reset by peer` even though the security group allows 1521. This is DB-side
> EBS config the deploy scripts intentionally do **not** modify.
>
> Add your two private subnet CIDRs (the `vpc.subnet_ids` — where the Lambdas and agent ENIs live) to
> the invited list — on EBS use the AutoConfig-safe `sqlnet_ifile.ora`, keeping the existing EBS tier
> hosts — then reload the listener:
> ```
> # in $TNS_ADMIN/sqlnet_ifile.ora on the DB host
> tcp.invited_nodes=(<existing EBS hosts>, 10.x.x.0/25, 10.y.y.0/25)
> tcp.validnode_checking = yes
> ```
> ```bash
> lsnrctl reload <LISTENER_NAME>   # required — the running listener won't pick up edits until reloaded
> ```
- **`DBMS_CLOUD` + `DBMS_CLOUD_AI`** installed (under `C##CLOUD$SERVICE`) and an **SSL wallet**
  configured at the CDB root for outbound HTTPS (needed for SELECT AI → Bedrock). See
  `docs/DETAILED_DESIGN.md` troubleshooting for the common `ORA-20000 SSL_WALLET` / `ORA-01435` fixes.
- **(Only for the optional in-DB SELECT AI path)** a DB credential with long-lived IAM `AKIA…` keys
  (not temporary `ASIA…`) for its Bedrock calls. The default agent NL→SQL path uses the runtime's IAM
  role instead, so this is not needed unless you enable in-DB SELECT AI.
- The AR/AP/PO/RCV base schemas must be present (they come with EBS). You do **not** create the
  `COLLECTIONS_AI` schema by hand — `deploy.sh` does it in the `db-user` stage (run as SYSDBA via
  SSM: creates the user, object-creation privileges, SELECT AI package grants, and `SELECT` on the
  AR base tables; AP/PO/RCV/HR grants follow in `database-p2p`). The base schemas only need to
  exist so those `SELECT` grants succeed.

### 3. AWS account
- AWS credentials for the target account (default CLI creds, no `--profile`); **us-east-1**.
- The identity running `deploy.sh` (your CLI credentials, or the **SageMaker notebook's execution
  role** if you deploy from a notebook) needs — in addition to the app-stack permissions
  (CloudFormation, Lambda, S3, IAM `CAPABILITY_NAMED_IAM`, Secrets Manager, ECR, CloudFront, Cognito,
  SES, Bedrock) — permission to **`ssm:SendCommand` and `ssm:GetCommandInvocation`** targeting the DB
  EC2 instance. That is how every database-layer stage runs SQL on the DB host.
- **Amazon Bedrock** — the configured model / inference-profile id (`bedrock.model_id`) must be
  available in the region. On-demand models need **no access request**; IAM permission to invoke is
  granted by the stack roles.
- A **VPC** with private subnets that can reach both the Oracle DB (1521) and the EBS app tier (ISG
  `:8000`), plus the subnet/SG IDs to put in `deploy-config.json`.

> [!IMPORTANT]
> ### ⚠️ AgentCore subnets must be in a supported Availability Zone
>
> **Bedrock AgentCore Runtime is not available in every AZ.** Every subnet you list in
> `vpc.subnet_ids` **must** be in an AgentCore-supported AZ, or the agent deploy fails with:
>
> ```
> Launch failed: Agent endpoint create failed: The following subnets are in unsupported
> availability zones in region us-east-1: subnet-xxxx in us-east-1b (ID: use1-az6).
> Supported availability zones are: use1-az4, use1-az1, use1-az2
> ```
>
> - Match on the **AZ ID** (`use1-az1`, `use1-az2`, …), **not** the AZ name (`us-east-1a`). AZ names
>   are randomized per account; the AZ ID is stable and is what the error reports.
> - **`us-east-1` supported AZ IDs: `use1-az1`, `use1-az2`, `use1-az4`** (the error message lists the
>   current authoritative set — always trust that over this doc).
> - List which of your VPC's subnets are in supported AZs:
>   ```bash
>   aws ec2 describe-subnets --region us-east-1 \
>     --filters "Name=vpc-id,Values=<YOUR_VPC_ID>" \
>     --query "Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,AzId:AvailabilityZoneId,CIDR:CidrBlock}" \
>     --output table
>   ```
> - Use **two** subnets in **different supported AZs** for HA, and make sure they share the same egress
>   (NAT/VPC endpoints for Bedrock/ECR/S3/Secrets/Logs) and can reach the DB. DB reachability itself is
>   governed by the **security group** (`sg-…` allowing 1521), not the subnet CIDR — so changing to a
>   supported-AZ subnet in the same VPC/SG does **not** break DB connectivity.
> - The Lambdas share these same subnets but are **not** AZ-restricted (Lambda runs in all AZs); only
>   the AgentCore agent and Quick MCP runtimes are constrained. Fixing the subnet only requires
>   re-running `./deploy.sh agentcore`.

- **Amazon SES** identity verified for the sender (and, in the SES sandbox, the recipient) if you want
  dunning letters to actually email. See the `email` block in `deploy-config.json`.

### 4. Local toolchain (to run the deploy)
- **AWS CLI v2**, **Python 3.12+**, **Node 18+ / npm** (for the React build), and **Docker** *or* the
  **`agentcore` CLI** (for the AgentCore Runtime image build — the CLI uses CodeBuild, no local Docker).

### Optional / advanced (everything required is already in `./deploy.sh`)

**Embedding model — handled automatically by the `onnx` stage.** No manual upload needed: the stage
stages Oracle's prebuilt ONNX model to your `bedrock.onnx_s3_uri` bucket if it isn't already there,
loads `COLL_EMBED_MODEL`, and embeds the KB. If your deploy host has no internet egress to fetch the
model, pre-stage it once and re-run `./deploy.sh onnx`:
```bash
curl -fsSL -o /tmp/all_MiniLM_L12_v2.onnx \
  https://objectstorage.us-ashburn-1.oraclecloud.com/n/adwc4pm/b/OML-Resources/o/all_MiniLM_L12_v2.onnx
aws s3 cp /tmp/all_MiniLM_L12_v2.onnx s3://<YOUR_ONNX_BUCKET>/onnx/all_MiniLM_L12_v2.onnx  # = bedrock.onnx_s3_uri
```
The model is the full **133,322,334-byte** file — a truncated upload throws `ORA-54401` (the stage
verifies the byte size before loading).

**(Optional) ISG REST write-back** — `./collections_agent/scripts/deploy_all_rest_services.sh` on the
EBS app tier (run as `applmgr`, EBS env sourced; needs iRep Patch 13602850). Only needed with
`USE_ISG_REST_HTTP=1`; the default write path calls the audited APPS packages directly over `oracledb`.

**(Optional) SQLcl MCP** for in-browser governed SQL — turn-key, no separate install. SQLcl 25.2+ is
bundled in the AgentCore image and enabled with `USE_SQLCL_MCP=1` (already set by `./deploy.sh agentcore`).

**(Optional) EBS Finance MCP server for Amazon Quick** — `./deploy.sh quick-mcp` (a second AgentCore
Runtime, MCP protocol + Cognito auth). One manual step a script cannot do: a Quick administrator must
register the MCP endpoint in the Quick console once. Full steps in `docs/QUICK_MCP_SETUP.md`.

> Full step-by-step platform setup and troubleshooting: `docs/DETAILED_DESIGN.md` (sections 6–7).

## Security posture (summary)

- **Secrets**: runtime application/database credentials are KMS-encrypted in AWS Secrets Manager.
  The deployment config remains a sensitive plaintext file, and the prototype SQL*Plus/SSM flows
  require the production remediation described under [Configuration & secrets](#configuration--secrets).
- **Auth**: Cognito + server-verified JWT; **RBAC** on all agent write actions (deterministic code
  check on a verified identity — the LLM is never the security boundary; fail-closed).
- **DB least-privilege**: the agent's DB account is **read-only on EBS data** (no INSERT/UPDATE/DELETE
  grants); all writes go through audited seeded PL/SQL packages → EBS public APIs. Agent SQL (SQLcl
  MCP) is read-scoped and off by default. Full posture: `docs/DETAILED_DESIGN.md` (section 5.6).
- **Network**: **all four Lambdas** (collections, P2P, extract, WebSocket) are VPC-attached to the
  private subnets, and the agent runs on a **VPC-attached AgentCore Runtime**; DB/EBS reached over
  private paths; no public data path.
- **Encryption at rest (KMS)**: a customer-managed CMK (auto-rotation) encrypts the invoice inbox and
  artifacts buckets, DynamoDB, the WebSocket access-log group, the Lambda DLQ, and all Lambda env
  vars. The frontend + central logging buckets use SSE-S3/AES256 by design (CloudFront OAI origin and
  the log-delivery sink cannot use SSE-KMS).
- **S3**: every bucket has public-access-block, versioning, SSL-only bucket policies, and server
  access logging to the central logging bucket (the log sink itself cannot log to itself).
- **Edge**: CloudFront pins TLS 1.2 and is fronted by a WAFv2 WebACL (AWS common + known-bad-inputs /
  Log4Shell rule groups).
- **Resilience**: each Lambda has a dead-letter queue (encrypted SQS) and reserved concurrency.
- **Containers**: the AgentCore images run as a non-root user with a HEALTHCHECK.
- **VPD** row-level security scopes data by operating unit in the DB kernel.

## Notes

- Internal build log (`PROGRESS.md`), IDE/agent config (`.kiro/`), the scratch `tmp/` dir, build
  output, and `.docx` renders are intentionally **not** tracked.
- `.docx` deliverables are regenerated from the `.md` sources with `pandoc <file>.md -o <file>.docx`.
