param(
     [parameter(Mandatory=$true, HelpMessage="String to match all the subscriptions you wish to process.")]
     [string]$SubscriptionFilter,

     [parameter(Mandatory=$true, HelpMessage="Check Classic Azure")]
     [boolean]$CheckClassicAzure,

     [parameter(Mandatory=$true, HelpMessage="Check Resrouce Manager Azure")]
     [boolean]$CheckResourceManagerAzure,

     [parameter(Mandatory=$true, HelpMessage="Perform VM Checks")]
     [boolean]$CheckVMs,

     [parameter(Mandatory=$true, HelpMessage="Perform SQL DB Checks")]
     [boolean]$CheckSqlDB,

     [parameter(Mandatory=$true, HelpMessage="Perform Storage Checks")]
     [boolean]$CheckStorage,

     [parameter(Mandatory=$true, HelpMessage="Perform SQL DW Checks")]
     [boolean]$CheckSqlDW,

     [parameter(Mandatory=$true, HelpMessage="Perform HD Insight Checks")]
     [boolean]$CheckHdInsight,

     [parameter(Mandatory=$true, HelpMessage="Perform Premium Storage Checks")]
     [boolean]$CheckPremiumStorage,

     [parameter(Mandatory=$true, HelpMessage="Email address to send emails from")]
     [string]$FromEmail,
     
     [parameter(Mandatory=$true, HelpMessage="Email address to send emails to")]
     [string]$ToEmail,
     
     [parameter(Mandatory=$true, HelpMEssage="Subject of the emails to send")]
     [string]$Subject,
	 
	 [parameter(Mandatory=$true, HelpMessage="Creditial which maps to Azure AD account to authenticate against azure")]
	 [string]$AzureAccount,
	 
	 [parameter(Mandatory=$false, HelpMessage="Credential which has SendGrid credentials")]
	 [string]$EMailAccount
)

if ($CheckClassicAzure -eq $false -and $CheckResourceManagerAzure -eq $false) {
    Write-Warning ("Checks for Classic and Resource Manager are both disabled. Nothing to do.")
    return
}

if (!$cred) {
    try {
        $cred = Get-AutomationPSCredential -Name $AzureAccount
    }
    catch {
        write-warning ("Unable to get runbook account. Authenticate Manaually")
        [PSCredential] $cred = Get-Credential -Message "Enter Azure Portal Creds"

        if (!$cred) {
            write-warning "Credentials were not provided. Exiting." -ForegroundColor Yellow
            return
        }
    }

    if ($CheckClassicAzure -eq $true) {
        try {
            $a = add-AzureRmAccount -Credential $cred -InformationVariable InfoVar -ErrorVariable ErrorVar
        }
        catch {
            Clear-Variable cred
            write-warning ("Unable to authenticate to AzureRM using the provided credentials")
		    write-warning($ErrorVar)
            return
        }
    }

    if ($CheckResourceManagerAzure -eq $true) {
        try {
            $a= add-AzureAccount -Credential $cred -InformationVariable InfoVar -ErrorVariable ErrorVar
        }
        catch {
            Clear-Variable cred
            write-warning ("Unable to authenticate to AzureSM using the provided credentials")
		    write-warning( $ErrorVar)
            return
        }
    }
}

try {
    $email_cred = Get-AutomationPSCredential -Name $EMailAccount
}
catch {
    write-warning ("Unable to get email credential. Emailing features are disabled.")
}

if ($CheckClassicAzure -eq $true -and $CheckResourceManagerAzure -eq $false) {
    $Subscriptions = Get-AzureSubscription -InformationVariable InfoVar | where ({$_.SubscriptionName -like $SubScriptionFilter})
} else {
    $Subscriptions = Get-AzureRmSubscription -InformationVariable InfoVar | where ({$_.SubscriptionName -like $SubScriptionFilter})
}

