metadata description = 'Grants a role to the runbook identity at subscription scope.'

targetScope = 'subscription'

@description('Object (principal) ID of the managed identity the runbook runs as.')
param principalId string

@description('Role definition GUID to grant. Defaults to Contributor.')
param roleDefinitionId string = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    // Avoids a replication race where the freshly created identity is not yet
    // visible to the RBAC service.
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the created role assignment.')
output roleAssignmentId string = roleAssignment.id
