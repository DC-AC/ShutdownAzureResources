# ShutdownAzureResources

Automatically shut down, scale down, and clean up non-production Azure resources on a
schedule. Runs as an Azure Automation PowerShell 7.2 runbook authenticating with a managed
identity — no stored credentials, no service principal secrets to rotate.

**New deployment**

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FDC-AC%2FShutdownAzureResources%2Fmaster%2Fazuredeploy.json)

**Upgrade an existing deployment** (refreshes the script and modules only, leaves your
identity, schedule, and role assignments alone)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FDC-AC%2FShutdownAzureResources%2Fmaster%2FazureUpgrade.json)

---

## Safety first

**The runbook ships in report-only mode.** `dryRun` defaults to `true`, which logs every
action it *would* take and changes nothing. Deploy it, let one job run, read the output, and
only then redeploy with `dryRun: false`.

Three independent exemption mechanisms protect anything you care about:

| Exemption | Effect |
| --- | --- |
| Resource group or resource tagged `env` = `production` | Skipped entirely. Tag name and value are configurable. |
| Any resource tagged `CostOptimizerExempt` = `true` / `yes` / `1` | Skipped entirely. |
| Resource group with a `ManagedBy` value | Skipped — covers AKS node pools, Databricks, and similar service-managed groups. |

AKS node resource groups are additionally discovered and excluded even when Azure does not
stamp them with `ManagedBy`.

## What it does

Destructive actions are marked ⚠.

| # | Action | Default |
| --- | --- | --- |
| 1 | Deallocate running VMs | on |
| 2 | Deallocate running VM Scale Sets | on |
| 3 | Stop running AKS clusters | on |
| 4 | Stop running Container Instances | on |
| 5 | Stop running Application Gateways | on |
| 6 | Deallocate Azure Firewalls (VNet-based only) | on |
| 7 | Downsize Azure SQL databases to the cheapest SKU that still fits the data | on |
| 8 | Suspend Synapse / standalone SQL Data Warehouse pools | on |
| 9 | Pause running Microsoft Fabric capacities | on |
| 10 | Convert Premium managed disks on deallocated VMs to Standard | on |
| 11 | ⚠ Delete managed disks unattached for more than 7 days | on |
| 12 | ⚠ Delete unattached public IP addresses | on |
| 13 | ⚠ Delete orphaned NICs | **off** |
| 14 | ⚠ Delete App Service Plans hosting zero sites | on |
| 15 | ⚠ Delete snapshots older than 90 days | **off** |
| 16 | Report on expensive resources needing a human decision (VPN gateways, Bastion, Redis, Cosmos DB, idle load balancers, premium storage) | always |

The SQL pass sizes each database from its actual 12-hour peak storage metric, never moves a
database *up* a tier, and refuses to touch elastic-pool members or Hyperscale databases —
those are reported instead.

## Quick start

### Portal

Use the **Deploy to Azure** button above. At minimum supply an Automation account name; the
defaults handle everything else.

### Azure CLI

```bash
az group create --name rg-cost-optimizer --location eastus2

az deployment group create \
  --resource-group rg-cost-optimizer \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --parameters automationAccountName=shutdown-azure-resources
```

Preview first with `az deployment group what-if` in place of `create`.

### Azure PowerShell

```powershell
New-AzResourceGroup -Name rg-cost-optimizer -Location eastus2

New-AzResourceGroupDeployment `
  -ResourceGroupName rg-cost-optimizer `
  -TemplateFile ./infra/main.bicep `
  -TemplateParameterFile ./infra/main.bicepparam `
  -automationAccountName shutdown-azure-resources
```

### Run it now

The schedule's first job runs the day after deployment, so start one by hand to see the
dry-run output immediately:

```powershell
$job = Start-AzAutomationRunbook `
  -ResourceGroupName rg-cost-optimizer `
  -AutomationAccountName shutdown-azure-resources `
  -Name ShutdownAzureResources

Get-AzAutomationJobOutput -ResourceGroupName rg-cost-optimizer `
  -AutomationAccountName shutdown-azure-resources -Id $job.JobId -Stream Output
```

Or use **Automation account → Runbooks → ShutdownAzureResources → Start** in the portal. A
manual start uses the script's own defaults, which include `DryRun = $true`.

