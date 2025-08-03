#-------------------------------------------------------------------
# Internal DNS Health & Event Report
#-------------------------------------------------------------------

# 1) Import AD module
Import-Module ActiveDirectory

# 2) Define output paths
$htmlFilePath = "C:\temp\DNS_Report.html"
$markdownFilePath = "C:\temp\DNS_Report.md"

# 3) Initialize HTML container
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
"@

# 4) Initialize Markdown
$markdownOutput = "# Internal DNS Health & Event Report`n`n"
$markdownOutput += "Run Date: $(Get-Date)`n`n"

#-------------------------------------------------------------------
# Section 1: Domain Controller & DNS Server Health
#-------------------------------------------------------------------
$htmlOutput += "<div class='section-header'>Domain Controller & DNS Server Health</div>"
$markdownOutput += "## Domain Controller & DNS Server Health`n"

# 1.1) Discover your root domain and DCs
try {
    $adDomain = Get-ADDomain
    $internalDomain = $adDomain.DNSRootDomain
    $dcs = Get-ADDomainController -Filter *
} catch {
    Write-Warning "Could not auto-discover domain; using fallback"
    $internalDomain = "yourinternaldomain.com"
    $dcs = @()
}

# 1.2) Report on each DC's DNS resolution and details
if ($dcs.Count -eq 0) {
    $htmlOutput += "<p class='event-warning'>⚠️ No domain controllers discovered.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered.`n"
}
else {
    foreach ($dc in $dcs) {
        $dcName = $dc.Name
        $htmlOutput += "<h3>DC: $dcName</h3>"
        $markdownOutput += "### DC: $dcName`n"

        try {
            $adComputer = Get-ADComputer -Identity $dcName -Properties dNSHostName, OperatingSystem -ErrorAction Stop
            $dcHostname = $adComputer.dNSHostName
            $os = $adComputer.OperatingSystem
            
            # --- FIX IS HERE ---
            # Extract the short name for display purposes
            $shortName = $dcHostname.Split('.')[0]

            $dnsResults = Resolve-DnsName -Name $dcHostname -ErrorAction Stop
            $ipv4 = ($dnsResults | Where-Object Type -eq 'A'   ).IPAddress -join ", "
            
            $htmlOutput += "<div class='result success'>
                ✅ <strong>$shortName</strong> resolved.<br/>
                <strong>FQDN:</strong> $dcHostname<br/>
                <strong>IPv4:</strong> $ipv4<br/>
                <strong>Operating System:</strong> $os
            </div>"
            
            $markdownOutput += "* ✅ **$shortName** resolved.`n"
            $markdownOutput += "    - **FQDN:** $dcHostname`n"
            $markdownOutput += "    - **IPv4:** $ipv4`n"
            $markdownOutput += "    - **Operating System:** $os`n"
        }
        catch {
            $msg = $_.Exception.Message
            $htmlOutput += "<div class='result failure'>
                ❌ Could not retrieve details or resolve host for <strong>$dcName</strong>.<br/>
                $msg
            </div>"
            $markdownOutput += "* ❌ Could not retrieve details or resolve host for **$dcName**. $msg`n"
        }
    }
}

# 1.3) Mail Server Check
$htmlOutput += "<div class='section-header'>Mail Server Check</div>"
$markdownOutput += "`n## Mail Server Check`n"
try {
    $mailHost = "mail.$internalDomain"
    $mailARecord = Resolve-DnsName -Name $mailHost -Type A -ErrorAction Stop
    $mailIP = $mailARecord.IPAddress -join ", "

    $htmlOutput += "<div class='result success'>
        ✅ <strong>$mailHost</strong> resolved.<br/>
        <strong>IP Address:</strong> $mailIP
    </div>"
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

        $htmlOutput += "<div class='result success'>
            ⚠️ <strong>mail.$internalDomain</strong> could not be resolved, but MX records were found for the domain.<br/>
            <strong>MX Records:</strong><ul>$mxHtml</ul>
        </div>"
        $markdownOutput += "* ⚠️ **mail.$internalDomain** could not be resolved, but MX records were found for the domain.`n"
        $markdownOutput += "    - **MX Records:**`n$mxMd"
    }
    catch {
        $htmlOutput += "<div class='result failure'>
            ❌ No mail server detected (neither mail.$internalDomain A record nor MX records found).
        </div>"
        $markdownOutput += "* ❌ No mail server detected (neither mail.$internalDomain A record nor MX records found).`n"
    }
}


