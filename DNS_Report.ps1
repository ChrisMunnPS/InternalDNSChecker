#-------------------------------------------------------------------
# Internal DNS Health & Event Report
#-------------------------------------------------------------------

# Set console output encoding to UTF-8 for special characters
chcp 65001 | Out-Null
$OutputEncoding = [System.Text.Encoding]::UTF8

# 1) Import AD module
Import-Module ActiveDirectory

# 2) Define output paths and create folder
$dateString = (Get-Date).ToString("yyMMdd")
$outputDir = "C:\temp"
$htmlFilePath = "$outputDir\DNS_Report_$dateString.html"
$markdownFilePath = "$outputDir\DNS_Report_$dateString.md"

if (!(Test-Path -Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

# 3) Initialize variables for report content
$healthReportContent = ""
$scavengingReportContent = ""
$eventReportContent = ""
$markdownOutput = ""

#-------------------------------------------------------------------
# Section 1: Domain Controller & DNS Server Health
#-------------------------------------------------------------------
$healthReportContent += "<div class='section-header'>Domain Controller & DNS Server Health</div>"
$markdownOutput += "## Domain Controller & DNS Server Health`n"

try {
    $adDomain = Get-ADDomain
    $internalDomain = $adDomain.DNSRootDomain
    $dcs = Get-ADDomainController -Filter *
} catch {
    Write-Warning "Could not auto-discover domain; using fallback"
    $internalDomain = "yourinternaldomain.com"
    $dcs = @()
}

if ($dcs.Count -eq 0) {
    $healthReportContent += "<p class='event-warning'>⚠️ No domain controllers discovered.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered.`n"
}
else {
    foreach ($dc in $dcs) {
        $dcName = $dc.Name
        $healthReportContent += "<h3>DC: $dcName</h3>"
        $markdownOutput += "### DC: $dcName`n"

        try {
            $adComputer = Get-ADComputer -Identity $dcName -Properties dNSHostName, OperatingSystem -ErrorAction Stop
            $dcHostname = $adComputer.dNSHostName
            $os = $adComputer.OperatingSystem
            
            $shortName = $dcHostname.Split('.')[0]

            $dnsResults = Resolve-DnsName -Name $dcHostname -ErrorAction Stop
            $ipv4 = ($dnsResults | Where-Object Type -eq 'A'   ).IPAddress -join ", "
            
            $healthReportContent += @"
<div class='result success'>
    ✅ <strong>$shortName</strong> resolved.<br/>
    <strong>FQDN:</strong> $dcHostname<br/>
    <strong>IPv4:</strong> $ipv4<br/>
    <strong>Operating System:</strong> $os
</div>
"@
            
            $markdownOutput += "* ✅ **$shortName** resolved.`n"
            $markdownOutput += "    - **FQDN:** $dcHostname`n"
            $markdownOutput += "    - **IPv4:** $ipv4`n"
            $markdownOutput += "    - **Operating System:** $os`n"
        }
        catch {
            $msg = $_.Exception.Message
            $healthReportContent += @"
<div class='result failure'>
    ❌ Could not retrieve details or resolve host for <strong>$dcName</strong>.<br/>
    $msg
</div>
"@
            $markdownOutput += "* ❌ Could not retrieve details or resolve host for **$dcName**. $msg`n"
        }
    }
}

# 1.3) Mail Server Check
$healthReportContent += "<div class='section-header'>Mail Server Check</div>"
$markdownOutput += "`n## Mail Server Check`n"
try {
    $mailHost = "mail.$internalDomain"
    $mailARecord = Resolve-DnsName -Name $mailHost -Type A -ErrorAction Stop
    $mailIP = $mailARecord.IPAddress -join ", "

    $healthReportContent += @"
<div class='result success'>
    ✅ <strong>$mailHost</strong> resolved.<br/>
    <strong>IP Address:</strong> $mailIP
</div>
"@
    $markdownOutput += "* ✅ **$mailHost** resolved.`n"
    $markdownOutput += "    - **IP Address:** $mailIP`n"
}
catch {
    try {
        $mxRecords = Resolve-DnsName -Name $internalDomain -Type MX -ErrorAction Stop
        $mxHtml = ""
        $mxMd = ""
        foreach ($mx in $mxRecords) {
            $mxHtml += "<li><strong>$($mx.NameExchange)</strong> (Preference: $($mx.Preference))</li>"
            $mxMd += "    - **$($mx.NameExchange)** (Preference: $($mx.Preference))`n"
        }

        $healthReportContent += @"
<div class='result success'>
    ⚠️ <strong>mail.$internalDomain</strong> could not be resolved, but MX records were found for the domain.<br/>
    <strong>MX Records:</strong><ul>$mxHtml</ul>
</div>
"@
        $markdownOutput += "* ⚠️ **mail.$internalDomain** could not be resolved, but MX records were found for the domain.`n"
        $markdownOutput += "    - **MX Records:**`n$mxMd"
    }
    catch {
        $healthReportContent += @"
<div class='result failure'>
    ❌ No mail server detected (neither mail.$internalDomain A record nor MX records found).
</div>
"@
        $markdownOutput += "* ❌ No mail server detected (neither mail.$internalDomain A record nor MX records found).`n"
    }
}


#-------------------------------------------------------------------
# Section 2: DNS Server Configuration & Scavenging
#-------------------------------------------------------------------
$scavengingReportContent += "<div class='section-header'>DNS Server Configuration & Scavenging</div>"
$markdownOutput += "`n## DNS Server Configuration & Scavenging`n"

if ($dcs.Count -eq 0) {
    $scavengingReportContent += "<p class='event-warning'>⚠️ No domain controllers discovered.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered.`n"
}
else {
    foreach ($dc in $dcs) {
        $serverName = $dc.Name
        $scavengingReportContent += "<h3>Server: $serverName</h3>"
        $markdownOutput += "### Server: $serverName`n"

        try {
            $dnsService = Get-Service -Name "DNS" -ComputerName $serverName -ErrorAction SilentlyContinue
            if ($null -ne $dnsService -and $dnsService.Status -eq "Running") {
                $dnsServerInfo = Get-DnsServer -ComputerName $serverName
                $allZones = Get-DnsServerZone -ComputerName $serverName -ErrorAction SilentlyContinue
                $scavenging = Get-DnsServerScavenging -ComputerName $serverName

                $forwardZones = $allZones | Where-Object { -not $_.IsReverseLookupZone } | Select-Object -ExpandProperty ZoneName
                $reverseZones = $allZones | Where-Object { $_.IsReverseLookupZone } | Select-Object -ExpandProperty ZoneName
                
                $forwardZonesHtml = ($forwardZones | ForEach-Object { "<li>$_</li>" }) -join ""
                $reverseZonesHtml = ($reverseZones | ForEach-Object { "<li>$_</li>" }) -join ""
                $forwarders = ($dnsServerInfo.Forwarders | Select-Object -ExpandProperty IPAddress) -join ", "
                if ([string]::IsNullOrWhiteSpace($forwarders)) { $forwarders = "None" }
                $interfaces = ($dnsServerInfo.ListenAddresses | Select-Object -ExpandProperty IPAddress) -join ", "

                $scavengingReportContent += @"
<div class='result event-info'>
    <p>✅ DNS service is running.</p>
    <p><strong>Total Zones:</strong> $($allZones.Count)</p>
    <p><strong>Forward Zones:</strong></p><ul>$forwardZonesHtml</ul>
    <p><strong>Reverse Zones:</strong></p><ul>$reverseZonesHtml</ul>
    <p><strong>Forwarders:</strong> $forwarders</p>
    <p><strong>Listening Interfaces:</strong> $interfaces</p>
</div>
"@
                $markdownOutput += "* ✅ DNS service is running.`n"
                
                $forwardZonesMd = ($forwardZones | ForEach-Object { "    - $_`n" }) -join ""
                $reverseZonesMd = ($reverseZones | ForEach-Object { "    - $_`n" }) -join ""

                $markdownOutput += "    - **Total Zones:** $($allZones.Count)`n"
                $markdownOutput += "    - **Forward Zones:**`n$forwardZonesMd"
                $markdownOutput += "    - **Reverse Zones:**`n$reverseZonesMd"
                $markdownOutput += "    - **Forwarders:** $forwarders`n"
                $markdownOutput += "    - **Listening Interfaces:** $interfaces`n`n"
                
                $isEnabled = if ($scavenging.ScavengingInterval -gt [System.TimeSpan]::Zero) { "✅ Enabled" } else { "❌ Disabled" }
                $interval = $scavenging.ScavengingInterval
                $lastScavenge = $scavenging.LastScavengeTime

                $scavengingReportContent += "<h3>Scavenging Details</h3>"
                $scavengingReportContent += @"
<div class='result event-info'>
    <p><strong>Server Scavenging:</strong> $isEnabled</p>
    <p><strong>Interval:</strong> $interval</p>
    <p><strong>Last Scavenge:</strong> $lastScavenge</p>
</div>
"@
                $markdownOutput += "### Scavenging Details`n"
                $markdownOutput += "* **Server Scavenging:** $isEnabled`n"
                $markdownOutput += "    - **Interval:** $interval`n"
                $markdownOutput += "    - **Last Scavenge:** $lastScavenge`n`n"
                
                $zonesWithScavenging = $allZones | Where-Object { $_.ScavengingEnabled }
                if ($zonesWithScavenging.Count -gt 0) {
                    $scavengingHtmlList = ($zonesWithScavenging | ForEach-Object { "<li>`$($_.ZoneName)` - NoRefreshInterval: `$($_.NoRefreshInterval)`, RefreshInterval: `$($_.RefreshInterval)`</li>" }) -join ""
                    $scavengingReportContent += "<p><strong>Zones with Scavenging Enabled:</strong></p><ul>$scavengingHtmlList</ul>"
                    
                    $scavengingMdList = ($zonesWithScavenging | ForEach-Object { "    - `$($_.ZoneName)` - NoRefreshInterval: `$($_.NoRefreshInterval)`, RefreshInterval: `$($_.RefreshInterval)` `n" }) -join ""
                    $markdownOutput += "* **Zones with Scavenging Enabled:**`n"
                    $markdownOutput += $scavengingMdList
                }
                else {
                     $scavengingReportContent += "<p class='event-warning'>⚠️ No zones on this server have scavenging enabled.</p>"
                     $markdownOutput += "⚠️ No zones on this server have scavenging enabled.`n"
                }

            }
            else {
                $scavengingReportContent += "<p class='event-warning'>⚠️ DNS Service is not running on '$serverName'.</p>"
                $markdownOutput += "⚠️ DNS Service is not running on '$serverName'.`n`n"
            }
        }
        catch {
            $err = $_.Exception.Message
            $scavengingReportContent += "<p class='event-error'>❌ Could not retrieve DNS configuration from '$serverName'.<br/>$err</p>"
            $markdownOutput += "❌ Could not retrieve DNS configuration from '$serverName'. $err`n`n"
        }
    }
}


#-------------------------------------------------------------------
# Section 3: DNS Event Log Check (Last 24 Hours)
#-------------------------------------------------------------------
$eventReportContent += "<div class='section-header'>DNS Event Log Check (Last 24 Hours)</div>"
$markdownOutput += "`n## DNS Event Log Check (Last 24 Hours)`n"

if ($dcs.Count -eq 0) {
    $eventReportContent += "<p class='event-warning'>⚠️ No domain controllers discovered; skipping event-log checks.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered; event-log checks skipped.`n"
}
else {
    $startTime = (Get-Date).AddDays(-1)
    $filter = @{
        LogName = "DNS Server"
        Level   = 2,3        # Errors & Warnings
        StartTime = $startTime
    }

    foreach ($dc in $dcs) {
        $serverName = $dc.Name
        $eventReportContent += "<h3>Events from server: $serverName</h3>"
        $markdownOutput += "### Events from server: $serverName`n"

        try {
            $dnsService = Get-Service -Name "DNS" -ComputerName $serverName -ErrorAction SilentlyContinue
            if ($null -ne $dnsService -and $dnsService.Status -eq "Running") {
                $events = Get-WinEvent `
                         -ComputerName $serverName `
                         -FilterHashtable $filter `
                         -ErrorAction SilentlyContinue

                if (!$events -or $events.Count -eq 0) {
                    $eventReportContent += "<p>✅ No errors or warnings in the last 24h.</p>"
                    $markdownOutput += "✅ No errors or warnings in the last 24 hours.`n"
                    continue
                }

                foreach ($e in $events) {
                    $levelText = switch ($e.Level) { 2 { "Error" } 3 { "Warning" } default { "Info" } }
                    $cssClass = switch ($e.Level) { 2 { "event-error" } 3 { "event-warning" } default { "event-info" } }
                    $cleanMessage = ($e.Message -replace '[^\x20-\x7E]', '') -replace '"', '`"'
                    
                    $eventReportContent += @"
<div class='$cssClass'>
    <h4>[$levelText] Event ID $($e.Id) @ $($e.TimeCreated)</h4>
    <p><strong>Source:</strong> $($e.ProviderName)</p>
    <p><strong>Message:</strong> $cleanMessage</p>
</div>
"@
                    $markdownOutput += "#### [$levelText] Event ID $($e.Id) @ $($e.TimeCreated)`n"
                    $markdownOutput += " - **Source:** $($e.ProviderName)`n"
                    $markdownOutput += " - **Message:** $cleanMessage`n`n"
                }
            }
            else {
                $eventReportContent += "<p class='event-warning'>⚠️ DNS Service is not running on '$serverName'; skipping DNS event log check.</p>"
                $markdownOutput += "⚠️ DNS Service is not running on '$serverName'; skipping DNS event log check.`n"
            }
        }
        catch {
            $err = $_.Exception.Message
            if ($err -like "*RPC server is unavailable*") {
                $eventReportContent += "<p class='event-error'>
                    ❌ Could not retrieve logs from '$serverName'.<br/>
                    **Solution:** The RPC server is unavailable. This is often caused by a firewall blocking communication or the RPC service being stopped. Check the Windows Firewall on '$serverName' for 'Remote Event Log Management' rules.
                </p>"
                $markdownOutput += "❌ Could not retrieve logs from '$serverName'. The RPC server is unavailable. This is often caused by a firewall blocking communication or the RPC service being stopped. Check the Windows Firewall on '$serverName' for 'Remote Event Log Management' rules.`n"
            }
            else {
                $eventReportContent += "<p class='event-error'>
                    ❌ Could not retrieve logs from '$serverName'.<br/>$err
                </p>"
                $markdownOutput += "❌ Could not retrieve logs from '$serverName'. $err`n"
            }
        }
    }
}

#-------------------------------------------------------------------
# Finalize & Write Out
#-------------------------------------------------------------------
$htmlOutput = @"
<!DOCTYPE html>
<html>
<head>
    <title>Internal DNS Health & Event Report</title>
    <style>
        body { font-family: Arial, sans-serif; background-color: #f4f7f9; color: #333; }
        .container { max-width: 900px; margin: 20px auto; padding: 20px; background-color: #fff;
                     border: 1px solid #e1e8ed; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
        .section-header { background-color: #0078d4; color: #fff; padding: 15px; margin-top: 20px;
                          border-radius: 5px; font-size: 1.5em; }
        .result { padding: 10px; margin-bottom: 10px; border-radius: 4px; }
        .success { background-color: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .failure { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        .event-error { background-color: #f8d7da; color: #721c24; border: 1px solid #f5c6cb;
                       padding: 10px; margin-bottom: 10px; border-radius: 4px; }
        .event-warning { background-color: #fff3cd; color: #856404; border: 1px solid #ffeeba;
                          padding: 10px; margin-bottom: 10px; border-radius: 4px; }
        .event-info { background-color: #d1ecf1; color: #0c5460; border: 1px solid #bee5eb;
                      padding: 10px; margin-bottom: 10px; border-radius: 4px; }
        h3 { border-bottom: 2px solid #ccc; padding-bottom: 5px; margin-top: 25px; }
    </style>
</head>
<body>
    <div class='container'>
        <h1 style="text-align: center;">Internal DNS Health & Event Report</h1>
        <p style="text-align: center;">Run Date: $(Get-Date)</p>
        $healthReportContent
        $scavengingReportContent
        $eventReportContent
    </div>
</body>
</html>
"@

$htmlOutput | Out-File -FilePath $htmlFilePath -Encoding UTF8
$markdownOutput | Out-File -FilePath $markdownFilePath -Encoding UTF8

Write-Host "`n✅ Report generation complete! The files have been saved to C:\temp."

Invoke-Item $htmlFilePath
