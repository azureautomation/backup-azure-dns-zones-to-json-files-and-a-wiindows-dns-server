<#
.SYNOPSIS
This script is intended to back up Azure DNS which as of December 2018 doesn't have a backup facility.
It saves the Azure DNS recordsets to json files, and replicates them to a Windows DNS server.
The Windows DNS server provides an easy, gui way of checking that a backup exists, and its .dns 
files can be uploaded to Azure DNS to provide an easy way to restore a zone.

.DESCRIPTION
This script does the actions below:
- Queries an array of subscription names for their DNS zones
- Uses the Get-AzureRmDnsRecordSet cmdlet to get the recordsets from the zones
- Uses the ConvertTo-Json cmdlet to write the recordsets to json files
- Removes any json files older than x days (default is 100 days)
- If any DNS zone is found in Azure DNS which doesn't exist in Windows DNS, creates it
- Uses the Compare-Object cmdlet to compare each zone in Azure DNS and Windows DNS and adds or deletes records in Windows DNS to keep it in line with Azure DNS
- Sends an email and writes to the Windows event log

Supports WhatIf.

Limitations:
- The Windows DNS part only supports these record types: A, CNAME, MX, NS, PTR, SRV, TXT.
- The script stops with an error if someone has accidentally created child domains within a zone with the same name as the zone. So a domain 'mydomain.com' might contain a child domain 'com', which contains a child domain 'mydomain'. I think it's an easy mistake to make and you can do it by creating a record called 'myname.mydomain.com' (should be just 'myname') in a domain 'mydomain.con'. It makes the Get-DnsServerResourceRecord cmdlet do silly things, better to stop.
- Only works with a single tenant because it uses a single service principal/Azure AD application to authenticate to Azure
- Requires the AzureRM module, not the new az module.

.PARAMETER Subscriptions
An array of subscription names

.PARAMETER DnsServer
The Windows DNS server to write Azure DNS zones to

.PARAMETER DnsBackupFileMaximumAge
The number of days to keep export files from the Azure DNS zones, default is 100

.PARAMETER DnsBackupFolder
The path the write the Azure DNS recordsets to, as json files

.EXAMPLE
C:\scripts\Backup-AzureDns.ps1 -Subscriptions @('mySubscription1', 'mySubscription2') -DnsServer myDnsServer -DnsBackupFileMaximumAge 100 -DnsBackupFolder \\myServer\myShare
#>
[CmdLetBinding(SupportsShouldProcess=$True)]
Param(
    [Parameter(Mandatory=$true)]
    [string[]]$Subscriptions        # array of subscription names
    ,
    [Parameter(Mandatory=$true)]
    [string]$DnsServer              # the Windows DNS server to write Azure DNS zones to
    ,
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,1000)]
    [int]$DnsBackupFileMaximumAge = 100     # the number of days to keep export files from the Azure DNS zones
    ,
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_})]
    [string]$DnsBackupFolder      # the path the write the Azure DNS recordsets to, as json files
) 

Set-StrictMode -version Latest
$ErrorActionPreference = 'Stop'

# THESE VARIABLES MUST BE CHANGED
# TenantId, ApplicationId and CertificateThumbprint required to run as a scheduled task in Windows, set up as per https://github.com/Azure/azure-docs-powershell-azuread/blob/master/docs-conceptual/azureadps-2.0-preview/signing-in-service-principal.md
$TenantId = '11111111-2222-3333-4444-555555555555'
$ApplicationId = '66666666-7777-7777-7777-aaaaaaaaaaaa'
$CertificateThumbprint = '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'
$SuccessEmailRecipients = @('firstname.lastname@mydomain.com', 'aaa.bbb@mydomain.com')   # set to $null to disable sending an email after running successfully
$ErrorEmailRecipients = @('firstname.lastname@mydomain.com', 'aaa.bbb@mydomain.com')     # set to $null to disable sending an email after an error
$EmailRelay = 'myrelay.mydomain.com'
$EmailFrom = 'donotereply@mydomain.com'

