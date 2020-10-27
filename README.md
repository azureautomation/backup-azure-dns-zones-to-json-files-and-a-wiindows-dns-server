Backup Azure DNS zones to json files and a Wiindows DNS server
==============================================================

            

What the script does is simple in principle. It queries an array of Azure subscriptions for their DNS zones. For each zone it:




  *  Writes it to a json file 
  *  Deletes any json files older than x days 
  *  If it doesn't exist in the Windows DNS server, creates it 
  *  Compares the DNS records in the zone on the Windows DNS server with the DNS recordsets in the Azure zone, and writes the changes to the Windows DNS server

  *  Writes to the Application event log (I intended it to be run as a scheduled task)

  *  Optionally sends emails every time, and/or on encountering an error 





It supports -WhatIf and -Verbose, without these it writes hardly anything to the screen and the event log records should be used to see what it did. I recommend running it interactively with -WhatIf and -Verbose first. Note
 that with WhatIf it still tries to create the event log source and write to the event log. I think this helps to understand what changes it would have made.




It's possible to argue that the approach I took wasn't the best. The Azure CLI has a facility to export a DNS zone, so this might be a better method of backing up Azure DNS. I didn't choose it because I like receiving an email
 every time a record changes in Azure DNS, confirming that the same change has been made in Windows DNS. This reassures me that the zone files I have in Windows DNS are valid (I mean because Windows DNS is maintaining them) and are in line with Azure DNS. I
 can go into the Windows DNS mmc whenever I like to check, and the <zone name>.dns file in Windows DNS can be imported into Azure using the CLI if I need to restore the whole zone.


