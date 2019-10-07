## -----------------------------------------
## | Section 0 - Defining input parameters |
## -----------------------------------------

#region
    Param
    (
        [parameter (mandatory = $false)][string]$NetScalerName = "ns01",
        [parameter (mandatory = $false)][string]$NSPassword = "NetScalerDemo!",
        [parameter (mandatory = $false)][string]$NSUsername = "adm-demo"
    )
#endregion

Write-Output ""
Write-Output "## ----------------------------------------------------------------------"
Write-Output "## | Section 1 - Logging onto Azure using the AzureRM PowerShell Module |"
Write-Output "## ----------------------------------------------------------------------"
Write-Output ""

#region Logon information - Use the created PSARM Service Principal (Owner of RG-PSARM) for non-interactive logon to Azure
    #region Read App secrets from CSV file
        #source: https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/import-csv?view=powershell-6
        $AppSecrets = Import-Csv -Path "C:\Scripts\Azure_App_Secrets.csv" -Delimiter ","
        $ApplicationID = $AppSecrets.AppID
        $ApplicationKey = $AppSecrets.AppKey
        $TenantID = $AppSecrets.TenantID
    #endregion
    #region Create Azure Credentials
        $SPpasswd = ConvertTo-SecureString $ApplicationKey -AsPlainText -Force
        $SPCreds = New-Object System.Management.Automation.PSCredential($ApplicationID, $SPpasswd)
    #endregion
#endregion

## Create a session to Azure, using the Service Principal (ApplicationID, AppllicationKey and TenantID) and no interaction
Write-Output "Step 0: Create a session to Azure ... "
$Session = Add-AzureRmAccount -Credential $SPCreds -TenantId $TenantID -ServicePrincipal

## Check if the session is created (and we have the application limited scope!)
If ($Session.Count -gt 0)
{
    Write-Output " => Session Created Successful!"    
}
Else
{
    Throw "Could not log onto Azure, script aborted!"
}

## Retrieve the ResourceGroup associated with the Automation Account (that is used for the session)
$ResourceGroupName = (Get-AzureRmResourceGroup).ResourceGroupName
$vNetName = (Get-AzureRmVirtualNetwork -ResourceGroupName RG-PSARM -WarningAction SilentlyContinue).Name

Write-Output (" => Objects will be created in Resource Group '" + $ResourceGroupName + "'")

Write-Output ""
Write-Output "## -----------------------------------------------------------------------------------"
Write-Output "## | Section 2 - Deploy NetScaler VPX BYOL, based on custom ARM Template (w/ 2 NICs) |"
Write-Output "## -----------------------------------------------------------------------------------"
Write-Output ""

## Create the Admin password as a secure string
Write-Output "Step 1: Create the password for the admin account of the NetScaler (as a secure string)."
$SecurePassword=ConvertTo-SecureString $NSPassword -AsPlainText -Force

## Create Hashtable object
Write-Output "Step 2: Create a Hashtable Object that contains all the ARM Template variables and values."
$objTemplateParameter = @{}

## Add the parameter values to it
$objTemplateParameter.Add('location', 'westeurope')
$objTemplateParameter.Add('virtualMachineName', $NetScalerName)
$objTemplateParameter.Add('virtualMachineSize', 'Standard_A4_v2')
$objTemplateParameter.Add('adminUsername', $NSUsername)
$objTemplateParameter.Add('adminPassword', $SecurePassword)
$objTemplateParameter.Add('virtualNetworkName', 'RG-PSARM-vnet')
$objTemplateParameter.Add('virtualNetworkAddressPrefix', '10.1.4.0/24')             # Places the NetScaler in the same internal network as the Hybrid Worker
$objTemplateParameter.Add('availabilitySetName', 'AS-PSARM-NS')
$objTemplateParameter.Add('nic1SubnetName', 'sn-internal')
$objTemplateParameter.Add('nic1SubnetAddressPrefix', '10.1.4.0/25')
$objTemplateParameter.Add('nic2SubnetName', 'sn-external')
$objTemplateParameter.Add('nic2SubnetAddressPrefix', '10.1.4.128/25')
$objTemplateParameter.Add('networkSecurityGroup1Name', 'nsg-ns-internal')
$objTemplateParameter.Add('networkSecurityGroup2Name', 'nsg-ns-external')

## Show created object
#$objTemplateParameter

