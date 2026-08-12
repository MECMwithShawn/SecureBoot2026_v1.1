#requires -Version 5.1
param(
    [int]$Port = 8091
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'index.html'))) {
    $root = 'C:\SecureBoot2026'
}

if (-not (Test-Path (Join-Path $root 'index.html'))) {
    Write-Error "index.html not found in $root"
    exit 1
}

$useHttps = $false
try {
    $sslBinding = netsh http show sslcert ipport=0.0.0.0:$Port 2>$null | Out-String
    if ($sslBinding -match 'Certificate Hash\s*:\s*[0-9a-fA-F]+') { $useHttps = $true }
} catch { }

$fqdn = try { [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }

$httpsPrefixSets = @(
    @("https://$fqdn`:$Port/", "https://$env:COMPUTERNAME`:$Port/", "https://localhost:$Port/"),
    @("https://$fqdn`:$Port/", "https://localhost:$Port/"),
    @("https://localhost:$Port/")
)
$httpPrefixSets = @(
    @("http://$fqdn`:$Port/", "http://$env:COMPUTERNAME`:$Port/", "http://localhost:$Port/"),
    @("http://$fqdn`:$Port/", "http://localhost:$Port/"),
    @("http://localhost:$Port/")
)

$bound = $false
$activeScheme = $null
$activePrefixes = $null
$httpsError = $null

if ($useHttps) {
    foreach ($set in $httpsPrefixSets) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
            foreach ($p in $set) { $listener.Prefixes.Add($p) }
            $listener.Start()
            $bound = $true; $activeScheme = 'https'; $activePrefixes = $set
            break
        } catch {
            $httpsError = $_.Exception.Message
            try { $listener.Close() } catch { }
        }
    }
}

if (-not $bound) {
    foreach ($set in $httpPrefixSets) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
            foreach ($p in $set) { $listener.Prefixes.Add($p) }
            $listener.Start()
            $bound = $true; $activeScheme = 'http'; $activePrefixes = $set
            break
        } catch {
            try { $listener.Close() } catch { }
        }
    }
}

if ($bound) {
    Write-Host "Secure Boot 2026 Web Dashboard Service started on: $($activePrefixes -join ', ')" -ForegroundColor Green
    if ($activeScheme -eq 'https') {
        Write-Host "SSL: Enabled (certificate bound to port $Port)" -ForegroundColor Green
    } elseif ($useHttps) {
        Write-Host "SSL: Certificate bound but HTTPS failed - serving plain HTTP." -ForegroundColor Yellow
        if ($httpsError) { Write-Host "     Last HTTPS error: $httpsError" -ForegroundColor Yellow }
    } else {
        Write-Host "SSL: Disabled (no certificate bound to port $Port)" -ForegroundColor Yellow
    }
}

if (-not $bound) {
    Write-Host ""
    Write-Host "=====================================================================" -ForegroundColor Red
    Write-Host " ERROR: Could not bind to port $Port with any prefix." -ForegroundColor Red
    Write-Host " Please ensure the port is not in use and run as Administrator." -ForegroundColor Red
    Write-Host "=====================================================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
}

$canonicalRoot = [System.IO.Path]::GetFullPath($root)

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            $path = $request.Url.LocalPath
            if ($path -eq '/') { $path = '/index.html' }

            $normalizedPath = $path.Replace('/', '\').TrimStart('\')
            $filePath = [System.IO.Path]::GetFullPath((Join-Path $root $normalizedPath))

            if (-not $filePath.StartsWith($canonicalRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $response.StatusCode = 403
                $body = [System.Text.Encoding]::UTF8.GetBytes("403 Forbidden")
                $response.ContentLength64 = $body.Length
                $response.OutputStream.Write($body, 0, $body.Length)
                $response.OutputStream.Close()
                continue
            }

            if (Test-Path $filePath -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
                $contentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
                
                $response.ContentType = $contentType
                $response.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
                $response.Headers.Add("Pragma", "no-cache")
                $response.Headers.Add("Expires", "0")

                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentLength64 = $bytes.Length
                $response.StatusCode = 200
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
            } else {
                $response.StatusCode = 404
                $body = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                $response.ContentLength64 = $body.Length
                $response.OutputStream.Write($body, 0, $body.Length)
                $response.OutputStream.Close()
            }
        } catch {
            try {
                $response.StatusCode = 500
                $response.OutputStream.Close()
            } catch {}
        }
    }
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
}
