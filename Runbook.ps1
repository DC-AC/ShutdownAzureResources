param(
     [parameter(Mandatory=$true, HelpMessage="String to match all the subscriptions you wish to process.")]
     [string]$SubscriptionFilter,

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

    try {
        add-AzureRmAccount -Credential $cred -InformationVariable InfoVar -ErrorVariable ErrorVar
    }
    catch {
        Clear-Variable cred
        write-warning ("Unable to authenticate to AzureRM using the provided credentials")
		write-warning($ErrorVar)
        return
    }

    try {
        add-AzureAccount -Credential $cred -InformationVariable InfoVar -ErrorVariable ErrorVar
    }
    catch {
        Clear-Variable cred
        write-warning ("Unable to authenticate to AzureSM using the provided credentials")
		write-warning( $ErrorVar)
        return
    }
}

try {
    $email_cred = Get-AutomationPSCredential -Name $EMailAccount
}
catch {
    write-warning ("Unable to get email credential. Emailing features are disabled.")
}


$Subscriptions = Get-AzureRmSubscription -InformationVariable InfoVar | where ({$_.SubscriptionName -like $SubScriptionFilter})

function ShutdownVMs {
    $VMs = get-AzureRMVM

    $VMs | foreach {
        $VM = get-AzureRmVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name -Status

        
        $State = $VM.Statuses | where ({ $_.Code -eq "PowerState/deallocated" })
        
        if ($State.count -eq 0) {
            write-output ("Attempting to stop RM VM {0}" -f $VM.Name)
            Stop-AzureRmVM -Name $_.Name -ResourceGroupName $_.ResourceGroupName -Force -InformationVariable InfoVar
        } else {
            write-output ("RM VM {0} is already stopped" -f $VM.Name)
        }
    }

    Clear-Variable VMs

    $VMs = get-azureVM

    $VMs | foreach {
        
        if ($_.Status -ne "StoppedDeallocated") {
            write-output ("Attempting to stop SM VM {0}" -f $_.Name)
            stop-AzureVM -Name $_.Name -ServiceName $_.ServiceName -Force -ErrorVariable ErrorVar -InformationVariable InfoVar
        } else { 
            Write-output ("SM VM {0} is alrady stopped." -f $_.Name)
        }
    }
}

function SQLDBToBasic {
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
                Set-AzureRmSqlDatabase -ServerName $Server -DatabaseName $DatabaseName  -ResourceGroupName $ResourceGroupName -RequestedServiceObjectiveName "Basic" -ErrorAction SilentlyContinue -InformationVariable InfoVar
            }
        }
    }
}

function StorageToLRS {
        $StorageAccounts = get-AzureRmStorageAccount 

        $StorageAccounts | foreach {
            write-output ("Attempting to change storage account {0} to LRS" -f $_.StorageAccountName)
            Set-AzureRmStorageAccount -Name $_.StorageAccountName -ResourceGroupName $_.ResourceGroupName -SkuName "Standard_LRS" -InformationVariable InfoVar 
        }

        Clear-Variable StorageAccounts 

        $StorageAccounts = get-azureStorageAccount | where ({$_.AccountType -ne "Standard_LRS"})
        $StorageAccounts | foreach {
            write-output ("Attempting to change storage account {0} to LRS" -f $_.StorageAccountName)
            set-AzureStorageAccount -StorageAccountName $_.StorageAccountName -GeoReplicationEnabled $false -InformationVariable InfoVar
        }
}

function KillSQLDW {
    $MailMessage = "";
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
    return $MailMessage
}

function KillHDInsight {
    $MailMessage = "";

    $Clusters = Get-AzureRmHdInsightCluster 

    $Clusters | foreach {
        $Cluster = get-AzureRmResource -ResourceId $_.Id
        $Properties = $Cluster.Properties
        [datetime] $Created = $Properties.createdDate
        [datetime] $now = get-date
        [timespan] $Timespan = $now - $Created

        if ($Timespan.TotalDays -gt 3) {
            Write-Output ("Killing HD Insite cluster {0}" -f $_.Name)
            Remove-AzureRmHDInsightCluster -ClusterName $_.Name -ResourceGroupName $_.ResourceGroup -InformationVariable InfoVar -ErrorVariable ErrorVar
        } else {
            $MailMessage = "$MailMessage <BR>
            The HDInsite Cluster $_.Name is going to be deleted in less than three days."
        }
    }

    return $MailMessage
}

Function CheckPremiumStorage {
    $StorageAccounts = get-AzureRmStorageAccount 
    $EmAilMessage = ""

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

    $StorageAccounts = get-azureStorageAccount | where ({$_.AccountType -like "*Premium*"})
    $StorageAccounts | foreach {
        $StorageAccountName = $_.StorageAccountName

          $EmailMessage = "$EmailMessage <BR>
          $StorageAccountName is using premium storage.  Unable to fix, logged."  

    
        write-warning ("Storage account {0} is using premium storage. Unable to fix, logged." -f $_.StorageAccountName)
    }

    return $EmailMessage
}

$FinalEmail = ""

$Subscriptions | foreach {
    $EmailMessage = ""
    $SubscriptionName = $_.SubscriptionName

    Select-AzureRmSubscription -SubscriptionId $_.SubscriptionId -InformationVariable InfoVar
    Select-AzureSubscription -SubscriptionId $_.SubscriptionId -InformationVariable InfoVar

    ShutdownVMs
    SQLDBToBasic
    StorageToLRS
    $TempMessage = KillSQLDW
    $EmailMessage = $EmailMessage + $TempMessage

    $TempMessage = KillHDInsight
    $EmailMessage = $EmailMessage + $TempMessage

    $TempMessage = CheckPremiumStorage
    $EmailMessage = $EmailMessage + $TempMessage

    if ($EmailMessage -ne "") {
        $EmailMessage = "Errors for Subscription $SubscriptionName
        <BR><BR>
        $EmailMessage
        <BR><BR>
        "
        $FinalMessage = $FinalMessage + $EmailMessage
    }
   
}

if ($EmailMessage -ne "") {
    if ($email_cred) {
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
