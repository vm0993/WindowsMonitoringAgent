# Trusts the monitoring server's CURRENT self-signed certificate on an installed agent, e.g. after make-cert.sh was run
# again on the server (new names/IPs) and the agent stopped delivering ("The remote certificate is invalid").
# Run in Windows PowerShell 5.1 as Administrator:
#   powershell -ExecutionPolicy Bypass -File "C:\Program Files\OfficeMonitoringAgent\tools\trust-server-cert.ps1"
#   [-CertFile C:\temp\monitoring.crt]   use this file instead of reading the certificate from the server
#   [-ExpectedThumbprint <SHA1>]          refuse unless the server certificate has this thumbprint
# Without -CertFile the certificate is read from ApiBaseUrl, which must be a Tailscale IP: the Tailscale tunnel already
# authenticates the server, so the certificate seen there is the server's own. Older certificates with the same CN are
# removed from Trusted Root, then the service is restarted.
param([string]$CertFile, [string]$ExpectedThumbprint, [string]$InstallDir)
$ErrorActionPreference = 'Stop'
$service = 'OfficeMonitoringAgent'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Jalankan sebagai Administrator' }
if (-not $InstallDir) { $InstallDir = Split-Path ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$service").ImagePath.Trim('"')) }
$a = (Get-Content -LiteralPath (Join-Path $InstallDir 'appsettings.json') -Raw | ConvertFrom-Json).Agent
$uri = [Uri]("$($a.ApiBaseUrl)".TrimEnd('/'))
$hostName = $uri.Host.Trim('[', ']')
$ip = $null
$isTs = [Net.IPAddress]::TryParse($hostName, [ref]$ip) -and $ip.GetAddressBytes().Length -eq 4 -and $ip.GetAddressBytes()[0] -eq 100 -and $ip.GetAddressBytes()[1] -ge 64 -and $ip.GetAddressBytes()[1] -le 127

if ($CertFile) {
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path -LiteralPath $CertFile).Path)
} else {
    if (-not $isTs) { throw "ApiBaseUrl $($a.ApiBaseUrl) bukan IP Tailscale: berikan -CertFile dari server (fullchain.pem)" }
    $tcp = New-Object Net.Sockets.TcpClient($hostName, $uri.Port)
    try {
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true } -as [Net.Security.RemoteCertificateValidationCallback]))
        $ssl.AuthenticateAsClient($hostName)
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $ssl.Dispose()
    } finally { $tcp.Close() }
}
$sha256 = (([Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData) | ForEach-Object { $_.ToString('X2') }) -join ':')
Write-Host "Sertifikat : $($cert.Subject)  berlaku s/d $($cert.NotAfter)"
Write-Host "SAN        : $(($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }).Format($false))"
Write-Host "Thumbprint : $($cert.Thumbprint)"
Write-Host "SHA-256    : $sha256"
if ($ExpectedThumbprint -and ($ExpectedThumbprint -replace '[\s:]', '') -ne $cert.Thumbprint -and ($ExpectedThumbprint -replace '[\s:]', '') -ne ($sha256 -replace ':', '')) {
    throw "Thumbprint tidak sama dengan -ExpectedThumbprint: sertifikat TIDAK diimpor"
}
if ($cert.Subject -notlike "*CN=$hostName*" -and -not $CertFile) { Write-Warning "CN sertifikat tidak sama dengan $hostName" }

$store = New-Object Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
$store.Open('ReadWrite')
try {
    foreach ($old in @($store.Certificates | Where-Object { $_.Subject -eq $cert.Subject -and $_.Thumbprint -ne $cert.Thumbprint })) {
        $store.Remove($old); Write-Host "Dihapus sertifikat lama $($old.Thumbprint) (dibuat $($old.NotBefore))"
    }
    if ($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }) { Write-Host 'Sertifikat sudah dipercaya.' }
    else { $store.Add($cert); Write-Host 'Sertifikat ditambahkan ke Trusted Root.' }
} finally { $store.Close() }

# Keep the installed copy in sync so a later repair/upgrade does not re-import the old one.
$certDir = Join-Path $InstallDir 'certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null
$pem = "-----BEGIN CERTIFICATE-----`r`n" + [Convert]::ToBase64String($cert.RawData, 'InsertLineBreaks') + "`r`n-----END CERTIFICATE-----`r`n"
[IO.File]::WriteAllText((Join-Path $certDir 'monitoring.crt'), $pem, (New-Object Text.UTF8Encoding($false)))

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { Write-Host "Tes HTTPS $($a.ApiBaseUrl)/up : HTTP $((Invoke-WebRequest -Uri "$($a.ApiBaseUrl.TrimEnd('/'))/up" -UseBasicParsing -TimeoutSec 15).StatusCode)" }
catch { Write-Warning "Tes HTTPS masih gagal: $($_.Exception.Message)" }
if (Get-Service $service -ErrorAction SilentlyContinue) { Restart-Service $service; Write-Host "Service $service di-restart. Cek lagi dengan tools\diagnose.ps1" }
