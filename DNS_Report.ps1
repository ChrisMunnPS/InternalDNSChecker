#-------------------------------------------------------------------
# Enhanced Internal DNS Health & Event Report
# Version: 2.0
# Features: Performance metrics, parallel processing, configuration file support,
#          enhanced error handling, alerting, and historical trending
#-------------------------------------------------------------------

# Set console output encoding to UTF-8 for special characters
chcp 65001 | Out-Null
$OutputEncoding = [System.Text.Encoding]::UTF8

# Import required modules
Import-Module ActiveDirectory
if (Get-Module -ListAvailable -Name PowerShell-Parallel) {
    Import-Module PowerShell-Parallel -ErrorAction SilentlyContinue
}

#-------------------------------------------------------------------
# Configuration Management
#-------------------------------------------------------------------
# Robust script path detection
$scriptPath = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptPath)) {
    if ($MyInvocation.MyCommand.Path) {
        $scriptPath = Split-Path $MyInvocation.MyCommand.Path -Parent
    } else {
        # Fallback to current directory if running interactively
        $scriptPath = Get-Location
    }
}

# Ensure we have a valid script path
if ([string]::IsNullOrEmpty($scriptPath)) {
    $scriptPath = "C:\temp"
    Write-Warning "Could not determine script location. Using fallback path: $scriptPath"
}

$configPath = Join-Path $scriptPath "dns-config.json"

# Default configuration
$defaultConfig = @{
    outputDir = "C:\temp"
    eventLogDays = 1
    queryTimeoutSeconds = 5
    maxParallelJobs = 5
    enableAlerting = $false
    alertThresholds = @{
        maxQueryTimeMs = 1000
        maxEventErrors = 5
        maxEventWarnings = 10
    }
    emailSettings = @{
        smtpServer = "mail.yourdomain.com"
        from = "dns-monitoring@yourdomain.com"
        to = @("admin@yourdomain.com")
        subject = "DNS Health Alert - Critical Issues Detected"
    }
    externalDNSTests = @(
        "google.com",
        "microsoft.com",
        "cloudflare.com"
    )
    customDNSServers = @()
    enableHistoricalTracking = $true
    staleRecordDays = 30
}

# Load configuration from file or create default
if (Test-Path $configPath) {
    try {
        $configContent = Get-Content $configPath -Raw -ErrorAction Stop
        $config = $configContent | ConvertFrom-Json
        Write-Host "✅ Configuration loaded from: $configPath" -ForegroundColor Green
        
        # Ensure all required properties exist by merging with defaults
        $defaultConfig.PSObject.Properties | ForEach-Object {
            if (-not $config.PSObject.Properties.Name.Contains($_.Name)) {
                $config | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value
            }
        }
    } catch {
        Write-Warning "Failed to load config file. Using defaults. Error: $($_.Exception.Message)"
        $config = $defaultConfig
    }
} else {
    Write-Host "ℹ️ Creating default configuration file: $configPath" -ForegroundColor Yellow
    try {
        $defaultConfig | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding UTF8 -ErrorAction Stop
        Write-Host "✅ Default configuration file created successfully" -ForegroundColor Green
    } catch {
        Write-Warning "Could not create config file: $($_.Exception.Message)"
    }
    $config = $defaultConfig
}

#-------------------------------------------------------------------
# Initialize Variables and Paths
#-------------------------------------------------------------------
$dateString = (Get-Date).ToString("yyMMdd_HHmm")

# Ensure we have a valid output directory
$outputDir = $config.outputDir
if ([string]::IsNullOrEmpty($outputDir)) {
    $outputDir = "C:\temp"
    Write-Warning "Output directory not specified in config. Using default: $outputDir"
}

$htmlFilePath = Join-Path $outputDir "DNS_Report_$dateString.html"
$markdownFilePath = Join-Path $outputDir "DNS_Report_$dateString.md"
$historyPath = Join-Path $outputDir "DNS_History.json"
$logFilePath = Join-Path $outputDir "DNS_Report_$dateString.log"

if (!(Test-Path -Path $outputDir)) {
    try {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        Write-Host "✅ Created output directory: $outputDir" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create output directory: $($_.Exception.Message)"
        throw
    }
}

