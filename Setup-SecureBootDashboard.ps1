#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallPath = '',
    [string]$ServerName = '',
    [string]$DatabaseName = '',
    [int]$Port = 0,
    [int]$CollectionIntervalMinutes = 0,
    [switch]$NonInteractive,
    [switch]$SkipSsl
)

$ErrorActionPreference = 'Stop'

$TotalSteps = 10
$UseHttps = $false
$taskName = "eWAN_SecureBootDashboard"
$collectionTaskName = "eWAN_SecureBootDashboard_DataCollection"

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "  +========================================================+" -ForegroundColor Cyan
    Write-Host ("  |   {0,-52} |" -f $Text) -ForegroundColor Cyan
    Write-Host "  +========================================================+" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Step {
    param([int]$Number, [string]$Text)
    Write-Host ""
    Write-Host ("  [{0}/{1}] {2}" -f $Number, $TotalSteps, $Text.ToUpper()) -ForegroundColor White
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
}
function Write-Ok    { param([string]$Text) Write-Host "    [OK] $Text"    -ForegroundColor Green }
function Write-Info  { param([string]$Text) Write-Host "    [INFO] $Text"  -ForegroundColor Cyan }
function Write-Warn2 { param([string]$Text) Write-Host "    [WARN] $Text"  -ForegroundColor Yellow }
function Write-Err   { param([string]$Text) Write-Host "    [ERROR] $Text" -ForegroundColor Red }
function Write-Skip  { param([string]$Text) Write-Host "    [SKIP] $Text"  -ForegroundColor DarkYellow }

function Read-Default {
    param([string]$Prompt, [string]$Default)
    if ($NonInteractive) { return $Default }
    $answer = Read-Host ("  {0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Test-SqlDatabase {
    param([string]$Server, [string]$Database)
    $conn = $null
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=5;")
        $conn.Open()
        return $true
    } catch {
        return $false
    } finally {
        if ($conn) { $conn.Dispose() }
    }
}

Write-Banner "RTX Secure Boot 2026 Dashboard - Production Setup"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "Administrator privileges are required to register Scheduled Tasks and Firewall rules."
    Write-Host "  Please re-run this script in an ELEVATED PowerShell window (Run as Administrator)." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Step 1 "Configuration"

$detectedSite = $null
try {
    $site = Get-WmiObject -Namespace "root\sms" -Class "__NAMESPACE" -ErrorAction Stop |
            Where-Object { $_.Name -match "^site_" } | Select-Object -First 1 -ExpandProperty Name
    if ($site) {
        $detectedSite = $site.Split('_')[1]
        Write-Info "Detected MECM Site Code: $detectedSite"
    }
} catch {
    Write-Warn2 "MECM WMI namespace (root\sms) not found."
}

$defaultServer = if ($ServerName) { $ServerName } else { $env:COMPUTERNAME }

$defaultDatabase = $DatabaseName
if ([string]::IsNullOrWhiteSpace($defaultDatabase)) {
    $candidates = @()
    if ($detectedSite) { $candidates += "CM_$detectedSite" }
    $candidates += @("CM_RTX", "CM_PS1")
    foreach ($db in ($candidates | Select-Object -Unique)) {
        if (Test-SqlDatabase -Server $defaultServer -Database $db) { $defaultDatabase = $db; break }
    }
}
if ([string]::IsNullOrWhiteSpace($defaultDatabase)) { $defaultDatabase = "CM_$detectedSite" }

$defaultInstall  = if ($InstallPath) { $InstallPath } else { 'C:\SecureBoot2026' }
$defaultPort     = if ($Port -gt 0) { $Port } else { 8091 }
$defaultInterval = if ($CollectionIntervalMinutes -gt 0) { $CollectionIntervalMinutes } else { 15 }

