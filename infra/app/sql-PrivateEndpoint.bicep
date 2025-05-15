@description('Location for the private endpoint')
param location string
@description('Tags for the resource')
param tags object = {}
@description('Name of the virtual network')
param virtualNetworkName string
@description('Name of the subnet for the private endpoint')
param subnetName string
@description('Name of the SQL server')
param sqlServerName string

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: 'sql-private-endpoint'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, subnetName)
    }
    privateLinkServiceConnections: [
      {
        name: '${sqlServerName}-plsc'
        properties: {
          privateLinkServiceId: resourceId('Microsoft.Sql/servers', sqlServerName)
          groupIds: [ 'sqlServer' ]
        }
      }
    ]
  }
}

output privateEndpointId string = sqlPrivateEndpoint.id
output privateEndpointName string = sqlPrivateEndpoint.name
