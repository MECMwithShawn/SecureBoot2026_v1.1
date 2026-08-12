[CmdletBinding()]
param(
    [string]$OutputRoot = 'C:\Windows\Temp\SecureBoot2026',
    [string]$NetworkDrop = '',
    [int]$EventLookbackDays = 45,
    [switch]$IncludeDecodedVariables,
    [switch]$PopulateLocalWmi
)

$ErrorActionPreference = 'Continue'
$ComputerName = $env:COMPUTERNAME
$Now = Get-Date
$Stamp = $Now.ToString('yyyyMMdd-HHmmss')
$RegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
$SvcPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
$TaskPath = '\Microsoft\Windows\PI\'
$TaskName = 'Secure-Boot-Update'
$EventIds = @(1032,1042,1043,1044,1045,1795,1796,1797,1798,1799,1800,1801,1802,1803,1808)

try {
    New-Item -ItemType Directory -Path $OutputRoot -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Failed to create OutputRoot '$OutputRoot': $($_.Exception.Message)"
    exit 1
}
$LogFile = Join-Path $OutputRoot "Collect-SecureBoot2026Inventory.log"

try {
    Get-ChildItem -Path $OutputRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $Now.AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    }
    catch {
        return $null
    }
}

function Format-HexValue {
    param($Value)
    if ($null -eq $Value) { return '0x0000' }
    try { return ('0x{0:X4}' -f [int64]$Value) }
    catch { return [string]$Value }
}

function Get-SecureBootEnabledState {
    try {
        $enabled = Confirm-SecureBootUEFI -ErrorAction Stop
        return [pscustomobject]@{
            SecureBootEnabled = [bool]$enabled
            SecureBootState = $(if ($enabled) { 'Enabled' } else { 'Disabled' })
            SecureBootError = $null
        }
    }
    catch {
        return [pscustomobject]@{
            SecureBootEnabled = $false
            SecureBootState = 'LegacyOrUnsupportedOrAccessDenied'
            SecureBootError = $_.Exception.Message
        }
    }
}

function Get-SecureBootDecodedVariableText {
    param([string]$Name)
    try {
        $cmd = Get-Command Get-SecureBootUEFI -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Parameters.ContainsKey('Decoded')) {
            return ((Get-SecureBootUEFI -Name $Name -Decoded -ErrorAction Stop) | Out-String).Trim()
        }
        else {
            return 'Get-SecureBootUEFI -Decoded is not available on this OS build.'
        }
    }
    catch {
        return "Unable to read ${Name}: $($_.Exception.Message)"
    }
}

function Get-SecureBootTaskInfo {
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        return [pscustomobject]@{
            Exists = $true
            State = [string]$task.State
            LastRunTime = $info.LastRunTime
            LastTaskResult = $info.LastTaskResult
            NextRunTime = $info.NextRunTime
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $false
            State = $null
            LastRunTime = $null
            LastTaskResult = $null
            NextRunTime = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-BitLockerOsState {
    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
            return [pscustomobject]@{
                ProtectionStatus = [string]$vol.ProtectionStatus
                VolumeStatus = [string]$vol.VolumeStatus
                EncryptionPercentage = $vol.EncryptionPercentage
                KeyProtectorTypes = (($vol.KeyProtector | ForEach-Object { $_.KeyProtectorType }) -join ';')
            }
        }
        else {
            return [pscustomobject]@{ ProtectionStatus = 'BitLockerCmdletsUnavailable' }
        }
    }
    catch {
        return [pscustomobject]@{ ProtectionStatus = 'Unknown'; Error = $_.Exception.Message }
    }
}

function Get-TpmStateSafe {
    try {
        if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
            $tpm = Get-Tpm
            return [pscustomobject]@{
                TpmPresent = $tpm.TpmPresent
                TpmReady = $tpm.TpmReady
                TpmEnabled = $tpm.TpmEnabled
                TpmActivated = $tpm.TpmActivated
                ManufacturerIdTxt = $tpm.ManufacturerIdTxt
            }
        }
        else {
            return [pscustomobject]@{ TpmPresent = $null; Status = 'Get-Tpm unavailable' }
        }
    }
    catch {
        return [pscustomobject]@{ TpmPresent = $null; Error = $_.Exception.Message }
    }
}

