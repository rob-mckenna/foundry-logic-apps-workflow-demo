# End-to-end walkthrough

This guide takes you from an empty subscription to a working conversational agent.

## 0. Assumptions

You have:

- Azure CLI signed in (`az login`) with **Owner** on the target resource group scope.
- A **Microsoft Foundry project** in the same tenant. Note its resource ID:

    ```
    /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>
    ```

    Find it in the Foundry portal → project → Overview → JSON view, or via `az cognitiveservices account list`.

- A tool-capable model deployed in that project (this repo assumes `gpt-4.1-mini`).

## 1. Deploy infrastructure

```powershell
./scripts/deploy.ps1 `
    -SubscriptionId 00000000-0000-0000-0000-000000000000 `
    -ResourceGroupName rg-foundry-pademo `
    -Location eastus2 `
    -FoundryProjectResourceId /subscriptions/.../accounts/foundry-x/projects/proj-y `
    -EnvironmentName pademo01
```

What the script does, in order:

1. Creates the resource group if it doesn't exist.
2. Runs `infra/main.bicep` to provision:
    - Storage account (Standard Logic App backing)
    - App Service plan, `WS1` SKU
    - Standard Logic App resource
    - User-assigned managed identity `id-foundry-<env>`
    - Attaches the UAMI to the Foundry project
    - Log Analytics workspace + diagnostic settings on the Logic App
3. Creates (or reuses) an Entra app registration `prior-auth-api`:
    - Identifier URI `api://prior-auth-api`
    - App Role `PriorAuth.Read` (Application-only)
4. Grants the UAMI the `PriorAuth.Read` app role on `prior-auth-api`.
5. Substitutes the tenant ID into `workflows/prior-auth-status-check/workflow.json`'s `triggerAuthenticationPolicy` claims.
6. Zip-deploys the workflow bundle (`workflow.json` + `host.json` + `connections.json`) to the Standard Logic App.
7. Generates `openapi.yaml` with the correct `servers.url` (your Logic App's default hostname).
8. Prints the values you'll need for `.env`:
    - `FOUNDRY_PROJECT_ENDPOINT`
    - `MODEL_DEPLOYMENT_NAME` (defaulted, edit if different)
    - `TENANT_ID`
    - `AUDIENCE` (`api://prior-auth-api`)
    - `LOGIC_APP_HOSTNAME`

## 2. Register the agent

```powershell
cd agent
python -m venv .venv
. .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

Copy-Item .env.example .env
# Edit .env with values printed by deploy.ps1

python create_agent.py
```

This:

- Loads the workflow's `openapi.yaml`.
- Creates a `PromptAgentDefinition` named `prior-auth-assistant`.
- Attaches an `OpenApiTool` (`check_prior_auth_status`) with `managed_identity` auth pointing at `api://prior-auth-api`.
- Prints the created agent name.

## 3. Chat with it

```powershell
python run_agent.py
```

`run_agent.py` opens a REPL against the agent. Try:

```
> What's the status of PA-2026-88421?
```

Expected behavior:

1. The agent decides to call `check_prior_auth_status` with `{ "priorAuthId": "PA-2026-88421" }`.
2. Foundry fetches a token (audience `api://prior-auth-api`) with the UAMI.
3. The Logic App validates the token via its Authorization Policy.
4. The workflow finds PA-2026-88421 in the synthetic dataset (5 business days pending), enters the escalation branch, POSTs a mock ticket (to `httpbin.org` unless you overrode the Teams webhook URL), and returns a summary.
5. The agent narrates the summary.

More prompts in [`agent/demo_prompts.md`](../agent/demo_prompts.md).

## 4. Inspect a workflow run

In the Azure portal, open the Logic App resource → **Workflows** → `check-prior-auth-status` → **Run history**. Each agent turn that calls the tool creates a run. Open one to see inputs, action-by-action outputs, and the token claims (visible in the trigger's `Show raw inputs` view).

## 5. Cleanup

```powershell
cd agent
python cleanup.py           # Deletes the agent version
az group delete -n rg-foundry-pademo -y
```

You may also want to delete the Entra app registration if you won't reuse it:

```powershell
az ad app delete --id (az ad app list --display-name prior-auth-api --query "[0].appId" -o tsv)
```

## Common gotchas

See [`troubleshooting.md`](troubleshooting.md).
