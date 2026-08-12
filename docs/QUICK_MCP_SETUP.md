# Amazon Quick — MCP Integration Setup Guide

This guide connects **Amazon Quick** to the EBS Finance solution so Quick's agents and
automations can query the ERP, pull the working-capital action plan into an email or Slack
digest, and turn emailed/Slack'd invoice attachments into EBS invoices.

It has two parts:
1. **Deploy the MCP server** (scripted — `./deploy.sh quick-mcp`).
2. **Connect Amazon Quick** to that server (manual — done once in the Quick console, because
   Quick is a customer-side, licensed SaaS product with its own tenant, connectors and admin
   consent; it cannot be provisioned by our CloudFormation stack).

---

## What this integration is (and is not)

The solution exposes a small set of **governed ERP tools** as a Model Context Protocol (MCP)
server hosted on Amazon Bedrock AgentCore Runtime. Amazon Quick includes an **MCP client**: you
register the server endpoint once, Quick discovers the tools, and Quick's agents/automations can
then invoke them using your own Quick authentication and governance.

Tools exposed (each becomes a Quick "action"):

| MCP tool | Type | What it does |
|---|---|---|
| `query_ebs_finance` | read | NL → governed SELECT over live AR/AP reporting views |
| `search_finance_knowledge_base` | read | Semantic search over policies / SOPs / dunning templates |
| `get_ap_invoice_exceptions` | read | The AP exception queue (held / mismatched invoices) |
| `get_working_capital_action_plan` | read | Ranked highest-value AR + AP next moves |
| `predict_customer_payment` | read | Which customers are likely to pay late |
| `get_invoice_review_queue` | read | Low-confidence ingested invoices awaiting human review |
| `create_ap_note` | write (audited) | Attach an audited note to an AP invoice |
| `submit_invoice_to_inbox` | capture | Drop an invoice file into the AP capture inbox (S3) |

**Boundaries (honest):**
- All writes stay on the solution's audited, seeded-API path (the same Oracle PL/SQL packages the
  in-app assistant uses). Nothing here does direct DML, and no tool pays or approves an invoice.
- `submit_invoice_to_inbox` only **stages** a document into the existing capture pipeline
  (extract → anomaly check → seeded Payables Open Interface, or the human review queue). It is the
  Quick equivalent of the in-app drag-and-drop upload — a capture channel in front of a pipeline
  that already exists, not a new pipeline.
- **Quick's own connectors** (Outlook / Gmail / Slack / SharePoint), its **subscription/licensing**,
  and its **scheduled automations** live entirely inside the customer's Quick tenant. Those are
  configured in the Quick console (below), not deployed by this repo.

---

## Use cases this enables

- **Email/Slack an invoice → EBS.** A Quick automation watching an invoice mailbox or Slack channel
  takes the attachment, calls `submit_invoice_to_inbox`, and the existing pipeline processes it. Low
  confidence lands in the review queue; clean invoices stage to Payables Open Interface.
- **Scheduled working-capital digest.** "Every weekday 8am, call `get_working_capital_action_plan`
  and `get_ap_invoice_exceptions`, summarise, and email the AP manager / post to Slack."
- **Conversational ERP in Quick chat.** Users ask "what's our overdue total?" or "which vendors have
  the most invoices on hold?" in Quick and get a live answer via `query_ebs_finance`.

> The scheduler/automation logic (cron, mailbox monitoring, routing) is authored **in Quick**. The
> solution provides the **tools**; Quick provides the orchestration.

---

## Prerequisites

- The core solution is deployed (`./deploy.sh infra` has created the Cognito pool, the
  `QuickMcp*` auth resources, the MCP runtime role, and the S3 invoice inbox).
- An **Amazon Quick Enterprise** subscription (required for MCP integrations).
- The `agentcore` CLI available where you run the deploy
  (`pip install bedrock-agentcore-starter-toolkit`).
- The Oracle DB security group allows inbound 1521 from the AgentCore runtime ENIs (same VPC/subnets
  as the agent runtime).
- Bedrock model access enabled in-account for the configured model (used by `query_ebs_finance`).

---

## Part 1 — Deploy the MCP server (scripted)