Write-Log 'Starting Secure Boot 2026 inventory collection.'
$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$sb = Get-SecureBootEnabledState
$taskInfo = Get-SecureBootTaskInfo
$bitlocker = Get-BitLockerOsState
$tpm = Get-TpmStateSafe

$availableUpdates = Get-RegValue -Path $RegPath -Name 'AvailableUpdates'
$highConfidenceOptOut = Get-RegValue -Path $RegPath -Name 'HighConfidenceOptOut'
$msManagedOptIn = Get-RegValue -Path $RegPath -Name 'MicrosoftUpdateManagedOptIn'
$availableUpdatesPolicy = Get-RegValue -Path $RegPath -Name 'AvailableUpdatesPolicy'

$status = Get-RegValue -Path $SvcPath -Name 'UEFICA2023Status'
$errorCode = Get-RegValue -Path $SvcPath -Name 'UEFICA2023Error'
$errorEvent = Get-RegValue -Path $SvcPath -Name 'UEFICA2023ErrorEvent'
$capable = Get-RegValue -Path $SvcPath -Name 'WindowsUEFICA2023Capable'
$bucketHash = Get-RegValue -Path $SvcPath -Name 'BucketHash'
$confidenceLevel = Get-RegValue -Path $SvcPath -Name 'ConfidenceLevel'

$start = (Get-Date).AddDays(-1 * [Math]::Abs($EventLookbackDays))
try {
    $events = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-TPM-WMI'; Id=$EventIds; StartTime=$start } -ErrorAction Stop |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 50 TimeCreated, Id, ProviderName, LevelDisplayName, Message
}
catch {
    $events = @()
}

$has1808 = $false
$has1801 = $false
$hasFirmwareError = $false
$hasBitLockerBlock = $false
if ($events) {
    $has1808 = [bool]($events | Where-Object { $_.Id -eq 1808 } | Select-Object -First 1)
    $has1801 = [bool]($events | Where-Object { $_.Id -eq 1801 } | Select-Object -First 1)
    $hasFirmwareError = [bool]($events | Where-Object { $_.Id -in 1795,1796,1802,1803 } | Select-Object -First 1)
    $hasBitLockerBlock = [bool]($events | Where-Object { $_.Id -eq 1032 } | Select-Object -First 1)
}

$statusCategory = 'UnknownNoData'
if (-not $taskInfo.Exists -and $null -eq $status -and $null -eq $availableUpdates) {
    $statusCategory = 'NeedsOSReview'
}
elseif ($status -eq 'Updated' -or $has1808) {
    $statusCategory = 'Complete'
}
elseif (-not $sb.SecureBootEnabled) {
    $statusCategory = 'SecureBootDisabledOrLegacy'
}
elseif ($hasBitLockerBlock) {
    $statusCategory = 'NeedsBitLockerReview'
}
elseif (($null -ne $errorCode -and [int64]$errorCode -ne 0) -or $hasFirmwareError) {
    $statusCategory = 'NeedsFirmwareReview'
}
elseif ($status -eq 'InProgress' -or ($null -ne $availableUpdates -and [int64]$availableUpdates -ne 0)) {
    $statusCategory = 'InProgress'
}
elseif ($status -eq 'NotStarted' -or $has1801) {
    $statusCategory = 'ReadyForPilotReview'
}

$latestEvent = $(if ($events) { $events | Select-Object -First 1 } else { $null })

