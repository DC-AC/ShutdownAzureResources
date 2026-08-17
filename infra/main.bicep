metadata description = '''
Deploys the ShutdownAzureResources cost-optimizer runbook into an Azure Automation
account: a PowerShell 7.2 runbook, the Az modules it needs, a managed identity, an
optional daily schedule, and an optional Contributor role assignment.
'''

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
//  Automation account
// ---------------------------------------------------------------------------

@description('Name of the Azure Automation account to create or update.')
@minLength(6)
@maxLength(50)
param automationAccountName string

@description('Region for the Automation account. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('''Automation account pricing tier. Free includes 500 job minutes/month, which
is normally enough for one nightly run. Basic bills per minute beyond that.''')
@allowed([
  'Free'
  'Basic'
])
param sku string = 'Free'

@description('''Disable local (key-based) authentication on the Automation account. Leave true
unless you need classic webhook or agent-registration keys; Entra ID auth is unaffected.''')
param disableLocalAuth bool = true

@description('Allow the Automation account to be reached over the public internet. Set false only when using Private Link plus a Hybrid Runbook Worker.')
param publicNetworkAccess bool = true

@description('Tags applied to the Automation account.')
param tags object = {}

// ---------------------------------------------------------------------------
//  Identity
// ---------------------------------------------------------------------------

@description('''Resource ID of an existing user-assigned managed identity. Leave empty to
create and use a system-assigned identity instead.''')
param userAssignedIdentityResourceId string = ''

@description('''Assign a subscription-scope role to the runbook identity. Requires the deploying
principal to be Owner or User Access Administrator. Set false to grant access yourself
afterwards (see README).''')
param assignSubscriptionRole bool = true

@description('Role definition GUID granted to the identity at subscription scope. Defaults to Contributor.')
param roleDefinitionId string = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

// ---------------------------------------------------------------------------
//  Runbook
// ---------------------------------------------------------------------------

@description('Name of the runbook inside the Automation account.')
param runbookName string = 'ShutdownAzureResources'

@description('URI the runbook content is published from.')
param runbookScriptUri string = 'https://raw.githubusercontent.com/DC-AC/ShutdownAzureResources/master/Runbook.ps1'

@description('''Content version stamped on the runbook. Bump this when redeploying so Azure
Automation re-fetches the script from runbookScriptUri.''')
param runbookContentVersion string = '2.0.0.0'

@description('Write verbose streams to the job log. Useful while tuning, noisy in steady state.')
param logVerbose bool = false

@description('Write progress records to the job log.')
param logProgress bool = false

// ---------------------------------------------------------------------------
//  Runbook behaviour (passed through to the scheduled job)
// ---------------------------------------------------------------------------

@description('''SAFETY: when true the runbook reports what it would do and changes nothing.
Deploy with true, read one job output, then redeploy with false.''')
param dryRun bool = true

@description('Subscription IDs to process. Empty means every enabled subscription the identity can see.')
param subscriptionIds array = []

@description('Resource groups and resources carrying this tag name/value pair are never touched.')
param exemptTagName string = 'env'
param exemptTagValue string = 'production'

@description('Per-resource opt-out tag. Any resource tagged with this name and a value of true/yes/1 is skipped.')
param resourceExemptTagName string = 'CostOptimizerExempt'

@description('''Any other Runbook.ps1 parameter, merged into the scheduled job. Use this for
the feature switches and tuning knobs, for example:
  { DeleteOldSnapshots: 'true', TargetDiskSku: 'Standard_LRS', UnattachedDiskMinAgeDays: '14' }
Azure Automation parses each value as JSON, so booleans must be the literals 'true' or
'false' and numbers must be unquoted digits.''')
param runbookParameterOverrides object = {}

// ---------------------------------------------------------------------------
//  Schedule
// ---------------------------------------------------------------------------

@description('Create a recurring schedule for the runbook.')
param createSchedule bool = true

@description('''Link the runbook to the schedule.

Azure Automation job schedules are NOT idempotent in ARM. Redeploying a template that
contains one fails with "A job schedule for the specified runbook and schedule already
exists", and using a fresh GUID does not help because the conflict is on the
runbook-plus-schedule pair, not the name.

So: leave this true for the first deployment, and set it false on every redeployment into an
account that already has the link. To change the runbook parameters afterwards, re-register
the link instead of redeploying (see the README "Going live" section).''')
param createJobSchedule bool = true

@description('Name of the schedule resource.')
param scheduleName string = 'Nightly-Shutdown'

@description('How often the runbook runs.')
@allowed([
  'Hour'
  'Day'
  'Week'
  'Month'
])
param scheduleFrequency string = 'Day'

@description('Interval between runs, in units of scheduleFrequency.')
@minValue(1)
param scheduleInterval int = 1

@description('''Wall-clock time of day for the first run, as HH:mm:ss, interpreted in
scheduleTimeZone. Defaults to 19:00 the day after deployment.''')
param scheduleTimeOfDay string = '19:00:00'

@description('''IANA time zone the schedule runs in, for example America/New_York. Etc/UTC
keeps the run time fixed year-round; a named zone follows daylight saving.''')
param scheduleTimeZone string = 'Etc/UTC'

@description('''Explicit ISO-8601 start time. Leave empty to start one full period after
deployment, which is always safely in the future.''')
param scheduleStartTime string = ''

@description('Do not edit. Used to compute a schedule start time in the future.')
param baseTime string = utcNow('yyyy-MM-dd')

// ---------------------------------------------------------------------------
//  Modules
// ---------------------------------------------------------------------------

@description('''Az modules imported into the PowerShell 7.2 runtime, as objects of the shape
{ name: 'Az.Compute', version: '11.8.0' }. Leave a version empty to pull the latest from the
PowerShell Gallery; pin it for reproducible deployments. Az.Accounts is always imported
first regardless of its position in this array.

Declared as a plain array rather than a user-defined type on purpose: user-defined types
force the compiled template to languageVersion 2.0, which the portal "Deploy to Azure"
button does not reliably accept.''')
param powerShellModules array = [
  { name: 'Az.Accounts', version: '5.5.2' }
  { name: 'Az.Resources', version: '10.1.0' }
  { name: 'Az.Compute', version: '11.8.0' }
  { name: 'Az.Sql', version: '7.0.0' }
  { name: 'Az.Network', version: '8.1.0' }
  { name: 'Az.Storage', version: '9.7.2' }
  { name: 'Az.Monitor', version: '8.0.0' }
  { name: 'Az.Websites', version: '4.0.0' }
  { name: 'Az.Aks', version: '7.2.1' }
  { name: 'Az.ContainerInstance', version: '5.0.0' }
  { name: 'Az.Synapse', version: '3.3.0' }
  { name: 'Az.Fabric', version: '1.0.0' }
]

// ---------------------------------------------------------------------------
//  Observability
// ---------------------------------------------------------------------------

@description('Resource ID of a Log Analytics workspace to send job logs and streams to. Empty disables diagnostics.')
param logAnalyticsWorkspaceId string = ''

// ---------------------------------------------------------------------------
//  Computed
// ---------------------------------------------------------------------------

var useUserAssigned = !empty(userAssignedIdentityResourceId)

// Every other Az module binds against Az.Accounts, so it has to import first.
// The loop below is serial, so sorting it to the front is enough to order the whole set.
var orderedModules = concat(
  filter(powerShellModules, m => m.name == 'Az.Accounts'),
  filter(powerShellModules, m => m.name != 'Az.Accounts')
)

var galleryRoot = 'https://www.powershellgallery.com/api/v2/package'

// Tomorrow at the requested time of day. Anchoring a full day out keeps the first run in
// the future for every frequency, including hourly, where adding just one period to a fixed
// time of day can land in the past and Azure rejects start times less than 5 minutes away.
var computedStartTime = dateTimeAdd('${baseTime}T${scheduleTimeOfDay}Z', 'P1D')
var effectiveStartTime = empty(scheduleStartTime) ? computedStartTime : scheduleStartTime

// Automation parses these strings as JSON, so booleans and arrays must be JSON literals.
var runbookJobParameters = {
  DryRun: dryRun ? 'true' : 'false'
  SubscriptionIds: string(subscriptionIds)
  ExemptTagName: exemptTagName
  ExemptTagValue: exemptTagValue
  ResourceExemptTagName: resourceExemptTagName
  UserAssignedIdentityClientId: useUserAssigned ? userAssignedIdentity!.properties.clientId : ''
}

// ---------------------------------------------------------------------------
//  Resources
// ---------------------------------------------------------------------------

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (useUserAssigned) {
  name: last(split(userAssignedIdentityResourceId, '/'))
  scope: resourceGroup(split(userAssignedIdentityResourceId, '/')[2], split(userAssignedIdentityResourceId, '/')[4])
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: useUserAssigned
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${userAssignedIdentityResourceId}': {}
        }
      }
    : {
        type: 'SystemAssigned'
      }
  properties: {
    sku: {
      name: sku
    }
    disableLocalAuth: disableLocalAuth
    publicNetworkAccess: publicNetworkAccess
  }
}

// Serial import, one module at a time in array order. Azure Automation is historically
// unreliable when several module imports run concurrently, and Az.Accounts (sorted to the
// front above) has to be in place before any other Az module will load.
@batchSize(1)
resource azModules 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = [
  for m in orderedModules: {
    parent: automationAccount
    name: m.name
    properties: {
      contentLink: {
        uri: empty(m.version) ? '${galleryRoot}/${m.name}' : '${galleryRoot}/${m.name}/${m.version}'
        version: empty(m.version) ? null : m.version
      }
    }
  }
]

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logProgress: logProgress
    logVerbose: logVerbose
    description: 'Automatically shut down, scale down, and clean up non-production Azure resources.'
    publishContentLink: {
      uri: runbookScriptUri
      version: runbookContentVersion
    }
  }
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (createSchedule) {
  parent: automationAccount
  name: scheduleName
  properties: {
    description: 'Recurring trigger for ${runbookName}.'
    startTime: effectiveStartTime
    frequency: scheduleFrequency
    interval: scheduleInterval
    timeZone: scheduleTimeZone
  }
}

// Deliberately a stable GUID: varying it on redeploy does not avoid the duplicate-link
// error, and a stable name at least keeps repeat deployments referring to the same object.
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (createSchedule && createJobSchedule) {
  parent: automationAccount
  name: guid(automationAccount.id, runbookName, scheduleName)
  properties: {
    runbook: {
      name: runbookName
    }
    schedule: {
      name: scheduleName
    }
    parameters: union(runbookJobParameters, runbookParameterOverrides)
  }
  dependsOn: [
    runbook
    schedule
    azModules
  ]
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: automationAccount
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

module subscriptionRoleAssignment 'modules/role-assignment.bicep' = if (assignSubscriptionRole) {
  name: 'shutdown-runbook-rbac'
  scope: subscription()
  params: {
    principalId: useUserAssigned
      ? userAssignedIdentity!.properties.principalId
      : automationAccount.identity.principalId
    roleDefinitionId: roleDefinitionId
  }
}

// ---------------------------------------------------------------------------
//  Outputs
// ---------------------------------------------------------------------------

@description('Object ID of the identity the runbook authenticates as. Grant this access to any additional subscriptions.')
output runbookPrincipalId string = useUserAssigned
  ? userAssignedIdentity!.properties.principalId
  : automationAccount.identity.principalId

@description('Name of the deployed Automation account.')
output automationAccountName string = automationAccount.name

@description('Name of the deployed runbook.')
output runbookName string = runbook.name

@description('UTC timestamp of the first scheduled run, or empty when no schedule was created.')
output firstScheduledRun string = createSchedule ? effectiveStartTime : ''

@description('Whether the runbook will run in report-only mode.')
output dryRun bool = dryRun
