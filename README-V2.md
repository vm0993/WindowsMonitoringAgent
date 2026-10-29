# Windows Monitoring Agent v2 — DFSR + Folder Activity

This package extends v1 without changing the existing file events and heartbeat request shapes. **Not yet validated on an actual Windows Server.** Windows Server integration testing is mandatory.

## What is collected

- Folder events via `FileSystemWatcher` (created/modified/deleted/renamed). Events survive temporary API outage in SQLite, but events during a stopped agent or watcher buffer overflow may be missed.
- DFSR service state and per-replication-route total backlog using `Get-DfsrBacklog -Verbose`. Collects each direction independently. On error returns `unknown` with null backlog.
- Heartbeat including offline-queue depth and folder watcher state.
- Folder manifest for data parity (`Parity`): path, size and last-write time of every file, per-directory bucket hashes, plus SHA-256 of a small deterministic sample of files (`ContentSampleFiles`, default 20 per folder per scan). Sampled files are read only to compute the hash; no document contents leave the server. `ContentSampleFiles=0` disables content reads.

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
- Does not verify NTFS ACLs or DFSR staging quota. Content parity is checked with full metadata (path/size/mtime) and a rotating content-hash sample, not a hash of every file.
- `FileSystemWatcher` still requires USN journal replay/reconciliation for gap-free historical tracking.
- Does not contain a Laravel backend. See API contract above.
- First-run tests on a Windows Server staging environment required before use with financial production data.

## Uji coba 3 server: DFSR + Syncthing via Tailscale

```
FS-UTAMA ──DFSR──▶ FS-MIRROR ──Syncthing (Send Only → Receive Only) via Tailscale──▶ FS-DC
 (domain AD)        (domain AD)                                                   (data center, di luar domain)
```

| Server | Contoh nama | Replikasi | Syncthing | Tailscale | Konfigurasi contoh |
|---|---|---|---|---|---|
| Utama | `FS-UTAMA` | DFSR → FS-MIRROR | – | – | `deploy/examples/appsettings.fs-utama.json` |
| Mirror | `FS-MIRROR` | Anggota DFSR, sumber Syncthing | **Send Only** | Ya | `deploy/examples/appsettings.fs-mirror.json` |
| Data center | `FS-DC` | Penerima Syncthing | **Receive Only** | Ya | `deploy/examples/appsettings.fs-dc.json` |

Nama server, path, dan device ID di file contoh harus diganti dengan nilai sebenarnya.

### Peran pengukuran

- **DFSR** diukur dari agent `FS-UTAMA` (utama → mirror, plus arah sebaliknya yang seharusnya tetap 0), termasuk status layanan DFSR di kedua server.
- **Syncthing** diukur dari kedua ujung:
  - `FS-MIRROR` melaporkan apakah tersambung ke DC, kelengkapan DC (%), dan item yang belum diterima DC.
  - `FS-DC` melaporkan item yang masih harus diterima dan **perubahan lokal** di folder Receive Only.
  - Keduanya memeriksa **tipe folder** (`ExpectedFolderType`) dan apakah koneksi lewat alamat Tailscale.
- **Tailscale** diukur dua arah antara `FS-MIRROR` dan `FS-DC`: state daemon, peer online, latensi `tailscale ping`, dan jalur langsung atau relay DERP.
- Agent tidak pernah mengubah konfigurasi DFSR, Syncthing, atau Tailscale.

### Persiapan

1. **DFSR utama → mirror.** Disarankan menjadikan keanggotaan FS-MIRROR *read-only* (`Set-DfsrMembership -GroupName RG-MIRROR -FolderName <folder> -ComputerName FS-MIRROR -ReadOnly $true`). Perubahan langsung di mirror tidak akan kembali ke utama. Syncthing Send Only hanya membaca, jadi tetap berfungsi.
2. **Syncthing di FS-MIRROR:** folder bertipe **Send Only**. Tambahkan `DfsrPrivate` ke `.stignore` karena folder ini berada di dalam root folder DFSR. Jalankan Syncthing dengan akun yang punya izin baca ke folder tersebut.
3. **Syncthing di FS-DC:** folder dengan **Folder ID yang sama** bertipe **Receive Only**. Aktifkan *File Versioning*, misalnya Staggered, agar file yang terhapus atau tertimpa masih bisa dipulihkan.
4. **Paksa jalur Tailscale.** Di kedua sisi:
   - isi alamat device lawan `tcp://<IP-Tailscale>:22000`;
   - matikan *Global Discovery*, *Local Discovery*, dan *Relaying*.

   Dengan begitu peringatan "Tidak via Tailscale" berarti ada konfigurasi yang bocor.
