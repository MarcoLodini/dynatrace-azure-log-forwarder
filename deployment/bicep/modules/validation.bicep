/*
     Dynatrace Azure Log Forwarder - Validation Module
     
     This module handles pre-deployment validation to ensure all
     parameters and connectivity requirements are met before
     proceeding with the actual deployment.
*/

targetScope = 'resourceGroup'

// ===================================================================
// Parameters
// ===================================================================

@description('Deployment name for validation')
param deploymentName string

@description('Use existing ActiveGate flag')
param useExistingActiveGate bool

@description('Dynatrace target URL')
param targetUrl string

@description('Dynatrace API token')
@secure()
param targetApiToken string

@description('Event Hub connection string')
@secure()
param eventHubConnectionString string

@description('Enable user-assigned managed identity')
param enableUserAssignedManagedIdentity string

@description('Event Hub name')
param eventHubName string

@description('Event Hub connection client ID')
param eventhubConnectionClientId string

@description('Managed identity resource name')
param managedIdentityResourceName string

@description('Event Hub fully qualified namespace')
param eventhubConnectionFullyQualifiedNamespace string

@description('Resource tags')
param resourceTags object

// ===================================================================
// Variables
// ===================================================================

var deploymentIdentityName = '${deploymentName}-deploy-id'

// ===================================================================
// Resources
// ===================================================================

// Deployment Identity for validation script
resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deploymentIdentityName
  location: resourceGroup().location
  tags: resourceTags
}

