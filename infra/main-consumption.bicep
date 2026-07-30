// ============================================================================
// foundry-logic-apps-workflow-demo — main-consumption.bicep
// Consumption Logic App variant (SFI-friendly: no storage account, no site).
// Provisions:
//   - Consumption Logic App (Microsoft.Logic/workflows)
//     with Request trigger + AAD Authorization Policy embedded
//   - Reuses pre-existing user-assigned MI (id-foundry-<env>) — passed by ID
//   - Reuses pre-existing Entra app registration audience
// ============================================================================

targetScope = 'resourceGroup'

@description('Short environment name — used as a suffix on resource names.')
@minLength(2)
@maxLength(10)
param envName string

@description('Azure region for the workflow.')
param location string = resourceGroup().location

@description('Tenant ID for the AAD Authorization Policy iss claim.')
param tenantId string = subscription().tenantId

@description('Audience string the Foundry agent presents (e.g. api://<appId>).')
param audience string

@description('Optional Teams incoming webhook the workflow POSTs escalations to.')
param teamsWebhookUrl string = ''

@description('Mock ServiceNow-style endpoint. Defaults to httpbin.org for demo use.')
param serviceNowUrl string = 'https://httpbin.org/post'

@description('Tags applied to every resource.')
param tags object = {
  workload: 'foundry-logic-apps-demo'
  scenario: 'prior-auth'
  variant: 'consumption'
  owner: 'rob-mckenna'
}