```bash
# One-time (or after infra changes): ensure the CFN stack has the QuickMcp* resources
./deploy.sh infra

# Deploy the EBS Finance MCP server to AgentCore Runtime (--protocol MCP, Cognito JWT auth)
./deploy.sh quick-mcp
```

`quick-mcp` builds `agentcore_version/mcp_server.py` (via `Dockerfile.mcp` /
`requirements-mcp.txt`) on CodeBuild (ARM64), pushes to ECR, and launches an AgentCore Runtime
named `ebs_finance_mcp_26ai` with:
- **inbound auth** = Cognito JWT (the `QuickMcpClient` client-credentials app client from the stack),
- **VPC** attachment (to reach the private Oracle DB on 1521),
- env for the DB secret, Bedrock model, and the S3 invoice inbox.

When it finishes, note the **runtime ARN** it prints. The MCP endpoint Quick connects to is:

```
https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<URL-encoded-runtime-arn>/invocations?qualifier=DEFAULT
```

Collect the four auth values from the stack outputs:

```bash
aws cloudformation describe-stacks --stack-name cash-flow-analytics-26ai --region us-east-1 \
  --query 'Stacks[0].Outputs[?starts_with(OutputKey,`QuickMcp`)].[OutputKey,OutputValue]' --output table
```

You'll get:
- `QuickMcpClientId` — the OAuth client ID
- `QuickMcpTokenUrl` — the Cognito `/oauth2/token` endpoint
- `QuickMcpScope` — `ebs-finance-mcp/invoke`
- `QuickMcpDiscoveryUrl` — the OIDC discovery URL (AgentCore uses this to validate the token)

Get the client **secret** (not exported by CloudFormation, by design):

```bash
POOL_ID=$(aws cloudformation describe-stacks --stack-name cash-flow-analytics-26ai --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name cash-flow-analytics-26ai --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`QuickMcpClientId`].OutputValue' --output text)
aws cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" \
  --region us-east-1 --query 'UserPoolClient.ClientSecret' --output text
```

---

## Part 2 — Connect Amazon Quick (manual, in the Quick console)

Because Quick is a licensed SaaS workspace tied to the customer's own identity and connectors,
this step is done once by a Quick administrator in the console. It is not automatable from this repo.

> These steps were validated end-to-end against Amazon Quick Suite (Enterprise). Console labels can
> vary slightly by Quick version; the flow (create connector → discover tools → attach the connector
> to a space or chat agent → chat) is the same.

### Step 2a — Create the MCP connector

1. In the **Amazon Quick console**, choose **Connectors** (Data → Connectors).
2. Choose the **Create for your team** tab, then find and choose **Model Context Protocol (MCP)**.
3. On **Connect** (page 1 of the wizard), enter:
   - **Name** — e.g. `EBS Finance 26ai`.
   - **MCP server endpoint** — the runtime invocations URL from Part 1.
   - **Connection type / VPC connection for resource** — **Public network** (the AgentCore endpoint
     is public; the runtime itself reaches the private DB over its VPC ENIs). If your security
     posture requires a private path, use a Quick **VPC connection** — note the Cognito OAuth
     endpoints must still be reachable over the public internet (they are, being standard Cognito URLs).
4. On **Authenticate** (page 2), select **Service authentication (Service-to-Service)** and enter:
   - **Client ID** — `QuickMcpClientId` (Part 1)
   - **Client Secret** — the secret retrieved in Part 1
   - **Token URL** — `QuickMcpTokenUrl` (Part 1)
5. On **Manage Tools & Permissions** (page 3), Quick shows the discovered tools, grouped into
   **Write Operations** (create_ap_note, predict_customer_payment, query_ebs_finance,
   submit_invoice_to_inbox) and **Read Operations** (get_ap_invoice_exceptions,
   get_invoice_review_queue, get_working_capital_action_plan, …) — **8 tools total**.
   - **There is no per-tool enable toggle in this version** — discovered tools are auto-registered.
     This page is a read-only confirmation of what the connector exposes. That is expected; you do
     not need to switch anything on here.
