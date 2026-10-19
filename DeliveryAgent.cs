using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
namespace WindowsMonitoringAgent;
public sealed class DeliveryAgent : BackgroundService
{
    private readonly AgentOptions _cfg;
    private readonly SqliteStore _store;
    private readonly IHttpClientFactory _factory;
    private readonly FolderAgent _folderAgent;
    private readonly ILogger<DeliveryAgent> _log;
    private DateTimeOffset _lastHeartbeat=DateTimeOffset.MinValue;
    public DeliveryAgent(IOptions<AgentOptions> cfg, SqliteStore store, IHttpClientFactory factory, ILogger<DeliveryAgent> log, IServiceProvider services)
    {
        _cfg=cfg.Value; _store=store; _factory=factory; _log=log;
        // The same FolderAgent instance is registered as both a hosted service and a singleton.
        _folderAgent=services.GetRequiredService<FolderAgent>();
    }
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var key=Environment.GetEnvironmentVariable(_cfg.ApiKeyEnvironmentVariable);
        if(string.IsNullOrWhiteSpace(key)) { _log.LogCritical("Missing API key in environment variable {Env}",_cfg.ApiKeyEnvironmentVariable); return; }
        if (!Uri.TryCreate(_cfg.ApiBaseUrl,UriKind.Absolute,out var uri) || uri.Scheme != Uri.UriSchemeHttps)
        { _log.LogCritical("ApiBaseUrl must be HTTPS"); return; }
        while(!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var http=_factory.CreateClient("monitor");
                http.BaseAddress=uri;
                http.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",key);
                http.DefaultRequestHeaders.Add("X-Agent-Id",_cfg.AgentId);
                var batch=_store.ReadBatch(_cfg.BatchSize);
                if(batch.Count>0)
                {
                    using var response=await http.PostAsJsonAsync("/api/monitoring/agent/events",new BatchPayload(_cfg.AgentId,_cfg.Site,batch),stoppingToken);
                    response.EnsureSuccessStatusCode();
                    // Server must atomically persist every event BEFORE acknowledging success.
                    // Any non-2xx leaves the local queue intact; IDs make retries idempotent.
                    _store.DeleteAcknowledged(batch.Select(e=>e.Id).ToArray());
                    _log.LogInformation("Delivered {Count} events, pending {Pending}",batch.Count,_store.PendingCount());
                }
                var dfsrBatch=_store.ReadDfsrBatch(_cfg.BatchSize);
                if(dfsrBatch.Count>0)
                {
                    using var dfsrResponse=await http.PostAsJsonAsync("/api/monitoring/agent/dfsr", new DfsrBatch(_cfg.AgentId,_cfg.Site,dfsrBatch),stoppingToken);
                    dfsrResponse.EnsureSuccessStatusCode();
                    _store.DeleteDfsr(dfsrBatch.Select(d=>d.Id).ToArray());
                }
                if((DateTimeOffset.UtcNow-_lastHeartbeat).TotalSeconds>=_cfg.HeartbeatIntervalSeconds)
                {
                    var heartbeat=new HeartbeatPayload(_cfg.AgentId,_cfg.Site,Environment.MachineName,DateTimeOffset.UtcNow,_store.PendingCount(),_folderAgent.States());
                    using var result=await http.PostAsJsonAsync("/api/monitoring/agent/heartbeat",heartbeat,stoppingToken);
                    result.EnsureSuccessStatusCode();
                    _lastHeartbeat=DateTimeOffset.UtcNow;
                }
            }
            catch(OperationCanceledException) when(stoppingToken.IsCancellationRequested) { break; }
            catch(Exception ex) { _log.LogWarning(ex,"Delivery failed: queued events will retry"); }
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(3,_cfg.SendIntervalSeconds)),stoppingToken); } catch(OperationCanceledException){break;}
        }
    }
}
