/*
     Dynatrace Azure Log Forwarder - ActiveGate Module
     
     This module deploys an ActiveGate container instance when
     a new ActiveGate deployment is required.
*/

targetScope = 'resourceGroup'

// ===================================================================
// Parameters
// ===================================================================

@description('Deployment name')
param deploymentName string

@description('Dynatrace target URL')
param targetUrl string

@description('Dynatrace PaaS token')
@secure()
param targetPaasToken string

@description('Container subnet ID')
param containerSubnetId string

@description('Static IP address for ActiveGate container (optional - if not provided, a dynamic IP will be used)')
param activeGateStaticIP string

@description('Resource tags')
param resourceTags object

// ===================================================================
// Variables
// ===================================================================

var containerGroupName = deploymentName

// Parse target URL for ActiveGate deployment
var targetUrlCleaned = trim(replace(targetUrl, 'https://', ''))
var dtHost = contains(targetUrlCleaned, '/') ? first(split(targetUrlCleaned, '/')) : targetUrlCleaned
var registryUser = contains(targetUrl, '/e/') ? last(split(targetUrl, '/e/')) : first(split(dtHost, '.'))
var activeGateImage = '${dtHost}/linux/activegate:latest'

// Use provided static IP or let Azure assign one dynamically
var useStaticIP = !empty(activeGateStaticIP)
var activeGatePrivateIP = useStaticIP ? activeGateStaticIP : 'Dynamic'

// ===================================================================
// Resources
// ===================================================================

// ActiveGate Container Instance
resource activeGateContainer 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: resourceGroup().location
  tags: resourceTags
  properties: {
    sku: 'Standard'
    subnetIds: [
      {
        id: containerSubnetId
      }
    ]
    containers: [
      {
        name: deploymentName
        properties: {
          image: activeGateImage
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
              value: deploymentName
            }
          ]
          resources: {
            requests: {
              memoryInGB: 1
              cpu: 1
            }
            limits: {
              memoryInGB: 2
              cpu: 2
            }
          }
          livenessProbe: {
            httpGet: {
              path: '/rest/health'
              port: 9999
              scheme: 'HTTPS'
            }
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
          }
          readinessProbe: {
            httpGet: {
              path: '/rest/health'
              port: 9999
              scheme: 'HTTPS'
            }
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
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
    ipAddress: {
      type: 'Private'
      ip: useStaticIP ? activeGatePrivateIP : null
      ports: [
        {
          port: 9999
          protocol: 'TCP'
        }
      ]
    }
  }
}

// ===================================================================
// Outputs
// ===================================================================

output containerGroupName string = activeGateContainer.name
output containerGroupId string = activeGateContainer.id
output activeGatePrivateIP string = activeGateContainer.properties.ipAddress.ip
output registryUser string = registryUser
output dtHost string = dtHost

output activeGateSummary object = {
  containerGroup: activeGateContainer.name
  state: 'Deployed'
  privateIP: activeGateContainer.properties.ipAddress.ip
  image: activeGateImage
  registryUser: registryUser
  capabilities: 'log_analytics_collector'
  ipAllocation: useStaticIP ? 'Static' : 'Dynamic'
}