var workflowName = 'la-priorauth-${envName}'
var iss = 'https://sts.windows.net/${tenantId}/'

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: workflowName
  location: location
  tags: tags
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        serviceNowUrl: {
          type: 'String'
          defaultValue: serviceNowUrl
        }
        teamsWebhookUrl: {
          type: 'String'
          defaultValue: teamsWebhookUrl
        }
      }
      triggers: {
        When_a_HTTP_request_is_received: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {
              type: 'object'
              properties: {
                priorAuthId:        { type: 'string' }
                memberId:           { type: 'string' }
                requestingProvider: { type: 'string' }
              }
              required: [ 'priorAuthId' ]
            }
          }
          operationOptions: 'EnableSchemaValidation'
        }
      }
      actions: {
        Compose_paDataset: {
          type: 'Compose'
          runAfter: {}
          inputs: [
            { priorAuthId: 'PA-2026-88421', status: 'Pending',  drug: 'Ozempic 1mg',     memberId: 'M-99231', submittedDate: '2026-07-23', assignedReviewer: 'clinicalreview@example.com', denialReason: null }
            { priorAuthId: 'PA-2026-88422', status: 'Approved', drug: 'Humira 40mg/0.4mL', memberId: 'M-40182', submittedDate: '2026-07-28', assignedReviewer: 'clinicalreview@example.com', denialReason: null }
            { priorAuthId: 'PA-2026-88423', status: 'Denied',   drug: 'Xolair 150mg',    memberId: 'M-72910', submittedDate: '2026-07-26', assignedReviewer: 'clinicalreview@example.com', denialReason: 'Step therapy not completed — trial of inhaled corticosteroid required per plan formulary.' }
            { priorAuthId: 'PA-2026-88424', status: 'Pending',  drug: 'Trulicity 1.5mg', memberId: 'M-58024', submittedDate: '2026-07-29', assignedReviewer: 'clinicalreview@example.com', denialReason: null }
            { priorAuthId: 'PA-2026-88425', status: 'Pending',  drug: 'Enbrel 50mg',     memberId: 'M-11557', submittedDate: '2026-07-21', assignedReviewer: 'clinicalreview@example.com', denialReason: null }
          ]
        }
        Filter_matching_pa: {
          type: 'Query'
          runAfter: { Compose_paDataset: [ 'Succeeded' ] }
          inputs: {
            from: '@outputs(\'Compose_paDataset\')'
            where: '@equals(item()[\'priorAuthId\'], triggerBody()?[\'priorAuthId\'])'
          }
        }
        Check_pa_found: {
          type: 'If'
          runAfter: { Filter_matching_pa: [ 'Succeeded' ] }
          expression: {
            and: [
              { greater: [ '@length(body(\'Filter_matching_pa\'))', 0 ] }
            ]
          }
          actions: {
            Compose_pa: {
              type: 'Compose'
              runAfter: {}
              inputs: '@first(body(\'Filter_matching_pa\'))'
            }
            Compose_daysOutstanding: {
              type: 'Compose'
              runAfter: { Compose_pa: [ 'Succeeded' ] }
              inputs: '@div(sub(ticks(utcNow()), ticks(outputs(\'Compose_pa\')[\'submittedDate\'])), 864000000000)'
            }
            Should_escalate: {
              type: 'If'
              runAfter: { Compose_daysOutstanding: [ 'Succeeded' ] }
              expression: {
                and: [
                  { equals: [ '@outputs(\'Compose_pa\')[\'status\']', 'Pending' ] }
                  { greater: [ '@outputs(\'Compose_daysOutstanding\')', 3 ] }
                ]
              }
              actions: {
                Open_mock_incident: {
                  type: 'Http'
                  runAfter: {}
                  inputs: {
                    method: 'POST'
                    uri: '@parameters(\'serviceNowUrl\')'
                    headers: { 'Content-Type': 'application/json' }
                    body: {
                      short_description: '@{concat(\'PA SLA breach: \', outputs(\'Compose_pa\')[\'priorAuthId\'])}'
                      assignment_group:  'PBM-PA-Clinical-Review'
                      priority:          '3'
                      caller_id:         'foundry-agent'
                      u_prior_auth_id:   '@outputs(\'Compose_pa\')[\'priorAuthId\']'
                      u_days_outstanding: '@outputs(\'Compose_daysOutstanding\')'
                      u_member_id:       '@outputs(\'Compose_pa\')[\'memberId\']'
                      u_drug:            '@outputs(\'Compose_pa\')[\'drug\']'
                    }
                    retryPolicy: { type: 'exponential', count: 3, interval: 'PT10S' }
                  }
                }
                Compose_incidentNumber: {
                  type: 'Compose'
                  runAfter: { Open_mock_incident: [ 'Succeeded', 'Failed' ] }
                  inputs: '@{concat(\'INC00\', substring(guid(), 0, 6))}'
                }
                Notify_reviewer_if_webhook_set: {
                  type: 'If'
                  runAfter: { Compose_incidentNumber: [ 'Succeeded' ] }
                  expression: {
                    and: [
                      { greater: [ '@length(parameters(\'teamsWebhookUrl\'))', 0 ] }
                    ]
                  }
                  actions: {
                    Post_to_teams: {
                      type: 'Http'
                      inputs: {
                        method: 'POST'
                        uri: '@parameters(\'teamsWebhookUrl\')'
                        headers: { 'Content-Type': 'application/json' }
                        body: {
                          text: '@{concat(\'⚠️ PA \', outputs(\'Compose_pa\')[\'priorAuthId\'], \' (\', outputs(\'Compose_pa\')[\'drug\'], \' for member \', outputs(\'Compose_pa\')[\'memberId\'], \') has been pending \', string(outputs(\'Compose_daysOutstanding\')), \' business days. Incident \', outputs(\'Compose_incidentNumber\'), \' opened.\')}'
                        }
                      }
                    }
                  }
                  else: { actions: {} }
                }
              }
              else: { actions: {} }
            }
            Response_found: {
              type: 'Response'
              kind: 'Http'
              runAfter: { Should_escalate: [ 'Succeeded', 'Skipped' ] }
              inputs: {
                statusCode: 200
                headers: { 'Content-Type': 'application/json' }
                body: {
                  priorAuthId:       '@outputs(\'Compose_pa\')[\'priorAuthId\']'
                  status:            '@outputs(\'Compose_pa\')[\'status\']'
                  drug:              '@outputs(\'Compose_pa\')[\'drug\']'
                  memberId:          '@outputs(\'Compose_pa\')[\'memberId\']'
                  submittedDate:     '@outputs(\'Compose_pa\')[\'submittedDate\']'
                  daysOutstanding:   '@outputs(\'Compose_daysOutstanding\')'
                  escalated:         '@and(equals(outputs(\'Compose_pa\')[\'status\'], \'Pending\'), greater(outputs(\'Compose_daysOutstanding\'), 3))'
                  escalationTicket:  '@if(and(equals(outputs(\'Compose_pa\')[\'status\'], \'Pending\'), greater(outputs(\'Compose_daysOutstanding\'), 3)), outputs(\'Compose_incidentNumber\'), null)'
                  assignedReviewer:  '@outputs(\'Compose_pa\')[\'assignedReviewer\']'
                  nextStepSlaHours:  '@if(and(equals(outputs(\'Compose_pa\')[\'status\'], \'Pending\'), greater(outputs(\'Compose_daysOutstanding\'), 3)), 24, null)'
                  denialReason:      '@outputs(\'Compose_pa\')[\'denialReason\']'
                  summary:           '@{if(equals(outputs(\'Compose_pa\')[\'status\'], \'Denied\'), concat(outputs(\'Compose_pa\')[\'priorAuthId\'], \' was DENIED. Reason: \', coalesce(outputs(\'Compose_pa\')[\'denialReason\'], \'not provided\'), \'.\'), if(equals(outputs(\'Compose_pa\')[\'status\'], \'Approved\'), concat(outputs(\'Compose_pa\')[\'priorAuthId\'], \' (\', outputs(\'Compose_pa\')[\'drug\'], \' for member \', outputs(\'Compose_pa\')[\'memberId\'], \') is APPROVED.\'), if(greater(outputs(\'Compose_daysOutstanding\'), 3), concat(outputs(\'Compose_pa\')[\'priorAuthId\'], \' (\', outputs(\'Compose_pa\')[\'drug\'], \' for member \', outputs(\'Compose_pa\')[\'memberId\'], \') has been Pending for \', string(outputs(\'Compose_daysOutstanding\')), \' business days. Escalation ticket \', outputs(\'Compose_incidentNumber\'), \' opened; reviewer \', outputs(\'Compose_pa\')[\'assignedReviewer\'], \' notified. Next-step SLA is 24 hours.\'), concat(outputs(\'Compose_pa\')[\'priorAuthId\'], \' (\', outputs(\'Compose_pa\')[\'drug\'], \' for member \', outputs(\'Compose_pa\')[\'memberId\'], \') is Pending — \', string(outputs(\'Compose_daysOutstanding\')), \' business day(s) old, within SLA.\'))))}'
                }
              }
            }
          }
          else: {
            actions: {
              Response_not_found: {
                type: 'Response'
                kind: 'Http'
                inputs: {
                  statusCode: 404
                  headers: { 'Content-Type': 'application/json' }
                  body: {
                    error: 'PA not found'
                    priorAuthId: '@triggerBody()?[\'priorAuthId\']'
                  }
                }
              }
            }
          }
        }
      }
      outputs: {}
    }
    parameters: {
      serviceNowUrl:  { value: serviceNowUrl }
      teamsWebhookUrl: { value: teamsWebhookUrl }
    }
    accessControl: {
      triggers: {
        openAuthenticationPolicies: {
          policies: {
            AadPolicy: {
              type: 'AAD'
              claims: [
                { name: 'iss', value: iss }
                { name: 'aud', value: audience }
              ]
            }
          }
        }
      }
    }
  }
}

output workflowName    string = workflow.name
output workflowId      string = workflow.id
output callbackUrlHint string = 'Fetch trigger callback URL via listCallbackUrl action on triggers/When_a_HTTP_request_is_received.'