# Initialize logging
function Write-Log {
    param($Message, $Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    
    # Only write to file if we have a valid log file path
    if (-not [string]::IsNullOrEmpty($logFilePath)) {
        try {
            Add-Content -Path $logFilePath -Value $logMessage -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {
            # Silently ignore log file write errors to prevent script failure
        }
    }
}

Write-Log "DNS Health Report Started" "INFO"

# Initialize report variables
$healthReportContent = ""
$scavengingReportContent = ""
$eventReportContent = ""
$performanceReportContent = ""
$markdownOutput = ""
$alertMessages = @()
$criticalIssues = 0
$performanceMetrics = @{}

#-------------------------------------------------------------------
# Enhanced DNS Query Function with Performance Metrics
#-------------------------------------------------------------------
function Test-DNSPerformance {
    param(
        [string]$HostName,
        [string]$DNSServer = $null,
        [int]$TimeoutSeconds = 5
    )
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = @{
        HostName = $HostName
        Success = $false
        QueryTime = 0
        IPAddress = ""
        Error = ""
        DNSServer = $DNSServer
    }
    
    try {
        $resolveParams = @{
            Name = $HostName
            ErrorAction = 'Stop'
        }
        if ($DNSServer) {
            $resolveParams.Server = $DNSServer
        }
        
        $dnsResult = Resolve-DnsName @resolveParams
        $stopwatch.Stop()
        
        $result.Success = $true
        $result.QueryTime = $stopwatch.ElapsedMilliseconds
        $result.IPAddress = ($dnsResult | Where-Object Type -eq 'A').IPAddress -join ", "
    } catch {
        $stopwatch.Stop()
        $result.Error = $_.Exception.Message
        $result.QueryTime = $stopwatch.ElapsedMilliseconds
    }
    
    return $result
}

#-------------------------------------------------------------------
# Section 1: Domain Controller & DNS Server Health (Enhanced)
#-------------------------------------------------------------------
Write-Log "Starting Domain Controller Health Check" "INFO"
$healthReportContent += "<div class='section-header'>Domain Controller & DNS Server Health</div>"
$markdownOutput += "## Domain Controller & DNS Server Health`n"

try {
    $adDomain = Get-ADDomain
    $internalDomain = $adDomain.DNSRoot
    $dcs = Get-ADDomainController -Filter * -ErrorAction Stop
    Write-Log "Discovered $($dcs.Count) domain controllers in domain: $internalDomain" "INFO"
} catch {
    Write-Log "Could not auto-discover domain: $($_.Exception.Message)" "WARNING"
    $internalDomain = "yourinternaldomain.com"
    $dcs = @()
}

if ($dcs.Count -eq 0) {
    $healthReportContent += "<p class='event-warning'>⚠️ No domain controllers discovered.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered.`n"
    $alertMessages += "No domain controllers discovered"
    $criticalIssues++
} else {
    # Process DCs in parallel if PowerShell 7+ is available
    $dcResults = if ($PSVersionTable.PSVersion.Major -ge 7) {
        $dcs | ForEach-Object -Parallel {
            $dc = $_
            $dcName = $dc.Name
            $result = @{
                Name = $dcName
                Success = $false
                Details = @{}
                Error = ""
                Performance = @{}
            }
            
            try {
                $adComputer = Get-ADComputer -Identity $dcName -Properties dNSHostName, OperatingSystem -ErrorAction Stop
                $dcHostname = $adComputer.dNSHostName
                $os = $adComputer.OperatingSystem
                
                # Test DNS performance
                $perfTest = Test-DNSPerformance -HostName $dcHostname -TimeoutSeconds 5
                
                $result.Success = $perfTest.Success
                $result.Details = @{
                    FQDN = $dcHostname
                    IPv4 = $perfTest.IPAddress
                    OperatingSystem = $os
                }
                $result.Performance = @{
                    QueryTime = $perfTest.QueryTime
                }
                
                if (-not $perfTest.Success) {
                    $result.Error = $perfTest.Error
                }
            } catch {
                $result.Error = $_.Exception.Message
            }
            
            return $result
        } -ThrottleLimit $config.maxParallelJobs
    } else {
        # Fallback to sequential processing
        $dcs | ForEach-Object {
            $dc = $_
            $dcName = $dc.Name
            $result = @{
                Name = $dcName
                Success = $false
                Details = @{}
                Error = ""
                Performance = @{}
            }
            
            try {
                $adComputer = Get-ADComputer -Identity $dcName -Properties dNSHostName, OperatingSystem -ErrorAction Stop
                $dcHostname = $adComputer.dNSHostName
                $os = $adComputer.OperatingSystem
                
                $perfTest = Test-DNSPerformance -HostName $dcHostname -TimeoutSeconds $config.queryTimeoutSeconds
                
                $result.Success = $perfTest.Success
                $result.Details = @{
                    FQDN = $dcHostname
                    IPv4 = $perfTest.IPAddress
                    OperatingSystem = $os
                }
                $result.Performance = @{
                    QueryTime = $perfTest.QueryTime
                }
                
                if (-not $perfTest.Success) {
                    $result.Error = $perfTest.Error
                }
            } catch {
                $result.Error = $_.Exception.Message
            }
            
            return $result
        }
    }
    
    # Process results
    foreach ($result in $dcResults) {
        $dcName = $result.Name
        $healthReportContent += "<h3>DC: $dcName</h3>"
        $markdownOutput += "### DC: $dcName`n"
        
        if ($result.Success) {
            $shortName = $result.Details.FQDN.Split('.')[0]
            $queryTime = $result.Performance.QueryTime
            
            # Check if query time exceeds threshold
            $performanceClass = if ($queryTime -gt $config.alertThresholds.maxQueryTimeMs) { 
                "event-warning"
                $alertMessages += "Slow DNS query for $dcName ($queryTime ms)"
            } else { 
                "success" 
            }
            
            $healthReportContent += @"
<div class='result $performanceClass'>
    ✅ <strong>$shortName</strong> resolved in ${queryTime}ms.<br/>
    <strong>FQDN:</strong> $($result.Details.FQDN)<br/>
    <strong>IPv4:</strong> $($result.Details.IPv4)<br/>
    <strong>Operating System:</strong> $($result.Details.OperatingSystem)
</div>
"@
            
            $markdownOutput += "* ✅ **$shortName** resolved in ${queryTime}ms.`n"
            $markdownOutput += "    - **FQDN:** $($result.Details.FQDN)`n"
            $markdownOutput += "    - **IPv4:** $($result.Details.IPv4)`n"
            $markdownOutput += "    - **Operating System:** $($result.Details.OperatingSystem)`n"
            
            # Store performance metrics
            $performanceMetrics[$dcName] = $queryTime
        } else {
            $healthReportContent += @"
<div class='result failure'>
    ❌ Could not retrieve details or resolve host for <strong>$dcName</strong>.<br/>
    $($result.Error)
</div>
"@
            $markdownOutput += "* ❌ Could not retrieve details or resolve host for **$dcName**. $($result.Error)`n"
            $alertMessages += "Failed to resolve DC: $dcName - $($result.Error)"
            $criticalIssues++
        }
    }
}

#-------------------------------------------------------------------
# External DNS Performance Testing
#-------------------------------------------------------------------
if ($config.externalDNSTests.Count -gt 0) {
    $healthReportContent += "<div class='section-header'>External DNS Performance Test</div>"
    $markdownOutput += "`n## External DNS Performance Test`n"
    
    Write-Log "Testing external DNS resolution" "INFO"
    
    foreach ($testHost in $config.externalDNSTests) {
        $perfTest = Test-DNSPerformance -HostName $testHost -TimeoutSeconds $config.queryTimeoutSeconds
        
        if ($perfTest.Success) {
            $performanceClass = if ($perfTest.QueryTime -gt $config.alertThresholds.maxQueryTimeMs) { "event-warning" } else { "success" }
            
            $healthReportContent += @"
<div class='result $performanceClass'>
    ✅ <strong>$testHost</strong> resolved in $($perfTest.QueryTime)ms.<br/>
    <strong>IP Address:</strong> $($perfTest.IPAddress)
</div>
"@
            $markdownOutput += "* ✅ **$testHost** resolved in $($perfTest.QueryTime)ms - IP: $($perfTest.IPAddress)`n"
        } else {
            $healthReportContent += @"
<div class='result failure'>
    ❌ Failed to resolve <strong>$testHost</strong>.<br/>
    $($perfTest.Error)
</div>
"@
            $markdownOutput += "* ❌ Failed to resolve **$testHost** - $($perfTest.Error)`n"
            $alertMessages += "External DNS test failed: $testHost"
        }
    }
}

#-------------------------------------------------------------------
# Mail Server Check (Enhanced)
#-------------------------------------------------------------------
$healthReportContent += "<div class='section-header'>Mail Server Check</div>"
$markdownOutput += "`n## Mail Server Check`n"

$mailHosts = @("mail.$internalDomain", "smtp.$internalDomain", "exchange.$internalDomain")
$mailFound = $false

foreach ($mailHost in $mailHosts) {
    $perfTest = Test-DNSPerformance -HostName $mailHost -TimeoutSeconds $config.queryTimeoutSeconds
    
    if ($perfTest.Success) {
        $healthReportContent += @"
<div class='result success'>
    ✅ <strong>$mailHost</strong> resolved in $($perfTest.QueryTime)ms.<br/>
    <strong>IP Address:</strong> $($perfTest.IPAddress)
</div>
"@
        $markdownOutput += "* ✅ **$mailHost** resolved in $($perfTest.QueryTime)ms - IP: $($perfTest.IPAddress)`n"
        $mailFound = $true
        break
    }
}

if (-not $mailFound) {
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
    ⚠️ Direct mail hosts not found, but MX records exist for the domain.<br/>
    <strong>MX Records:</strong><ul>$mxHtml</ul>
</div>
"@
        $markdownOutput += "* ⚠️ Direct mail hosts not found, but MX records exist for the domain.`n"
        $markdownOutput += "    - **MX Records:**`n$mxMd"
    } catch {
        $healthReportContent += @"
<div class='result failure'>
    ❌ No mail server detected (neither direct mail hosts nor MX records found).
</div>
"@
        $markdownOutput += "* ❌ No mail server detected (neither direct mail hosts nor MX records found).`n"
    }
}

#-------------------------------------------------------------------
# Section 2: DNS Server Configuration & Scavenging (Enhanced)
#-------------------------------------------------------------------
Write-Log "Starting DNS Server Configuration Check" "INFO"
$scavengingReportContent += "<div class='section-header'>DNS Server Configuration & Scavenging</div>"
$markdownOutput += "`n## DNS Server Configuration & Scavenging`n"

if ($dcs.Count -eq 0) {
    $scavengingReportContent += "<p class='event-warning'>⚠️ No domain controllers discovered.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered.`n"
} else {
    foreach ($dc in $dcs) {
        $serverName = $dc.Name
        $scavengingReportContent += "<h3>Server: $serverName</h3>"
        $markdownOutput += "### Server: $serverName`n"

        try {
            $dnsService = Get-Service -Name "DNS" -ComputerName $serverName -ErrorAction SilentlyContinue
            if ($null -ne $dnsService -and $dnsService.Status -eq "Running") {
                $dnsServerInfo = Get-DnsServer -ComputerName $serverName -ErrorAction Stop
                $allZones = Get-DnsServerZone -ComputerName $serverName -ErrorAction SilentlyContinue
                $scavenging = Get-DnsServerScavenging -ComputerName $serverName -ErrorAction SilentlyContinue

                $forwardZones = $allZones | Where-Object { -not $_.IsReverseLookupZone } | Select-Object -ExpandProperty ZoneName
                $reverseZones = $allZones | Where-Object { $_.IsReverseLookupZone } | Select-Object -ExpandProperty ZoneName
                
                # Enhanced zone analysis
                $adIntegratedZones = $allZones | Where-Object { $_.ZoneType -eq 'DirectoryIntegrated' } | Select-Object -ExpandProperty ZoneName
                $primaryZones = $allZones | Where-Object { $_.ZoneType -eq 'Primary' } | Select-Object -ExpandProperty ZoneName
                $secondaryZones = $allZones | Where-Object { $_.ZoneType -eq 'Secondary' } | Select-Object -ExpandProperty ZoneName
                
                $forwardZonesHtml = ($forwardZones | ForEach-Object { "<li>$_</li>" }) -join ""
                $reverseZonesHtml = ($reverseZones | ForEach-Object { "<li>$_</li>" }) -join ""
                $forwarders = ($dnsServerInfo.Forwarders | Select-Object -ExpandProperty IPAddress) -join ", "
                if ([string]::IsNullOrWhiteSpace($forwarders)) { $forwarders = "None" }
                $interfaces = ($dnsServerInfo.ListenAddresses | Select-Object -ExpandProperty IPAddress) -join ", "

                $scavengingReportContent += @"
<div class='result event-info'>
    <p>✅ DNS service is running.</p>
    <p><strong>Total Zones:</strong> $($allZones.Count) (AD-Integrated: $($adIntegratedZones.Count), Primary: $($primaryZones.Count), Secondary: $($secondaryZones.Count))</p>
    <p><strong>Forward Zones:</strong></p><ul>$forwardZonesHtml</ul>
    <p><strong>Reverse Zones:</strong></p><ul>$reverseZonesHtml</ul>
    <p><strong>Forwarders:</strong> $forwarders</p>
    <p><strong>Listening Interfaces:</strong> $interfaces</p>
</div>
"@
                $markdownOutput += "* ✅ DNS service is running.`n"
                
                $forwardZonesMd = ($forwardZones | ForEach-Object { "    - $_`n" }) -join ""
                $reverseZonesMd = ($reverseZones | ForEach-Object { "    - $_`n" }) -join ""

                $markdownOutput += "    - **Total Zones:** $($allZones.Count) (AD-Integrated: $($adIntegratedZones.Count), Primary: $($primaryZones.Count), Secondary: $($secondaryZones.Count))`n"
                $markdownOutput += "    - **Forward Zones:**`n$forwardZonesMd"
                $markdownOutput += "    - **Reverse Zones:**`n$reverseZonesMd"
                $markdownOutput += "    - **Forwarders:** $forwarders`n"
                $markdownOutput += "    - **Listening Interfaces:** $interfaces`n`n"
                
                # Enhanced Scavenging Analysis
                if ($scavenging) {
                    $isEnabled = if ($scavenging.ScavengingInterval -gt [System.TimeSpan]::Zero) { "✅ Enabled" } else { "❌ Disabled" }
                    $interval = $scavenging.ScavengingInterval
                    $lastScavenge = $scavenging.LastScavengeTime
                    
                    # Check if scavenging hasn't run recently
                    $scavengeWarning = ""
                    if ($scavenging.ScavengingInterval -gt [System.TimeSpan]::Zero -and $lastScavenge -lt (Get-Date).AddDays(-7)) {
                        $scavengeWarning = "<p class='event-warning'>⚠️ Warning: Scavenging hasn't run in over 7 days.</p>"
                        $alertMessages += "Scavenging hasn't run recently on $serverName"
                    }

                    $scavengingReportContent += "<h4>Scavenging Details</h4>"
                    $scavengingReportContent += @"
<div class='result event-info'>
    <p><strong>Server Scavenging:</strong> $isEnabled</p>
    <p><strong>Interval:</strong> $interval</p>
    <p><strong>Last Scavenge:</strong> $lastScavenge</p>
    $scavengeWarning
</div>
"@
                    $markdownOutput += "#### Scavenging Details`n"
                    $markdownOutput += "* **Server Scavenging:** $isEnabled`n"
                    $markdownOutput += "    - **Interval:** $interval`n"
                    $markdownOutput += "    - **Last Scavenge:** $lastScavenge`n"
                    
                    if ($scavengeWarning) {
                        $markdownOutput += "    - ⚠️ Warning: Scavenging hasn't run in over 7 days.`n"
                    }
                    $markdownOutput += "`n"
                    
                    $zonesWithScavenging = $allZones | Where-Object { $_.ScavengingEnabled }
                    if ($zonesWithScavenging.Count -gt 0) {
                        $scavengingHtmlList = ($zonesWithScavenging | ForEach-Object { "<li>$($_.ZoneName) - NoRefresh: $($_.NoRefreshInterval), Refresh: $($_.RefreshInterval)</li>" }) -join ""
                        $scavengingReportContent += "<p><strong>Zones with Scavenging Enabled ($($zonesWithScavenging.Count)):</strong></p><ul>$scavengingHtmlList</ul>"
                        
                        $scavengingMdList = ($zonesWithScavenging | ForEach-Object { "    - $($_.ZoneName) - NoRefresh: $($_.NoRefreshInterval), Refresh: $($_.RefreshInterval)`n" }) -join ""
                        $markdownOutput += "* **Zones with Scavenging Enabled ($($zonesWithScavenging.Count)):**`n"
                        $markdownOutput += $scavengingMdList
                    } else {
                         $scavengingReportContent += "<p class='event-warning'>⚠️ No zones on this server have scavenging enabled.</p>"
                         $markdownOutput += "⚠️ No zones on this server have scavenging enabled.`n"
                         $alertMessages += "No zones have scavenging enabled on $serverName"
                    }
                }

                # Stale Record Analysis (if enabled)
                if ($config.enableHistoricalTracking) {
                    try {
                        $staleThreshold = (Get-Date).AddDays(-$config.staleRecordDays)
                        $staleCount = 0
                        
                        foreach ($zone in $forwardZones) {
                            $records = Get-DnsServerResourceRecord -ZoneName $zone -ComputerName $serverName -ErrorAction SilentlyContinue | 
                                Where-Object { $_.Timestamp -and $_.Timestamp -lt $staleThreshold }
                            $staleCount += $records.Count
                        }
                        
                        if ($staleCount -gt 0) {
                            $scavengingReportContent += "<p class='event-warning'>⚠️ Found $staleCount potentially stale records older than $($config.staleRecordDays) days.</p>"
                            $markdownOutput += "⚠️ Found $staleCount potentially stale records older than $($config.staleRecordDays) days.`n"
                        } else {
                            $scavengingReportContent += "<p class='success'>✅ No stale records detected.</p>"
                            $markdownOutput += "✅ No stale records detected.`n"
                        }
                    } catch {
                        Write-Log "Could not analyze stale records for $serverName : $($_.Exception.Message)" "WARNING"
                    }
                }

            } else {
                $scavengingReportContent += "<p class='event-warning'>⚠️ DNS Service is not running on '$serverName'.</p>"
                $markdownOutput += "⚠️ DNS Service is not running on '$serverName'.`n`n"
                $alertMessages += "DNS Service not running on $serverName"
                $criticalIssues++
            }
        } catch {
            $err = $_.Exception.Message
            $scavengingReportContent += "<p class='event-error'>❌ Could not retrieve DNS configuration from '$serverName'.<br/>$err</p>"
            $markdownOutput += "❌ Could not retrieve DNS configuration from '$serverName'. $err`n`n"
            
            # Enhanced error handling
            if ($err -like "*RPC server is unavailable*") {
                $scavengingReportContent += "<p class='event-info'><strong>Solution:</strong> Check Windows Firewall and RPC service on '$serverName'.</p>"
                $markdownOutput += "**Solution:** Check Windows Firewall and RPC service on '$serverName'.`n"
            }
            
            Write-Log "DNS configuration check failed for $serverName : $err" "ERROR"
        }
    }
}

#-------------------------------------------------------------------
# Section 3: DNS Event Log Check (Enhanced with Better Filtering)
#-------------------------------------------------------------------
Write-Log "Starting DNS Event Log Analysis" "INFO"
$eventReportContent += "<div class='section-header'>DNS Event Log Check (Last $($config.eventLogDays) Day(s))</div>"
$markdownOutput += "`n## DNS Event Log Check (Last $($config.eventLogDays) Day(s))`n"

if ($dcs.Count -eq 0) {
    $eventReportContent += "<p class='event-warning'>⚠️ No domain controllers discovered; skipping event-log checks.</p>"
    $markdownOutput += "⚠️ No domain controllers discovered; event-log checks skipped.`n"
} else {
    $startTime = (Get-Date).AddDays(-$config.eventLogDays)
    $filter = @{
        LogName = "DNS Server"
        Level   = 2,3        # Errors & Warnings
        StartTime = $startTime
    }
    
    $totalErrors = 0
    $totalWarnings = 0

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
                    $eventReportContent += "<p>✅ No errors or warnings in the last $($config.eventLogDays) day(s).</p>"
                    $markdownOutput += "✅ No errors or warnings in the last $($config.eventLogDays) day(s).`n"
                    continue
                }

                # Group and count events
                $eventGroups = $events | Group-Object Id | Sort-Object Count -Descending
                $errors = $events | Where-Object Level -eq 2
                $warnings = $events | Where-Object Level -eq 3
                
                $totalErrors += $errors.Count
                $totalWarnings += $warnings.Count
                
                $eventReportContent += "<p><strong>Summary:</strong> $($errors.Count) errors, $($warnings.Count) warnings</p>"
                $markdownOutput += "**Summary:** $($errors.Count) errors, $($warnings.Count) warnings`n`n"

                # Show top 10 most frequent events
                foreach ($eventGroup in ($eventGroups | Select-Object -First 10)) {
                    $sampleEvent = $eventGroup.Group[0]
                    $levelText = switch ($sampleEvent.Level) { 2 { "Error" } 3 { "Warning" } default { "Info" } }
                    $cssClass = switch ($sampleEvent.Level) { 2 { "event-error" } 3 { "event-warning" } default { "event-info" } }
                    $cleanMessage = ($sampleEvent.Message -replace '[^\x20-\x7E\r\n]', '') -replace '"', '&quot;'
                    
                    # Limit message length for readability
                    if ($cleanMessage.Length -gt 200) {
                        $cleanMessage = $cleanMessage.Substring(0, 200) + "..."
                    }
                    
                    $eventReportContent += @"
<div class='$cssClass'>
    <h4>[$levelText] Event ID $($sampleEvent.Id) (Occurred $($eventGroup.Count) times)</h4>
    <p><strong>Source:</strong> $($sampleEvent.ProviderName)</p>
    <p><strong>Latest Occurrence:</strong> $($sampleEvent.TimeCreated)</p>
    <p><strong>Message:</strong> $cleanMessage</p>
</div>
"@
                    $markdownOutput += "#### [$levelText] Event ID $($sampleEvent.Id) (Occurred $($eventGroup.Count) times)`n"
                    $markdownOutput += " - **Source:** $($sampleEvent.ProviderName)`n"
                    $markdownOutput += " - **Latest Occurrence:** $($sampleEvent.TimeCreated)`n"
                    $markdownOutput += " - **Message:** $cleanMessage`n`n"
                }
            } else {
                $eventReportContent += "<p class='event-warning'>⚠️ DNS Service is not running on '$serverName'; skipping DNS event log check.</p>"
                $markdownOutput += "⚠️ DNS Service is not running on '$serverName'; skipping DNS event log check.`n"
            }
        } catch {
            $err = $_.Exception.Message
            if ($err -like "*RPC server is unavailable*") {
                $eventReportContent += @"
<p class='event-error'>
    ❌ Could not retrieve logs from '$serverName'.<br/>
    <strong>Solution:</strong> The RPC server is unavailable. Check Windows Firewall on '$serverName' for 'Remote Event Log Management' rules, or verify the RPC service is running.
</p>
"@
                $markdownOutput += "❌ Could not retrieve logs from '$serverName'. The RPC server is unavailable. Check Windows Firewall on '$serverName' for 'Remote Event Log Management' rules, or verify the RPC service is running.`n"
            }
            elseif ($err -like "*Access is denied*") {
                $eventReportContent += @"
<p class='event-error'>
    ❌ Access denied when querying '$serverName'.<br/>
    <strong>Solution:</strong> Verify the account running this script has sufficient privileges to read event logs on the target server.
</p>
"@
                $markdownOutput += "❌ Access denied when querying '$serverName'. Verify the account running this script has sufficient privileges to read event logs on the target server.`n"
            }
            else {
                $eventReportContent += @"
<p class='event-error'>
    ❌ Could not retrieve logs from '$serverName'.<br/>$err
</p>
"@
                $markdownOutput += "❌ Could not retrieve logs from '$serverName'. $err`n"
            }
            Write-Log "Event log retrieval failed for $serverName : $err" "ERROR"
        }
    }
    
    # Check alert thresholds
    if ($totalErrors -gt $config.alertThresholds.maxEventErrors) {
        $alertMessages += "High error count: $totalErrors errors found in DNS logs"
    }
    if ($totalWarnings -gt $config.alertThresholds.maxEventWarnings) {
        $alertMessages += "High warning count: $totalWarnings warnings found in DNS logs"
    }
}

