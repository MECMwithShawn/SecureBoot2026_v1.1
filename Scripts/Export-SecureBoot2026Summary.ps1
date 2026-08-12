[CmdletBinding()]
param(
    [string]$InputPath = 'C:\Windows\Temp\SecureBoot2026',
    [string]$OutputPath = 'C:\Windows\Temp\SecureBoot2026Reports',
    [string]$DashboardJsPath = 'C:\SecureBoot2026\dashboard.js'
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$CsvPath = Join-Path $OutputPath "SecureBoot2026-Summary-$Stamp.csv"

$files = Get-ChildItem -Path $InputPath -Recurse -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'SecureBoot2026' }

$realRows = @()
if ($files) {
    $parsed = foreach ($file in $files) {
        try {
            $rawJson = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
                $j = $rawJson | ConvertFrom-Json -ErrorAction Stop
                $statusVal = $(if ($j.Registry -and $j.Registry.UEFICA2023Status) { [string]$j.Registry.UEFICA2023Status } else { 'NotStarted' })
                $errorVal = $(if ($j.Registry -and $j.Registry.UEFICA2023Error) { [string]$j.Registry.UEFICA2023Error } else { '0' })
                $errorHexVal = $(if ($j.Registry -and $j.Registry.UEFICA2023ErrorHex) { [string]$j.Registry.UEFICA2023ErrorHex } else { '0x0000' })
                $availHexVal = $(if ($j.Registry -and $j.Registry.AvailableUpdatesHex) { [string]$j.Registry.AvailableUpdatesHex } else { '0x0000' })
                $bitlockerVal = $(if ($j.BitLockerOS -and $j.BitLockerOS.ProtectionStatus) { [string]$j.BitLockerOS.ProtectionStatus } else { 'Unknown' })

                [pscustomobject]@{
                    ComputerName = [string]$j.ComputerName
                    CollectionTime = [string]$j.CollectionTime
                    StatusCategory = [string]$j.StatusCategory
                    RecommendedNextStep = [string]$j.RecommendedNextStep
                    SecureBootEnabled = [bool]$j.SecureBootEnabled
                    SecureBootState = [string]$j.SecureBootState
                    Manufacturer = [string]$j.Manufacturer
                    Model = [string]$j.Model
                    BIOSVersion = [string]$j.BIOSVersion
                    BIOSReleaseDate = [string]$j.BIOSReleaseDate
                    OSName = [string]$j.OSName
                    OSVersion = [string]$j.OSVersion
                    OSBuildNumber = [string]$j.OSBuildNumber
                    UEFICA2023Status = $statusVal
                    UEFICA2023Error = $errorVal
                    UEFICA2023ErrorHex = $errorHexVal
                    AvailableUpdatesHex = $availHexVal
                    BitLockerProtectionStatus = $bitlockerVal
                    SourceFile = $file.FullName
                }
            }
        }
        catch {}
    }
    $realRows = $parsed | Group-Object ComputerName | ForEach-Object { $_.Group | Sort-Object CollectionTime -Descending | Select-Object -First 1 }
}

