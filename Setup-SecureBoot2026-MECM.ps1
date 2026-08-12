#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SiteCode = '',
    [string]$SourcePath = '',
    [switch]$SkipMofCheck,
    [switch]$SkipFileCopy
)

$ErrorActionPreference = 'Stop'

function Write-SetupLog {
    param([string]$Message, [string]$Level = 'INFO')
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) { 'SUCCESS' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$time] [$Level] $Message" -ForegroundColor $color
}

Write-SetupLog 'Starting MECM Secure Boot 2026 Provisioning Script.'

$prodUncRoot    = '\\nedvap6e9b5\d$\Software\Microsoft\Secure Boot'
$prodUncScripts = '\\nedvap6e9b5\d$\Software\Microsoft\Secure Boot\Scripts'
$devUncRoot     = '\\nedvap94f54\d$\Software\Microsoft\Secure Boot'
$devUncScripts  = '\\nedvap94f54\d$\Software\Microsoft\Secure Boot\Scripts'
$localScripts   = Join-Path $PSScriptRoot 'Scripts'

$targetShareRoot = $null
if (Test-Path '\\nedvap6e9b5\d$\Software\Microsoft') {
    $targetShareRoot = $prodUncRoot
}
elseif (Test-Path '\\nedvap94f54\d$\Software\Microsoft') {
    $targetShareRoot = $devUncRoot
}

if (-not $SkipFileCopy -and $targetShareRoot) {
    try {
        Write-SetupLog "Auto-syncing package files to network share: $targetShareRoot" 'INFO'
        
        $targetMofDir     = Join-Path $targetShareRoot 'MOF'
        $targetDashDir    = Join-Path $targetShareRoot 'Dashboard'
        $targetQueriesDir = Join-Path $targetShareRoot 'MECM_Queries'
        $pkgDiscoveryDir  = Join-Path $targetShareRoot 'Packages\Discovery'
        $pkgTriggerDir    = Join-Path $targetShareRoot 'Packages\Trigger'

        foreach ($dir in @($targetShareRoot, $targetMofDir, $targetDashDir, $targetQueriesDir, $pkgDiscoveryDir, $pkgTriggerDir)) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }

        Get-ChildItem -Path $PSScriptRoot -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $targetShareRoot -Force
        }

        foreach ($subFolder in @('MOF', 'Dashboard', 'MECM_Queries', 'Documentation')) {
            $srcSub = Join-Path $PSScriptRoot $subFolder
            $destSub = Join-Path $targetShareRoot $subFolder
            if (Test-Path $srcSub) {
                if (-not (Test-Path $destSub)) { New-Item -ItemType Directory -Path $destSub -Force | Out-Null }
                Copy-Item -Path "$srcSub\*" -Destination $destSub -Recurse -Force
            }
        }

        $srcScripts = Join-Path $PSScriptRoot 'Scripts'
        if (Test-Path $srcScripts) {
            Copy-Item -Path "$srcScripts\Collect-SecureBoot2026Inventory.ps1" -Destination $pkgDiscoveryDir -Force -ErrorAction SilentlyContinue
            
            $triggerFiles = @('Install-SecureBoot2026Trigger.cmd', 'Invoke-SecureBoot2026Update.ps1', 'Firmware-Remediation-Wrapper.ps1', 'Test-SecureBoot2026Compliance.ps1')
            foreach ($file in $triggerFiles) {
                Copy-Item -Path "$srcScripts\$file" -Destination $pkgTriggerDir -Force -ErrorAction SilentlyContinue
            }
            
            Copy-Item -Path "$srcScripts\Export-SecureBoot2026Summary.ps1" -Destination $targetShareRoot -Force -ErrorAction SilentlyContinue
        }

        Write-SetupLog "Successfully auto-populated network package share: $targetShareRoot" 'SUCCESS'
    }
    catch {
        Write-SetupLog "Note during network file copy: $($_.Exception.Message)" 'WARN'
    }
}

$DiscoveryPkgPath = $null
$TriggerPkgPath = $null

