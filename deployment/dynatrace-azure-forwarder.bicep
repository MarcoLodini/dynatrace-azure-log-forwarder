@description('Dynatrace logs forwarder name')
param forwarderName string = 'dyntracelogs'

@description('Dynatrace destination (ActiveGate) URL')
param targetUrl string

@description('Dynatrace Paas Token')
@secure()
param targetPaasToken string = ''

@description('Dynatrace API Token')
@secure()
param targetAPIToken string

@description('Event hub connection string')
@secure()
param eventHubConnectionString string = ''

@description('Event hub name')
param eventHubName string

@description('Deploy Active Gate')
param deployActiveGateContainer bool = false

@description('Should send self monitoring metrics to Azure? true/false')
param selfMonitoringEnabled bool = false

@description('Should verify Dynatrace Logs Ingest endpoint SSL certificate? true/false')
param requireValidCertificate bool = false

@description('Azure tags')
param resourceTags object = {
  LogsForwarderDeployment: forwarderName
}

@description('Filter config')
param filterConfig string

@description('MI user id')
param eventhubConnectionClientId string = ''

@description('Managed Identity')
param eventhubConnectionCredentials string = ''

@description('Eventhub\'s host name')
param eventhubConnectionFullyQualifiedNamespace string = ''

var dtHost = replace(targetUrl, 'https://', '')
var registryUser = (contains(dtHost, '/e/') ? last(split(dtHost, '/e/')) : first(split(dtHost, '.')))
var image = '${dtHost}/linux/activegate:latest'
var virtualNetworkName = '${forwarderName}-vnet'
var functionSubnetName = 'functionapp'
var containerSubnetName = 'aci'
var appServicePlanName = '${forwarderName}-plan'
var functionName = '${forwarderName}-function'
var forwarderNameShort = take(forwarderName, 18)
var randomIdToMakeStorageAccountGloballyUnique = substring(uniqueString(forwarderName, resourceGroup().id), 0, 4)
var storageAccountName = '${forwarderNameShort}sa${randomIdToMakeStorageAccountGloballyUnique}'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-01-01' = if (deployActiveGateContainer) {
  name: virtualNetworkName
  location: resourceGroup().location
  tags: resourceTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '172.0.0.0/22'
      ]
    }
  }
}

