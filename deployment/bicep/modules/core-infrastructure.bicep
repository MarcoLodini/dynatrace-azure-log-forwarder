/*
     Dynatrace Azure Log Forwarder - Core Infrastructure Module
     
     This module deploys the core infrastructure components including
     networking, storage, Event Hub, Function App, and App Service Plan.
*/

targetScope = 'resourceGroup'

// ===================================================================
// Parameters
// ===================================================================

@description('Deployment name')
param deploymentName string

@description('Deploy ActiveGate container')
param deployActiveGateContainer bool

@description('Event Hub connection string')
@secure()
param eventHubConnectionString string

@description('App Service Plan resource ID')
param appServicePlanId string

@description('Use user-assigned managed identity')
param useUserAssignedMI bool

@description('User-assigned identity resource ID')
param userAssignedIdentityId string

@description('Existing virtual network resource ID')
param existingVirtualNetworkId string

@description('Existing subnet resource ID for Function App')
param existingFunctionSubnetId string

@description('Existing subnet resource ID for ActiveGate container')
param existingContainerSubnetId string

@description('Resource tags')
param resourceTags object

// ===================================================================
// Variables
// ===================================================================

var functionAppName = '${deploymentName}-function'
var storageAccountName = '${take(deploymentName, 18)}sa${substring(uniqueString(deploymentName, resourceGroup().id), 0, 4)}'
var eventHubNamespaceName = '${deploymentName}-eventhub'
var virtualNetworkName = '${deploymentName}-vnet'
var appServicePlanName = '${deploymentName}-plan'

// Determine if we're using existing infrastructure
var useExistingVNet = !empty(existingVirtualNetworkId)
var useExistingFunctionSubnet = !empty(existingFunctionSubnetId)
var useExistingContainerSubnet = !empty(existingContainerSubnetId)
var createEventHub = empty(eventHubConnectionString)

// Network configuration (only used when creating new VNet)
var vnetAddressSpace = '172.0.0.0/22'
var functionSubnetPrefix = '172.0.1.0/24'
var containerSubnetPrefix = '172.0.0.0/24'

// Extract resource names from existing resource IDs
var existingVNetName = useExistingVNet ? last(split(existingVirtualNetworkId, '/')) : ''

// ===================================================================
// Resources
// ===================================================================

// Virtual Network (only created if not using existing)
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-01-01' = if (!useExistingVNet) {
  name: virtualNetworkName
  location: resourceGroup().location
  tags: resourceTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    enableDdosProtection: false
  }
}

// Function App Subnet (only created if not using existing)
resource functionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (!useExistingFunctionSubnet) {
  parent: virtualNetwork
  name: 'functionapp'
  properties: {
    addressPrefix: functionSubnetPrefix
    serviceEndpoints: [
      {
        service: 'Microsoft.Storage'
        locations: [
          resourceGroup().location
        ]
      }
      {
        service: 'Microsoft.EventHub'
        locations: [
          resourceGroup().location
        ]
      }
    ]
    delegations: [
      {
        name: 'app-service-delegation'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

// Container Instance Subnet (when ActiveGate is deployed and not using existing)
resource containerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployActiveGateContainer && !useExistingContainerSubnet) {
  parent: virtualNetwork
  name: 'aci'
  properties: {
    addressPrefix: containerSubnetPrefix
    delegations: [
      {
        name: 'container-delegation'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
      }
    ]
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
  dependsOn: [
    functionSubnet
  ]
}

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: resourceGroup().location
  tags: resourceTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    defaultToOAuthAuthentication: true
    allowCrossTenantReplication: false
    allowSharedKeyAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: useExistingFunctionSubnet ? existingFunctionSubnetId : functionSubnet.id
          action: 'Allow'
        }
      ]
      defaultAction: 'Deny'
    }
    encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
        queue: {
          keyType: 'Account'
          enabled: true
        }
        table: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
    }
  }
}

// Blob Service
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: []
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    changeFeed: {
      enabled: false
    }
  }
}

// Required storage containers for Function App
resource containerEventHub 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'azure-webjobs-eventhub'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'None'
  }
}

resource containerHosts 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'azure-webjobs-hosts'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'None'
  }
}

resource containerSecrets 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'azure-webjobs-secrets'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'None'
  }
}

// Event Hub Namespace (created if no connection string provided)
resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = if (createEventHub) {
  name: eventHubNamespaceName
  location: resourceGroup().location
  tags: resourceTags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    isAutoInflateEnabled: true
    maximumThroughputUnits: 2
    kafkaEnabled: false
    zoneRedundant: false
    disableLocalAuth: false
  }
  dependsOn: [
    virtualNetwork
  ]
}

// Event Hub (created if no connection string provided)
resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = if (createEventHub) {
  parent: eventHubNamespace
  name: 'dynatrace'
  properties: {
    messageRetentionInDays: 1
    partitionCount: 1
    status: 'Active'
  }
}