5. **API Syncthing:** biarkan GUI/API hanya mendengarkan `127.0.0.1:8384`. Simpan API key (GUI → Actions → Settings → API Key) di variabel environment Machine `SYNCTHING_API_KEY`, lalu restart service agent.
6. **Nilai konfigurasi:**
   - `FolderId` adalah *Folder ID* Syncthing, bukan label.
   - `RemoteDeviceId` adalah device ID lengkap server lawan.
   - `ExpectedFolderType`: `sendonly` di mirror, `receiveonly` di DC.

### Pendaftaran di server monitoring

```bash
php artisan migrate
php artisan monitor:register-agent fs-utama office
php artisan monitor:register-agent fs-mirror office
php artisan monitor:register-agent fs-dc datacenter
```

Rute Syncthing dan peer Tailscale yang ada di konfigurasi agent otomatis masuk daftar target lewat heartbeat. Target yang belum pernah mengirim pengukuran tampil "Belum ada data". Rute DFSR bisa didaftarkan sebelum agent berjalan dengan `php artisan monitor:dfsr-route`. Jalankan `deploy\check-prerequisites.ps1` di setiap server sebelum service dinyalakan.

### Arti status Syncthing

| Status | Arti |
|---|---|
| Tersinkron | Tidak ada item tertunda, DC lengkap 100%, dan tidak ada perubahan lokal di DC saat diperiksa |
| Sedang sinkronisasi | Syncthing sendiri melaporkan proses sync |
| Tertinggal | Masih ada item yang belum diterima DC, tanpa aktivitas sync |
| Isi berbeda | File di DC diubah langsung (Receive Only), atau mirror menolak versi dari remote. Perlu *Revert Local Changes* di DC atau pemeriksaan |
| Tipe folder salah | Tipe folder tidak sesuai `ExpectedFolderType` (misalnya DC terpasang Send & Receive) |
| Tidak via Tailscale | Tersambung, tetapi bukan lewat alamat Tailscale |
| Terputus / Gangguan | Peer tidak tersambung / folder Syncthing melaporkan error |

### Skenario uji

| Skenario | Hasil yang diharapkan di dashboard |
|---|---|
| Buat/ubah file di FS-UTAMA | Aktivitas folder bertambah. Backlog DFSR naik lalu 0. Syncthing "Sedang sinkronisasi" lalu "Tersinkron". |
| Salin folder besar (mis. 2 GB) ke FS-UTAMA | DFSR backlog lalu Syncthing: item tertunda menurun, kelengkapan DC < 100% sampai selesai. |
| Ubah/hapus file langsung di FS-DC | Syncthing (agent FS-DC) "Isi berbeda" sampai *Revert Local Changes*. |
| Ubah tipe folder DC ke Send & Receive | "Tipe folder salah". |
| Matikan Tailscale di FS-DC | Tailscale "Tailscale mati" (dari FS-DC) atau "Tidak terjangkau" (dari FS-MIRROR). Syncthing "Terputus". DFSR tidak terpengaruh. |
| Blokir jalur langsung (UDP 41641) | Tailscale "Lewat relay", latensi naik, Syncthing tetap terhubung. |
| Hentikan service Syncthing di FS-MIRROR | Rute dari agent FS-MIRROR "Belum dapat diperiksa". Dari FS-DC "Terputus". |
| Hentikan service DFSR di FS-MIRROR | Rute DFSR "Gangguan" dengan nama server yang berhenti. Syncthing tetap tersinkron (data mirror tidak bertambah). |
| Putus koneksi agent FS-DC ke API monitoring 10 menit | Agent "Belum melapor". Setelah tersambung antrean terkirim. Sampel lama masuk riwayat tanpa menggantikan kondisi terbaru. |
| Matikan FS-DC | Agent FS-DC "Belum melapor", Tailscale dari FS-MIRROR "Tidak terjangkau", Syncthing "Terputus". |
| Salin file baru ke FS-UTAMA | Kesamaan Data "Menunggu replikasi" lalu "Isi sama" setelah pemindaian berikutnya di kedua sisi. |
| Hapus file langsung di FS-DC (tanpa diketahui Syncthing, mis. saat service mati) | Kesamaan Data utama → DC "Isi berbeda" dengan folder yang terdampak. |
| Ubah isi file di FS-DC lalu kembalikan ukuran dan waktu ubahnya | "Isi file berbeda" bila file itu masuk sampel hari itu. |

