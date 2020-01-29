# Getting Started with AzureRM => RIGHT MODULE
Install-Module Az

#region Logon information - Use the created PSARM Service Principal (Owner of RG-PSARM) for non-interactive logon to Azure
    #region Read App secrets from CSV file
        #source: https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/import-csv?view=powershell-6
        $AppSecrets = Import-Csv -Path "C:\`$_Sources\Azure_App_Secrets.csv" -Delimiter ","
        $SubscriptionID = $AppSecrets.SubscriptionID

        $AutomationAccountName = "DevOps-PSARM"
        $AAResourceGroupName = "RG-PSARM"
        $LogAnalyticsWorkspaceName = "OMS-WS-PSARM"
        $OMSResourceGroupName = "RG-PSARM"
        $HybridGroupName = "HWG-PSARM"
    #endregion
#endregion

C:\Scripts\New-OnPremiseHybridWorker.ps1 -AutomationAccountName $AutomationAccountName -AAResourceGroupName $AAResourceGroupName `
-OMSResourceGroupName $OMSResourceGroupName -HybridGroupName $HybridGroupName `
-SubscriptionId $SubscriptionID -WorkspaceName $LogAnalyticsWorkspaceName