$result = [pscustomobject]@{
    ComputerName = $ComputerName
    CollectionTime = $Now.ToString('s')
    StatusCategory = $statusCategory
    RecommendedNextStep = switch ($statusCategory) {
        'Complete' { 'Retain evidence and monitor.' }
        'ReadyForPilotReview' { 'Select representative pilot devices.' }
        'InProgress' { 'Review task, restart, and servicing state.' }
        'NeedsBitLockerReview' { 'Validate recovery-key access and BitLocker suspension.' }
        'NeedsFirmwareReview' { 'Review OEM firmware guidance.' }
        'NeedsOSReview' { 'Deploy prerequisite Windows cumulative update (LCU/ESU).' }
        'SecureBootDisabledOrLegacy' { 'Review UEFI/GPT/Secure Boot enablement or exception handling.' }
        default { 'Validate missing data, OS support, and local logs.' }
    }
    SecureBootEnabled = $sb.SecureBootEnabled
    SecureBootState = $sb.SecureBootState
    SecureBootError = $sb.SecureBootError
    Manufacturer = $cs.Manufacturer
    Model = $cs.Model
    SystemType = $cs.SystemType
    BIOSVersion = ($bios.SMBIOSBIOSVersion -join ' ')
    BIOSReleaseDate = $(if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } else { $null })
    BaseBoardManufacturer = $bb.Manufacturer
    BaseBoardProduct = $bb.Product
    OSName = $os.Caption
    OSVersion = $os.Version
    OSBuildNumber = $os.BuildNumber
    Registry = [pscustomobject]@{
        AvailableUpdates = $availableUpdates
        AvailableUpdatesHex = Format-HexValue $availableUpdates
        AvailableUpdatesPolicy = $availableUpdatesPolicy
        AvailableUpdatesPolicyHex = Format-HexValue $availableUpdatesPolicy
        HighConfidenceOptOut = $highConfidenceOptOut
        MicrosoftUpdateManagedOptIn = $msManagedOptIn
        UEFICA2023Status = $status
        UEFICA2023Error = $errorCode
        UEFICA2023ErrorHex = Format-HexValue $errorCode
        UEFICA2023ErrorEvent = $errorEvent
        WindowsUEFICA2023Capable = $capable
        BucketHash = $bucketHash
        ConfidenceLevel = $confidenceLevel
    }
    ScheduledTask = $taskInfo
    BitLockerOS = $bitlocker
    TPM = $tpm
    RecentSecureBootEvents = $events
    KEKDecoded = $(if ($IncludeDecodedVariables) { Get-SecureBootDecodedVariableText -Name 'KEK' } else { 'NotCollected' })
    DBDecoded = $(if ($IncludeDecodedVariables) { Get-SecureBootDecodedVariableText -Name 'db' } else { 'NotCollected' })
}

$jsonPath = Join-Path $OutputRoot "$ComputerName-SecureBoot2026-$Stamp.json"
$csvPath = Join-Path $OutputRoot "$ComputerName-SecureBoot2026-$Stamp.csv"
$latestPath = Join-Path $OutputRoot "$ComputerName-SecureBoot2026-latest.json"

$result | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
$result | ConvertTo-Json -Depth 8 | Out-File -FilePath $latestPath -Encoding UTF8 -Force

$result | Select-Object ComputerName,CollectionTime,StatusCategory,SecureBootEnabled,SecureBootState,Manufacturer,Model,BIOSVersion,BIOSReleaseDate,OSName,OSVersion,OSBuildNumber,@{n='UEFICA2023Status';e={$_.Registry.UEFICA2023Status}},@{n='UEFICA2023Error';e={$_.Registry.UEFICA2023Error}},@{n='AvailableUpdatesHex';e={$_.Registry.AvailableUpdatesHex}},@{n='BucketHash';e={$_.Registry.BucketHash}},@{n='ConfidenceLevel';e={$_.Registry.ConfidenceLevel}} |
    Export-Csv -Path $csvPath -NoTypeInformation -Force

if ($NetworkDrop) {
    try {
        if (Test-Path $NetworkDrop) {
            Copy-Item -Path $latestPath -Destination (Join-Path $NetworkDrop "$ComputerName-SecureBoot2026-latest.json") -Force
            Write-Log "Copied latest JSON to $NetworkDrop."
        }
        else {
            Write-Log "NetworkDrop path not reachable: $NetworkDrop"
        }
    }
    catch {
        Write-Log "Failed to copy to NetworkDrop: $($_.Exception.Message)"
    }
}