# THESE VARIABLES DON'T HAVE TO BE CHANGED
$DnsBackupFilePrefix = 'AzureDnsBackup'                 # first part of the json file name which Azure recordsets are exported to
$AppEventLogSource = 'PowerShell-Script'
$EventLogPrefix = "Script $PSCommandPath`: "
$EmailSubjectSuffix = "script $PSCommandPath on $($env:computername)"
$EmailBody = "Script $PSCommandPath running on $($env:computername) started at $(Get-Date -Format 'HH:mm:ss').`r`n`r`n"
$TotalZonesProcessed = 0
$TotalDnsRecordsAdded = 0
$TotalDnsRecordsRemoved = 0



# Function to add a record to Windows DNS. Its input is a generic DNS record object created by function ConvertTo-GenericDnsObjects
# The function relies on the fact that the parameter names for Add-DnsServerResourceRecord are the same as the property names
# of the RecordData property of $GenericDnsObject which themselves come from the objects that Get-DnsServerResourceRecord returns.
function Add-WindowsDnsRecord {
	[CmdLetBinding(SupportsShouldProcess=$True)]
    Param(
        [Parameter(Mandatory=$true)]
        [AllowNull()]
        [PSCustomObject[]]$GenericDnsObjects
        ,
        [Parameter(Mandatory=$true)]
        [string]$DnsServer
        ,
        [Parameter(Mandatory=$true)]
        [string]$Zone
    )

    Set-StrictMode -version Latest
    $ErrorActionPreference = 'Stop'
    
    foreach ($GenericDnsObject in $GenericDnsObjects) {
        # Hash table to contain the parameters for the new DNS record
        $NewDnsRecordCmdletParameters = @{}
        $NewDnsRecordCmdletParameters.Add('Name', $GenericDnsObject.HostName)
        $NewDnsRecordCmdletParameters.Add('TimeToLive', $GenericDnsObject.TimeToLive)
        $NewDnsRecordCmdletParameters.Add($GenericDnsObject.RecordType, $true)
        foreach ($PropertyName in $GenericDnsObject.RecordData.psobject.properties.Name) {
            if ($PropertyName -ne 'PSComputerName') {
                $NewDnsRecordCmdletParameters.Add($PropertyName, $GenericDnsObject.RecordData.$PropertyName)
            }
        }

        if ($pscmdlet.ShouldProcess("$DnsServer", "adding the DNS record with name $($GenericDnsObject.HostName) to zone $Zone")) {
            Add-DnsServerResourceRecord -ZoneName $Zone -ComputerName $DnsServer @NewDnsRecordCmdletParameters
        }
    }
}


# Function to remove a single record from Windows DNS. Its input is a generic DNS record object created by function ConvertTo-GenericDnsObjects
# Because there can be multiple DNS records with the same name (round robin) it has to test the property values
function Remove-WindowsDnsRecord {
	[CmdLetBinding(SupportsShouldProcess=$True)]
    Param(
        [Parameter(Mandatory=$true)]
        [AllowNull()]
        [PSCustomObject[]]$GenericDnsObjects
        ,
        [Parameter(Mandatory=$true)]
        [string]$DnsServer
        ,
        [Parameter(Mandatory=$true)]
        [string]$Zone
    )

    Set-StrictMode -version Latest
	$ErrorActionPreference = 'Stop'

    foreach ($GenericDnsObject in $GenericDnsObjects) {
        if ($GenericDnsObject.HostName -eq '@') {
            $DnsRecordsWithSameName = Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $Zone -Node
        } else {
            $DnsRecordsWithSameName = Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $Zone -Name $GenericDnsObject.HostName
        }
        $DnsRecordToDelete = $null

        if (@($DnsRecordsWithSameName).Count -eq 1) {
            # 1 DNS record was returned, we know it's the one to delete
            $DnsRecordToDelete = $DnsRecordsWithSameName 
        } else {
            # multiple DNS records were returned, compare property values to find the one to delete
            foreach ($DnsRecord in $DnsRecordsWithSameName) {
                if ($DnsRecord.RecordType -eq $GenericDnsObject.RecordType `
                -and $DnsRecord.TimeToLive -eq $GenericDnsObject.TimeToLive `
                -and (!(Compare-Object -ReferenceObject $GenericDnsObject.RecordData -DifferenceObject $DnsRecord.RecordData -Property $GenericDnsObject.RecordData.psobject.properties.Name))) {
                    $DnsRecordToDelete = $DnsRecord
                    break
                }
            }
        }
                    
        if ($DnsRecordToDelete) {
            if ($pscmdlet.ShouldProcess("$DnsServer", "deleting the DNS record with name $($DnsRecordToDelete.HostName) in zone $Zone")) {
                $DnsRecordToDelete | Remove-DnsServerResourceRecord -ZoneName $Zone -ComputerName $DnsServer -Force
            }
        } else {
            Write-Error -Message "No DNS record was found in zone $Zone on DNS server $DnsServer which matched all the attributes of the generic DNS object(s) for $($GenericDnsObject.HostName)." -ErrorAction Stop
        }
    }
}



