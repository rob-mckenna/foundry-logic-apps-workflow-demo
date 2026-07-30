// ============================================================================
// foundry-logic-apps-workflow-demo — main.bicep
// Provisions:
//   - Storage account (Standard Logic App backing)
//   - App Service plan (WS1)
//   - Standard Logic App (single-tenant)
//   - User-assigned Managed Identity attached to the Foundry project
//   - Log Analytics workspace + diagnostic settings
// Entra ID app registration + app-role assignment are handled by deploy.ps1
// because Microsoft.Graph Bicep types are still preview and can't be assumed.
// ============================================================================

targetScope = 'resourceGroup'

@description('Short environment name — used as a suffix on resource names.')
@minLength(2)
@maxLength(10)
param envName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Resource ID of the pre-existing Microsoft Foundry project this demo attaches to.')
param foundryProjectResourceId string

@description('Optional Teams incoming webhook the workflow POSTs escalations to. Leave blank to skip.')
param teamsWebhookUrl string = ''

@description('Optional mock ServiceNow-style endpoint. Defaults to httpbin.org for demo use.')
param serviceNowUrl string = 'https://httpbin.org/post'

@description('Tags applied to every resource.')
param tags object = {
  workload: 'foundry-logic-apps-demo'
  scenario: 'prior-auth'
  owner: 'rob-mckenna'
}

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------
var storageName    = toLower('st${envName}${uniqueString(resourceGroup().id)}')
var planName       = 'plan-la-${envName}'
var logicAppName   = 'la-priorauth-${envName}'
var uamiName       = 'id-foundry-${envName}'
var lawName        = 'log-${envName}'

// ---------------------------------------------------------------------------
// Log Analytics
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

// ---------------------------------------------------------------------------
// Storage account for the Standard Logic App runtime
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled' // Demo posture; production: 'Disabled' + private endpoint
  }
}

// ---------------------------------------------------------------------------
// App Service plan (WS1)
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  sku: { name: 'WS1', tier: 'WorkflowStandard' }
  properties: { targetWorkerCount: 1, targetWorkerSizeId: 0, maximumElasticWorkerCount: 20 }
  kind: 'elastic'
}

// ---------------------------------------------------------------------------
// User-assigned managed identity for the Foundry project
// ---------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: uamiName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Standard Logic App (functionapp-kind = workflowapp)
// ---------------------------------------------------------------------------
var storageKeys = storage.listKeys()
var storageConn = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storageKeys.keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: logicAppName
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      netFrameworkVersion: 'v6.0'
      use32BitWorkerProcess: false
      appSettings: [
        { name: 'AzureWebJobsStorage',                       value: storageConn }
        { name: 'FUNCTIONS_EXTENSION_VERSION',               value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',                  value: 'node' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION',              value: '~20' }
        { name: 'AzureFunctionsJobHost__extensionBundle__id',       value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version',  value: '[1.*, 2.0.0)' }
        { name: 'APP_KIND',                                   value: 'workflowApp' }
        // Workflow parameter values, referenced from workflow.json via @parameters()
        { name: 'PARAM_SERVICENOW_URL',                       value: serviceNowUrl }
        { name: 'PARAM_TEAMS_WEBHOOK_URL',                    value: teamsWebhookUrl }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Diagnostic settings on the Logic App → Log Analytics
// ---------------------------------------------------------------------------
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: site
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'FunctionAppLogs',        enabled: true }
      { category: 'WorkflowRuntime',        enabled: true }
    ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

// ---------------------------------------------------------------------------
// Attach the UAMI to the Foundry project.
// The project is external to this deployment; deploy.ps1 patches the project
// separately (Bicep can't reliably update a resource in another RG scope
// without knowing all its required properties).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Outputs — consumed by deploy.ps1 and the agent's .env
// ---------------------------------------------------------------------------
output logicAppName       string = site.name
output logicAppHostname   string = site.properties.defaultHostName
output logicAppResourceId string = site.id
output uamiClientId       string = uami.properties.clientId
output uamiPrincipalId    string = uami.properties.principalId
output uamiResourceId     string = uami.id
output storageAccountName string = storage.name
output lawName            string = law.name
output tenantId           string = subscription().tenantId
output foundryProjectResourceId string = foundryProjectResourceId
