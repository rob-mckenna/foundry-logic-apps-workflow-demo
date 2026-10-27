# Deploying in policy-governed Azure environments

## Why there are two variants

Enterprise Azure environments may enforce Azure Policies that disable storage shared-key authentication or restrict public network access. These controls can affect Standard-plan Logic Apps deployments that use connection-string-based storage or public storage endpoints. Policy names, assignment scopes, effects, and exemption processes vary by organization.

| Storage control | Effective setting | Impact on Standard LA |
|---|---|---|
| Shared-key authentication disabled | `allowSharedKeyAccess=false` | Prevents shared-key authentication used by classic `AzureWebJobsStorage=<connection-string>` and `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING=<...>` configurations. |
| Public network access disabled | `publicNetworkAccess=Disabled` | Prevents access through public storage endpoints. The Standard LA runtime needs private connectivity to the storage account. |

Policies with a `modify` effect can change applicable resource properties during create or update operations. For example, a request to set `allowSharedKeyAccess=true` may succeed while the effective value remains `false`. Other assignments may deny changes or audit configuration instead. Inspect the applicable definitions, parameters, and effective resource settings rather than relying on policy names.

## Design implications by variant

### Variant A — Consumption Logic App (recommended demo path)

Consumption LAs run entirely on **Microsoft-managed infrastructure**. This variant does not provision a customer-managed runtime storage account, an App Service plan, or a site, so the storage controls described above do not apply to a runtime storage account in your subscription. Other organizational policies may still affect deployment.

You still get:
- Entra ID Authorization Policy on the Request trigger (`accessControl.triggers.openAuthenticationPolicies.policies.AadPolicy`)
- Managed identity as the caller (via the Foundry project)
- Standard connectors, retries, delays, run history

You give up:
- Single-tenant isolation
- VNet integration
- Long-running (>1 minute) synchronous responses
- Some connectors that are Standard-only

**For the demo, this is the recommended choice.** It avoids the customer-managed runtime storage requirements of Standard LA, but deployment remains subject to your organization's applicable policies.

### Variant B — Standard Logic App (WS1), restricted storage considerations

When shared-key authentication and public storage access are both disabled, Standard LA needs the following configuration considerations alongside the base repo Bicep. These are deployment guidance, not a compliance certification; confirm requirements with your organization's policy owners.

1. **Identity-based `AzureWebJobsStorage`** using Logic-Apps-specific setting names:
    ```
    AzureWebJobsStorage__accountName=<storage-name>
    AzureWebJobsStorage__credentialType=managedIdentity          # NOT __credential
    AzureWebJobsStorage__managedIdentityResourceId=<UAMI full ARM ID>   # NOT __clientId
    ```
    Note the settings differ from the generic Function App identity-based pattern. Standard Logic Apps runtime expects `credentialType` (camelCase) and `managedIdentityResourceId` (full ARM ID, not just clientId). Getting this wrong yields the error:
    > *The authentication credential type for the storage account isn't valid. To authenticate with a user-assigned identity, check that the 'AzureWebJobsStorage__credentialType' app setting is set to 'managedIdentity' and that the 'AzureWebJobsStorage__managedIdentityResourceId' app setting is set to a valid managed identity resource ID.*
2. **Remove** `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` and `WEBSITE_CONTENTSHARE` (both require shared key).
3. **Private Endpoint + VNet integration** so the runtime can reach the storage account even with `publicNetworkAccess=Disabled`. See [`vnet-hardening.md`](vnet-hardening.md).

Roles the identity needs on the storage account:
- `Storage Blob Data Owner`
- `Storage Queue Data Contributor`
- `Storage Table Data Contributor`
- (Historically also `Storage File Data SMB Share Contributor` — no longer required once content-share settings are removed)

RBAC propagation to the storage plane can take **5–15 minutes** after assignment. Set roles at the Bicep-deploy stage, wait, then start the app.

## How to identify applicable policies in your environment

```powershell
# List policy-state results with a modify action for resources in the resource group
az policy state list --resource-group <rg> `
    --query "[?policyDefinitionAction=='modify'].{def:policyDefinitionName, assign:policyAssignmentName}" `
    -o table

# Read a specific policy definition at the MG scope
az policy definition show --name <policy-definition-name> `
    --management-group <mg-id> `
    --query "{name:name, displayName:displayName, description:description, effect:policyRule.then.effect}" `
    -o json
```

Use your environment's policy definition name and management-group ID in the example above. For definitions at a different scope, use the corresponding scope option. The policy-state query shows evaluation results, not a complete inventory of assignments. Review applicable assignments, including those inherited from management groups and subscriptions, along with their definitions, parameters, effects, and exemptions. Check the storage account's effective `allowSharedKeyAccess` and `publicNetworkAccess` settings; do not rely on assignment display names.

## Approved exceptions and alternative deployment options

These options are not required for the recommended Consumption demo path. For production planning, prefer an architecture that satisfies applicable controls and work with your organization's policy owners before pursuing an exception:

- **Policy exemption**: Where approved, use a documented exemption (Waiver / Mitigated) with the required permissions, scope, and risk acceptance. Confirm the approval process with policy owners.
- **Network Security Perimeter (`SecuredByPerimeter`)**: Evaluate only where current service support and organizational policy permit it. Do not assume it replaces the Standard LA private connectivity requirements described above.
- **Alternative deployment scope**: Use another subscription or management-group scope only when explicitly approved by your organization's governance owners, not as a way to bypass controls.
