-- ============================================================================
-- MECM SQL Reporting & Dashboard Queries for Secure Boot 2026
-- Environment: eWAN MECM Site Database (SQL Server / SSRS / Power BI)
-- Purpose: Executive dashboarding, model risk analysis, and compliance tracking
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Baseline Model, BIOS, and OS Inventory Query (Default MECM Hardware Inventory)
-- ----------------------------------------------------------------------------
SELECT
    sys.ResourceID,
    sys.Netbios_Name0 AS DeviceName,
    cs.Manufacturer0 AS Manufacturer,
    cs.Model0 AS Model,
    bios.SMBIOSBIOSVersion0 AS BIOSVersion,
    bios.ReleaseDate0 AS BIOSReleaseDate,
    os.Caption0 AS OSName,
    os.Version0 AS OSVersion,
    os.BuildNumber0 AS OSBuildNumber,
    os.LastBootUpTime0 AS LastBootTime,
    sys.Client0 AS MECMClient,
    sys.Active0 AS ActiveClient
FROM v_R_System sys
LEFT JOIN v_GS_COMPUTER_SYSTEM cs ON sys.ResourceID = cs.ResourceID
LEFT JOIN v_GS_PC_BIOS bios ON sys.ResourceID = bios.ResourceID
LEFT JOIN v_GS_OPERATING_SYSTEM os ON sys.ResourceID = os.ResourceID
WHERE sys.Obsolete0 = 0
ORDER BY cs.Manufacturer0, cs.Model0, bios.SMBIOSBIOSVersion0;

-- ----------------------------------------------------------------------------
-- 2. Custom WMI Hardware Inventory Status Summary (EWAN_SecureBoot2026Discovery)
-- ----------------------------------------------------------------------------
SELECT
    sb.StatusCategory0 AS StatusCategory,
    COUNT(*) AS DeviceCount
FROM v_GS_EWAN_SECUREBOOT2026DISCOVERY0 sb
INNER JOIN v_R_System sys ON sys.ResourceID = sb.ResourceID
WHERE sys.Obsolete0 = 0
GROUP BY sb.StatusCategory0
ORDER BY DeviceCount DESC;

-- ----------------------------------------------------------------------------
-- 3. Model-Level Hardware Remediation & Readiness Matrix
-- ----------------------------------------------------------------------------
SELECT
    sb.Manufacturer0 AS Manufacturer,
    sb.Model0 AS Model,
    sb.BIOSVersion0 AS BIOSVersion,
    sb.OSBuildNumber0 AS OSBuildNumber,
    sb.StatusCategory0 AS StatusCategory,
    COUNT(*) AS DeviceCount
FROM v_GS_EWAN_SECUREBOOT2026DISCOVERY0 sb
INNER JOIN v_R_System sys ON sys.ResourceID = sb.ResourceID
WHERE sys.Obsolete0 = 0
GROUP BY sb.Manufacturer0, sb.Model0, sb.BIOSVersion0, sb.OSBuildNumber0, sb.StatusCategory0
ORDER BY sb.Manufacturer0, sb.Model0, sb.StatusCategory0, DeviceCount DESC;

-- ----------------------------------------------------------------------------
-- 4. Firmware Review Backlog (Devices with Errors or Blocked Events)
-- ----------------------------------------------------------------------------
SELECT
    sb.ComputerName0 AS ComputerName,
    sb.Manufacturer0 AS Manufacturer,
    sb.Model0 AS Model,
    sb.BIOSVersion0 AS BIOSVersion,
    sb.BIOSReleaseDate0 AS BIOSReleaseDate,
    sb.UEFICA2023Status0 AS UEFICA2023Status,
    sb.UEFICA2023ErrorHex0 AS UEFICA2023ErrorHex,
    sb.LatestSecureBootEventId0 AS LatestSecureBootEventId,
    sb.StatusCategory0 AS StatusCategory
FROM v_GS_EWAN_SECUREBOOT2026DISCOVERY0 sb
INNER JOIN v_R_System sys ON sys.ResourceID = sb.ResourceID
WHERE sys.Obsolete0 = 0
  AND sb.StatusCategory0 IN ('NeedsFirmwareReview', 'Error')
ORDER BY sb.Manufacturer0, sb.Model0, sb.BIOSVersion0, sb.ComputerName0;

-- ----------------------------------------------------------------------------
-- 5. Staging Table Query (If Importing Script CSV Outputs into Custom Database)
-- ----------------------------------------------------------------------------
/*
CREATE TABLE dbo.SecureBoot2026DiscoveryStaging (
    ComputerName nvarchar(128) NOT NULL,
    CollectionTime datetime2 NULL,
    StatusCategory nvarchar(64) NULL,
    SecureBootEnabled nvarchar(16) NULL,
    Manufacturer nvarchar(128) NULL,
    Model nvarchar(256) NULL,
    BIOSVersion nvarchar(128) NULL,
    OSBuildNumber nvarchar(64) NULL,
    UEFICA2023Status nvarchar(64) NULL,
    UEFICA2023ErrorHex nvarchar(64) NULL,
    AvailableUpdatesHex nvarchar(64) NULL,
    WindowsUEFICA2023Capable nvarchar(64) NULL,
    BitLockerProtection nvarchar(64) NULL,
    LastSecureBootEventId nvarchar(64) NULL
);

SELECT StatusCategory, COUNT(*) AS TotalCount
FROM dbo.SecureBoot2026DiscoveryStaging
GROUP BY StatusCategory
ORDER BY TotalCount DESC;
*/
