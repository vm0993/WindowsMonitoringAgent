# Reads the real DFSR topology on this server (replication groups, replicated folders, connections) and writes
# Agent.Dfsr.Routes in appsettings.json, so routes never carry example names such as RG-MIRROR or FS-MIRROR.
# DFSR replicates both ways, so every replicated folder gets one route per connection (A -> B and B -> A).
# Run in Windows PowerShell 5.1 as Administrator on the DFSR member that runs the agent (FS-UTAMA / dp00):
#   powershell -ExecutionPolicy Bypass -File dfsr-routes.ps1            # preview only
#   powershell -ExecutionPolicy Bypass -File dfsr-routes.ps1 -Apply     # backup, write appsettings.json, restart agent
#   [-GroupName "Nama RG"]  limit to one replication group
param([switch]$Apply, [string]$GroupName, [string]$InstallDir)
$ErrorActionPreference = 'Stop'
$service = 'OfficeMonitoringAgent'
Import-Module DFSR
if (-not $InstallDir) { $InstallDir = Split-Path ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$service").ImagePath.Trim('"')) }
$config = Join-Path $InstallDir 'appsettings.json'
$json = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
$me = $env:COMPUTERNAME

function Get-Slug([string]$s) { (($s.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) }
# Route code starts with the agent folder code so the dashboard links DFSR to "Folder per bagian".
function Get-FolderCode([string]$folderName) {
    foreach ($f in $json.Agent.Folders) {
        if ($f.Name -ieq $folderName -or (Split-Path $f.Path -Leaf) -ieq $folderName) { return $f.Code }
    }
    return (Get-Slug $folderName)
}

$groups = @(Get-DfsReplicationGroup | Where-Object { -not $GroupName -or $_.GroupName -ieq $GroupName })
if (-not $groups) { throw "Tidak ada replication group DFSR$(if ($GroupName) { " bernama $GroupName" })" }
$routes = New-Object System.Collections.Generic.List[object]
foreach ($g in $groups) {
    $connections = @(Get-DfsrConnection -GroupName $g.GroupName | Where-Object {
        $_.Enabled -and ($_.SourceComputerName.Split('.')[0] -ieq $me -or $_.DestinationComputerName.Split('.')[0] -ieq $me) })
    if (-not $connections) { continue }
    foreach ($rf in @(Get-DfsReplicatedFolder -GroupName $g.GroupName)) {
        $code = Get-FolderCode $rf.FolderName
        foreach ($c in $connections) {
            $src = $c.SourceComputerName.Split('.')[0].ToUpperInvariant()
            $dst = $c.DestinationComputerName.Split('.')[0].ToUpperInvariant()
            $routes.Add([pscustomobject]@{
                Code = "$code-$($src.ToLowerInvariant())-$($dst.ToLowerInvariant())"
                GroupName = $g.GroupName
                FolderName = $rf.FolderName
                SourceComputer = $src
                DestinationComputer = $dst
            })
        }
    }
}
if (-not $routes.Count) { throw "Server $me tidak punya koneksi DFSR aktif" }
$routes | Sort-Object FolderName, SourceComputer | Format-Table Code, GroupName, FolderName, SourceComputer, DestinationComputer -AutoSize
$folders = @($routes | Select-Object -ExpandProperty FolderName -Unique).Count
Write-Host "$folders folder x 2 arah = $($routes.Count) rute (DFSR mereplikasi dua arah; backlog diukur per arah)."

$unmatched = @($routes | Where-Object { -not ($json.Agent.Folders | Where-Object Code -eq ($_.Code -replace '-[^-]+-[^-]+$', '')) } | Select-Object -ExpandProperty FolderName -Unique)
if ($unmatched) { Write-Warning "Folder DFSR tanpa pasangan di Agent.Folders (kode dibuat dari nama): $($unmatched -join ', ')" }

# Get-DfsrBacklog runs as the agent account (LocalSystem = computer account $me$) and needs admin rights on the partner.
$partners = @($routes | ForEach-Object { $_.SourceComputer, $_.DestinationComputer } | Where-Object { $_ -ine $me } | Select-Object -Unique)
Write-Host "Catatan: akun service agent harus Administrator di $($partners -join ', ') (mis. tambahkan '$me`$' atau akun domain service ke grup Administrators di sana), kalau tidak backlog tetap 'Belum dapat diperiksa'."

if (-not $Apply) { Write-Host "`nPratinjau saja. Jalankan ulang dengan -Apply untuk menyimpan."; exit 0 }
$backup = "$config.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item -LiteralPath $config -Destination $backup
$json.Agent.Dfsr.Enabled = $true
$json.Agent.Dfsr.Routes = @($routes | Sort-Object FolderName, SourceComputer)
[IO.File]::WriteAllText($config, ($json | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
Restart-Service $service
Write-Host "Disimpan ($($routes.Count) rute), cadangan: $backup. Service $service di-restart."
Write-Host "Di server monitoring, hapus rute lama berisi nama contoh: php artisan monitor:dfsr-prune $($json.Agent.AgentId)"
