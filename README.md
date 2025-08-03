# InternalDNSChecker

Internal DNS Health & Event Report
A PowerShell script that automates DNS resolution checks and DNS Server event-log reviews across your Active Directory domain. It outputs both an HTML and a Markdown report summarizing:
- IPv4 and IPv6 resolution results for your root domain, common hostnames, and all domain controllers
- Errors and warnings from the DNS Server event log over the past 24 hours

Prerequisites
- Windows PowerShell 5.1 or later
- ActiveDirectory module installed
- Appropriate credentials to query AD domain information and read remote event logs

Installation
- Clone or download this repository to a Windows server or workstation with the AD RSAT tools installed.
- Open an elevated PowerShell console.
- Ensure the script file (e.g., DNS_Report.ps1) resides under a folder where you have write permissions for output (default: C:\temp).


- By default, the script writes two files:
- C:\temp\DNS_Report.html
- C:\temp\DNS_Report.md
- It then launches the HTML report in your default browser.


Output
DNS Resolution Check
Lists each target name (root domain, mail, www, and DC FQDNs) with their resolved IPv4 and IPv6 addresses, or a failure message.
DNS Event Log Check
Iterates through each domain controller by NetBIOS name and retrieves DNS Server errors/warnings from the last 24 hours.
- Displays an “All Clear” message if no events are found
- Shows detailed event entries otherwise

Customization
- Fallback Domain: Change the yourinternaldomain.com default in the discovery block.
- Domain Controller Filter: Modify the Get-ADDomainController filter or switch back to Get-ADComputer if needed.
- Output Paths: Update $htmlFilePath and $markdownFilePath at the top of the script.


Troubleshooting
- Empty Event-Log Section:
- Verify that your account can read the DNS Server log remotely.
- Ensure domain controllers are correctly discovered (check $dcs output).
- ADPropertyValueCollection Errors:
- Make sure you’re using Get-ADDomainController or explicitly expanding the Name property and casting to string.

License
This project is licensed under the MIT License.
Feel free to fork, modify, and contribute back enhancements!