function ShutdownVMs {
    param (
     [parameter(HelpMessage="Check Classic Azure")]
     [boolean]$CheckClassicAzure,

     [parameter(HelpMessage="Check Resrouce Manager Azure")]
     [boolean]$CheckResourceManagerAzure
    )

    Write-host ("Shutting down VMs as needed")

    if ($CheckResourceManagerAzure -eq $true) {
        $VMs = get-AzureRMVM -WarningAction SilentlyContinue

        $VMs | foreach {
            $VM = get-AzureRmVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name -Status  -WarningAction SilentlyContinue

        
            $State = $VM.Statuses | where ({ $_.Code -eq "PowerState/deallocated" })
        
            if ($State.count -eq 0) {
                write-output ("Attempting to stop RM VM {0}" -f $VM.Name)
                $a = Stop-AzureRmVM -Name $_.Name -ResourceGroupName $_.ResourceGroupName -Force -WarningVariable InfoVar -WarningAction SilentlyContinue
            } #else {
            #    write-output ("RM VM {0} is already stopped" -f $VM.Name)
            #}
        }

        Clear-Variable VMs
    }

    if ($CheckClassicAzure -eq $true) {
        $VMs = get-azureVM  -WarningAction SilentlyContinue

        $VMs | foreach {
        
            if ($_.Status -ne "StoppedDeallocated") {
                write-output ("Attempting to stop SM VM {0}" -f $_.Name)
                $a = stop-AzureVM -Name $_.Name -ServiceName $_.ServiceName -Force -ErrorVariable ErrorVar -InformationVariable InfoVar -WarningAction SilentlyContinue
            } #else { 
            #    Write-output ("SM VM {0} is alrady stopped." -f $_.Name)
            #}
        }
    }
}

function SQLDBToBasic {
    param (
     [parameter(HelpMessage="Check Resrouce Manager Azure")]
     [boolean]$CheckResourceManagerAzure
    )

    Write-host ("Checking SQL Databases")

    if ($CheckResourceManagerAzure -eq $true) {
        $ResourceGroups = get-AzureRmResourceGroup

        $ResourceGroups | foreach {
            $ResourceGroupName = $_.ResourceGroupName
            $Servers = get-AzureRmSqlServer -ResourceGroupName $_.ResourceGroupName
            $Servers | foreach {
                $DBs = Get-AzureRmSqlDatabase -ServerName $_.ServerName -ResourceGroupName $ResourceGroupName | where ({$_.DatabaseName -ne "master" -and $_.CurrentServiceObjectiveName -ne "Basic"})
                $Server = $_.ServerName
                $DBs | foreach {
                    $DatabaseName = $_.DatabaseName
                    write-output ("Attempting to resize SQL DB {0} on Server {1}" -f $DatabaseName, $Server)
                    $a = Set-AzureRmSqlDatabase -ServerName $Server -DatabaseName $DatabaseName  -ResourceGroupName $ResourceGroupName -RequestedServiceObjectiveName "Basic" -ErrorAction SilentlyContinue -InformationVariable InfoVar  -WarningAction SilentlyContinue
                }
            }
        }
    }
}

function StorageToLRS {
    param (
     [parameter(HelpMessage="Check Classic Azure")]
     [boolean]$CheckClassicAzure,

     [parameter(HelpMessage="Check Resrouce Manager Azure")]
     [boolean]$CheckResourceManagerAzure
    )

    Write-host ("Checking Storage accounts")

    if ($CheckResourceManagerAzure -eq $true) {
        $StorageAccounts = get-AzureRmStorageAccount 

        $StorageAccounts | foreach {
            $Sku = $_.Sku
            if ($Sku.Name -ne "StandardLRS") {
                write-output ("Attempting to change storage account {0} from {1} to LRS" -f $_.StorageAccountName, $Sku.Name)
                $a = Set-AzureRmStorageAccount -Name $_.StorageAccountName -ResourceGroupName $_.ResourceGroupName -SkuName "Standard_LRS" -InformationVariable InfoVar   -WarningAction SilentlyContinue
            } 
        }

        Clear-Variable StorageAccounts
    }
    
    if ($CheckClassicAzure -eq $true) { 
        $StorageAccounts = get-azureStorageAccount | where ({$_.AccountType -ne "Standard_LRS"})
        $StorageAccounts | foreach {
            write-output ("Attempting to change storage account {0} to LRS" -f $_.StorageAccountName)
            $a = set-AzureStorageAccount -StorageAccountName $_.StorageAccountName -GeoReplicationEnabled $false -InformationVariable InfoVar -WarningAction SilentlyContinue
        }
    }
}

