# Run elevated. Set server-wide MONITOR_AGENT_API_KEY securely BEFORE starting.
# Install and upgrade both use this script: an existing service is stopped, binaries are replaced,
# and the server's appsettings.json is kept (the new default is saved as appsettings.json.new).
param(
    [string]$Source = "$PSScriptRoot\..\publish",
    [string]$Destination = "C:\Program Files\OfficeMonitoringAgent",
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$service = 'OfficeMonitoringAgent'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script as Administrator' }
if (-not (Test-Path (Join-Path $Source 'WindowsMonitoringAgent.exe'))) { throw "Missing publish folder or executable in $Source" }

$existing = Get-Service $service -ErrorAction SilentlyContinue
if ($existing -and $existing.Status -ne 'Stopped') {
    Write-Host "Stopping $service ..."
    Stop-Service $service -Force
    $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$config = Join-Path $Destination 'appsettings.json'
$keepConfig = Test-Path $config
Get-ChildItem -LiteralPath $Source | Where-Object { -not ($keepConfig -and $_.Name -eq 'appsettings.json') } |
    Copy-Item -Destination $Destination -Recurse -Force
if ($keepConfig) {
    Copy-Item (Join-Path $Source 'appsettings.json') (Join-Path $Destination 'appsettings.json.new') -Force
    Write-Host 'Kept existing appsettings.json; compare with appsettings.json.new for new settings.'
}

$exe = Join-Path $Destination 'WindowsMonitoringAgent.exe'
if (-not $existing) {
    New-Service -Name $service -DisplayName 'Office Windows Monitoring Agent' -BinaryPathName ('"'+$exe+'"') -StartupType Automatic -Description 'Monitors departmental file metadata and reports to monitoring API.' | Out-Null
    sc.exe failure $service reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    Write-Host "Service $service created."
    Write-Host 'Review service account access, system API key and appsettings.json, then: Start-Service OfficeMonitoringAgent'
    return
}

$version = (Get-Item $exe).VersionInfo.ProductVersion
if ($NoStart) { Write-Host "Upgraded to $version (service left stopped)."; return }
Start-Service $service
Write-Host "Upgraded to $version; service status: $((Get-Service $service).Status)"
