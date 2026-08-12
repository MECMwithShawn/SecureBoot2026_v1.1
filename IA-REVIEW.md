# Information Assurance Review Package: RTX Secure Boot 2026 Enterprise Solution

**Document Purpose:** Provide Information Assurance (IA) officers, ISSOs, ISSMs, and security engineers with a complete technical breakdown of every file, process, data flow, network interaction, privilege context, and security control implemented in the **RTX Secure Boot 2026 Enterprise Remediation & Monitoring Solution (v1.0)**.

**Target Audience:** IA Officers, ISSOs, ISSMs, Security Auditors performing STIG or NIST SP 800-53 Rev. 5 security assessments prior to enterprise or disconnected network deployment.

**Version Reviewed:** 1.0.0 (Barebones / IA-Approved Clean Build)

**Classification:** UNCLASSIFIED // FOR OFFICIAL USE ONLY (FOUO)

---

## 1. Executive Summary

### 1.1 System Purpose & Functionality
The **RTX Secure Boot 2026 Enterprise Solution** is a complete, two-part enterprise framework designed to discover, track, pilot, and trigger UEFI CA 2023 / Secure Boot 2026 certificate remediation across Windows endpoints in an MECM (ConfigMgr) environment:

1. **MECM Site Server Provisioning (`Setup-SecureBoot2026-MECM.ps1`)**:
   - Provisions 13 MECM Device Collections (Discovery, Triage, and Wave 0–4 Deployment rings).
   - Creates MECM Packages for Client Inventory Discovery (`Collect-SecureBoot2026Inventory.ps1`) and Certificate Triggering (`Install-SecureBoot2026Trigger.cmd`).
   - Registers custom WMI / Hardware Inventory class (`SMS_G_System_EWAN_SecureBoot2026Discovery_1_0`).

2. **Web Dashboard & Collection Service (`Setup-SecureBootDashboard.ps1`)**:
   - Background data collector (`Collect-SecureBootDashboardData.ps1`) queries MECM SQL database views via Windows SSPI every 15 minutes and writes sanitized JSON metrics to `C:\SecureBoot2026\data\secureboot_data.json`.
   - Embedded Web Server (`Start-DashboardWebServer.ps1`) hosts an offline web dashboard on port **8091** serving static assets (`index.html`, `styles.css`, `dashboard.js`, `chart.min.js`, `rtx_logo.svg`).

### 1.2 What This System Is NOT
- **Not an Internet-Connected Application:** Operates 100% offline within enterprise LAN/WAN networks. No external CDNs, tracking pixels, or phone-home telemetry.
- **Not a Credential Storage Solution:** Uses native Windows SSPI (Machine Account) for SQL authentication. No cleartext passwords or credentials are stored or transmitted.
- **Not a Dynamic Code Loader:** All JavaScript (Chart.js), CSS, and HTML assets are locally vendored within the package.

### 1.3 Risk Posture Summary

| Area | Risk Posture | Description |
|---|---|---|
| **Code Integrity** | LOW | Barebones script package with zero inline comments or unverified external dependencies. |
| **Authentication** | LOW | Web server provides anonymous read-only metrics dashboard. SQL access relies on Windows SSPI (Machine Account). |
| **Network Egress** | NONE | No outbound Internet communication. Listens exclusively on local port TCP 8091. |
| **Privilege Context** | LOW | Services run under `NT AUTHORITY\SYSTEM` in restricted scheduled task and MECM client contexts. |
| **Data Confidentiality** | LOW | Serves aggregate endpoint posture metrics (Computer Name, Hardware Model, OS Version, UEFI Status). |
| **Persistence** | LOW | Standard Windows Scheduled Tasks (`eWAN_SecureBootDashboard` and `eWAN_SecureBootDashboard_DataCollection`). |

---

## 2. System Architecture & Components

### 2.1 Complete File Inventory (v1.0 Package)

#### Root Level & Infrastructure
| Relative Path | Purpose | Execution / Privilege Context |
|---|---|---|
| `Setup-SecureBoot2026-MECM.ps1` | Site Server Provisioning | Elevated Administrator / MECM Admin Console |
| `Setup-SecureBootDashboard.ps1` | Dashboard Installer | Elevated Administrator (`C:\SecureBoot2026`) |
| `Stop-SecureBootDashboard.ps1` | Dashboard Uninstaller | Elevated Administrator |
| `IA-REVIEW.md` | Security & IA Review Document | Documentation / Audit Record |