function KillSQLDW {
    param (
     [parameter(HelpMessage="Check Resrouce Manager Azure")]
     [boolean]$CheckResourceManagerAzure
    )

    Write-host ("Checking SQL DWs")

    $MailMessage = "";

    if ($CheckResourceManagerAzure -eq $true) {

        $ResourceGroups = get-AzureRmResourceGroup

        $ResourceGroups | foreach {
            $ResourceGroupName = $_.ResourceGroupName
            $Servers = get-AzureRmSqlServer -ResourceGroupName $ResourceGroupName

            $Servers | foreach {
                $Databases = get-AzureRmSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $_.ServerName | where ({ $_.Edition -eq "DataWarehouse" })

                $Databases | foreach {
                    [datetime] $now = get-date;
                    [timespan] $Timespan = $now - $_.creationDate

                    if ($Timespan.TotalDays -gt 3) {
                        Write-Output ("Killing SQL DW {0} on {1}" -f $_.DatabaseName, $_.ServerName)
                        Remove-AzureRmSqlDatabase -DatabaseName $_.DatabaseName -ServerName $_.ServerName -ResourceGroupName $ResourceGroupName -Force -InformationVariable InfoVar -ErrorVariable ErrorVar
                    } else {
                        $MailMessage = "$MailMessage <BR>
                        The Data Warehoues $_.DatabaseName on server $_.ServerName is online.  It will be automatically deleted in less than three days."
                    }
                }
            }
        }
    }
    return $MailMessage
}

function KillHDInsight {
    param (
     [parameter(HelpMessage="Check Resrouce Manager Azure")]
     [boolean]$CheckResourceManagerAzure
    )

    Write-host ("Checking HD Insight clusters")

    $MailMessage = "";

    if ($CheckResourceManagerAzure -eq $true) {

        $Clusters = Get-AzureRmHdInsightCluster 

        $Clusters | foreach {
            $Cluster = get-AzureRmResource -ResourceId $_.Id
            $Properties = $Cluster.Properties
            [datetime] $Created = $Properties.createdDate
            [datetime] $now = get-date
            [timespan] $Timespan = $now - $Created

            if ($Timespan.TotalDays -gt 3) {
                Write-Output ("Killing HD Insite cluster {0}" -f $_.Name)
                $a = Remove-AzureRmHDInsightCluster -ClusterName $_.Name -ResourceGroupName $_.ResourceGroup -InformationVariable InfoVar -ErrorVariable ErrorVar -WarningAction SilentlyContinue
            } else {
                $MailMessage = "$MailMessage <BR>
                The HDInsite Cluster $_.Name is going to be deleted in less than three days."
            }
        }
    }

    return $MailMessage
}