### Going live

Once you are happy with the dry-run output, re-register the schedule link with
`DryRun = $false`:

```powershell
$common = @{
  ResourceGroupName     = 'rg-cost-optimizer'
  AutomationAccountName = 'shutdown-azure-resources'
  RunbookName           = 'ShutdownAzureResources'
  ScheduleName          = 'Nightly-Shutdown'
}

Unregister-AzAutomationScheduledRunbook @common -Force
Register-AzAutomationScheduledRunbook @common -Parameters @{ DryRun = $false }
```

> **Why not just redeploy?** Azure Automation job schedules are not idempotent in ARM.
> Redeploying a template containing one fails with *"A job schedule for the specified runbook
> and schedule already exists"* — and a fresh GUID does not help, because the conflict is on
> the runbook-plus-schedule pair rather than the name. Re-registering is the reliable path.
>
> If you do need to redeploy `main.bicep` against an account that already has the link, pass
> `createJobSchedule=false` so the template skips it:
>
> ```bash
> az deployment group create \
>   --resource-group rg-cost-optimizer \
>   --template-file infra/main.bicep \
>   --parameters infra/main.bicepparam \
>   --parameters automationAccountName=shutdown-azure-resources createJobSchedule=false
> ```
>
> Routine script and module upgrades use `infra/upgrade.bicep`, which contains no schedule
> resources and is safe to redeploy as often as you like.

## Permissions

The deployment creates a system-assigned managed identity and grants it **Contributor** on
the subscription you deploy into. That role assignment requires you to be **Owner** or **User
Access Administrator**; if you are not, deploy with `assignSubscriptionRole=false` and have
someone grant it separately:

```bash
PRINCIPAL_ID=$(az deployment group show \
  --resource-group rg-cost-optimizer --name main \
  --query properties.outputs.runbookPrincipalId.value -o tsv)

az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope /subscriptions/<subscription-id>
```

### Covering more than one subscription

The runbook processes every enabled subscription its identity can see. Repeat the command
above for each additional subscription, or grant the role once at a management group scope:

```bash
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope /providers/Microsoft.Management/managementGroups/<mg-id>
```

Restrict the scope explicitly with the `subscriptionIds` parameter if you would rather not
process everything the identity can reach.

## Failure alerting

A cost optimizer that quietly stops working is worse than not having one — the savings
disappear and nothing tells you. The deployment can create a metric alert that fires when a
job of this runbook ends in a non-success state:

```bash
az deployment group create \
  --resource-group rg-cost-optimizer \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --parameters automationAccountName=shutdown-azure-resources \
               alertEmailAddress=you@example.com
```

That creates an action group with your address and a rule on the Automation account's
**Total Jobs** (`TotalJob`) metric, split by the `Status` dimension and filtered to the
`Runbook` dimension so other runbooks in the same account do not trip it. Condition is
`Total > 0` evaluated every 5 minutes over a 5-minute window.

It watches three states, not just `Failed`:

| Status | Why it matters |
| --- | --- |
| `Failed` | The ordinary case — the script threw. |
| `Stopped` | A job killed by the 3-hour fair-share limit, or cancelled by hand. |
| `Suspended` | Under the PowerShell Workflow engine a thrown error suspends and retries before it ever reaches `Failed`. Harmless to watch on a PowerShell 7.2 runbook. |

To reuse an action group you already have, pass `existingActionGroupId` instead of
`alertEmailAddress` — it takes precedence.

**Confirm it actually deployed.** `enableFailureAlert` alone is not enough; with no email and
no action group there is nowhere to send the alert and it is skipped. The deployment reports
which happened:

```bash
az deployment group show \
  --resource-group rg-cost-optimizer --name shutdown-optimizer \
  --query properties.outputs.failureAlertStatus.value -o tsv
# Enabled
# NOT DEPLOYED - supply alertEmailAddress or existingActionGroupId
# Disabled - enableFailureAlert is false
```

> This alerts on jobs that **ran and failed**. It cannot tell you the runbook never started —
> a deleted schedule or an unlinked job schedule produces no metric at all, so there is
> nothing to threshold. If that matters, add a log alert on the `AzureDiagnostics` table with
> `logAnalyticsWorkspaceId` set, firing when the count of completed jobs over 24 hours is
> zero.

