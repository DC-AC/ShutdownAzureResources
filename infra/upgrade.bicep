metadata description = '''
Refreshes the runbook script and its Az modules on an Automation account that already
exists. Touches nothing else: identity, schedules, and role assignments are left as they
are. Use this for routine version bumps; use main.bicep for a first deployment.
'''

targetScope = 'resourceGroup'

@description('Name of the existing Azure Automation account.')
@minLength(6)
@maxLength(50)
param automationAccountName string

@description('Region of the existing Automation account. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Name of the runbook to refresh.')
param runbookName string = 'ShutdownAzureResources'

@description('URI the runbook content is published from.')
param runbookScriptUri string = 'https://raw.githubusercontent.com/DC-AC/ShutdownAzureResources/master/Runbook.ps1'

@description('''Content version stamped on the runbook. This must change for Azure Automation
to re-fetch the script, so bump it on every upgrade.''')
param runbookContentVersion string = '2.0.0.0'

@description('Write verbose streams to the job log.')
param logVerbose bool = false

@description('Write progress records to the job log.')
param logProgress bool = false

@description('''Az modules to re-import, as objects of the shape
{ name: 'Az.Compute', version: '11.8.0' }. Leave a version empty to pull the latest from the
PowerShell Gallery; pin it for reproducible deployments.''')
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

// Az.Accounts first; the serial loop below then imports the rest in order behind it.
var orderedModules = concat(
  filter(powerShellModules, m => m.name == 'Az.Accounts'),
  filter(powerShellModules, m => m.name != 'Az.Accounts')
)
var galleryRoot = 'https://www.powershellgallery.com/api/v2/package'

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' existing = {
  name: automationAccountName
}

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

@description('Name of the refreshed runbook.')
output runbookName string = runbook.name

@description('Content version now published.')
output runbookContentVersion string = runbookContentVersion