$existingConfigPath = Join-Path $defaultInstall 'data\dashboard-config.json'
if (Test-Path $existingConfigPath) {
    try {
        $existingCfg = Get-Content $existingConfigPath -Raw | ConvertFrom-Json
        Write-Info "Found existing install (port $($existingCfg.Port), installed $($existingCfg.InstalledAt))"
        if ($Port -le 0 -and $existingCfg.Port) { $defaultPort = [int]$existingCfg.Port }
        if ($CollectionIntervalMinutes -le 0 -and $existingCfg.CollectionIntervalMinutes) { $defaultInterval = [int]$existingCfg.CollectionIntervalMinutes }
        if ([string]::IsNullOrWhiteSpace($DatabaseName) -and $existingCfg.DatabaseName) { $defaultDatabase = $existingCfg.DatabaseName }
        if ([string]::IsNullOrWhiteSpace($ServerName) -and $existingCfg.ServerName) { $defaultServer = $existingCfg.ServerName }
    } catch {
        Write-Warn2 "Existing config file could not be read: $existingConfigPath"
    }
}

Write-Host ""
$InstallPath   = Read-Default "Dashboard install path" $defaultInstall
$ServerName    = Read-Default "MECM SQL Server" $defaultServer
$DatabaseName  = Read-Default "MECM Database name" $defaultDatabase
$Port          = [int](Read-Default "Dashboard web port" $defaultPort)
$CollectionIntervalMinutes = [int](Read-Default "Data collection interval in minutes" $defaultInterval)

$sqlReachable = Test-SqlDatabase -Server $ServerName -Database $DatabaseName

Write-Host ""
Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("    Install path:    {0}" -f $InstallPath)
Write-Host ("    SQL Server:      {0}" -f $ServerName)
Write-Host ("    Database:        {0}" -f $DatabaseName)
Write-Host ("    Web port:        {0}" -f $Port)
Write-Host ("    Collect every:   {0}m" -f $CollectionIntervalMinutes)
Write-Host  "    Auth:            Windows Auth (SSPI)"
Write-Host ("    SQL reachable:   {0}" -f $(if ($sqlReachable) { 'YES' } else { 'NO' })) -ForegroundColor $(if ($sqlReachable) { 'Green' } else { 'Red' })
Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

if (-not $sqlReachable) {
    Write-Warn2 "Cannot reach $ServerName / $DatabaseName as $env:USERDOMAIN\$env:USERNAME."
    Write-Host "           The collection task runs as SYSTEM (machine account $env:COMPUTERNAME`$)," -ForegroundColor Yellow
    Write-Host "           which needs db_datareader on the ConfigMgr database." -ForegroundColor Yellow
    Write-Host ""
}

if (-not $NonInteractive) {
    $proceed = Read-Host "  Proceed with installation? [Y]"
    if ($proceed -and $proceed -notmatch '^(y|yes)$') {
        Write-Host ""
        Write-Warn2 "Cancelled by user. No changes were made."
        Write-Host ""
        exit 0
    }
}

Write-Step 2 "Stopping Existing Services"

foreach ($name in @($taskName, $collectionTaskName)) {
    $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($existing) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        Write-Info "Removed existing task: $name"
    }
}

$procs = Get-WmiObject Win32_Process -Filter "Name='powershell.exe' AND (CommandLine LIKE '%Start-DashboardWebServer.ps1%' OR CommandLine LIKE '%Collect-SecureBootDashboardData.ps1%' OR CommandLine LIKE '%SecureBoot2026%')" -ErrorAction SilentlyContinue
foreach ($proc in $procs) {
    if ($proc.CommandLine -notlike '*8086*' -and $proc.CommandLine -notlike '*8087*' -and $proc.CommandLine -notlike '*Kiosk*' -and $proc.CommandLine -notlike '*Admin*') {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Info "Stopped active Secure Boot 2026 dashboard process (PID: $($proc.ProcessId))"
    }
}

Start-Sleep -Seconds 2
Write-Ok "Previous dashboard instance stopped"

function Test-PortFree {
    param([int]$TestPort)
    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return -not ($listeners | Where-Object { $_.Port -eq $TestPort })
}