if ($targetShareRoot) {
    $DiscoveryPkgPath = Join-Path $targetShareRoot 'Packages\Discovery'
    $TriggerPkgPath   = Join-Path $targetShareRoot 'Packages\Trigger'
    Write-SetupLog "Using Network Share for Packages: $targetShareRoot\Packages" 'SUCCESS'
}
else {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        if (Test-Path $localScripts) {
            $SourcePath = $localScripts
            Write-SetupLog "Using local Scripts folder as Package Source: $SourcePath" 'INFO'
        }
        else {
            $SourcePath = $PSScriptRoot
        }
    }
    $DiscoveryPkgPath = $SourcePath
    $TriggerPkgPath   = $SourcePath
    Write-SetupLog "Using Fallback Path for Packages: $SourcePath" 'WARN'
}

$candidateModulePaths = @(
    "$env:SMS_ADMIN_UI_PATH\ConfigurationManager.psd1",
    "D:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
    "D:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
    "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
    "C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
    "E:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
)

try {
    $regDir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'UI Installation Directory' -ErrorAction SilentlyContinue).'UI Installation Directory'
    if ($regDir) {
        $candidateModulePaths = @(Join-Path $regDir 'bin\ConfigurationManager.psd1') + $candidateModulePaths
    }
} catch {}

$modulePath = $null
foreach ($path in $candidateModulePaths) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
        $modulePath = $path
        break
    }
}

if (-not $modulePath) {
    $cmModule = Get-Module ConfigurationManager -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmModule) {
        $modulePath = $cmModule.Path
    }
}

if (-not $modulePath -or -not (Test-Path $modulePath)) {
    Write-SetupLog "MECM Admin Console module not found." 'ERROR'
    exit 2
}

Write-SetupLog "Detected Admin Console Module at: $modulePath" 'SUCCESS'
Import-Module $modulePath -ErrorAction Stop
$CMPSSuppressFastNotUsedCheck = $true

if ([string]::IsNullOrWhiteSpace($SiteCode)) {
    try {
        $provider = Get-CimInstance -Namespace 'root\sms' -ClassName 'SMS_ProviderLocation' -ErrorAction Stop | Select-Object -First 1
        if ($provider -and $provider.SiteCode) {
            $SiteCode = $provider.SiteCode
            Write-SetupLog "Detected MECM Site Code: $SiteCode" 'SUCCESS'
        }
        else {
            $SiteCode = 'RTX'
            Write-SetupLog "Provider location returned empty site code. Defaulting to Site Code: $SiteCode" 'WARN'
        }
    }
    catch {
        $SiteCode = 'RTX'
        Write-SetupLog "Could not auto-detect site code via CIM. Defaulting to Site Code: $SiteCode" 'WARN'
    }
}

if (-not $SkipMofCheck) {
    $mofClass = Get-CimClass -Namespace "root\sms\site_$SiteCode" -ClassName 'SMS_G_System_EWAN_SecureBoot2026Discovery_1_0' -ErrorAction SilentlyContinue
    if (-not $mofClass) {
        Write-Host ""
        Write-Host "====================================================================================================" -ForegroundColor Yellow
        Write-Host "                              ACTION REQUIRED: HARDWARE INVENTORY MOF IMPORT                        " -ForegroundColor Yellow
        Write-Host "====================================================================================================" -ForegroundColor Yellow
        Write-Host " The custom WMI class 'SMS_G_System_EWAN_SecureBoot2026Discovery_1_0' is NOT YET imported in MECM." -ForegroundColor White
        Write-Host ""
        Write-Host " PLEASE PERFORM THIS ONE-TIME MANUAL STEP NOW IN MECM CONSOLE:" -ForegroundColor Cyan
        Write-Host " 1. Open MECM Console -> Administration -> Client Settings." -ForegroundColor White
        Write-Host " 2. Right-click 'Default Client Settings' -> Properties -> Hardware Inventory -> Set Classes..." -ForegroundColor White
        Write-Host " 3. Click 'Import...' -> Select file: MOF\SecureBoot2026_HardwareInventory.mof" -ForegroundColor White
        Write-Host " 4. Click 'Import' -> 'OK' -> 'OK'." -ForegroundColor White
        Write-Host "====================================================================================================" -ForegroundColor Yellow
        Write-Host ""
        $mofPath = Join-Path $PSScriptRoot 'MOF\SecureBoot2026_HardwareInventory.mof'
        if (Test-Path $mofPath) {
            Write-Host " MOF File Path: $mofPath" -ForegroundColor Green
            Write-Host ""
        }
        $null = Read-Host " Once imported in MECM Console, press [ENTER] to continue script execution..."
        Write-SetupLog "Resuming MECM setup after user confirmed MOF import." 'INFO'
    } else {
        Write-SetupLog "Hardware Inventory MOF Class 'SMS_G_System_EWAN_SecureBoot2026Discovery_1_0' verified in Site Provider." 'SUCCESS'
    }
}

