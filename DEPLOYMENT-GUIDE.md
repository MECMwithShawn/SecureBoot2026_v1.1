# RTX Secure Boot 2026 Enterprise Deployment Guide

**Document Version:** 1.1.0  
**Target Environment:** Microsoft Endpoint Configuration Manager (MECM / ConfigMgr) & Enterprise Web Dashboard Host  
**Classification:** UNCLASSIFIED // FOR OFFICIAL USE ONLY  

---

## 1. Overview & Prerequisites

### 1.1 Solution Summary
The **RTX Secure Boot 2026 Enterprise Solution** automates the discovery, reporting, pilot targeting, certificate update triggering, and health monitoring for Windows endpoints undergoing the Microsoft Secure Boot UEFI CA 2023 certificate migration.

The solution consists of two primary deployment phases:
1. **MECM Infrastructure & Client Deployment** (MECM Site Server)
2. **Web Health Dashboard Deployment** (Web Host / Collector Server)

### 1.2 Administrative Prerequisites

| Prerequisite | Location / Role | Requirement |
|---|---|---|
| **MECM Console Module** | MECM Site Server | `ConfigurationManager.psd1` (Admin Console installed) |
| **SQL Read Access** | Dashboard Host | Host machine account (`DOMAIN\COMPUTERNAME$`) needs `db_datareader` on `ConfigMgr_<SiteCode>` DB |
| **PowerShell Version** | All Systems | PowerShell 5.1+ with ExecutionPolicy Bypass capability |
| **Network Port** | Dashboard Host | TCP Port 8091 allowed inbound through Windows Firewall |

---

## 2. Phase 1: Deployment Source Staging & MECM Site Setup

### Step 1.1: Staging the Source Package

Extract or copy the source deployment package to a staging directory on your server (for example, `C:\Temp\SecureBoot2026_v1.1`):

```
C:\Temp\SecureBoot2026_v1.1\
├── Setup-SecureBoot2026-MECM.ps1
├── Setup-SecureBootDashboard.ps1
├── Stop-SecureBootDashboard.ps1
├── DEPLOYMENT-GUIDE.md
├── IA-REVIEW.md
├── Dashboard\
├── Scripts\
├── MOF\
└── MECM_Queries\
```

> **IMPORTANT ARCHITECTURAL NOTE:** Do NOT pre-copy the source package directly into `C:\SecureBoot2026`. The dashboard setup script (`Setup-SecureBootDashboard.ps1`) runs from your staging directory (`C:\Temp\SecureBoot2026_v1.0`), creates the `C:\SecureBoot2026` production directory automatically, structures the subfolders (`Dashboard`, `scripts`, `data`), and deploys all runtime files to `C:\SecureBoot2026`.

---

### Step 1.2: Run MECM Provisioning Script

Execute this step on your **MECM Primary Site Server** or a machine with the MECM Admin Console installed.

Open an **elevated PowerShell prompt** (Run as Administrator) and navigate to your staging directory:

```powershell
Set-Location -Path "C:\Temp\SecureBoot2026_v1.0"
.\Setup-SecureBoot2026-MECM.ps1
```

> **Note on Site Code Auto-Detection:** The script automatically detects your site code (e.g., `RTX`). If you need to specify it manually:
> ```powershell
> .\Setup-SecureBoot2026-MECM.ps1 -SiteCode "RTX"
> ```

#### What this script automatically provisions:
1. **Device Collection Folder:** `\DeviceCollection\Secure Boot 2026`
2. **13 Device Collections & WQL Membership Rules:**
   - `Secure Boot 2026 - Discovery - All Windows Endpoints`
   - `Secure Boot 2026 - Discovery - Servers`
   - `Secure Boot 2026 - Pilot Candidate - Model Representatives`
   - `Secure Boot 2026 - Complete`
   - `Secure Boot 2026 - Hold - Legacy BIOS or Secure Boot Disabled`
   - `Secure Boot 2026 - Hold - Firmware Review Required`
   - `Secure Boot 2026 - Hold - BitLocker Review Required`
   - `Secure Boot 2026 - Hold - OS Review Required`
   - `Secure Boot 2026 - Deployment - Wave 0 (Lab & IT Test)`
   - `Secure Boot 2026 - Deployment - Wave 1 (Pilot 5%)`
   - `Secure Boot 2026 - Deployment - Wave 2 (Production 25%)`
   - `Secure Boot 2026 - Deployment - Wave 3 (Production 50%)`
   - `Secure Boot 2026 - Deployment - Wave 4 (Production 100%)`
