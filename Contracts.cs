using System.Text.Json.Serialization;
namespace WindowsMonitoringAgent;
public record FolderEvent(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("folder_code")] string FolderCode,
    [property: JsonPropertyName("relative_path")] string RelativePath,
    [property: JsonPropertyName("action")] string Action,
    [property: JsonPropertyName("occurred_at_utc")] DateTimeOffset OccurredAtUtc,
    [property: JsonPropertyName("is_directory")] bool IsDirectory,
    [property: JsonPropertyName("size_bytes")] long? SizeBytes);
public record BatchPayload(
    [property: JsonPropertyName("agent_id")] string AgentId,
    [property: JsonPropertyName("site")] string Site,
    [property: JsonPropertyName("events")] IReadOnlyList<FolderEvent> Events);
public record FolderState(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("root")] string Root,
    [property: JsonPropertyName("available")] bool Available,
    [property: JsonPropertyName("last_change_at_utc")] DateTimeOffset? LastChangeAtUtc,
    [property: JsonPropertyName("watcher_error_at_utc")] DateTimeOffset? WatcherErrorAtUtc,
    // Folder access and watcher state are separate: an existing folder is not necessarily being watched.
    [property: JsonPropertyName("watcher_active")] bool WatcherActive,
    [property: JsonPropertyName("watcher_recovered_at_utc")] DateTimeOffset? WatcherRecoveredAtUtc);
public record DfsrRouteInfo(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("group_name")] string GroupName,
    [property: JsonPropertyName("folder_name")] string FolderName,
    [property: JsonPropertyName("source_computer")] string SourceComputer,
    [property: JsonPropertyName("destination_computer")] string DestinationComputer);
public record HeartbeatPayload(
    [property: JsonPropertyName("agent_id")] string AgentId,
    [property: JsonPropertyName("site")] string Site,
    [property: JsonPropertyName("host_name")] string HostName,
    [property: JsonPropertyName("observed_at_utc")] DateTimeOffset ObservedAtUtc,
    [property: JsonPropertyName("pending_events")] long PendingEvents,
    [property: JsonPropertyName("folders")] IReadOnlyList<FolderState> Folders,
    [property: JsonPropertyName("pending_dfsr")] long PendingDfsr,
    [property: JsonPropertyName("delivery_error")] string? DeliveryError,
    [property: JsonPropertyName("delivery_error_at_utc")] DateTimeOffset? DeliveryErrorAtUtc,
    [property: JsonPropertyName("dfsr_routes")] IReadOnlyList<DfsrRouteInfo>? DfsrRoutes,
    [property: JsonPropertyName("pending_probes")] long PendingProbes,
    [property: JsonPropertyName("syncthing_routes")] IReadOnlyList<TargetInfo>? SyncthingRoutes,
    [property: JsonPropertyName("tailscale_peers")] IReadOnlyList<TargetInfo>? TailscalePeers);
// Expected Syncthing route / Tailscale peer, so the server can show "no data" for targets that never reported.
public record TargetInfo(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("label")] string Label,
    [property: JsonPropertyName("target")] string Target);
public record SyncthingResult(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("folder_id")] string FolderId,
    [property: JsonPropertyName("folder_label")] string? FolderLabel,
    [property: JsonPropertyName("local_name")] string LocalName,
    [property: JsonPropertyName("remote_device_id")] string RemoteDeviceId,
    [property: JsonPropertyName("remote_name")] string? RemoteName,
    [property: JsonPropertyName("connected")] bool? Connected,
    [property: JsonPropertyName("connection_type")] string? ConnectionType,
    [property: JsonPropertyName("address")] string? Address,
    [property: JsonPropertyName("over_tailscale")] bool? OverTailscale,
    [property: JsonPropertyName("folder_state")] string? FolderState,
    [property: JsonPropertyName("folder_errors")] long? FolderErrors,
    [property: JsonPropertyName("local_need_items")] long? LocalNeedItems,
    [property: JsonPropertyName("local_need_bytes")] long? LocalNeedBytes,
    [property: JsonPropertyName("remote_completion")] double? RemoteCompletion,
    [property: JsonPropertyName("remote_need_items")] long? RemoteNeedItems,
    [property: JsonPropertyName("remote_need_bytes")] long? RemoteNeedBytes,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("checked_at_utc")] DateTimeOffset CheckedAtUtc,
    [property: JsonPropertyName("folder_type")] string? FolderType = null,
    [property: JsonPropertyName("expected_folder_type")] string? ExpectedFolderType = null,
    // Receive-only folder: items changed locally (no longer identical to the sender).
    [property: JsonPropertyName("local_changed_items")] long? LocalChangedItems = null);
public record TailscaleResult(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("self_host")] string? SelfHost,
    [property: JsonPropertyName("backend_state")] string? BackendState,
    [property: JsonPropertyName("peer_host")] string PeerHost,
    [property: JsonPropertyName("peer_ip")] string? PeerIp,
    [property: JsonPropertyName("online")] bool? Online,
    [property: JsonPropertyName("path")] string? Path,
    [property: JsonPropertyName("relay")] string? Relay,
    [property: JsonPropertyName("latency_ms")] double? LatencyMs,
    [property: JsonPropertyName("last_seen_utc")] DateTimeOffset? LastSeenUtc,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("checked_at_utc")] DateTimeOffset CheckedAtUtc);
public record ProbeBatch<T>(
    [property: JsonPropertyName("agent_id")] string AgentId,
    [property: JsonPropertyName("site")] string Site,
    [property: JsonPropertyName("results")] IReadOnlyList<T> Results);
// Folder manifest: counts, an order-independent fingerprint, per-directory buckets and a content-hash sample.
public record ParityResult(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("folder_code")] string FolderCode,
    [property: JsonPropertyName("root")] string Root,
    [property: JsonPropertyName("files")] long? Files,
    [property: JsonPropertyName("directories")] long? Directories,
    [property: JsonPropertyName("total_bytes")] long? TotalBytes,
    [property: JsonPropertyName("fingerprint")] string? Fingerprint,
    [property: JsonPropertyName("bucket_depth")] int? BucketDepth,
    [property: JsonPropertyName("latest_change_utc")] DateTimeOffset? LatestChangeUtc,
    [property: JsonPropertyName("buckets")] IReadOnlyList<ParityBucket> Buckets,
    [property: JsonPropertyName("samples")] IReadOnlyList<ParitySample> Samples,
    [property: JsonPropertyName("sample_salt")] string? SampleSalt,
    [property: JsonPropertyName("unreadable")] long Unreadable,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("started_at_utc")] DateTimeOffset StartedAtUtc,
    [property: JsonPropertyName("checked_at_utc")] DateTimeOffset CheckedAtUtc,
    [property: JsonPropertyName("duration_ms")] long DurationMs);
public record ParityBucket(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("files")] long Files,
    [property: JsonPropertyName("directories")] long Directories,
    [property: JsonPropertyName("bytes")] long Bytes,
    [property: JsonPropertyName("hash")] string Hash,
    [property: JsonPropertyName("latest_change_utc")] DateTimeOffset? LatestChangeUtc);
public record ParitySample(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("mtime")] long MTime,
    // null = file locked or changed while being read.
    [property: JsonPropertyName("sha256")] string? Sha256);