if (-not (Test-PortFree -TestPort $Port)) {
    $owner = "unknown process"
    $ownerPid = $null
    try {
        $conns = netstat -ano | Select-String ":$Port\s" | Select-String "LISTENING"
        if ($conns) {
            $ownerPid = ($conns[0].ToString() -split '\s+')[-1]
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
            if ($proc) { $owner = "$($proc.Name) (PID $ownerPid)" }
        }
    } catch { }

    if ($ownerPid -and $owner -match 'powershell') {
        Write-Info "Terminating orphan PowerShell dashboard process listening on port $Port (PID $ownerPid)..."
        Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    if (-not (Test-PortFree -TestPort $Port)) {
        Write-Err "Port $Port is already in use by $owner."
        Write-Host ""
        Write-Host "    Known occupants in this range:" -ForegroundColor Yellow
        Write-Host "      8086  Kiosk dashboard" -ForegroundColor White
        Write-Host "      8087  Admin dashboard" -ForegroundColor White
        Write-Host "      8090  splunkd.exe - do NOT reclaim" -ForegroundColor White
        Write-Host "      8091  Secure Boot dashboard" -ForegroundColor White
        Write-Host ""
        Write-Host "    To remove a stray instance:" -ForegroundColor Yellow
        Write-Host "      .\Stop-SecureBootDashboard.ps1 -Port $Port" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}
Write-Ok "Port $Port is available"

Write-Step 3 "Copying Files"

$sourceDash = Get-Item (Join-Path $PSScriptRoot 'Dashboard') -ErrorAction SilentlyContinue
if (-not $sourceDash -or -not (Test-Path $sourceDash.FullName)) {
    Write-Err "Source Dashboard folder not found at: $PSScriptRoot\Dashboard"
    exit 1
}

if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

$sourceFiles = Get-ChildItem -Path $sourceDash -Recurse -File
foreach ($file in $sourceFiles) {
    $rel = $file.FullName.Substring($sourceDash.FullName.Length).TrimStart('\')
    if (($rel -split '\\')[0] -eq 'data') { continue }
    $destFile = Join-Path $InstallPath $rel
    $destDir = Split-Path $destFile -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    try {
        Copy-Item -Path $file.FullName -Destination $destFile -Force -ErrorAction Stop
        Write-Ok $rel
    } catch {
        Write-Err "$rel ($($_.Exception.Message))"
    }
}

$dataDir = Join-Path $InstallPath 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
Write-Ok "data\\"

Write-Step 4 "Firewall Rule"

$fwRuleName = "Secure Boot 2026 Dashboard (TCP $Port)"

$staleRules = Get-NetFirewallRule -DisplayName "Secure Boot 2026 Dashboard (TCP *" -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -ne $fwRuleName }
foreach ($rule in $staleRules) {
    try {
        Remove-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction Stop
        Write-Info "Removed stale firewall rule: $($rule.DisplayName)"
    } catch {
        Write-Warn2 "Could not remove stale rule $($rule.DisplayName)"
    }
}

if (-not (Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue)) {
    try {
        New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
        Write-Ok "Firewall rule created: $fwRuleName"
    } catch {
        Write-Warn2 "Failed to create firewall rule: $($_.Exception.Message)"
    }
} else {
    Write-Ok "Firewall rule already exists: $fwRuleName"
}

Write-Step 5 "URL Reservations"

Write-Info "Removing any wildcard reservations that would block hostname listeners..."
$removedAny = $false
foreach ($wild in @("http://+:$Port/", "http://*:$Port/", "https://+:$Port/", "https://*:$Port/")) {
    $del = netsh http delete urlacl url=$wild 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Removed wildcard reservation: $wild"
        $removedAny = $true
    }
}
if (-not $removedAny) {
    Write-Ok "No wildcard reservations present."
}
Write-Info "No reservations created - the SYSTEM service binds hostname prefixes directly."

Write-Step 6 "SSL Certificate"
if ($SkipSsl) {
    Write-Info "-SkipSsl specified; dashboard will serve plain HTTP."
} else {
    $certScript = Join-Path $InstallPath 'scripts\New-SecureBootDashboardCert.ps1'
    if (-not (Test-Path $certScript)) {
        $certScript = Join-Path $PSScriptRoot 'Dashboard\scripts\New-SecureBootDashboardCert.ps1'
    }
    if (-not (Test-Path $certScript)) {
        Write-Warn2 "Certificate script not found at $certScript - serving plain HTTP."
    } else {
        $doSsl = $true
        if (-not $NonInteractive) {
            $answer = Read-Host "  Configure HTTPS for the dashboard? [Y]"
            if ($answer -and $answer -notmatch '^(y|yes)$') { $doSsl = $false }
        }

        if (-not $doSsl) {
            Write-Info "Skipped by choice; dashboard will serve plain HTTP."
        } else {
            try {
                if ($NonInteractive) {
                    & $certScript -Port $Port -Force | Out-Null
                } else {
                    & $certScript -Port $Port | Out-Null
                }

                $sslCheck = netsh http show sslcert ipport=0.0.0.0:$Port 2>$null | Out-String
                if ($sslCheck -match 'Certificate Hash') {
                    $UseHttps = $true
                    Write-Ok "Certificate bound to port $Port - dashboard will serve HTTPS"
                } else {
                    Write-Warn2 "No certificate bound to port $Port - dashboard will serve plain HTTP."
                }
            } catch {
                Write-Warn2 "Certificate setup failed: $($_.Exception.Message)"
                Write-Warn2 "Install continues; dashboard will serve plain HTTP."
            }
        }
    }
}

Write-Step 7 "Scheduling Data Collection"

$collectionScriptPath = Join-Path $InstallPath 'scripts\Collect-SecureBootDashboardData.ps1'
$dataArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$collectionScriptPath`" -ServerName `"$ServerName`" -DatabaseName `"$DatabaseName`""
$dataAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $dataArgs -WorkingDirectory $InstallPath

$dataTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $CollectionIntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$dataPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$dataSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

$dataTask = New-ScheduledTask -Action $dataAction -Principal $dataPrincipal -Trigger $dataTrigger -Settings $dataSettings
Register-ScheduledTask -TaskName $collectionTaskName -InputObject $dataTask -Force | Out-Null
Write-Ok "Scheduled task created: $collectionTaskName (every $($CollectionIntervalMinutes)m)"

Write-Host "    Running initial data collection..." -ForegroundColor DarkGray
Start-ScheduledTask -TaskName $collectionTaskName

Write-Step 8 "Scheduling Web Server (Auto-Start)"

$scriptPath = Join-Path $InstallPath 'Start-DashboardWebServer.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Port $Port" -WorkingDirectory $InstallPath
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Days 9999) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 3

