/*
     Dynatrace Azure Log Forwarder - Post-Deployment RBAC Module
     
     This module handles post-deployment RBAC assignments and configuration,
     including managed identity assignment to function apps which must happen
     after the function app is fully deployed.
*/

targetScope = 'resourceGroup'

// ===================================================================
// Parameters
// ===================================================================

@description('User-assigned identity resource ID')
param userAssignedIdentityId string

@description('Event Hub namespace name')
param eventHubNamespace string

@description('Event Hub name')
param eventHubName string

// ===================================================================
// Resources
// ===================================================================

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = {
  name: '${eventHubNamespace}/$eventHubName'
}

// Role Assignment for User Assigned Identity (Event Hub Data Reader)
resource eventHubRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userAssignedIdentityId) && !empty(eventHubName) && !empty(eventHubNamespace)) {
  name: guid(eventHub.id, userAssignedIdentityId, 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde')
  scope: eventHub
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde')
    principalId: reference(userAssignedIdentityId, '2023-01-31').principalId
    principalType: 'ServicePrincipal'
  }
}

// ===================================================================
// Outputs
// ===================================================================

output configurationStatus string = 'SUCCESS'
output identityAssigned bool = !empty(userAssignedIdentityId)
output roleAssignmentsCreated bool = !empty(userAssignedIdentityId) && !empty(eventHubName)
