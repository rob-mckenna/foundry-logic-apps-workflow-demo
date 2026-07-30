<#
    generate-openapi.ps1 — regenerate workflows/prior-auth-status-check/openapi.yaml
    from the trigger schema. Useful when you edit trigger-schema.json.

    For this demo the OpenAPI file is hand-maintained (has richer descriptions
    than a naive schema-to-openapi conversion produces), so this script is
    provided as scaffolding and prints a diff instead of overwriting.
#>

[CmdletBinding()]
param(
    [string] $WorkflowDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workflows\prior-auth-status-check')
)

$ErrorActionPreference = 'Stop'

$schema = Get-Content (Join-Path $WorkflowDir 'trigger-schema.json') -Raw | ConvertFrom-Json
$openapi = Get-Content (Join-Path $WorkflowDir 'openapi.yaml') -Raw

Write-Host 'Trigger schema properties:'
$schema.properties.PSObject.Properties | ForEach-Object {
    Write-Host ("  {0,-20} {1}" -f $_.Name, $_.Value.description)
}

Write-Host "`nOpenAPI spec currently references these operations:"
[regex]::Matches($openapi, 'operationId:\s+(\S+)') | ForEach-Object {
    Write-Host "  $($_.Groups[1].Value)"
}

Write-Host "`n(For this demo, edit openapi.yaml directly to keep richer descriptions.)"
