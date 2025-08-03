#-------------------------------------------------------------------
# Internal DNS Health & Event Report
#-------------------------------------------------------------------

# 1) Import AD module
Import-Module ActiveDirectory

# 2) Define output paths
$htmlFilePath     = "C:\temp\DNS_Report.html"
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
$markdownOutput  = "# Internal DNS Health & Event Report`n`n"
$markdownOutput += "Run Date: $(Get-Date)`n`n"

#-------------------------------------------------------------------
# Section 1: DNS Resolution Check
#-------------------------------------------------------------------
$htmlOutput     += "<div class='section-header'>DNS Resolution Check</div>"
$markdownOutput += "## DNS Resolution Check`n"

# 1.1) Discover your root domain
try {
    $internalDomain = (Get-ADDomain).DNSRootDomain
} catch {
    Write-Warning "Could not auto-discover domain; using fallback"
    $internalDomain = "yourinternaldomain.com"
}

# 1.2) Seed the list with known names
$domains = @(
    $internalDomain,
    "mail.$internalDomain",
    "www.$internalDomain"
)

# 1.3) Get DCs (Name + DNSHostName)
try {
    $dcs = Get-ADDomainController -Filter * |
           Select-Object Name, DNSHostName
} catch {
    Write-Warning "Get-ADDomainController failed; script will skip DC entries altogether"
    $dcs = @()
}

# 1.4) Append each DC’s FQDN into the lookup list
foreach ($dc in $dcs) {
    if ($dc.DNSHostName) {
        $domains += $dc.DNSHostName.Trim()
    }
}

# 1.5) Resolve A & AAAA for every entry (including DCs)
foreach ($entry in $domains) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }

    try {
        $dnsResults = Resolve-DnsName -Name $entry -ErrorAction Stop
        $ipv4 = ($dnsResults | Where Type -eq 'A'   ).IPAddress -join ", "
        $ipv6 = ($dnsResults | Where Type -eq 'AAAA').IPAddress -join ", "

        # HTML
        $htmlOutput   += "<div class='result success'>
            ✅ <strong>$entry</strong> resolved.<br/>IPv4: $ipv4<br/>IPv6: $ipv6
        </div>"

        # Markdown
        $markdownOutput += "* ✅ **$entry** resolved.`n"
        $markdownOutput += "    - IPv4: $ipv4`n"
        $markdownOutput += "    - IPv6: $ipv6`n"
    }
    catch {
        $msg = $_.Exception.Message
        $htmlOutput   += "<div class='result failure'>
            ❌ <strong>$entry</strong> could not be resolved.<br/>$msg
        </div>"

        $markdownOutput += "* ❌ **$entry** could not be resolved.`n"
    }
}

#-------------------------------------------------------------------
# Section 2: DNS Event Log Check (Last 24 Hours)
#-------------------------------------------------------------------
$htmlOutput     += "<div class='section-header'>DNS Event Log Check (Last 24 Hours)</div>"
$markdownOutput += "`n## DNS Event Log Check (Last 24 Hours)`n"

if ($dcs.Count -eq 0) {
    # No DCs at all
    $htmlOutput   += "<p class='event-warning'>
        ⚠️ No domain controllers discovered; skipping event-log checks.
    </p>"
    $markdownOutput += "⚠️ No domain controllers discovered; event-log checks skipped.`n"
}
else {
    $startTime = (Get-Date).AddDays(-1)
    $filter    = @{
        LogName   = "DNS Server"
        Level     = 2,3       # Errors & Warnings
        StartTime = $startTime
    }

    foreach ($dc in $dcs) {
        $serverName = $dc.Name   # NetBIOS name for Get-WinEvent
        $htmlOutput   += "<h3>Events from server: $serverName</h3>"
        $markdownOutput += "### Events from server: $serverName`n"

        try {
            $events = Get-WinEvent `
                       -ComputerName $serverName `
                       -FilterHashtable $filter `
                       -ErrorAction SilentlyContinue

            if (!$events -or $events.Count -eq 0) {
                $htmlOutput   += "<p>✅ No errors or warnings in the last 24h.</p>"
                $markdownOutput += "✅ No errors or warnings in the last 24 hours.`n"
                continue
            }

            foreach ($e in $events) {
                $levelText = switch ($e.Level) { 2 { "Error" } 3 { "Warning" } default { "Info" } }
                $cssClass  = switch ($e.Level) { 2 { "event-error" } 3 { "event-warning" } default { "event-info" } }

                $htmlOutput   += "<div class='$cssClass'>
                    <h4>[$levelText] Event ID $($e.Id) @ $($e.TimeCreated)</h4>
                    <p><strong>Source:</strong> $($e.ProviderName)</p>
                    <p><strong>Message:</strong> $($e.Message)</p>
                </div>"

                $markdownOutput += "#### [$levelText] Event ID $($e.Id) @ $($e.TimeCreated)`n"
                $markdownOutput += "  - **Source:** $($e.ProviderName)`n"
                $markdownOutput += "  - **Message:** $($e.Message)`n`n"
            }
        }
        catch {
            $err = $_.Exception.Message
            $htmlOutput   += "<p class='event-error'>
                ❌ Could not retrieve logs from '$serverName'.<br/>$err
            </p>"
            $markdownOutput += "❌ Could not retrieve logs from '$serverName'. $err`n"
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

$htmlOutput     | Out-File -FilePath $htmlFilePath    -Encoding UTF8
$markdownOutput | Out-File -FilePath $markdownFilePath -Encoding UTF8

# Launch the HTML report
Invoke-Item $htmlFilePath