function ConvertTo-PSCustomObjectAsString {
	[cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$obj
    )

    Set-StrictMode -version Latest
	$ErrorActionPreference = 'Stop'

    $OutputString = '@{'

    foreach ($Property in ($obj.psobject.properties | Sort-Object Name)) {
        $OutputString += "'$($Property.Name)' = '$($Property.Value)'; "
    }

    $OutputString += '}'

    return $OutputString
}



# Function to convert objects from Azure DNS (created by Get-AzureRmDnsRecordSet) or from  Windows DNS (created by 
# Get-DnsServerResourceRecord to a common generic format. This is so they can be compared with Compare-Object to look for changes.
function ConvertTo-GenericDnsObjects {
	[cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName='AzureDnsRecordSets')]
        [PSCustomObject[]]$AzureDnsRecordSets
        ,
        [Parameter(Mandatory=$true, ParameterSetName='WindowsDnsRecords')]
        [PSCustomObject[]]$WindowsDnsRecords
    )

    Set-StrictMode -version Latest
	$ErrorActionPreference = 'Stop'

    # Create a class reformatted DNS records, and a list for more efficient adding than arrays
    Class GenericDns {
        [string]$HostName
        [string]$RecordType
        [TimeSpan]$TimeToLive
        [PSCustomObject]$RecordData
        [string]$RecordDataAsString
    }

    $GenericDnsRecords = New-Object System.Collections.Generic.List[GenericDns]

	switch ($PsCmdlet.ParameterSetName) {
		'AzureDnsRecordSets' {
            foreach ($AzureDnsRecordSet in $AzureDnsRecordSets) {
                foreach ($Record in $AzureDnsRecordSet.Records) {
                    if ($AzureDnsRecordSet.RecordType -ne 'SOA' -and !($AzureDnsRecordSet.Name -eq '@' -and $AzureDnsRecordSet.RecordType -eq 'NS')) {
                        $GenericDnsRecord = New-Object -TypeName GenericDns
                        $GenericDnsRecord.HostName = $AzureDnsRecordSet.Name
                        $GenericDnsRecord.RecordType = $AzureDnsRecordSet.RecordType
                        $GenericDnsRecord.TimeToLive = New-TimeSpan -Seconds $AzureDnsRecordSet.Ttl

                        switch ($AzureDnsRecordSet.RecordType) {
                            'A' {
                                $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                    'IPv4Address' = $Record.IPv4Address;
                                    'PSComputerName' = $null
                                }
                            }
                            'CNAME' {
                                $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                    'HostNameAlias' = "$($Record.Cname.TrimEnd('.')).";
                                    'PSComputerName' = $null
                                }
                            }
                            'MX' {
                                $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                    'MailExchange' = "$($Record.Exchange.TrimEnd('.'))."; 
                                    'Preference' = $Record.Preference;
                                    'PSComputerName' = $null
                                }
                            }
                            'NS' {
                                $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                    'NameServer' = "$($Record.Nsdname.TrimEnd('.')).";
                                    'PSComputerName' = $null
                                }
                            }
                            'PTR' {
                                $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                    'PtrDomainName' = "$($Record.Ptrdname.TrimEnd('.')).";
                                    'PSComputerName' = $null
                                }
                            }
                            'SRV' {
                                $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                    'DomainName' = "$($Record.Target.TrimEnd('.'))."; 
                                    'Port' = $Record.Port;
                                    'Priority' = $Record.Priority;
                                    'Weight' = $Record.Weight;
                                    'PSComputerName' = $null
                                }
                            }
                            'TXT' {
                                $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                    'DescriptiveText' = $Record.Value; 
                                    'PSComputerName' = $null
                                }
                            }
                            default {
                                Write-Error -Message "Unsupported record type $($AzureDnsRecordSet.RecordType). This script ignores SOA records and NS records for zone, and can only process record types A, CNAME, MX, NS, PTR, SRV, TXT." -ErrorAction Stop
                            }
                        }
                        $GenericDnsRecord.RecordDataAsString = ConvertTo-PSCustomObjectAsString -obj $GenericDnsRecord.RecordData
                        $GenericDnsRecords.Add($GenericDnsRecord)
                    }
                }
            }
        }
        'WindowsDnsRecords' {
            foreach ($WindowsDnsRecord in $WindowsDnsRecords) {
                if ($WindowsDnsRecord.RecordType -ne 'SOA' -and !($WindowsDnsRecord.HostName -eq '@' -and $WindowsDnsRecord.RecordType -eq 'NS')) {
                    $GenericDnsRecord = New-Object -TypeName GenericDns
                    $GenericDnsRecord.HostName = $WindowsDnsRecord.HostName
                    $GenericDnsRecord.RecordType = $WindowsDnsRecord.RecordType
                    $GenericDnsRecord.TimeToLive = $WindowsDnsRecord.TimeToLive

                    switch ($WindowsDnsRecord.RecordType) {
                        'A' {
                            $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                'IPv4Address' = $WindowsDnsRecord.RecordData.IPv4Address;
                                'PSComputerName' = $null
                            }
                        }
                        'CNAME' {
                            $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                'HostNameAlias' = $WindowsDnsRecord.RecordData.HostNameAlias;
                                'PSComputerName' = $null
                            }
                        }
                        'MX' {
                            $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                'MailExchange' = $WindowsDnsRecord.RecordData.MailExchange; 
                                'Preference' = $WindowsDnsRecord.RecordData.Preference;
                                'PSComputerName' = $null
                            }
                        }
                        'NS' {
                            $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                'NameServer' = $WindowsDnsRecord.RecordData.NameServer;
                                'PSComputerName' = $null
                            }
                        }
                        'PTR' {
                            $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                'PtrDomainName' = $WindowsDnsRecord.RecordData.PtrDomainName;
                                'PSComputerName' = $null
                            }
                        }
                        'SRV' {
                            $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                'DomainName' = $WindowsDnsRecord.RecordData.DomainName; 
                                'Port' = $WindowsDnsRecord.RecordData.Port;
                                'Priority' = $WindowsDnsRecord.RecordData.Priority;
                                'Weight' = $WindowsDnsRecord.RecordData.Weight;
                                'PSComputerName' = $null
                            }
                        }
                        'TXT' {
                            $GenericDnsRecord.RecordData = [PSCustomObject]@{
                                'DescriptiveText' = $WindowsDnsRecord.RecordData.DescriptiveText; 
                                'PSComputerName' = $null
                            }
                        }
                        default {
                            Write-Error -Message "Unsupported record type $($WindowsDnsRecord.RecordType). This script ignores SOA records and NS records for zone, and can only process record types A, CNAME, MX, NS, PTR, SRV, TXT." -ErrorAction Stop
                        }
                    }
                    $GenericDnsRecord.RecordDataAsString = ConvertTo-PSCustomObjectAsString -obj $GenericDnsRecord.RecordData
                    $GenericDnsRecords.Add($GenericDnsRecord)
                }
            }
        }
    }
    return $GenericDnsRecords
}