#-------------------------------------------------------------------
# Section 4: Performance Summary
#-------------------------------------------------------------------
if ($performanceMetrics.Count -gt 0) {
    $performanceReportContent += "<div class='section-header'>DNS Performance Summary</div>"
    $markdownOutput += "`n## DNS Performance Summary`n"
    
    $avgQueryTime = ($performanceMetrics.Values | Measure-Object -Average).Average
    $maxQueryTime = ($performanceMetrics.Values | Measure-Object -Maximum).Maximum
    $minQueryTime = ($performanceMetrics.Values | Measure-Object -Minimum).Minimum
    
    $perfClass = if ($avgQueryTime -gt $config.alertThresholds.maxQueryTimeMs) { "event-warning" } else { "success" }
    
    $performanceReportContent += @"
<div class='result $perfClass'>
    <p><strong>Average Query Time:</strong> $([math]::Round($avgQueryTime, 2))ms</p>
    <p><strong>Minimum Query Time:</strong> ${minQueryTime}ms</p>
    <p><strong>Maximum Query Time:</strong> ${maxQueryTime}ms</p>
    <p><strong>Total Servers Tested:</strong> $($performanceMetrics.Count)</p>
</div>
"@
    
    $markdownOutput += "* **Average Query Time:** $([math]::Round($avgQueryTime, 2))ms`n"
    $markdownOutput += "* **Minimum Query Time:** ${minQueryTime}ms`n"
    $markdownOutput += "* **Maximum Query Time:** ${maxQueryTime}ms`n"
    $markdownOutput += "* **Total Servers Tested:** $($performanceMetrics.Count)`n`n"
    
    # Detailed performance breakdown
    $performanceReportContent += "<h4>Detailed Performance Breakdown</h4>"
    $markdownOutput += "### Detailed Performance Breakdown`n"
    
    foreach ($server in ($performanceMetrics.Keys | Sort-Object)) {
        $queryTime = $performanceMetrics[$server]
        $perfStatus = if ($queryTime -gt $config.alertThresholds.maxQueryTimeMs) { "⚠️" } else { "✅" }
        
        $performanceReportContent += "<p>$perfStatus <strong>${server}:</strong> ${queryTime}ms</p>"
        $markdownOutput += "* $perfStatus **${server}:** ${queryTime}ms`n"
    }
}