3. **2 MECM Packages & Programs:**
   - Package: `Secure Boot 2026 - Discovery Inventory` (Program: `Run Discovery & Populate WMI`)
   - Package: `Secure Boot 2026 - Certificate Update Trigger` (Program: `Trigger Secure Boot Update`)

---

### Step 1.3: Import Custom Hardware Inventory MOF Class

1. Open **MECM Console**.
2. Navigate to **Administration** -> **Overview** -> **Client Settings**.
3. Right-click **Default Client Settings** (or your custom Client Setting) and select **Properties**.
4. Select **Hardware Inventory** in the left menu, then click **Set Classes...**.
5. Click **Import...**.
6. Browse to your staging directory (`MOF` folder) and select:
   `SecureBoot2026_HardwareInventory.mof`
7. In the import confirmation window, click **Import**.
8. Ensure `SMS_G_System_EWAN_SecureBoot2026Discovery_1_0` is checked in the list, then click **OK** -> **OK**.

---

### Step 1.4: Deploy Discovery Package to Endpoints

1. In **MECM Console**, navigate to **Software Library** -> **Overview** -> **Application Management** -> **Packages**.
2. Locate `Secure Boot 2026 - Discovery Inventory`.
3. Right-click and select **Deploy**.
4. Target Collection: **`Secure Boot 2026 - Discovery - All Windows Endpoints`**.
5. Deployment Purpose: **Required** (recurrence schedule e.g. every 7 days).
6. Program: `Run Discovery & Populate WMI`.

> **Client Execution Lifecycle:** When clients run this package, `Collect-SecureBoot2026Inventory.ps1` checks UEFI status, Event Logs (1795, 1032), BitLocker status, and OS build numbers. It writes the result to local WMI (`root\cimv2\EWAN_SecureBoot2026Discovery`), which MECM Hardware Inventory uploads to SQL on its next cycle.

---

## 3. Phase 2: Web Dashboard Deployment

Execute this phase on the server designated to host the Web Dashboard (can be the MECM Site Server, SMS Provider, or a standalone Web Server).

### Step 2.1: Verify SQL Access Rights
Ensure the machine account of the Dashboard host (`DOMAIN\COMPUTERNAME$`) has been granted `db_datareader` role on your ConfigMgr database (`CM_<SiteCode>`).

### Step 2.2: Run Dashboard Installer

Open an **elevated PowerShell prompt** (Run as Administrator) and navigate to your staging directory:

```powershell
Set-Location -Path "C:\Temp\SecureBoot2026_v1.0"
.\Setup-SecureBootDashboard.ps1
```

#### Interactive Options & Parameters:
- **Install Path:** Default is `C:\SecureBoot2026` (the script creates and populates this folder).
- **SQL Server:** Auto-detected (or specify `-ServerName "SQLSERVER01"`).
- **Database Name:** Auto-detected `CM_<SiteCode>` (or specify `-DatabaseName "CM_RTX"`).
- **Web Port:** Default is `8091`.
- **Collection Interval:** Default is `15` minutes.

#### Unattended / Automated Install Example:
```powershell
.\Setup-SecureBootDashboard.ps1 -InstallPath "C:\SecureBoot2026" -ServerName "localhost" -DatabaseName "CM_RTX" -Port 8091 -CollectionIntervalMinutes 15 -NonInteractive -SkipSsl
```

#### What the installer does:
1. Automatically creates production folder `C:\SecureBoot2026`.
2. Copies runtime web and script assets into `C:\SecureBoot2026\Dashboard` and `C:\SecureBoot2026\scripts`.
3. Creates `C:\SecureBoot2026\data` for dashboard state and JSON collection storage.
4. Creates Windows Defender Firewall Rule: `Secure Boot 2026 Dashboard (TCP 8091)`.
5. Deletes stale HTTP.sys wildcard ACLs (`http://+:8091/`) to prevent HttpListener binding errors.
6. Optionally binds SSL host certificates for HTTPS.
7. Creates Scheduled Task: `eWAN_SecureBootDashboard_DataCollection` (queries SQL every 15m as `SYSTEM`).
8. Creates Scheduled Task: `eWAN_SecureBootDashboard` (runs web listener `Start-DashboardWebServer.ps1` at boot as `SYSTEM`).
9. Triggers initial data collection and verifies HTTP 200 health response.

---

## 4. Phase 3: Operational Workflow & Remediation

Once Discovery & Dashboard are installed, follow this operational cadence:

### Operational Step 1: Monitor Initial Triage
Open your web browser and navigate to:
- `http://<SERVER_NAME>:8091/` (or `https://<FQDN>:8091/`)

