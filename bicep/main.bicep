@description('The name of the Azure Databricks workspace to create.')
param databricksResourceName string

@description('Google street API key to be used in the notebooks.')
@secure()
@minLength(15)
param googleStreetApiKey string

var acceleratorRepoName = 'databricks-accelerator-anti-money-laundering'
var randomString = uniqueString(resourceGroup().id, databricksResourceName, acceleratorRepoName)
var managedResourceGroupName = 'databricks-rg-${databricksResourceName}-${randomString}'
var location = resourceGroup().location

// Managed Identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: randomString
  location: location
}

// Role Assignment (Contributor Role)
resource resourceGroupRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(randomString)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor role ID
    )
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource createDatabricks 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'create-databricks-${randomString}'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.49.0' // Specify the Azure CLI version
    arguments: '-resourceName ${databricksResourceName} -resourceGroupName ${resourceGroup().name} -location ${location} -sku premium -managedResourceGroupName ${managedResourceGroupName}'
    scriptContent: '''
      # Define parameters
      resource_name=$1
      resource_group_name=$2
      location=$3
      sku=$4
      managed_resource_group_name=$5

      # Check if the workspace exists
      workspace=$(az databricks workspace show --resource-group "$resource_group_name" --name "$resource_name" --query "id" -o tsv 2>/dev/null)
      if [ -n "$workspace" ]; then
        # Retrieve the SKU of the existing workspace
        current_sku=$(az databricks workspace show --resource-group "$resource_group_name" --name "$resource_name" --query "sku.name" -o tsv)

        # Validate the SKU
        if [ "$current_sku" != "$sku" ]; then
          echo "The existing Databricks workspace does not have the required SKU '$sku'. Current SKU: $current_sku"
          exit 1
        fi
      else
        # Create a new workspace
        echo "Creating new Databricks workspace: $resource_name"
        az databricks workspace create \
          --name "$resource_name" \
          --resource-group "$resource_group_name" \
          --location "$location" \
          --sku "$sku" \
          --managed-resource-group "$managed_resource_group_name"

        # Wait for provisioning to complete
        retry_count=0
        while true; do
          provisioning_state=$(az databricks workspace show --resource-group "$resource_group_name" --name "$resource_name" --query "provisioningState" -o tsv)
          echo "Current state: $provisioning_state (attempt $retry_count)"
          if [ "$provisioning_state" == "Succeeded" ]; then
            break
          elif [ $retry_count -ge 40 ]; then
            echo "Timeout waiting for workspace provisioning."
            exit 1
          fi
          sleep 15
          retry_count=$((retry_count + 1))
        done
      fi

      # Output the workspace ID to signal completion
      workspace_id=$(az databricks workspace show --resource-group "$resource_group_name" --name "$resource_name" --query "id" -o tsv)
      echo "{\"WorkspaceId\": \"$workspace_id\", \"Exists\": \"True\"}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
    timeout: 'PT1H'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'PT2H'
  }
}

module databricksModule './databricks.bicep' = {
  name: 'databricks-module-${randomString}'
  params: {
    acceleratorRepoName: acceleratorRepoName
    databricksResourceName: databricksResourceName
    googleStreetApiKey: googleStreetApiKey
    location: location
    managedIdentityName: randomString
  }
  dependsOn: [
    createDatabricks
  ]
}

// Outputs
output databricksWorkspaceUrl string = databricksModule.outputs.databricksWorkspaceUrl
output databricksJobUrl string = databricksModule.outputs.databricksJobUrl
