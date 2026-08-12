[CmdletBinding()]
param(
    [int]$EventLookbackDays = 30
)
$SvcPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
$Status = $null
$ErrorCode = $null
try { $Status = (Get-ItemProperty -Path $SvcPath -Name 'UEFICA2023Status' -ErrorAction Stop).UEFICA2023Status } catch {}
try { $ErrorCode = (Get-ItemProperty -Path $SvcPath -Name 'UEFICA2023Error' -ErrorAction Stop).UEFICA2023Error } catch {}

if ($Status -eq 'Updated' -and ($null -eq $ErrorCode -or [int64]$ErrorCode -eq 0)) {
    Write-Output 'Compliant'
    exit 0
}

if ($null -eq $Status) {
    $start = (Get-Date).AddDays(-1 * [Math]::Abs($EventLookbackDays))
    try {
        $event1808 = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-TPM-WMI'; Id=1808; StartTime=$start } -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        $event1808 = $null
    }

    if ($event1808) {
        Write-Output 'Compliant'
        exit 0
    }
}

Write-Output 'NonCompliant'
exit 0

