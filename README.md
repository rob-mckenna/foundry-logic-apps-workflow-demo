# foundry-logic-apps-workflow-demo

Demonstrates how to expose an **Azure Logic Apps workflow** as a tool for a **Microsoft Foundry Agent Service** agent, using **Microsoft Entra ID (AAD)** authentication end-to-end (no SAS keys, no shared secrets).

The demo scenario is a **healthcare payer / pharmacy-benefit-manager (PBM)** prior-authorization (PA) status check with automatic SLA-based escalation — a workflow that a pharmacist or care coordinator can invoke conversationally through the Foundry agent.

> **Disclaimer.** This repo uses fully **synthetic data**. It is a technical demonstration — not a production system, not HIPAA-certified, and not affiliated with any specific payer, PBM, or Microsoft. See [`docs/healthcare-scenario.md`](docs/healthcare-scenario.md) for what would change to productionize.

## Two deployment variants

The repo ships **two** Logic App variants to support different hosting and governance requirements. Enterprise Azure environments may enforce storage controls that affect connection-string-based or public-endpoint Standard-plan configurations. See [`docs/sfi-tenant-notes.md`](docs/sfi-tenant-notes.md) for policy considerations.

| Variant | File | When to use | Storage policy considerations |
|---|---|---|---|
| **Consumption Logic App** (recommended demo path) | [`infra/main-consumption.bicep`](infra/main-consumption.bicep) | Fastest path to a live demo. Multitenant runtime with Microsoft-managed storage. | No customer-managed runtime storage account; other organizational policies still apply. |
| **Standard Logic App (WS1)** (production-shaped) | [`infra/main.bicep`](infra/main.bicep) + [`workflows/prior-auth-status-check/`](workflows/prior-auth-status-check) | Single-tenant hosting with additional storage and networking considerations (see [`docs/vnet-hardening.md`](docs/vnet-hardening.md)). | When shared-key authentication and public storage access are disabled, requires **identity-based storage** and **VNet integration + Private Endpoint**. |

**Both variants** share the same Foundry agent, the same OpenAPI tool contract, and the same Microsoft Entra ID app registration (`prior-auth-api` with app role `PriorAuth.Read`). Only the Logic App hosting model differs.

## What it shows

- An Azure Logic Apps workflow whose **Request trigger is protected by an Entra ID Authorization Policy** (`iss` + `aud` claims) — no SAS-key URL.
- A **Microsoft Foundry agent** using the **OpenAPI tool** with `managed_identity` auth to invoke the workflow.
- A dedicated **Entra ID app registration** (`prior-auth-api`, identifier URI `api://<appId>`) that represents the workflow's API surface and exposes an app role (`PriorAuth.Read`) granted to the Foundry project's user-assigned managed identity.
- Multi-step orchestration: lookup → SLA branch → optional escalation to a mock ticketing system and reviewer notification.

## Architecture

```
User → Foundry Agent (gpt-5-mini)
         │  OpenApiTool (auth = managed_identity, audience = api://<appId>)
         ▼
Foundry Project (user-assigned Managed Identity)
         │  Acquires Entra ID token
         ▼
Logic App workflow: check-prior-auth-status
   ├─ Trigger authorization: iss + aud claims validated
   ├─ Lookup PA in synthetic dataset
   ├─ Compute businessDaysOutstanding
   ├─ Condition: status == "Pending" AND days > 3
   │     ├─ True  → POST mock ServiceNow incident + notify reviewer
   │     └─ False → skip
   └─ Response → summary JSON
```

Full narrative and Mermaid diagram: [`docs/architecture.md`](docs/architecture.md).

## Repository layout