#-------------------------------------------------------------------
# Historical Data Tracking
#-------------------------------------------------------------------
if ($config.enableHistoricalTracking) {
    Write-Log "Updating historical data" "INFO"
    
    $currentResults = @{
        Timestamp = Get-Date
        DomainControllers = $performanceMetrics
        TotalErrors = $totalErrors
        TotalWarnings = $totalWarnings
        CriticalIssues = $criticalIssues
        AlertMessages = $alertMessages
    }
    
    # Load existing history
    $history = @()
    if (Test-Path $historyPath) {
        try {
            $history = Get-Content $historyPath -Raw | ConvertFrom-Json
        } catch {
            Write-Log "Could not load historical data: $($_.Exception.Message)" "WARNING"
            $history = @()
        }
    }
    
    # Add current results and keep last 30 days
    $history += $currentResults
    $cutoffDate = (Get-Date).AddDays(-30)
    $history = $history | Where-Object { [DateTime]$_.Timestamp -gt $cutoffDate }
    
    # Save updated history
    try {
        $history | ConvertTo-Json -Depth 10 | Out-File $historyPath -Encoding UTF8
        Write-Log "Historical data updated successfully" "INFO"
    } catch {
        Write-Log "Failed to save historical data: $($_.Exception.Message)" "WARNING"
    }
}

