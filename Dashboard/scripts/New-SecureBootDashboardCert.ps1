#requires -Version 5.1
# NOTE: no "#Requires -RunAsAdministrator" here on purpose. Reading certificate metadata
# needs no elevation, so -DetectOnly must work as a normal user. Elevation is enforced
# below, only for the paths that actually create, delete, or bind.
<#
.SYNOPSIS
    Provisions and binds the SSL certificate for the Secure Boot 2026 Dashboard.
.DESCRIPTION
    Mirrors the Kiosk/Admin dashboard certificate workflow (New-DashboardCert.ps1 and
    Request-CACert.ps1).

    Prefers an existing CA-issued certificate, because those chain to the enterprise CA and
    are trusted by every domain machine with no client-side action. A self-signed
    certificate is only trusted where it has been installed into the Trusted Root store,
    which is why a self-signed dashboard shows a browser warning on every other machine.

    Detection order for an existing CA-issued certificate:
      1. FriendlyName "Secure Boot Dashboard*"
      2. Subject exactly CN=<fqdn>
      3. Any certificate carrying <fqdn> in its SAN list

    In all three cases the certificate must be CA-issued (Issuer differs from Subject),
    have a private key, not expire within 7 days, and not be a ConfigMgr (SMS) certificate.

.PARAMETER Port
    Port to bind the certificate to. Required unless -SkipBinding.
.PARAMETER Force
    Non-interactive. Re-uses a found CA certificate, otherwise creates self-signed.
.PARAMETER SelfSigned
    Skip CA detection and create a self-signed certificate.
.PARAMETER SkipBinding
    Create/select the certificate but do not bind it to a port.
.PARAMETER DetectOnly
    READ-ONLY. Report which certificate would be selected and why, then exit. Creates
    nothing, deletes nothing, binds nothing. Use this to verify detection on a live host
    before running setup.
.EXAMPLE
    .\New-SecureBootDashboardCert.ps1 -DetectOnly
.EXAMPLE
    .\New-SecureBootDashboardCert.ps1 -Port 8091
.EXAMPLE
    .\New-SecureBootDashboardCert.ps1 -Port 8091 -Force
#>
[CmdletBinding()]
param(
    [string]$HostName,
    [string]$Domain,
    [int]$Port,
    [switch]$Force,
    [switch]$SelfSigned,
    [switch]$SkipBinding,
    [switch]$DetectOnly
)

$ErrorActionPreference = 'Stop'

# Distinct from the Kiosk (4dc3e181-...) and PBIRS app IDs so HTTP.SYS bindings never collide.
$AppId = '{9f2a7c34-6b18-4d52-a0e7-3c8b5d194ea6}'
$FriendlyPrefix = 'Secure Boot Dashboard'
$ServerAuthOid = '1.3.6.1.5.5.7.3.1'

if (-not $HostName) { $HostName = $env:COMPUTERNAME }
if (-not $Domain) {
    try { $Domain = (Get-CimInstance Win32_ComputerSystem).Domain } catch { $Domain = $env:USERDNSDOMAIN }
}
$fqdn = if ($Domain -and $Domain -ne 'WORKGROUP') { "$HostName.$Domain" } else { $HostName }

# Elevation is required to create certificates, write the Root store, and bind via HTTP.SYS.
# -DetectOnly touches none of those, so it is allowed to run unelevated.
if (-not $DetectOnly) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ""
        Write-Host "    [ERROR] Administrator privileges are required to create or bind a certificate." -ForegroundColor Red
        Write-Host "    Re-run elevated, or use -DetectOnly to inspect without changing anything." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

function Write-Ok    { param([string]$T) Write-Host "    [OK] $T"    -ForegroundColor Green }
function Write-Info  { param([string]$T) Write-Host "    [INFO] $T"  -ForegroundColor Cyan }
function Write-Warn2 { param([string]$T) Write-Host "    [WARN] $T"  -ForegroundColor Yellow }
function Write-Err   { param([string]$T) Write-Host "    [FAIL] $T"  -ForegroundColor Red }
function Write-Detail{ param([string]$T) Write-Host "         $T"    -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  +========================================================+" -ForegroundColor DarkCyan
Write-Host "  |   Secure Boot 2026 Dashboard -- SSL Certificate Setup  |" -ForegroundColor DarkCyan
Write-Host "  +========================================================+" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Hostname : $HostName" -ForegroundColor DarkGray
Write-Host "  FQDN     : $fqdn" -ForegroundColor DarkGray
Write-Host "  SAN      : $fqdn, $HostName, localhost" -ForegroundColor DarkGray
if ($Port) { Write-Host "  Port     : $Port" -ForegroundColor DarkGray }
Write-Host ""

# Certificates already bound to some port must never be deleted during cleanup.
$boundHashes = @()
try {
    $sslDump = netsh http show sslcert 2>&1 | Out-String
    foreach ($m in [regex]::Matches($sslDump, 'Certificate Hash\s*:\s*([0-9a-fA-F]+)')) {
        $boundHashes += $m.Groups[1].Value
    }
} catch { }

# ---------------------------------------------------------------------------
Write-Host "  [1/4] CERTIFICATE DETECTION" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$cert = $null
$existingCA = $null

function Test-UsableForServerAuth {
    param($Certificate)
    # No EKU extension means "all purposes", which is usable. Otherwise Server Auth must be present.
    $eku = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }
    if (-not $eku) { return $true }
    return ($Certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq $ServerAuthOid }) -ne $null
}

