namespace WindowsMonitoringAgent;

public sealed class AgentOptions
{
    public string AgentId { get; set; } = "fs01-office";
    public string Site { get; set; } = "office";
    public string ApiBaseUrl { get; set; } = "https://monitor.example.com";
    public string ApiKeyEnvironmentVariable { get; set; } = "MONITOR_AGENT_API_KEY";
    public string DataDirectory { get; set; } = @"C:\ProgramData\OfficeMonitoringAgent";
    public int BatchSize { get; set; } = 200;
    public int SendIntervalSeconds { get; set; } = 15;
    public int HeartbeatIntervalSeconds { get; set; } = 60;
    public int FileEventDebounceSeconds { get; set; } = 3;
    public List<FolderDefinition> Folders { get; set; } = [];
    public DfsrOptions Dfsr { get; set; } = new();
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
