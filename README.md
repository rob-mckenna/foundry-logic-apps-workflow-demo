# foundry-logic-apps-workflow-demo

Demonstrates how to expose a **Standard Azure Logic Apps workflow** as a tool for a **Microsoft Foundry Agent Service** agent, using **Microsoft Entra managed identity** authentication end-to-end (no SAS keys, no shared secrets).

The demo scenario is a **healthcare payer / pharmacy-benefit-manager (PBM)** prior-authorization (PA) status check with automatic SLA-based escalation — a workflow that a pharmacist or care coordinator can invoke conversationally through the Foundry agent.

> **Disclaimer.** This repo uses fully **synthetic data**. It is a technical demonstration — not a production system, not HIPAA-certified, and not affiliated with any specific payer, PBM, or Microsoft. See [`docs/healthcare-scenario.md`](docs/healthcare-scenario.md) for what would change to productionize.

## What it shows

- A **Standard Logic App (WS1)** workflow with a Request trigger secured by a **per-trigger Azure AD Authorization Policy** (no SAS-key URL).
- A **Microsoft Foundry agent** using the **OpenAPI tool** with `managed_identity` auth to invoke the workflow.
- A dedicated **Entra ID app registration** (`prior-auth-api`) that represents the Logic App's API surface and exposes an app role (`PriorAuth.Read`) which is granted to the Foundry project's user-assigned managed identity.
- Multi-step orchestration: lookup → SLA branch → optional escalation to a mock ticketing system and reviewer notification.

## Architecture

```
User → Foundry Agent (gpt-4.1-mini)
         │  OpenApiTool (auth = managed_identity, audience = api://prior-auth-api)
         ▼
Foundry Project (user-assigned Managed Identity)
         │  Acquires Entra ID token
         ▼
Standard Logic App (WS1) — workflow: check-prior-auth-status
   ├─ Request trigger with Authorization Policy
   │     • iss  = https://sts.windows.net/<tenantId>/
   │     • aud  = api://prior-auth-api
   │     • roles contains "PriorAuth.Read"
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
│   ├── vnet-hardening.md         Optional Private Endpoint + VNet integration
│   └── troubleshooting.md
├── infra/                         Bicep infrastructure
│   ├── main.bicep                Storage + App Service plan (WS1) + Standard Logic App + UAMI + RBAC
│   └── parameters.example.json
├── workflows/prior-auth-status-check/
│   ├── workflow.json             Standard Logic Apps workflow (with triggerAuthenticationPolicy)
│   ├── host.json                 Runtime config
│   ├── connections.json          Empty — this workflow uses no managed connectors
│   ├── trigger-schema.json       Request body JSON schema
│   ├── openapi.yaml              OpenAPI 3.1 spec for the workflow (oauth2 clientCredentials)
│   └── sample-payloads/          Example inputs the agent might synthesize
├── agent/                         Python client that creates and runs the Foundry agent
│   ├── requirements.txt
│   ├── .env.example
│   ├── create_agent.py           Register OpenApiTool + create agent
│   ├── run_agent.py              Interactive REPL against the agent
│   ├── demo_prompts.md           Canned prompts for a live demo
│   └── cleanup.py
├── scripts/
│   ├── deploy.ps1                End-to-end deploy: Bicep + Entra app + role grant + zip deploy
│   └── generate-openapi.ps1      Emit openapi.yaml from trigger-schema.json
├── .github/workflows/ci.yml       Bicep build + Python lint
├── LICENSE                        MIT
└── README.md
```

## Prerequisites

- Azure subscription with **Owner** on the target resource group (needed for RBAC + Entra app registration + role assignments).
- Microsoft Foundry project (new Foundry Agent Service — not Foundry classic).
- Tool-capable model deployed in the project (e.g. `gpt-4.1-mini`, `gpt-4o`, or a `gpt-5`-family model).
- Local tooling:
    - Azure CLI ≥ `2.63`
    - Bicep CLI (bundled with `az`)
    - PowerShell 7
    - Python 3.10+
    - `gh` (optional)

## Quick start

```powershell
# 1. Deploy infrastructure, Entra app, role assignment, and workflow
./scripts/deploy.ps1 `
    -SubscriptionId <sub-id> `
    -ResourceGroupName rg-foundry-pademo `
    -Location eastus2 `
    -FoundryProjectResourceId /subscriptions/.../accounts/<foundry>/projects/<project> `
    -EnvironmentName pademo01

# 2. Register the agent
cd agent
python -m venv .venv; . .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env      # then edit .env with values from deploy output
python create_agent.py

# 3. Chat with it
python run_agent.py

# 4. Tear down
python cleanup.py
az group delete -n rg-foundry-pademo -y
```

Detailed step-by-step: [`docs/walkthrough.md`](docs/walkthrough.md).

## Why the new Foundry Agent Service (and not Foundry classic)

The classic `Add Logic App action` wizard ([MS Learn](https://learn.microsoft.com/en-us/azure/logic-apps/add-agent-action-create-run-workflow)) targets **Foundry classic agents, which retire March 31, 2027**. The new Foundry Agent Service does not carry that wizard forward. Instead, Logic Apps workflows are surfaced through the generic **OpenAPI tool** (or Foundry Toolbox / MCP for multi-agent sharing), which is the go-forward pattern. This repo uses that pattern.

## License

[MIT](LICENSE).
