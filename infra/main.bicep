targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources & Flex Consumption Function App')
@allowed([
  'australiaeast'
  'australiasoutheast'
  'brazilsouth'
  'canadacentral'
  'centralindia'
  'centralus'
  'eastasia'
  'eastus'
  'eastus2'
  'eastus2euap'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'koreacentral'
  'northcentralus'
  'northeurope'
  'norwayeast'
  'southafricanorth'
  'southcentralus'
  'southeastasia'
  'southindia'
  'spaincentral'
  'swedencentral'
  'uaenorth'
  'uksouth'
  'ukwest'
  'westcentralus'
  'westeurope'
  'westus'
  'westus2'
  'westus3'
])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string
param apiServiceName string = ''
param apiUserAssignedIdentityName string = ''
param applicationInsightsName string = ''
param appServicePlanName string = ''
param keyVaultName string = ''
param logAnalyticsName string = ''
param resourceGroupName string = ''
param storageAccountName string = ''
param sqlServerName string = ''
param webServiceName string = ''
param apimServiceName string = ''
param connectionStringKey string = 'AZURE-SQL-CONNECTION-STRING'

@description('Flag to use Azure API Management to mediate the calls between the Web frontend and the backend API')
param useAPIM bool = false

@description('API Management SKU to use if APIM is enabled')
param apimSku string = 'Consumption'

param vnetEnabled bool
param vNetName string = ''

@description('Id of the user or app to assign application roles')
param principalId string = ''

param sqlDatabaseName string = ''

var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, resourceToken)), 7)}'
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var webUri = 'https://${web.outputs.defaultHostname}'
var functionAppName = !empty(apiServiceName) ? apiServiceName : '${abbrs.webSitesFunctions}api-${resourceToken}'


// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// User assigned managed identity to be used by the function app to reach storage and other dependencies
// Assign specific roles to this identity in the RBAC module
module apiUserAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'apiUserAssignedIdentity'
  scope: rg
  params: {
    location: location
    tags: tags
    name: !empty(apiUserAssignedIdentityName) ? apiUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}api-${resourceToken}'
  }
}

// The application frontend
module web 'br/public:avm/res/web/static-site:0.3.0' = {
  name: 'staticweb'
  scope: rg
  params: {
    name: !empty(webServiceName) ? webServiceName : '${abbrs.webStaticSites}web-${resourceToken}'
    location: location
    provider: 'Custom'
    tags: union(tags, { 'azd-service-name': 'web' })
  }
}

// Create an App Service Plan to group applications under the same payment plan and SKU
module appServicePlan 'br/public:avm/res/web/serverfarm:0.1.1' = {
  name: 'appserviceplan'
  scope: rg
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
    reserved: true
    location: location
    tags: tags
  }
}

module api './app/api.bicep' = {
  name: 'api'
  scope: rg
  params: {
    name: functionAppName
    location: location
    tags: tags
    applicationInsightsName: monitoring.outputs.name
    appServicePlanId: appServicePlan.outputs.resourceId
    runtimeName: 'dotnet-isolated'
    runtimeVersion: '8.0'
    storageAccountName: storage.outputs.name
    enableBlob: storageEndpointConfig.enableBlob
    enableQueue: storageEndpointConfig.enableQueue
    enableTable: storageEndpointConfig.enableTable
    deploymentStorageContainerName: deploymentStorageContainerName
    identityId: apiUserAssignedIdentity.outputs.resourceId
    identityClientId: apiUserAssignedIdentity.outputs.clientId
    appSettings: {
      AZURE_KEY_VAULT_ENDPOINT: keyVault.outputs.uri
      AZURE_SQL_CONNECTION_STRING_KEY: 'Server=${sqlServer.outputs.name}${environment().suffixes.sqlServerHostname}; Database=${actualDatabaseName}; Authentication=Active Directory Default; User Id=${apiUserAssignedIdentity.outputs.clientId}; TrustServerCertificate=True'
    }
    virtualNetworkSubnetId: vnetEnabled ? serviceVirtualNetwork.outputs.appSubnetID : ''
    allowedOrigins: [ webUri ]
  }
}

