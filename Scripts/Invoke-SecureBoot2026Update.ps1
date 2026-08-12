[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidatePattern('^0x[0-9A-Fa-f]+$')]
    [string]$TriggerValueHex = '0x5944',
    [switch]$RunTask,
    [switch]$RequireSecureBootEnabled = $true,
    [switch]$AllowExistingError,
    [switch]$Force,
    [string]$LogDir = 'C:\Windows\Temp\SecureBoot2026'
)
$ErrorActionPreference = 'Stop'
$RegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
$SvcPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
$TaskPath = '\Microsoft\Windows\PI\'
$TaskName = 'Secure-Boot-Update'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir 'Invoke-SecureBoot2026Update.log'

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Output $line
}

function Get-RegValue {
    param([string]$Path,[string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { return $null }
}

function Format-HexValue {
    param($Value)
    if ($null -eq $Value) { return '0x0000' }
    try { return ('0x{0:X4}' -f [int64]$Value) }
    catch { return [string]$Value }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Log 'ERROR: Script must run elevated or as Local System.'
    exit 5
}

$secureBootEnabled = $false
try {
    $secureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
}
catch {
    Write-Log "Secure Boot state could not be confirmed: $($_.Exception.Message)"
}

if ($RequireSecureBootEnabled -and -not $secureBootEnabled) {
    Write-Log 'Secure Boot is disabled, legacy BIOS, unsupported, or access was denied. No update triggered.'
    exit 10
}

$triggerValue = [Convert]::ToInt32($TriggerValueHex,16)
$currentStatus = Get-RegValue -Path $SvcPath -Name 'UEFICA2023Status'
$currentError = Get-RegValue -Path $SvcPath -Name 'UEFICA2023Error'
$currentAvailable = Get-RegValue -Path $RegPath -Name 'AvailableUpdates'

Write-Log "Starting Secure Boot trigger. CurrentStatus=$currentStatus CurrentError=$currentError CurrentAvailable=$(Format-HexValue $currentAvailable)"

if ($currentStatus -eq 'Updated') {
    Write-Log 'Device already reports UEFICA2023Status=Updated. No trigger needed.'
    exit 0
}

if (-not $Force -and $null -ne $currentAvailable -and [int64]$currentAvailable -ne 0) {
    Write-Log "Device AvailableUpdates is already non-zero ($(Format-HexValue $currentAvailable)). Mid-sequence processing active. No re-trigger needed."
    exit 0
}

try {
    $preflightTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
}
catch {
    Write-Log 'ERROR: Secure-Boot-Update task is missing. Install prerequisite Windows cumulative update.'
    exit 12
}

if ($preflightTask.State -eq 'Disabled') {
    Write-Log 'ERROR: Secure-Boot-Update task is disabled.'
    exit 20
}

if (-not $AllowExistingError -and $null -ne $currentError -and [int64]$currentError -ne 0) {
    Write-Log 'ERROR: An existing non-zero UEFICA2023Error is present.'
    exit 11
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Set AvailableUpdates to $TriggerValueHex")) {
    New-Item -Path $RegPath -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name 'AvailableUpdates' -PropertyType DWord -Value $triggerValue -Force | Out-Null
    Write-Log "Set AvailableUpdates to $TriggerValueHex."
}

if ($RunTask) {
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        if ($task.State -eq 'Disabled') {
            Write-Log 'Secure-Boot-Update task exists but is disabled.'
            exit 20
        }
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Start Secure-Boot-Update scheduled task')) {
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
            Write-Log 'Started Secure-Boot-Update scheduled task.'
        }
    }
    catch {
        Write-Log "ERROR: Unable to start scheduled task $TaskPath$TaskName. $($_.Exception.Message)"
        exit 21
    }
}
else {
    Write-Log 'RunTask not specified. Task will run on schedule.'
}

Start-Sleep -Seconds 5
$newAvailable = Get-RegValue -Path $RegPath -Name 'AvailableUpdates'
$newStatus = Get-RegValue -Path $SvcPath -Name 'UEFICA2023Status'
$newError = Get-RegValue -Path $SvcPath -Name 'UEFICA2023Error'
$newErrorEvent = Get-RegValue -Path $SvcPath -Name 'UEFICA2023ErrorEvent'
Write-Log "Post-trigger state: AvailableUpdates=$(Format-HexValue $newAvailable) UEFICA2023Status=$newStatus UEFICA2023Error=$newError UEFICA2023ErrorEvent=$newErrorEvent"
exit 0

