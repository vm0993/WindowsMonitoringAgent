$service = 'OfficeMonitoringAgent'
if (Get-Service $service -ErrorAction SilentlyContinue) {
 Stop-Service $service -ErrorAction SilentlyContinue
 sc.exe delete $service
}
Write-Host 'Persistent SQLite queue remains under C:\ProgramData\OfficeMonitoringAgent; do not delete until exported.'