// Give the API access to KeyVault
module accessKeyVault 'br/public:avm/res/key-vault/vault:0.5.1' = {
  name: 'accesskeyvault'
  scope: rg
  params: {
    name: keyVault.outputs.name
    enableRbacAuthorization: false
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enablePurgeProtection: false
    sku: 'standard'
    accessPolicies: [
      {
        objectId: principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: apiUserAssignedIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
    secrets:{
      secureList: [
        {
          name: connectionStringKey
          value: 'Server=${sqlServer.outputs.fullyQualifiedDomainName}; Database=${actualDatabaseName}; Authentication=Active Directory Default; User Id=${apiUserAssignedIdentity.outputs.clientId}; TrustServerCertificate=True'
        }
      ]
    }
  }
}

// The application database
var defaultDatabaseName = 'Todo'
var actualDatabaseName = !empty(sqlDatabaseName) ? sqlDatabaseName : defaultDatabaseName

module sqlServer 'br/public:avm/res/sql/server:0.16.1' = {
  name: 'sqlservice'
  scope: rg
  params: {
    name: !empty(sqlServerName) ? sqlServerName : '${abbrs.sqlServers}${resourceToken}'
    location: location
    tags: tags
    publicNetworkAccess: 'Enabled'
    administrators: {
      azureADOnlyAuthentication: true
      login: apiUserAssignedIdentity.outputs.name
      principalType: 'Application'
      sid: apiUserAssignedIdentity.outputs.clientId
      tenantId: tenant().tenantId
    }
    databases: [
      {
        name: actualDatabaseName
        availabilityZone: -1
        zoneRedundant: false
      }
    ]
    firewallRules: [
      {
        name: 'Azure Services'
        startIpAddress: '0.0.0.1'
        endIpAddress: '255.255.255.254'
      }
    ]
  }
}

// // Optional deployment script to add the API user to the database
// module deploymentScript 'br/public:avm/res/resources/deployment-script:0.1.3' = {
//   name: 'deployment-script'
//   scope: rg
//   params: {
//     kind: 'AzureCLI'
//     name: 'deployment-script'
//     azCliVersion: '2.37.0'
//     location: location
//     retentionInterval: 'PT1H'
//     timeout: 'PT5M'
//     cleanupPreference: 'OnSuccess'
//     environmentVariables:{
//       secureList: [
//         {
//           name: 'DBNAME'
//           value: actualDatabaseName
//         }
//         {
//           name: 'DBSERVER'
//           value: '${sqlServer.outputs.name}${environment().suffixes.sqlServerHostname}'
//         }
//         {
//           name: 'UAMIOBJECTID-API'
//           secureValue: apiUserAssignedIdentity.outputs.principalId
//         }
//         {
//           name: 'UAMINAME-API'
//           secureValue: apiUserAssignedIdentity.outputs.name
//         }
//         {
//           name: 'UAMICLIENTID-SQLADMIN'
//           secureValue: sqlAdminUserAssignedIdentity.outputs.clientId
//         }
//       ]
//     }
//     // Uses sqlAdminUserAssignedIdentity to run the script as elevated SQL admin
//     // Adds the apiUserAssignedIdentity (normal app/api user) to the database and assigns it the db_datareader, db_datawriter, and db_ddladmin roles
//     // More info: https://learn.microsoft.com/en-us/azure/app-service/tutorial-connect-msi-sql-database?tabs=windowsclient%2Cefcore%2Cdotnet#grant-permissions-to-managed-identity
//     scriptContent: '''
// wget https://github.com/microsoft/go-sqlcmd/releases/download/v0.8.1/sqlcmd-v0.8.1-linux-x64.tar.bz2
// tar x -f sqlcmd-v0.8.1-linux-x64.tar.bz2 -C .

// cat <<SCRIPT_END > ./initDb.sql
// drop user if exists ${UAMINAME-API}
// go
// CREATE USER [${UAMINAME-API}] FROM EXTERNAL PROVIDER With OBJECT_ID='${UAMIOBJECTID-API}';
// ALTER ROLE db_datareader ADD MEMBER [${UAMINAME-API}];
// ALTER ROLE db_datawriter ADD MEMBER [${UAMINAME-API}];
// ALTER ROLE db_ddladmin ADD MEMBER [${UAMINAME-API}];
// GO
// SCRIPT_END

// ./sqlcmd -S ${DBSERVER} -d ${DBNAME} --authentication-method ActiveDirectoryManagedIdentity -U {UAMICLIENTID-SQLADMIN} -i ./initDb.sql
//     '''
//   }
// }



module storage 'br/public:avm/res/storage/storage-account:0.8.3' = {
  name: 'storage'
  scope: rg
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // Disable local authentication methods as per policy
    dnsEndpointType: 'Standard'
    publicNetworkAccess: vnetEnabled ? 'Disabled' : 'Enabled'
    networkAcls: vnetEnabled ? {
      defaultAction: 'Deny'
      bypass: 'None'
    } : {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    blobServices: {
      containers: [{name: deploymentStorageContainerName}]
    }
    minimumTlsVersion: 'TLS1_2'  // Enforcing TLS 1.2 for better security
    location: location
    tags: tags
  }
}

// Define the configuration object locally to pass to the modules
var storageEndpointConfig = {
  enableBlob: true  // Required for AzureWebJobsStorage, .zip deployment, Event Hubs trigger and Timer trigger checkpointing
  enableQueue: false  // Required for Durable Functions and MCP trigger
  enableTable: false  // Required for Durable Functions and OpenAI triggers and bindings
  enableFiles: false   // Not required, used in legacy scenarios
  allowUserIdentityPrincipal: true   // Allow interactive user identity to access for testing and debugging
}

// Create a keyvault to store secrets
module keyVault 'br/public:avm/res/key-vault/vault:0.5.1' = {
  name: 'keyvault'
  scope: rg
  params: {
    name: !empty(keyVaultName) ? keyVaultName : '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enablePurgeProtection: false
    sku: 'standard'
  }
}

// Consolidated Role Assignments
module rbac 'app/rbac.bicep' = {
  name: 'rbacAssignments'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    appInsightsName: monitoring.outputs.name
    managedIdentityPrincipalId: apiUserAssignedIdentity.outputs.principalId
    userIdentityPrincipalId: principalId
    enableBlob: storageEndpointConfig.enableBlob
    enableQueue: storageEndpointConfig.enableQueue
    enableTable: storageEndpointConfig.enableTable
    allowUserIdentityPrincipal: storageEndpointConfig.allowUserIdentityPrincipal
  }
}

// Virtual Network & private endpoint to blob storage
module serviceVirtualNetwork 'app/vnet.bicep' =  if (vnetEnabled) {
  name: 'serviceVirtualNetwork'
  scope: rg
  params: {
    location: location
    tags: tags
    vNetName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
  }
}

module storagePrivateEndpoint 'app/storage-PrivateEndpoint.bicep' = if (vnetEnabled) {
  name: 'servicePrivateEndpoint'
  scope: rg
  params: {
    location: location
    tags: tags
    virtualNetworkName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
    subnetName: vnetEnabled ? serviceVirtualNetwork.outputs.peSubnetName : '' // Keep conditional check for safety, though module won't run if !vnetEnabled
    resourceName: storage.outputs.name
    enableBlob: storageEndpointConfig.enableBlob
    enableQueue: storageEndpointConfig.enableQueue
    enableTable: storageEndpointConfig.enableTable
  }
}

// Monitor application with Azure Monitor - Log Analytics and Application Insights
module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.11.1' = {
  name: '${uniqueString(deployment().name, location)}-loganalytics'
  scope: rg
  params: {
    name: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    location: location
    tags: tags
    dataRetention: 30
  }
}
 
