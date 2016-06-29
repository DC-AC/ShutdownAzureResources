<B>New Depoyments</B><BR>
[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FDC-AC%2FShutdownAzureResources%2Fmaster%2Fazuredeploy.json) 
<a href="http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FDC-AC%2FShutdownAzureResources%2Fmaster%2Fazuredeploy.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

<B>Upgrading an existing Runbook</B><BR>
[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FDC-AC%2FShutdownAzureResources%2Fmaster%2FazureUpgrade.json) 


# ShutdownAzureResources
Automatically shutdown (or scale down) Azure resources on a schedule every day.

This solutions requires at least one Credential be created within the runbook configruation.   This Credential can be created with any name and needs to have the a username and password for an account which has access to manage the Azure Subscription.

A second credential can be created with any name with your credentials for SendGrid.

For the $SubscriptionFilter parameter specify a string filter to filter down the list of subscriptions to process such as "dev*".

You can then schedule this runbook to run as often as you'd like.

The deployment now automatically upgrades all the PowerShell modules from a static source stored in an Azure Storage Account.  If for some reason the modeles throw errors when being upgraded (it happens for no good reason we can find, and it happens randomly) upgrade the failed modules manually as shown in this <a href="http://blog.coretech.dk/jgs/azure-automation-script-for-downloading-and-preparing-azurerm-modules-for-azure-automation/">blog post</a>.  When you deploy there is a parameter which is set with the URI to get the PowerShell modules from.  You can change this to your own URI if desired.

After upgrading the Azure PowerShell modules (if needed) you'll need to schedule how often you want the modeule to run using the Runbook Scheduler.  It is recommended to configure it to run nightly.

If you have deployed this in the past and just wish to upgrade to the latest version use the Upgrade button at the top of this page so avoid having to fill out the various credentials when deploying. Do make sure to select the current Resource Group and the current Region to deploy to.