Function CheckPremiumStorage {
    param (
     [parameter(HelpMessage="Check Classic Azure")]
     [boolean]$CheckClassicAzure,

     [parameter(HelpMessage="Check Resrouce Manager Azure")]
     [boolean]$CheckResourceManagerAzure
    )

    Write-host ("Checking for premium storage")

    $EmailMessage = ""

    if ($CheckResourceManagerAzure -eq $true) {
        $StorageAccounts = get-AzureRmStorageAccount 

        $StorageAccounts | foreach {
            $StorageAccount = $_
            $Sku = $StorageAccount.Sku
            $StorageAccountName = $_.StorageAccountName

            if ($Sku.Tier -eq "Premium") {
              $EmailMessage = "$EmailMessage <BR>
              $StorageAccountName is using premium storage."  
              write-warning ("Storage account {0} is using premium storage. Unable to fix, logged." -f $_.StorageAccountName)
            }
        }

        Clear-Variable StorageAccounts 
    }

    if ($CheckClassicAzure -eq $true) {
        $StorageAccounts = get-azureStorageAccount | where ({$_.AccountType -like "*Premium*"})
        $StorageAccounts | foreach {
            $StorageAccountName = $_.StorageAccountName

            $EmailMessage = "$EmailMessage <BR>
            $StorageAccountName is using premium storage.  Unable to fix, logged."  

            write-warning ("Storage account {0} is using premium storage. Unable to fix, logged." -f $_.StorageAccountName)
        }
    }

    return $EmailMessage
}

$FinalEmail = ""

$InfoVar1 = ""
$InfoVar2 = ""

$Subscriptions | foreach {
    $EmailMessage = ""
    $SubscriptionName = $_.SubscriptionName

    Write-Output ("Checking subscription {0}" -f $SubscriptionName)

    Clear-Variable InfoVar1
    Clear-Variable InfoVar2

    if ($CheckResourceManagerAzure -eq $true) {
        $a= Select-AzureRmSubscription -SubscriptionId $_.SubscriptionId -WarningVariable InfoVar1
    }

    if ($CheckClassicAzure -eq $true) {
        $a= Select-AzureSubscription -SubscriptionId $_.SubscriptionId -WarningVariable InfoVar2
    }

    if ($InfoVar1.count -eq 0 -and $InfoVar2.count -eq 0) {
        if ($CheckVMs -eq $true) {
            ShutdownVMs -CheckClassicAzure $CheckClassicAzure -CheckResourceManagerAzure $CheckResourceManagerAzure
        }

        if ($CheckSqlDB -eq $true) {
            SQLDBToBasic -CheckResourceManagerAzure $CheckResourceManagerAzure
        }

        if ($CheckStorage -eq $true) {
            StorageToLRS  -CheckClassicAzure $CheckClassicAzure -CheckResourceManagerAzure $CheckResourceManagerAzure
        }

        if ($CheckSqlDW -eq $true) {
            $TempMessage = KillSQLDW  -CheckResourceManagerAzure $CheckResourceManagerAzure
            $EmailMessage = $EmailMessage + $TempMessage
        }

        if ($CheckHdInsight -eq $true) {
            $TempMessage = KillHDInsight -CheckResourceManagerAzure $CheckResourceManagerAzure
            $EmailMessage = $EmailMessage + $TempMessage
        }

        if ($CheckPremiumStorage -eq $true) {
            $TempMessage = CheckPremiumStorage -CheckClassicAzure $CheckClassicAzure -CheckResourceManagerAzure $CheckResourceManagerAzure
            $EmailMessage = $EmailMessage + $TempMessage
        }  
    } else {
        Write-Warning ("Unable to process subscription {0}. Output from RM (if used) was '{1}', output from SM (if used) was '{2}'." -f $SubscriptionName, $InfoVar1[0], $InfoVar2[0])
    }
}

if ($EmailMessage -ne "") {
    Write-Output ("Email message needs to be sent")

    if ($email_cred) {
        $EmailMessage = "Errors for Subscription $SubscriptionName
        <BR><BR>
        $EmailMessage
        <BR><BR>
        "
        $FinalMessage = $FinalMessage + $EmailMessage

		try {
            Send-MailMessage -SmtpServer "smtp.sendgrid.com" -Credential $email_cred  -Port 25 -from $FromEmail -to $ToEmail -subject $Subject -Body $EmailMessage -BodyAsHtml 
		} catch {
			write-warning ("Unable to send email do to failure of send-mailmessage. Email Contents:
				{0}" -f $EmailMessage)
		}
    } else {
        Write-Warning ("Unable to send email.  Email Contents:
        {0}" -f $EmailMessage)
    }
}

Write-Output ("Job complete")