# Function to write a message to the Application event log, source "PowerShell-Script", event ID 1
# Requires admin rights to create the source, or if a scheduled task, with "Run with highest privileges" ticked.
function Write-AppEventLog {
	Param(
		[Parameter(Mandatory=$true)]
		[string]$MessageText
		,
		[Parameter(Mandatory=$true)]
		[ValidateSet("Information","Warning","Error")] 
		[string]$EventType
	)
	
	$AppEventLogSource = 'PowerShell-Script'

	If(![System.Diagnostics.EventLog]::SourceExists($AppEventLogSource)) {
		try {
			[System.Diagnostics.EventLog]::CreateEventSource($AppEventLogSource, 'Application')
		} catch {
			$ErrorMessage = $_.Exception.Message
			Write-Error "Failed to created the Application event log source $AppEventLogSource, perhaps due to lack of rights. The error message was: $ErrorMessage"
			return
		}
	}
    Write-EventLog -LogName 'Application' -Source $AppEventLogSource -EventId 1 -EntryType $EventType -Message $MessageText
}


# ---------------------------------------------------------- MAIN CODE ------------------------------------------------------

Write-AppEventLog -EventType Information -MessageText "$EventLogPrefix`r`n`r`nScript started. These subscriptions will be processed: $(@($Subscriptions) -join ', ')"