// Role Assignment for Deployment Identity
resource deploymentRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentIdentity.id, 'de139f84-1756-47ae-9be6-808fbbe84772')
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'de139f84-1756-47ae-9be6-808fbbe84772')
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Pre-deployment Validation Script
resource preDeploymentValidation 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'pre-deployment-validation'
  location: resourceGroup().location
  tags: resourceTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentity.id}': {}
    }
  }
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.50.0'
    retentionInterval: 'P1D'
    timeout: 'PT10M'
    scriptContent: '''
      # Enhanced pre-deployment validation matching bash script logic
      
      echo "=== Starting Pre-deployment Validation ==="
      
      # Function definitions
      log_info() { echo "$(date +%T) INFO: $1"; }
      log_warn() { echo "$(date +%T) WARNING: $1"; }
      log_error() { echo "$(date +%T) ERROR: $1"; }
      
      VALIDATION_FAILED=false
      
      # 1. Azure CLI Version Check (prevent known v2.29.0 bug)
      log_info "Checking Azure CLI version..."
      CLI_VERSION=$(az version --query '"azure-cli"' -o tsv)
      if [ "$CLI_VERSION" = "2.29.0" ]; then
        log_error "Azure CLI version 2.29.0 has known bugs. Please upgrade."
        VALIDATION_FAILED=true
      else
        log_info "Azure CLI version: $CLI_VERSION (OK)"
      fi
      
      # 2. Parameter validation using regex patterns
      log_info "Validating deployment parameters..."
      
      # Deployment name validation (bash: ^[a-z0-9]{3,20}$)
      if ! echo "$DEPLOYMENT_NAME" | grep -qE '^[a-z0-9]{3,20}$'; then
        log_error "Invalid deployment name. Must be 3-20 lowercase alphanumeric characters."
        VALIDATION_FAILED=true
      fi
      
      # Event Hub connection string validation (when provided)
      if [ -n "$EVENT_HUB_CONNECTION_STRING" ] && [ "$ENABLE_USER_ASSIGNED_MI" != "true" ]; then
        if ! echo "$EVENT_HUB_CONNECTION_STRING" | grep -qE '^Endpoint=sb://.*EntityPath=[^[:space:]]+$'; then
          log_error "Invalid Event Hub connection string format."
          VALIDATION_FAILED=true
        fi
      fi
      
      # Target URL validation based on ActiveGate deployment choice
      if [ "$USE_EXISTING_ACTIVE_GATE" = "false" ]; then
        # New ActiveGate: must be Dynatrace SaaS URL
        if ! echo "$TARGET_URL" | grep -qE '^https://[-a-zA-Z0-9@:%._+~=]{1,255}\.live\.dynatrace\.com/?(/e/[a-z0-9-]{36}/?)?$'; then
          log_error "Invalid target URL for new ActiveGate deployment. Expected: https://<env>.live.dynatrace.com"
          VALIDATION_FAILED=true
        fi
      else
        # Existing ActiveGate or direct ingest
        if ! echo "$TARGET_URL" | grep -qE '^https://[-a-zA-Z0-9@:%._+~=]{1,255}(\.live\.dynatrace\.com)?(/e/[-a-z0-9]{1,36})?/?$'; then
          log_error "Invalid target URL format."
          VALIDATION_FAILED=true
        fi
      fi
      
      # 3. ActiveGate health check (for existing ActiveGate)
      if [ "$USE_EXISTING_ACTIVE_GATE" = "true" ] && [ "$SKIP_CONNECTIVITY_CHECK" != "true" ]; then
        log_info "Checking ActiveGate health..."
        HEALTH_URL="${TARGET_URL%/}/rest/health"
        
        if HEALTH_RESPONSE=$(curl -ksS "$HEALTH_URL" --connect-timeout 20 --max-time 30 2>/dev/null); then
          if [ "$HEALTH_RESPONSE" = "RUNNING" ] || [ "$HEALTH_RESPONSE" = '"RUNNING"' ]; then
            log_info "ActiveGate health check: RUNNING (OK)"
          else
            log_warn "ActiveGate health check returned: $HEALTH_RESPONSE (Expected: RUNNING)"
            log_warn "This may be normal if ActiveGate doesn't allow public access."
          fi
        else
          log_warn "Failed to connect to ActiveGate health endpoint."
          log_warn "This may be normal if ActiveGate doesn't allow public access."
        fi
      fi
      
      # 4. API Token validation
      if [ "$SKIP_CONNECTIVITY_CHECK" != "true" ]; then
        log_info "Validating Dynatrace API token permissions..."
        API_URL="${TARGET_URL%/}/api/v2/apiTokens/lookup"
        
        if API_RESPONSE=$(curl -k -s -X POST \
          -d "{\"token\":\"$TARGET_API_TOKEN\"}" \
          "$API_URL" \
          -H "accept: application/json; charset=utf-8" \
          -H "Content-Type: application/json; charset=utf-8" \
          -H "Authorization: Api-Token $TARGET_API_TOKEN" \
          --connect-timeout 20 --max-time 30 \
          -w "<<HTTP_CODE>>%{http_code}" 2>/dev/null); then
          
          HTTP_CODE=$(echo "$API_RESPONSE" | sed -n 's/.*<<HTTP_CODE>>\([0-9]*\)$/\1/p')
          RESPONSE_BODY=$(echo "$API_RESPONSE" | sed 's/<<HTTP_CODE>>[0-9]*$//')
          
          if [ "$HTTP_CODE" -ge 300 ]; then
            log_error "API token validation failed (HTTP $HTTP_CODE): $RESPONSE_BODY"
            VALIDATION_FAILED=true
          elif ! echo "$RESPONSE_BODY" | grep -q '"logs.ingest"'; then
            log_error "API token missing required 'logs.ingest' permission."
            VALIDATION_FAILED=true
          else
            log_info "API token validation: OK (logs.ingest permission confirmed)"
          fi
        else
          log_warn "Failed to validate API token. This may be normal if endpoint doesn't allow public access."
        fi
        
        # 5. Test log ingest endpoint
        log_info "Testing log ingest endpoint..."
        INGEST_URL="${TARGET_URL%/}/api/v2/logs/ingest"
        TEST_LOG='{"timestamp":"'$(date --iso-8601=seconds)'","cloud.provider":"azure","content":"Azure Log Forwarder pre-deployment test","severity":"INFO"}'
        
        if INGEST_RESPONSE=$(curl -k -s -X POST \
          -d "$TEST_LOG" \
          "$INGEST_URL" \
          -H "accept: application/json; charset=utf-8" \
          -H "Content-Type: application/json; charset=utf-8" \
          -H "Authorization: Api-Token $TARGET_API_TOKEN" \
          --connect-timeout 20 --max-time 30 \
          -w "<<HTTP_CODE>>%{http_code}" 2>/dev/null); then
          
          HTTP_CODE=$(echo "$INGEST_RESPONSE" | sed -n 's/.*<<HTTP_CODE>>\([0-9]*\)$/\1/p')
          RESPONSE_BODY=$(echo "$INGEST_RESPONSE" | sed 's/<<HTTP_CODE>>[0-9]*$//')
          
          if [ "$HTTP_CODE" -ge 300 ]; then
            log_error "Log ingest test failed (HTTP $HTTP_CODE): $RESPONSE_BODY"
            VALIDATION_FAILED=true
          else
            log_info "Log ingest test: OK"
          fi
        else
          log_warn "Failed to test log ingest endpoint. This may be normal if endpoint doesn't allow public access."
        fi
      fi
      
      # 6. User-assigned managed identity parameter validation
      if [ "$ENABLE_USER_ASSIGNED_MI" = "true" ]; then
        log_info "Validating user-assigned managed identity parameters..."
        
        if [ -z "$EVENT_HUB_NAME" ]; then
          log_error "Event Hub name is required when using user-assigned managed identity."
          VALIDATION_FAILED=true
        fi
        
        if [ -z "$EVENT_HUB_CONNECTION_CLIENT_ID" ]; then
          log_error "Event Hub connection client ID is required when using user-assigned managed identity."
          VALIDATION_FAILED=true
        fi
        
        if [ -z "$MANAGED_IDENTITY_RESOURCE_NAME" ]; then
          log_error "Managed identity resource name is required when using user-assigned managed identity."
          VALIDATION_FAILED=true
        fi
        
        if [ -z "$EVENT_HUB_CONNECTION_FULLY_QUALIFIED_NAMESPACE" ]; then
          log_error "Event Hub fully qualified namespace is required when using user-assigned managed identity."
          VALIDATION_FAILED=true
        fi
      fi
      
      # Final validation result
      if [ "$VALIDATION_FAILED" = "true" ]; then
        log_error "Pre-deployment validation failed. Please fix the issues above and retry."
        exit 1
      else
        log_info "=== Pre-deployment validation completed successfully ==="
        echo "VALIDATION_STATUS=SUCCESS" > $AZ_SCRIPTS_OUTPUT_PATH
      fi
    '''
    environmentVariables: [
      {
        name: 'DEPLOYMENT_NAME'
        value: deploymentName
      }
      {
        name: 'USE_EXISTING_ACTIVE_GATE'
        value: string(useExistingActiveGate)
      }
      {
        name: 'TARGET_URL'
        value: targetUrl
      }
      {
        name: 'TARGET_API_TOKEN'
        secureValue: targetApiToken
      }
      {
        name: 'EVENT_HUB_CONNECTION_STRING'
        secureValue: eventHubConnectionString
      }
      {
        name: 'ENABLE_USER_ASSIGNED_MI'
        value: enableUserAssignedManagedIdentity
      }
      {
        name: 'EVENT_HUB_NAME'
        value: eventHubName
      }
      {
        name: 'EVENT_HUB_CONNECTION_CLIENT_ID'
        value: eventhubConnectionClientId
      }
      {
        name: 'MANAGED_IDENTITY_RESOURCE_NAME'
        value: managedIdentityResourceName
      }
      {
        name: 'EVENT_HUB_CONNECTION_FULLY_QUALIFIED_NAMESPACE'
        value: eventhubConnectionFullyQualifiedNamespace
      }
      {
        name: 'SKIP_CONNECTIVITY_CHECK'
        value: 'false'
      }
    ]
  }
  dependsOn: [
    deploymentRoleAssignment
  ]
}

// ===================================================================
// Outputs
// ===================================================================

output deploymentIdentityId string = deploymentIdentity.id
output deploymentIdentityName string = deploymentIdentity.name
output deploymentIdentityPrincipalId string = deploymentIdentity.properties.principalId
output validationStatus string = 'SUCCESS'