if ($PopulateLocalWmi) {
    try {
        $wmiNs = "root\cimv2"
        $className = "EWAN_SecureBoot2026Discovery"
        
        $wmiClass = Get-CimClass -Namespace $wmiNs -ClassName $className -ErrorAction SilentlyContinue
        if (-not $wmiClass) {
            Write-Log "WMI Class $className does not exist in $wmiNs. Compiling schema..."
            $mofContent = @"
#pragma namespace ("\\\\.\\root\\cimv2")

class EWAN_SecureBoot2026Discovery
{
    [key] string ComputerName;
    string CollectionTime;
    string Manufacturer;
    string Model;
    string BIOSVersion;
    string BIOSReleaseDate;
    string OSBuildNumber;
    string SecureBootEnabled;
    string UEFICA2023Status;
    string UEFICA2023ErrorHex;
    string AvailableUpdatesHex;
    string WindowsUEFICA2023Capable;
    string ConfidenceLevel;
    string BitLockerProtectionStatus;
    string LatestSecureBootEventId;
    string StatusCategory;
};
"@
            $tempMof = Join-Path $OutputRoot 'EWAN_SecureBoot2026Discovery.mof'
            Set-Content -Path $tempMof -Value $mofContent -Encoding ASCII
            $mofcompExe = "$env:SystemRoot\System32\wbem\mofcomp.exe"
            if (-not (Test-Path $mofcompExe)) { $mofcompExe = "mofcomp.exe" }
            try {
                $mofOut = & $mofcompExe -N:root\cimv2 $tempMof 2>&1 | Out-String
                Write-Log "MOF compilation output: $mofOut"
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "ERROR: mofcomp.exe failed with exit code $LASTEXITCODE"
                    exit 1
                }
            } catch {
                Write-Log "ERROR: MOF compilation failed: $($_.Exception.Message)"
                exit 1
            } finally {
                Remove-Item -Path $tempMof -Force -ErrorAction SilentlyContinue
            }
            $wmiClass = Get-CimClass -Namespace $wmiNs -ClassName $className -ErrorAction SilentlyContinue
            if (-not $wmiClass) {
                Write-Log "ERROR: WMI Class $className missing after compilation."
                exit 1
            }
        }
        
        Get-CimInstance -ClassName $className -Namespace $wmiNs -ErrorAction SilentlyContinue | Remove-CimInstance -ErrorAction SilentlyContinue
        
        $statusVal = $(if ($null -ne $status) { [string]$status } else { '' })
        $errorHexVal = Format-HexValue $errorCode
        $availHexVal = Format-HexValue $availableUpdates
        $capableVal = $(if ($null -ne $capable) { [string]$capable } else { '' })
        $confVal = $(if ($null -ne $confidenceLevel) { [string]$confidenceLevel } else { '' })
        $eventIdVal = $(if ($latestEvent) { [string]$latestEvent.Id } else { '' })

        New-CimInstance -Namespace $wmiNs -ClassName $className -Property @{
            ComputerName = [string]$ComputerName
            CollectionTime = [string]$Now.ToString('o')
            Manufacturer = [string]$cs.Manufacturer
            Model = [string]$cs.Model
            BIOSVersion = [string]($bios.SMBIOSBIOSVersion -join ' ')
            BIOSReleaseDate = [string]$bios.ReleaseDate
            OSBuildNumber = [string]$os.BuildNumber
            SecureBootEnabled = [string]$sb.SecureBootEnabled
            UEFICA2023Status = $statusVal
            UEFICA2023ErrorHex = $errorHexVal
            AvailableUpdatesHex = $availHexVal
            WindowsUEFICA2023Capable = $capableVal
            ConfidenceLevel = $confVal
            BitLockerProtectionStatus = [string]$bitlocker.ProtectionStatus
            LatestSecureBootEventId = $eventIdVal
            StatusCategory = [string]$statusCategory
        } -ErrorAction Stop | Out-Null
        Write-Log "Populated local WMI class $className."
    }
    catch {
        Write-Log "ERROR: WMI population failed: $($_.Exception.Message)"
        exit 1
    }
}

Write-Log "Completed inventory. StatusCategory=$statusCategory"
Write-Output "StatusCategory=$statusCategory"
exit 0