#-------------------------------------------------------------------
# Alert Processing
#-------------------------------------------------------------------
if ($config.enableAlerting -and $alertMessages.Count -gt 0) {
    Write-Log "Processing alerts - $($alertMessages.Count) issues detected" "WARNING"
    
    $alertBody = @"
DNS Health Report Alert
Generated: $(Get-Date)

Critical Issues Detected: $criticalIssues
Total Alert Messages: $($alertMessages.Count)

Issues Found:
$($alertMessages | ForEach-Object { "• $_" } | Out-String)

Please review the full DNS health report for detailed information.

This is an automated message from the DNS Health Monitoring System.
"@
    
    try {
        $mailParams = @{
            SmtpServer = $config.emailSettings.smtpServer
            From = $config.emailSettings.from
            To = $config.emailSettings.to
            Subject = $config.emailSettings.subject
            Body = $alertBody
            Encoding = 'UTF8'
        }
        
        Send-MailMessage @mailParams
        Write-Log "Alert email sent successfully" "INFO"
    } catch {
        Write-Log "Failed to send alert email: $($_.Exception.Message)" "ERROR"
    }
}

#-------------------------------------------------------------------
# Generate Final Report
#-------------------------------------------------------------------
$reportSummary = @"
<div class='section-header'>Executive Summary</div>
<div class='result $(if ($criticalIssues -gt 0) { "failure" } elseif ($alertMessages.Count -gt 0) { "event-warning" } else { "success" })'>
    <h3>Overall Status: $(if ($criticalIssues -gt 0) { "❌ Critical Issues Found" } elseif ($alertMessages.Count -gt 0) { "⚠️ Warnings Detected" } else { "✅ Healthy" })</h3>
    <p><strong>Domain Controllers Checked:</strong> $($dcs.Count)</p>
    <p><strong>Critical Issues:</strong> $criticalIssues</p>
    <p><strong>Total Warnings:</strong> $($alertMessages.Count)</p>
    <p><strong>DNS Event Errors:</strong> $totalErrors</p>
    <p><strong>DNS Event Warnings:</strong> $totalWarnings</p>
    $(if ($performanceMetrics.Count -gt 0) { "<p><strong>Average Query Time:</strong> $([math]::Round(($performanceMetrics.Values | Measure-Object -Average).Average, 2))ms</p>" })
