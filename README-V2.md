# Windows Monitoring Agent v2 — DFSR + Folder Activity

This package extends v1 without changing the existing file events and heartbeat request shapes. **Not yet validated on an actual Windows Server.** Windows Server integration testing is mandatory.

## What is collected

- Folder events via `FileSystemWatcher` (created/modified/deleted/renamed). Events survive temporary API outage in SQLite, but events during a stopped agent or watcher buffer overflow may be missed.
- DFSR service state and per-replication-route total backlog using `Get-DfsrBacklog -Verbose`. Collects each direction independently. On error returns `unknown` with null backlog.
- Heartbeat including offline-queue depth and folder watcher state.
- No document contents are read.

`caught_up` means **backlog count 0 at query time**, NOT proof that every file matches, not proof of backup, and not proof DFSR membership is healthy. Alert logic must incorporate freshness, health checks and DFSR Event Log (future enhancement).

## Fast installation (Windows Server 2022/2025)

1. Ensure DFS Replication service and DFSR PowerShell module available. Create/test DFSR replication groups separately; **this agent will not configure or alter DFSR**.
2. Use Windows PowerShell 5.1 as Administrator. Copy project to a development computer with .NET 10 SDK:

```powershell
dotnet restore
dotnet publish .\WindowsMonitoringAgent.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\publish
```

3. Edit `publish\appsettings.json`, including `ApiBaseUrl`, folders, DFSR group names, route source/destination server names. Enable `Agent.Dfsr.Enabled=true` and define **both** directions for every DFSR replicated folder you need to monitor. `FolderName` must be the DFSR *replicated folder name*, not necessarily the underlying directory name.
4. Run `deploy\check-prerequisites.ps1 -ConfigPath .\publish\appsettings.json` on the Windows server. When running remote backlog queries, use a domain service account authorized to inspect DFSR and able to reach both partner servers over the necessary AD/RPC ports; test command under the actual service identity. Using LocalSystem may not work across machines depending on AD permissions. Avoid Domain Admin rights if not necessary.
5. Set `MONITOR_AGENT_API_KEY` as a **machine-level** environment variable using your enterprise secrets deployment process. Avoid embedding it in the JSON or shell history. Protect it using system ACLs. Restart the service after changing it.
6. Install using elevated PowerShell `deploy\install.ps1 -Source .\publish`; then `Start-Service OfficeMonitoringAgent`. Confirm `Get-Service OfficeMonitoringAgent` and use Event Viewer/application logs. Service install does not auto-assign a domain identity: set it via Services MMC / enterprise service-management, with `Log on as a service` privilege.
7. Backend must implement below endpoints, authenticate the agent and respond HTTP 2xx only **after durable, idempotent persistence**.

## Endpoints

`POST /api/monitoring/agent/events` — Existing v1 payload `{agent_id, site, events:[{id,folder_code,relative_path,action,occurred_at_utc,is_directory,size_bytes}]}`.

`POST /api/monitoring/agent/heartbeat` — Existing v1 payload `{agent_id,site,host_name,observed_at_utc,pending_events,folders:[...]}`.

`POST /api/monitoring/agent/dfsr` — New v2 payload (envelope snake_case, result fields camelCase — matches `AgentController::dfsr`):

```json
{
  "agent_id":"fs01-office", "site":"office",
  "results":[{
    "id":"7cd3d1bb5c8f4e89aa30cd541383a134",
    "code":"finance-out", "groupName":"RG-OFFICE", "folderName":"Keuangan",
    "sourceComputer":"FS-KANTOR", "destinationComputer":"FS-DC",
    "serviceStatus":"running", "backlogCount":5, "status":"backlog",
    "error":null, "checkedAtUtc":"2026-10-16T08:00:00+00:00"
  }]
}
```

Use an SQL unique index on `(agent_id, event_id)` to deduplicate retried events and DFSR samples; do not use file path as the unique identifier. Each new sample has its own GUID.

## Recommended dashboard states

- `unknown` / stale: failed measurement, missing agent, or old timestamp.
- `backlog`: count > 0, normally syncing, not necessarily failure.
- `caught_up`: query reported zero backlog, not proof of end-to-end file parity.
- `critical`: service stopped. Do not label 'healthy' unless event logs, membership and both directions are checked.

## Non-goals / limitations

- Not DFSR install/repair, not file backup or file replication itself.
- Does not verify NTFS ACLs, file hashes, DFSR staging quota, or end-to-end content parity.
- `FileSystemWatcher` still requires USN journal replay/reconciliation for gap-free historical tracking.
- Does not contain a Laravel backend. See API contract above.
- First-run tests on a Windows Server staging environment required before use with financial production data.
