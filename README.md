[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FDC-AC%2FShutdownAzureResources%2Fmaster%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FDC-AC%2FShutdownAzureResources%2Fmaster%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

# ShutdownAzureResources
Automatically shutdown (or scale down) Azure resources on a schedule every day.

This solutions requires at least one Credential be created within the runbook configruation.   This Credential can be created with any name and needs to have the a username and password for an account which has access to manage the Azure Subscription.

A second credential can be created with any name with your credentials for SendGrid.

For the $SubscriptionFilter parameter specify a string filter to filter down the list of subscriptions to process such as "dev*".

You can then schedule this runbook to run as often as you'd like.

After the runbook is deployed you'll need to upgrade the PowerShell module which is included in the Automation account.  Use the instructions <a href="http://blog.coretech.dk/jgs/azure-automation-script-for-downloading-and-preparing-azurerm-modules-for-azure-automation/">here</a> to upgrade the PowerShell modules for the Azure Automation account.  You will need to upgrade the PowerShell module AzureRM.Profile first, then upgrade the rest of the PowerShell modules.

After upgrading the Azure PowerShell modules you'll need to schedule how often you want the modeule to run using the Runbook Scheduler.  It is recommended to configure it to run nightly.
