# Troubleshooting

## `401 Unauthorized` from the Logic App when the agent calls the tool

The Authorization Policy rejected the token. Check the token's claims by copying the raw token from the agent's run history (Foundry portal → agent → runs) and decoding it at [jwt.ms](https://jwt.ms).

| Symptom | Likely cause | Fix |
|---|---|---|
| `iss` mismatch | Tenant ID mismatch or v2 vs v1 endpoint | Standard Logic App triggers use v1 (`sts.windows.net`). Ensure the policy claim uses `https://sts.windows.net/<tenantId>/` with the trailing slash. |
| `aud` mismatch | App registration identifier URI doesn't match | Confirm `az ad app list --display-name prior-auth-api --query "[0].identifierUris"` returns `["api://prior-auth-api"]`. |
| Missing `roles` | Foundry UAMI wasn't granted the app role | Re-run the `az rest` app-role assignment step in `deploy.ps1`. Wait 5–10 minutes for propagation. |
| No `roles` claim ever appears | The app role's `allowedMemberTypes` is `User` only | Must be `Application` (or both). Fix in the app manifest and re-grant. |

## `403 Forbidden` from Entra ID when Foundry tries to acquire a token

- The UAMI doesn't exist in the tenant the Foundry project uses.
- The UAMI wasn't attached to the Foundry project. Confirm with `az cognitiveservices account show --name <foundry> -g <rg> --query identity`.

## Agent doesn't call the tool at all

The model didn't decide to call `check_prior_auth_status`. Check:

1. The tool's **description** matches the user's phrasing pattern. The description in `openapi.yaml` and `create_agent.py` needs to be action-oriented ("Look up the status of a prior authorization by ID and escalate if past SLA").
2. The **operation summary/description** in the OpenAPI spec is clear.
3. The user prompt actually implies calling the tool — try `"What's the status of PA-2026-88421?"` verbatim.

## `Workflow trigger not found` on zip-deploy

Standard Logic Apps expects a specific folder layout inside the zip:

```
<zip root>
├── host.json
├── connections.json
└── <workflow-name>/
    └── workflow.json
```

`scripts/deploy.ps1` produces this structure. If you build the zip manually, double-check the workflow name matches the folder name.

## `The provider Microsoft.Web is not registered` during Bicep deploy

```powershell
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.Logic
az provider register --namespace Microsoft.CognitiveServices
```

## Foundry SDK error: `'PromptAgentDefinition' object has no attribute 'tools'`

You're on an older SDK. Bump `azure-ai-projects` to the version pinned in `agent/requirements.txt` (or later).

## The demo's mock HTTP call to `httpbin.org` is blocked

Corporate proxies often block it. Either:

- Deploy the workflow in a subscription with unfiltered outbound egress, or
- Override the escalation endpoints with parameters when deploying (`-ServiceNowUrl`, `-TeamsWebhookUrl`).

## Model won't call the tool because it hit a content filter

Rename the sample drug names or use non-PHI sample data. The synthetic dataset in this repo already avoids real member identifiers, but some models filter aggressively on medical terms — swap `Ozempic` for `<drug-a>` in the synthetic data if needed.

## The Logic App run succeeded but the agent shows a generic error

Look at the run's Response action output. If it's returning a non-JSON body or a non-200 status, the OpenAPI tool may not be able to parse it. Confirm the Response action's `statusCode` is `200` and the body matches the response schema in `openapi.yaml`.