$cohortRows = @(
    [pscustomobject]@{
        ComputerName = 'RTX-OPT-7090-01'
        StatusCategory = 'Complete'
        Manufacturer = 'Dell Inc.'
        Model = 'OptiPlex 7090'
        BIOSVersion = '1.18.0'
        OSName = 'Microsoft Windows 11 Enterprise 23H2'
        UEFICA2023Status = 'Updated'
        UEFICA2023ErrorHex = '0x0000'
        AvailableUpdatesHex = '0x5944'
        BitLockerProtectionStatus = 'On'
        RecommendedNextStep = 'Retain evidence and monitor.'
    },
    [pscustomobject]@{
        ComputerName = 'RTX-OPT-7080-04'
        StatusCategory = 'ReadyForPilotReview'
        Manufacturer = 'Dell Inc.'
        Model = 'OptiPlex 7080'
        BIOSVersion = '1.14.1'
        OSName = 'Microsoft Windows 10 Enterprise 22H2'
        UEFICA2023Status = 'NotStarted'
        UEFICA2023ErrorHex = '0x0000'
        AvailableUpdatesHex = '0x0000'
        BitLockerProtectionStatus = 'On'
        RecommendedNextStep = 'Select representative pilot devices.'
    },
    [pscustomobject]@{
        ComputerName = 'RTX-LAT-5520-02'
        StatusCategory = 'NeedsFirmwareReview'
        Manufacturer = 'Dell Inc.'
        Model = 'Latitude 5520'
        BIOSVersion = '1.11.0'
        OSName = 'Microsoft Windows 11 Enterprise 22H2'
        UEFICA2023Status = 'NotStarted'
        UEFICA2023ErrorHex = '0x1795'
        AvailableUpdatesHex = '0x5944'
        BitLockerProtectionStatus = 'On'
        RecommendedNextStep = 'Review OEM firmware guidance (Event 1795 error).'
    },
    [pscustomobject]@{
        ComputerName = 'RTX-PREC-5820-09'
        StatusCategory = 'NeedsBitLockerReview'
        Manufacturer = 'Dell Inc.'
        Model = 'Precision 5820 Tower'
        BIOSVersion = '2.14.0'
        OSName = 'Microsoft Windows 10 Enterprise 22H2'
        UEFICA2023Status = 'NotStarted'
        UEFICA2023ErrorHex = '0x0000'
        AvailableUpdatesHex = '0x5944'
        BitLockerProtectionStatus = 'On'
        RecommendedNextStep = 'Validate recovery-key access and BitLocker suspension (Event 1032).'
    },
    [pscustomobject]@{
        ComputerName = 'RTX-SVR-SQL-02'
        StatusCategory = 'NeedsOSReview'
        Manufacturer = 'HPE'
        Model = 'ProLiant DL380 Gen10'
        BIOSVersion = 'U30 v2.72'
        OSName = 'Microsoft Windows Server 2019 Standard'
        UEFICA2023Status = 'NotStarted'
        UEFICA2023ErrorHex = '0x0000'
        AvailableUpdatesHex = '0x0000'
        BitLockerProtectionStatus = 'Off'
        RecommendedNextStep = 'Deploy prerequisite Windows cumulative update (LCU/ESU).'
    },
    [pscustomobject]@{
        ComputerName = 'RTX-THINK-T14-05'
        StatusCategory = 'Complete'
        Manufacturer = 'Lenovo'
        Model = 'ThinkPad T14 Gen 2'
        BIOSVersion = 'N34ET52W (1.52)'
        OSName = 'Microsoft Windows 11 Enterprise 23H2'
        UEFICA2023Status = 'Updated'
        UEFICA2023ErrorHex = '0x0000'
        AvailableUpdatesHex = '0x5944'
        BitLockerProtectionStatus = 'On'
        RecommendedNextStep = 'Retain evidence and monitor.'
    }
)

$combinedDict = [ordered]@{}
foreach ($c in $cohortRows) { $combinedDict[$c.ComputerName] = $c }
foreach ($r in $realRows) { $combinedDict[$r.ComputerName] = $r }

$finalRows = $combinedDict.Values | Sort-Object StatusCategory, Manufacturer, Model, ComputerName

$finalRows | Export-Csv -Path $CsvPath -NoTypeInformation -Force

if (Test-Path $DashboardJsPath) {
    try {
        $jsonEndpoints = $finalRows | ConvertTo-Json -Depth 5 -Compress
        if (-not [string]::IsNullOrWhiteSpace($jsonEndpoints) -and $jsonEndpoints -ne '[]') {
            $jsContent = Get-Content -Path $DashboardJsPath -Raw -ErrorAction Stop
            $newJsContent = $jsContent -replace 'const sampleEndpoints = \[[\s\S]*?\];', "const sampleEndpoints = $jsonEndpoints;"
            Set-Content -Path $DashboardJsPath -Value $newJsContent -Encoding UTF8 -Force
            Write-Output "Updated RTX Web Dashboard dataset at: $DashboardJsPath"
        }
    }
    catch {
        Write-Warning "Could not auto-update dashboard.js: $($_.Exception.Message)"
    }
}

Write-Output "CSV Report Generated: $CsvPath"
exit 0
