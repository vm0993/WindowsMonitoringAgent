# Called by the setup wizard (OfficeMonitoringAgent.iss); can also be rerun by hand to reconfigure.
# Fresh install: copies the example config of the chosen role. Existing install: keeps the config and only
# updates the values passed in. The agent token is NOT handled here; setup writes it to the service registry.
param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [string]$Role = 'default',
    [string]$ApiBaseUrl,
    [string]$AgentId,
    [string]$Site,
    [string]$DataRoot,
    [string]$CertFile,
    [string]$ReadConfig,   # read mode: write ApiBaseUrl/AgentId/Site of this config to -OutFile and exit
    [string]$OutFile,
    [string]$LogFile,
    [switch]$NoService
)
$ErrorActionPreference = 'Stop'
$service = 'OfficeMonitoringAgent'
$utf8 = New-Object System.Text.UTF8Encoding($false)
# Tailscale IP only: 100.64.0.0/10 or fd7a:115c:a1e0::/48. Host names, LAN and public IPs are refused.
function Test-TailscaleUrl([string]$Url) {
    try { $h = ([Uri]$Url).Host.Trim('[', ']').ToLowerInvariant() } catch { return $false }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($h, [ref]$ip)) { return $false }
    $b = $ip.GetAddressBytes()
    if ($b.Length -eq 4) { return $b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127 }
    return $b[0] -eq 0xfd -and $b[1] -eq 0x7a -and $b[2] -eq 0x11 -and $b[3] -eq 0x5c -and $b[4] -eq 0xa1 -and $b[5] -eq 0xe0
}

if ($ReadConfig) {
    $a = (Get-Content -LiteralPath $ReadConfig -Raw | ConvertFrom-Json).Agent
    [IO.File]::WriteAllLines($OutFile, [string[]]@($a.ApiBaseUrl, $a.AgentId, $a.Site), $utf8)
    exit 0
}

if ($LogFile) { Start-Transcript -LiteralPath $LogFile -Append | Out-Null }
Write-Host "Configure $service in $InstallDir (role $Role)"
$config = Join-Path $InstallDir 'appsettings.json'
$fresh = -not (Test-Path -LiteralPath $config)
if ($fresh) {
    $example = Join-Path (Join-Path $InstallDir 'examples') "appsettings.$Role.json"
    if (-not (Test-Path -LiteralPath $example)) { $example = Join-Path (Join-Path $InstallDir 'examples') 'appsettings.default.json' }
    Copy-Item -LiteralPath $example -Destination $config
    Write-Host "Created appsettings.json from $(Split-Path $example -Leaf)"
}

$json = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
if ($ApiBaseUrl) { $json.Agent.ApiBaseUrl = $ApiBaseUrl.TrimEnd('/') }
if (-not (Test-TailscaleUrl $json.Agent.ApiBaseUrl)) {
    throw "ApiBaseUrl $($json.Agent.ApiBaseUrl) bukan IP Tailscale (100.64.0.0/10). Jalankan ulang dengan -ApiBaseUrl https://<IP Tailscale server monitoring>"
}
if ($json.Agent.PSObject.Properties.Name -notcontains 'RequireTailscaleApi') {
    $json.Agent | Add-Member -NotePropertyName RequireTailscaleApi -NotePropertyValue $true
} else { $json.Agent.RequireTailscaleApi = $true }
if ($AgentId) { $json.Agent.AgentId = $AgentId }
if ($Site) { $json.Agent.Site = $Site }
# Only on a fresh install: on upgrade the folder list may already have been edited by hand.
if ($fresh -and $DataRoot) {
    # Plain concatenation: a drive root ("D:" from setup) must give D:\Keuangan, and Join-Path fails on a missing drive.
    foreach ($f in $json.Agent.Folders) { $f.Path = $DataRoot.TrimEnd('\') + '\' + (Split-Path $f.Path -Leaf) }
}
[IO.File]::WriteAllText($config, ($json | ConvertTo-Json -Depth 20), $utf8)
foreach ($f in $json.Agent.Folders) {
    if (Test-Path -LiteralPath $f.Path -PathType Container) { Write-Host "OK folder: $($f.Path)" }
    else { Write-Warning "Folder missing or not readable: $($f.Path)" }
}

# The queue lists file names, so only SYSTEM and Administrators may read it (add the service account if changed).
$data = $json.Agent.DataDirectory
New-Item -ItemType Directory -Force -Path $data | Out-Null
if ($fresh) { icacls $data /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null }

if (-not $NoService -and -not (Get-Service $service -ErrorAction SilentlyContinue)) {
    $exe = Join-Path $InstallDir 'WindowsMonitoringAgent.exe'
    New-Service -Name $service -DisplayName 'Office Windows Monitoring Agent' -BinaryPathName ('"' + $exe + '"') -StartupType Automatic -Description 'Monitors departmental file metadata and reports to monitoring API.' | Out-Null
    sc.exe failure $service reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    Write-Host "Service $service created."
}

if ($CertFile) {
    certutil.exe -f -addstore Root $CertFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not import certificate $CertFile into Trusted Root" }
    Write-Host "Trusted certificate $CertFile"
}

# Exit code 2 = installed, but the monitoring server is not reachable (setup shows a warning, not an error).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$up = "$($json.Agent.ApiBaseUrl)/up"
try {
    $status = (Invoke-WebRequest -Uri $up -UseBasicParsing -TimeoutSec 15).StatusCode
    Write-Host "Connection test $up : HTTP $status"
} catch {
    Write-Warning "Connection test $up failed: $($_.Exception.Message)"
    exit 2
}
exit 0
