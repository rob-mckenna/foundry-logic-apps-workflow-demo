# Security model

This demo takes the position that **no shared secrets or SAS keys should be used** to authenticate the Foundry agent to the Logic App. Instead, the agent's Foundry project holds a **user-assigned managed identity (UAMI)** that acquires a Microsoft Entra ID token for a specific audience, and the Logic App's Request trigger validates that token before running.

## Actors

| Actor | Identity | What it can do |
|---|---|---|
| Foundry project | User-assigned managed identity `id-foundry-pademo` | Acquire Entra tokens for `api://prior-auth-api/.default`. Nothing else. |
| Foundry agent | The agent inherits the project's identity when invoking tools. | Call the Logic App workflow. |
| Standard Logic App | Its own system-assigned managed identity (used only if the workflow calls other Azure resources — none in this demo). | N/A for demo. |
| Entra app registration `prior-auth-api` | Represents the workflow's API surface. Owns App Role `PriorAuth.Read`. | Nothing directly. It's an audience + role container. |

## Token contract

The token the Foundry agent presents to the Logic App has these claims:

| Claim | Value | Enforced by |
|---|---|---|
| `iss` | `https://sts.windows.net/<tenant-id>/` | Logic App Authorization Policy |
| `aud` | `api://prior-auth-api` | Logic App Authorization Policy |
| `roles` | contains `PriorAuth.Read` | Logic App Authorization Policy |
| `appid` / `azp` | UAMI client ID | (Available for audit — not enforced by policy in this demo, but a good hardening addition) |

## Enforcement (workflow.json)

```json
"runtimeConfiguration": {
  "triggerAuthenticationPolicy": {
    "authenticationType": "AAD",
    "claims": [
      { "name": "iss",   "value": "https://sts.windows.net/${TENANT_ID}/" },
      { "name": "aud",   "value": "api://prior-auth-api" },
      { "name": "roles", "value": "PriorAuth.Read" }
    ]
  }
}
```

Requests with a missing or non-matching token are rejected by the Logic Apps runtime *before* the workflow starts — no run-history entry, no execution cost.

## Enforcement (Foundry side)

The `OpenApiTool` on the agent is configured with:

```python
from azure.ai.projects.models import (
    OpenApiTool,
    OpenApiManagedAuthDetails,
    OpenApiManagedSecurityScheme,
)

tool = OpenApiTool(
    name="check_prior_auth_status",
    description="Look up the current status of a prior authorization by ID and, if it has breached the 3-business-day SLA, escalate it.",
    spec=openapi_spec_dict,
    auth=OpenApiManagedAuthDetails(
        security_scheme=OpenApiManagedSecurityScheme(
            audience="api://prior-auth-api",
        ),
    ),
)
```

Foundry uses the project's managed identity to acquire a token for that audience at tool-invocation time. No client secret, no client certificate, no key rotation to schedule.

## Provisioning the app registration + role

The `scripts/deploy.ps1` script performs these steps idempotently:

```powershell
# 1. Create the app registration if it doesn't exist
$app = az ad app list --display-name prior-auth-api --query "[0]" | ConvertFrom-Json
if (-not $app) {
    $manifest = @{
        displayName    = "prior-auth-api"
        identifierUris = @("api://prior-auth-api")
        appRoles       = @(@{
            id                  = [Guid]::NewGuid().ToString()
            allowedMemberTypes  = @("Application")
            displayName         = "PriorAuth.Read"
            description         = "Call the check-prior-auth-status workflow"
            value               = "PriorAuth.Read"
            isEnabled           = $true
        })
    }
    # az ad app create ...
}

# 2. Ensure the service principal exists in the tenant
az ad sp create --id $app.appId

# 3. Grant the Foundry UAMI the PriorAuth.Read app role
az rest --method POST `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$foundryMiObjectId/appRoleAssignments" `
    --headers "Content-Type=application/json" `
    --body "{ `"principalId`": `"$foundryMiObjectId`", `"resourceId`": `"$apiSpObjectId`", `"appRoleId`": `"$appRoleId`" }"
```

## What this demo does NOT do (and where to add it)

| Missing hardening | Where to add it | Docs |
|---|---|---|
| Private Endpoint on Logic App | Enable Private Endpoint + DNS zone in `infra/main.bicep` | `docs/vnet-hardening.md` |
| VNet integration for outbound calls | Add `virtualNetworkSubnetId` to the App Service plan / Site config | `docs/vnet-hardening.md` |
| Customer-managed keys | Wrap Storage account + Logic App runtime encryption with Key Vault CMK | Not covered — production step |
| Separate write role (`PriorAuth.Escalate`) | Add second app role, move HTTP-POST actions behind a role-gated child workflow | Not covered — production step |
| PHI abuse-monitoring opt-out on the model | Coordinated with Microsoft account team | Not covered — process step |
| Log Analytics + long-term audit retention | Diagnostic settings on Logic App to a Log Analytics workspace | Not covered — production step |

## Rotating things

Because the demo uses no secrets, rotation is limited to:

- **UAMI client ID** — stable for the life of the UAMI. If you rebuild the UAMI, re-grant the app role assignment.
- **App registration `prior-auth-api`** — App ID URI (`api://prior-auth-api`) is stable. The App Role's GUID must be re-referenced only if you rebuild the app registration.
- **Foundry project endpoint** — only changes if the project is rebuilt.

No client secrets, no certificates, no SAS keys means nothing expires in this demo's happy path.