# Run as a scheduled task in Windows, set up as per https://github.com/Azure/azure-docs-powershell-azuread/blob/master/docs-conceptual/azureadps-2.0-preview/signing-in-service-principal.md
Connect-AzureRmAccount -TenantId $TenantId -ApplicationId $ApplicationId -CertificateThumbprint $CertificateThumbprint -WhatIf:$false

try {
    foreach ($Subscription in $Subscriptions) {
        Write-Verbose -Message "Processing the $Subscription subscription"
        $ZoneEventLogText = "$Subscription subscription`r`n`r`n" 
            
        Select-AzureRmSubscription -Subscription $Subscription -WhatIf:$false
        $ZonesThisSubscription = Get-AzureRmResource -ODataQuery "`$filter=resourcetype eq 'Microsoft.Network/dnszones'" | Sort-Object Name

        if (!$ZonesThisSubscription) {
            $ZoneEventLogText += "No DNS zones were found in the $Subscription subscription`r`n`r`n"
            Write-AppEventLog -EventType Information -MessageText "$EventLogPrefix`r`n`r`n$ZoneEventLogText"
            $EmailBody += "$ZoneEventLogText`r`n"
            Write-Verbose -Message $ZoneEventLogText
            $ZoneEventLogText = $null
        } else {
            foreach ($Zone in $ZonesThisSubscription) {
                $ZoneEventLogText += "$($Zone.Name) zone in the $Subscription subscription`r`n`r`n"
                if ($WhatIfPreference) {$ZoneEventLogText += "WhatIf WAS SPECIFIED IN THE PARAMETERS, NO CHANGES WILL BE MADE.`r`n"}
                
                # Get the Azure zone records
                $AzureZoneRecords = Get-AzureRmDnsRecordSet -ZoneName $Zone.Name -ResourceGroupName $Zone.ResourceGroupName

                # Create the folder on $DnsServer, subscription folder then zone name
                $SubscriptionFolderName = $Subscription -replace '[^a-zA-Z0-9- .]', ''      # remove characters like "\" which can't be used in folder names
                if (!(Test-Path -Path $(Join-Path -Path $DnsBackupFolder -ChildPath $SubscriptionFolderName))) {
                    New-Item -ItemType Directory -Path $DnsBackupFolder -Name $SubscriptionFolderName | Out-Null
                }
                $SubscriptionFolderPath = Join-Path -Path $DnsBackupFolder -ChildPath $SubscriptionFolderName
                if (!(Test-Path -Path $(Join-Path -Path $SubscriptionFolderPath -ChildPath $Zone.Name))) {
                    New-Item -ItemType Directory -Path $SubscriptionFolderPath -Name $Zone.Name | Out-Null
                }
                $ZoneFolderPath = Join-Path -Path $SubscriptionFolderPath -ChildPath $Zone.Name

                # Write the Azure zone records to a json file
                $DnsBackupFile = Join-Path -Path $ZoneFolderPath -ChildPath "$DnsBackupFilePrefix-$($Zone.Name)-$(Get-Date -Format 'yyyy.MM.dd-HH.mm.ss').json"
                $AzureZoneRecords  | ConvertTo-Json -depth 100 | Out-File $DnsBackupFile -Force -ErrorAction Stop
                $ZoneEventLogText += "$(@($AzureZoneRecords).Count) DNS recordsets were written to $DnsBackupFile.`r`n"

                # Remove json files older than $DnsBackupFileMaximumAge days
                if (Test-Path -Path $ZoneFolderPath) {  # the folder might not exist if using WhatIf
                    $DnsBackupFilesToDelete = Get-ChildItem -File -Path $ZoneFolderPath -Filter "$DnsBackupFilePrefix*.*" | Where-Object {$_.CreationTime -lt (Get-Date).AddDays(-$DnsBackupFileMaximumAge)}
                    $DnsBackupFilesToDelete | Remove-Item
                    $ZoneEventLogText += "$(@($DnsBackupFilesToDelete).Count) files older than $DnsBackupFileMaximumAge days were deleted.`r`n"
                    if (@($DnsBackupFilesToDelete).Count -gt 0 -and @($DnsBackupFilesToDelete).Count -le 10) {
                        $ZoneEventLogText += "The deleted files were $(@($DnsBackupFilesToDelete) -join ', ')`r`n"
                    }
                } else {
                    $ZoneEventLogText += "0 files older than $DnsBackupFileMaximumAge days were deleted.`r`n"
                }

                # If the zone doesn't exist in the Windows DNS server, create it 
                $WindowsDnsZones = Get-DnsServerZone -ComputerName $DnsServer
                if ($Zone.Name -notIn $WindowsDnsZones.ZoneName) {
                    Add-DnsServerPrimaryZone -Name $Zone.Name -ComputerName $DnsServer -ZoneFile "$($Zone.Name).dns" -WhatIf:$WhatIfPreference # Add-DnsServerPrimaryZone seems to need WhatIf setting explicitly
                    $ZoneEventLogText += "The zone $($Zone.Name) was not found on $DnsServer, it was created.`r`n"
                    $WindowsDnsZones = Get-DnsServerZone -ComputerName $DnsServer
                }

                # Reformat the objects from Get-AzureRmDnsRecordSet (ie Azure DNS) so they have the same property names as the objects from Get-DnsServerResourceRecord (Windows DNS)
                $AzureZoneRecordsReformatted = ConvertTo-GenericDnsObjects -AzureDnsRecordSets $AzureZoneRecords

                # Get the Windows DNS zone records, zone might not exist if using WhatIf only, no other reason
                if ($WindowsDnsZones.ZoneName -contains $Zone.Name) {
                    $WindowsZoneRecords = Get-DnsServerResourceRecord -ZoneName $Zone.Name -ComputerName $DnsServer

                    # If the HostName property of any Windows DNS records in this zone end with the domain name (so their FQDN is myhost1.mydomain.com.mydomain.com)
                    # terminate with an error. This is because this confuses the Get-DnsServerResourceRecord cmdlet (as of Dec 2018), it returns twice the number of objects
                    if ($WindowsZoneRecords | Where-Object {$_.HostName -match ".$($Zone.Name).?$"}) {
                        Write-Error -Message "the zone $($Zone.Name) contains a subdomain with the same name, ie where the records names are as myhost1.$($Zone.Name).$($Zone.Name). This is an error, and it confuses the the Get-DnsServerResourceRecord cmdlet (as of Dec 2018). The zone $($Zone.Name) has been written to a file but no changes made in Windows DNS, and no further zones have been processed. Remove this subdomain from Azure and Windows DNS then rerun." -ErrorAction Stop
                    }

                    # Reformat the Windows DNS records for comparison with the Azure records, by adding a property RecordDataAsString
                    $WindowsZoneRecordsReformatted = ConvertTo-GenericDnsObjects -WindowsDnsRecords $WindowsZoneRecords

                    if ($WindowsZoneRecordsReformatted -and $AzureZoneRecordsReformatted) {
                        # Get the differences between the generic versions of the Azure and Windows DNS records
                        $Differences = Compare-Object -ReferenceObject $WindowsZoneRecordsReformatted -DifferenceObject $AzureZoneRecordsReformatted -Property @('HostName', 'RecordType', 'TimeToLive', 'RecordDataAsString', 'RecordData') -PassThru
                        $DeletedOrIncorrectDnsRecords = $Differences | Where-Object {$_.SideIndicator -eq '<='}
                        $NewOrUpdatedDnsRecords = $Differences | Where-Object {$_.SideIndicator -eq '=>'}
                    } else {
                        # either the DNS zone in Windows is empty, or the zone in Azure is. If the Windows zone is empty, add all the 
                        # records from Azure. If the Azure zone is empty, delete all the records in the Windows zone.
                        $DeletedOrIncorrectDnsRecords = $WindowsZoneRecordsReformatted
                        $NewOrUpdatedDnsRecords = $AzureZoneRecordsReformatted
                    }
    
                    # Delete the records in Windows DNS which have either been deleted or changed in Azure
                    Remove-WindowsDnsRecord -GenericDnsObject $DeletedOrIncorrectDnsRecords -DnsServer $DnsServer -Zone $Zone.Name -WhatIf:$WhatIfPreference
                    $ZoneEventLogText += "$(@($DeletedOrIncorrectDnsRecords).Count) records were removed from the zone.`r`n"
                    if (@($DeletedOrIncorrectDnsRecords).Count -gt 0 -and @($DeletedOrIncorrectDnsRecords).Count -le 10) {
                        $ZoneEventLogText += "The records removed were for these names: $(@($DeletedOrIncorrectDnsRecords).HostName -join ', ')`r`n"
                    }
                    $TotalDnsRecordsRemoved += @($DeletedOrIncorrectDnsRecords).Count

                    # Add the records to Windows DNS which have either been created or changed in Azure
                    Add-WindowsDnsRecord -GenericDnsObject $NewOrUpdatedDnsRecords -DnsServer $DnsServer -Zone $Zone.Name -WhatIf:$WhatIfPreference
                    $ZoneEventLogText += "$(@($NewOrUpdatedDnsRecords).Count) records were added to the zone.`r`n"
                    if (@($NewOrUpdatedDnsRecords).Count -gt 0 -and @($NewOrUpdatedDnsRecords).Count -le 10) {
                        $ZoneEventLogText += "The records added were for these names: $(@($NewOrUpdatedDnsRecords).HostName -join ', ')`r`n"
                    }
                    $TotalDnsRecordsAdded += @($NewOrUpdatedDnsRecords).Count
                } else {    
                    # Zone doesn't exist, we must be using WhatIf. $NewOrUpdatedDnsRecords isn't set, use $AzureZoneRecordsReformatted
                    $ZoneEventLogText += "$(@($AzureZoneRecordsReformatted).Count) records were added to the zone.`r`n"
                    if (@($AzureZoneRecordsReformatted).Count -gt 0 -and @($AzureZoneRecordsReformatted).Count -le 10) {
                        $ZoneEventLogText += "The records added were for these names: $(@($AzureZoneRecordsReformatted).HostName -join ', ')`r`n"
                    }
                    $TotalDnsRecordsAdded += @($AzureZoneRecordsReformatted).Count      # no change to $TotalDnsRecordsRemoved
                }

                Write-AppEventLog -EventType Information -MessageText "$EventLogPrefix`r`n`r`n$ZoneEventLogText"
                Write-Verbose "$ZoneEventLogText`r`n"
                $EmailBody += "$ZoneEventLogText`r`n"
                $ZoneEventLogText = $null   # this helps to tidy up the text that's written to the event log when the try catch runs

                $TotalZonesProcessed ++
            }
        }
    }
    $FinalEventText = "Script finished. $TotalDnsRecordsAdded DNS records added, $TotalDnsRecordsRemoved removed in $TotalZonesProcessed zones."
    Write-AppEventLog -EventType Information -MessageText "$EventLogPrefix`r`n`r`n$FinalEventText"
    if ($SuccessEmailRecipients) {
        Send-MailMessage -From $EmailFrom -To $SuccessEmailRecipients -Subject "$TotalDnsRecordsAdded DNS records added, $TotalDnsRecordsRemoved removed in $TotalZonesProcessed zones in $EmailSubjectSuffix" -Body "$EmailBody`r`n$FinalEventText" -SmtpServer $EmailRelay
    }
} catch {
    $ZoneEventLogText += "ERROR $($_.Exception.Message)"

    Write-AppEventLog -EventType Error -MessageText "$EventLogPrefix`r`n`r`n$ZoneEventLogText"
    if ($ErrorEmailRecipients) {
        Send-MailMessage -From $EmailFrom -To $ErrorEmailRecipients -Subject "ERROR OCCURRED IN $EmailSubjectSuffix" -Body "$EmailBody`r`n$ZoneEventLogText" -SmtpServer $EmailRelay
    }
    Write-Error -Message $ZoneEventLogText -ErrorAction Stop
}
