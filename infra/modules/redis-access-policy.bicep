@description('Name of the Redis Enterprise cluster')
param redisClusterName string

@description('Principal ID to grant access')
param principalId string

@description('Name for this access policy assignment')
param accessPolicyAssignmentName string

@description('Access policy name to assign (default, data-owner, data-reader, etc.)')
param accessPolicyName string = 'default'

// Reference existing Redis cluster and database
resource redis 'Microsoft.Cache/redisEnterprise@2024-09-01-preview' existing = {
  name: redisClusterName
}

resource database 'Microsoft.Cache/redisEnterprise/databases@2024-09-01-preview' existing = {
  parent: redis
  name: 'default'
}

// Access policy assignment
resource accessPolicy 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2024-09-01-preview' = {
  parent: database
  name: accessPolicyAssignmentName
  properties: {
    accessPolicyName: accessPolicyName
    user: {
      objectId: principalId
    }
  }
}

output accessPolicyId string = accessPolicy.id
