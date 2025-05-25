/*
     Dynatrace Azure Log Forwarder - Function Deployment Module
     
     This module handles Function App configuration and code deployment
     with enhanced retry logic matching the original bash script.
*/

targetScope = 'resourceGroup'

// ===================================================================
// Parameters
// ===================================================================

@description('Function App resource ID')
param functionAppId string

@description('Function App name')
param functionAppName string

@description('Deploy ActiveGate container')
param deployActiveGateContainer bool

@description('Dynatrace target URL')
param targetUrl string

@description('Dynatrace API token')
@secure()
param targetApiToken string

@description('Event Hub namespace name')
param eventHubNamespace string

@description('Computed Event Hub name')
param computedEventHubName string

@description('Require valid certificate')
param requireValidCertificate string

@description('Enable self-monitoring')
param enableSelfMonitoring string

@description('Filter configuration')
param filterConfig string

@description('Custom consumer group')
param customConsumerGroup string

@description('Use user-assigned managed identity')
param useUserAssignedMI bool

@description('Event Hub connection client ID')
param eventhubConnectionClientId string

@description('Event Hub fully qualified namespace')
param eventhubConnectionFullyQualifiedNamespace string

@description('Function package repository URL')
param repositoryReleaseUrl string

@description('Deployment identity resource ID')
param deploymentIdentityId string

@description('ActiveGate private IP')
param activeGatePrivateIP string

@description('Resource tags')
param resourceTags object

// ===================================================================
// Variables
// ===================================================================

var eventHubConnectionCredentials = useUserAssignedMI ? 'managedidentity' : ''

var managedIdentityAppSettings = useUserAssignedMI ? {
  EVENTHUB_CONNECTION_STRING__clientId: eventhubConnectionClientId
  EVENTHUB_CONNECTION_STRING__credential: eventHubConnectionCredentials
  EVENTHUB_CONNECTION_STRING__fullyQualifiedNamespace: eventhubConnectionFullyQualifiedNamespace
} : {}

// Parse target URL for ActiveGate deployment
var targetUrlCleaned = trim(replace(targetUrl, 'https://', ''))
var dtHost = contains(targetUrlCleaned, '/') ? first(split(targetUrlCleaned, '/')) : targetUrlCleaned
var registryUser = contains(targetUrl, '/e/') ? last(split(targetUrl, '/e/')) : first(split(dtHost, '.'))

// ===================================================================
// Resources
// ===================================================================

// Function App Settings
resource functionAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  name: '${functionAppName}/appsettings'
  properties: {
    // Function runtime settings
    FUNCTIONS_WORKER_RUNTIME: 'python'
    FUNCTIONS_EXTENSION_VERSION: '~4'
    PYTHON_ISOLATE_WORKER_DEPENDENCIES: '1'
    
    // Dynatrace configuration
    DYNATRACE_URL: deployActiveGateContainer ? 'https://${activeGatePrivateIP}:9999/e/${registryUser}' : targetUrl
    DYNATRACE_ACCESS_KEY: targetApiToken
    
    // Event Hub configuration
    EVENTHUB_NAME: computedEventHubName
    EVENTHUB_NAMESPACE: eventHubNamespace
    
    // Application settings
    REQUIRE_VALID_CERTIFICATE: requireValidCertificate
    SELF_MONITORING_ENABLED: enableSelfMonitoring
    RESOURCE_ID: functionAppId
    REGION: resourceGroup().location
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    ENABLE_ORYX_BUILD: 'true'
    FILTER_CONFIG: filterConfig
    CONSUMER_GROUP: customConsumerGroup
    
    // Managed Identity settings (when enabled)
    ...managedIdentityAppSettings
    
    // Security and monitoring
    WEBSITE_HTTPLOGGING_RETENTION_DAYS: '3'
    WEBSITE_LOAD_CERTIFICATES: '*'
    WEBSITE_RUN_FROM_PACKAGE: '0'
    
    // Performance settings
    WEBSITE_MAX_DYNAMIC_APPLICATION_SCALE_OUT: '10'
    WEBSITE_ENABLE_SYNC_UPDATE_SITE: 'true'
    WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'false'
  }
}

