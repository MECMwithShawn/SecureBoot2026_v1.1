[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$BiosExe,
    [string]$Arguments = '/s',
    [string]$LogDir = 'C:\Windows\Temp\SecureBoot2026\Firmware',
    [switch]$SuspendBitLocker
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir 'Firmware-Remediation.log'

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -ErrorAction SilentlyContinue
}

if (-not (Test-IsAdmin)) {
    Write-Log 'ERROR: Script must run elevated or as Local System.'
    exit 5
}

if (-not (Test-Path $BiosExe)) {
    Write-Log "ERROR: BIOS executable not found: $BiosExe"
    exit 2
}

if ($SuspendBitLocker) {
    if (-not (Get-Command Suspend-BitLocker -ErrorAction SilentlyContinue)) {
        Write-Log 'ERROR: Suspend-BitLocker unavailable; refusing to flash with BitLocker state unknown.'
        exit 3
    }
    try {
        Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2 -ErrorAction Stop
        $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($vol.ProtectionStatus -ne 'Off') {
            Write-Log 'ERROR: BitLocker protection state is still ON after Suspend-BitLocker.'
            exit 3
        }
        Write-Log 'Suspended BitLocker for 2 reboots successfully.'
    }
    catch {
        Write-Log "ERROR: Failed to suspend BitLocker: $($_.Exception.Message)"
        exit 3
    }
}

Write-Log "Starting firmware update: $BiosExe (arguments redacted)"
$process = Start-Process -FilePath $BiosExe -ArgumentList $Arguments -Wait -PassThru
Write-Log "Firmware process exit code: $($process.ExitCode)"
exit $process.ExitCode

