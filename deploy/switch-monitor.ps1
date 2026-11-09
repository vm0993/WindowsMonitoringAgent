# Temporarily points an installed agent at another monitoring server (e.g. a developer's monitoring-api over
# Tailscale) and restores the original afterwards. Run in Windows PowerShell 5.1 as Administrator.
#   Switch : .\switch-monitor.ps1 -ApiBaseUrl https://100.73.134.0:8443 -Token <token> -CertFile C:\temp\monitor-local.crt
#   Restore: .\switch-monitor.ps1 -Restore
# The original ApiBaseUrl and token are kept in the agent data directory (readable by SYSTEM/Administrators only).
# Events queued while switched are delivered to the test server; the production server only sees new ones after restore.
param(
    [string]$ApiBaseUrl,
    [string]$Token,
    [string]$CertFile,
    [switch]$Restore
)
$ErrorActionPreference = 'Stop'
$service = 'OfficeMonitoringAgent'
$key = "HKLM:\SYSTEM\CurrentControlSet\Services\$service"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Jalankan sebagai Administrator' }
$installDir = Split-Path ((Get-ItemProperty $key).ImagePath.Trim('"'))
$config = Join-Path $installDir 'appsettings.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$json = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
$tokenVar = if ($json.Agent.ApiKeyEnvironmentVariable) { $json.Agent.ApiKeyEnvironmentVariable } else { 'MONITOR_AGENT_API_KEY' }
$backup = Join-Path $json.Agent.DataDirectory 'switch-backup.json'

function Get-ServiceToken { @((Get-ItemProperty $key).Environment) | Where-Object { $_ -like "$tokenVar=*" } | ForEach-Object { $_.Substring($tokenVar.Length + 1) } | Select-Object -First 1 }
function Set-ServiceToken([string]$Value) {
    $envList = @(@((Get-ItemProperty $key).Environment) | Where-Object { $_ -and $_ -notlike "$tokenVar=*" }) + "$tokenVar=$Value"
    Set-ItemProperty -Path $key -Name Environment -Type MultiString -Value ([string[]]$envList)
}
function Set-ApiUrl([string]$Url) {
    $json.Agent.ApiBaseUrl = $Url.TrimEnd('/')
    [IO.File]::WriteAllText($config, ($json | ConvertTo-Json -Depth 20), $utf8)
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $backup)) { throw "Tidak ada cadangan ${backup}: agent belum pernah dialihkan" }
    $b = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    Set-ApiUrl $b.ApiBaseUrl
    if ($b.Token) { Set-ServiceToken $b.Token }
    Remove-Item -LiteralPath $backup -Force
    Restart-Service $service
    Write-Host "Dikembalikan ke $($b.ApiBaseUrl). Service di-restart."
    exit 0
}

if (-not $ApiBaseUrl -or -not $Token) { throw 'Isi -ApiBaseUrl dan -Token, atau pakai -Restore' }
if ($Token.Length -lt 32) { throw 'Token terlalu pendek: salin token lengkap dari monitor:register-agent' }
if (-not (Test-Path -LiteralPath $backup)) {
    # Only the first switch saves the original, so switching twice never loses the production values.
    $b = @{ ApiBaseUrl = $json.Agent.ApiBaseUrl; Token = (Get-ServiceToken); SavedAt = (Get-Date).ToString('s') } | ConvertTo-Json
    [IO.File]::WriteAllText($backup, $b, $utf8)
    Write-Host "Cadangan konfigurasi produksi: $backup"
}
if ($CertFile) {
    certutil.exe -f -addstore Root $CertFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Gagal mengimpor $CertFile ke Trusted Root" }
    Write-Host "Sertifikat dipercaya: $CertFile"
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { Write-Host "Uji $ApiBaseUrl/up : HTTP $((Invoke-WebRequest -Uri "$($ApiBaseUrl.TrimEnd('/'))/up" -UseBasicParsing -TimeoutSec 15).StatusCode)" }
catch { Write-Warning "Server test belum bisa dihubungi: $($_.Exception.Message)" }
Set-ApiUrl $ApiBaseUrl
Set-ServiceToken $Token
Restart-Service $service
Write-Host "Agent $($json.Agent.AgentId) sekarang mengirim ke $ApiBaseUrl. Kembalikan dengan: .\switch-monitor.ps1 -Restore"