$siteDrive = "$($SiteCode):"
if (-not (Test-Path $siteDrive)) {
    Write-SetupLog "MECM PSDrive $siteDrive is not accessible." 'ERROR'
    exit 3
}

Set-Location $siteDrive
Write-SetupLog "Connected to MECM Provider Drive: $siteDrive" 'SUCCESS'

$folderName = 'Secure Boot 2026'
$parentFolderPath = "$siteDrive\DeviceCollection"

try {
    $existingFolder = Get-Item "$parentFolderPath\$folderName" -ErrorAction SilentlyContinue
    if (-not $existingFolder) {
        New-Item -Path $parentFolderPath -Name $folderName -ItemType Directory | Out-Null
        Write-SetupLog "Created Device Collection Folder: \$folderName" 'SUCCESS'
    } else {
        Write-SetupLog "Device Collection Folder '\$folderName' already exists." 'INFO'
    }
}
catch {
    Write-SetupLog "Note on folder creation: $($_.Exception.Message)" 'WARN'
}

$collections = @(
    @{
        Name = 'Secure Boot 2026 - Discovery - All Windows Endpoints'
        Comment = 'All Windows 10 and 11 endpoints in scope for Secure Boot 2026 discovery.'
        Limiting = 'All Systems'
        Wql = 'select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_OPERATING_SYSTEM on SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceID where SMS_G_System_OPERATING_SYSTEM.Caption like "%Windows 10%" or SMS_G_System_OPERATING_SYSTEM.Caption like "%Windows 11%"'
    },
    @{
        Name = 'Secure Boot 2026 - Discovery - Servers'
        Comment = 'Windows Server endpoints requiring separate maintenance windows and pilot validation.'
        Limiting = 'All Systems'
        Wql = 'select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_OPERATING_SYSTEM on SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceID where SMS_G_System_OPERATING_SYSTEM.Caption like "%Server%"'
    },
    @{
        Name = 'Secure Boot 2026 - Pilot Candidate - Model Representatives'
        Comment = 'Target cohort of representative hardware models ready for Secure Boot 2026 pilot testing.'
        Limiting = 'Secure Boot 2026 - Discovery - All Windows Endpoints'
        Wql = "select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_EWAN_SecureBoot2026Discovery_1_0 on SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.ResourceID = SMS_R_System.ResourceID where SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.StatusCategory = 'ReadyForPilotReview'"
    },
    @{
        Name = 'Secure Boot 2026 - Complete'
        Comment = 'Endpoints that have completed the 2023 Secure Boot CA transition (UEFICA2023Status = Updated).'
        Limiting = 'All Systems'
        Wql = "select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_EWAN_SecureBoot2026Discovery_1_0 on SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.ResourceID = SMS_R_System.ResourceID where SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.UEFICA2023Status = 'Updated' or SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.StatusCategory = 'Complete'"
    },
    @{
        Name = 'Secure Boot 2026 - Hold - Legacy BIOS or Secure Boot Disabled'
        Comment = 'Endpoints running legacy BIOS or with Secure Boot disabled in firmware.'
        Limiting = 'All Systems'
        Wql = "select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_EWAN_SecureBoot2026Discovery_1_0 on SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.ResourceID = SMS_R_System.ResourceID where SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.SecureBootEnabled = 'False' or SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.StatusCategory = 'SecureBootDisabledOrLegacy'"
    },
    @{
        Name = 'Secure Boot 2026 - Hold - Firmware Review Required'
        Comment = 'Endpoints with UEFICA2023Error or firmware blockers requiring OEM BIOS updates.'
        Limiting = 'All Systems'
        Wql = "select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_EWAN_SecureBoot2026Discovery_1_0 on SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.ResourceID = SMS_R_System.ResourceID where SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.StatusCategory = 'NeedsFirmwareReview' or (SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.UEFICA2023ErrorHex not in ('', '0x0000'))"
    },
    @{
        Name = 'Secure Boot 2026 - Hold - BitLocker Review Required'
        Comment = 'Endpoints with Event 1032 BitLocker risk requiring recovery key escrow validation.'
        Limiting = 'All Systems'
        Wql = "select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_EWAN_SecureBoot2026Discovery_1_0 on SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.ResourceID = SMS_R_System.ResourceID where SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.StatusCategory = 'NeedsBitLockerReview'"
    },
    @{
        Name = 'Secure Boot 2026 - Hold - OS Review Required'
        Comment = 'Endpoints missing prerequisite Windows cumulative updates (LCU/ESU gap).'
        Limiting = 'All Systems'
        Wql = "select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System inner join SMS_G_System_EWAN_SecureBoot2026Discovery_1_0 on SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.ResourceID = SMS_R_System.ResourceID where SMS_G_System_EWAN_SecureBoot2026Discovery_1_0.StatusCategory = 'NeedsOSReview'"
    },
    @{
        Name = 'Secure Boot 2026 - Deployment - Wave 0 (Lab & IT Test)'
        Comment = 'Initial test ring containing lab devices and IT test endpoints for trigger validation.'
        Limiting = 'Secure Boot 2026 - Pilot Candidate - Model Representatives'
        Wql = ''
    },
    @{
        Name = 'Secure Boot 2026 - Deployment - Wave 1 (Pilot 5%)'
        Comment = 'Pilot wave containing 5% of representative enterprise hardware models.'
        Limiting = 'Secure Boot 2026 - Pilot Candidate - Model Representatives'
        Wql = ''
    },
    @{
        Name = 'Secure Boot 2026 - Deployment - Wave 2 (Production 25%)'
        Comment = 'Production Wave 2 targeting 25% of validated enterprise endpoints.'
        Limiting = 'Secure Boot 2026 - Discovery - All Windows Endpoints'
        Wql = ''
    },
    @{
        Name = 'Secure Boot 2026 - Deployment - Wave 3 (Production 50%)'
        Comment = 'Production Wave 3 targeting 50% of validated enterprise endpoints.'
        Limiting = 'Secure Boot 2026 - Discovery - All Windows Endpoints'
        Wql = ''
    },
    @{
        Name = 'Secure Boot 2026 - Deployment - Wave 4 (Production 100% Remaining)'
        Comment = 'Final Production Wave 4 targeting all remaining eligible enterprise endpoints.'
        Limiting = 'Secure Boot 2026 - Discovery - All Windows Endpoints'
        Wql = ''
    }
)

