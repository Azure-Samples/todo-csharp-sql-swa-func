param location string
param tags object = {}
param sqlServerName string = ''
param apiUserAssignedIdentityName string = ''
param apiUserAssignedIdentityPrincipalId string = ''
param apiUserAssignedIdentityClientId string = ''
param sqlDatabaseName string = ''
param enableSQLScripts bool = false
param sqlAdminUserAssignedIdentityName string = ''
param abbrs object
param resourceToken string
param keyVaultName string = ''
param principalId string = ''
param connectionStringKey string = 'AZURE-SQL-CONNECTION-STRING'
param vnetEnabled bool = false

// SQL admin user assigned identity - only created if enableSQLScripts is true
// This identity is used for running SQL scripts with elevated permissions
module sqlAdminUserAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = if (enableSQLScripts) {
  name: 'sqlAdminUserAssignedIdentity'
  params: {
    location: location
    tags: tags
    name: !empty(sqlAdminUserAssignedIdentityName) ? sqlAdminUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}sqladmin-${resourceToken}'
  }
}

// The application database
var defaultDatabaseName = 'Todo'
var actualDatabaseName = !empty(sqlDatabaseName) ? sqlDatabaseName : defaultDatabaseName

module sqlServer 'br/public:avm/res/sql/server:0.16.1' = {
  name: 'sqlservice'
  params: {
    name: !empty(sqlServerName) ? sqlServerName : '${abbrs.sqlServers}${resourceToken}'
    location: location
    tags: tags
    publicNetworkAccess: vnetEnabled ? 'Disabled' : 'Enabled'
    administrators: {
      azureADOnlyAuthentication: true
      login: apiUserAssignedIdentityName
      principalType: 'Application'
      sid: apiUserAssignedIdentityClientId
      tenantId: tenant().tenantId
    }
    databases: [
      {
        name: actualDatabaseName
        availabilityZone: -1
        zoneRedundant: false
      }
    ]
    firewallRules: !vnetEnabled ? [
      {
        name: 'Azure Services'
        startIpAddress: '0.0.0.1'
        endIpAddress: '255.255.255.254'
      }
    ] : []
  }
}

// Optional deployment script to add the API user to the database
module deploymentScript 'br/public:avm/res/resources/deployment-script:0.1.3' = if (enableSQLScripts) {
  name: 'deployment-script'
  params: {
    kind: 'AzureCLI'
    name: 'deployment-script'
    azCliVersion: '2.37.0'
    location: location
    retentionInterval: 'PT1H'
    timeout: 'PT5M'
    cleanupPreference: 'OnSuccess'
    environmentVariables:{
      secureList: [
        {
          name: 'DBNAME'
          value: actualDatabaseName
        }
        {
          name: 'DBSERVER'
          value: '${sqlServer.outputs.name}${environment().suffixes.sqlServerHostname}'
        }
        {
          name: 'UAMIOBJECTID-API'
          secureValue: apiUserAssignedIdentityPrincipalId
        }
        {
          name: 'UAMINAME-API'
          secureValue: apiUserAssignedIdentityName
        }
        {
          name: 'UAMICLIENTID-SQLADMIN'
          secureValue: enableSQLScripts ? sqlAdminUserAssignedIdentity.outputs.clientId : ''
        }
      ]
    }
    // Uses sqlAdminUserAssignedIdentity to run the script as elevated SQL admin
    // Adds the apiUserAssignedIdentity (normal app/api user) to the database and assigns it the db_datareader, db_datawriter, and db_ddladmin roles
    // More info: https://learn.microsoft.com/en-us/azure/app-service/tutorial-connect-msi-sql-database?tabs=windowsclient%2Cefcore%2Cdotnet#grant-permissions-to-managed-identity
    scriptContent: '''
wget https://github.com/microsoft/go-sqlcmd/releases/download/v0.8.1/sqlcmd-v0.8.1-linux-x64.tar.bz2
tar x -f sqlcmd-v0.8.1-linux-x64.tar.bz2 -C .

cat <<SCRIPT_END > ./initDb.sql
drop user if exists ${UAMINAME-API}
go
CREATE USER [${UAMINAME-API}] FROM EXTERNAL PROVIDER With OBJECT_ID='${UAMIOBJECTID-API}';
ALTER ROLE db_datareader ADD MEMBER [${UAMINAME-API}];
ALTER ROLE db_datawriter ADD MEMBER [${UAMINAME-API}];
ALTER ROLE db_ddladmin ADD MEMBER [${UAMINAME-API}];
GO
SCRIPT_END

./sqlcmd -S ${DBSERVER} -d ${DBNAME} --authentication-method ActiveDirectoryManagedIdentity -U {UAMICLIENTID-SQLADMIN} -i ./initDb.sql
    '''
  }
}

// Create a keyvault to store secrets - only created if enableSQLScripts is true
module keyVault 'br/public:avm/res/key-vault/vault:0.5.1' = if (enableSQLScripts) {
  name: 'keyvault'
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

// Give the API access to KeyVault - only if enableSQLScripts is true
module accessKeyVault 'br/public:avm/res/key-vault/vault:0.5.1' = if (enableSQLScripts) {
  name: 'accesskeyvault'
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
        objectId: apiUserAssignedIdentityPrincipalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
    secrets:{
      secureList: [
        {
          name: connectionStringKey
          value: 'Server=${sqlServer.outputs.fullyQualifiedDomainName}; Database=${actualDatabaseName}; Authentication=Active Directory Default; User Id=${apiUserAssignedIdentityClientId}; TrustServerCertificate=True'
        }
      ]
    }
  }
}

// Outputs
output fullyQualifiedDomainName string = sqlServer.outputs.fullyQualifiedDomainName
output name string = sqlServer.outputs.name
output databaseName string = actualDatabaseName
output keyVaultName string = enableSQLScripts ? keyVault.outputs.name : ''
output keyVaultUri string = enableSQLScripts ? keyVault.outputs.uri : ''
output sqlAdminIdentityId string = enableSQLScripts ? sqlAdminUserAssignedIdentity.outputs.resourceId : ''
output sqlAdminIdentityClientId string = enableSQLScripts ? sqlAdminUserAssignedIdentity.outputs.clientId : ''
