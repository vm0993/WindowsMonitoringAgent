namespace WindowsMonitoringAgent;

public sealed class AgentOptions
{
    public string AgentId { get; set; } = "fs01-office";
    public string Site { get; set; } = "office";
    public string ApiBaseUrl { get; set; } = "https://monitor.example.com";
    public string ApiKeyEnvironmentVariable { get; set; } = "MONITOR_AGENT_API_KEY";
    public string DataDirectory { get; set; } = @"C:\ProgramData\OfficeMonitoringAgent";
    public int BatchSize { get; set; } = 200;
    // Server thresholds (config/monitoring.php) assume these values: agent offline after 90 s without heartbeat.
    public int SendIntervalSeconds { get; set; } = 5;
    public int HeartbeatIntervalSeconds { get; set; } = 30;
    public int FileEventDebounceSeconds { get; set; } = 3;
    // How often folders are re-checked so watchers are (re)created when a folder appears or a watcher fails.
    public int FolderCheckSeconds { get; set; } = 30;
    // Upper bound on "reconciled" events emitted by the rescan after a watcher outage.
    public int MaxReconcileEvents { get; set; } = 5000;
    public List<FolderDefinition> Folders { get; set; } = [];
    public DfsrOptions Dfsr { get; set; } = new();
    public SyncthingOptions Syncthing { get; set; } = new();
    public TailscaleOptions Tailscale { get; set; } = new();
    public ParityOptions Parity { get; set; } = new();
}
public sealed class FolderDefinition
{
    public string Code { get; set; } = "";
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
}

public sealed class DfsrOptions
{
    public bool Enabled { get; set; } = false;
    public int IntervalSeconds { get; set; } = 60;
    public int CommandTimeoutSeconds { get; set; } = 90;
    public List<DfsrRoute> Routes { get; set; } = [];
}
public sealed class DfsrRoute
{
    public string Code { get; set; } = "";
    public string GroupName { get; set; } = "";
    public string FolderName { get; set; } = "";
    public string SourceComputer { get; set; } = "";
    public string DestinationComputer { get; set; } = "";
}

// Syncthing is used for servers outside the AD domain (e.g. the data-center server), where DFSR cannot be used.
public sealed class SyncthingOptions
{
    public bool Enabled { get; set; } = false;
    // Local Syncthing GUI/REST address. A self-signed certificate is only accepted for loopback addresses.
    public string BaseUrl { get; set; } = "https://127.0.0.1:8384";
    public string ApiKeyEnvironmentVariable { get; set; } = "SYNCTHING_API_KEY";
    // Local REST calls are cheap; server marks data stale after 60 s.
    public int IntervalSeconds { get; set; } = 15;
    // The peer connection must use a Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48); otherwise it is flagged.
    public bool RequireTailscale { get; set; } = true;
    public List<SyncthingRoute> Routes { get; set; } = [];
}
public sealed class SyncthingRoute
{
    public string Code { get; set; } = "";
    public string FolderId { get; set; } = "";
    public string FolderLabel { get; set; } = "";
    public string RemoteDeviceId { get; set; } = "";
    public string RemoteName { get; set; } = "";
    // Expected Syncthing folder type on this host: "sendonly", "receiveonly" or "sendreceive"; empty = not checked.
    public string ExpectedFolderType { get; set; } = "";
}
public sealed class TailscaleOptions
{
    public bool Enabled { get; set; } = false;
    public string ExePath { get; set; } = @"C:\Program Files\Tailscale\tailscale.exe";
    // Each peer costs one ping (up to PingTimeoutSeconds); server marks data stale after 90 s.
    public int IntervalSeconds { get; set; } = 30;
    public int PingTimeoutSeconds { get; set; } = 5;
    public List<TailscalePeer> Peers { get; set; } = [];
}
public sealed class TailscalePeer
{
    public string Code { get; set; } = "";
    // Tailscale machine name (HostName or first label of the MagicDNS name).
    public string HostName { get; set; } = "";
}
// Folder manifests compared by the server between a source and its replica (same Folder Code on both agents).
public sealed class ParityOptions
{
    public bool Enabled { get; set; } = false;
    // A full scan reads metadata of every file; server marks the result stale after monitoring.parity_max_age (1 h).
    public int IntervalSeconds { get; set; } = 900;
    // Differences are reported per directory up to this depth (e.g. 2 = "2026/Oktober").
    public int BucketDepth { get; set; } = 2;
    // Above this many buckets the agent merges them into a shallower depth.
    public int MaxBuckets { get; set; } = 1000;
    // Files read for a SHA-256 content check per folder per scan (0 = metadata only). Same files on every server.
    public int ContentSampleFiles { get; set; } = 20;
    public long ContentSampleMaxFileBytes { get; set; } = 100L*1024*1024;
    // Names (any level, wildcards * and ?) left out of the comparison. Empty = DefaultExclude; a configured list
    // replaces the defaults, so it must be identical on the source and replica agents.
    public List<string> Exclude { get; set; } = [];
    // Not replicated by DFSR default file filter (~*, *.bak, *.tmp) or by Syncthing, or system folders.
    public static readonly IReadOnlyList<string> DefaultExclude=["DfsrPrivate",".stfolder",".stversions",".stignore","$RECYCLE.BIN","System Volume Information","~*","*.tmp","*.bak","Thumbs.db","desktop.ini"];
    public IReadOnlyList<string> EffectiveExclude => Exclude.Count>0 ? Exclude : DefaultExclude;
}
