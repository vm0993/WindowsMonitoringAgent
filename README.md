# Windows Monitoring Agent v2

Start with [README-V2.md](README-V2.md).

# Office Windows Monitoring Agent (.NET 10 Worker Service)

Windows Service prototype for **folder metadata activity**, departmental last-change summaries, durable local delivery queue, and host heartbeat. Designed for FS01 with Laravel monitoring backend. **It does not copy/synchronize files, read document contents, or confirm that a destination received files.** Sync status must be obtained from the actual replication engine.

## Components
- `FileSystemWatcher` receives create/change/delete/rename events recursively.
- SQLite queue (`C:\ProgramData\OfficeMonitoringAgent\queue.sqlite`) keeps metadata until a successful HTTP response.
- HTTPS JSON batch push with a service-specific Bearer token from an environment variable.
- Heartbeat reports pending queue size, monitored folder availability, and watcher-error timestamps.
- No file contents are uploaded. Relative paths **do contain sensitive filenames**; restrict API permissions and retention.

## Build on Windows (.NET 10 SDK)
```powershell
cd WindowsMonitoringAgent
dotnet restore
dotnet build -c Release
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\publish
```

## Release otomatis via GitHub Actions
Workflow `.github/workflows/release.yml` membangun exe win-x64 self-contained (single file) di runner Ubuntu.
- Push/PR ke `main` → build saja; paket zip tersedia sebagai *workflow artifact* (14 hari).
- Push tag `v*` → build + **GitHub Release** berisi `OfficeMonitoringAgent-<versi>-win-x64.zip` dan `.sha256`.

```bash
git tag v2.0.1 && git push origin v2.0.1
```

Di server Windows (PowerShell Administrator) — install pertama maupun upgrade:
```powershell
# repo private: $env:GITHUB_TOKEN = '<fine-grained token, Contents: read-only>'
.\deploy\update.ps1 -Repo owner/windows-monitoring-agent          # rilis terbaru
.\deploy\update.ps1 -Repo owner/windows-monitoring-agent -Tag v2.0.1
```
`update.ps1` mengunduh rilis, memverifikasi SHA-256, lalu menjalankan `install.ps1`, yang menghentikan service, mengganti binary, **mempertahankan `appsettings.json` di server** (default baru disimpan sebagai `appsettings.json.new`), lalu menyalakan service lagi. Pada install pertama service dibuat tapi belum distart.

Edit the *published* `appsettings.json` (paths, API base URL, stable agent ID). Create folders beforehand. Use `https://` for the API. Restrict the folder list to those actually being monitored.

## Authentication and permissions
Set `MONITOR_AGENT_API_KEY` as a machine-level protected environment variable or through a dedicated service identity's secret provisioning process. Never commit it into config or source code. Example for a **lab only**:
```powershell
[Environment]::SetEnvironmentVariable('MONITOR_AGENT_API_KEY', 'REPLACE_WITH_LONG_RANDOM_TOKEN', 'Machine')
```
The service needs read/list access to monitored folders, write access to its `DataDirectory`, and outbound TCP 443 only to the monitoring API (ideally across Tailscale). Run with a dedicated low-privilege service account instead of LocalSystem after configuring folder and data-directory ACLs. Windows Service environment changes may require restarting the service. Deny regular users access to the SQLite folder as it contains filenames.

Run as administrator:
```powershell
.\deploy\install.ps1 -Source .\publish
Start-Service OfficeMonitoringAgent
Get-Service OfficeMonitoringAgent
```
If running interactively during testing:
```powershell
$env:MONITOR_AGENT_API_KEY = 'YOUR_TEST_TOKEN'
dotnet run
```

## Laravel API contract

`POST /api/monitoring/agent/events`, Bearer auth + `X-Agent-Id: fs01-office`:
```json
{
  "agent_id": "fs01-office",
  "site": "office",
  "events": [{"id":"eb8701c08d894151a4e6a7fb9a870a46","folder_code":"finance","relative_path":"2026/report.xlsx","action":"modified","occurred_at_utc":"2026-10-16T06:00:00+00:00","is_directory":false,"size_bytes":1024}]
}
```
Server MUST insert events using a UNIQUE `(agent_id, id)` key and commit the entire batch atomically before returning **2xx**. On any error return non-2xx. The agent retries whole batches; client does not implement partial acknowledgement.

`POST /api/monitoring/agent/heartbeat`:
```json
{
 "agent_id":"fs01-office","site":"office","host_name":"FS01",
 "observed_at_utc":"2026-10-16T06:00:00+00:00","pending_events":0,
 "folders":[{"code":"finance","name":"Keuangan","root":"D:\\Shared\\Keuangan","available":true,"last_change_at_utc":null,"watcher_error_at_utc":null}]
}
```

Apply backend request rate limiting, token revocation/rotation, TLS verification, payload size limits and audit logging. Validate folder codes against registered agents. Do not expose arbitrary document paths to unauthorized dashboard users.

## Critical limitations / production hardening backlog
1. **Not lossless:** `FileSystemWatcher` can miss activity while agent offline, during buffer overflow, or across Windows reboot. An error timestamp is sent but a real production system should add **NTFS USN Journal checkpoint reading and baseline reconciliation** (not implemented). Do not use this prototype to certify backup completeness.
2. Events are edge notifications; the `modified` event is not proof a file's write is completed. Multiple events may merge due to debounce. File size may be unavailable for locked files. Renames produce `renamed_from` and `renamed_to` entries.
3. The store is synchronous SQLite for durable local queuing. Very high change rates require a bounded ingestion worker and measured load testing, plus a disk-usage alert for the queue.
4. Last folder change is session-memory only; reload from backend after a service restart. Agent timestamp is UTC; dashboard should convert to Asia/Jakarta.
5. No full disk/server metrics, replication status, or NAS sync verification here. Collect from Windows Exporter, Proxmox, MariaDB and the selected sync engine separately.
6. Authentication is a bearer token over TLS, not mTLS. For high-security deployment add short-lived credential rotation or mTLS, server-side idempotency, and protected machine secrets.
7. A successfully received event means the monitoring API stored metadata, **not** that the document was backed up or synchronized.
8. Folder permission failures at runtime and missing folders need operator alerts and a watcher reinitialization strategy (service restart). Current watchdog only sends heartbeat state.

## Verify
- Start service and check `Get-Service OfficeMonitoringAgent`.
- Save a file to `D:\Shared\Keuangan`, then rename and delete it.
- Verify POST batches and persisted events in Laravel.
- Block API temporarily: SQLite `pending_events` should accumulate and drain when connectivity returns.
- Restart service and confirm queue persists.
- Trigger backup/sync and compare receiver-side actual status independently.
- Conduct burst tests with thousands of files; verify event loss/overflow reporting.