#-------------------------------------------------------------------
# Section 2: DNS Server Configuration Overview
#-------------------------------------------------------------------
$htmlOutput += "<div class='section-header'>DNS Server Configuration Overview</div>"
$markdownOutput += "`n## DNS Server Configuration Overview`n"

if ($dcs.Count -eq 0) {
    $htmlOutput += "<p class='event-warning'>⚠️ No domain controllers discovered.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered.`n"
}
else {
    foreach ($dc in $dcs) {
        $serverName = $dc.Name
        $htmlOutput += "<h3>Server: $serverName</h3>"
        $markdownOutput += "### Server: $serverName`n"

        try {
            $dnsService = Get-Service -Name "DNS" -ComputerName $serverName -ErrorAction SilentlyContinue
            if ($null -ne $dnsService -and $dnsService.Status -eq "Running") {
                $dnsServerInfo = Get-DnsServer -ComputerName $serverName
                $allZones = Get-DnsServerZone -ComputerName $serverName -ErrorAction SilentlyContinue
                
                $forwardZones = $allZones | Where-Object { -not $_.IsReverseLookupZone } | Select-Object -ExpandProperty ZoneName
                $reverseZones = $allZones | Where-Object { $_.IsReverseLookupZone } | Select-Object -ExpandProperty ZoneName

                $forwardZonesHtml = ($forwardZones | ForEach-Object { "<li>$_</li>" }) -join ""
                $reverseZonesHtml = ($reverseZones | ForEach-Object { "<li>$_</li>" }) -join ""

                $forwardZonesMd = ($forwardZones | ForEach-Object { "    - $_`n" }) -join ""
                $reverseZonesMd = ($reverseZones | ForEach-Object { "    - $_`n" }) -join ""

                $forwarders = ($dnsServerInfo.Forwarders | Select-Object -ExpandProperty IPAddress) -join ", "
                if ([string]::IsNullOrWhiteSpace($forwarders)) { $forwarders = "None" }
                $interfaces = ($dnsServerInfo.ListenAddresses | Select-Object -ExpandProperty IPAddress) -join ", "

                $htmlOutput += "<div class='result event-info'>
                    <p>✅ DNS service is running.</p>
                    <p><strong>Total Zones:</strong> $($allZones.Count)</p>
                    <p><strong>Forward Zones:</strong></p><ul>$forwardZonesHtml</ul>
                    <p><strong>Reverse Zones:</strong></p><ul>$reverseZonesHtml</ul>
                    <p><strong>Forwarders:</strong> $forwarders</p>
                    <p><strong>Listening Interfaces:</strong> $interfaces</p>
                </div>"

                $markdownOutput += "* ✅ DNS service is running.`n"
                $markdownOutput += "    - **Total Zones:** $($allZones.Count)`n"
                $markdownOutput += "    - **Forward Zones:**`n$forwardZonesMd"
                $markdownOutput += "    - **Reverse Zones:**`n$reverseZonesMd"
                $markdownOutput += "    - **Forwarders:** $forwarders`n"
                $markdownOutput += "    - **Listening Interfaces:** $interfaces`n`n"
            }
            else {
                $htmlOutput += "<p class='event-warning'>⚠️ DNS Service is not running on '$serverName'.</p>"
                $markdownOutput += "⚠️ DNS Service is not running on '$serverName'.`n`n"
            }
        }
        catch {
            $err = $_.Exception.Message
            $htmlOutput += "<p class='event-error'>❌ Could not retrieve DNS configuration from '$serverName'.<br/>$err</p>"
            $markdownOutput += "❌ Could not retrieve DNS configuration from '$serverName'. $err`n`n"
        }
    }
}