## Tuning the runbook

The deployment wires the common settings (`dryRun`, `subscriptionIds`, the exemption tags)
into the schedule directly. Every other `Runbook.ps1` parameter goes through
`runbookParameterOverrides`:

```bicep
param runbookParameterOverrides = {
  DeleteOldSnapshots: 'true'
  SnapshotMinAgeDays: '180'
  TargetDiskSku: 'Standard_LRS'
  UseServerlessForSql: 'true'
}
```

Azure Automation parses each value as JSON, so booleans must be the bare literals `true` or
`false` and numbers must be unquoted digits — all wrapped in Bicep strings as shown.

Available switches: `StopVirtualMachines`, `StopScaleSets`, `StopAksClusters`,
`StopContainerInstances`, `StopApplicationGateways`, `DeallocateFirewalls`,
`DownsizeSqlDatabases`, `SuspendDataWarehouses`, `PauseFabricCapacities`, `ConvertDisksToStandard`,
`DeleteUnattachedDisks`, `DeleteUnattachedPublicIps`, `DeleteEmptyAppServicePlans`,
`DeleteOldSnapshots`, `DeleteOrphanedNics`. Tuning knobs: `UnattachedDiskMinAgeDays`,
`SnapshotMinAgeDays`, `TargetDiskSku`, `DeallocationWaitMinutes`, `UseServerlessForSql`.

