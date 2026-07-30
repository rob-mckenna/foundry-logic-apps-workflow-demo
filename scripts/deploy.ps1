<#
    deploy.ps1 — end-to-end deployment for foundry-logic-apps-workflow-demo.

    Steps:
      1. Login / subscription context
      2. Deploy Bicep (storage, plan, Standard Logic App, UAMI, Log Analytics)
      3. Create/reuse Entra app registration 'prior-auth-api' with App Role 'PriorAuth.Read'
      4. Grant the app role to the UAMI's service principal
      5. Attach the UAMI to the Foundry project
      6. Substitute ${TENANT_ID} into workflow.json's Authorization Policy claims
      7. Zip and deploy the workflow bundle to the Standard Logic App
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
    [string] $ServiceNowUrl       = 'https://httpbin.org/post'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot     = Split-Path -Parent $PSScriptRoot
$WorkflowDir  = Join-Path $RepoRoot 'workflows\prior-auth-status-check'
$BicepFile    = Join-Path $RepoRoot 'infra\main.bicep'

function Write-Step($n, $text) { Write-Host "`n[$n] $text" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# 1. Context
# ---------------------------------------------------------------------------
Write-Step 1 'Setting Azure context'
az account set --subscription $SubscriptionId | Out-Null
$tenantId = az account show --query tenantId -o tsv

Write-Step '1a' "Ensuring resource group '$ResourceGroupName' exists"
az group create --name $ResourceGroupName --location $Location --output none

# ---------------------------------------------------------------------------
# 2. Bicep deploy
# ---------------------------------------------------------------------------
Write-Step 2 'Deploying infrastructure via Bicep'
$deployName = "pademo-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
$deployment = az deployment group create `
    --resource-group $ResourceGroupName `
    --name $deployName `
    --template-file $BicepFile `
    --parameters `
        envName=$EnvironmentName `
        location=$Location `
        foundryProjectResourceId=$FoundryProjectResourceId `
        teamsWebhookUrl=$TeamsWebhookUrl `
        serviceNowUrl=$ServiceNowUrl `
    --output json | ConvertFrom-Json

if (-not $deployment -or -not $deployment.properties -or $deployment.properties.provisioningState -ne 'Succeeded') {
    Write-Host 'Deployment failed. Recent operation errors:' -ForegroundColor Red
    az deployment operation group list `
        --resource-group $ResourceGroupName `
        --name $deployName `
        --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.id, code:properties.statusMessage.error.code, msg:properties.statusMessage.error.message}" `
        -o json | Write-Host
    throw "Bicep deployment '$deployName' did not succeed."
}

$outputs           = $deployment.properties.outputs
$logicAppName      = $outputs.logicAppName.value
$logicAppHost      = $outputs.logicAppHostname.value
$uamiPrincipalId   = $outputs.uamiPrincipalId.value
$uamiResourceId    = $outputs.uamiResourceId.value
$uamiClientId      = $outputs.uamiClientId.value

Write-Host "  Logic App:        $logicAppName ($logicAppHost)"
Write-Host "  UAMI clientId:    $uamiClientId"
Write-Host "  UAMI principalId: $uamiPrincipalId"

# ---------------------------------------------------------------------------
# 3. Entra app registration + app role
# ---------------------------------------------------------------------------
Write-Step 3 "Ensuring Entra app '$AppRegistrationName' exists with role '$AppRoleValue'"
$existingApp = az ad app list --display-name $AppRegistrationName --query "[0]" -o json | ConvertFrom-Json

if (-not $existingApp) {
    Write-Host '  Creating app registration (without identifier URI — will set to api://<appId> after)'
    $appRoleId = [Guid]::NewGuid().ToString()
    $appRoles = @(
        @{
            id                 = $appRoleId
            allowedMemberTypes = @('Application')
            displayName        = $AppRoleValue
            description        = 'Call the check-prior-auth-status workflow.'
            value              = $AppRoleValue
            isEnabled          = $true
        }
    )
    $rolesFile = Join-Path $env:TEMP "approles-$([Guid]::NewGuid()).json"
    ($appRoles | ConvertTo-Json -Depth 5 -AsArray) | Out-File -Encoding utf8 $rolesFile

    $newApp = az ad app create `
        --display-name $AppRegistrationName `
        --app-roles "@$rolesFile" `
        --output json | ConvertFrom-Json
    Remove-Item $rolesFile -Force
    $appObjectId = $newApp.id
    $appId       = $newApp.appId

    Write-Host "  Setting identifier URI to api://$appId"
    az ad app update --id $appObjectId --identifier-uris "api://$appId" | Out-Null
} else {
    $appObjectId = $existingApp.id
    $appId       = $existingApp.appId
    Write-Host "  Reusing existing app registration $appId"

    if (-not ($existingApp.identifierUris | Where-Object { $_ -eq "api://$appId" })) {
        Write-Host "  Adding identifier URI api://$appId"
        az ad app update --id $appObjectId --identifier-uris "api://$appId" | Out-Null
    }

    $hasRole = $existingApp.appRoles | Where-Object { $_.value -eq $AppRoleValue }
    if (-not $hasRole) {
        Write-Host "  Adding missing app role '$AppRoleValue'"
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

$audience = "api://$appId"

Write-Step '3a' 'Ensuring service principal for the app registration'
$apiSp = az ad sp list --filter "appId eq '$appId'" --query "[0]" -o json | ConvertFrom-Json
if (-not $apiSp) {
    $apiSp = az ad sp create --id $appId -o json | ConvertFrom-Json
}
$apiSpObjectId = $apiSp.id

# Re-fetch app to get the (possibly new) role's GUID
$appNow    = az ad app show --id $appObjectId -o json | ConvertFrom-Json
$appRoleId = ($appNow.appRoles | Where-Object { $_.value -eq $AppRoleValue }).id

# ---------------------------------------------------------------------------
# 4. Grant role to the UAMI service principal
# ---------------------------------------------------------------------------
Write-Step 4 "Granting UAMI service principal the '$AppRoleValue' app role"
$assignments = az rest --method GET `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$uamiPrincipalId/appRoleAssignments" `
    -o json | ConvertFrom-Json
$already = $assignments.value | Where-Object { $_.appRoleId -eq $appRoleId -and $_.resourceId -eq $apiSpObjectId }
if (-not $already) {
    $body = @{
        principalId = $uamiPrincipalId
        resourceId  = $apiSpObjectId
        appRoleId   = $appRoleId
    } | ConvertTo-Json -Compress
    $bodyFile = Join-Path $env:TEMP "assign-$([Guid]::NewGuid()).json"
    $body | Out-File -Encoding utf8 $bodyFile
    az rest --method POST `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$uamiPrincipalId/appRoleAssignments" `
        --headers 'Content-Type=application/json' `
        --body "@$bodyFile" | Out-Null
    Remove-Item $bodyFile -Force
    Write-Host '  Role assigned. Propagation can take a few minutes.'
} else {
    Write-Host '  Role already assigned.'
}

# ---------------------------------------------------------------------------
# 5. Attach UAMI to Foundry project
# ---------------------------------------------------------------------------
Write-Step 5 'Attaching UAMI to the Foundry project'
# NOTE: Microsoft.CognitiveServices .../projects supports userAssignedIdentities via PATCH.
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
Write-Host '  Foundry project patched.'

# ---------------------------------------------------------------------------
# 6. Substitute ${TENANT_ID} and ${AUDIENCE} in workflow.json
# ---------------------------------------------------------------------------
Write-Step 6 'Substituting tenant ID and audience into workflow.json Authorization Policy'
$stagingDir  = Join-Path $env:TEMP "la-stage-$([Guid]::NewGuid())"
$stageInner  = Join-Path $stagingDir 'check-prior-auth-status'
New-Item -ItemType Directory -Force -Path $stageInner | Out-Null

$workflowText = Get-Content (Join-Path $WorkflowDir 'workflow.json') -Raw
$workflowText = $workflowText.Replace('${TENANT_ID}', $tenantId)
$workflowText = $workflowText.Replace('${AUDIENCE}', $audience)
# Backwards compat: the initial repo hardcoded api://prior-auth-api; keep replacing that too.
$workflowText = $workflowText.Replace('api://prior-auth-api', $audience)
$workflowText | Out-File -Encoding utf8 (Join-Path $stageInner 'workflow.json')

Copy-Item (Join-Path $WorkflowDir 'host.json')        (Join-Path $stagingDir 'host.json')
Copy-Item (Join-Path $WorkflowDir 'connections.json') (Join-Path $stagingDir 'connections.json')

# ---------------------------------------------------------------------------
# 7. Zip-deploy
# ---------------------------------------------------------------------------
Write-Step 7 'Zip-deploying workflow bundle'
$zipPath = Join-Path $env:TEMP "la-$EnvironmentName-$([Guid]::NewGuid()).zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath

az functionapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $logicAppName `
    --src $zipPath | Out-Null

Remove-Item $stagingDir -Recurse -Force
Remove-Item $zipPath -Force
Write-Host '  Workflow deployed.'

# ---------------------------------------------------------------------------
# 8. Print .env values
# ---------------------------------------------------------------------------
# Fetch the Foundry project endpoint for the agent SDK
$foundry = az resource show --ids $FoundryProjectResourceId --query 'properties' -o json | ConvertFrom-Json
$projectEndpoint = $foundry.endpoints.'AI Foundry API'
if (-not $projectEndpoint) { $projectEndpoint = $foundry.endpoints.'Microsoft Foundry API' }
if (-not $projectEndpoint) { $projectEndpoint = "<see Foundry portal → project → Overview>" }

Write-Host "`n============================================================"
Write-Host 'Copy these into agent\.env:' -ForegroundColor Green
Write-Host "============================================================"
Write-Host "FOUNDRY_PROJECT_ENDPOINT=$projectEndpoint"
Write-Host 'MODEL_DEPLOYMENT_NAME=gpt-5-mini'
Write-Host "LOGIC_APP_HOSTNAME=$logicAppHost"
Write-Host "TENANT_ID=$tenantId"
Write-Host "AUDIENCE=$audience"
Write-Host 'AGENT_NAME=prior-auth-assistant'
Write-Host "============================================================`n"

# Auto-write agent/.env so the next step doesn't need manual copy/paste.
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'agent\.env'
@"
FOUNDRY_PROJECT_ENDPOINT=$projectEndpoint
MODEL_DEPLOYMENT_NAME=gpt-5-mini
LOGIC_APP_HOSTNAME=$logicAppHost
TENANT_ID=$tenantId
AUDIENCE=$audience
AGENT_NAME=prior-auth-assistant
"@ | Out-File -Encoding utf8 $envFile
Write-Host "Wrote $envFile" -ForegroundColor Green
