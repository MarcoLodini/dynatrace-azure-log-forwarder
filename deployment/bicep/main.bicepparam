// Dynatrace Azure Log Forwarder - Parameters File
// Fixed: Now correctly references main.bicep

using 'main.bicep'

// Core Configuration
param deploymentName = 'dynatracelogs'
param useExistingActiveGate = true
param targetUrl = 'https://your-environment.live.dynatrace.com'
param targetApiToken = '<YOUR_ACTUAL_API_TOKEN>'
param targetPaasToken = ''

// Event Hub
param eventHubConnectionString = ''
param eventHubName = ''

// Bring Your Own Infrastructure
param existingVirtualNetworkId = ''
param existingFunctionSubnetId = ''
param existingContainerSubnetId = ''
param activeGateStaticIP = ''

// Security
param requireValidCertificate = 'true'
param enableSelfMonitoring = 'false'
param filterConfig = ''

// Managed Identity
param enableUserAssignedManagedIdentity = 'false'
param eventhubConnectionClientId = ''
param managedIdentityResourceName = ''
param eventhubConnectionFullyQualifiedNamespace = ''

// Resources
param customConsumerGroup = '$Default'
param repositoryReleaseUrl = 'https://github.com/dynatrace-oss/dynatrace-azure-log-forwarder/releases/latest/download/'
param appServicePlanId = ''

// Tags
param tags = {
  Environment: 'Production'
  Project: 'LogForwarding'
  ManagedBy: 'Bicep'
}

// Options
param skipValidation = 'false'