#-------------------------------------------------------------------
# Section 3: DNS Event Log Check (Last 24 Hours)
#-------------------------------------------------------------------
$htmlOutput += "<div class='section-header'>DNS Event Log Check (Last 24 Hours)</div>"
$markdownOutput += "`n## DNS Event Log Check (Last 24 Hours)`n"

if ($dcs.Count -eq 0) {
    $htmlOutput += "<p class='event-warning'>⚠️ No domain controllers discovered; skipping event-log checks.</p>"
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
        $htmlOutput += "<h3>Events from server: $serverName</h3>"
        $markdownOutput += "### Events from server: $serverName`n"

        try {
            $dnsService = Get-Service -Name "DNS" -ComputerName $serverName -ErrorAction SilentlyContinue
            if ($null -ne $dnsService -and $dnsService.Status -eq "Running") {
                $events = Get-WinEvent `
                         -ComputerName $serverName `
                         -FilterHashtable $filter `
                         -ErrorAction SilentlyContinue

                if (!$events -or $events.Count -eq 0) {
                    $htmlOutput += "<p>✅ No errors or warnings in the last 24h.</p>"
                    $markdownOutput += "✅ No errors or warnings in the last 24 hours.`n"
                    continue
                }

                foreach ($e in $events) {
                    $levelText = switch ($e.Level) { 2 { "Error" } 3 { "Warning" } default { "Info" } }
                    $cssClass = switch ($e.Level) { 2 { "event-error" } 3 { "event-warning" } default { "event-info" } }

                    $htmlOutput += "<div class='$cssClass'>
                        <h4>[$levelText] Event ID $($e.Id) @ $($e.TimeCreated)</h4>
                        <p><strong>Source:</strong> $($e.ProviderName)</p>
                        <p><strong>Message:</strong> $($e.Message)</p>
                    </div>"

                    $markdownOutput += "#### [$levelText] Event ID $($e.Id) @ $($e.TimeCreated)`n"
                    $markdownOutput += " - **Source:** $($e.ProviderName)`n"
                    $markdownOutput += " - **Message:** $($e.Message)`n`n"
                }
            }
            else {
                $htmlOutput += "<p class='event-warning'>
                    ⚠️ DNS Service is not running on '$serverName'; skipping DNS event log check.
                </p>"
                $markdownOutput += "⚠️ DNS Service is not running on '$serverName'; skipping DNS event log check.`n"
            }
        }
        catch {
            $err = $_.Exception.Message
            if ($err -like "*RPC server is unavailable*") {
                $htmlOutput += "<p class='event-error'>
                    ❌ Could not retrieve logs from '$serverName'.<br/>
                    **Solution:** The RPC server is unavailable. This is often caused by a firewall blocking communication or the RPC service being stopped. Check the Windows Firewall on '$serverName' for 'Remote Event Log Management' rules.
                </p>"
                $markdownOutput += "❌ Could not retrieve logs from '$serverName'. The RPC server is unavailable. This is often caused by a firewall blocking communication or the RPC service being stopped. Check the Windows Firewall on '$serverName' for 'Remote Event Log Management' rules.`n"
            }
            else {
                $htmlOutput += "<p class='event-error'>
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
$htmlOutput += @"
    </div>
</body>
</html>
"@

$htmlOutput | Out-File -FilePath $htmlFilePath -Encoding UTF8
$markdownOutput | Out-File -FilePath $markdownFilePath -Encoding UTF8

# Launch the HTML report
Invoke-Item $htmlFilePath
