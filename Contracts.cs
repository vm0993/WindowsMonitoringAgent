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
    [property: JsonPropertyName("watcher_error_at_utc")] DateTimeOffset? WatcherErrorAtUtc);
public record HeartbeatPayload(
    [property: JsonPropertyName("agent_id")] string AgentId,
    [property: JsonPropertyName("site")] string Site,
    [property: JsonPropertyName("host_name")] string HostName,
    [property: JsonPropertyName("observed_at_utc")] DateTimeOffset ObservedAtUtc,
    [property: JsonPropertyName("pending_events")] long PendingEvents,
    [property: JsonPropertyName("folders")] IReadOnlyList<FolderState> Folders);