## Create NetScaler with TemplateParameterObject
Write-Output "Step 3: Create the NetScaler VPX instance by using a custom build ARM Template."
Write-Output " => cmdlet: New-AzureRmResourceGroupDeployment -ResourceGroupName `$ResourceGroupName -TemplateFile ""C:\Scripts\ARMT_NetScaler_BYOL_v20181005.json"" -TemplateParameterObject `$objTemplateParameter"
New-AzureRmResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile "C:\Scripts\ARMT_NetScaler_BYOL_v20181005.json" -TemplateParameterObject $objTemplateParameter

Write-Output ""
Write-Output "## --------------------------------------------------------------------------------"
Write-Output "## | Section 3 - Retrieve NetScaler VM configuration (reserved IP-addresses, etc) |"
Write-Output "## --------------------------------------------------------------------------------"
Write-Output ""

## Configure the NetScaler for a simple Load Balancing configuration, using the VM NIC IP-address (VIP-LB-SF) information.
Write-Output "Step 4: Retrieving Azure variables values."
$oVM = (Get-AzureRmVm -name $NetScalerName -ResourceGroupName $ResourceGroupName)

Write-Output " => VM information: "
# Retrieve virtual Network object
$oVNet = Get-AzureRmVirtualNetwork -Name $vNetName -ResourceGroupName $ResourceGroupName -WarningAction SilentlyContinue
# Retrieve NIC information
$oVM.NetworkProfile.NetworkInterfaces.Id | ForEach-Object{
    if ($_.split("/")[8] -match "-nic1")
    {
        $NSIP =  (Get-AzureRmNetworkInterface -Name $_.split("/")[8] -ResourceGroupName $ResourceGroupName | Get-AzureRmNetworkInterfaceIpConfig -name "NSIP").PrivateIpAddress 
        $InternalSNIP =  (Get-AzureRmNetworkInterface -Name $_.split("/")[8] -ResourceGroupName $ResourceGroupName | Get-AzureRmNetworkInterfaceIpConfig -name "SNIP-Backend").PrivateIpAddress 
        $InternalSubnet = (Get-AzureRmNetworkInterface -Name $_.split("/")[8] -ResourceGroupName $ResourceGroupName | Get-AzureRmNetworkInterfaceIpConfig -name "SNIP-Backend").Subnet.id.split("/")[10]
        $InternalSubnetmask = (get-AzureRmVirtualNetworkSubnetConfig -Name $InternalSubnet -VirtualNetwork $oVNet -WarningAction SilentlyContinue).AddressPrefix.split("/")[1]
        switch ($InternalSubnetmask){
            26{$InternalSubnetmaskSNIP = "255.255.0.0"}
            30{$InternalSubnetmaskSNIP = "255.255.255.252"}
            29{$InternalSubnetmaskSNIP = "255.255.255.248"}
            28{$InternalSubnetmaskSNIP = "255.255.255.240"}
            27{$InternalSubnetmaskSNIP = "255.255.255.224"}
            26{$InternalSubnetmaskSNIP = "255.255.255.192"}
            25{$InternalSubnetmaskSNIP = "255.255.255.128"}
            24{$InternalSubnetmaskSNIP = "255.255.255.0"}
            23{$InternalSubnetmaskSNIP = "255.255.254.0"}
            22{$InternalSubnetmaskSNIP = "255.255.252.0"}
            21{$InternalSubnetmaskSNIP = "255.255.248.0"}
            20{$InternalSubnetmaskSNIP = "255.255.240.0"}
            19{$InternalSubnetmaskSNIP = "255.255.224.0"}
            18{$InternalSubnetmaskSNIP = "255.255.192.0"}
            17{$InternalSubnetmaskSNIP = "255.255.128.0"}
            16{$InternalSubnetmaskSNIP = "255.255.0.0"}
        }
    }
    if ($_.split("/")[8] -match "-nic2"){
        $ExternalSNIP =  (Get-AzureRmNetworkInterface -Name $_.split("/")[8] -ResourceGroupName $ResourceGroupName | Get-AzureRmNetworkInterfaceIpConfig -name "SNIP-Public").PrivateIpAddress 
        $ExternalSubnet = (Get-AzureRmNetworkInterface -Name $_.split("/")[8] -ResourceGroupName $ResourceGroupName | Get-AzureRmNetworkInterfaceIpConfig -name "SNIP-Public").Subnet.id.split("/")[10]
#        $LBVIPStoreFront =   (Get-AzureRmNetworkInterface -Name $_.split("/")[8] -ResourceGroupName $ResourceGroupName | Get-AzureRmNetworkInterfaceIpConfig -name "VIP-LB-SF").PrivateIpAddress  # internal only address (cannot be reached from the internet)
        $LBVIPStoreFront =   (Get-AzureRmNetworkInterface -Name $_.split("/")[8] -ResourceGroupName $ResourceGroupName | Get-AzureRmNetworkInterfaceIpConfig -name "VIP-NSG-Public").PrivateIpAddress   # internal and external IP-addresses, so can be reached using the external IP-address!
        $ExternalSubnetmask = (get-AzureRmVirtualNetworkSubnetConfig -Name $ExternalSubnet -VirtualNetwork $oVNet -WarningAction SilentlyContinue).AddressPrefix.split("/")[1]
        switch ($ExternalSubnetmask){
            26{$ExternalSubnetmaskSNIP = "255.255.0.0"}
            30{$ExternalSubnetmaskSNIP = "255.255.255.252"}
            29{$ExternalSubnetmaskSNIP = "255.255.255.248"}
            28{$ExternalSubnetmaskSNIP = "255.255.255.240"}
            27{$ExternalSubnetmaskSNIP = "255.255.255.224"}
            26{$ExternalSubnetmaskSNIP = "255.255.255.192"}
            25{$ExternalSubnetmaskSNIP = "255.255.255.128"}
            24{$ExternalSubnetmaskSNIP = "255.255.255.0"}
            23{$ExternalSubnetmaskSNIP = "255.255.254.0"}
            22{$ExternalSubnetmaskSNIP = "255.255.252.0"}
            21{$ExternalSubnetmaskSNIP = "255.255.248.0"}
            20{$ExternalSubnetmaskSNIP = "255.255.240.0"}
            19{$ExternalSubnetmaskSNIP = "255.255.224.0"}
            18{$ExternalSubnetmaskSNIP = "255.255.192.0"}
            17{$ExternalSubnetmaskSNIP = "255.255.128.0"}
            16{$ExternalSubnetmaskSNIP = "255.255.0.0"}
        }
    }
}

