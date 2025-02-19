#
# This script provides a scaleable solution to set or change the license type on all Azure-connected SQL Servers
# in a specific subscription, a list of subscruiptions or the entire account. By default, it sets the new license  
# type value only on the servers where it is undefined. 
#
# You can specfy a single subscription to scan, or provide subscriptions as a .CSV file with the list of IDs. 
# If not specified, all subscriptions your role has access to are scanned. 
#
# The script accepts the following command line parameters:
# 
# -SubId [subscription_id] | [csv_file_name]    (Limit scope to specific subscriptions. Accepts a .csv file with the list of subscriptions)
# -ResourceGroup [resource_goup]                (Limit scope  to a specific resoure group)
# -MachineName [machine_name]                   (Limit scope to a specific machine)
# -LicenseType [license_type_value]             (Specific LT value)
# -All                                          (Optional. Set the new license type value only if undefined)
# 

param (
    [Parameter (Mandatory= $false)] 
    [string] $SubId, 
    [Parameter (Mandatory= $false)] 
    [string] $ResourceGroup, 
    [Parameter (Mandatory= $false)] 
    [string] $MachineName, 
    [Parameter (Mandatory= $false)]
    [string] $LicenseType="Paid", 
    [Parameter (Mandatory= $false)]
    [boolean] $All=$false
)

function CheckModule ($m) {

    # This function ensures that the specified module is imported into the session
    # If module is already imported - do nothing

    if (!(Get-Module | Where-Object {$_.Name -eq $m})) {
         # If module is not imported, but available on disk then import
        if (Get-Module -ListAvailable | Where-Object {$_.Name -eq $m}) {
            Import-Module $m 
        }
        else {

            # If module is not imported, not available on disk, but is in online gallery then install and import
            if (Find-Module -Name $m | Where-Object {$_.Name -eq $m}) {
                Install-Module -Name $m -Force -Verbose -Scope CurrentUser
                Import-Module $m
            }
            else {

                # If module is not imported, not available and not in online gallery then abort
                write-host "Module $m not imported, not available and not in online gallery, exiting."
                EXIT 1
            }
        }
    }
}

function ObjectToHashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
    process {
        ## Return null if the input is null. This can happen when calling the function
        ## recursively and a property is null
        if ($null -eq $InputObject) {
            return $null
        }
        ## Check if the input is an array or collection. If so, we also need to convert
        ## those types into hash tables as well. This function will convert all child
        ## objects into hash tables (if applicable)
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @(
                foreach ($object in $InputObject) {
                    ObjectToHashtable -InputObject $object
                }
            )
            ## Return the array but don't enumerate it because the object may be pretty complex
            Write-Output -NoEnumerate $collection
        } elseif ($InputObject -is [psobject]) { 
            ## If the object has properties that need enumeration, cxonvert it to its own hash table and return it
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ObjectToHashtable -InputObject $property.Value
            }
            $hash
        } else {
            ## If the object isn't an array, collection, or other object, it's already a hash table
            ## So just return it.
            $InputObject
        }
    }
}

#
# Suppress warnings
#
Update-AzConfig -DisplayBreakingChangeWarning $false

# Load required modules
$requiredModules = @(
    "Az.Accounts",
    "Az.ConnectedMachine",
    "Az.ResourceGraph"
)
$requiredModules | Foreach-Object {CheckModule $_}

# Subscriptions to scan

if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne $null){
    $subscriptions = [PSCustomObject]@{SubscriptionId = $SubId} | Get-AzSubscription 
}else{
    $subscriptions = Get-AzSubscription
}


Write-Host ([Environment]::NewLine + "-- Scanning subscriptions --")

# Scan arc-enabled servers in each subscription 

foreach ($sub in $subscriptions){

    if ($sub.State -ne "Enabled") {continue}

    try {
        Set-AzContext -SubscriptionId $sub.Id  
    }catch {
        write-host "Invalid subscription: $($sub.Id)"
        {continue}
    }
   
    $query = "
    resources
    | where type =~ 'microsoft.hybridcompute/machines/extensions'
    | extend extensionPublisher = tostring(properties.publisher), extensionType = tostring(properties.type), provisioningState = tostring(properties.provisioningState)
    | where extensionPublisher =~ 'Microsoft.AzureData'
    | where provisioningState =~ 'Succeeded'
    | parse id with * '/providers/Microsoft.HybridCompute/machines/' machineName '/extensions/' *
    | project machineName, extensionName = name, resourceGroup, location, subscriptionId, extensionPublisher, extensionType, properties
    "
    
    if ($MachineName) {$query += "| where machineName =~ '$($MachineName)'"}     
    if ($ResourceGroup) {$query += "| where resourceGroup =~ '$($ResourceGroup)'"}

    $resources = Search-AzGraph -Query "$($query) | where subscriptionId =~ '$($sub.Id)'"
    foreach ($r in $resources) {

        $setID = @{
            MachineName = $r.MachineName        
            Name = $r.extensionName        
            ResourceGroup = $r.resourceGroup        
            Location = $r.location        
            SubscriptionId = $r.subscriptionId
            Publisher = $r.extensionPublisher
            ExtensionType = $r.extensionType    
        }

        $settings = @{}
        $settings = $r.properties.settings | ConvertTo-Json | ConvertFrom-Json | ObjectToHashtable
        
        if ($settings.ContainsKey("LicenseType")) {
            if ($All) {
                if ($settings["LicenseType"] -ne $LicenseType ) {
                    $settings["LicenseType"] = $LicenseType 
                    Write-Host "Resource group: [$($r.resourceGroup)] Connected machine: [$($r.MachineName)] : License type: [$($settings["LicenseType"])]"
                    Set-AzConnectedMachineExtension @setId -Settings $settings -NoWait   
                }
            }        
        } else {
            $settings["LicenseType"] = $LicenseType   
            Write-Host "Resource group: [$($r.resourceGroup)] Connected machine: [$($r.MachineName)] : License type: [$($settings["LicenseType"])]"
            Set-AzConnectedMachineExtension @setId -Settings $settings 
        }
    } 
}
    
    