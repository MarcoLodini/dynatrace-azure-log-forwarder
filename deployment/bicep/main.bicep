/*
     Copyright 2021 Dynatrace LLC
     Enhanced Modular Implementation by Claude AI Assistant

     Licensed under the Apache License, Version 2.0 (the "License");
     you may not use this file except in compliance with the License.
     You may obtain a copy of the License at

         http://www.apache.org/licenses/LICENSE-2.0

     Unless required by applicable law or agreed to in writing, software
     distributed under the License is distributed on an "AS IS" BASIS,
     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
     See the License for the specific language governing permissions and
     limitations under the License.
*/

// ===================================================================
// Dynatrace Azure Log Forwarder - Main Orchestration Template
// ===================================================================
// This main template orchestrates the deployment of all components
// in the correct order with proper dependency management.

targetScope = 'resourceGroup'

// ===================================================================
// Parameters
// ===================================================================

@description('Dynatrace logs forwarder deployment name (3-20 lowercase alphanumeric characters only)')
@minLength(3)
@maxLength(20)
param deploymentName string

@description('Deploy ActiveGate in Azure Container Instance. Set to false to use existing ActiveGate or direct ingest.')
param useExistingActiveGate bool = true

@description('Dynatrace destination URL. For new ActiveGate: https://<environment_id>.live.dynatrace.com. For existing ActiveGate: https://<activegate>:9999/e/<environment_id>')
param targetUrl string

@description('Dynatrace API token with Ingest logs (v2) permission')
@secure()
param targetApiToken string

@description('Dynatrace PaaS token (required only when deploying new ActiveGate)')
@secure()
param targetPaasToken string = ''

@description('Event Hub connection string (if not provided, a new Event Hub will be created)')
@secure()
param eventHubConnectionString string = ''

@description('Event Hub name (required when using user-assigned managed identity)')
param eventHubName string = ''

@description('Enable SSL certificate validation for ActiveGate connection')
@allowed(['true', 'false'])
param requireValidCertificate string = 'true'

@description('Enable self-monitoring metrics to Azure')
@allowed(['true', 'false'])
param enableSelfMonitoring string = 'false'

@description('Filter configuration for log processing (e.g., "Level!=Informational")')
param filterConfig string = ''

@description('Azure resource tags as key-value pairs')
param tags object = {}

@description('Enable user-assigned managed identity for Event Hub connection')
@allowed(['true', 'false'])
param enableUserAssignedManagedIdentity string = 'false'

@description('Client ID of the user-assigned managed identity')
param eventhubConnectionClientId string = ''

@description('Name of the managed identity resource')
param managedIdentityResourceName string = ''

@description('Event Hub namespace fully qualified domain name')
param eventhubConnectionFullyQualifiedNamespace string = ''

@description('Custom Event Hub consumer group name')
param customConsumerGroup string = '$Default'

@description('Function package repository URL')
param repositoryReleaseUrl string = 'https://github.com/dynatrace-oss/dynatrace-azure-log-forwarder/releases/latest/download/'

@description('App Service Plan resource ID (if provided, existing plan will be used)')
param appServicePlanId string = ''

@description('Existing virtual network resource ID (optional - if not provided, a new VNet will be created)')
param existingVirtualNetworkId string = ''

@description('Existing subnet resource ID for Function App (required when using existing VNet)')
param existingFunctionSubnetId string = ''

@description('Existing subnet resource ID for ActiveGate container (required when using existing VNet and deploying ActiveGate)')
param existingContainerSubnetId string = ''

@description('Static IP address for ActiveGate container (optional - if not provided, a dynamic IP will be used)')
param activeGateStaticIP string = ''

@description('Skip pre-deployment validations (not recommended for production)')
@allowed(['true', 'false'])
param skipValidation string = 'false'

// ===================================================================
// Variables
// ===================================================================

var deployActiveGateContainer = (useExistingActiveGate == false)
var useUserAssignedMI = (enableUserAssignedManagedIdentity == 'true')
var useExistingVNet = !empty(existingVirtualNetworkId)
var createEventHub = empty(eventHubConnectionString)

// Build resource tags with deployment identifier
var resourceTags = union(tags, {
  LogsForwarderDeployment: deploymentName
})

// ===================================================================
// Module Deployments
// ===================================================================

