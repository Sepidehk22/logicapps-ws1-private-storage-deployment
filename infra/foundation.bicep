targetScope = 'resourceGroup'

@minLength(1)
@description('Stable identifier. Keep unchanged in both deployment stages.')
param environmentName string
@minLength(1)
@description('Customer-approved Azure public cloud region supporting Windows WS1.')
param location string
@description('Address space for a NEW dedicated VNet, without overlaps.')
param vnetAddressPrefix string
@description('Dedicated integration subnet, /26 or larger.')
param integrationSubnetPrefix string
@description('Separate Private Endpoint subnet.')
param privateEndpointSubnetPrefix string
@minLength(1)
@maxLength(2)
@description('Reachable primary and optional secondary customer DNS IPv4 addresses.')
param dnsServerIps array
@minLength(1)
@description('Existing Azure VNet IDs hosting DNS forwarders or a resolver inbound endpoint. Adds DNS links, not routing.')
param resolverVnetResourceIds array
param tags object = {}

var suffix = uniqueString(resourceGroup().id, environmentName)
var storageServices = ['blob', 'file', 'queue', 'table']
var privateZoneNames = [
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.file.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.table.${environment().suffixes.storage}'
  'privatelink.azurewebsites.net'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressPrefix] }
    dhcpOptions: { dnsServers: dnsServerIps }
    subnets: [
      {
        name: 'integration'
        properties: {
          addressPrefix: integrationSubnetPrefix
          delegations: [{
            name: 'appService'
            properties: { serviceName: 'Microsoft.Web/serverFarms' }
          }]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in privateZoneNames: {
  name: zone
  location: 'global'
  tags: tags
}]
resource workloadLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in privateZoneNames: {
  parent: zones[i]
  name: 'workload-${suffix}'
  location: 'global'
  properties: { virtualNetwork: { id: vnet.id }, registrationEnabled: false }
}]
var resolverLinks = flatten(map(privateZoneNames, (zone, i) => map(resolverVnetResourceIds, resolverId => {
  zoneIndex: i
  vnetId: resolverId
})))
resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for link in resolverLinks: {
  parent: zones[link.zoneIndex]
  name: 'resolver-${uniqueString(link.vnetId)}'
  location: 'global'
  properties: { virtualNetwork: { id: link.vnetId }, registrationEnabled: false }
}]

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}
resource files 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}
resource content 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: files
  name: 'logicapp-content'
  properties: { shareQuota: 5, enabledProtocols: 'SMB' }
}
resource storageEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for service in storageServices: {
  name: 'pe-${service}-${suffix}'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${vnet.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [{
      name: service
      properties: { privateLinkServiceId: storage.id, groupIds: [service] }
    }]
  }
}]
resource storageGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (service, i) in storageServices: {
  parent: storageEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: service, properties: { privateDnsZoneId: zones[i].id } }]
  }
}]

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${suffix}'
  location: location
  tags: tags
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}
resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'ai-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}
resource monitoringRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, identity.id, 'metricsPublisher')
  scope: insights
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: 'ampls-${suffix}'
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: { ingestionAccessMode: 'PrivateOnly', queryAccessMode: 'PrivateOnly' }
  }
}
resource insightsScope 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'insights'
  properties: { linkedResourceId: insights.id }
}
resource workspaceScope 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'workspace'
  properties: { linkedResourceId: workspace.id }
}
resource monitorEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-monitor-${suffix}'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${vnet.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [{
      name: 'monitor'
      properties: { privateLinkServiceId: ampls.id, groupIds: ['azuremonitor'] }
    }]
  }
  dependsOn: [insightsScope, workspaceScope]
}
resource monitorGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: monitorEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for i in [0, 5, 6, 7, 8]: {
      name: 'zone${i}'
      properties: { privateDnsZoneId: zones[i].id }
    }]
  }
}

output resourceNames object = {
  vnet: vnet.name
  storage: storage.name
  contentShare: content.name
  identity: identity.name
  insights: insights.name
  workspace: workspace.name
}
output vnetResourceId string = vnet.id