$task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
Write-Ok "Scheduled task created: $taskName (runs at startup)"

Start-ScheduledTask -TaskName $taskName

$serverStarted = $false
for ($attempt = 1; $attempt -le 10; $attempt++) {
    Start-Sleep -Seconds 1
    $taskState = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
    if ($taskState -eq 'Running') {
        $serverStarted = $true
        break
    }
}

if ($serverStarted) {
    Write-Ok "Web server task is RUNNING on port $Port"
} else {
    Write-Err "Web server task failed to enter 'Running' state. Current state: '$taskState'"
    Write-Host "    Attempting direct task start retry..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3
    $taskState = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
    if ($taskState -eq 'Running') {
        Write-Ok "Web server task is now RUNNING on port $Port after retry"
    } else {
        Write-Err "CRITICAL: Web server task is stuck in state '$taskState'."
        Write-Host "    Please check Event Viewer -> Applications and Services Logs -> Microsoft -> Windows -> TaskScheduler" -ForegroundColor Yellow
    }
}

try {
    $configPath = Join-Path $dataDir 'dashboard-config.json'
    $config = [ordered]@{
        Port                      = $Port
        ServerName                = $ServerName
        DatabaseName              = $DatabaseName
        InstallPath               = $InstallPath
        CollectionIntervalMinutes = $CollectionIntervalMinutes
        InstalledAt               = (Get-Date).ToString('o')
        InstalledBy               = "$env:USERDOMAIN\$env:USERNAME"
    }
    [System.IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $config -Depth 3), [System.Text.Encoding]::UTF8)
    Write-Ok "Wrote data\dashboard-config.json (port $Port)"
} catch {
    Write-Warn2 "Could not write dashboard-config.json: $($_.Exception.Message)"
}

