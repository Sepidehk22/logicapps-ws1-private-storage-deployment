param location string
param suffix string
param tags object
param integrationSubnetId string
param privateEndpointSubnetId string
param appZoneId string
param identityId string
param identityClientId string
param insightsConnectionString string
param workspaceId string
param dnsServerIps array
param serviceAUrl string
param serviceBUrl string
@secure()
param runtimeStorageConnection string

resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: 'asp-${suffix}'
  location: location
  tags: tags
  kind: 'elastic'
  sku: { name: 'WS1', tier: 'WorkflowStandard', capacity: 1 }
  properties: { reserved: false }
}
resource app 'Microsoft.Web/sites@2024-11-01' = {
  name: 'la-${suffix}'
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identityId}': {} } }
  properties: {
    serverFarmId: plan.id
    virtualNetworkSubnetId: integrationSubnetId
    publicNetworkAccess: 'Disabled'
    httpsOnly: true
    outboundVnetRouting: { allTraffic: true, contentShareTraffic: true }
    siteConfig: {
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      alwaysOn: true
      appSettings: concat([
        { name: 'APP_KIND', value: 'workflowApp' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet' }
        { name: 'AzureWebJobsStorage', value: runtimeStorageConnection }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: runtimeStorageConnection }
        { name: 'WEBSITE_CONTENTSHARE', value: 'logicapp-content' }
        { name: 'WEBSITE_CONTENTOVERVNET', value: '1' }
        { name: 'WEBSITE_SKIP_CONTENTSHARE_VALIDATION', value: '1' }
        { name: 'WEBSITE_DNS_SERVER', value: dnsServerIps[0] }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insightsConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD;ClientId=${identityClientId}' }
        { name: 'AVAILABILITY_SERVICE_A_URL', value: serviceAUrl }
        { name: 'AVAILABILITY_SERVICE_B_URL', value: serviceBUrl }
      ], length(dnsServerIps) > 1 ? [
        { name: 'WEBSITE_DNS_ALT_SERVER', value: dnsServerIps[1] }
      ] : [])
    }
  }
}
resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: app
  name: 'scm'
  properties: { allow: false }
}
resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: app
  name: 'ftp'
  properties: { allow: false }
}
resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-app-${suffix}'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [{
      name: 'sites'
      properties: { privateLinkServiceId: app.id, groupIds: ['sites'] }
    }]
  }
}
resource appGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: 'sites', properties: { privateDnsZoneId: appZoneId } }]
  }
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'workflow-runtime'
  scope: app
  properties: {
    workspaceId: workspaceId
    logs: [{ category: 'WorkflowRuntime', enabled: true }]
  }
}
output appName string = app.name
output appHostName string = app.properties.defaultHostName
output appPrivateEndpointName string = endpoint.name
