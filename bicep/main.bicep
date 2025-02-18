@allowed([
  'new'
  'existing'
])
param newOrExistingWorkspace string = 'new'

@description('The name of the Azure Databricks workspace to create.')
param databricksResourceName string



@description('Google street API key to be used in the notebooks.')
@secure()
@minLength(15)
param googleStreetApiKey string

var acceleratorRepoName = 'databricks-accelerator-anti-money-laundering'
var deploymentId = guid(resourceGroup().id)
var deploymentIdShort = substring(deploymentId, 0, 8)
var disablePublicIp = false
var managedResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', trimmedMRGName)
var managedResourceGroupName = 'databricks-rg-${databricksResourceName}-${uniqueString(databricksResourceName, resourceGroup().id)}'
var sku = 'premium'
var trimmedMRGName = substring(managedResourceGroupName, 0, min(length(managedResourceGroupName), 90))

// Managed Identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'dbw-id-${deploymentIdShort}'
  location: resourceGroup().location
}

// Create Databricks Workspace if `newOrExistingWorkspace` is 'new'
resource newDatabricks 'Microsoft.Databricks/workspaces@2024-05-01' = if (newOrExistingWorkspace == 'new') {
  name: databricksResourceName
  location: resourceGroup().location
  sku: {
    name: sku
  }
  properties: {
    managedResourceGroupId: managedResourceGroupId
    parameters: {
      enableNoPublicIp: {
        value: disablePublicIp
      }
    }
  }
}

// Reference to an existing Databricks workspace if `newOrExistingWorkspace` is 'existing'
resource databricks 'Microsoft.Databricks/workspaces@2024-05-01' existing = if (newOrExistingWorkspace == 'existing') {
  name: databricksResourceName
}

// Role Assignment (Contributor Role)
resource databricksRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedIdentity.id, 'Contributor', databricks.id ?? newDatabricks.id)
  scope: databricks ?? newDatabricks
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor role ID
    )
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Deployment Script
resource deploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'setup-databricks-script'
  location: resourceGroup().location
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.9.1'
    scriptContent: '''
      cd ~
      # Install dependencies
      curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

      # Create a secret scope
      databricks secrets create-scope solution-accelerator-cicd

      # Add the secret to the scope
      databricks secrets put-secret solution-accelerator-cicd google-api --string-value "${SECRET}"

      # Clone the GitHub repository
      repo_info=$(databricks repos create https://github.com/southworks/${ACCELERATOR_REPO_NAME} gitHub)
      REPO_ID=$(echo "$repo_info" | jq -r '.id')
      databricks repos update ${REPO_ID} --branch ${BRANCH_NAME}

      # Export the job template and modify it

      databricks workspace export /Users/${ARM_CLIENT_ID}/${ACCELERATOR_REPO_NAME}/bicep/job-template.json > job-template.json
      notebook_path="/Users/${ARM_CLIENT_ID}/${ACCELERATOR_REPO_NAME}/RUNME"
      jq ".tasks[0].notebook_task.notebook_path = \"${notebook_path}\"" job-template.json > job.json

      # Submit the Databricks job
      job_page_url=$(databricks jobs submit --json @./job.json | jq -r '.run_page_url')
      echo "{\"job_page_url\": \"$job_page_url\"}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
    environmentVariables: [
      {
        name: 'DATABRICKS_AZURE_RESOURCE_ID'
        value: databricks.id ?? newDatabricks.id
      }
      {
        name: 'BRANCH_NAME'
        value: 'main'
      }
      {
        name: 'ARM_CLIENT_ID'
        value: managedIdentity.properties.clientId
      }
      {
        name: 'ARM_USE_MSI'
        value: 'true'
      }
      {
        name: 'ACCELERATOR_REPO_NAME'
        value: acceleratorRepoName
      }
      {
        name: 'SECRET'
        secureValue: googleStreetApiKey
      }
    ]
    timeout: 'PT1H'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  dependsOn: [
    databricksRoleAssignment
  ]
}

// Outputs
output databricksWorkspaceUrl string = 'https://${(databricks ?? newDatabricks).properties.workspaceUrl}'
output databricksJobUrl string = deploymentScript.properties.outputs.job_page_url
