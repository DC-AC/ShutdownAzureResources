<#
.SYNOPSIS
    Azure Automation runbook that applies aggressive cost-reduction actions across
    one or more subscriptions, skipping anything tagged as production.

.DESCRIPTION
    Runs as the Automation Account's managed identity. Actions taken:

      1.  Deallocate running VMs
      2.  Deallocate running VM Scale Sets
      3.  Stop running AKS clusters
      4.  Stop running Azure Container Instances
      5.  Stop running Application Gateways
      6.  Deallocate Azure Firewalls (VNet-based only)
      7.  Downsize Azure SQL databases to the cheapest SKU that still fits the data
      8.  Suspend Synapse / standalone SQL Data Warehouse pools
      9.  Convert Premium managed disks on deallocated VMs to Standard
     10.  Delete unattached managed disks older than N days
     11.  Delete unattached public IP addresses
     12.  Delete empty (zero-site) App Service Plans
     13.  Optionally delete snapshots older than N days
     14.  Optionally delete orphaned NICs
     15.  Report-only pass over expensive resources that need a human decision

    EXEMPTIONS
      * Any resource group tagged  env = production  (names/values configurable)
      * Any individual resource carrying that same tag
      * Any resource tagged  CostOptimizerExempt = true
      * Any resource group with a ManagedBy value (AKS node RGs, Databricks, etc.)

.PREREQUISITES
    Modules (import into the Automation Account, 'Az' runtime v2 recommended):
        Az.Accounts, Az.Resources, Az.Compute, Az.Sql, Az.Network, Az.Storage,
        Az.Monitor, Az.Websites, Az.Aks, Az.ContainerInstance, Az.Synapse

    RBAC for the managed identity:
        Contributor at each target subscription (or at a management group).
        Add 'Monitoring Reader' if it is not already implied, for SQL size metrics.

    Grant with:
        $mi = (Get-AzAutomationAccount -ResourceGroupName <rg> -Name <aa>).Identity.PrincipalId
        New-AzRoleAssignment -ObjectId $mi -RoleDefinitionName Contributor -Scope /subscriptions/<subId>

.NOTES
    Azure sandbox jobs are killed at the 3-hour fair-share limit. For large estates,
    run this on a Hybrid Runbook Worker or shard it by subscription.

    Restore hints are written back as tags:
        costopt-originalSku, costopt-originalMaxSizeBytes, costopt-originalDiskSku,
        costopt-stoppedOn
#>

[CmdletBinding()]
param(
    # SAFETY: nothing is changed while this is $true. Flip to $false to execute.
    [bool]   $DryRun = $true,

    # Empty = every enabled subscription the identity can see.
    [string[]] $SubscriptionIds = @(),

    # Resource-group / resource exemption tag.
    [string] $ExemptTagName  = 'env',
    [string] $ExemptTagValue = 'production',

    # Per-resource opt-out tag (value true/yes/1).
    [string] $ResourceExemptTagName = 'CostOptimizerExempt',

    # Set to a client ID to use a user-assigned identity instead of system-assigned.
    [string] $UserAssignedIdentityClientId = '',

    # --- Feature switches -------------------------------------------------
    [bool] $StopVirtualMachines       = $true,
    [bool] $StopScaleSets             = $true,
    [bool] $StopAksClusters           = $true,
    [bool] $StopContainerInstances    = $true,
    [bool] $StopApplicationGateways   = $true,
    [bool] $DeallocateFirewalls       = $true,
    [bool] $DownsizeSqlDatabases      = $true,
    [bool] $SuspendDataWarehouses     = $true,
    [bool] $ConvertDisksToStandard    = $true,
    [bool] $DeleteUnattachedDisks     = $true,
    [bool] $DeleteUnattachedPublicIps = $true,
    [bool] $DeleteEmptyAppServicePlans = $true,
    [bool] $DeleteOldSnapshots        = $false,
    [bool] $DeleteOrphanedNics        = $false,

    # --- Tuning -----------------------------------------------------------
    # Only delete disks that have been unattached at least this long.
    [int] $UnattachedDiskMinAgeDays = 7,
    [int] $SnapshotMinAgeDays       = 90,

    # Standard_LRS (HDD, cheapest) or StandardSSD_LRS (safer perf floor).
    [ValidateSet('Standard_LRS','StandardSSD_LRS')]
    [string] $TargetDiskSku = 'StandardSSD_LRS',

    # How long to wait for VMs to reach Deallocated before converting their disks.
    [int] $DeallocationWaitMinutes = 20,

    # Use GP_S_Gen5_1 serverless with auto-pause instead of DTU tiers for SQL.
    # Cheaper for genuinely idle databases, MORE expensive for busy ones.
    [bool] $UseServerlessForSql = $false
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ======================================================================
#  Helpers
# ======================================================================

$script:Actions        = New-Object System.Collections.Generic.List[object]
$script:Report         = New-Object System.Collections.Generic.List[object]
$script:CurrentSubName = ''

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Warning $line }
        'ERROR' { Write-Error   $line -ErrorAction Continue }
        default { Write-Output  $line }
    }
}

