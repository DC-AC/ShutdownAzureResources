# ShutdownAzureResources
Automatically shutdown (or scale down) Azure resources on a schedule every day.

This solutions requires at least one Credential be created within the runbook configruation.   This Credential can be created with any name and needs to have the a username and password for an account which has access to manage the Azure Subscription.

A second credential can be created with any name with your credentials for SendGrid.

For the $SubscriptionFilter parameter specify a string filter to filter down the list of subscriptions to process such as "*dev*".