6. Choose **Update** (or **Create and continue**) to save the connector. Its status shows **Ready**.
7. (Optional) **Try it** (top-right of the connector page) runs an action directly against the
   connector — the fastest confirmation the tools actually execute, with no agent setup.

### Step 2b — Make the actions usable in chat (attach them to a Space or chat agent)

Discovery only *registers* the tools; to call them in a conversation they must be in a chat's
resource scope. There are three ways, easiest first:

- **Option A — a Space (validated, recommended).** Create a **Space** (Spaces → new), then in the
  left menu open **Actions** → **Add knowledge / Add action** → select **EBS Finance 26ai**. The
  action shows **Ready**. Chat from that space's panel — the space's actions are in scope, so the
  assistant will call them. (You can rename the space, e.g. "EBS Finance 26ai", and **Share** it.)
- **Option B — a custom chat agent.** Chat agents → **Create chat agent** → add an **Actions /
  action connector** = **EBS Finance 26ai**, save, then **Launch chat agent**. Best for a repeatable
  demo because the actions are pinned to the agent regardless of which data source is selected.
- **Option C — the system assistant ("My assistant").** It is *unopinionated*: if no data source is
  selected it can use any action you have access to. In the chat box, use the resource selector
  (icon next to the "+") to include **EBS Finance 26ai**, then ask. Note: if you narrow the chat to a
  specific dashboard/topic/dataset, Quick removes actions from scope — so keep actions selected.

> **Saving:** Quick **auto-saves** the connector, the space, and its attached action — there is no
> explicit save button. The space/connector reappears under **Spaces** / **Connectors** next session.

### Sample prompts to verify (validated)

- "What is our total outstanding and overdue?" → returns Total Outstanding / Total Overdue with a
  "Model Context Protocol — query_ebs_finance submitted" badge (proves the MCP call ran).
- "Show me the AP invoice exceptions and summarise the top 5 by value."
- "Give me the working-capital action plan and draft an email to the AP manager."
- "Here is an invoice PDF — submit it to the EBS capture inbox." (attach a file)

### Example automation (authored in Quick)

> Monitor the *AP Invoices* mailbox. When an email with an invoice attachment arrives, call
> `submit_invoice_to_inbox` with the attachment. Then reply to the sender confirming the invoice was
> received and is being processed. Once a day, call `get_invoice_review_queue` and email me anything
> awaiting review.

---

## Troubleshooting

- **Connector passes discovery but fails at publish** — a tool `inputSchema` isn't JSON Schema
  Draft 7. FastMCP (used here) emits Draft 7 with `required` as an array, so this shouldn't occur;
  if you add tools, keep type hints clean.
- **401 / auth failures** — confirm the client ID/secret/token URL match the stack outputs and that
  the app client has the `ebs-finance-mcp/invoke` scope and the `client_credentials` flow enabled.
- **Tool calls time out** — Quick enforces a 60s per-operation timeout. The read tools return well
  inside that; if the DB is cold, retry once.
- **No data / DB errors** — confirm the DB SG allows 1521 from the runtime ENIs and the Oracle
  secret is correct (same checks as the agent runtime).
- **Tool list looks stale after you change the server** — Quick caches the tool list at registration;
  delete and recreate the integration to re-discover.
- **"Manage Tools & Permissions" shows the tools but has no enable/toggle** — expected in current
  Quick versions; discovered tools are auto-registered. Just choose **Update** and continue.
- **Tools discovered but the assistant won't call them in chat** — the connector alone isn't enough;
  the actions must be in the chat's resource scope. Attach the connector to a **Space** or a **custom
  chat agent** (Step 2b, Options A/B), or select it via the chat resource picker (Option C). If you
  focused the chat on a dashboard/topic/dataset, actions drop out of scope — re-select the actions.

---

## Back-out

The integration is fully reversible and isolated:
- **In Quick**: delete the MCP integration (Connectors → Manage).
- **In AWS**: delete the AgentCore runtime `ebs_finance_mcp_26ai` (`agentcore destroy` in
  `agentcore_version/`, or the console). The `QuickMcp*` Cognito resources and MCP role are part of
  the CFN stack and can be left in place (they're inert without the runtime) or removed by a stack
  update. None of this touches the agent runtime, the Lambdas, the DB packages, or the UI.
