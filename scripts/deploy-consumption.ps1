<#
    deploy-consumption.ps1 — end-to-end deployment of the Consumption LA variant.

    Steps:
      1. Login / subscription context
      2. Ensure resource group + user-assigned Managed Identity
      3. Create/reuse Entra app registration 'prior-auth-api' with App Role 'PriorAuth.Read'
      4. Grant the app role to the UAMI's service principal
      5. Attach the UAMI to the Foundry project
      6. Deploy the Consumption Logic App (Microsoft.Logic/workflows) via Bicep
      7. Fetch the trigger callback URL (base, no SAS) and generate agent/openapi.deployed.yaml
      8. Emit the values you'll need for agent/.env

    Idempotent — safe to re-run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SubscriptionId,
    [Parameter(Mandatory)][string] $ResourceGroupName,
    [Parameter(Mandatory)][string] $Location,
    [Parameter(Mandatory)][string] $FoundryProjectResourceId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{2,10}$')][string] $EnvironmentName,
    [string] $AppRegistrationName = 'prior-auth-api',
    [string] $AppRoleValue        = 'PriorAuth.Read',
    [string] $TeamsWebhookUrl     = '',
    [string] $ServiceNowUrl       = 'https://httpbin.org/post',
    [string] $ModelDeploymentName = 'gpt-5-mini',
    [string] $AgentName           = 'prior-auth-assistant'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Bicep    = Join-Path $RepoRoot 'infra\main-consumption.bicep'

