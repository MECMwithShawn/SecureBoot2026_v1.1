[CmdletBinding()]
param(
    [string]$ServerName = "localhost",
    [string]$DatabaseName = "",
    [string]$OutputPath = "",
    [switch]$UseCredential
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'SUCCESS' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message" -ForegroundColor $color
}

$sqlCred = $null
if ($UseCredential) {
    $sqlCred = Get-Credential -Message "Enter SQL credentials for $ServerName"
}

function New-SqlConnectionString {
    param([string]$Database, [int]$Timeout = 0)
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Server'] = $ServerName
    $builder['Database'] = $Database
    $builder['TrustServerCertificate'] = $true
    if ($Timeout -gt 0) { $builder['Connect Timeout'] = $Timeout }
    if ($sqlCred) {
        $builder['User ID'] = $sqlCred.UserName
        $builder['Password'] = $sqlCred.GetNetworkCredential().Password
    } else {
        $builder['Integrated Security'] = 'SSPI'
    }
    return $builder.ConnectionString
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $dashboardRoot = Split-Path $PSScriptRoot -Parent
    $OutputPath = Join-Path $dashboardRoot "data\secureboot_data.json"
}

$dataDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

$siteCode = $null
if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
    try {
        $site = Get-WmiObject -Namespace "root\sms" -Class "__NAMESPACE" -ErrorAction Stop | Where-Object { $_.Name -match "^site_" } | Select-Object -ExpandProperty Name
        if ($site) {
            $siteCode = $site.Split('_')[1]
            Write-Log "Auto-detected MECM Site Code: $siteCode" 'INFO'
        }
    } catch {
        Write-Log "Failed to auto-detect MECM Site Code via WMI." 'WARN'
    }

    $candidates = @()
    if ($siteCode) {
        $candidates += "CM_$siteCode"
        $candidates += "ConfigMgr_$siteCode"
    }
    $candidates += @("CM_RTX", "ConfigMgr_RTX", "CM_PS1", "ConfigMgr_PS1")
    $candidates = $candidates | Select-Object -Unique

    foreach ($db in $candidates) {
        $testConn = $null
        try {
            $testConn = New-Object System.Data.SqlClient.SqlConnection((New-SqlConnectionString -Database $db -Timeout 5))
            $testConn.Open()
            $DatabaseName = $db
            Write-Log "Connected to MECM Database: $DatabaseName" 'SUCCESS'
            break
        } catch {
        } finally {
            if ($testConn) { $testConn.Dispose() }
        }
    }

    if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
        Write-Log "Could not find an accessible MECM database. Tried: $($candidates -join ', ')" 'ERROR'
        exit 1
    }
}

$connStr = New-SqlConnectionString -Database $DatabaseName
$authMode = if ($sqlCred) { "SQL login '$($sqlCred.UserName)'" } else { "Integrated Security as $env:USERDOMAIN\$env:USERNAME" }
Write-Log "Connecting to SQL Server: $ServerName / $DatabaseName ($authMode)" 'INFO'

try {
    $sqlConn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $sqlConn.Open()
    $initCmd = $sqlConn.CreateCommand()
    $initCmd.CommandText = "SET NOCOUNT ON; SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;"
    $initCmd.ExecuteNonQuery() | Out-Null
    Write-Log "SQL connection established successfully." 'SUCCESS'
} catch {
    Write-Log "SQL connection FAILED: $($_.Exception.Message)" 'ERROR'
    exit 1
}

try {
    $siteCmd = $sqlConn.CreateCommand()
    $siteCmd.CommandText = "SELECT TOP 1 SiteCode FROM v_Site ORDER BY SiteCode"
    $resolved = $siteCmd.ExecuteScalar()
    if ($resolved -and -not [System.DBNull]::Value.Equals($resolved)) {
        $siteCode = [string]$resolved
    }
} catch {
    Write-Log "Could not read site code from v_Site: $($_.Exception.Message)" 'WARN'
}

if ([string]::IsNullOrWhiteSpace($siteCode)) {
    if ($DatabaseName -match '^(?:CM|ConfigMgr)_(.+)$') {
        $siteCode = $Matches[1]
        Write-Log "Derived site code '$siteCode' from database name '$DatabaseName'." 'WARN'
    } else {
        Write-Log "Could not determine site code from database name '$DatabaseName'." 'WARN'
    }
}

Write-Log "Active MECM Site Code: $siteCode" 'INFO'

$query = @"
SELECT
    sb.ComputerName0 AS ComputerName,
    sb.StatusCategory0 AS StatusCategory,
    sb.Manufacturer0 AS Manufacturer,
    sb.Model0 AS Model,
    sb.BIOSVersion0 AS BIOSVersion,
    sb.BIOSReleaseDate0 AS BIOSReleaseDate,
    sb.OSBuildNumber0 AS OSBuildNumber,
    sb.UEFICA2023Status0 AS UEFICA2023Status,
    sb.UEFICA2023ErrorHex0 AS UEFICA2023ErrorHex,
    sb.AvailableUpdatesHex0 AS AvailableUpdatesHex,
    sb.BitLockerProtectionStatus0 AS BitLockerProtectionStatus,
    sb.SecureBootEnabled0 AS SecureBootEnabled,
    sb.LatestSecureBootEventId0 AS LatestSecureBootEventId,
    sb.ConfidenceLevel0 AS ConfidenceLevel,
    sb.WindowsUEFICA2023Capable0 AS WindowsUEFICA2023Capable,
    os.Caption0 AS OSName,
    os.Version0 AS OSVersion
FROM v_GS_EWAN_SecureBoot2026Discovery0 sb
INNER JOIN v_R_System sys ON sys.ResourceID = sb.ResourceID
LEFT JOIN v_GS_OPERATING_SYSTEM os ON sys.ResourceID = os.ResourceID
WHERE sys.Obsolete0 = 0
"@

try {
    $cmd = $sqlConn.CreateCommand()
    $cmd.CommandText = $query
    $cmd.CommandTimeout = 120
    
    Write-Log "Executing SQL Query..." 'INFO'
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable
    $adapter.Fill($dt) | Out-Null
    
    Write-Log "Retrieved $($dt.Rows.Count) rows from database." 'SUCCESS'
    
    $results = @()
    foreach ($row in $dt.Rows) {
        $obj = @{}
        foreach ($col in $dt.Columns) {
            $val = $row[$col.ColumnName]
            if ($null -eq $val -or [System.DBNull]::Value.Equals($val)) {
                $obj[$col.ColumnName] = $null
            } else {
                $obj[$col.ColumnName] = $val
            }
        }
        $results += $obj
    }

    $payload = [ordered]@{
        meta = [ordered]@{
            SiteCode    = $siteCode
            Database    = $DatabaseName
            Server      = $ServerName
            CollectedAt = (Get-Date).ToString('o')
            RowCount    = @($results).Count
        }
        endpoints = @($results)
    }

    $json = ConvertTo-Json -InputObject $payload -Depth 6 -Compress
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.Encoding]::UTF8)
    Write-Log "Successfully exported $(@($results).Count) endpoint record(s) for site '$siteCode' to $OutputPath" 'SUCCESS'
} catch {
    Write-Log "Data collection failed: $($_.Exception.Message)" 'ERROR'
    exit 1
} finally {
    if ($sqlConn.State -eq 'Open') {
        $sqlConn.Close()
    }
}