## Deployment parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `automationAccountName` | *(required)* | 6–50 characters. |
| `location` | resource group location | Any region supporting Azure Automation. |
| `sku` | `Free` | `Free` includes 500 job minutes/month. Use `Basic` for large estates. |
| `dryRun` | `true` | Report-only. Set `false` to let it act. |
| `subscriptionIds` | `[]` | Empty means every enabled subscription the identity can see. |
| `exemptTagName` / `exemptTagValue` | `env` / `production` | Exemption tag pair. |
| `resourceExemptTagName` | `CostOptimizerExempt` | Per-resource opt-out tag. |
| `runbookParameterOverrides` | `{}` | Any other runbook parameter. See above. |
| `createSchedule` | `true` | Creates the recurring schedule. |
| `createJobSchedule` | `true` | Links the runbook to the schedule. Set `false` on redeploys — see [Going live](#going-live). |
| `scheduleFrequency` | `Day` | `Hour`, `Day`, `Week`, or `Month`. |
| `scheduleTimeOfDay` | `19:00:00` | First run is the day after deployment at this time. |
| `scheduleTimeZone` | `Etc/UTC` | IANA zone, e.g. `America/New_York`, to follow daylight saving. |
| `assignSubscriptionRole` | `true` | Needs Owner / User Access Administrator. |
| `roleDefinitionId` | Contributor GUID | Swap for a narrower custom role if you have one. |
| `userAssignedIdentityResourceId` | `''` | Use an existing user-assigned identity instead of system-assigned. |
| `logAnalyticsWorkspaceId` | `''` | Set to collect `JobLogs` and `JobStreams`. |
| `enableFailureAlert` | `true` | Alert when a job ends badly. Needs an email or action group — see [Failure alerting](#failure-alerting). |
| `alertEmailAddress` | `''` | Creates an action group notifying this address. |
| `existingActionGroupId` | `''` | Reuse an action group you already have. Wins over `alertEmailAddress`. |
| `alertOnJobStatuses` | `Failed`, `Stopped`, `Suspended` | Job states that raise the alert. |
| `alertSeverity` | `1` | 0 critical … 4 verbose. |
| `powerShellModules` | pinned `Az.*` set | Empty version on any entry pulls latest from the gallery. |
| `disableLocalAuth` | `true` | Blocks key-based auth. Entra ID auth is unaffected. |
| `runbookContentVersion` | `2.0.0.0` | **Bump this to make Automation re-fetch the script.** |

## Undoing changes

The runbook records restore hints as tags before it changes anything:

| Tag | Written on |
| --- | --- |
| `costopt-stoppedOn` | VMs, before deallocation |
| `costopt-originalSku`, `costopt-originalMaxSizeBytes` | SQL databases, before downsizing |
| `costopt-originalDiskSku` | Managed disks, before conversion to Standard |

Resources that were merely stopped are brought back with their usual cmdlets —
`Start-AzVM`, `Start-AzAksCluster`, `Resume-AzSynapseSqlPool`, `Resume-AzFabricCapacity`, and
so on. Deletions are not reversible, which is why disk deletion has a minimum age and
snapshot and NIC deletion are off by default.

## Repository layout

```
infra/main.bicep                     Source of truth for a new deployment
infra/upgrade.bicep                  Refreshes script + modules on an existing account
infra/modules/role-assignment.bicep  Subscription-scope RBAC grant
infra/main.bicepparam                Example parameter file
azuredeploy.json                     Compiled from infra/main.bicep — do not edit by hand
azureUpgrade.json                    Compiled from infra/upgrade.bicep — do not edit by hand
azuredeploy.parameters.json          ARM-format parameter file
Runbook.ps1                          The runbook itself
```

`azuredeploy.json` and `azureUpgrade.json` are committed compiled artifacts so the portal
buttons keep working. After editing any `.bicep` file, regenerate them:

```bash
bicep build infra/main.bicep --outfile azuredeploy.json
bicep build infra/upgrade.bicep --outfile azureUpgrade.json
```

CI fails the build if they drift.

## Upgrading from v1 (AzureRM)

Version 2 is a **breaking change**. The old deployment stored an Azure username and password
plus a SendGrid credential, and side-loaded AzureRM 3.5.0 module zips from a public blob
container. None of that is used any more.

| v1 | v2 |
| --- | --- |
| AzureRM modules from a blob container | `Az.*` modules from the PowerShell Gallery, imported serially |
| Username/password Automation credential | System-assigned managed identity |
| SendGrid credential for email | Removed — use Log Analytics or an Action Group |
| `$SubscriptionFilter` wildcard string | `subscriptionIds` array (empty = all visible) |
| PowerShell 5.1 runbook | PowerShell 7.2 runbook |
| Runbook location limited to 7 regions | Any region supporting Azure Automation |
| Acted immediately | `dryRun` defaults to on |

To migrate, deploy fresh with the button above, confirm a dry run looks right, then delete
the old Automation account and its stored credentials. The old
`azuredeploy.parameters.json` is not compatible.

Do not point the v2 upgrade template at a v1 Automation account: the old account has AzureRM
modules and a PowerShell 5.1 runbook of the same name, and mixing the two runtimes causes
assembly conflicts.

## Local development

```bash
bicep build infra/main.bicep --stdout          # compile and lint
bicep build-params infra/main.bicepparam       # validate the parameter file
az deployment group what-if \
  --resource-group rg-cost-optimizer \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --parameters automationAccountName=shutdown-azure-resources

pwsh -c "Invoke-ScriptAnalyzer -Path ./Runbook.ps1 -Severity Error,Warning"
```

GitHub Actions runs all of the above on every push and pull request.

## Limits and caveats

- **Job schedules are not idempotent in ARM.** Redeploy `main.bicep` with
  `createJobSchedule=false`, or use `upgrade.bicep`, which has no schedule resources.
- Azure sandbox jobs are killed at the **3-hour fair-share limit**. For large estates, run on
  a Hybrid Runbook Worker or shard by subscription using `subscriptionIds`.
- The `Free` SKU includes 500 job minutes per month. A nightly run across a modest estate
  fits comfortably; a large one will not.
- Module imports are deliberately serial and take several minutes on first deployment.
  Azure Automation is unreliable when many imports run concurrently.
- Stopping a web app does **not** reduce App Service Plan cost — the plan is billed. Only
  empty plans are deleted; populated ones are reported so you can scale them down.
- **Pausing a Fabric capacity takes every workload on it offline** — Power BI reports,
  lakehouses, warehouses, and notebooks all become unavailable until it is resumed. Storage
  still bills while paused; only compute stops. Tag any capacity that must stay up.
  Only capacities in the `Active` state are touched, and Fabric trial capacities are not
  pausable. Subscriptions without the `Microsoft.Fabric` resource provider registered log a
  warning and skip the pass.
- Secured-hub (Virtual WAN) firewalls cannot be deallocated and are reported instead.
- Ultra and Premium v2 disks cannot be converted in place; they are reported.

## License

MIT. See [LICENSE](LICENSE).