</div>
"@

$markdownSummary = @"
## Executive Summary

**Overall Status:** $(if ($criticalIssues -gt 0) { "❌ Critical Issues Found" } elseif ($alertMessages.Count -gt 0) { "⚠️ Warnings Detected" } else { "✅ Healthy" })

* **Domain Controllers Checked:** $($dcs.Count)
* **Critical Issues:** $criticalIssues
* **Total Warnings:** $($alertMessages.Count)
* **DNS Event Errors:** $totalErrors  
* **DNS Event Warnings:** $totalWarnings
$(if ($performanceMetrics.Count -gt 0) { "* **Average Query Time:** $([math]::Round(($performanceMetrics.Values | Measure-Object -Average).Average, 2))ms" })

"@

$htmlOutput = @"
<!DOCTYPE html>
<html>
<head>
    <title>Enhanced Internal DNS Health & Event Report</title>
    <meta charset="UTF-8">
    <style>
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
            background-color: #f5f7fa; 
            color: #333; 
            line-height: 1.6;
            margin: 0;
            padding: 0;
        }
        .container { 
            max-width: 1200px; 
            margin: 20px auto; 
            padding: 20px; 
            background-color: #fff;
            border-radius: 10px; 
            box-shadow: 0 6px 20px rgba(0,0,0,0.1); 
        }
        .header {
            background: linear-gradient(135deg, #0078d4 0%, #106ebe 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 20px;
            text-align: center;
        }
        .section-header { 
            background: linear-gradient(135deg, #0078d4 0%, #106ebe 100%);
            color: #fff; 
            padding: 15px 20px; 
            margin: 25px 0 15px 0;
            border-radius: 8px; 
            font-size: 1.4em; 
            font-weight: 600;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .result { 
            padding: 15px; 
            margin-bottom: 12px; 
            border-radius: 6px; 
            border-left: 4px solid;
            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
        }
        .success { 
            background-color: #d4edda; 
            color: #155724; 
            border-color: #28a745;
        }
        .failure { 
            background-color: #f8d7da; 
            color: #721c24; 
            border-color: #dc3545;
        }
        .event-error { 
            background-color: #f8d7da; 
            color: #721c24; 
            border-color: #dc3545;
            padding: 15px; 
            margin-bottom: 12px; 
            border-radius: 6px; 
            border-left: 4px solid #dc3545;
        }
        .event-warning { 
            background-color: #fff3cd; 
            color: #856404; 
            border-color: #ffc107;
            padding: 15px; 
            margin-bottom: 12px; 
            border-radius: 6px; 
            border-left: 4px solid #ffc107;
        }
        .event-info { 
            background-color: #d1ecf1; 
            color: #0c5460; 
            border-color: #17a2b8;
            padding: 15px; 
            margin-bottom: 12px; 
            border-radius: 6px; 
            border-left: 4px solid #17a2b8;
        }
        h3 { 
            border-bottom: 3px solid #e9ecef; 
            padding-bottom: 8px; 
            margin: 25px 0 15px 0;
            color: #495057;
            font-weight: 600;
        }
        h4 {
            color: #6c757d;
            margin: 15px 0 10px 0;
        }
        .timestamp {
            color: #6c757d;
            font-size: 0.9em;
            margin-bottom: 20px;
        }
        ul li {
            margin-bottom: 5px;
        }
        .footer {
            text-align: center;
            padding: 20px;
            color: #6c757d;
            border-top: 1px solid #e9ecef;
            margin-top: 30px;
        }
        @media (max-width: 768px) {
            .container {
                margin: 10px;
                padding: 15px;
            }
            .section-header {
                font-size: 1.2em;
                padding: 12px 15px;
            }
        }
    </style>
</head>
<body>
    <div class='container'>
        <div class='header'>
            <h1>Enhanced Internal DNS Health & Event Report</h1>
            <p class='timestamp'>Generated: $(Get-Date -Format "dddd, MMMM dd, yyyy 'at' HH:mm:ss")</p>
        </div>
        
        $reportSummary
        $healthReportContent
        $performanceReportContent
        $scavengingReportContent
        $eventReportContent
        
        <div class='footer'>
            <p>Report generated by Enhanced DNS Health Monitor v2.0</p>
            <p>Configuration: $configPath</p>
        </div>
    </div>
</body>
</html>
"@

$finalMarkdownOutput = @"
# Enhanced Internal DNS Health & Event Report

**Generated:** $(Get-Date -Format "dddd, MMMM dd, yyyy 'at' HH:mm:ss")

$markdownSummary
$markdownOutput

---

*Report generated by Enhanced DNS Health Monitor v2.0*  
*Configuration: $configPath*
"@

# Write output files
try {
    if ([string]::IsNullOrEmpty($htmlFilePath) -or [string]::IsNullOrEmpty($markdownFilePath)) {
        throw "Output file paths are not properly initialized"
    }
    
    $htmlOutput | Out-File -FilePath $htmlFilePath -Encoding UTF8 -ErrorAction Stop
    $finalMarkdownOutput | Out-File -FilePath $markdownFilePath -Encoding UTF8 -ErrorAction Stop
    
    Write-Log "Reports generated successfully" "INFO"
    Write-Log "HTML Report: $htmlFilePath" "INFO"
    Write-Log "Markdown Report: $markdownFilePath" "INFO"
    if (-not [string]::IsNullOrEmpty($logFilePath)) {
        Write-Log "Log File: $logFilePath" "INFO"
    }
} catch {
    Write-Log "Failed to write report files: $($_.Exception.Message)" "ERROR"
    Write-Error "Failed to generate reports: $($_.Exception.Message)"
    return
}

#-------------------------------------------------------------------
# Final Summary and Cleanup
#-------------------------------------------------------------------
$endTime = Get-Date
$duration = $endTime - $startTime
Write-Log "DNS Health Report completed in $([math]::Round($duration.TotalSeconds, 2)) seconds" "INFO"

# Display summary
Write-Host "`n" -NoNewline
Write-Host "="*80 -ForegroundColor Cyan
Write-Host "ENHANCED DNS HEALTH REPORT SUMMARY" -ForegroundColor Cyan
Write-Host "="*80 -ForegroundColor Cyan

$statusColor = if ($criticalIssues -gt 0) { 'Red' } elseif ($alertMessages.Count -gt 0) { 'Yellow' } else { 'Green' }
$statusText = if ($criticalIssues -gt 0) { "CRITICAL ISSUES FOUND" } elseif ($alertMessages.Count -gt 0) { "WARNINGS DETECTED" } else { "HEALTHY" }

Write-Host "Overall Status: " -NoNewline
Write-Host $statusText -ForegroundColor $statusColor

Write-Host "Domain Controllers Checked: $($dcs.Count)"
Write-Host "Critical Issues: $criticalIssues" -ForegroundColor $(if ($criticalIssues -gt 0) { 'Red' } else { 'White' })
Write-Host "Total Warnings: $($alertMessages.Count)" -ForegroundColor $(if ($alertMessages.Count -gt 0) { 'Yellow' } else { 'White' })
Write-Host "DNS Event Errors: $totalErrors" -ForegroundColor $(if ($totalErrors -gt 0) { 'Red' } else { 'White' })
Write-Host "DNS Event Warnings: $totalWarnings" -ForegroundColor $(if ($totalWarnings -gt 0) { 'Yellow' } else { 'White' })

if ($performanceMetrics.Count -gt 0) {
    $avgTime = [math]::Round(($performanceMetrics.Values | Measure-Object -Average).Average, 2)
    Write-Host "Average DNS Query Time: ${avgTime}ms" -ForegroundColor $(if ($avgTime -gt $config.alertThresholds.maxQueryTimeMs) { 'Yellow' } else { 'Green' })
}

Write-Host "Execution Time: $([math]::Round($duration.TotalSeconds, 2)) seconds"
Write-Host ""
Write-Host "Reports saved to:" -ForegroundColor Cyan
if (-not [string]::IsNullOrEmpty($htmlFilePath)) {
    Write-Host "  • HTML: $htmlFilePath" -ForegroundColor White
}
if (-not [string]::IsNullOrEmpty($markdownFilePath)) {
    Write-Host "  • Markdown: $markdownFilePath" -ForegroundColor White
}
if (-not [string]::IsNullOrEmpty($logFilePath)) {
    Write-Host "  • Log: $logFilePath" -ForegroundColor White
}

if ($config.enableHistoricalTracking -and -not [string]::IsNullOrEmpty($historyPath)) {
    Write-Host "  • History: $historyPath" -ForegroundColor White
}

Write-Host ""

# Show alerts if any
if ($alertMessages.Count -gt 0) {
    Write-Host "ALERTS DETECTED:" -ForegroundColor Red
    $alertMessages | ForEach-Object { Write-Host "  • $_" -ForegroundColor Yellow }
    Write-Host ""
    
    if ($config.enableAlerting) {
        Write-Host "Email alerts have been sent to configured recipients." -ForegroundColor Green
    } else {
        Write-Host "Email alerting is disabled. Enable in config to receive notifications." -ForegroundColor Yellow
    }
}

Write-Host "="*80 -ForegroundColor Cyan

# Open HTML report if no critical issues (to prevent overwhelming with error reports)
if ($criticalIssues -eq 0 -and -not [string]::IsNullOrEmpty($htmlFilePath)) {
    try {
        Invoke-Item $htmlFilePath
    } catch {
        Write-Log "Could not open HTML report automatically: $($_.Exception.Message)" "WARNING"
    }
}
