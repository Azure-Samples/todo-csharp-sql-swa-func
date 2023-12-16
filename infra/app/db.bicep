param name string
param location string = resourceGroup().location
param tags object = {}

param databaseName string = ''
param keyVaultName string

@secure()
param sqlAdminPassword string
@secure()
param appUserPassword string

param databaseSkuName string
param databaseSkuTier string
param databaseSkuCapacity int

// Because databaseName is optional in main.bicep, we make sure the database name is set here.
var defaultDatabaseName = 'Todo'
var actualDatabaseName = !empty(databaseName) ? databaseName : defaultDatabaseName

// Default SKU Settings
var defaultDatabaseSkuName = 'Basic'
var actualDatabaseSkuName = !empty(databaseSkuName) ? databaseSkuName : defaultDatabaseSkuName

var defaultDatabaseSkuTier = 'Basic'
var actualDatabaseSkuTier = !empty(databaseSkuTier) ? databaseSkuTier : defaultDatabaseSkuTier

var defaultDatabaseSkuCapacity = 5
var actualDatabaseSkuCapacity = databaseSkuCapacity > 0 ? databaseSkuCapacity : defaultDatabaseSkuCapacity

module sqlServer '../core/database/sqlserver/sqlserver.bicep' = {
  name: 'sqlserver'
  params: {
    name: name
    location: location
    tags: tags
    databaseName: actualDatabaseName
    keyVaultName: keyVaultName
    sqlAdminPassword: sqlAdminPassword
    appUserPassword: appUserPassword
    databaseSkuName: actualDatabaseSkuName
    databaseSkuTier: actualDatabaseSkuTier
    databaseSkuCapacity: actualDatabaseSkuCapacity
  }
}

output connectionStringKey string = sqlServer.outputs.connectionStringKey
output databaseName string = sqlServer.outputs.databaseName
