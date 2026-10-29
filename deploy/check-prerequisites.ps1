param([string]$ConfigPath = "$PSScriptRoot\..\appsettings.json")
$ErrorActionPreference='Stop'
Write-Host 'Windows Monitoring Agent v2 - preflight checks'
if(-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'Must run on Windows' }
if(-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$c=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if($c.Agent.ApiBaseUrl -notmatch '^https://') { throw 'API URL must use HTTPS' }
if([string]::IsNullOrWhiteSpace($c.Agent.AgentId)) { throw 'AgentId required' }
foreach($f in $c.Agent.Folders){
 if(Test-Path -LiteralPath $f.Path -PathType Container){Write-Host "OK folder: $($f.Path)"}
 else {Write-Warning "Folder missing or not readable: $($f.Path)"}
}
if($c.Agent.Dfsr.Enabled){
 if(-not (Get-Module -ListAvailable DFSR)){throw 'DFSR PowerShell module missing. Install RSAT DFS Management Tools / DFSR role.'}
 $svc=Get-Service DFSR -ErrorAction Stop
 Write-Host "DFSR service: $($svc.Status)"
 foreach($r in $c.Agent.Dfsr.Routes){
  Write-Host "Query DFSR: $($r.SourceComputer) -> $($r.DestinationComputer) / $($r.GroupName) / $($r.FolderName)"
  try {
    $items=@(Get-DfsrBacklog -GroupName $r.GroupName -FolderName $r.FolderName -SourceComputerName $r.SourceComputer -DestinationComputerName $r.DestinationComputer -ErrorAction Stop)
    Write-Host "Query OK; $($items.Count) sample items returned (max 100, NOT total backlog)"
  }catch{Write-Warning "Query FAILED: $($_.Exception.Message)"}
 }
}
if($c.Agent.Syncthing.Enabled){
 $stEnv=$c.Agent.Syncthing.ApiKeyEnvironmentVariable
 $stKey=[Environment]::GetEnvironmentVariable($stEnv,'Machine')
 if(-not $stKey){Write-Warning "Missing Machine environment variable $stEnv (Syncthing GUI > Actions > Settings > API Key)"}
 else {
  try {
    # Windows PowerShell 5.1 has no -SkipCertificateCheck; Syncthing's self-signed loopback cert is accepted only for this check.
    [Net.ServicePointManager]::ServerCertificateValidationCallback={$true}
    $h=@{'X-API-Key'=$stKey}
    $conn=(Invoke-RestMethod -Uri "$($c.Agent.Syncthing.BaseUrl)/rest/system/connections" -Headers $h -TimeoutSec 10).connections
    foreach($r in $c.Agent.Syncthing.Routes){
      $st=Invoke-RestMethod -Uri "$($c.Agent.Syncthing.BaseUrl)/rest/db/status?folder=$([uri]::EscapeDataString($r.FolderId))" -Headers $h -TimeoutSec 10
      $peer=$conn.PSObject.Properties | Where-Object {$_.Name -eq $r.RemoteDeviceId} | Select-Object -First 1
      if(-not $peer){Write-Warning "Syncthing $($r.Code): device $($r.RemoteName) not configured"; continue}
      $type=(Invoke-RestMethod -Uri "$($c.Agent.Syncthing.BaseUrl)/rest/config/folders/$([uri]::EscapeDataString($r.FolderId))" -Headers $h -TimeoutSec 10).type
      Write-Host "Syncthing $($r.Code): type=$type, folder state=$($st.state), connected=$($peer.Value.connected), address=$($peer.Value.address)"
      if($r.ExpectedFolderType -and $type -ne $r.ExpectedFolderType){Write-Warning "Syncthing $($r.Code): folder type is $type, expected $($r.ExpectedFolderType)"}
      if($type -eq 'receiveonly' -and $st.receiveOnlyTotalItems -gt 0){Write-Warning "Syncthing $($r.Code): $($st.receiveOnlyTotalItems) item(s) changed locally on receive-only folder"}
      if($peer.Value.connected -and $peer.Value.address -notmatch '(^|//|\[)(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|fd7a:115c:a1e0:)'){Write-Warning "Syncthing $($r.Code) is NOT connected over Tailscale: $($peer.Value.address)"}
    }
  } catch {Write-Warning "Syncthing API check FAILED: $($_.Exception.Message)"}
  finally {[Net.ServicePointManager]::ServerCertificateValidationCallback=$null}
 }
}
if($c.Agent.Tailscale.Enabled){
 $exe=$c.Agent.Tailscale.ExePath
 if(-not (Test-Path -LiteralPath $exe)){Write-Warning "tailscale.exe not found: $exe"}
 else {
  $ts=& $exe status --json | ConvertFrom-Json
  Write-Host "Tailscale: $($ts.BackendState) as $($ts.Self.HostName)"
  foreach($p in $c.Agent.Tailscale.Peers){
    $peer=$ts.Peer.PSObject.Properties.Value | Where-Object {$_.HostName -eq $p.HostName -or $_.DNSName.Split('.')[0] -eq $p.HostName} | Select-Object -First 1
    if(-not $peer){Write-Warning "Tailscale peer $($p.HostName) not found"; continue}
    Write-Host "Ping $($p.HostName) ($($peer.TailscaleIPs[0])): $(& $exe ping --c 1 --timeout 5s $peer.TailscaleIPs[0] 2>&1)"
  }
 }
}
$envName=$c.Agent.ApiKeyEnvironmentVariable
if(-not [Environment]::GetEnvironmentVariable($envName,'Machine')){Write-Warning "Missing Machine environment variable $envName (set securely before service start)"}
Write-Host 'Preflight completed; resolve warnings before production deployment.'
