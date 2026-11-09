# Diagnoses why an installed agent does not show up on the monitoring dashboard. Read-only: it changes nothing
# and sends no monitoring data (the credential check posts an incomplete heartbeat that the server rejects with 422).
# Run in Windows PowerShell 5.1 as Administrator on the Windows file server:
#   powershell -ExecutionPolicy Bypass -File "C:\Program Files\OfficeMonitoringAgent\tools\diagnose.ps1"
param([string]$InstallDir)
$ErrorActionPreference = 'Continue'
$service = 'OfficeMonitoringAgent'
$key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service"
$bad = 0
function Ok($m) { Write-Host "[OK]    $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[GAGAL] $m" -ForegroundColor Red; $script:bad++ }
function Warn($m) { Write-Host "[CEK]   $m" -ForegroundColor Yellow }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# 1. Service and config
$svc = Get-Service $service -ErrorAction SilentlyContinue
if (-not $svc) { Bad "Service $service tidak ada. Jalankan installer."; exit 1 }
if (-not $InstallDir) { $InstallDir = Split-Path ((Get-ItemProperty $key).ImagePath.Trim('"')) }
$exe = Join-Path $InstallDir 'WindowsMonitoringAgent.exe'
$ver = (Get-Item $exe -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
if ($svc.Status -eq 'Running') { Ok "Service berjalan (versi $ver, $InstallDir)" } else { Bad "Service status $($svc.Status). Start-Service $service" }
$a = (Get-Content -LiteralPath (Join-Path $InstallDir 'appsettings.json') -Raw | ConvertFrom-Json).Agent
$url = "$($a.ApiBaseUrl)".TrimEnd('/')
Write-Host "        AgentId=$($a.AgentId)  Site=$($a.Site)  ApiBaseUrl=$url"
Write-Host "        AgentId harus sama persis dengan 'php artisan monitor:register-agent <agent_id> <site>' di server."

$uri = $null
if (-not [Uri]::TryCreate($url, 'Absolute', [ref]$uri) -or $uri.Scheme -ne 'https') { Bad "ApiBaseUrl bukan URL https://"; exit 1 }
$hostName = $uri.Host.Trim('[', ']')
$ip = $null
$isTs = [Net.IPAddress]::TryParse($hostName, [ref]$ip) -and $ip.GetAddressBytes().Length -eq 4 -and $ip.GetAddressBytes()[0] -eq 100 -and $ip.GetAddressBytes()[1] -ge 64 -and $ip.GetAddressBytes()[1] -le 127
$local = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | ForEach-Object { $_.GetIPProperties().UnicastAddresses } | ForEach-Object { $_.Address.ToString().Split('%')[0] }
if ($local -contains $hostName) { Bad "ApiBaseUrl $hostName adalah IP server INI sendiri, bukan server monitoring: agent mengirim ke dirinya sendiri. Perbaiki: powershell -ExecutionPolicy Bypass -File `"$InstallDir\tools\configure.ps1`" -InstallDir `"$InstallDir`" -ApiBaseUrl https://<IP Tailscale server monitoring>; lalu Restart-Service $service" }
elseif ($isTs) { Ok "ApiBaseUrl memakai IP Tailscale $hostName" }
elseif ($a.RequireTailscaleApi -ne $false) { Bad "ApiBaseUrl $hostName bukan IP Tailscale: agent menolak mengirim apa pun (RequireTailscaleApi). Jalankan ulang installer dan isi https://<IP Tailscale server monitoring>" }
else { Warn "ApiBaseUrl $hostName bukan IP Tailscale (RequireTailscaleApi=false)" }

# 2. Token in the service environment (never printed)
$envList = @((Get-ItemProperty $key -ErrorAction SilentlyContinue).Environment)
$tokenVar = if ($a.ApiKeyEnvironmentVariable) { $a.ApiKeyEnvironmentVariable } else { 'MONITOR_AGENT_API_KEY' }
$token = ($envList | Where-Object { $_ -like "$tokenVar=*" } | Select-Object -First 1)
if ($token) { $token = $token.Substring($tokenVar.Length + 1) } else { $token = [Environment]::GetEnvironmentVariable($tokenVar, 'Machine') }
if ($token) { Ok "Token agent terpasang ($($token.Length) karakter)" } else { Bad "Token $tokenVar tidak ada di registry service maupun environment Machine" }

# 3. Tailscale on this server
$ts = if ($a.Tailscale.ExePath) { $a.Tailscale.ExePath } else { 'C:\Program Files\Tailscale\tailscale.exe' }
if (Test-Path -LiteralPath $ts) {
    $st = & $ts status --json 2>$null | ConvertFrom-Json
    if ($st.BackendState -eq 'Running') { Ok "Tailscale aktif sebagai $($st.Self.HostName) ($($st.Self.TailscaleIPs -join ', '))" } else { Bad "Tailscale status $($st.BackendState): login/connect Tailscale di server ini" }
    $prefs = & $ts debug prefs 2>$null | ConvertFrom-Json
    if ($prefs -and -not $prefs.ForceDaemon) { Bad "Tailscale tidak 'Run unattended': koneksi putus saat user logoff. Klik ikon Tailscale > Preferences > Run unattended, atau: tailscale up --unattended" }
    elseif ($prefs) { Ok "Tailscale Run unattended aktif" }
    if ($isTs) {
        $peer = $st.Peer.PSObject.Properties.Value | Where-Object { $_.TailscaleIPs -contains $hostName } | Select-Object -First 1
        if ($peer) { Ok "Server monitoring terlihat di tailnet: $($peer.HostName) online=$($peer.Online)" }
        else { Bad "IP $hostName tidak ada di tailnet server ini (beda akun/tailnet, atau ACL Tailscale memblokir)" }
    }
    # Peer yang dipantau (dashboard "Koneksi Tailscale"): dicocokkan lewat Address (IP) lalu HostName mesin Tailscale.
    if (-not $a.Tailscale.Enabled) { Warn "Pemantauan peer Tailscale nonaktif (Agent.Tailscale.Enabled=false): dashboard tidak menampilkan koneksi Tailscale server ini" }
    elseif (-not $a.Tailscale.Peers) { Warn "Agent.Tailscale.Peers kosong: tidak ada peer yang dipantau" }
    else {
        foreach ($p in $a.Tailscale.Peers) {
            $m = $null
            if ($p.Address) { $m = $st.Peer.PSObject.Properties.Value | Where-Object { $_.TailscaleIPs -contains $p.Address } | Select-Object -First 1 }
            if (-not $m) { $m = $st.Peer.PSObject.Properties.Value | Where-Object { $_.HostName -eq $p.HostName -or ($_.DNSName -and $_.DNSName.Split('.')[0] -eq $p.HostName) } | Select-Object -First 1 }
            if ($m) { Ok "Peer $($p.Code) ditemukan: $($m.HostName) $($m.TailscaleIPs[0]) online=$($m.Online)" }
            else {
                $seen = ($st.Peer.PSObject.Properties.Value | ForEach-Object { "$($_.HostName) $($_.TailscaleIPs[0])" }) -join ', '
                Bad "Peer $($p.Code) (HostName '$($p.HostName)', Address '$($p.Address)') tidak ada di tailnet. Isi nama mesin/IP Tailscale yang benar di appsettings.json. Peer terlihat: $seen"
            }
        }
    }
} else { Bad "tailscale.exe tidak ditemukan ($ts): pasang Tailscale dan login ke tailnet yang sama dengan server monitoring" }

# 4. Network and TLS
$tcp = Test-NetConnection -ComputerName $hostName -Port $uri.Port -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) { Ok "TCP $hostName`:$($uri.Port) terhubung" } else { Bad "TCP $hostName`:$($uri.Port) tidak terhubung (Tailscale, firewall, atau nginx allow)" }
try {
    $r = Invoke-WebRequest -Uri "$url/up" -UseBasicParsing -TimeoutSec 15
    Ok "HTTPS $url/up -> HTTP $($r.StatusCode) (sertifikat dipercaya)"
} catch {
    $msg = $_.Exception.Message
    if ($_.Exception.InnerException) { $msg += ' / ' + $_.Exception.InnerException.Message }
    Bad "HTTPS $url/up gagal: $msg"
    # Bandingkan sertifikat yang dikirim server dengan yang ada di Trusted Root: setelah make-cert.sh dijalankan ulang di
    # server, sertifikat lama di Windows tidak lagi cocok dan SEMUA pengiriman agent gagal (termasuk Tailscale/Syncthing).
    $served = $null
    try {
        $tcpc = New-Object Net.Sockets.TcpClient($hostName, $uri.Port)
        $ssl = New-Object Net.Security.SslStream($tcpc.GetStream(), $false, ({ $true } -as [Net.Security.RemoteCertificateValidationCallback]))
        $ssl.AuthenticateAsClient($hostName)
        $served = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $ssl.Dispose(); $tcpc.Close()
    } catch { Warn "Tidak bisa membaca sertifikat server: $($_.Exception.Message)" }
    $roots = @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*CN=$hostName*" })
    if ($served) {
        Write-Host "        Sertifikat server: $($served.Subject) thumbprint $($served.Thumbprint), berlaku s/d $($served.NotAfter)"
        if ($roots.Thumbprint -contains $served.Thumbprint) { Warn "Sertifikat server sudah ada di Trusted Root; penyebab gagal di luar sertifikat (lihat pesan di atas)" }
        elseif ($roots) { Bad "Sertifikat di Trusted Root ($($roots.Thumbprint -join ', ')) BERBEDA dengan sertifikat server: sertifikat server sudah dibuat ulang. Perbaiki: powershell -ExecutionPolicy Bypass -File `"$InstallDir\tools\trust-server-cert.ps1`"" }
        else { Bad "Sertifikat server belum ada di Trusted Root. Perbaiki: powershell -ExecutionPolicy Bypass -File `"$InstallDir\tools\trust-server-cert.ps1`"" }
    } elseif (-not $roots) { Warn "Tidak ada sertifikat CN=$hostName di Trusted Root. Impor: certutil -addstore Root `"$InstallDir\certs\monitoring.crt`"" }
}

# 5. Agent credentials: 401 = token/AgentId salah, 422 = diterima (payload sengaja tidak lengkap, tidak disimpan)
if ($token) {
    try {
        $body = @{ agent_id = "$($a.AgentId)" } | ConvertTo-Json
        Invoke-WebRequest -Uri "$url/api/monitoring/agent/heartbeat" -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 15 `
            -Headers @{ Authorization = "Bearer $token"; 'X-Agent-Id' = "$($a.AgentId)"; Accept = 'application/json' } | Out-Null
        Ok "Kredensial agent diterima server"
    } catch {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -eq 422) { Ok "Kredensial agent '$($a.AgentId)' diterima server" }
        elseif ($code -eq 401) { Bad "Server menolak kredensial (401): AgentId '$($a.AgentId)' tidak terdaftar/nonaktif atau token salah. Di server: php artisan monitor:register-agent $($a.AgentId) $($a.Site), lalu pasang token baru lewat installer" }
        elseif ($code -eq 429) { Warn "Server membatasi request (429), ulangi sebentar lagi" }
        else { Bad "Uji kredensial gagal: $($_.Exception.Message)" }
    }
}

# 6. Recent agent errors
$events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'WindowsMonitoringAgent'; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 10 -ErrorAction SilentlyContinue |
    Where-Object { $_.Level -le 3 }
if ($events) {
    Warn "Error/peringatan agent 24 jam terakhir (Event Viewer > Application):"
    $events | ForEach-Object { Write-Host ("        {0:yyyy-MM-dd HH:mm} {1}" -f $_.TimeCreated, (($_.Message -split "`n")[0..2] -join ' ').Trim()) }
} else { Ok "Tidak ada error agent di Event Viewer 24 jam terakhir" }

Write-Host ''
if ($bad -eq 0) { Write-Host 'Semua pemeriksaan lolos. Bila dashboard tetap kosong, kirim output ini.' -ForegroundColor Green }
else { Write-Host "$bad pemeriksaan gagal. Perbaiki dari yang paling atas, lalu: Restart-Service $service" -ForegroundColor Red }