foreach ($c in $collections) {
    try {
        $col = Get-CMDeviceCollection -Name $c.Name -ErrorAction SilentlyContinue
        if (-not $col) {
            $col = New-CMDeviceCollection -Name $c.Name -LimitingCollectionName $c.Limiting -Comment $c.Comment -RefreshType Continuous
            Write-SetupLog "Created Device Collection: $($c.Name)" 'SUCCESS'
        } else {
            Write-SetupLog "Device Collection already exists: $($c.Name)" 'INFO'
        }

        Move-CMObject -FolderPath "$parentFolderPath\$folderName" -InputObject $col -ErrorAction SilentlyContinue

        if (-not [string]::IsNullOrWhiteSpace($c.Wql)) {
            $ruleName = "$($c.Name) Query Rule"
            $existingRule = Get-CMDeviceCollectionQueryMembershipRule -CollectionName $c.Name -RuleName $ruleName -ErrorAction SilentlyContinue
            if (-not $existingRule) {
                try {
                    Add-CMDeviceCollectionQueryMembershipRule -CollectionName $c.Name -RuleName $ruleName -QueryExpression $c.Wql -ErrorAction Stop | Out-Null
                    Write-SetupLog "Added WQL Query Rule to collection: $($c.Name)" 'SUCCESS'
                }
                catch {
                    Write-SetupLog "WQL Query rule skipped for '$($c.Name)': $($_.Exception.Message)" 'WARN'
                }
            } else {
                Write-SetupLog "WQL Query Rule already exists on: $($c.Name)" 'INFO'
            }
        }
    }
    catch {
        Write-SetupLog "Note on collection '$($c.Name)': $($_.Exception.Message)" 'WARN'
    }
}

Write-SetupLog "Configuring MECM Packages pointing to source: $SourcePath"

