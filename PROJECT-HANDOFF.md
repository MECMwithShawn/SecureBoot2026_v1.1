# eWAN Secure Boot 2026 Enterprise Solution (v1.1) - Project Handoff

**Document Version:** 1.1.0  
**Classification:** UNCLASSIFIED // FOR OFFICIAL USE ONLY  
**Release Date:** 2026-08-12  
**Target Environment:** Microsoft Endpoint Configuration Manager (MECM / ConfigMgr) & Enterprise Web Dashboard Host  
**GitHub Repository:** [https://github.com/MECMwithShawn/SecureBoot2026_v1.1](https://github.com/MECMwithShawn/SecureBoot2026_v1.1)  

---

## 1. Executive Summary & Overview

The **eWAN Secure Boot 2026 Enterprise Solution (v1.1)** is a production-ready, automated suite designed for enterprise Microsoft Endpoint Configuration Manager (MECM) environments. It automates:
1. **Endpoint UEFI CA 2023 Readiness Discovery & Reporting**
2. **Local Client WMI Provisioning (`root\cimv2\EWAN_SecureBoot2026Discovery`)**
3. **MECM Hardware Inventory Collection (`SMS_G_System_EWAN_SecureBoot2026Discovery_1_0`)**
4. **Targeted Pilot Certificate Deployment & Firmware Remediation**
5. **Real-time Web Health & Triage Dashboard (TCP Port 8091)**

---

## 2. Component Architecture & End-to-End Flow

```text
MECM Package: "Secure Boot 2026 - Discovery Inventory"
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Collect-SecureBoot2026Inventory.ps1 -PopulateLocalWmi
                                       │
                                       ▼
                     [Client Endpoint (SYSTEM Context)]
   1. Checks UEFI CA 2023 Registry Keys (AvailableUpdates, Servicing)
   2. Evaluates Event Logs (1795, 1032, 1800, etc.) & BitLocker Status
   3. Evaluates MOF & Compiles Plain Class in root\cimv2 via mofcomp.exe -N:root\cimv2
   4. Writes Instance Record to root\cimv2:EWAN_SecureBoot2026Discovery
                                       │
                                       ▼
                     [MECM Hardware Inventory Cycle]
   Collects root\cimv2:EWAN_SecureBoot2026Discovery using MOF: SecureBoot2026_HardwareInventory.mof
                                       │
                                       ▼
                     [MECM Site Database (SQL Server)]
   Populates SQL View: v_GS_EWAN_SecureBoot2026Discovery0
                                       │
                                       ▼
                     [Secure Boot 2026 Web Dashboard]
   Queries ConfigMgr SQL View every 15m -> Renders Web UI on http://<SERVER>:8091/
```

---

## 3. Key Technical Fixes & Improvements in v1.1

### Local WMI Class Schema & Compilation Fixes
- **Plain WMI Schema in `root\cimv2`:** The local MOF embedded in [Collect-SecureBoot2026Inventory.ps1](https://github.com/MECMwithShawn/SecureBoot2026_v1.1/blob/main/Scripts/Collect-SecureBoot2026Inventory.ps1) defines a clean local class without MECM qualifiers:
  ```mof
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
  ```
- **Hardened `mofcomp.exe` Execution:**
  - Evaluates `$env:SystemRoot\System32\wbem\mofcomp.exe` explicitly before falling back to PATH.
  - Passes explicit namespace flag `-N:root\cimv2`.
  - Captures stdout/stderr into `Collect-SecureBoot2026Inventory.log`.
  - Verifies `$LASTEXITCODE -eq 0` and confirms class existence via `Get-CimClass`, throwing a logged error if compilation fails.
- **Obsolete File Removal:**
  - `MOF/Create-LocalWmiClass.ps1` was removed as WMI class creation is handled self-healingly by `Collect-SecureBoot2026Inventory.ps1 -PopulateLocalWmi`.

---

## 4. Release Package Directory Structure (`SecureBoot2026_v1.1`)

```
SecureBoot2026_v1.1/
├── DEPLOYMENT-GUIDE.md               # Complete end-to-end admin guide
├── IA-REVIEW.md                      # Information Assurance / Security review doc
├── Setup-SecureBoot2026-MECM.ps1     # Automated MECM collection & package setup
├── Setup-SecureBootDashboard.ps1     # Automated Web Dashboard installer
├── Update-SecureBootDashboard.ps1    # In-place SHA256 upgrade script
├── Stop-SecureBootDashboard.ps1      # Clean uninstaller and teardown script
├── Dashboard/                        # Web dashboard assets & collector scripts
│   ├── index.html
│   ├── styles.css
│   ├── dashboard.js
│   ├── chart.min.js
│   ├── rtx_logo.svg
│   ├── Start-DashboardWebServer.ps1
│   └── scripts/
│       ├── Collect-SecureBootDashboardData.ps1
│       └── New-SecureBootDashboardCert.ps1
├── MECM_Queries/                     # Admin SQL & WQL query reference files
│   ├── CMPivot_Queries.txt
│   ├── SQL_Reporting_Queries.sql
│   └── WQL_Collections.sql
├── MOF/                              # Hardware inventory reporting definition
│   └── SecureBoot2026_HardwareInventory.mof
└── Scripts/                          # Client execution payload scripts
    ├── Collect-SecureBoot2026Inventory.ps1
    ├── Export-SecureBoot2026Summary.ps1
    ├── Firmware-Remediation-Wrapper.ps1
    ├── Install-SecureBoot2026Trigger.cmd
    ├── Invoke-SecureBoot2026Update.ps1
    └── Test-SecureBoot2026Compliance.ps1
```

---

## 5. Operational Instructions & Procedures

### 5.1 Fresh Deployment (New Site / Server)
1. Stage release package to `C:\Temp\SecureBoot2026_v1.1`.
2. Run MECM site setup (Primary Site Server):
   ```powershell
   Set-Location -Path "C:\Temp\SecureBoot2026_v1.1"
   .\Setup-SecureBoot2026-MECM.ps1
   ```
3. Import Hardware Inventory MOF in MECM Console:
   - **Administration** -> **Client Settings** -> **Default Client Settings** -> **Properties** -> **Hardware Inventory** -> **Set Classes...** -> **Import...** -> Select `MOF\SecureBoot2026_HardwareInventory.mof`.
4. Deploy **"Secure Boot 2026 - Discovery Inventory"** package to collection **"Secure Boot 2026 - Discovery - All Windows Endpoints"**.
5. Install Web Dashboard (Dashboard Host):
   ```powershell
   Set-Location -Path "C:\Temp\SecureBoot2026_v1.1"
   .\Setup-SecureBootDashboard.ps1 -ServerName "SQLSERVER" -DatabaseName "ConfigMgr_CHQ"
   ```

### 5.2 In-Place Upgrade (Upgrading Production v1.0 to v1.1)
Run from the staged v1.1 folder on your Dashboard Host / Package Share:
```powershell
Set-Location -Path "C:\Temp\SecureBoot2026_v1.1"
.\Update-SecureBootDashboard.ps1
```
*Performs SHA256 hash comparison across assets, updates modified files, syncs network package shares (`Packages\Discovery`), and restarts background scheduled tasks.*

### 5.3 Complete Teardown & Reset (Clean Re-Testing on DEV)
To completely remove the deployment for fresh re-testing:
```powershell
Set-Location -Path "C:\Temp\SecureBoot2026_v1.1"
.\Stop-SecureBootDashboard.ps1 -RemoveFiles -Force
```

---

## 6. Client Verification Commands

Run on any target client endpoint to verify local WMI class and instance data:

```powershell
# 1. Verify WMI Class Definition
Get-CimClass -Namespace root\cimv2 -ClassName EWAN_SecureBoot2026Discovery

# 2. Verify Instance Data Properties
Get-CimInstance -Namespace root\cimv2 -ClassName EWAN_SecureBoot2026Discovery | Select-Object *
```

---

## 7. Hand-off Sign-off Checklist

- [x] Hardened `Collect-SecureBoot2026Inventory.ps1` with explicit `mofcomp.exe` resolution & error handling.
- [x] Verified local WMI schema (`root\cimv2:EWAN_SecureBoot2026Discovery`) and MECM Hardware Inventory MOF separation.
- [x] Created `Update-SecureBootDashboard.ps1` in-place upgrade script.
- [x] Tested in-place upgrade and teardown/redeploy workflows in lab.
- [x] Synchronized release artifacts to GitHub repository: [SecureBoot2026_v1.1](https://github.com/MECMwithShawn/SecureBoot2026_v1.1).
