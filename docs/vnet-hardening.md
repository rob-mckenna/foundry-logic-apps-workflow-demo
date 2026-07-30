# VNet hardening (optional)

The demo deploys the Standard Logic App with public inbound. For a production healthcare workload you would layer these networking controls.

## Target end-state

```
Foundry project ──▶ Private Endpoint ──▶ Standard Logic App ──▶ VNet-integrated outbound ──▶ Private DNS zones ──▶ Corp PA API / ServiceNow / Teams (via ExpressRoute)
```

## Steps to add

### 1. Add a VNet + subnets to `infra/main.bicep`

```bicep
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${envName}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/22' ] }
    subnets: [
      { name: 'snet-la-inbound',  properties: { addressPrefix: '10.20.0.0/26', privateEndpointNetworkPolicies: 'Disabled' } }
      { name: 'snet-la-outbound', properties: { addressPrefix: '10.20.0.64/26', delegations: [ { name: 'appservice', properties: { serviceName: 'Microsoft.Web/serverFarms' } } ] } }
    ]
  }
}
```

### 2. Enable VNet integration on the App Service plan

```bicep
resource site 'Microsoft.Web/sites@2024-04-01' = {
  // ... existing ...
  properties: {
    // ... existing ...
    virtualNetworkSubnetId: '${vnet.id}/subnets/snet-la-outbound'
    vnetRouteAllEnabled: true
  }
}
```

### 3. Create a Private Endpoint for the Logic App site

```bicep
resource pe 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-la-${envName}'
  location: location
  properties: {
    subnet: { id: '${vnet.id}/subnets/snet-la-inbound' }
    privateLinkServiceConnections: [{
      name: 'la-plsc'
      properties: {
        privateLinkServiceId: site.id
        groupIds: [ 'sites' ]
      }
    }]
  }
}
```

### 4. Wire up the Private DNS zone

```bicep
resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
}
resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZone
  name: 'link-${envName}'
  location: 'global'
  properties: { registrationEnabled: false, virtualNetwork: { id: vnet.id } }
}
resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: pe
  name: 'default'
  properties: { privateDnsZoneConfigs: [ { name: 'sites', properties: { privateDnsZoneId: dnsZone.id } } ] }
}
```

### 5. Restrict inbound to the Private Endpoint

```bicep
resource site 'Microsoft.Web/sites@2024-04-01' = {
  // ...
  properties: {
    // ...
    publicNetworkAccess: 'Disabled'
  }
}
```

### 6. Update the Foundry project connectivity

The Foundry project must reach the Logic App via the Private Endpoint. That means the Foundry project's VNet (managed VNet in the new Foundry) needs a peering or direct integration to the same VNet, and the Private DNS zone must resolve there. This is done in the Foundry project's `network` block.

## Trade-offs

| Control | Adds | Cost |
|---|---|---|
| VNet integration | Outbound calls traverse corp network | App Service plan pricing unchanged, VNet resources ~$0 |
| Private Endpoint | Inbound restricted to the VNet | ~$0.01/hr per PE + data processed |
| Private DNS zone | Correct name resolution inside VNet | ~$0.50/month per zone + queries |
| `publicNetworkAccess: Disabled` | No public exposure at all | Blocks Kudu/Portal debugging unless you jump-box in |

## What NOT to lock down in the demo

Leaving the demo repo VNet-free keeps it runnable for anyone who wants to see the pattern in an empty subscription. When productionizing for a healthcare payer/PBM, layer the above via a `vnet` module in `infra/` and enable it with a boolean parameter.