## Show all retrieved values
Write-Output ("`t  - NSIP: " + $NSIP)
Write-Output ("`t  - Internal SNIP: " + $InternalSNIP)
Write-Output ("`t  - Internal SNIP Subnetmask: " + $InternalSubnetmaskSNIP)
Write-Output ("`t  - External SNIP: " + $ExternalSNIP)
Write-Output ("`t  - External SNIP Subnetmask: " + $ExternalSubnetmaskSNIP)
Write-Output ("`t  - VIP StoreFront: " + $LBVIPStoreFront)

#Write-Output "=> Waiting for NetScaler VPX to be up and running ... (3 minute delay)"
#Start-Sleep -Seconds 60
Write-Output "=> Waiting for NetScaler VPX to be up and running ... (2 minute delay)"
Start-Sleep -Seconds 60
Write-Output "=> Waiting for NetScaler VPX to be up and running ... (1 minute delay)"
Start-Sleep -Seconds 60

Write-Output ""
Write-Output "## -------------------------------------------------------------------"
Write-Output "## | Section 4 - Configure the NetScaler using NITRO, REST API calls |"
Write-Output "## -------------------------------------------------------------------"
Write-Output ""

#Log on to the NetScaler VPX with REST API
Write-Output "Step 5: Log on to the NetScaler VPX instance, using a REST API call."
#region Start NetScaler NITRO Session
    #Connect to the NetScaler VPX Virtual Appliance
    $Login = @{"login" = @{"username"=$NSUsername;"password"=$NSPassword;"timeout"="900"}} | ConvertTo-Json
    $dummy = Invoke-RestMethod -Uri ("http://" + $NSIP + "/nitro/v1/config/login") -Body $Login -Method POST -SessionVariable NetScalerSession -ContentType "application/json"
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Uri (""http://"" + `$NSIP + ""/nitro/v1/config/login"") -Body `$Login -Method POST -SessionVariable NetScalerSession -ContentType ""application/json"""


Write-Output "Step 6: Retrieve License information for this NetScaler VPX instance."
#region Get License information
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/nslicense")

    # Method #1: Making the REST API call to the NetScaler
#    (Invoke-RestMethod -Method Get -Uri $strURI -ContentType $ContentType -WebSession $NetScalerSession -Verbose:$VerbosePreference -ErrorAction SilentlyContinue).nslicense | Select-Object modelid, isstandardlic,isenterpriselic,isplatinumlic, f_sslvpn_users
    $LicInfo = (Invoke-RestMethod -Method Get -Uri $strURI -ContentType "application/json" -WebSession $NetScalerSession).nslicense
    Write-Output ("`nLicense info: `n-------------`n`tLicensing mode = " +  $LicInfo.licensingmode + "; model ID = " + $LicInfo.modelid + "; Standard License = " + $LicInfo.isstandardlic + "; Enterprise License = " + $LicInfo.isenterpriselic + "; Platinum License = " + $LicInfo.isplatinumlic + "`n")
#endregion
Write-Output " => cmdlet: (Invoke-RestMethod -Method Get -Uri `$strURI -ContentType ""application/json"" -WebSession `$NetScalerSession).nslicense"


Write-Output "Step 7: Configure the Internal & External SNIP on the NetScaler VPX instance"
#region Configure SNIP
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/nsip")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "nsip"= @(
        @{"ipaddress"=$InternalSNIP;"netmask"=$InternalSubnetmaskSNIP;"type"="SNIP"},
        @{"ipaddress"=$ExternalSNIP;"netmask"=$ExternalSubnetmaskSNIP;"type"="SNIP"}
        )
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $dummy = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -ErrorAction SilentlyContinue
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 8: Configure the hostname on the NetScaler VPX instance"
#region Add Hostname
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/nshostname")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "nshostname"= @{
        "hostname"="NSAzureNitroDemo";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $dummy = Invoke-RestMethod -Method Put -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -ErrorAction SilentlyContinue
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Put -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 9: Configure a DNS Server on the NetScaler VPX instance"
#region Add DNS Server
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/dnsnameserver")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "dnsnameserver"= @{
        "ip"="8.8.8.8";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $dummy = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference -ErrorAction SilentlyContinue
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 10: Configure the Timezone on the NetScaler VPX instance"
#region Set Timezone
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/nsconfig")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "nsconfig"= @{
        "timezone"="GMT+01:00-CET-Europe/Amsterdam";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $dummy = Invoke-RestMethod -Method Put -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -ErrorAction SilentlyContinue
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Put -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 11: Enable NetScaler Modes on the NetScaler VPX instance"
#region Enable NetScaler Modes
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/nsmode?action=enable")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "nsmode"= @{
        "mode"=@("FR","Edge","L3","USNIP","PMTUD")
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $dummy = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference -ErrorAction SilentlyContinue
#endregion Enable NetScaler Modes
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 12: Disable the NetScaler Feature Call Home on the NetScaler VPX instance"
#region Disable NetScaler Feature (Call Home)
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/nsfeature?action=disable")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "nsfeature"= @{
        "feature"=@("CH")
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $dummy = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference -ErrorAction SilentlyContinue
#endregion Disable NetScaler Modes
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 13: Enable NetScaler Basic & Advanced Features on the NetScaler VPX instance"
#region Enable NetScaler Basic & Advanced Features
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/nsfeature?action=enable")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "nsfeature"= @{
        "feature"=@("LB","SSL","REWRITE","RESPONDER")
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $dummy = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference -ErrorAction SilentlyContinue
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 14: Configure Rewrite action on the NetScaler VPX instance"
#region Add Rewrite Actions
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/rewriteaction")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "rewriteaction"= @{
           "name"="rwa_store_redirect";
           "type"="replace";
           "target"="HTTP.REQ.URL";
           "stringbuilderexpr"="""/Citrix/StoreWeb""";
           "comment"="created by PowerShell script";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion Add Rewrite Actions
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 15: Configure Rewrite policy on the NetScaler VPX instance"
#region Add Rewrite Policies
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/rewritepolicy")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "rewritepolicy"= @{
           "name"="rwp_store_redirect";
           "rule"="HTTP.REQ.URL.EQ(""/"")";
           "action"="rwa_store_redirect";
           "comment"="created by PowerShell script";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 16: Configure Responder action on the NetScaler VPX instance"
