#requires -Version 5.1
[CmdletBinding()]
param(
    [int[]]$Port = @(),
    [string]$InstallPath = 'C:\SecureBoot2026',
    [int]$ScanFrom = 8090,
    [int]$ScanTo = 8100,
    [switch]$RemoveFiles,
    [switch]$Force
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-Ok    { param([string]$T) Write-Host "    [OK] $T"    -ForegroundColor Green }
function Write-Info  { param([string]$T) Write-Host "    [INFO] $T"  -ForegroundColor Cyan }
function Write-Warn2 { param([string]$T) Write-Host "    [WARN] $T"  -ForegroundColor Yellow }
function Write-Sect  { param([string]$T) Write-Host ""; Write-Host "  $T" -ForegroundColor White; Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray }

$taskName = "eWAN_SecureBootDashboard"
$collectionTaskName = "eWAN_SecureBootDashboard_DataCollection"

Write-Host ""
Write-Host "  +========================================================+" -ForegroundColor Magenta
Write-Host "  |   SECURE BOOT 2026 DASHBOARD - UNINSTALL               |" -ForegroundColor Magenta
Write-Host "  +========================================================+" -ForegroundColor Magenta

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "    [ERROR] Administrator privileges are required." -ForegroundColor Red
    Write-Host "    Re-run in an ELEVATED PowerShell window." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Sect "1. DISCOVERING PORTS"

$confirmed = New-Object System.Collections.Generic.HashSet[int]
$unconfirmed = New-Object System.Collections.Generic.HashSet[int]

if ($Port.Count -gt 0) {
    foreach ($p in $Port) { [void]$confirmed.Add($p) }
    Write-Info "Using port(s) from -Port: $($Port -join ', ')"
} else {
    $configPath = Join-Path $InstallPath 'data\dashboard-config.json'
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.Port) { [void]$confirmed.Add([int]$cfg.Port); Write-Ok "Config file: port $($cfg.Port) (installed $($cfg.InstalledAt))" }
        } catch { Write-Warn2 "Config file present but unreadable: $configPath" }
    } else {
        Write-Info "No config file at $configPath"
    }

    $rules = Get-NetFirewallRule -DisplayName "Secure Boot 2026 Dashboard (TCP *" -ErrorAction SilentlyContinue
    foreach ($r in $rules) {
        if ($r.DisplayName -match 'TCP (\d+)\)') {
            [void]$confirmed.Add([int]$Matches[1])
            Write-Ok "Firewall rule: port $($Matches[1])"
        }
    }

    $aclText = netsh http show urlacl | Out-String
    foreach ($m in [regex]::Matches($aclText, 'http://[+*]:(\d+)/')) {
        $p = [int]$m.Groups[1].Value
        if ($p -ge $ScanFrom -and $p -le $ScanTo -and -not $confirmed.Contains($p)) {
            if ($unconfirmed.Add($p)) { Write-Warn2 "URL ACL reservation on port $p - ownership NOT confirmed" }
        }
    }
}

if ($unconfirmed.Count -gt 0) {
    Write-Host ""
    Write-Warn2 "These ports have a reservation in range but no dashboard config or firewall rule:"
    Write-Host  "           $((@($unconfirmed) | Sort-Object) -join ', ')" -ForegroundColor Yellow
    Write-Host ""
    if ($Force) {
        Write-Warn2 "-Force specified: including them."
        foreach ($p in @($unconfirmed)) { [void]$confirmed.Add($p) }
    } else {
        $answer = Read-Host "  Include these ports in cleanup? [y/N]"
        if ($answer -match '^(y|yes)$') {
            foreach ($p in @($unconfirmed)) { [void]$confirmed.Add($p) }
        } else {
            Write-Info "Leaving unconfirmed reservations in place."
        }
    }
}

if ($confirmed.Count -eq 0) {
    Write-Warn2 "No dashboard ports identified - nothing to clean up."
    Write-Info  "If you know the port, re-run with -Port <n>."
    $portList = @()
} else {
    $portList = @($confirmed) | Sort-Object
    Write-Info "Will clean up port(s): $($portList -join ', ')"
}

Write-Sect "2. SCHEDULED TASKS"
foreach ($name in @($taskName, $collectionTaskName)) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($t) {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        Write-Ok "Removed scheduled task: $name"
    } else {
        Write-Info "Task not present: $name"
    }
}

Write-Sect "3. RUNNING PROCESSES"
$procs = Get-WmiObject Win32_Process -Filter "Name='powershell.exe' AND (CommandLine LIKE '%Start-DashboardWebServer.ps1%' OR CommandLine LIKE '%Collect-SecureBootDashboardData.ps1%')" -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Ok "Stopped dashboard process (PID $($p.ProcessId))"
    }
} else {
    Write-Info "No dashboard processes running"
}

Start-Sleep -Seconds 2

$listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
foreach ($p in $portList) {
    if ($listeners | Where-Object { $_.Port -eq $p }) {
        Write-Warn2 "Port $p is STILL in use after cleanup - an orphan listener not started by this dashboard"
        Write-Host  "           Identify it with: netstat -ano | findstr :$p" -ForegroundColor Yellow
    }
}

Write-Sect "4. URL ACL RESERVATIONS"
foreach ($p in $portList) {
    foreach ($form in @("http://+:$p/", "http://*:$p/")) {
        $existing = netsh http show urlacl url=$form | Out-String
        if ($existing -match 'Reserved URL') {
            netsh http delete urlacl url=$form | Out-Null
            Write-Ok "Removed URL ACL: $form"
        }
    }
}

Write-Sect "5. FIREWALL RULES"
$allRules = Get-NetFirewallRule -DisplayName "Secure Boot 2026 Dashboard (TCP *" -ErrorAction SilentlyContinue
if ($allRules) {
    foreach ($r in $allRules) {
        Remove-NetFirewallRule -DisplayName $r.DisplayName -ErrorAction SilentlyContinue
        Write-Ok "Removed firewall rule: $($r.DisplayName)"
    }
} else {
    Write-Info "No dashboard firewall rules found"
}

Write-Sect "6. FILES"
if ($RemoveFiles) {
    if (Test-Path $InstallPath) {
        Remove-Item -Path $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $InstallPath) { Write-Warn2 "Could not fully remove $InstallPath" } else { Write-Ok "Removed $InstallPath" }
    }
} else {
    Write-Info "Files left in place at $InstallPath (use -RemoveFiles to delete)"
}

Write-Host ""
Write-Host "  +--------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  UNINSTALL COMPLETE                                    |" -ForegroundColor Green
Write-Host "  +--------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host ("  Ports cleaned: {0}" -f ($portList -join ', '))
Write-Host ""
