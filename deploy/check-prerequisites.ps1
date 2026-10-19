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
$envName=$c.Agent.ApiKeyEnvironmentVariable
if(-not [Environment]::GetEnvironmentVariable($envName,'Machine')){Write-Warning "Missing Machine environment variable $envName (set securely before service start)"}
Write-Host 'Preflight completed; resolve warnings before production deployment.'
