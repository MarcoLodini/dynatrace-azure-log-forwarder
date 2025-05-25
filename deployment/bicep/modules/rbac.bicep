/*
     Dynatrace Azure Log Forwarder - RBAC Module
     
     This module handles all managed identity creation and role assignments
     for secure access to Azure resources using zero-trust principles.
*/

targetScope = 'resourceGroup'

// ===================================================================
// Parameters
// ===================================================================

@description('Deployment name')
param deploymentName string

@description('Enable user-assigned managed identity')
param enableUserAssignedManagedIdentity bool

@description('Managed identity resource name')
param managedIdentityResourceName string

@description('Resource tags')
param resourceTags object

// ===================================================================
// Variables
// ===================================================================

var userAssignedIdentityName = !empty(managedIdentityResourceName) ? managedIdentityResourceName : '${deploymentName}-id'
var deploymentIdentityName = '${deploymentName}-deploy-id'

// ===================================================================
// Resources
// ===================================================================

// Deployment Identity (always created for code deployment operations)
resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deploymentIdentityName
  location: resourceGroup().location
  tags: resourceTags
}

// User Assigned Managed Identity (for Event Hub access when enabled)
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (enableUserAssignedManagedIdentity) {
  name: userAssignedIdentityName
  location: resourceGroup().location
  tags: resourceTags
}

// Role Assignment for Deployment Identity (Website Contributor for function deployment)
resource deploymentRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentIdentity.id, 'de139f84-1756-47ae-9be6-808fbbe84772')
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'de139f84-1756-47ae-9be6-808fbbe84772')
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Contributor role for deployment identity (needed for post-deployment configuration)
resource deploymentContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentIdentity.id, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ===================================================================
// Outputs
// ===================================================================

output deploymentIdentityId string = deploymentIdentity.id
output deploymentIdentityName string = deploymentIdentity.name
output deploymentIdentityPrincipalId string = deploymentIdentity.properties.principalId

output userAssignedIdentityId string = enableUserAssignedManagedIdentity ? userAssignedIdentity.id : ''
output userAssignedIdentityName string = enableUserAssignedManagedIdentity ? userAssignedIdentity.name : ''
output userAssignedIdentityPrincipalId string = enableUserAssignedManagedIdentity ? userAssignedIdentity.properties.principalId : ''
output userAssignedIdentityClientId string = enableUserAssignedManagedIdentity ? userAssignedIdentity.properties.clientId : ''

output identitySummary object = {
  deploymentIdentity: {
    name: deploymentIdentity.name
    resourceId: deploymentIdentity.id
    principalId: deploymentIdentity.properties.principalId
  }
  userAssignedIdentity: enableUserAssignedManagedIdentity ? {
    name: userAssignedIdentity.name
    resourceId: userAssignedIdentity.id
    principalId: userAssignedIdentity.properties.principalId
    clientId: userAssignedIdentity.properties.clientId
  } : {
    name: 'Not Enabled'
    resourceId: 'N/A'
    principalId: 'N/A'
    clientId: 'N/A'
  }
}