if ($SelfSigned) {
    Write-Info "-SelfSigned specified; skipping CA certificate detection."
} else {
    $candidates = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(7) -and
        $_.Issuer -ne $_.Subject -and          # CA-issued: a self-signed cert issues itself
        $_.Issuer -notmatch 'SMS' -and         # exclude ConfigMgr's own certificates
        (Test-UsableForServerAuth -Certificate $_)
    })

    # Tier 1: previously provisioned for this dashboard
    $existingCA = $candidates | Where-Object { $_.FriendlyName -like "$FriendlyPrefix*" } |
                  Sort-Object NotAfter -Descending | Select-Object -First 1

    # Tier 2: subject exactly matches this host's FQDN
    if (-not $existingCA) {
        $existingCA = $candidates | Where-Object { $_.Subject -eq "CN=$fqdn" } |
                      Sort-Object NotAfter -Descending | Select-Object -First 1
    }

    # Tier 3: any certificate carrying the FQDN as a SAN
    if (-not $existingCA) {
        $existingCA = $candidates | Where-Object {
            ($_.DnsNameList | ForEach-Object { $_.Unicode }) -contains $fqdn
        } | Sort-Object NotAfter -Descending | Select-Object -First 1
    }
}

if ($existingCA) {
    $daysLeft = [math]::Floor(($existingCA.NotAfter - (Get-Date)).TotalDays)
    Write-Host ""
    Write-Ok "Existing CA-issued certificate found in LocalMachine\My:"
    Write-Detail "Subject    : $($existingCA.Subject)"
    Write-Detail "Issuer     : $($existingCA.Issuer)"
    Write-Detail "Thumbprint : $($existingCA.Thumbprint)"
    Write-Detail "Expires    : $($existingCA.NotAfter.ToString('yyyy-MM-dd')) ($daysLeft days remaining)"
    $sans = ($existingCA.DnsNameList | ForEach-Object { $_.Unicode }) -join ', '
    if ($sans) { Write-Detail "SANs       : $sans" }
    Write-Host ""

    if ($DetectOnly) {
        Write-Info "-DetectOnly: this certificate WOULD be re-used. Nothing was changed."
        $choice = 'R'
    } elseif ($Force) {
        Write-Info "Re-using existing CA certificate (-Force specified)."
        $choice = 'R'
    } else {
        Write-Host "    [R] Re-use this certificate (recommended - already trusted domain-wide)" -ForegroundColor White
        Write-Host "    [N] Create a new self-signed certificate instead (browser warnings)" -ForegroundColor DarkGray
        Write-Host ""
        $choice = Read-Host "    Re-use existing cert? [R]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'R' }
    }

    if ($choice -match '^[Rr]') {
        $cert = $existingCA
        Write-Ok "Re-using CA-issued certificate"
    } else {
        Write-Info "Will create a self-signed certificate instead."
    }
} elseif (-not $SelfSigned) {
    Write-Warn2 "No CA-issued certificate found for $fqdn."
    Write-Host "           A self-signed certificate will be created. It is trusted only on" -ForegroundColor Yellow
    Write-Host "           machines where it has been added to Trusted Root - every other" -ForegroundColor Yellow
    Write-Host "           browser will show a warning." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "           For a domain-trusted certificate, request one from the enterprise CA" -ForegroundColor Yellow
    Write-Host "           (WebServer template, subject CN=$fqdn) and re-run this script - it" -ForegroundColor Yellow
    Write-Host "           will detect and offer to re-use it." -ForegroundColor Yellow
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Read-only exit. Everything below this point creates, deletes, or binds.
# ---------------------------------------------------------------------------
if ($DetectOnly) {
    Write-Host ""
    Write-Host "  +--------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |  DETECTION RESULT (read-only - nothing was changed)     |" -ForegroundColor DarkCyan
    Write-Host "  +--------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""

    if ($cert) {
        Write-Host "  Would RE-USE a CA-issued certificate:" -ForegroundColor Green
        Write-Host "    Subject    : $($cert.Subject)" -ForegroundColor DarkGray
        Write-Host "    Issuer     : $($cert.Issuer)" -ForegroundColor DarkGray
        Write-Host "    Thumbprint : $($cert.Thumbprint)" -ForegroundColor DarkGray
        Write-Host "    Expires    : $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Result: HTTPS would be trusted domain-wide." -ForegroundColor Green
    } else {
        $reusableSelf = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
            $_.FriendlyName -like "$FriendlyPrefix*" -and
            $_.NotAfter -gt (Get-Date).AddDays(7) -and
            ($_.DnsNameList.Unicode -contains $fqdn -or $_.Subject -eq "CN=$fqdn")
        } | Sort-Object NotAfter -Descending | Select-Object -First 1

        if ($reusableSelf) {
            Write-Host "  Would RE-USE an existing self-signed certificate:" -ForegroundColor Yellow
            Write-Host "    Thumbprint : $($reusableSelf.Thumbprint)" -ForegroundColor DarkGray
            Write-Host "    Expires    : $($reusableSelf.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray
        } else {
            Write-Host "  Would CREATE a new self-signed certificate for CN=$fqdn" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Result: browser warnings on every machine except this one." -ForegroundColor Yellow
        Write-Host "  To get domain-wide trust, request a certificate from the enterprise CA" -ForegroundColor Yellow
        Write-Host "  (WebServer template, subject CN=$fqdn) and re-run - it will be detected." -ForegroundColor Yellow
    }

    # Show what was considered and rejected, so a "wrong" answer can be explained.
    Write-Host ""
    Write-Host "  Certificates examined in LocalMachine\My:" -ForegroundColor DarkGray
    foreach ($c in (Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue)) {
        $why = if ($c.Issuer -eq $c.Subject)      { 'self-signed, not CA-issued' }
               elseif ($c.Issuer -match 'SMS')    { 'ConfigMgr/SMS certificate - excluded by design' }
               elseif (-not $c.HasPrivateKey)     { 'no private key' }
               elseif ($c.NotAfter -le (Get-Date).AddDays(7)) { 'expired or expiring within 7 days' }
               elseif (-not (Test-UsableForServerAuth -Certificate $c)) { 'not valid for Server Authentication' }
               elseif ($cert -and $c.Thumbprint -eq $cert.Thumbprint) { 'SELECTED' }
               else { 'CA-issued but does not match this host name' }
        $col = if ($why -eq 'SELECTED') { 'Green' } else { 'DarkGray' }
        Write-Host ("    {0}  {1,-46} {2}" -f $c.Thumbprint.Substring(0,8), $c.Subject, $why) -ForegroundColor $col
    }
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
Write-Host "  [2/4] CERTIFICATE SELECTION" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$isSelfSigned = $false

if ($cert) {
    Write-Ok "Using CA-issued certificate $($cert.Thumbprint.Substring(0,8))..."
} else {
    $isSelfSigned = $true

    # Re-use a still-valid self-signed cert we previously created, rather than stacking up
    # a new one on every run.
    $existingSelf = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -like "$FriendlyPrefix*" -and
        $_.NotAfter -gt (Get-Date).AddDays(7) -and
        ($_.DnsNameList.Unicode -contains $fqdn -or $_.Subject -eq "CN=$fqdn")
    } | Sort-Object NotAfter -Descending | Select-Object -First 1

    if ($existingSelf) {
        Write-Ok "Re-using existing self-signed certificate"
        Write-Detail "Thumbprint : $($existingSelf.Thumbprint)"
        Write-Detail "Expires    : $($existingSelf.NotAfter.ToString('yyyy-MM-dd'))"
        $cert = $existingSelf
    } else {
        # Remove superseded self-signed certs, but never one bound to another port.
        $stale = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                 Where-Object { $_.FriendlyName -like "$FriendlyPrefix*" }
        foreach ($old in $stale) {
            if ($old.Thumbprint -in $boundHashes) {
                Write-Host "    [SKIP] Bound to another port: $($old.Thumbprint.Substring(0,8))..." -ForegroundColor DarkYellow
                continue
            }
            Remove-Item "Cert:\LocalMachine\My\$($old.Thumbprint)" -Force -ErrorAction SilentlyContinue
            Write-Info "Removed superseded certificate $($old.Thumbprint.Substring(0,8))..."
        }

        $cert = New-SelfSignedCertificate `
            -DnsName @($fqdn, $HostName, 'localhost') `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -FriendlyName "$FriendlyPrefix ($HostName)" `
            -NotAfter (Get-Date).AddYears(5) `
            -KeyLength 2048 `
            -KeyAlgorithm RSA `
            -HashAlgorithm SHA256 `
            -KeyUsage DigitalSignature, KeyEncipherment `
            -TextExtension @("2.5.29.37={text}$ServerAuthOid") `
            -Provider 'Microsoft RSA SChannel Cryptographic Provider' `
            -KeySpec KeyExchange

        # HTTP.SYS reads the private key as a service account; without this the binding
        # succeeds but the TLS handshake fails.
        try {
            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
            if ($rsa -and $rsa.CspKeyContainerInfo) {
                $keyPath = "$env:ALLUSERSPROFILE\Microsoft\Crypto\RSA\MachineKeys\$($rsa.CspKeyContainerInfo.UniqueKeyContainerName)"
                if (Test-Path $keyPath) { icacls $keyPath /grant "Everyone:RX" /Q | Out-Null }
            }
        } catch {
            Write-Warn2 "Could not update private key ACLs: $($_.Exception.Message)"
        }

        Write-Ok "Created self-signed certificate (SHA256)"
        Write-Detail "Subject    : CN=$fqdn"
        Write-Detail "Thumbprint : $($cert.Thumbprint)"
        Write-Detail "Expires    : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  [3/4] TRUST STORE" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
if ($isSelfSigned) {
    try {
        $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
        $rootStore.Open('ReadWrite')
        if (-not ($rootStore.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
            $rootStore.Add($cert)
            Write-Ok "Added to Trusted Root CAs on this machine"
        } else {
            Write-Ok "Already present in Trusted Root CAs"
        }
        $rootStore.Close()
        Write-Detail "Trusted on THIS machine only. Other clients will still warn."
        Write-Detail "Distribute via GPO, or request a CA certificate, for domain-wide trust."
    } catch {
        Write-Warn2 "Could not add to Root store: $($_.Exception.Message)"
    }
} else {
    Write-Ok "CA-issued certificate - chains to the enterprise CA, no Root import needed"
    Write-Detail "Trusted automatically by every domain-joined client."
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  [4/4] HTTPS BINDING" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$bound = $false

if ($SkipBinding -or -not $Port) {
    Write-Info "Skipped (no -Port supplied, or -SkipBinding specified)."
    Write-Detail "Thumbprint for manual binding: $($cert.Thumbprint)"
} else {
    foreach ($ipport in @("0.0.0.0:$Port", "[::]:$Port")) {
        try {
            netsh http delete sslcert ipport=$ipport 2>$null | Out-Null
            $result = netsh http add sslcert ipport=$ipport certhash=$($cert.Thumbprint) appid=$AppId certstorename=MY
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Bound to $ipport"
                $bound = $true
            } else {
                Write-Warn2 "Could not bind $ipport : $result"
            }
        } catch {
            Write-Warn2 "Could not bind $ipport : $($_.Exception.Message)"
        }
    }

    if ($bound) {
        $verify = netsh http show sslcert ipport=0.0.0.0:$Port 2>$null | Out-String
        if ($verify -match 'Certificate Hash\s*:\s*([0-9a-fA-F]+)') {
            Write-Ok "Verified binding on 0.0.0.0:$Port (hash $($Matches[1].Substring(0,8))...)"
        }
    }
}

Write-Host ""
Write-Host "  +--------------------------------------------------------+" -ForegroundColor DarkCyan
if ($bound -or $SkipBinding -or -not $Port) {
    Write-Host "  |  SSL CERTIFICATE READY                                 |" -ForegroundColor Green
} else {
    Write-Host "  |  SSL BINDING FAILED - dashboard will fall back to HTTP  |" -ForegroundColor Red
}
Write-Host "  +--------------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ""
if ($isSelfSigned) {
    Write-Host "  Certificate type : SELF-SIGNED (browser warning off this machine)" -ForegroundColor Yellow
} else {
    Write-Host "  Certificate type : CA-ISSUED (trusted domain-wide)" -ForegroundColor Green
}
Write-Host "  Thumbprint       : $($cert.Thumbprint)" -ForegroundColor DarkGray
Write-Host ""

Write-Output $cert.Thumbprint