// Event Hub Authorization Rule (created if no connection string provided)
resource eventHubAuthorization 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = if (createEventHub) {
  parent: eventHub
  name: 'ReadSharedAccessKey'
  properties: {
    rights: [
      'Listen'
    ]
  }
}

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = if (empty(appServicePlanId)) {
  name: appServicePlanName
  location: resourceGroup().location
  tags: resourceTags
  sku: {
    name: 'B3'
    tier: 'Basic'
    size: 'B3'
    family: 'B'
    capacity: 1
  }
  kind: 'linux'
  properties: {
    perSiteScaling: false
    maximumElasticWorkerCount: 1
    isSpot: false
    reserved: true
    isXenon: false
    hyperV: false
    targetWorkerCount: 0
    targetWorkerSizeId: 0
  }
  dependsOn: [
    storageAccount
  ]
}

// Function App
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: resourceGroup().location
  tags: resourceTags
  kind: 'functionapp,linux'
  identity: useUserAssignedMI ? {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  } : {
    type: 'SystemAssigned'
  }
  properties: {
    enabled: true
    serverFarmId: empty(appServicePlanId) ? appServicePlan.id : appServicePlanId
    reserved: true
    isXenon: false
    hyperV: false
    vnetRouteAllEnabled: true
    virtualNetworkSubnetId: useExistingFunctionSubnet ? existingFunctionSubnetId : functionSubnet.id
    scmSiteAlsoStopped: false
    clientAffinityEnabled: false
    clientCertEnabled: false
    clientCertMode: 'Required'
    hostNamesDisabled: false
    httpsOnly: true
    redundancyMode: 'None'
    storageAccountRequired: false
    keyVaultReferenceIdentity: 'SystemAssigned'
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: 'Python|3.9'
      requestTracingEnabled: false
      remoteDebuggingEnabled: false
      httpLoggingEnabled: false
      detailedErrorLoggingEnabled: false
      use32BitWorkerProcess: false
      webSocketsEnabled: false
      alwaysOn: true
      managedPipelineMode: 'Integrated'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      functionAppScaleLimit: 10
      minimumElasticInstanceCount: 0
    }
  }
  dependsOn: [
    storageAccount
  ]
}

// ===================================================================
// Outputs
// ===================================================================

@description('The Event Hub namespace name')
output eventHubNamespace string = createEventHub ? eventHubNamespace.name : 'N/A'

@description('The Event Hub namespace resource ID')
output eventHubNamespaceId string = createEventHub ? eventHubNamespace.id : 'N/A'

@description('The Event Hub name')
output computedEventHubName string = createEventHub ? eventHub.name : 'N/A'

@description('The Event Hub resource ID')
output eventHubId string = createEventHub ? eventHub.id : 'N/A'

@description('The Event Hub Authorization Rule ID')
output eventHubAuthRuleId string = createEventHub ? eventHubAuthorization.id : 'N/A'

@description('The storage account ID')
output storageAccountId string = storageAccount.id

@description('The storage account name')
output storageAccountName string = storageAccount.name

@description('The container subnet ID')
output containerSubnetId string = deployActiveGateContainer ? (useExistingContainerSubnet ? existingContainerSubnetId : containerSubnet.id) : 'N/A'

@description('The function subnet ID')
output functionSubnetId string = useExistingFunctionSubnet ? existingFunctionSubnetId : functionSubnet.id

@description('The function app name')
output functionAppName string = functionAppName

@description('The function app ID')
output functionAppId string = functionApp.id

@description('The function app URL')
output functionAppUrl string = 'https://${functionAppName}.azurewebsites.net'

@description('Virtual network name')
output virtualNetworkName string = useExistingVNet ? existingVNetName : virtualNetwork.name

@description('Virtual network ID')
output virtualNetworkId string = useExistingVNet ? existingVirtualNetworkId : virtualNetwork.id

@description('Function app resource summary')
output functionAppSummary object = {
  name: functionAppName
  id: functionApp.id
  url: 'https://${functionAppName}.azurewebsites.net'
  plan: empty(appServicePlanId) ? appServicePlan.id : appServicePlanId
}

@description('Storage account summary')
output storageAccountSummary object = {
  name: storageAccountName
  id: storageAccount.id
}

@description('Event Hub summary')
output eventHubSummary object = createEventHub ? {
  name: eventHub.name
  namespace: eventHubNamespace.name
  id: eventHub.id
} : {
  name: 'Using existing Event Hub'
  namespace: 'N/A'
  id: 'N/A'
}

@description('Networking summary')
output networkingSummary object = {
  virtualNetwork: useExistingVNet ? existingVNetName : virtualNetwork.name
  functionSubnet: useExistingFunctionSubnet ? 'Using existing subnet' : functionSubnet.name
  containerSubnet: deployActiveGateContainer ? (useExistingContainerSubnet ? 'Using existing subnet' : containerSubnet.name) : 'N/A'
  usingExistingVNet: useExistingVNet
}