Write-Step 9 "Verifying Dashboard Response"

$scheme = if ($UseHttps) { 'https' } else { 'http' }

if ($UseHttps) {
    try {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class SetupCertBypass {
    public static void Ignore() {
        ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
    }
}
"@ -ErrorAction SilentlyContinue
        [SetupCertBypass]::Ignore()
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor 3072
    } catch { }
}

$fqdnHost = try { [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }
$checkHosts = @($fqdnHost, $env:COMPUTERNAME, 'localhost') | Select-Object -Unique
$healthOk = $false
$primaryUrl = "$scheme`://$fqdnHost`:$Port/"

for ($hAttempt = 1; $hAttempt -le 5; $hAttempt++) {
    foreach ($h in $checkHosts) {
        $url = "$scheme`://$h`:$Port/"
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -eq 200) {
                Write-Ok "$scheme OK ($($resp.StatusCode)): $url"
                $healthOk = $true
                break
            }
        } catch { }
    }
    if ($healthOk) { break }
    Start-Sleep -Seconds 2
}

if (-not $healthOk) {
    foreach ($h in $checkHosts) {
        $url = "$scheme`://$h`:$Port/"
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
            Write-Warn2 "$url responded $($resp.StatusCode)"
        } catch {
            Write-Err "$url did not respond: $($_.Exception.Message)"
        }
    }
}

if ($UseHttps -and -not $healthOk) {
    try {
        $httpProbe = Invoke-WebRequest -Uri "http://$fqdnHost`:$Port/" -UseBasicParsing -TimeoutSec 5
        if ($httpProbe.StatusCode -eq 200) {
            Write-Err "Dashboard answering on HTTP, not HTTPS, despite a bound certificate."
        }
    } catch { }
}

if ($healthOk) {
    Write-Ok "Verified $scheme health at $primaryUrl"
} else {
    Write-Err "CRITICAL: Dashboard web server failed to respond on port $Port."
    Write-Host "    Troubleshooting options:" -ForegroundColor Yellow
    Write-Host "      1. Check running tasks: Get-ScheduledTask -TaskName 'eWAN_SecureBootDashboard'" -ForegroundColor White
    Write-Host "      2. Start manually: powershell.exe -ExecutionPolicy Bypass -File 'C:\SecureBoot2026\Dashboard\Start-DashboardWebServer.ps1' -Port $Port" -ForegroundColor White
}

$deployedData = Join-Path $InstallPath 'data\secureboot_data.json'
$rowCount = -1
if (Test-Path $deployedData) {
    try {
        $payload = Get-Content -Path $deployedData -Raw | ConvertFrom-Json
        if ($payload.meta) {
            $rowCount = [int]$payload.meta.RowCount
            Write-Ok "Data file present: site '$($payload.meta.SiteCode)', $rowCount endpoint record(s)"
        }
    } catch {
        Write-Warn2 "Data file exists but could not be parsed: $($_.Exception.Message)"
    }
} else {
    Write-Warn2 "No data file yet - the collection task may still be running."
}

Write-Step 10 "MECM Prerequisites"

$manualSteps = @()