View metrics for:
- **Compliant (Updated)**: Endpoints with `UEFICA2023Status = Updated`.
- **Pilot Candidates**: Devices marked `ReadyForPilotReview` (ready for trigger deployment).
- **Holds**: Devices grouped by Firmware Review (Event 1795 / missing BIOS updates), BitLocker Review (Event 1032 recovery key validation), OS Review (missing LCU updates), or Disabled/Legacy.

### Operational Step 2: Trigger Pilot Cohort (Wave 0 / Wave 1)
1. Add target pilot endpoints to collection `Secure Boot 2026 - Deployment - Wave 0 (Lab & IT Test)`.
2. Deploy Package `Secure Boot 2026 - Certificate Update Trigger` (Program: `Trigger Secure Boot Update`) to Wave 0.
3. Upon execution, `Invoke-SecureBoot2026Update.ps1` sets registry key `AvailableUpdates = 0x5944` and reboots the client to apply the 2023 UEFI CA certificate into firmware.

---

## 5. Maintenance, Upgrade & Uninstallation

### 5.1 Verification Commands
Validate SQL connectivity and inventory view status:
```powershell
C:\SecureBoot2026\scripts\Test-SecureBootSQL.ps1 -ServerName "localhost" -DatabaseName "CM_CHQ"
```

### 5.2 Force Immediate Data Refresh
Trigger the background data collection task manually:
```powershell
Start-ScheduledTask -TaskName "eWAN_SecureBootDashboard_DataCollection"
```

### 5.3 In-Place Upgrade (Option A: Upgrading from v1.0 to v1.1)
To upgrade an existing production deployment (`C:\SecureBoot2026`) in-place without losing configuration or incurring extended downtime:

1. Stage the new release package to a staging directory (e.g. `C:\Temp\SecureBoot2026_v1.1`).
2. Open an elevated PowerShell prompt and run:
   ```powershell
   Set-Location -Path "C:\Temp\SecureBoot2026_v1.1"
   .\Update-SecureBootDashboard.ps1
   ```
3. **What the upgrade script performs:**
   - Temporarily stops background web listener services.
   - Performs a **SHA256 hash comparison** across release assets, updating only changed or new files (`Collect-SecureBoot2026Inventory.ps1`, web UI, collector backend).
   - Automatically synchronizes updated discovery scripts to network package shares (`\\<SERVER>\Software\Microsoft\Secure Boot\Packages\Discovery`).
   - Restarts background services and triggers data collection.

### 5.4 Complete Removal & Reset (Option B: Clean Removal for Re-Testing)
To completely rip out the existing deployment for clean environment re-testing:

1. Open an elevated PowerShell prompt and execute:
   ```powershell
   Set-Location -Path "C:\Temp\SecureBoot2026_v1.1"
   .\Stop-SecureBootDashboard.ps1 -RemoveFiles -Force
   ```
2. **What the clean removal script performs:**
   - Stops running dashboard PowerShell web processes (`Start-DashboardWebServer.ps1`, `Collect-SecureBootDashboardData.ps1`).
   - Unregisters Scheduled Tasks (`eWAN_SecureBootDashboard` and `eWAN_SecureBootDashboard_DataCollection`).
   - Deletes Windows Firewall rules (`Secure Boot 2026 Dashboard (TCP 8091)`).
   - Removes HTTP.sys URL ACL reservations (`http://+:8091/`).
   - Deletes the deployed directory `C:\SecureBoot2026`.

---

## 6. Summary Checklist for Admins

- [ ] **Step 1:** Source package staged at `C:\Temp\SecureBoot2026_v1.1`.
- [ ] **Step 2:** Executed `Setup-SecureBoot2026-MECM.ps1` from `C:\Temp\SecureBoot2026_v1.1`.
- [ ] **Step 3:** Imported `SecureBoot2026_HardwareInventory.mof` in Client Settings.
- [ ] **Step 4:** Deployed Package `Secure Boot 2026 - Discovery Inventory` to `Secure Boot 2026 - Discovery - All Windows Endpoints`.
- [ ] **Step 5:** Verified SQL `db_datareader` permissions for Dashboard Host machine account.
- [ ] **Step 6:** Executed `Setup-SecureBootDashboard.ps1` from `C:\Temp\SecureBoot2026_v1.1` (provisions production `C:\SecureBoot2026`).
- [ ] **Step 7:** Accessed `http://<SERVER_NAME>:8091/` in browser to confirm metrics display.
- [ ] **Step 8 (Upgrades):** Ran `Update-SecureBootDashboard.ps1` for in-place maintenance.
- [ ] **Step 9 (Clean Reset):** Ran `Stop-SecureBootDashboard.ps1 -RemoveFiles -Force` for full teardown and fresh re-testing.