module monitoring 'br/public:avm/res/insights/component:0.6.0' = {
  name: '${uniqueString(deployment().name, location)}-appinsights'
  scope: rg
  params: {
    name: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
    location: location
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    disableLocalAuth: true
  }
}

// Creates Azure API Management (APIM) service to mediate the requests between the frontend and the backend API
module apim 'br/public:avm/res/api-management/service:0.2.0' = if (useAPIM) {
  name: 'apim-deployment'
  scope: rg
  params: {
    name: !empty(apimServiceName) ? apimServiceName : '${abbrs.apiManagementService}${resourceToken}'
    publisherEmail: 'noreply@microsoft.com'
    publisherName: 'n/a'
    location: location
    tags: tags
    sku: apimSku
    skuCount: 0
    zones: []
    customProperties: {}
    loggers: [
      {
        name: 'app-insights-logger'
        credentials: {
          instrumentationKey: monitoring.outputs.instrumentationKey
        }
        loggerDescription: 'Logger to Azure Application Insights'
        isBuffered: false
        loggerType: 'applicationInsights'
        targetResourceId: monitoring.outputs.resourceId
      }
    ]
  }
}

//Configures the API settings for an api app within the Azure API Management (APIM) service.
module apimApi 'br/public:avm/ptn/azd/apim-api:0.1.0' = if (useAPIM) {
  name: 'apim-api-deployment'
  scope: rg
  params: {
    apiBackendUrl: api.outputs.SERVICE_API_URI
    apiDescription: 'This is a simple Todo API'
    apiDisplayName: 'Simple Todo API'
    apiName: 'todo-api'
    apiPath: 'todo'
    name: useAPIM ? apim.outputs.name : ''
    webFrontendUrl: webUri
    location: location
    apiAppName: api.outputs.SERVICE_API_NAME
  }
}

// Data outputs
output AZURE_SQL_CONNECTION_STRING_KEY string = 'Server=${sqlServer.outputs.fullyQualifiedDomainName}; Database=${actualDatabaseName}; Authentication=Active Directory Default; User Id=${apiUserAssignedIdentity.outputs.clientId}; TrustServerCertificate=True'
output AZURE_SQL_SERVER_NAME string = sqlServer.outputs.fullyQualifiedDomainName
output AZURE_SQL_DATABASE_NAME string = actualDatabaseName
output USER_ASSIGNED_IDENTITY_CLIENT_ID string = apiUserAssignedIdentity.outputs.clientId

// App outputs
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.connectionString
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output API_BASE_URL string = useAPIM ? apimApi.outputs.serviceApiUri : api.outputs.SERVICE_API_URI
output REACT_APP_WEB_BASE_URL string = webUri
output USE_APIM bool = useAPIM
output SERVICE_API_ENDPOINTS array = useAPIM ? [ apimApi.outputs.serviceApiUri, api.outputs.SERVICE_API_URI ]: []