resource virtualNetworkName_functionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployActiveGateContainer) {
  parent: virtualNetwork
  name: functionSubnetName
  properties: {
    addressPrefix: '172.0.1.0/24'
    serviceEndpoints: [
      {
        service: 'Microsoft.Storage'
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

resource virtualNetworkName_containerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployActiveGateContainer) {
  parent: virtualNetwork
  name: containerSubnetName
  properties: {
    addressPrefix: '172.0.0.0/24'
    delegations: [
      {
        name: 'private-subnet-delegation'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
      }
    ]
  }
}

resource forwarder 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = if (deployActiveGateContainer) {
  name: forwarderName
  location: resourceGroup().location
  tags: resourceTags
  properties: {
    sku: 'Standard'
    subnetIds: [
      {
        id: virtualNetworkName_containerSubnet.id
      }
    ]
    containers: [
      {
        name: forwarderName
        properties: {
          image: image
          ports: [
            {
              port: 9999
              protocol: 'TCP'
            }
          ]
          environmentVariables: [
            {
              name: 'DT_CAPABILITIES'
              value: 'log_analytics_collector'
            }
            {
              name: 'DT_ID_SKIP_HOSTNAME'
              value: 'true'
            }
            {
              name: 'DT_ID_SEED_SUBSCRIPTIONID'
              value: subscription().subscriptionId
            }
            {
              name: 'DT_ID_SEED_RESOURCEGROUP'
              value: resourceGroup().name
            }
            {
              name: 'DT_ID_SEED_RESOURCENAME'
              value: forwarderName
            }
          ]
          resources: {
            requests: {
              memoryInGB: 1
              cpu: 1
            }
          }
        }
      }
    ]
    imageRegistryCredentials: [
      {
        server: dtHost
        username: registryUser
        password: targetPaasToken
      }
    ]
    restartPolicy: 'Always'
    osType: 'Linux'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: resourceGroup().location
  tags: resourceTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'Storage'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: deployActiveGateContainer ? [
        {
          id: virtualNetworkName_functionSubnet.id
        }
      ] : null
      defaultAction: deployActiveGateContainer ? 'Deny' : 'Allow' //Setting this to "Deny" if deployActiveGateContainer is "true"; this seems to make sense considering previous if conditions
    }
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
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
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource storageAccountName_default 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: []
    }
    deleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = { //TODO: Since serverFarms cost, how about allowing users to choose the eventual serverFarm?
  name: appServicePlanName
  location: resourceGroup().location
  tags: resourceTags
  sku: {
    name: 'S1'
    tier: 'Standard'
    size: 'S1'
    family: 'S'
    capacity: 1
  }
  kind: 'Linux'
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
}

resource function 'Microsoft.Web/sites@2023-12-01' = {
  name: functionName
  location: resourceGroup().location
  tags: resourceTags
  kind: 'functionapp,linux'
  properties: {
    enabled: true
    serverFarmId: appServicePlan.id
    reserved: false
    isXenon: false
    hyperV: false
    virtualNetworkSubnetId: deployActiveGateContainer ? virtualNetworkName_functionSubnet.id : null
    scmSiteAlsoStopped: false
    clientAffinityEnabled: true
    clientCertEnabled: false
    hostNamesDisabled: false
    containerSize: 1536
    dailyMemoryTimeQuota: 0
    httpsOnly: true
    redundancyMode: 'None'
  }
}

resource functionName_appSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: function
  name: 'appsettings'
  properties: {
    FUNCTIONS_WORKER_RUNTIME: 'python'
    FUNCTIONS_EXTENSION_VERSION: '~4'
    DYNATRACE_URL: deployActiveGateContainer ? 'https://172.0.0.4:9999/e/${registryUser}' : targetUrl
    DYNATRACE_ACCESS_KEY: targetAPIToken
    EVENTHUB_CONNECTION_STRING: eventHubConnectionString
    EVENTHUB_NAME: eventHubName
    AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
    REQUIRE_VALID_CERTIFICATE: '${requireValidCertificate}'
    SELF_MONITORING_ENABLED: '${selfMonitoringEnabled}'
    RESOURCE_ID: function.id
    REGION: resourceGroup().location
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    FILTER_CONFIG: filterConfig
    EVENTHUB_CONNECTION_STRING__clientId: eventhubConnectionClientId
    EVENTHUB_CONNECTION_STRING__credential: eventhubConnectionCredentials
    EVENTHUB_CONNECTION_STRING__fullyQualifiedNamespace: eventhubConnectionFullyQualifiedNamespace
  }
}

resource functionName_web 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: function
  name: 'web'
  properties: {
    numberOfWorkers: 1
    netFrameworkVersion: 'v4.0'
    requestTracingEnabled: false
    remoteDebuggingEnabled: false
    httpLoggingEnabled: false
    logsDirectorySizeLimit: 35
    detailedErrorLoggingEnabled: false
    azureStorageAccounts: {}
    scmType: 'None'
    use32BitWorkerProcess: true
    webSocketsEnabled: false
    alwaysOn: true
    managedPipelineMode: 'Integrated'
    linuxFxVersion: 'Python|3.9'
  }
}

resource functionName_storageAccountName_default_azure_webjobs_eventhub 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storageAccountName_default
  name: 'azure-webjobs-eventhub'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'None'
  }
}

resource functionName_storageAccountName_default_azure_webjobs_hosts 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storageAccountName_default
  name: 'azure-webjobs-hosts'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'None'
  }
}

resource functionName_storageAccountName_default_azure_webjobs_secrets 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: storageAccountName_default
  name: 'azure-webjobs-secrets'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'None'
  }
}
