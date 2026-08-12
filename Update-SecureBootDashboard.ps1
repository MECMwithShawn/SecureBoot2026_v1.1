[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\SecureBoot2026'
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot

Write-Host ""
Write-Host "  +========================================================+" -ForegroundColor Cyan
Write-Host "  |   Secure Boot 2026 Dashboard & Package - Update (v1.1) |" -ForegroundColor Cyan
Write-Host "  +========================================================+" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $repoRoot)) {
    Write-Host "  [ERROR] Source directory not found: $repoRoot" -ForegroundColor Red
    exit 1
}

Write-Host "  Source Repository: $repoRoot" -ForegroundColor DarkGray
Write-Host "  Deployed Target:   $InstallPath" -ForegroundColor DarkGray
Write-Host ""

# 1. Stop background dashboard processes if target install path exists
if (Test-Path $InstallPath) {
    Write-Host "  [1/4] STOPPING RUNNING DASHBOARD PROCESSES" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    $taskName = 'eWAN_SecureBootDashboard'
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    
    $escapedPath = [regex]::Escape($InstallPath)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $escapedPath } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
} else {
    Write-Host "  [1/4] DEPLOYMENT TARGET NOT FOUND - FRESH INSTALL PROCEEDING" -ForegroundColor Yellow
    Write-Host "  Target path $InstallPath does not exist. Creating directories..." -ForegroundColor DarkGray
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

# 2. Compare and sync release assets via SHA256 hashes
Write-Host ""
Write-Host "  [2/4] COMPARING & UPDATING RELEASE FILES (SHA256)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

$filesToSync = Get-ChildItem -Path $repoRoot -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\\.git' -and $_.Name -ne 'Update-SecureBootDashboard.ps1'
}

$updatedCount = 0
$newCount = 0
$unchangedCount = 0

foreach ($file in $filesToSync) {
    $relPath = $file.FullName.Substring($repoRoot.Length).TrimStart('\')
    $dstPath = Join-Path $InstallPath $relPath

    if (-not (Test-Path $dstPath)) {
        $dstDir = Split-Path $dstPath -Parent
        if (-not (Test-Path $dstDir)) { New-Item -Path $dstDir -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $file.FullName -Destination $dstPath -Force
        $newCount++
        Write-Host "    [NEW] $relPath" -ForegroundColor Green
        continue
    }

    $srcHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash -Path $dstPath -Algorithm SHA256).Hash

    if ($srcHash -ne $dstHash) {
        Copy-Item -Path $file.FullName -Destination $dstPath -Force
        $updatedCount++
        Write-Host "    [UPDATED] $relPath" -ForegroundColor Yellow
    } else {
        $unchangedCount++
    }
}

Write-Host ""
Write-Host "    Updated: $updatedCount  |  New: $newCount  |  Unchanged: $unchangedCount" -ForegroundColor White
Get-ChildItem $InstallPath -Recurse -Filter '*.ps1' | Unblock-File -ErrorAction SilentlyContinue

# 3. Synchronize MECM Network Package Source Share if reachable
Write-Host ""
Write-Host "  [3/4] SYNCING MECM PACKAGE SHARE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

$targetShares = @('\\nedvap6e9b5\d$\Software\Microsoft\Secure Boot', '\\nedvap94f54\d$\Software\Microsoft\Secure Boot')
foreach ($share in $targetShares) {
    if (Test-Path $share) {
        try {
            Write-Host "    Syncing latest package files to share: $share" -ForegroundColor DarkGray
            $pkgDisc = Join-Path $share 'Packages\Discovery'
            if (-not (Test-Path $pkgDisc)) { New-Item -ItemType Directory -Path $pkgDisc -Force | Out-Null }
            
            $srcInv = Join-Path $repoRoot 'Scripts\Collect-SecureBoot2026Inventory.ps1'
            if (Test-Path $srcInv) {
                Copy-Item -Path $srcInv -Destination $pkgDisc -Force
                Write-Host "    [OK] Updated $pkgDisc\Collect-SecureBoot2026Inventory.ps1" -ForegroundColor Green
            }
        } catch {
            Write-Host "    [WARN] Share sync note: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# 4. Restart Scheduled Tasks
Write-Host ""
Write-Host "  [4/4] RESTARTING BACKGROUND SERVICES & TASKS" -ForegroundColor Cyan
Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

$taskNames = @('eWAN_SecureBootDashboard', 'eWAN_SecureBootDashboard_DataCollection')
foreach ($tn in $taskNames) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if ($t) {
        if ($tn -eq 'eWAN_SecureBootDashboard_DataCollection') {
            Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 2
        } else {
            Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue | Out-Null
        }
        $info = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
        Write-Host "    [OK] Task '$tn' status: $($t.State) (Last result: $($info.LastTaskResult))" -ForegroundColor Green
    } else {
        Write-Host "    [INFO] Task '$tn' is not configured yet on this host." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  +========================================================+" -ForegroundColor Cyan
Write-Host "  |   SECURE BOOT 2026 UPDATE COMPLETE (v1.1)               |" -ForegroundColor Cyan
Write-Host "  +========================================================+" -ForegroundColor Cyan
Write-Host ""