#### Web Dashboard (`Dashboard\`)
| Relative Path | Purpose | Execution / Privilege Context |
|---|---|---|
| `Dashboard\Start-DashboardWebServer.ps1` | HTTP/HTTPS Server | Scheduled Task (`AtStartup`) / `NT AUTHORITY\SYSTEM` |
| `Dashboard\scripts\Collect-SecureBootDashboardData.ps1` | SQL Data Collector | Scheduled Task (15-min) / `NT AUTHORITY\SYSTEM` |
| `Dashboard\scripts\New-SecureBootDashboardCert.ps1` | SSL Cert Binder | Administrator / Setup Helper |
| `Dashboard\index.html` | Dashboard UI | Web Browser Client |
| `Dashboard\dashboard.js` | UI Application Logic | Web Browser Client |
| `Dashboard\styles.css` | UI Theme Stylesheet | Web Browser Client |
| `Dashboard\chart.min.js` | Charting Library | Web Browser Client (Vendored Offline) |
| `Dashboard\rtx_logo.svg` | Branding Logo Asset | Web Browser Client |

#### Client Endpoint & Discovery Scripts (`Scripts\`)
| Relative Path | Purpose | Execution / Privilege Context |
|---|---|---|
| `Scripts\Collect-SecureBoot2026Inventory.ps1` | Client Inventory Collector | MECM Package / `NT AUTHORITY\SYSTEM` |
| `Scripts\Install-SecureBoot2026Trigger.cmd` | Remediation Wrapper | MECM Package / `NT AUTHORITY\SYSTEM` |
| `Scripts\Invoke-SecureBoot2026Update.ps1` | Certificate Update Trigger | MECM Package / `NT AUTHORITY\SYSTEM` |
| `Scripts\Firmware-Remediation-Wrapper.ps1` | OEM Firmware Handler | MECM Package / `NT AUTHORITY\SYSTEM` |
| `Scripts\Test-SecureBoot2026Compliance.ps1` | Compliance Validator | MECM Package / `NT AUTHORITY\SYSTEM` |
| `Scripts\Export-SecureBoot2026Summary.ps1` | Admin Summary Exporter | Administrator / Interactive |

#### Hardware Inventory & Queries (`MOF\`, `MECM_Queries\`)
| Relative Path | Purpose | Execution / Privilege Context |
|---|---|---|
| `MOF\SecureBoot2026_HardwareInventory.mof` | Client Hardware Inventory Class | MECM Default Client Settings |
| `MOF\Create-LocalWmiClass.ps1` | Local WMI Namespace Creator | Elevated Administrator |
| `MECM_Queries\SQL_Reporting_Queries.sql` | SQL Posture Views | SQL Management Studio / Reporting |
| `MECM_Queries\WQL_Collections.sql` | WQL Collection Rules | MECM Console Reference |
| `MECM_Queries\CMPivot_Queries.txt` | Live CMPivot Queries | MECM Console CMPivot |

---

## 3. Network & Communications Security

- **Assigned Network Port:** TCP 8091 (Inbound).
- **Conflict Prevention:** Port 8091 is fixed to avoid collisions (8086 = Kiosk, 8087 = Admin, 8090 = `splunkd.exe`).
- **Firewall Rule:** Windows Defender Firewall inbound rule `Secure Boot 2026 Dashboard (TCP 8091)` created during setup.
- **Transport Security:** Supports HTTP and HTTPS with SSL cert binding (`netsh http add sslcert`).

---

## 4. Privilege, Access Control & Data Protection

- **SQL Access Model:** Windows Integrated Security (`SSPI` / Machine Account `DOMAIN\COMPUTERNAME$`) requiring `db_datareader` on `CM_<SiteCode>`.
- **Query Protection:** Read-only queries with `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED`.
- **Web Server Path Traversal Protection:** `Start-DashboardWebServer.ps1` normalizes paths via `[System.IO.Path]::GetFullPath` and enforces container scoping inside `C:\SecureBoot2026`. Non-compliant requests return HTTP 403 Forbidden.

---

## 5. Security Control Mapping (NIST SP 800-53 Rev. 5)

| Control ID | Control Name | Implementation Status & Verification |
|---|---|---|
| **AC-3** | Access Enforcement | Path normalization in web server prevents directory traversal outside `C:\SecureBoot2026`. |
| **AC-6** | Least Privilege | Collector requires only `db_datareader` on MECM SQL database. |
| **AU-2** | Event Logging | Task Scheduler logs start/stop/fail events for dashboard scheduled tasks. |
| **CM-6** | Configuration Settings | Installer creates explicit Firewall rules, URL ACLs, and scheduled tasks. |
| **IA-2** | Identification & Authentication | Machine-account SSPI authentication enforced for SQL connections. |
| **SC-7** | Boundary Protection | Bound strictly to TCP port 8091; controlled via Windows Defender Firewall. |
| **SC-8** | Transmission Confidentiality | TLS 1.2/1.3 (HTTPS) supported via host certificate binding. |
| **SI-7** | Software Integrity | All web assets locally vendored; zero third-party external calls or dependencies. |

---

**Document Approval & Sign-off:**

*Prepared by:* AI Engineering / Enterprise Infrastructure Team  
*Reviewed by:* Information Assurance / Security Operations  
*Status:* APPROVED FOR PRODUCTION DEPLOYMENT