function Test-Cmdlet {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function ConvertTo-TagHash {
    <# Normalises Hashtable / IDictionary tag bags into a plain hashtable. #>
    param($Tags)
    $h = @{}
    if ($null -eq $Tags) { return $h }
    foreach ($k in $Tags.Keys) { $h[[string]$k] = [string]$Tags[$k] }
    return $h
}

function Test-IsExempt {
    <# True when the resource group is exempt, managed, or the resource is tagged out. #>
    param(
        [string]$ResourceGroupName,
        $Tags
    )

    if ($ResourceGroupName) {
        if ($script:ExemptResourceGroups.Contains($ResourceGroupName)) { return $true }
        if ($script:ManagedResourceGroups.Contains($ResourceGroupName)) { return $true }
    }

    $t = ConvertTo-TagHash $Tags
    foreach ($k in $t.Keys) {
        if ($k -ieq $ResourceExemptTagName -and $t[$k] -imatch '^(true|yes|1)$') { return $true }
        if ($k -ieq $ExemptTagName -and $t[$k] -ieq $ExemptTagValue)             { return $true }
    }
    return $false
}

function Invoke-CostAction {
    <# Single choke point for every mutation, so DryRun is honoured everywhere. #>
    param(
        [string]$Type,
        [string]$Name,
        [string]$ResourceGroup,
        [string]$Action,
        [string]$Detail = '',
        [scriptblock]$Script
    )

    $record = [pscustomobject]@{
        Subscription  = $script:CurrentSubName
        ResourceGroup = $ResourceGroup
        Type          = $Type
        Name          = $Name
        Action        = $Action
        Detail        = $Detail
        Status        = ''
    }

    if ($DryRun) {
        $record.Status = 'WhatIf'
        Write-Log ("[WHATIF] {0} :: {1}/{2} :: {3} {4}" -f $Action, $ResourceGroup, $Name, $Type, $Detail)
    }
    else {
        try {
            & $Script | Out-Null
            $record.Status = 'Succeeded'
            Write-Log ("[DONE]   {0} :: {1}/{2} :: {3} {4}" -f $Action, $ResourceGroup, $Name, $Type, $Detail)
        }
        catch {
            $record.Status = 'Failed: ' + $_.Exception.Message
            Write-Log ("[FAIL]   {0} :: {1}/{2} :: {3}" -f $Action, $ResourceGroup, $Name, $_.Exception.Message) 'ERROR'
        }
    }

    $script:Actions.Add($record)
}

function Add-Report {
    param([string]$Type, [string]$Name, [string]$ResourceGroup, [string]$Note)
    $script:Report.Add([pscustomobject]@{
        Subscription  = $script:CurrentSubName
        ResourceGroup = $ResourceGroup
        Type          = $Type
        Name          = $Name
        Note          = $Note
    })
}

function Merge-ResourceTag {
    <# Non-destructive tag merge, used to stash restore hints. #>
    param([string]$ResourceId, [hashtable]$Tag)
    if ($DryRun) { return }
    try { Update-AzTag -ResourceId $ResourceId -Tag $Tag -Operation Merge -ErrorAction Stop | Out-Null }
    catch { Write-Log "Could not tag $ResourceId : $($_.Exception.Message)" 'WARN' }
}

# ======================================================================
#  Connect
# ======================================================================

Write-Log '============================================================'
Write-Log "Azure cost optimizer starting. DryRun = $DryRun"
Write-Log "Exemption: resource group tag '$ExemptTagName' = '$ExemptTagValue'"
Write-Log '============================================================'

try {
    Disable-AzContextAutosave -Scope Process | Out-Null

    if ([string]::IsNullOrWhiteSpace($UserAssignedIdentityClientId)) {
        $null = Connect-AzAccount -Identity
        Write-Log 'Authenticated with the system-assigned managed identity.'
    }
    else {
        $null = Connect-AzAccount -Identity -AccountId $UserAssignedIdentityClientId
        Write-Log "Authenticated with user-assigned identity $UserAssignedIdentityClientId."
    }
}
catch {
    throw "Managed identity sign-in failed: $($_.Exception.Message)"
}

if ($SubscriptionIds.Count -gt 0) {
    $subscriptions = foreach ($id in $SubscriptionIds) { Get-AzSubscription -SubscriptionId $id }
}
else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
}

Write-Log "Subscriptions in scope: $($subscriptions.Count)"

# ======================================================================
#  Per-subscription work
# ======================================================================