if ($sqlReachable) {
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$ServerName;Database=$DatabaseName;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=10;")
        $conn.Open()

        function Invoke-Scalar {
            param([string]$Sql)
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $Sql
            return $cmd.ExecuteScalar()
        }

        $classRegistered = Invoke-Scalar "SELECT COUNT(*) FROM v_GroupMap WHERE InvClassName = 'v_GS_EWAN_SecureBoot2026Discovery0'"
        if ([int]$classRegistered -gt 0) {
            Write-Ok "Hardware inventory class registered (v_GS_EWAN_SecureBoot2026Discovery0)"
        } else {
            Write-Err "Hardware inventory class NOT registered"
            $manualSteps += "Import MOF via MECM Console -> Administration -> Client Settings -> Default Client Settings -> Hardware Inventory -> Set Classes -> Import"
        }

        $viewRows = 0
        if ([int]$classRegistered -gt 0) {
            $viewRows = Invoke-Scalar "SELECT COUNT(*) FROM v_GS_EWAN_SecureBoot2026Discovery0"
            if ([int]$viewRows -gt 0) {
                Write-Ok "Inventory view populated: $viewRows device(s) reporting"
            } else {
                Write-Err "Inventory view exists but has 0 rows - no client has reported yet"
            }
        }

        $pkgCount = Invoke-Scalar "SELECT COUNT(*) FROM v_Package WHERE Name LIKE '%Secure Boot 2026%'"
        $advCount = Invoke-Scalar "SELECT COUNT(*) FROM v_Advertisement WHERE PackageID IN (SELECT PackageID FROM v_Package WHERE Name LIKE '%Secure Boot 2026%')"

        if ([int]$pkgCount -eq 0) {
            Write-Err "Secure Boot 2026 packages not found in the site"
            $manualSteps += "Run Setup-SecureBoot2026-MECM.ps1 on the Site Server to create collections and packages"
        } elseif ([int]$advCount -eq 0) {
            Write-Err "Packages exist but have NO deployments"
            $manualSteps += "Deploy the 'Secure Boot 2026 - Discovery Inventory' package to target collection"
            $manualSteps += "Trigger a Hardware Inventory cycle on target clients, then wait for the collection task to run"
        } else {
            Write-Ok "Discovery package deployed ($advCount deployment(s) found)"
        }

        $conn.Close()
    } catch {
        Write-Warn2 "Could not complete prerequisite checks: $($_.Exception.Message)"
    }
} else {
    Write-Warn2 "Skipping prerequisite checks - SQL was not reachable during configuration."
    $manualSteps += "Grant db_datareader on $DatabaseName to the machine account $env:COMPUTERNAME`$ (the collection task runs as SYSTEM)"
}

if ($manualSteps.Count -gt 0) {
    Write-Host ""
    Write-Host "    MANUAL STEPS REQUIRED:" -ForegroundColor Yellow
    $i = 1
    foreach ($stepText in $manualSteps) {
        Write-Host ("    {0}. {1}" -f $i, $stepText) -ForegroundColor White
        $i++
    }
}

$fqdn = try { [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }

Write-Host ""
Write-Host "  +--------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  SETUP COMPLETE                                        |" -ForegroundColor Green
Write-Host "  +--------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
$scheme = if ($UseHttps) { 'https' } else { 'http' }
Write-Host ("  Dashboard:          {0}://{1}:{2}/" -f $scheme, $env:COMPUTERNAME, $Port) -ForegroundColor Cyan
Write-Host ("  Dashboard (FQDN):   {0}://{1}:{2}/" -f $scheme, $fqdn, $Port) -ForegroundColor Cyan
Write-Host ("  Dashboard (local):  {0}://localhost:{1}/" -f $scheme, $Port) -ForegroundColor Cyan
if ($UseHttps) {
    Write-Host  "  Use the FQDN URL for certificates." -ForegroundColor DarkGray
} else {
    Write-Host  "  SSL not configured. To enable: scripts\New-SecureBootDashboardCert.ps1 -Port $Port" -ForegroundColor DarkGray
}
Write-Host ("  Install path:       {0}" -f $InstallPath)
Write-Host ("  SQL target:         {0} / {1}" -f $ServerName, $DatabaseName)
Write-Host ("  Data collection:    Every {0} minutes" -f $CollectionIntervalMinutes)
Write-Host  "  Web server:         Auto-starts on boot"
Write-Host ""
Write-Host "  Scheduled Tasks:"
Write-Host ("    - {0}" -f $collectionTaskName)
Write-Host ("    - {0}" -f $taskName)
Write-Host ""

if ($rowCount -eq 0) {
    Write-Host "  NOTE: The dashboard will display 0 for all metrics until the discovery" -ForegroundColor Yellow
    Write-Host "        package is deployed and clients report hardware inventory." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  To uninstall:"
Write-Host "    .\Stop-SecureBootDashboard.ps1 -RemoveFiles" -ForegroundColor White
Write-Host ""