function Write-Step($n, $text) { Write-Host "`n[$n] $text" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# 1. Context
# ---------------------------------------------------------------------------
Write-Step 1 'Setting Azure context'
az account set --subscription $SubscriptionId | Out-Null
$tenantId = az account show --query tenantId -o tsv

Write-Step '1a' "Ensuring resource group '$ResourceGroupName'"
az group create --name $ResourceGroupName --location $Location --output none

# ---------------------------------------------------------------------------
# 2. UAMI (Foundry-side identity)
# ---------------------------------------------------------------------------
Write-Step 2 'Ensuring user-assigned Managed Identity'
$uamiName = "id-foundry-$EnvironmentName"
$uami = az identity show -g $ResourceGroupName -n $uamiName -o json 2>$null | ConvertFrom-Json
if (-not $uami) {
    $uami = az identity create -g $ResourceGroupName -n $uamiName -l $Location -o json | ConvertFrom-Json
    Write-Host "  Created $uamiName"
} else {
    Write-Host "  Reusing $uamiName"
}
$uamiClientId    = $uami.clientId
$uamiPrincipalId = $uami.principalId
$uamiResourceId  = $uami.id

# ---------------------------------------------------------------------------
# 3. Entra app registration + app role (SFI-safe URI = api://<appId>)
# ---------------------------------------------------------------------------
Write-Step 3 "Ensuring Entra app '$AppRegistrationName' with role '$AppRoleValue'"
$existingApp = az ad app list --display-name $AppRegistrationName --query "[0]" -o json | ConvertFrom-Json

if (-not $existingApp) {
    Write-Host '  Creating app registration'
    $appRoleId = [Guid]::NewGuid().ToString()
    $rolesJson = @(@{
        id                 = $appRoleId
        allowedMemberTypes = @('Application')
        displayName        = $AppRoleValue
        description        = 'Call the check-prior-auth-status workflow.'
        value              = $AppRoleValue
        isEnabled          = $true
    }) | ConvertTo-Json -Depth 5 -AsArray
    $rolesFile = Join-Path $env:TEMP "approles-$([Guid]::NewGuid()).json"
    $rolesJson | Out-File -Encoding utf8 $rolesFile
    $newApp = az ad app create --display-name $AppRegistrationName --app-roles "@$rolesFile" -o json | ConvertFrom-Json
    Remove-Item $rolesFile -Force
    $appObjectId = $newApp.id
    $appId       = $newApp.appId
    Write-Host "  Setting identifier URI to api://$appId"
    az ad app update --id $appObjectId --identifier-uris "api://$appId" | Out-Null
} else {
    $appObjectId = $existingApp.id
    $appId       = $existingApp.appId
    Write-Host "  Reusing app registration $appId"
    if (-not ($existingApp.identifierUris | Where-Object { $_ -eq "api://$appId" })) {
        az ad app update --id $appObjectId --identifier-uris "api://$appId" | Out-Null
    }
    if (-not ($existingApp.appRoles | Where-Object { $_.value -eq $AppRoleValue })) {
        Write-Host "  Adding role '$AppRoleValue'"
        $appRoleId = [Guid]::NewGuid().ToString()
        $newRoles = @($existingApp.appRoles) + @(@{
            id                 = $appRoleId
            allowedMemberTypes = @('Application')
            displayName        = $AppRoleValue
            description        = 'Call the check-prior-auth-status workflow.'
            value              = $AppRoleValue
            isEnabled          = $true
        })
        $rolesFile = Join-Path $env:TEMP "approles-$([Guid]::NewGuid()).json"
        ($newRoles | ConvertTo-Json -Depth 5 -AsArray) | Out-File -Encoding utf8 $rolesFile
        az ad app update --id $appObjectId --app-roles "@$rolesFile" | Out-Null
        Remove-Item $rolesFile -Force
    }
}

Write-Step '3a' 'Ensuring service principal for the app'
$apiSp = az ad sp list --filter "appId eq '$appId'" --query "[0]" -o json | ConvertFrom-Json
if (-not $apiSp) { $apiSp = az ad sp create --id $appId -o json | ConvertFrom-Json }
$apiSpObjectId = $apiSp.id

$appNow    = az ad app show --id $appObjectId -o json | ConvertFrom-Json
$appRoleId = ($appNow.appRoles | Where-Object { $_.value -eq $AppRoleValue }).id
$audience  = "api://$appId"

# ---------------------------------------------------------------------------
# 4. Grant role to UAMI
# ---------------------------------------------------------------------------
Write-Step 4 "Granting UAMI the '$AppRoleValue' app role"
$assignments = az rest --method GET `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$uamiPrincipalId/appRoleAssignments" `
    -o json | ConvertFrom-Json
$already = $assignments.value | Where-Object { $_.appRoleId -eq $appRoleId -and $_.resourceId -eq $apiSpObjectId }
if (-not $already) {
    $body = @{ principalId = $uamiPrincipalId; resourceId = $apiSpObjectId; appRoleId = $appRoleId } | ConvertTo-Json -Compress
    $bodyFile = Join-Path $env:TEMP "assign-$([Guid]::NewGuid()).json"
    $body | Out-File -Encoding utf8 $bodyFile
    az rest --method POST `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$uamiPrincipalId/appRoleAssignments" `
        --headers 'Content-Type=application/json' `
        --body "@$bodyFile" | Out-Null
    Remove-Item $bodyFile -Force
    Write-Host '  Role assigned'
} else {
    Write-Host '  Role already assigned'
}

# ---------------------------------------------------------------------------
# 5. Attach UAMI to Foundry project
# ---------------------------------------------------------------------------
Write-Step 5 'Patching Foundry project with UAMI'
$patchBody = @{
    identity = @{
        type = 'UserAssigned'
        userAssignedIdentities = @{ "$uamiResourceId" = @{} }
    }
} | ConvertTo-Json -Depth 6 -Compress
$patchFile = Join-Path $env:TEMP "foundry-patch-$([Guid]::NewGuid()).json"
$patchBody | Out-File -Encoding utf8 $patchFile
az rest --method PATCH `
    --url "https://management.azure.com${FoundryProjectResourceId}?api-version=2025-04-01-preview" `
    --headers 'Content-Type=application/json' `
    --body "@$patchFile" | Out-Null
Remove-Item $patchFile -Force

# ---------------------------------------------------------------------------
# 6. Deploy Consumption LA
# ---------------------------------------------------------------------------
Write-Step 6 'Deploying Consumption Logic App'
$deployName = "consumption-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
$dep = az deployment group create `
    --resource-group $ResourceGroupName `
    --name $deployName `
    --template-file $Bicep `
    --parameters `
        envName=$EnvironmentName `
        location=$Location `
        audience=$audience `
        teamsWebhookUrl=$TeamsWebhookUrl `
        serviceNowUrl=$ServiceNowUrl `
    -o json | ConvertFrom-Json

if ($dep.properties.provisioningState -ne 'Succeeded') {
    throw "Deployment '$deployName' did not succeed."
}
$workflowId = $dep.properties.outputs.workflowId.value

# ---------------------------------------------------------------------------
# 7. Fetch callback URL and generate openapi.deployed.yaml
# ---------------------------------------------------------------------------
Write-Step 7 'Fetching trigger callback URL'
$callback = az rest --method POST `
    --url "https://management.azure.com${workflowId}/triggers/When_a_HTTP_request_is_received/listCallbackUrl?api-version=2019-05-01" `
    -o json | ConvertFrom-Json

$uri = [Uri]$callback.value
# Base URL for OpenAPI servers.url — strip /invoke and query string
$serverUrl = $uri.Scheme + '://' + $uri.Host + $uri.AbsolutePath.Substring(0, $uri.AbsolutePath.LastIndexOf('/'))
$specPath  = Join-Path $RepoRoot 'agent\openapi.deployed.yaml'
$spec = @"
openapi: 3.1.0
info:
  title: Prior Authorization Status API
  description: |
    Look up the status of a prior authorization (PA) and, if the PA has been
    Pending for more than 3 business days, automatically open a ServiceNow
    escalation ticket and notify the assigned reviewer. Backed by an Azure
    Logic Apps Consumption workflow with an Entra ID (AAD) Authorization
    Policy on the Request trigger.
  version: 1.0.0
servers:
  - url: $serverUrl
    description: Consumption Logic App trigger endpoint.
paths:
  /invoke:
    post:
      operationId: check_prior_auth_status
      summary: Look up a prior authorization by ID and escalate if past SLA.
      description: |
        Returns the current status of a prior authorization. If the PA is
        Pending and has been outstanding more than 3 business days, the
        workflow opens a ServiceNow-style escalation ticket and notifies
        the assigned clinical reviewer before returning.
      parameters:
        - name: api-version
          in: query
          required: true
          schema:
            type: string
            default: "2019-05-01"
      security:
        - azureAd: [$audience/.default]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              `$ref: '#/components/schemas/CheckPriorAuthRequest'
      responses:
        '200':
          description: PA found. Response includes summary + escalation status.
          content:
            application/json:
              schema:
                `$ref: '#/components/schemas/CheckPriorAuthResponse'
components:
  securitySchemes:
    azureAd:
      type: oauth2
      description: Microsoft Entra ID client-credentials flow using managed identity.
      flows:
        clientCredentials:
          tokenUrl: https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token
          scopes:
            $audience/.default: Call the check-prior-auth-status workflow
  schemas:
    CheckPriorAuthRequest:
      type: object
      required: [priorAuthId]
      properties:
        priorAuthId:
          type: string
          description: PA reference, e.g. PA-2026-88421.
          pattern: '^PA-\d{4}-\d{4,6}$'
        memberId:
          type: string
        requestingProvider:
          type: string
    CheckPriorAuthResponse:
      type: object
      required: [priorAuthId, status, daysOutstanding, escalated, summary]
      properties:
        priorAuthId:      { type: string }
        status:           { type: string, enum: [Pending, Approved, Denied] }
        drug:             { type: string }
        memberId:         { type: string }
        submittedDate:    { type: string, format: date }
        daysOutstanding:  { type: integer }
        escalated:        { type: boolean }
        escalationTicket: { type: [string, "null"] }
        assignedReviewer: { type: [string, "null"] }
        nextStepSlaHours: { type: [integer, "null"] }
        denialReason:     { type: [string, "null"] }
        summary:          { type: string }
"@
$spec | Out-File -Encoding utf8 $specPath
Write-Host "  Wrote $specPath"
Write-Host "  Server URL: $serverUrl"

# ---------------------------------------------------------------------------
# 8. Emit .env
# ---------------------------------------------------------------------------
$foundry = az resource show --ids $FoundryProjectResourceId --query 'properties' -o json | ConvertFrom-Json
$projectEndpoint = $foundry.endpoints.'AI Foundry API'
if (-not $projectEndpoint) { $projectEndpoint = $foundry.endpoints.'Microsoft Foundry API' }

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host 'agent\.env values:' -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
$envFile = Join-Path $RepoRoot 'agent\.env'
@"
FOUNDRY_PROJECT_ENDPOINT=$projectEndpoint
MODEL_DEPLOYMENT_NAME=$ModelDeploymentName
TENANT_ID=$tenantId
AUDIENCE=$audience
AGENT_NAME=$AgentName
OPENAPI_PATH=$specPath
"@ | Tee-Object -FilePath $envFile
Write-Host "`nWrote $envFile"
Write-Host "`nNext steps:"
Write-Host "  cd agent"
Write-Host "  python -m venv .venv; . .\.venv\Scripts\Activate.ps1"
Write-Host "  pip install -r requirements.txt"
Write-Host "  python create_agent.py"
Write-Host "  python smoke_test.py"
