-- ============================================================================
-- MECM / SCCM WQL Collection Queries for Secure Boot 2026
-- Environment: eWAN Offline MECM Infrastructure
-- Usage: Paste into MECM Console -> Assets and Compliance -> Device Collections -> Membership Rules -> Query Rule
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. All Windows 10 & 11 Endpoints (Discovery Scope)
-- ----------------------------------------------------------------------------
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name,
SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup,
SMS_R_SYSTEM.Client
from SMS_R_System
inner join SMS_G_System_OPERATING_SYSTEM on SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceID
where SMS_G_System_OPERATING_SYSTEM.Caption like "%Windows 10%"
   or SMS_G_System_OPERATING_SYSTEM.Caption like "%Windows 11%"

-- ----------------------------------------------------------------------------
-- 2. Windows Server Endpoints (Separate Maintenance Windows & Ringing)
-- ----------------------------------------------------------------------------
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name,
SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup,
SMS_R_SYSTEM.Client
from SMS_R_System
inner join SMS_G_System_OPERATING_SYSTEM on SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceID
where SMS_G_System_OPERATING_SYSTEM.Caption like "%Server%"

-- ----------------------------------------------------------------------------
-- 3. Secure Boot 2026 Complete (Updated / Compliant Devices)
-- Requires Hardware Inventory Custom WMI Class EWAN_SecureBoot2026Discovery
-- ----------------------------------------------------------------------------
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name,
SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup,
SMS_R_SYSTEM.Client
from SMS_R_System
inner join SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0 on SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.ResourceID = SMS_R_System.ResourceID
where SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.UEFICA2023Status0 = "Updated"
   or SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.StatusCategory0 = "Complete"

-- ----------------------------------------------------------------------------
-- 4. Hold Group - Legacy BIOS or Secure Boot Disabled
-- ----------------------------------------------------------------------------
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name,
SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup,
SMS_R_SYSTEM.Client
from SMS_R_System
inner join SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0 on SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.ResourceID = SMS_R_System.ResourceID
where SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.SecureBootEnabled0 = "False"
   or SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.StatusCategory0 = "SecureBootDisabledOrLegacy"

-- ----------------------------------------------------------------------------
-- 5. Hold Group - Firmware Review Required (Error or Blocked Events)
-- ----------------------------------------------------------------------------
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name,
SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup,
SMS_R_SYSTEM.Client
from SMS_R_System
inner join SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0 on SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.ResourceID = SMS_R_System.ResourceID
where SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.UEFICA2023ErrorHex0 != "0x0000"
   or SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.StatusCategory0 = "NeedsFirmwareReview"

-- ----------------------------------------------------------------------------
-- 6. Hold Group - BitLocker Review Required (Event 1032 Protection Risk)
-- ----------------------------------------------------------------------------
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name,
SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup,
SMS_R_SYSTEM.Client
from SMS_R_System
inner join SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0 on SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.ResourceID = SMS_R_System.ResourceID
where SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.StatusCategory0 = "NeedsBitLockerReview"

-- ----------------------------------------------------------------------------
-- 7. Pilot Candidates (Secure Boot Enabled, Ready for Deployment)
-- ----------------------------------------------------------------------------
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name,
SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup,
SMS_R_SYSTEM.Client
from SMS_R_System
inner join SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0 on SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.ResourceID = SMS_R_System.ResourceID
where SMS_G_System_EWAN_SECUREBOOT2026DISCOVERY0.StatusCategory0 = "ReadyForPilotReview"