$pkg1Name = 'Secure Boot 2026 - Discovery Inventory'
try {
    $pkg1 = Get-CMPackage -Name $pkg1Name -Fast -ErrorAction SilentlyContinue
    if (-not $pkg1) {
        $pkg1 = New-CMPackage -Name $pkg1Name -Path $DiscoveryPkgPath -Description 'Collects Secure Boot 2026 readiness data and populates local WMI for Hardware Inventory.' -Manufacturer 'Microsoft/eWAN'
        Write-SetupLog "Created Package: $pkg1Name" 'SUCCESS'
    } else {
        Write-SetupLog "Package already exists: $pkg1Name" 'INFO'
    }

    $prog1Name = 'Run Discovery & Populate WMI'
    $prog1 = Get-CMProgram -PackageId $pkg1.PackageID -ErrorAction SilentlyContinue | Where-Object { $_.ProgramName -eq $prog1Name }
    if (-not $prog1) {
        New-CMProgram -PackageId $pkg1.PackageID -StandardProgramName $prog1Name -CommandLine 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Collect-SecureBoot2026Inventory.ps1 -PopulateLocalWmi' -ProgramRunType WhetherOrNotUserIsLoggedOn -UserInteraction $false | Out-Null
        Write-SetupLog "Created Program '$prog1Name' for Package '$pkg1Name'" 'SUCCESS'
    } else {
        Write-SetupLog "Program '$prog1Name' already exists." 'INFO'
    }
}
catch {
    Write-SetupLog "Error creating Package 1: $($_.Exception.Message)" 'WARN'
}

$pkg2Name = 'Secure Boot 2026 - Certificate Update Trigger'
try {
    $pkg2 = Get-CMPackage -Name $pkg2Name -Fast -ErrorAction SilentlyContinue
    if (-not $pkg2) {
        $pkg2 = New-CMPackage -Name $pkg2Name -Path $TriggerPkgPath -Description 'Triggers Secure Boot 2026 certificate deployment (AvailableUpdates = 0x5944).' -Manufacturer 'Microsoft/eWAN'
        Write-SetupLog "Created Package: $pkg2Name" 'SUCCESS'
    } else {
        Write-SetupLog "Package already exists: $pkg2Name" 'INFO'
    }

    $prog2Name = 'Trigger Secure Boot Update'
    $prog2 = Get-CMProgram -PackageId $pkg2.PackageID -ErrorAction SilentlyContinue | Where-Object { $_.ProgramName -eq $prog2Name }
    if (-not $prog2) {
        New-CMProgram -PackageId $pkg2.PackageID -StandardProgramName $prog2Name -CommandLine 'Install-SecureBoot2026Trigger.cmd' -ProgramRunType WhetherOrNotUserIsLoggedOn -UserInteraction $false | Out-Null
        Write-SetupLog "Created Program '$prog2Name' for Package '$pkg2Name'" 'SUCCESS'
    } else {
        Write-SetupLog "Program '$prog2Name' already exists." 'INFO'
    }
}
catch {
    Write-SetupLog "Error creating Package 2: $($_.Exception.Message)" 'WARN'
}

Set-Location C:
Write-SetupLog 'MECM Setup Complete. All Collections and Packages are provisioned.' 'SUCCESS'

Write-Host ""
Write-Host "====================================================================================================" -ForegroundColor Yellow
Write-Host "                                   NEXT OPERATIONAL STEPS REQUIRED                                  " -ForegroundColor Yellow
Write-Host "====================================================================================================" -ForegroundColor Yellow
Write-Host "1. Deploy Discovery Package:" -ForegroundColor Cyan
Write-Host "   Deploy 'Secure Boot 2026 - Discovery Inventory' to 'Secure Boot 2026 - Discovery - All Windows Endpoints'." -ForegroundColor White
Write-Host ""
Write-Host "2. Target Wave 0 Test:" -ForegroundColor Cyan
Write-Host "   Add test devices to 'Secure Boot 2026 - Deployment - Wave 0 (Lab & IT Test)' and deploy" -ForegroundColor White
Write-Host "   'Secure Boot 2026 - Certificate Update Trigger' to Wave 0." -ForegroundColor White
Write-Host ""
Write-Host "3. Monitor Compliance:" -ForegroundColor Cyan
Write-Host "   Run 'Setup-SecureBootDashboard.ps1' to install the Web Service." -ForegroundColor White
Write-Host "====================================================================================================" -ForegroundColor Yellow
Write-Host ""