foreach ($sub in $subscriptions) {

    $script:CurrentSubName = $sub.Name
    Write-Log ''
    Write-Log "############ $($sub.Name) ($($sub.Id)) ############"

    try { Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null }
    catch { Write-Log "Cannot set context on $($sub.Id): $($_.Exception.Message)" 'ERROR'; continue }

    # ---- Build the exemption sets -------------------------------------
    $script:ExemptResourceGroups  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:ManagedResourceGroups = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rg in Get-AzResourceGroup) {
        $t = ConvertTo-TagHash $rg.Tags
        foreach ($k in $t.Keys) {
            if ($k -ieq $ExemptTagName -and $t[$k] -ieq $ExemptTagValue) {
                [void]$script:ExemptResourceGroups.Add($rg.ResourceGroupName)
            }
            if ($k -ieq $ResourceExemptTagName -and $t[$k] -imatch '^(true|yes|1)$') {
                [void]$script:ExemptResourceGroups.Add($rg.ResourceGroupName)
            }
        }
        # Service-managed resource groups (AKS nodes, Databricks, etc.)
        if ($rg.ManagedBy) { [void]$script:ManagedResourceGroups.Add($rg.ResourceGroupName) }
    }

    # AKS node resource groups are not always flagged with ManagedBy.
    if (Test-Cmdlet 'Get-AzAksCluster') {
        try {
            foreach ($aks in Get-AzAksCluster -ErrorAction Stop) {
                if ($aks.NodeResourceGroup) { [void]$script:ManagedResourceGroups.Add($aks.NodeResourceGroup) }
                if (Test-IsExempt -ResourceGroupName $aks.ResourceGroupName -Tags $aks.Tags) {
                    if ($aks.NodeResourceGroup) { [void]$script:ExemptResourceGroups.Add($aks.NodeResourceGroup) }
                }
            }
        } catch { Write-Log "AKS enumeration skipped: $($_.Exception.Message)" 'WARN' }
    }

    Write-Log "Exempt resource groups: $($script:ExemptResourceGroups.Count) | service-managed: $($script:ManagedResourceGroups.Count)"

    # ==================================================================
    #  1. Virtual machines
    # ==================================================================
    $vmsToWatch = @()

    if ($StopVirtualMachines -or $ConvertDisksToStandard) {
        Write-Log '--- Virtual machines ---'
        try {
            $vms = Get-AzVM -Status
        } catch {
            $vms = @()
            Write-Log "VM enumeration failed: $($_.Exception.Message)" 'ERROR'
        }

        foreach ($vm in $vms) {
            if (Test-IsExempt -ResourceGroupName $vm.ResourceGroupName -Tags $vm.Tags) { continue }

            $power = $vm.PowerState   # e.g. 'VM running', 'VM deallocated'
            $vmsToWatch += $vm

            if ($StopVirtualMachines -and $power -notmatch 'deallocated') {
                Merge-ResourceTag -ResourceId $vm.Id -Tag @{
                    'costopt-stoppedOn' = (Get-Date).ToString('o')
                }

                $rgName = $vm.ResourceGroupName
                $vmName = $vm.Name
                Invoke-CostAction -Type 'VirtualMachine' -Name $vmName -ResourceGroup $rgName `
                    -Action 'Deallocate' -Detail "was '$power'" -Script {
                        if ((Get-Command Stop-AzVM).Parameters.ContainsKey('NoWait')) {
                            Stop-AzVM -ResourceGroupName $rgName -Name $vmName -Force -NoWait
                        } else {
                            Stop-AzVM -ResourceGroupName $rgName -Name $vmName -Force
                        }
                    }
            }
        }
    }

    # ==================================================================
    #  2. VM Scale Sets
    # ==================================================================
    if ($StopScaleSets) {
        Write-Log '--- VM scale sets ---'
        try {
            foreach ($vmss in Get-AzVmss) {
                if (Test-IsExempt -ResourceGroupName $vmss.ResourceGroupName -Tags $vmss.Tags) { continue }

                # Skip AKS-owned scale sets; the cluster stop handles those.
                $tagKeys = (ConvertTo-TagHash $vmss.Tags).Keys
                if ($tagKeys | Where-Object { $_ -like 'aks-managed*' }) { continue }

                $instances = Get-AzVmssVM -ResourceGroupName $vmss.ResourceGroupName `
                                          -VMScaleSetName $vmss.Name -InstanceView -ErrorAction SilentlyContinue
                $running = @($instances | Where-Object {
                    $_.InstanceView.Statuses.Code -contains 'PowerState/running'
                })
                if ($running.Count -eq 0) { continue }

                $rgName   = $vmss.ResourceGroupName
                $vmssName = $vmss.Name
                Invoke-CostAction -Type 'VmScaleSet' -Name $vmssName -ResourceGroup $rgName `
                    -Action 'Deallocate' -Detail "$($running.Count) running instance(s)" -Script {
                        Stop-AzVmss -ResourceGroupName $rgName -VMScaleSetName $vmssName -Force
                    }
            }
        } catch { Write-Log "VMSS pass failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    #  3. AKS clusters
    # ==================================================================
    if ($StopAksClusters -and (Test-Cmdlet 'Stop-AzAksCluster')) {
        Write-Log '--- AKS clusters ---'
        try {
            foreach ($aks in Get-AzAksCluster) {
                if ($script:ExemptResourceGroups.Contains($aks.ResourceGroupName)) { continue }
                if (Test-IsExempt -ResourceGroupName $null -Tags $aks.Tags) { continue }
                if ($aks.PowerState.Code -ne 'Running') { continue }

                $rgName   = $aks.ResourceGroupName
                $aksName  = $aks.Name
                Invoke-CostAction -Type 'AksCluster' -Name $aksName -ResourceGroup $rgName `
                    -Action 'Stop' -Script {
                        Stop-AzAksCluster -ResourceGroupName $rgName -Name $aksName -Force
                    }
            }
        } catch { Write-Log "AKS pass failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    #  4. Container instances
    # ==================================================================
    if ($StopContainerInstances -and (Test-Cmdlet 'Stop-AzContainerGroup')) {
        Write-Log '--- Container instances ---'
        try {
            foreach ($cg in Get-AzContainerGroup) {
                if (Test-IsExempt -ResourceGroupName $cg.ResourceGroupName -Tags $cg.Tag) { continue }
                if ($cg.InstanceViewState -eq 'Stopped') { continue }

                $rgName = $cg.ResourceGroupName
                $cgName = $cg.Name
                Invoke-CostAction -Type 'ContainerGroup' -Name $cgName -ResourceGroup $rgName `
                    -Action 'Stop' -Script {
                        Stop-AzContainerGroup -ResourceGroupName $rgName -Name $cgName
                    }
            }
        } catch { Write-Log "ACI pass failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    #  5. Application gateways
    # ==================================================================
    if ($StopApplicationGateways) {
        Write-Log '--- Application gateways ---'
        try {
            foreach ($agw in Get-AzApplicationGateway) {
                if (Test-IsExempt -ResourceGroupName $agw.ResourceGroupName -Tags $agw.Tag) { continue }
                if ($agw.OperationalState -ne 'Running') { continue }

                $gw = $agw
                Invoke-CostAction -Type 'ApplicationGateway' -Name $agw.Name -ResourceGroup $agw.ResourceGroupName `
                    -Action 'Stop' -Script { Stop-AzApplicationGateway -ApplicationGateway $gw }
            }
        } catch { Write-Log "App Gateway pass failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    #  6. Azure Firewalls
    # ==================================================================
    if ($DeallocateFirewalls) {
        Write-Log '--- Azure firewalls ---'
        try {
            foreach ($fw in Get-AzFirewall) {
                if (Test-IsExempt -ResourceGroupName $fw.ResourceGroupName -Tags $fw.Tag) { continue }
                if ($fw.VirtualHub) {
                    Add-Report 'AzureFirewall' $fw.Name $fw.ResourceGroupName 'Secured-hub firewall cannot be deallocated'
                    continue
                }
                if (-not $fw.IpConfigurations -or $fw.IpConfigurations.Count -eq 0) { continue }  # already deallocated

                $target = $fw
                Invoke-CostAction -Type 'AzureFirewall' -Name $fw.Name -ResourceGroup $fw.ResourceGroupName `
                    -Action 'Deallocate' -Script {
                        $target.Deallocate()
                        Set-AzFirewall -AzureFirewall $target
                    }
            }
        } catch { Write-Log "Firewall pass failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    #  7. Azure SQL databases
    # ==================================================================
    if ($DownsizeSqlDatabases -or $SuspendDataWarehouses) {
        Write-Log '--- Azure SQL ---'

        # Cheapness rank; we never move a database "up" this list.
        $skuRank = @{ 'Basic' = 1; 'S0' = 2; 'S1' = 3; 'S2' = 4; 'S3' = 5 }

        try { $sqlServers = Get-AzSqlServer } catch { $sqlServers = @() }

        foreach ($srv in $sqlServers) {
            if (Test-IsExempt -ResourceGroupName $srv.ResourceGroupName -Tags $srv.Tags) { continue }

            $dbs = @()
            try {
                $dbs = Get-AzSqlDatabase -ResourceGroupName $srv.ResourceGroupName -ServerName $srv.ServerName |
                       Where-Object { $_.DatabaseName -ne 'master' }
            } catch {
                Write-Log "Cannot list databases on $($srv.ServerName): $($_.Exception.Message)" 'WARN'
                continue
            }

            foreach ($db in $dbs) {
                if (Test-IsExempt -ResourceGroupName $null -Tags $db.Tags) { continue }

                # --- Data warehouse / Synapse dedicated pool: pause, don't resize
                if ($db.Edition -eq 'DataWarehouse') {
                    if ($SuspendDataWarehouses -and $db.Status -eq 'Online') {
                        $rgN = $srv.ResourceGroupName; $svN = $srv.ServerName; $dbN = $db.DatabaseName
                        Invoke-CostAction -Type 'SqlDataWarehouse' -Name $dbN -ResourceGroup $rgN `
                            -Action 'Suspend' -Script {
                                Suspend-AzSqlDatabase -ResourceGroupName $rgN -ServerName $svN -DatabaseName $dbN
                            }
                    }
                    continue
                }

                if (-not $DownsizeSqlDatabases) { continue }

                if ($db.ElasticPoolName) {
                    Add-Report 'SqlDatabase' $db.DatabaseName $srv.ResourceGroupName `
                        "In elastic pool '$($db.ElasticPoolName)' - resize the pool, not the database"
                    continue
                }
                if ($db.Edition -eq 'Hyperscale') {
                    Add-Report 'SqlDatabase' $db.DatabaseName $srv.ResourceGroupName 'Hyperscale cannot be downgraded in place'
                    continue
                }
                if ($db.Edition -eq 'Free' -or $db.SkuName -eq 'Basic') { continue }

                # --- How much data is actually in there?
                $usedBytes = $null
                if (Test-Cmdlet 'Get-AzMetric') {
                    try {
                        $m = Get-AzMetric -ResourceId $db.ResourceId -MetricName 'storage' `
                                          -TimeGrain 01:00:00 -AggregationType Maximum `
                                          -StartTime (Get-Date).AddHours(-12) -EndTime (Get-Date) `
                                          -WarningAction SilentlyContinue -ErrorAction Stop
                        $vals = $m.Data | Where-Object { $null -ne $_.Maximum } | Select-Object -ExpandProperty Maximum
                        if ($vals) { $usedBytes = ($vals | Measure-Object -Maximum).Maximum }
                    } catch { }
                }

                # --- Pick the cheapest SKU that can hold the data
                $targetSku  = $null
                $targetEd   = $null
                $targetSize = $db.MaxSizeBytes

                if ($UseServerlessForSql) {
                    $targetSku = 'GP_S_Gen5_1'
                }
                elseif ($null -ne $usedBytes) {
                    if ($usedBytes -lt (1.8GB) -and -not $db.ZoneRedundant) {
                        $targetEd = 'Basic'; $targetSku = 'Basic'; $targetSize = 2GB
                    }
                    elseif ($usedBytes -lt (240GB)) {
                        $targetEd = 'Standard'; $targetSku = 'S0'
                        if ($targetSize -gt 250GB) { $targetSize = 250GB }
                    }
                    elseif ($usedBytes -lt (1000GB)) {
                        $targetEd = 'Standard'; $targetSku = 'S3'
                        if ($targetSize -gt 1024GB) { $targetSize = 1024GB }
                    }
                }
                else {
                    # No metric available: fall back to the declared max size, never shrink it.
                    if ($db.MaxSizeBytes -le 250GB)       { $targetEd = 'Standard'; $targetSku = 'S0' }
                    elseif ($db.MaxSizeBytes -le 1024GB)  { $targetEd = 'Standard'; $targetSku = 'S3' }
                }

                if (-not $targetSku) {
                    Add-Report 'SqlDatabase' $db.DatabaseName $srv.ResourceGroupName `
                        "Too large for a DTU tier (current SKU $($db.SkuName)) - review manually"
                    continue
                }

                # Never upsize.
                if ($skuRank.ContainsKey($db.SkuName) -and $skuRank.ContainsKey($targetSku)) {
                    if ($skuRank[$db.SkuName] -le $skuRank[$targetSku]) { continue }
                }

                $tags = ConvertTo-TagHash $db.Tags
                if (-not $tags.ContainsKey('costopt-originalSku')) {
                    $tags['costopt-originalSku']          = [string]$db.SkuName
                    $tags['costopt-originalMaxSizeBytes'] = [string]$db.MaxSizeBytes
                }

                $rgN = $srv.ResourceGroupName; $svN = $srv.ServerName; $dbN = $db.DatabaseName
                $tSku = $targetSku; $tEd = $targetEd; $tSize = $targetSize; $tTags = $tags

                Invoke-CostAction -Type 'SqlDatabase' -Name $dbN -ResourceGroup $rgN `
                    -Action 'Downsize' -Detail "$($db.SkuName) -> $tSku" -Script {
                        if ($tSku -eq 'GP_S_Gen5_1') {
                            Set-AzSqlDatabase -ResourceGroupName $rgN -ServerName $svN -DatabaseName $dbN `
                                -Edition 'GeneralPurpose' -ComputeModel 'Serverless' -ComputeGeneration 'Gen5' `
                                -VCore 1 -MinimumCapacity 0.5 -AutoPauseDelayInMinutes 60 -Tags $tTags
                        }
                        else {
                            Set-AzSqlDatabase -ResourceGroupName $rgN -ServerName $svN -DatabaseName $dbN `
                                -Edition $tEd -RequestedServiceObjectiveName $tSku `
                                -MaxSizeBytes $tSize -Tags $tTags
                        }
                    }
            }

            # Elastic pools are reported, never touched automatically.
            try {
                foreach ($pool in Get-AzSqlElasticPool -ResourceGroupName $srv.ResourceGroupName -ServerName $srv.ServerName) {
                    Add-Report 'SqlElasticPool' $pool.ElasticPoolName $srv.ResourceGroupName `
                        "SKU $($pool.SkuName) / $($pool.Capacity) - resize manually after checking pool members"
                }
            } catch { }
        }
    }

    # ==================================================================
    #  8. Synapse dedicated SQL pools
    # ==================================================================
    if ($SuspendDataWarehouses -and (Test-Cmdlet 'Get-AzSynapseWorkspace')) {
        Write-Log '--- Synapse SQL pools ---'
        try {
            foreach ($ws in Get-AzSynapseWorkspace) {
                if (Test-IsExempt -ResourceGroupName $ws.ResourceGroupName -Tags $ws.Tags) { continue }
                foreach ($pool in Get-AzSynapseSqlPool -WorkspaceName $ws.Name -ErrorAction SilentlyContinue) {
                    if ($pool.Status -ne 'Online') { continue }
                    $wsN = $ws.Name; $poolN = $pool.Name
                    Invoke-CostAction -Type 'SynapseSqlPool' -Name $poolN -ResourceGroup $ws.ResourceGroupName `
                        -Action 'Suspend' -Script {
                            Suspend-AzSynapseSqlPool -WorkspaceName $wsN -Name $poolN
                        }
                }
            }
        } catch { Write-Log "Synapse pass failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    #  9. Wait for deallocation, then downgrade attached disks
    # ==================================================================
    if ($ConvertDisksToStandard) {
        Write-Log '--- Waiting for VMs to finish deallocating ---'

        if (-not $DryRun -and $StopVirtualMachines) {
            $deadline = (Get-Date).AddMinutes($DeallocationWaitMinutes)
            do {
                Start-Sleep -Seconds 30
                $pending = @(Get-AzVM -Status | Where-Object {
                    $_.PowerState -notmatch 'deallocated' -and
                    -not (Test-IsExempt -ResourceGroupName $_.ResourceGroupName -Tags $_.Tags)
                })
                Write-Log "  $($pending.Count) VM(s) still allocated..."
            } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
        }

        Write-Log '--- Converting disks on deallocated VMs to Standard ---'

        $nonConvertible = @('UltraSSD_LRS','PremiumV2_LRS')
        $zrsMap = @{ 'Standard_LRS' = 'StandardSSD_ZRS'; 'StandardSSD_LRS' = 'StandardSSD_ZRS' }

        try { $vmsNow = Get-AzVM -Status } catch { $vmsNow = @() }

        foreach ($vm in $vmsNow) {
            if (Test-IsExempt -ResourceGroupName $vm.ResourceGroupName -Tags $vm.Tags) { continue }
            if ($vm.PowerState -notmatch 'deallocated') { continue }
            if ($vm.StorageProfile.OsDisk.DiffDiskSettings) { continue }   # ephemeral OS disk

            $diskIds = @()
            if ($vm.StorageProfile.OsDisk.ManagedDisk) { $diskIds += $vm.StorageProfile.OsDisk.ManagedDisk.Id }
            foreach ($d in $vm.StorageProfile.DataDisks) {
                if ($d.ManagedDisk) { $diskIds += $d.ManagedDisk.Id }
            }

            foreach ($id in $diskIds) {
                if (-not $id) { continue }
                $diskRg   = $id.Split('/')[4]
                $diskName = $id.Split('/')[-1]

                try { $disk = Get-AzDisk -ResourceGroupName $diskRg -DiskName $diskName -ErrorAction Stop }
                catch { continue }

                $currentSku = $disk.Sku.Name

                if ($nonConvertible -contains $currentSku) {
                    Add-Report 'ManagedDisk' $diskName $diskRg "$currentSku cannot be converted in place - recreate from snapshot"
                    continue
                }
                if ($disk.MaxShares -gt 1) {
                    Add-Report 'ManagedDisk' $diskName $diskRg 'Shared disk - must be detached from all VMs before conversion'
                    continue
                }
                if ($currentSku -notlike 'Premium*') { continue }
                if ($currentSku -eq $TargetDiskSku) { continue }

                $newSku = $TargetDiskSku
                if ($currentSku -like '*_ZRS') { $newSku = $zrsMap[$TargetDiskSku] }

                Merge-ResourceTag -ResourceId $disk.Id -Tag @{ 'costopt-originalDiskSku' = $currentSku }

                $dRg = $diskRg; $dName = $diskName; $dSku = $newSku
                Invoke-CostAction -Type 'ManagedDisk' -Name $dName -ResourceGroup $dRg `
                    -Action 'ConvertToStandard' -Detail "$currentSku -> $newSku (VM $($vm.Name) deallocated)" -Script {
                        New-AzDiskUpdateConfig -SkuName $dSku |
                            Update-AzDisk -ResourceGroupName $dRg -DiskName $dName
                    }
            }
        }
    }

    # ==================================================================
    # 10. Unattached managed disks
    # ==================================================================
    if ($DeleteUnattachedDisks) {
        Write-Log '--- Unattached managed disks ---'
        $cutoff = (Get-Date).AddDays(-$UnattachedDiskMinAgeDays)

        try {
            foreach ($disk in Get-AzDisk) {
                if (Test-IsExempt -ResourceGroupName $disk.ResourceGroupName -Tags $disk.Tags) { continue }
                if ($disk.ManagedBy) { continue }
                if ($disk.DiskState -ne 'Unattached') { continue }   # skips ActiveSAS / Reserved

                # Prefer the last detach time when the API surfaces it.
                $since = $disk.TimeCreated
                if ($disk.PSObject.Properties.Name -contains 'LastOwnershipUpdateTime' -and $disk.LastOwnershipUpdateTime) {
                    $since = $disk.LastOwnershipUpdateTime
                }
                if ($since -gt $cutoff) {
                    Write-Log "  Skipping $($disk.Name): unattached only since $since"
                    continue
                }

                $dRg = $disk.ResourceGroupName; $dName = $disk.Name
                Invoke-CostAction -Type 'ManagedDisk' -Name $dName -ResourceGroup $dRg `
                    -Action 'Delete' -Detail "$($disk.DiskSizeGB) GB $($disk.Sku.Name), idle since $since" -Script {
                        Remove-AzDisk -ResourceGroupName $dRg -DiskName $dName -Force
                    }
            }
        } catch { Write-Log "Disk cleanup failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    # 11. Unattached public IP addresses
    # ==================================================================
    if ($DeleteUnattachedPublicIps) {
        Write-Log '--- Unattached public IPs ---'
        try {
            foreach ($pip in Get-AzPublicIpAddress) {
                if (Test-IsExempt -ResourceGroupName $pip.ResourceGroupName -Tags $pip.Tag) { continue }
                if ($pip.IpConfiguration) { continue }
                if ($pip.NatGateway)      { continue }
                if ($pip.PublicIpPrefix)  { continue }

                $pRg = $pip.ResourceGroupName; $pName = $pip.Name
                Invoke-CostAction -Type 'PublicIpAddress' -Name $pName -ResourceGroup $pRg `
                    -Action 'Delete' -Detail "$($pip.Sku.Name)/$($pip.PublicIpAllocationMethod)" -Script {
                        Remove-AzPublicIpAddress -ResourceGroupName $pRg -Name $pName -Force
                    }
            }
        } catch { Write-Log "Public IP cleanup failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    # 12. Orphaned NICs (free, but tidy)
    # ==================================================================
    if ($DeleteOrphanedNics) {
        Write-Log '--- Orphaned NICs ---'
        try {
            foreach ($nic in Get-AzNetworkInterface) {
                if (Test-IsExempt -ResourceGroupName $nic.ResourceGroupName -Tags $nic.Tag) { continue }
                if ($nic.VirtualMachine)  { continue }
                if ($nic.PrivateEndpoint) { continue }

                $nRg = $nic.ResourceGroupName; $nName = $nic.Name
                Invoke-CostAction -Type 'NetworkInterface' -Name $nName -ResourceGroup $nRg `
                    -Action 'Delete' -Script {
                        Remove-AzNetworkInterface -ResourceGroupName $nRg -Name $nName -Force
                    }
            }
        } catch { Write-Log "NIC cleanup failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    # 13. Empty App Service Plans
    # ==================================================================
    if ($DeleteEmptyAppServicePlans -and (Test-Cmdlet 'Get-AzAppServicePlan')) {
        Write-Log '--- App Service plans ---'
        try {
            foreach ($plan in Get-AzAppServicePlan) {
                if (Test-IsExempt -ResourceGroupName $plan.ResourceGroup -Tags $plan.Tags) { continue }
                if ($plan.Sku.Tier -in @('Free','Dynamic','FlexConsumption')) { continue }

                if ($plan.NumberOfSites -gt 0) {
                    Add-Report 'AppServicePlan' $plan.Name $plan.ResourceGroup `
                        "$($plan.Sku.Name) hosting $($plan.NumberOfSites) site(s) - consider scaling down (stopping web apps does not reduce plan cost)"
                    continue
                }

                $aRg = $plan.ResourceGroup; $aName = $plan.Name
                Invoke-CostAction -Type 'AppServicePlan' -Name $aName -ResourceGroup $aRg `
                    -Action 'Delete' -Detail "$($plan.Sku.Name), zero sites" -Script {
                        Remove-AzAppServicePlan -ResourceGroupName $aRg -Name $aName -Force
                    }
            }
        } catch { Write-Log "App Service plan pass failed: $($_.Exception.Message)" 'ERROR' }
    }

    # ==================================================================
    # 14. Old snapshots
    # ==================================================================
    Write-Log '--- Snapshots ---'
    try {
        $snapCutoff = (Get-Date).AddDays(-$SnapshotMinAgeDays)
        foreach ($snap in Get-AzSnapshot) {
            if (Test-IsExempt -ResourceGroupName $snap.ResourceGroupName -Tags $snap.Tags) { continue }
            if ($snap.TimeCreated -gt $snapCutoff) { continue }

            if ($DeleteOldSnapshots) {
                $sRg = $snap.ResourceGroupName; $sName = $snap.Name
                Invoke-CostAction -Type 'Snapshot' -Name $sName -ResourceGroup $sRg `
                    -Action 'Delete' -Detail "created $($snap.TimeCreated)" -Script {
                        Remove-AzSnapshot -ResourceGroupName $sRg -SnapshotName $sName -Force
                    }
            }
            else {
                Add-Report 'Snapshot' $snap.Name $snap.ResourceGroupName `
                    "$($snap.DiskSizeGB) GB, created $($snap.TimeCreated) - enable DeleteOldSnapshots to remove"
            }
        }
    } catch { Write-Log "Snapshot pass failed: $($_.Exception.Message)" 'ERROR' }

    # ==================================================================
    # 15. Report-only: expensive things that need a human
    # ==================================================================
    Write-Log '--- Reporting expensive resources that were not modified ---'

    try {
        foreach ($gw in Get-AzVirtualNetworkGateway -ErrorAction SilentlyContinue) {
            if (Test-IsExempt -ResourceGroupName $gw.ResourceGroupName -Tags $gw.Tag) { continue }
            Add-Report 'VirtualNetworkGateway' $gw.Name $gw.ResourceGroupName `
                "$($gw.Sku.Name) - billed hourly and cannot be stopped; delete if unused"
        }
    } catch { }

    try {
        foreach ($b in Get-AzBastion -ErrorAction SilentlyContinue) {
            if (Test-IsExempt -ResourceGroupName $b.ResourceGroupName -Tags $b.Tag) { continue }
            Add-Report 'Bastion' $b.Name $b.ResourceGroupName 'Billed hourly; delete outside working hours if unused'
        }
    } catch { }

    if (Test-Cmdlet 'Get-AzRedisCache') {
        try {
            foreach ($r in Get-AzRedisCache -ErrorAction SilentlyContinue) {
                if (Test-IsExempt -ResourceGroupName $r.ResourceGroupName -Tags $r.Tag) { continue }
                Add-Report 'RedisCache' $r.Name $r.ResourceGroupName "$($r.Sku) $($r.Size) - resize manually"
            }
        } catch { }
    }

    if (Test-Cmdlet 'Get-AzCosmosDBAccount') {
        try {
            foreach ($c in Get-AzCosmosDBAccount -ErrorAction SilentlyContinue) {
                if (Test-IsExempt -ResourceGroupName $c.ResourceGroupName -Tags $c.Tags) { continue }
                Add-Report 'CosmosDB' $c.Name $c.ResourceGroupName 'Check for over-provisioned RU/s or switch to serverless/autoscale'
            }
        } catch { }
    }

    try {
        foreach ($lb in Get-AzLoadBalancer -ErrorAction SilentlyContinue) {
            if (Test-IsExempt -ResourceGroupName $lb.ResourceGroupName -Tags $lb.Tag) { continue }
            if ($lb.Sku.Name -eq 'Standard' -and -not $lb.BackendAddressPools.BackendIpConfigurations) {
                Add-Report 'LoadBalancer' $lb.Name $lb.ResourceGroupName 'Standard LB with empty backend pool - billed but unused'
            }
        }
    } catch { }

    try {
        foreach ($sa in Get-AzStorageAccount -ErrorAction SilentlyContinue) {
            if (Test-IsExempt -ResourceGroupName $sa.ResourceGroupName -Tags $sa.Tags) { continue }
            if ($sa.Sku.Name -like 'Premium*') {
                Add-Report 'StorageAccount' $sa.StorageAccountName $sa.ResourceGroupName `
                    "$($sa.Sku.Name) - premium storage cannot be converted in place; migrate data if not needed"
            }
            elseif ($sa.Kind -ne 'Storage' -and $sa.AccessTier -eq 'Hot') {
                Add-Report 'StorageAccount' $sa.StorageAccountName $sa.ResourceGroupName `
                    'Hot access tier - consider Cool/Archive tier or a lifecycle management policy'
            }
        }
    } catch { }
}

# ======================================================================
#  Summary
# ======================================================================

Write-Log ''
Write-Log '============================================================'
Write-Log ("SUMMARY  (DryRun = {0})" -f $DryRun)
Write-Log '============================================================'

if ($script:Actions.Count -eq 0) {
    Write-Log 'No actions identified.'
}
else {
    $script:Actions |
        Sort-Object Subscription, Type, ResourceGroup, Name |
        Format-Table Subscription, ResourceGroup, Type, Name, Action, Status, Detail -AutoSize -Wrap |
        Out-String -Width 4096 |
        Write-Output

    $grouped = $script:Actions | Group-Object Action | Sort-Object Count -Descending
    foreach ($g in $grouped) { Write-Log ("  {0,-20} {1}" -f $g.Name, $g.Count) }

    $failed = @($script:Actions | Where-Object { $_.Status -like 'Failed*' })
    Write-Log ("Total: {0} | Failed: {1}" -f $script:Actions.Count, $failed.Count)
}

if ($script:Report.Count -gt 0) {
    Write-Log ''
    Write-Log '--- Needs a human decision (nothing was changed) ---'
    $script:Report |
        Sort-Object Subscription, Type, Name |
        Format-Table Subscription, ResourceGroup, Type, Name, Note -AutoSize -Wrap |
        Out-String -Width 4096 |
        Write-Output
}

if ($DryRun) {
    Write-Log ''
    Write-Log 'DRY RUN COMPLETE - nothing was modified. Re-run with -DryRun $false to apply.'
}

# Emit structured objects so a parent runbook or webhook can consume them.
$script:Actions