**Requirements:** 


  *  A Windows server running DNS. I recommend standalone DNS, not AD-integrated, so that the <zone name>.dns files are available for restoring a zone

  *  A path where the json files are to be written, either a file share or a folder on the computer where the script runs

  *  If the email facility in the script is required, the computer where the script runs should be allowed to use an email relay

  *  A registered app/service principal in Azure AD with the Reader permission on the DNS zones. I followed the steps in [https://github.com/Azure/azure-docs-powershell-azuread/blob/master/docs-conceptual/azureadps-2.0-preview/signing-in-service-principal.md](https://github.com/Azure/azure-docs-powershell-azuread/blob/master/docs-conceptual/azureadps-2.0-preview/signing-in-service-principal.md).
 Note that as of writing this there's a small omission, there's a variable $notAfter which hasn't been assigned a value. I suggest a line like '$notAfter = (Get-Date).AddYears(10)' before running the other lines, where 10 is the number of years before
 the cert expires 
  *  The script creates an Event Log source so it must be run at least once with admin rights (or the source could be created manually beforehand). Apart from that it just needs permissions in the json file path and Windows DNS.

  *  I used poweshell V5, not tested with earlier versions 
  *  The Azure modules  AzureRm and  AzureAD 


**Instructions:** 


  *  On the computer where the script will run, start powershell and type: 'Install-Module -Name AzureRm' and 'Install-Module -Name AzureAD'

  *  Create a file share or folder where the json files will be written to. I used a folder on the DNS server, and also ran the scheduled task on the DNS server so that I could use the built-in SYSTEM account to run the scheduled task

  *  Create the registered app/service principal in Azure AD using the link above, give it the Reader permissions for the Azure DNS zones BUT NO MORE

  *  Edit the lines in the script containing the variables which are specific to an installation, between lines 65 and 71. These are the Azure service principal, email recipients etc.

  *  Create a scheduled task with these properties:
Run As: SYSTEM, tick 'Run with highest privileges'
Trigger: On a schedule, Weekly, tick Mon-Fri, set the time
Action: Start a program, powershell.exe. Arguments: '& <path for Backup-AzureDns.ps1> -Subscriptions @('mySub', 'mySub2') -DnsServer myDnsServer1 -DnsBackupFolder <path to backup folder>'
(including the double quotes in the Action part)
Stop the task if longer than: I suggest 1 or 2 hours 
Comments, limitations:




If a recordset in Azure DNS is changed, for example to change the TTL, the script records this as a deletion and addition of the same name


When run with -WhatIf the script still tries to create the Event log source if it doesn't exist, and writes to the Application event log. I don't think WhatIf is useful without the event log records.

The Windows DNS part only supports these record types: A, CNAME, MX, NS, PTR, SRV, TXT. These are the ones that are options in the portal except for AAAA records. 

The script stops with an error if someone has accidentally created child domains within a zone with the same name as the zone. So a domain '[mydomain.com](http://mydomain.com/)' might contain a child domain 'com',
 which contains a child domain 'mydomain'. I think it's an easy mistake to make, you can do it by creating a record called '[myname.mydomain.com](http://myname.mydomain.com/)' (should be just 'myname') in a domain
 'mydomain.con'. This situation makes the Get-DnsServerResourceRecord cmdlet do silly things, better to stop.

The script queries an array of subscription names, so it's possible that the a zone with the same name exists in multiple subscriptions. In this case the json files will be valid because they're created in a folder underneath the subscription name, but of course
 the Windows DNS server can't handle multiple zones with the same name and the script will try to merge them, useless

Only works with a single tenant because it uses a single service principal/Azure AD application to authenticate to Azure

Requires the AzureRM module, not the new az module. 
Restrict the permissions on the folder where you put the script, because it contains information to authenticate to Azure (combined with the cert).

Since writing this script I've started using Azure Hybrid Runbook Workers, which remove the need to have credentials in scripts. They also move the script and schedule to the Azure automation account, and give the option of redundancy for the VM it runs
 on. I really like them! 




**Restore a DNS zone**

These are the steps I follow to upload a <zonename>.dns file to Azure:




  *  Copy the C:\windows\system32\dns\<zonename>.dns file for the domain to migrate from the Windows DNS server to a local drive or similar.

  *  Edit the .dns file, removing the NS record for the Windows DNS server. It will look like '@   NS   [myDnsServer.mydomain.com](http://mydnsserver.mydomain.com/)',
 it's close to the top of the file, beneath the header and the SOA record. I haven't checked if uploading is possible with this left in, maybe. It's not wanted in the Azure zone.

  *  If necessary, create the zone in Azure. Note that the name servers will probably be different to the original ones, and the name servers in the DNS registrar will need to be updated.

  *  Import the .dns file into Azure DNS. This isn't supported in powershell but is in the CLI, the commands are:
az login
az account set --subscription <subscription name>
az network dns zone import -g <resource group name> -n [<](http://jato.biz/)zone name> -f c:\myDnsFiles\[<](http://jato.biz/)zone
 name>.dns 
The snippet below shows how the Azure DNS recordsets are converted to generic objects so that they can be compared with the objects from Windows
 DNS. Apart from this bit the script is pretty simple.

 

 




 


 





Short desc:

Queries Azure subscriptions for their DNS zones, and writes them to json files and to a Windows DNS server. The Windows DNS server provides an easy, gui way of checking that a replica exists, and also a quick
 method for restoring a zone - by importing the <zone name>.dns file into Azure with the CLI (.dns files are only on standalone Windows DNS server, not AD-integrated).



Main text:

What the script does is simple in principle. It queries an array of Azure subscriptions for their DNS zones. For each zone it:

- writes it to a json file

- deletes any json files older than x days

- if it doesn't exist in the Windows DNS server, creates it

- compares the DNS records in the zone on the Windows DNS server with the DNS recordsets in the Azure zone, and writes the changes to the Windows DNS server

- writes to the event log (I intended it to be run as a scheduled task)

- optionally sends emails every time, and/or on encountering an error



It supports -WhatIf in which case it writes to the screen, but when used without -WhatIf it writes hardly anything to the screen and the event log records should be used to see what it did. I suggest running it interactively with -WhatIf first.



It's possible to argue that the approach I took wasn't the best. The Azure CLI has a facility to export a DNS zone, so this might be a better method of backing up Azure DNS. I didn't choose it because I like receiving an email every time a record changes in
 Azure DNS, confirming that the same change has been made in Windows DNS. This reassures me that the zone files I have are valid (I mean because Windows DNS is maintaining them) and are in line with Azure DNS. I can go into the Windows DNS mmc whenever I like
 to check, and the <zone name>.dns file in Windows DNS can be imported into Azure using the CLI if I need to restore the whole zone.



**Requirements:** 

- A Windows server running DNS. I recommend standalone DNS, not AD-integrated, so that the <zone name>.dns files are available for restoring a zone

- A path where the json files are to be written, either a file share or a folder on the computer where the script runs

- If the email facility in the script is required, the computer where the script runs should be allowed to use an email relay

- A registered app/service principal in Azure AD with the Reader permission on the DNS zones. I followed the steps in [https://github.com/Azure/azure-docs-powershell-azuread/blob/master/docs-conceptual/azureadps-2.0-preview/signing-in-service-principal.md](https://github.com/Azure/azure-docs-powershell-azuread/blob/master/docs-conceptual/azureadps-2.0-preview/signing-in-service-principal.md).
 Note that as of writing this there's a small omission, there's a variable $notAfter which hasn't been assigned a value. I suggest a line like '$notAfter = (Get-Date).AddYears(10)' before running the other lines, where 10 is the number of years before
 the cert expires

- if the script is run manually, it requires admin rights on the computer because it creates an Event Log source (or the source could be created manually beforehand). Apart from that it just needs permissions in the json file path and Windows DNS.

- I used poweshell V5, not tested with earlier versions

- The Azure modules  AzureRm and  AzureAD



**Instructions:** 

- On the computer where the script will run, start powershell and type: 'Install-Module -Name AzureRm' and 'Install-Module -Name AzureAD'

- Create a file share or folder where the json files will be written to. I used a folder on the DNS server, and also ran the scheduled task on the DNS server so that I could use the built-in SYSTEM account to run the scheduled task

- Create the registered app/service principal in Azure AD using the link above, give it the Reader permissions for the Azure DNS zones BUT NO MORE

- Edit the lines in the script containing the variables which are specific to an installation, between lines 65 and 71. These are the Azure service principal, email recipients etc.

- Create a scheduled task with these properties:

Run As: SYSTEM, tick 'Run with highest privileges'

Trigger: On a schedule, Weekly, tick Mon-Fri, set the time
Action: Start a program, powershell.exe. Arguments: '& <path for Backup-AzureDns.ps1> -Subscriptions @('mySub', 'mySub2') -DnsServer myDnsServer1 -DnsBackupFolder <path to backup folder>'
(including the double quotes in the Action part)
Stop the task if longer than: I suggest 1 or 2 hours

**Comments, limitations:**

- Even when run with -WhatIf the script still tries to create the Event log source if it doesn't exist, this is the only change it makes. I don't think WhatIf is useful without the event log records.

Limitations:
- The Windows DNS part only supports these record types: A, CNAME, MX, NS, PTR, SRV, TXT. These are the ones that are options in the portal except for AAAA records. 
- The script stops with an error if someone has accidentally created child domains within a zone with the same name as the zone. So a domain '[mydomain.com](http://mydomain.com/)' might contain a child domain
 'com', which contains a child domain 'mydomain'. I think it's an easy mistake to make, you can do it by creating a record called '[myname.mydomain.com](http://myname.mydomain.com/)' (should be just 'myname')
 in a domain 'mydomain.con'. This situation makes the Get-DnsServerResourceRecord cmdlet do silly things, better to stop.
- Only works with a single tenant because it uses a single service principal/Azure AD application to authenticate to Azure
- Requires the AzureRM module, not the new az module.
- Restrict the permissions on the folder where you put the script, because it contains information to authenticate to Azure (combined with the cert). I've read that 
- Since writing this script I've read about Azure Hybrid Runbook Worker, might be a better way to handle authentication and move configuration information from the VM to the Azure automation account




**Restore a DNS zone**

These are the steps I follow to upload a <zonename>.dns file to azure:



1.      Copy
 the <zonename>.dns file for the domain to migrate from the Jato DNS server to a local drive or similar.  

 2.      Edit
 the .dns file, removing the NS record for the Windows DNS server. It will look like '@   NS   [myDnsServer.mydomain.com](http://mydnsserver.mydomain.com/)', it's close to the top of the file,
 beneath the header and the SOA record. I haven't checked if uploading is possible with this left in, maybe. It's not wanted in the Azure zone.

3. Create the zone in the portal, powershell etc.

4.      Import
 the .dns file into Azure DNS. This isn't supported in powershell but is in the CLI, the commands are:

az login
az account set --subscription 'IaaS Live'
az network dns zone import -g rgneurdnsial01 -n jato.biz -f c:\myDnsFiles\jato.biz.dns  

 




        
    
TechNet gallery is retiring! This script was migrated from TechNet script center to GitHub by Microsoft Azure Automation product group. All the Script Center fields like Rating, RatingCount and DownloadCount have been carried over to Github as-is for the migrated scripts only. Note : The Script Center fields will not be applicable for the new repositories created in Github & hence those fields will not show up for new Github repositories.