#region Add Responder Actions
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/responderaction")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "responderaction"= @{
          "name"="rspa_http_https_redirect";
          "type"="redirect";
          "target"="""https://"" + HTTP.REQ.HOSTNAME.HTTP_URL_SAFE + HTTP.REQ.URL.PATH_AND_QUERY.HTTP_URL_SAFE";
          "comment"="created by PowerShell script";
          "responsestatuscode"=302;
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 17: Configure a Responder policy on the NetScaler VPX instance"
#region Add Responder Policies
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/responderpolicy")

    # Creating the right payload formatting (mind the Depth for the nested arrays)
    $payload = @{
    "responderpolicy"= @{
           "name"="rspp_http_https_redirect";
           "rule"="HTTP.REQ.IS_VALID";
           "action"="rspa_http_https_redirect";
           "comment"="created by PowerShell script";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 18: Configure Servers on the NetScaler VPX instance"
#region Add LB Servers (bulk)
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/server")

    # Creating the right payload formatting (mind the Depth for the nested arrays)

    $payload = @{
        "server"= @(
            @{"name"="lb_svr_alwaysOn"; "ipaddress"="1.2.3.4"},
            @{"name"="SFGreen"; "ipaddress"="10.1.4.7"},
            @{"name"="SFBlue"; "ipaddress"="10.1.4.6"}
        )
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 19: Configure a ServiceGroup on the NetScaler VPX instance"
#region Add LB Services
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/service")

    # add 
    $payload = @{
        "service"= @{
        "name"="svc_alwaysOn";
        "servername"="lb_svr_alwaysOn";
        "servicetype"="HTTP";
        "port"=80;
        "healthmonitor"="NO";
        "comment"="created by PowerShell script";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion Add LB Services
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 20: Configure a ServiceGroup on the NetScaler VPX instance"
#region Add ServiceGroups
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/servicegroup")

    # 
    $payload = @{
    "servicegroup"= @{
        "servicegroupname"="svcgrp_SFStore";
        "servicetype"="HTTP";
        "cacheable"="YES";
        "healthmonitor"="YES";
        "state"="ENABLED"
        "appflowlog"="ENABLED";
        "autoscale"="DISABLED";
        "comment"="created by PowerShell script";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 21: Configure a ServiceGroup Binding on the NetScaler VPX instance"
#region Add ServiceGroup Bindings (bulk)
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/servicegroup_servicegroupmember_binding")

    $payload = @{
    "servicegroup_servicegroupmember_binding"= @(
            @{"servicegroupname"="svcgrp_SFStore";"servername"="SFGreen";"port"=80;"state"="ENABLED";"weight"=2},
            @{"servicegroupname"="svcgrp_SFStore";"servername"="SFBlue";"port"=80;"state"="ENABLED";"weight"=1}
        )
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 22: Configure LB vServers on the NetScaler VPX instance"
#region Add LB vServers (bulk)
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/lbvserver")

    $payload = @{
    "lbvserver"= @(
            @{"name"="vsvr_SFStore_http_redirect";"servicetype"="HTTP";"ipv46"=$LBVIPStoreFront;"port"=80;"lbmethod"="ROUNDROBIN"},
            @{"name"="vsvr_SFStore";"servicetype"="SSL";"ipv46"=$LBVIPStoreFront;"port"=443;"lbmethod"="ROUNDROBIN"}
        )
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference

#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 23: Configure LB vServer bindings on the NetScaler VPX instance"
#region Bind Service to vServer
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/lbvserver_service_binding")

    $payload = @{
    "lbvserver_service_binding"= @{
        "name"="vsvr_SFStore_http_redirect";
        "servicename"="svc_alwaysOn";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Put -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Put -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 24: Configure a LB vServer binding on the NetScaler VPX instance"
#region Bind ServiceGroup to vServer
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/lbvserver_servicegroup_binding")

    # 
    $payload = @{
    "lbvserver_servicegroup_binding"= @{
        "name"="vsvr_SFStore";
        "servicegroupname"="svcgrp_SFStore";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Put -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Put -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 25: Configure a LB vServer binding on the NetScaler VPX instance"
#region Bind Responder Policy to vServer
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/lbvserver_responderpolicy_binding")

    $payload = @{
    "lbvserver_responderpolicy_binding"= @{
        "name"="vsvr_SFStore_http_redirect";
        "policyname"="rspp_http_https_redirect";
        "priority"=100;
        "gotopriorityexpression"="END";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Put -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion Bind Responder Policy to vServer
Write-Output " => cmdlet: Invoke-RestMethod -Method Put -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 26: Configure a DNS Server on the NetScaler VPX instance"
#region Bind Rewrite Policy to vServer
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/lbvserver_rewritepolicy_binding")

    $payload = @{
    "lbvserver_rewritepolicy_binding"= @{
        "name"="vsvr_SFStore";
        "policyname"="rwp_store_redirect";
        "priority"=100;
        "gotopriorityexpression"="END";
        "bindpoint"="REQUEST";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Put -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion Bind Rewrite Policy to vServer
Write-Output " => cmdlet: Invoke-RestMethod -Method Put -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 27: Upload a certificate on the NetScaler VPX instance"
#region Upload certificates
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/systemfile")

    # Creating the right payload formatting (mind the Depth for the nested arrays)

    # get the FileName, Content and Base64 String from the FilePath
    # keep in mind that the filenames are case-sensitive
    $PathToFile = "C:\Scripts\rootCA_demo_nuc.cer"
    $File1Name = Split-Path -Path $PathToFile -Leaf                                                 # Parameter explained: -Leaf     => Indicates that this cmdlet returns only the last item or container in the path. For example, in the path C:\Test\Logs\Pass1.log, it returns only Pass1.log.
    $FileContent = Get-Content $PathToFile -Encoding "Byte"
    $File1ContentBase64 = [System.Convert]::ToBase64String($FileContent)

    $PathToFile = "C:\Scripts\star_demo_nuc.pfx"
    $File2Name = Split-Path -Path $PathToFile -Leaf                                                 # Parameter explained: -Leaf     => Indicates that this cmdlet returns only the last item or container in the path. For example, in the path C:\Test\Logs\Pass1.log, it returns only Pass1.log.
    $FileContent = Get-Content $PathToFile -Encoding "Byte"
    $File2ContentBase64 = [System.Convert]::ToBase64String($FileContent)

    $payload = @{
        "systemfile"= @(
            @{"filename"=$File1Name; "filecontent"=$File1ContentBase64; "filelocation"="/nsconfig/ssl/"; "fileencoding"="BASE64"},
            @{"filename"=$File2Name; "filecontent"=$File2ContentBase64; "filelocation"="/nsconfig/ssl/"; "fileencoding"="BASE64"}
        )
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference -ErrorVariable restError
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 28: Configure a CertKey pair on the NetScaler VPX instance"
#region Add certificate - key pairs
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/sslcertkey")

    $payload = @{
        "sslcertkey"= @(
            @{"certkey"="RootCA"; "cert"="/nsconfig/ssl/rootCA_demo_nuc.cer"; "inform"="PEM"; "expirymonitor"="ENABLED"; "notificationperiod"=25},
            @{"certkey"="wildcard"; "cert"="/nsconfig/ssl/star_demo_nuc.pfx"; "inform"="PFX"; "passplain"="password"}
        )
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 29: Configure a Certificate Link on the NetScaler VPX instance"
#region Add certificate - links
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/sslcertkey?action=link")

    # link ssl certKey wildcard RootCA 
    $payload = @{
    "sslcertkey"= @{
        "certkey"="wildcard";
        "linkcertkeyname"="RootCA";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Post -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion Add certificate - links
Write-Output " => cmdlet: Invoke-RestMethod -Method Post -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output "Step 30: Configure LB vServer binding on the NetScaler VPX instance"
#region Bind Certificate to VServer
    # Specifying the correct URL 
    $strURI = ("http://" + $NSIP + "/nitro/v1/config/sslvserver_sslcertkey_binding")

    # bind ssl vserver vsvr_SFStore -certkeyName wildcard.demo.lab
    $payload = @{
    "sslvserver_sslcertkey_binding"= @{
        "vservername"="vsvr_SFStore";
        "certkeyname"="wildcard";
        }
    } | ConvertTo-Json -Depth 5

    # Logging NetScaler Instance payload formatting
    Write-Output " => JSON payload: "
    Write-Output $payload

    # Method #1: Making the REST API call to the NetScaler
    $response = Invoke-RestMethod -Method Put -Uri $strURI -Body $payload -ContentType "application/json" -WebSession $NetScalerSession -Verbose:$VerbosePreference
#endregion
Write-Output " => cmdlet: Invoke-RestMethod -Method Put -Uri `$strURI -Body `$payload -ContentType ""application/json"" -WebSession `$NetScalerSession -ErrorAction SilentlyContinue"


Write-Output ""
Write-Output "!! All NetScaler configuration actions are finished !!"
Write-Output ""
