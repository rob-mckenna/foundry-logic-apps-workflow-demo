# SFI tenant notes

## Why there are two variants

Microsoft's **Secure Future Initiative (SFI)** applies management-group-scoped Azure Policies that enforce a stricter default posture on every storage account in the tenant. Two of these policies specifically break the classical Standard-plan Logic Apps deployment pattern:

| Policy | Effect | Impact on Standard LA |
|---|---|---|
| `StorageAccount_DisableLocalAuth_Modify` (SFI-ID4.2.1) | Forces `allowSharedKeyAccess=false` on every storage account | Blocks the classic `AzureWebJobsStorage=<connection-string>` and `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING=<...>` app settings that Standard LA relies on. |
| `StorageAccount_PublicNetwork_Modify` | Forces `publicNetworkAccess=Disabled` (unless the value is `SecuredByPerimeter`) | Blocks any traffic to the storage account from anywhere other than a private endpoint or a Network Security Perimeter. Standard LA runs on shared App Service infrastructure — public reach is off. |

Both policies use `modify` effect — they don't just audit, they *silently rewrite* the setting on every API call to the resource. Setting `allowSharedKeyAccess=true` "succeeds" but the value reads back as `false` immediately.

## Design implications by variant

### Variant A — Consumption Logic App (recommended demo path)

Consumption LAs run entirely on **Microsoft-managed infrastructure**. You never provision a storage account, an App Service plan, or a site. Both SFI policies simply don't apply.

You still get:
- Entra ID Authorization Policy on the Request trigger (`accessControl.triggers.openAuthenticationPolicies.policies.AadPolicy`)
- Managed identity as the caller (via the Foundry project)
- Standard connectors, retries, delays, run history

You give up:
- Single-tenant isolation
- VNet integration
- Long-running (>1 minute) synchronous responses
- Some connectors that are Standard-only

**For the demo, this is the winning choice.** It works in any SFI tenant with zero policy fights.

### Variant B — Standard Logic App (WS1), SFI-compliant

To ship Standard LA in an SFI tenant, you need three additional pieces on top of the base repo Bicep:

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

## How to identify SFI policies in your tenant

```powershell
# List modify policies at MG scope for storage
az policy state list --resource-group <rg> `
    --query "[?policyDefinitionAction=='modify'].{def:policyDefinitionName, assign:policyAssignmentName}" `
    -o table

# Read a specific policy definition at the MG scope
az policy definition show --name StorageAccount_DisableLocalAuth_Modify `
    --management-group <mg-id> `
    --query "{name:name, displayName:displayName, description:description, effect:policyRule.then.effect}" `
    -o json
```

Look for policies under the `MCAPSGovDeployPolicies` assignment or any assignment with `SFI` in the display name.

## Escape hatches for Standard LA in policy-locked tenants

Not applicable to the demo, but useful references for productionizing:

- **Policy exemption**: `Resource Policy Contributor` at RG scope can create a categorized exemption (Waiver / Mitigated). Documents the risk acceptance. Not appropriate for the SFI storage policies without a strong business case.
- **Network Security Perimeter (`SecuredByPerimeter`)**: Add the storage account to an NSP that also includes the Logic App. Preview feature.
- **Deploy in a subscription outside the enforcing management group**: the cleanest path if you can arrange it.