// 1. Pre-deployment Validation
module validation 'modules/validation.bicep' = if (skipValidation == 'false') {
  name: 'validation-${deploymentName}'
  params: {
    deploymentName: deploymentName
    useExistingActiveGate: useExistingActiveGate
    targetUrl: targetUrl
    targetApiToken: targetApiToken
    eventHubConnectionString: eventHubConnectionString
    enableUserAssignedManagedIdentity: enableUserAssignedManagedIdentity
    eventHubName: eventHubName
    eventhubConnectionClientId: eventhubConnectionClientId
    managedIdentityResourceName: managedIdentityResourceName
    eventhubConnectionFullyQualifiedNamespace: eventhubConnectionFullyQualifiedNamespace
    resourceTags: resourceTags
  }
}

// 2. RBAC and Managed Identities (created early for use by other modules)
module rbac 'modules/rbac.bicep' = {
  name: 'rbac-${deploymentName}'
  params: {
    deploymentName: deploymentName
    enableUserAssignedManagedIdentity: useUserAssignedMI
    managedIdentityResourceName: managedIdentityResourceName
    resourceTags: resourceTags
  }
  dependsOn: [
    validation
  ]
}

// 3. Core Infrastructure
module coreInfrastructure 'modules/core-infrastructure.bicep' = {
  name: 'core-infrastructure-${deploymentName}'
  params: {
    deploymentName: deploymentName
    deployActiveGateContainer: deployActiveGateContainer
    eventHubConnectionString: eventHubConnectionString
    appServicePlanId: appServicePlanId
    useUserAssignedMI: useUserAssignedMI
    userAssignedIdentityId: useUserAssignedMI ? rbac.outputs.userAssignedIdentityId : ''
    existingVirtualNetworkId: existingVirtualNetworkId
    existingFunctionSubnetId: existingFunctionSubnetId
    existingContainerSubnetId: existingContainerSubnetId
    resourceTags: resourceTags
  }
}

// 4. ActiveGate Deployment (conditional)
module activeGate 'modules/activegate.bicep' = if (deployActiveGateContainer) {
  name: 'activegate-${deploymentName}'
  params: {
    deploymentName: deploymentName
    targetUrl: targetUrl
    targetPaasToken: targetPaasToken
    containerSubnetId: coreInfrastructure.outputs.containerSubnetId
    activeGateStaticIP: activeGateStaticIP
    resourceTags: resourceTags
  }
}

// 5. Function App Configuration and Code Deployment
module functionDeployment 'modules/function-deployment.bicep' = {
  name: 'function-deployment-${deploymentName}'
  params: {
    functionAppId: coreInfrastructure.outputs.functionAppId
    functionAppName: coreInfrastructure.outputs.functionAppName
    deployActiveGateContainer: deployActiveGateContainer
    targetUrl: targetUrl
    targetApiToken: targetApiToken
    computedEventHubName: coreInfrastructure.outputs.computedEventHubName
    eventHubNamespace: coreInfrastructure.outputs.eventHubNamespace
    requireValidCertificate: requireValidCertificate
    enableSelfMonitoring: enableSelfMonitoring
    filterConfig: filterConfig
    customConsumerGroup: customConsumerGroup
    useUserAssignedMI: useUserAssignedMI
    eventhubConnectionClientId: eventhubConnectionClientId
    eventhubConnectionFullyQualifiedNamespace: eventhubConnectionFullyQualifiedNamespace
    repositoryReleaseUrl: repositoryReleaseUrl
    deploymentIdentityId: rbac.outputs.deploymentIdentityId
    activeGatePrivateIP: deployActiveGateContainer ? activeGate.outputs.activeGatePrivateIP : ''
    resourceTags: resourceTags
  }
}

// 6. Post-deployment RBAC assignments and configuration
module postDeploymentRbac 'modules/post-deployment-rbac.bicep' = if (useUserAssignedMI) {
  name: 'post-deployment-rbac-${deploymentName}'
  params: {
    userAssignedIdentityId: rbac.outputs.userAssignedIdentityId
    eventHubNamespace: coreInfrastructure.outputs.eventHubNamespace
    eventHubName: coreInfrastructure.outputs.computedEventHubName
  }
  dependsOn: [
    functionDeployment
  ]
}

// ===================================================================
// Outputs
// ===================================================================

output functionAppName string = coreInfrastructure.outputs.functionAppName
output functionAppResourceId string = coreInfrastructure.outputs.functionAppId
output functionAppUrl string = coreInfrastructure.outputs.functionAppUrl

output eventHubNamespace string = createEventHub ? coreInfrastructure.outputs.eventHubNamespace : 'Using existing Event Hub'
output eventHubName string = createEventHub ? coreInfrastructure.outputs.computedEventHubName : eventHubName

