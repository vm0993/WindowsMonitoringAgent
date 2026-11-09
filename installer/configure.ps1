# Called by the setup wizard (OfficeMonitoringAgent.iss); can also be rerun by hand to reconfigure.
# Fresh install: copies the example config of the chosen role. Existing install (upgrade): rebuilds the config from the
# example of the same role (examples\appsettings.<AgentId>.json, or -SyncRole) so every server has the same layout
# (folders, DFSR, Syncthing, Tailscale, Parity), keeping only server-specific values: API URL, AgentId, Site, data
# directory, folder paths, DFSR computer names, Syncthing device IDs and Tailscale peer names/IPs. The old file is
# kept as appsettings.json.bak-<time> when anything changes. -NoSync keeps the existing config untouched.
# The agent token is NOT handled here; setup writes it to the service registry.
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
    [string]$SyncRole,     # upgrade: example to align with when AgentId is not a role name (fs-utama, fs-mirror, fs-dc)
    [switch]$NoSync,
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

# IP addresses of this machine (incl. its Tailscale IP): ApiBaseUrl must point at the monitoring server, not here.
function Get-LocalAddresses {
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } | ForEach-Object { $_.Address.ToString().Split('%')[0].ToLowerInvariant() }
}
function Has($o, [string]$n) { $null -ne $o -and $o.PSObject.Properties.Name -contains $n }
# A value worth keeping from the installed config: set, and not an example placeholder.
function Keep($v) { $null -ne $v -and "$v" -ne '' -and "$v" -notmatch '^(REPLACE-|https://TAILSCALE-IP)' }
function Copy-Fields($from, $to, [string[]]$names) {
    foreach ($n in $names) { if ((Has $from $n) -and (Keep $from.$n)) { if (Has $to $n) { $to.$n = $from.$n } else { $to | Add-Member -NotePropertyName $n -NotePropertyValue $from.$n } } }
}
function Find-ByCode($list, [string]$code) { @($list) | Where-Object { $_ -and $_.Code -eq $code } | Select-Object -First 1 }
# Example layout + server-specific values of the installed config (see header).
function Sync-WithExample($cur, $ex) {
    $c = $cur.Agent; $a = $ex.Agent
    Copy-Fields $c $a @('AgentId', 'Site', 'ApiBaseUrl', 'ApiKeyEnvironmentVariable', 'DataDirectory')
    # Folder paths by Code; a folder new to this server goes next to the existing ones (same parent directory).
    $parent = @($c.Folders) | Where-Object { $_ -and $_.Path } | ForEach-Object { Split-Path $_.Path -Parent } | Select-Object -First 1
    foreach ($f in @($a.Folders)) {
        $old = Find-ByCode $c.Folders $f.Code
        if ($old -and (Keep $old.Path)) { $f.Path = $old.Path }
        elseif ($parent) { $f.Path = $parent.TrimEnd('\') + '\' + (Split-Path $f.Path -Leaf) }
    }
    # Routes written from the real DFSR topology (deploy\dfsr-routes.ps1 -Apply) carry no example names: keep them as is.
    $oldDfsr = @($c.Dfsr.Routes) | Where-Object { $_ }
    $realDfsr = $oldDfsr.Count -gt 0 -and -not ($oldDfsr | Where-Object { "$($_.GroupName) $($_.SourceComputer) $($_.DestinationComputer)" -match '\b(RG-MIRROR|FS-UTAMA|FS-MIRROR|FS-DC)\b' })
    if ($realDfsr) { $a.Dfsr.Routes = $oldDfsr; $a.Dfsr.Enabled = $c.Dfsr.Enabled }
    else { foreach ($r in @($a.Dfsr.Routes)) { $old = Find-ByCode $c.Dfsr.Routes $r.Code; if ($old) { Copy-Fields $old $r @('GroupName', 'SourceComputer', 'DestinationComputer') } } }
    if (Has $c 'Syncthing') { Copy-Fields $c.Syncthing $a.Syncthing @('BaseUrl', 'ApiKeyEnvironmentVariable') }
    # Device IDs by route Code, else from another route to the same remote server (one device ID per server),
    # else the only device ID the installed config knows.
    $oldRoutes = @($c.Syncthing.Routes) | Where-Object { $_ -and (Keep $_.RemoteDeviceId) }
    $onlyId = @($oldRoutes | ForEach-Object { $_.RemoteDeviceId } | Select-Object -Unique)
    foreach ($r in @($a.Syncthing.Routes)) {
        $old = Find-ByCode $c.Syncthing.Routes $r.Code
        if ($old) { Copy-Fields $old $r @('RemoteDeviceId', 'RemoteName') }
        if (Keep $r.RemoteDeviceId) { continue }
        $same = $oldRoutes | Where-Object { $_.RemoteName -and $_.RemoteName -eq $r.RemoteName } | Select-Object -First 1
        if ($same) { $r.RemoteDeviceId = $same.RemoteDeviceId }
        elseif ($onlyId.Count -eq 1) { $r.RemoteDeviceId = $onlyId[0] }
    }
    if (Has $c 'Tailscale') { Copy-Fields $c.Tailscale $a.Tailscale @('ExePath') }
    foreach ($p in @($a.Tailscale.Peers)) {
        $old = Find-ByCode $c.Tailscale.Peers $p.Code
        if (-not $old) { continue }
        # Role names ("fs-mirror") are not Tailscale machine names: those are replaced by the example's name.
        if ((Keep $old.HostName) -and $old.HostName -notmatch '^fs-(utama|mirror|dc)$') { $p.HostName = $old.HostName }
        Copy-Fields $old $p @('Address')
    }
    if ((Has $c 'Parity') -and (Has $c.Parity 'Exclude') -and @($c.Parity.Exclude).Count -gt 0) { $a.Parity.Exclude = @($c.Parity.Exclude) }
    return $ex
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
$apiHost = ([Uri]$json.Agent.ApiBaseUrl).Host.Trim('[', ']').ToLowerInvariant()
if (@(Get-LocalAddresses) -contains $apiHost) {
    throw "ApiBaseUrl $($json.Agent.ApiBaseUrl) adalah IP server INI sendiri, bukan server monitoring. Isi IP Tailscale server monitoring (mis. https://100.88.53.5): jalankan ulang dengan -ApiBaseUrl https://<IP server monitoring>"
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
if (-not $fresh -and -not $NoSync) {
    $syncName = if ($SyncRole) { $SyncRole } else { $json.Agent.AgentId }
    $ex = Join-Path (Join-Path $InstallDir 'examples') "appsettings.$syncName.json"
    if (Test-Path -LiteralPath $ex) {
        $before = $json | ConvertTo-Json -Depth 20 -Compress
        $json = Sync-WithExample $json (Get-Content -LiteralPath $ex -Raw | ConvertFrom-Json)
        if (($json | ConvertTo-Json -Depth 20 -Compress) -ne $before) {
            $bak = "$config.bak-$(Get-Date -Format yyyyMMddHHmmss)"
            Copy-Item -LiteralPath $config -Destination $bak
            Write-Host "appsettings.json diselaraskan dengan $(Split-Path $ex -Leaf); versi lama: $(Split-Path $bak -Leaf)"
        } else { Write-Host "appsettings.json sudah sesuai $(Split-Path $ex -Leaf)" }
    } else {
        Write-Warning "Tidak ada contoh konfigurasi untuk AgentId '$($json.Agent.AgentId)': appsettings.json tidak diselaraskan. Jalankan ulang dengan -SyncRole fs-utama|fs-mirror|fs-dc"
    }
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
