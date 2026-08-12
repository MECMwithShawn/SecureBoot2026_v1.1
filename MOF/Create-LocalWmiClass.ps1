<#
.SYNOPSIS
Creates the local WMI class root\cimv2\EWAN_SecureBoot2026Discovery on endpoints.
.DESCRIPTION
Run once on endpoints via MECM or as part of the inventory script pre-req to ensure
WMI schema exists before writing instance properties.
#>
[CmdletBinding()]
param()

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

$tempMof = Join-Path $env:TEMP 'EWAN_SecureBoot2026Discovery.mof'
Set-Content -Path $tempMof -Value $mofContent -Encoding ASCII

try {
    $result = mofcomp.exe $tempMof
    Write-Host "MOF Compilation Output: $result"
    Write-Host "Successfully compiled local WMI class EWAN_SecureBoot2026Discovery"
}
catch {
    Write-Error "Failed to compile MOF: $($_.Exception.Message)"
}
finally {
    Remove-Item -Path $tempMof -Force -ErrorAction SilentlyContinue
}