```
.
├── docs/                          Design and how-to docs
│   ├── architecture.md
│   ├── walkthrough.md            Deploy → register → chat, end-to-end
│   ├── healthcare-scenario.md    Business framing + productionization notes
│   ├── security.md               Token flow, roles, MI, Authorization Policy details
│   ├── sfi-tenant-notes.md       Enterprise storage policy considerations and deployment implications
│   ├── vnet-hardening.md         Private Endpoint + VNet integration (needed for Standard LA when public storage access is disabled)
│   └── troubleshooting.md
├── infra/                         Bicep infrastructure
│   ├── main.bicep                Standard LA variant (WS1) — Storage + Plan + Site + UAMI + LAW
│   ├── main-consumption.bicep    Consumption LA variant — single Microsoft.Logic/workflows resource
│   └── parameters.example.json
├── workflows/prior-auth-status-check/
│   ├── workflow.json             Standard schema (with triggerAuthenticationPolicy)
│   ├── host.json                 Runtime config (Standard only)
│   ├── connections.json          Empty — no managed connectors
│   ├── trigger-schema.json       Request body JSON schema
│   ├── openapi.yaml              OpenAPI 3.1 (Standard LA URL template)
│   └── sample-payloads/
├── agent/                         Python client that creates and runs the Foundry agent
│   ├── requirements.txt
│   ├── .env.example
│   ├── create_agent.py           Register OpenApiTool + create agent
│   ├── run_agent.py              Interactive REPL against the agent
│   ├── smoke_test.py             One-shot end-to-end test
│   ├── demo_run.py               Cycle through all 5 demo scenarios
│   ├── inspect_agent.py          Print current agent versions + tool URLs
│   ├── demo_prompts.md           Canned prompts for a live demo
│   ├── openapi.deployed.yaml     (Generated at deploy time — Consumption LA endpoint)
│   └── cleanup.py
├── scripts/
│   ├── deploy.ps1                Standard LA deploy: Bicep + Entra app + role grant + zip deploy
│   └── generate-openapi.ps1      Emit openapi.yaml from trigger-schema.json
├── .github/workflows/ci.yml
├── LICENSE                        MIT
└── README.md
```

## Prerequisites

- Azure subscription with **Owner** on the target resource group.
- Microsoft Foundry project (new Foundry Agent Service — not Foundry classic).
- **Model deployment**: `gpt-4.1` recommended (verified OpenAPI tool support in Foundry portal). `gpt-4o`, `gpt-4.1-mini`, and `gpt-5` family also work. `gpt-5-mini` functions via SDK but the Foundry portal flags it as "Not supported by the selected model" for OpenAPI tools.
- Local tooling: Azure CLI ≥ `2.63`, Bicep, PowerShell 7, Python 3.10+.

## Quick start — Consumption variant (recommended)

```powershell
# 1. Grant this deployment's UAMI the PriorAuth.Read app role on prior-auth-api,
#    patch the Foundry project with the UAMI, then deploy the Consumption LA.
./scripts/deploy-consumption.ps1 `
    -SubscriptionId <sub-id> `
    -ResourceGroupName rg-foundry-pademo `
    -Location eastus2 `
    -FoundryProjectResourceId /subscriptions/.../accounts/<foundry>/projects/<project> `
    -EnvironmentName pademo01

# 2. Register the agent
cd agent
python -m venv .venv; . .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env      # edit with values from deploy output
python create_agent.py

# 3. Chat with it
python run_agent.py

# 4. Verify all 5 scenarios
python demo_run.py

# 5. Tear down
python -c "from azure.ai.projects import AIProjectClient; from azure.identity import DefaultAzureCredential; import os; from dotenv import load_dotenv; load_dotenv(); AIProjectClient(endpoint=os.environ['FOUNDRY_PROJECT_ENDPOINT'], credential=DefaultAzureCredential()).agents.delete(agent_name=os.environ['AGENT_NAME'])"
az group delete -n rg-foundry-pademo -y
```

Detailed walkthrough: [`docs/walkthrough.md`](docs/walkthrough.md).

## Why the new Foundry Agent Service (and not Foundry classic)

The classic `Add Logic App action` wizard ([MS Learn](https://learn.microsoft.com/en-us/azure/logic-apps/add-agent-action-create-run-workflow)) targets **Foundry classic agents, which retire March 31, 2027**. The new Foundry Agent Service does not carry that wizard forward. Instead, Logic Apps workflows are surfaced through the generic **OpenAPI tool** (or Foundry Toolbox / MCP for multi-agent sharing), which is the go-forward pattern.

## License

[MIT](LICENSE).
