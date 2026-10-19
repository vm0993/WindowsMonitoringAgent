# Run elevated on the Windows server. Downloads a GitHub Release built by
# .github/workflows/release.yml, verifies its SHA-256, and installs/upgrades the service.
# Private repo: set $env:GITHUB_TOKEN (fine-grained token, Contents: read-only) before running.
param(
    [Parameter(Mandatory = $true)][string]$Repo,   # e.g. "owner/windows-monitoring-agent"
    [string]$Tag = 'latest',                       # or e.g. "v2.0.1"
    [string]$Destination = "C:\Program Files\OfficeMonitoringAgent"
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$headers = @{ 'User-Agent' = 'OfficeMonitoringAgent-Updater'; 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
$api = if ($Tag -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" } else { "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
$release = Invoke-RestMethod -Uri $api -Headers $headers
$zip = $release.assets | Where-Object { $_.name -like '*-win-x64.zip' } | Select-Object -First 1
$sum = $release.assets | Where-Object { $_.name -like '*-win-x64.zip.sha256' } | Select-Object -First 1
if (-not $zip -or -not $sum) { throw "Release $($release.tag_name) has no win-x64 package" }

$work = Join-Path $env:TEMP ("OfficeMonitoringAgent-" + $release.tag_name)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work | Out-Null
$dl = $headers.Clone(); $dl.Accept = 'application/octet-stream'
$zipPath = Join-Path $work $zip.name
Write-Host "Downloading $($release.tag_name) ..."
Invoke-WebRequest -Uri $zip.url -Headers $dl -OutFile $zipPath -UseBasicParsing
$sumPath = Join-Path $work $sum.name
Invoke-WebRequest -Uri $sum.url -Headers $dl -OutFile $sumPath -UseBasicParsing
$expected = ((Get-Content -LiteralPath $sumPath -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash
if ($actual -ne $expected.ToUpperInvariant()) { throw "SHA-256 mismatch: expected $expected, got $actual" }

Expand-Archive -LiteralPath $zipPath -DestinationPath $work -Force
& (Join-Path $work 'deploy\install.ps1') -Source (Join-Path $work 'publish') -Destination $Destination