// Function Code Deployment with enhanced retry logic
resource functionCodeDeployment 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'function-code-deployment'
  location: resourceGroup().location
  tags: resourceTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentityId}': {}
    }
  }
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.50.0'
    scriptContent: '''
      #!/bin/bash
      
      # Enhanced function code deployment with retry logic matching bash script
      
      log_info() { echo "$(date +%T) INFO: $1"; }
      log_warn() { echo "$(date +%T) WARNING: $1"; }
      log_error() { echo "$(date +%T) ERROR: $1"; }
      
      log_info "=== Starting Function Code Deployment ==="
      
      # Download function package
      log_info "Downloading function code package from: ${FUNCTION_PACKAGE_URL}${FUNCTION_PACKAGE_NAME}"
      
      MAX_DOWNLOAD_RETRIES=3
      DOWNLOAD_ATTEMPT=1
      
      while [ $DOWNLOAD_ATTEMPT -le $MAX_DOWNLOAD_RETRIES ]; do
        log_info "Download attempt ${DOWNLOAD_ATTEMPT}"
        
        if wget -q "${FUNCTION_PACKAGE_URL}${FUNCTION_PACKAGE_NAME}" -O "${FUNCTION_PACKAGE_NAME}"; then
          log_info "Package downloaded successfully"
          break
        else
          if [ $DOWNLOAD_ATTEMPT -lt $MAX_DOWNLOAD_RETRIES ]; then
            log_warn "Download failed, retrying in 10 seconds..."
            sleep 10
          else
            log_error "Failed to download package after ${MAX_DOWNLOAD_RETRIES} attempts"
            exit 1
          fi
        fi
        ((DOWNLOAD_ATTEMPT++))
      done
      
      # Verify package was downloaded
      if [ ! -f "${FUNCTION_PACKAGE_NAME}" ]; then
        log_error "Function package not found after download"
        exit 1
      fi
      
      PACKAGE_SIZE=$(ls -lh "${FUNCTION_PACKAGE_NAME}" | awk '{print $5}')
      log_info "Package size: ${PACKAGE_SIZE}"
      
      # Wait for function app to warm up (matching bash script timing)
      log_info "Waiting for function app to warm up (3 minutes)..."
      sleep 180
      
      # Deploy function code with retry logic
      log_info "Deploying function code to ${FUNCTIONAPP_NAME}..."
      
      MAX_DEPLOY_RETRIES=3
      DEPLOY_ATTEMPT=1
      
      while [ $DEPLOY_ATTEMPT -le $MAX_DEPLOY_RETRIES ]; do
        log_info "Deployment attempt ${DEPLOY_ATTEMPT}"
        
        # Create log file for this attempt
        DEPLOYMENT_LOG="deployment-attempt-${DEPLOY_ATTEMPT}.log"
        
        # Deploy with verbose logging
        if az webapp deploy \
          --name "${FUNCTIONAPP_NAME}" \
          --resource-group "${FUNCTIONAPP_RESOURCEGROUP}" \
          --src-path "${FUNCTION_PACKAGE_NAME}" \
          --type zip \
          --async true \
          --verbose 2>&1 | tee "${DEPLOYMENT_LOG}"; then
          
          log_info "Deployment command completed successfully"
          
          # Check for specific error patterns
          if grep -q "Status Code: 504" "${DEPLOYMENT_LOG}"; then
            log_warn "Timeout detected in deployment logs"
            if [ $DEPLOY_ATTEMPT -lt $MAX_DEPLOY_RETRIES ]; then
              log_warn "Retrying in 10 seconds..."
              sleep 10
              ((DEPLOY_ATTEMPT++))
              continue
            else
              log_error "Deployment failed with timeout after ${MAX_DEPLOY_RETRIES} attempts"
              exit 1
            fi
          else
            log_info "Deployment successful"
            break
          fi
        else
          if [ $DEPLOY_ATTEMPT -lt $MAX_DEPLOY_RETRIES ]; then
            log_warn "Deployment failed, retrying in 10 seconds..."
            sleep 10
          else
            log_error "Deployment failed after ${MAX_DEPLOY_RETRIES} attempts"
            cat "${DEPLOYMENT_LOG}"
            exit 1
          fi
        fi
        ((DEPLOY_ATTEMPT++))
      done
      
      # Verify deployment by checking function app status
      log_info "Verifying function app status..."
      if az webapp show --name "${FUNCTIONAPP_NAME}" --resource-group "${FUNCTIONAPP_RESOURCEGROUP}" --query "state" -o tsv | grep -q "Running"; then
        log_info "Function app is running"
      else
        log_warn "Function app may not be running yet"
      fi
      
      # Clean up
      log_info "Cleaning up deployment files..."
      rm -f "${FUNCTION_PACKAGE_NAME}" deployment-attempt-*.log
      
      log_info "=== Function code deployment completed successfully ==="
      echo "DEPLOYMENT_STATUS=SUCCESS" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
    retentionInterval: 'P1D'
    timeout: 'PT30M'
    environmentVariables: [
      {
        name: 'FUNCTION_PACKAGE_URL'
        value: repositoryReleaseUrl
      }
      {
        name: 'FUNCTION_PACKAGE_NAME'
        value: 'dynatrace-azure-log-forwarder.zip'
      }
      {
        name: 'FUNCTIONAPP_NAME'
        value: functionAppName
      }
      {
        name: 'FUNCTIONAPP_RESOURCEGROUP'
        value: resourceGroup().name
      }
    ]
  }
  dependsOn: [
    functionAppSettings
  ]
}

// ===================================================================
// Outputs
// ===================================================================

output deploymentStatus string = 'SUCCESS'
output functionConfigured bool = true
output codeDeployed bool = true
