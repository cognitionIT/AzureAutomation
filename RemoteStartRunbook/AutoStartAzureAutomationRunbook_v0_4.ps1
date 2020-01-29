#requires -Version 3
# ---------------------------------------------------
# Based upon the script shared by MS employee Stefan Stranger
#                https://blogs.technet.microsoft.com/stefan_stranger/2017/08/09/triggering-azure-automation-runbooks-using-the-azure-arm-rest-api/
# ... and the script from Laurie Rhodes
#             http://www.laurierhodes.info/?q=node/118
# ---------------------------------------------------


## ------------------------------------------------------------------
## | Section 1 - Create a Access Token for Azure with REST API call |
## ------------------------------------------------------------------
Write-Output ""
Write-Host "* Creating an Access Token for Azure, using REST API" -ForegroundColor Yellow

# Azure Automation account information
    $ResourceGroupName = "RG-PSARM"
    $AutomationAccountName = "DevOps-PSARM"
    $APIVersion = "2015-10-31"
    $RunbookName = "Az_RB_deploy_NS_v4"
    $HybridWorkerGroup = "HWG-PSARM"

#region Read App secrets from CSV file
    #source: https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/import-csv?view=powershell-6
    $AppSecrets = Import-Csv -Path "C:\`$_Sources\Azure_App_Secrets.csv" -Delimiter ","
    $ClientID = $AppSecrets.AppID
    $ClientSecret = $AppSecrets.AppKey
    $TenantID = $AppSecrets.TenantID
    $SubscriptionID = $AppSecrets.SubscriptionID
#endregion

$TokenEndpoint = {https://login.windows.net/{0}/oauth2/token} -f $TenantID 
$ARMResource = "https://management.core.windows.net/";

# Create the JSON payload
$Body = @{
        'resource'= $ARMResource
        'client_id' = $ClientID
        'grant_type' = 'client_credentials'
        'client_secret' = $ClientSecret
}

# Create the parameters for the REST API call
$params = @{
    ContentType = 'application/x-www-form-urlencoded'
    Headers = @{'accept'='application/json'}
    Body = $Body
    Method = 'Post'
    URI = $TokenEndpoint
}

# Get a token, based on the REST API call
$token = Invoke-RestMethod @params

# Show the access token en expire date
Write-Output ""
Write-Host "Token information: " -ForegroundColor Yellow
$token | select access_token, @{L='Expires';E={[timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($_.expires_on))}} | fl *


## ----------------------------------------------------------------------------
## | Section 2 - Start a specific Azure Automation Runbook with REST API call |
## ----------------------------------------------------------------------------

#region Start specified Runbook
    Write-Host "* Start a specific Runbook, using REST API" -ForegroundColor Yellow
    $Uri = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/jobs/{3}?api-version={4}' `
    -f $SubscriptionID, $ResourceGroupName, $AutomationAccountName, $((New-Guid).guid), $APIVersion
    
    $body = ConvertTo-Json @{
        "properties" = @{
            "runbook"  = @{"name" = $RunbookName}
            "parameters" = @{"NetScalerName" = "ns01";"NSPassword" = "NetScalerDemo!";"NSUsername" = "adm-demo"}
            "runon" = $HybridWorkerGroup
        }
        "tags" = @{}
    } -Depth 5

    # Invoke-RestMethod parameters
    $params = @{
        ContentType = "application/json"
        Headers = @{"authorization" = "Bearer $($token.Access_Token)"}
        Method = "Put"
        URI = $Uri
        Body = $body
    }

    # Make the REST API call
    $oRunbook = Invoke-RestMethod @params

    # Check the output
    Write-Output ""
    Write-Host "Runbook properties: " -ForegroundColor Yellow
    $oRunbook.properties
#endregion


## ---------------------------------------------------------------------------
## | Section 3 - Retrieve Azure Automation Runbook Status with REST API call |
## ---------------------------------------------------------------------------

#region get Runbook Status
    Write-Host "* Check the Runbook Job status, using REST API" -ForegroundColor Yellow
    $Uri ='https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/Jobs/{3}?api-version={4}' -f $SubscriptionID, $ResourceGroupName, $AutomationAccountName, $($oRunbook.properties.jobId), $APIVersion
    $params = @{
      ContentType = "application/application-json"
      Headers     = @{"authorization" = "Bearer $($token.Access_Token)"}
      Method      = "Get"
      URI         = $Uri
    }

    $doLoop = $true
    While ($doLoop)
    {
        Start-Sleep -Seconds 30
        $results = Invoke-RestMethod @params
        $Status = $results.properties.provisioningState
        Write-Host "=> Runbook Provisioning Status = " -ForegroundColor Yellow -nonewline
        Write-Host "$($Status)" -ForegroundColor Green
        $doLoop = (($Status -ne "Succeeded") -and ($Status -ne "Failed") -and ($Status -ne "Suspended") -and ($Status -ne "Stopped"))
    }
#endregion


## -----------------------------------------------------------------------
## | Section 4 - Get Azure Automation Runbook Summary with REST API call |
## -----------------------------------------------------------------------

#region get Runbook Summary
    Write-Host "* Get the Runbook Job Summary, using REST API" -ForegroundColor Yellow
#    $Uri ='https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/Jobs/{3}?api-version={4}' -f $SubscriptionID, $ResourceGroupName, $AutomationAccountName, $($oRunbook.properties.jobId), $APIVersion
    $URI  = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/jobs/{3}/streams?$filter=properties/streamType%20eq%20'Output'&api-version={4}" -f $SubscriptionID, $ResourceGroupName, $AutomationAccountName, $($oRunbook.properties.jobId), $APIVersion
    $params = @{
      ContentType = "application/application-json"
      Headers     = @{"authorization" = "Bearer $($token.Access_Token)"}
      Method      = "Get"
      URI         = $Uri
    }
    $response = Invoke-RestMethod @params
    $Summary = ($response.value).properties.summary
    Write-Output ""
    Write-Host "=> Runbook Provisioning Summary: " -ForegroundColor Yellow
    Write-Host "$($Summary)"
#endregion