output virtualNetworkName string = coreInfrastructure.outputs.virtualNetworkName
output virtualNetworkResourceId string = coreInfrastructure.outputs.virtualNetworkId
output usingExistingVNet bool = useExistingVNet

output activeGateDeployed bool = deployActiveGateContainer
output activeGatePrivateIP string = deployActiveGateContainer ? activeGate.outputs.activeGatePrivateIP : 'N/A'

output userAssignedIdentityEnabled bool = useUserAssignedMI
output userAssignedIdentityName string = useUserAssignedMI ? rbac.outputs.userAssignedIdentityName : 'N/A'
output userAssignedIdentityResourceId string = useUserAssignedMI ? rbac.outputs.userAssignedIdentityId : 'N/A'

output deploymentIdentityName string = rbac.outputs.deploymentIdentityName
output deploymentIdentityResourceId string = rbac.outputs.deploymentIdentityId

// Log viewer URL
output logViewerUrl string = (deployActiveGateContainer || contains(targetUrl, '.live.dynatrace.com')) ? '${targetUrl}/ui/log-monitoring?query=cloud.provider%3D%22azure%22' : 'Log viewer URL not available for existing ActiveGate deployments'

// Deployment validation and status information
output deploymentValidation object = {
  deploymentName: deploymentName
  targetUrlConfigured: targetUrl
  eventHubConfigured: createEventHub ? 'New Event Hub created' : 'Using existing Event Hub'
  selfMonitoringEnabled: (enableSelfMonitoring == 'true')
  filterConfigApplied: !empty(filterConfig)
  managedIdentityEnabled: useUserAssignedMI
  certificateValidationEnabled: (requireValidCertificate == 'true')
  vnetIntegrationEnabled: true
  usingExistingVNet: useExistingVNet
  activeGateDeployment: deployActiveGateContainer ? 'New ActiveGate Container' : 'Existing ActiveGate/Direct Ingest'
  activeGateStaticIP: !empty(activeGateStaticIP) ? activeGateStaticIP : 'Dynamic IP allocation'
  preValidationCompleted: (skipValidation == 'false')
  moduleArchitecture: 'Enhanced Modular Design with BYO Infrastructure Support'
}

// Connection information for troubleshooting
output connectionInfo object = {
  dynatraceUrl: (deployActiveGateContainer && activeGate.outputs.activeGatePrivateIP != null) ? 'https://${activeGate.outputs.activeGatePrivateIP}:9999/e/' : targetUrl
  eventHubConnectionMethod: useUserAssignedMI ? 'Managed Identity' : 'Resource Reference'
  functionSubnetId: coreInfrastructure.outputs.functionSubnetId
  storageNetworkAccess: 'VNet Restricted'
  deploymentMethod: 'Bicep Modular Template'
}

// Resource summary for cost tracking
output resourceSummary object = {
  functionApp: coreInfrastructure.outputs.functionAppSummary
  eventHub: coreInfrastructure.outputs.eventHubSummary
  networking: coreInfrastructure.outputs.networkingSummary
  activeGate: deployActiveGateContainer ? activeGate.outputs.activeGateSummary : {
    containerGroup: 'N/A'
    state: 'External/Not Deployed'
    privateIP: 'N/A'
  }
  identities: rbac.outputs.identitySummary
}

// Next steps and important information
output nextSteps object = {
  logMonitoring: 'Check logs in Dynatrace in 10 minutes: ${deployActiveGateContainer || contains(targetUrl, '.live.dynatrace.com') ? '${targetUrl}/ui/log-monitoring?query=cloud.provider%3D%22azure%22' : 'Contact your Dynatrace administrator for log viewer access'}'
  documentation: 'https://www.dynatrace.com/support/help/shortlink/azure-log-fwd'
  selfMonitoring: enableSelfMonitoring == 'true' ? 'Self-monitoring is enabled' : 'Consider enabling self-monitoring for diagnostics: https://www.dynatrace.com/support/help/shortlink/azure-log-fwd#self-monitoring-optional'
  prerequisites: 'Ensure all prerequisites are configured: https://www.dynatrace.com/support/help/shortlink/azure-log-fwd#anchor_prereq'
  troubleshooting: 'If no logs appear after 10 minutes, check the function app logs and Event Hub configuration'
  moduleInfo: 'This deployment uses a modular architecture for better maintainability and security'
}
