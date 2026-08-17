using './main.bicep'

param automationAccountName = 'shutdown-azure-resources'
param sku = 'Free'

// Start in report-only mode. Read one job's output, then flip to false.
param dryRun = true

// Empty processes every enabled subscription the identity can see.
param subscriptionIds = []

param exemptTagName = 'env'
param exemptTagValue = 'production'
param resourceExemptTagName = 'CostOptimizerExempt'

param createSchedule = true
param scheduleFrequency = 'Day'
param scheduleTimeOfDay = '19:00:00'
param scheduleTimeZone = 'Etc/UTC'

// Requires Owner or User Access Administrator on the subscription.
param assignSubscriptionRole = true

// Set to a Log Analytics workspace resource ID to collect JobLogs and JobStreams.
param logAnalyticsWorkspaceId = ''

// Alert when a job ends in a non-success state. Without an email address (or an existing
// action group) no alert is created, so set one of these.
param enableFailureAlert = true
param alertEmailAddress = ''
param existingActionGroupId = ''
param alertOnJobStatuses = [
  'Failed'
  'Stopped'
  'Suspended'
]
param alertSeverity = 1

param tags = {
  workload: 'cost-optimization'
}
