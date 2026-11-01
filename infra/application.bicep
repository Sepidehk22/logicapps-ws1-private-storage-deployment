targetScope = 'resourceGroup'

@minLength(1)
param environmentName string
@minLength(1)
param location string
@minLength(1)
@maxLength(2)
@description('Same reachable customer DNS IPv4 addresses as foundation.')
param dnsServerIps array
@description('HTTPS health URL, without secrets, SAS tokens or embedded credentials.')
param serviceAUrl string
@description('HTTPS health URL, without secrets, SAS tokens or embedded credentials.')
param serviceBUrl string
param tags object = {}

var suffix = uniqueString(resourceGroup().id, environmentName)
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: 'st${suffix}' }
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = { name: 'id-${suffix}' }
resource insights 'Microsoft.Insights/components@2020-02-02' existing = { name: 'ai-${suffix}' }
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: 'log-${suffix}' }
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = { name: 'vnet-${suffix}' }
resource appZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = { name: 'privatelink.azurewebsites.net' }

module runtime './modules/runtime.bicep' = {
  name: 'runtime-${suffix}'
  params: {
    location: location
    suffix: suffix
    tags: tags
    integrationSubnetId: '${vnet.id}/subnets/integration'
    privateEndpointSubnetId: '${vnet.id}/subnets/private-endpoints'
    appZoneId: appZone.id
    identityId: identity.id
    identityClientId: identity.properties.clientId
    insightsConnectionString: insights.properties.ConnectionString
    workspaceId: workspace.id
    dnsServerIps: dnsServerIps
    serviceAUrl: serviceAUrl
    serviceBUrl: serviceBUrl
    runtimeStorageConnection: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
}
output appName string = runtime.outputs.appName
output appHostName string = runtime.outputs.appHostName
output appPrivateEndpointName string = runtime.outputs.appPrivateEndpointName