"Tersinkron" pada DFSR maupun Syncthing hanya berarti tidak ada antrean terukur saat diperiksa. Apakah isi replika sama dengan sumber diperiksa terpisah oleh **Kesamaan Data** (di bawah).

## Kesamaan data (sumber vs replika)

Setiap agent dengan `Parity.Enabled=true` memindai semua `Folders` tiap `IntervalSeconds` (default 15 menit) dan mengirim manifest ke `POST /api/monitoring/agent/parity`. Server membandingkan manifest terbaru sumber dan replika untuk setiap pasangan yang didaftarkan:

```bash
php artisan monitor:parity-pair finance-utama-mirror fs-utama fs-mirror finance --label="Keuangan (utama → mirror)"
php artisan monitor:parity-pair finance-utama-dc     fs-utama fs-dc     finance --label="Keuangan (utama → DC)"
# ulangi untuk investment, pension, letters, board; --replica-folder=<code> bila Code folder di replika berbeda
```

Yang dibandingkan:

- **Daftar file**: path, ukuran, dan waktu ubah setiap file, serta nama setiap folder (termasuk folder kosong). Waktu ubah folder tidak dibandingkan karena berubah sendiri di setiap replika. Hasilnya dikelompokkan per folder sampai kedalaman `BucketDepth` (default 2, misalnya `2026/Oktober`), sehingga folder yang berbeda bisa ditunjukkan.
- **Isi file**: SHA-256 dari `ContentSampleFiles` file yang dipilih dengan cara yang sama di setiap server. Pilihan file berganti setiap hari (UTC), jadi lama-kelamaan semua file ikut terperiksa. File yang terkunci atau berubah saat dibaca dilewati.
- **Tidak dibandingkan**: `DfsrPrivate`, `.stfolder`, `.stversions`, `.stignore`, `$RECYCLE.BIN`, `System Volume Information`, `~*`, `*.tmp`, `*.bak`, `Thumbs.db`, `desktop.ini`, file ber-atribut Temporary, dan reparse point. Ini mengikuti filter bawaan DFSR. Bila `Exclude` diisi, isinya menggantikan daftar bawaan dan harus sama di semua agent.

| Status | Arti |
|---|---|
| Isi sama | Daftar file, ukuran, dan waktu ubah sama persis; sampel isi cocok |
| Menunggu replikasi | Perbedaan hanya ada di folder yang berubah ±15 menit sebelum pemindaian (`MONITORING_PARITY_SETTLE_SECONDS`) |
| Isi berbeda | Perbedaan ada di folder yang sudah lama tidak berubah; folder yang terdampak ditampilkan |
| Isi file berbeda | Nama, ukuran, dan waktu ubah sama, tetapi hash isinya berbeda (kemungkinan file rusak) |
| Sebagian tak terbaca | Yang terbaca sama, tetapi ada folder/file yang tidak dapat dibaca akun service |
| Pemindaian gagal / Data terlambat / Belum ada data | Tidak pernah dianggap sama |

Akun service agent harus punya izin baca ke seluruh isi folder di kedua sisi. Jika tidak, status menjadi "Sebagian tak terbaca", atau "Isi berbeda" bila izinnya tidak sama di kedua sisi. Pemindaian hanya membaca metadata, kecuali file sampel. Ukur durasinya di server sebenarnya (kolom durasi di halaman *Kesamaan Data*) sebelum memperkecil `IntervalSeconds`.
