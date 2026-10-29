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
    // Each channel fails and backs off independently: a rejected event batch must not stop heartbeat or DFSR delivery.
    private sealed class Channel(string name, int maxBackoffSeconds)
    {
        public string Name { get; } = name;
        public int MaxBackoffSeconds { get; } = maxBackoffSeconds;
        public int Failures;
        public DateTimeOffset NextAttempt = DateTimeOffset.MinValue;
        public DateTimeOffset? FailingSince;
        public string? LastError;
    }
    private readonly AgentOptions _cfg;
    private readonly SqliteStore _store;
    private readonly IHttpClientFactory _factory;
    private readonly FolderAgent _folderAgent;
    private readonly ILogger<DeliveryAgent> _log;
    private readonly Channel _heartbeat;
    private readonly Channel _events=new("events",300);
    private readonly Channel _dfsr=new("dfsr",300);
    private readonly Channel _syncthing=new("syncthing",300);
    private readonly Channel _tailscale=new("tailscale",300);
    private readonly Channel _parity=new("parity",300);
    private DateTimeOffset _lastHeartbeat=DateTimeOffset.MinValue;
    public DeliveryAgent(IOptions<AgentOptions> cfg, SqliteStore store, IHttpClientFactory factory, ILogger<DeliveryAgent> log, IServiceProvider services)
    {
        _cfg=cfg.Value; _store=store; _factory=factory; _log=log;
        // The same FolderAgent instance is registered as both a hosted service and a singleton.
        _folderAgent=services.GetRequiredService<FolderAgent>();
        // Heartbeat retries at least once per heartbeat interval so a recovered link shows up quickly.
        _heartbeat=new("heartbeat",Math.Max(15,_cfg.HeartbeatIntervalSeconds));
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
                if((DateTimeOffset.UtcNow-_lastHeartbeat).TotalSeconds>=_cfg.HeartbeatIntervalSeconds)
                    await RunAsync(_heartbeat,()=>SendHeartbeatAsync(http,stoppingToken),stoppingToken);
                await RunAsync(_events,()=>SendEventsAsync(http,stoppingToken),stoppingToken);
                await RunAsync(_dfsr,()=>SendDfsrAsync(http,stoppingToken),stoppingToken);
                await RunAsync(_syncthing,()=>SendProbesAsync<SyncthingResult>(http,ProbeKind.Syncthing,"syncthing",r=>r.Id,stoppingToken),stoppingToken);
                await RunAsync(_tailscale,()=>SendProbesAsync<TailscaleResult>(http,ProbeKind.Tailscale,"tailscale",r=>r.Id,stoppingToken),stoppingToken);
                // A manifest can be a few hundred KB; one per request stays under common proxy body limits (nginx 1 MB).
                await RunAsync(_parity,()=>SendProbesAsync<ParityResult>(http,ProbeKind.Parity,"parity",r=>r.Id,stoppingToken,1),stoppingToken);
            }
            catch(OperationCanceledException) when(stoppingToken.IsCancellationRequested) { break; }
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(3,_cfg.SendIntervalSeconds)),stoppingToken); } catch(OperationCanceledException){break;}
        }
    }
    private async Task RunAsync(Channel channel, Func<Task> send, CancellationToken stoppingToken)
    {
        var now=DateTimeOffset.UtcNow;
        if(now<channel.NextAttempt) return;
        try
        {
            await send();
            if(channel.Failures>0) _log.LogInformation("Delivery of {Channel} recovered after {Failures} failures",channel.Name,channel.Failures);
            channel.Failures=0; channel.NextAttempt=DateTimeOffset.MinValue; channel.FailingSince=null; channel.LastError=null;
        }
        catch(OperationCanceledException) when(stoppingToken.IsCancellationRequested) { throw; }
        catch(Exception ex)
        {
            channel.Failures++;
            channel.FailingSince??=now;
            channel.LastError=ex.Message.Length>500 ? ex.Message[..500] : ex.Message;
            var backoff=Math.Min(channel.MaxBackoffSeconds,Math.Max(3,_cfg.SendIntervalSeconds)*Math.Pow(2,Math.Min(10,channel.Failures-1)));
            channel.NextAttempt=now.AddSeconds(backoff);
            _log.LogWarning(ex,"Delivery of {Channel} failed ({Failures}x), retry in {Backoff}s; pending events {Events}, pending DFSR {Dfsr}",
                channel.Name,channel.Failures,(int)backoff,_store.PendingCount(),_store.PendingDfsrCount());
        }
    }
    private async Task SendEventsAsync(HttpClient http, CancellationToken stoppingToken)
    {
        var batch=_store.ReadBatch(_cfg.BatchSize);
        if(batch.Count==0) return;
        using var response=await http.PostAsJsonAsync("/api/monitoring/agent/events",new BatchPayload(_cfg.AgentId,_cfg.Site,batch),stoppingToken);
        await EnsureSuccessAsync(response,stoppingToken);
        // Server must atomically persist every event BEFORE acknowledging success.
        // Any non-2xx leaves the local queue intact; IDs make retries idempotent.
        _store.DeleteAcknowledged(batch.Select(e=>e.Id).ToArray());
        _log.LogInformation("Delivered {Count} events, pending {Pending}",batch.Count,_store.PendingCount());
    }
    private async Task SendDfsrAsync(HttpClient http, CancellationToken stoppingToken)
    {
        var dfsrBatch=_store.ReadDfsrBatch(_cfg.BatchSize);
        if(dfsrBatch.Count==0) return;
        using var response=await http.PostAsJsonAsync("/api/monitoring/agent/dfsr", new DfsrBatch(_cfg.AgentId,_cfg.Site,dfsrBatch),stoppingToken);
        await EnsureSuccessAsync(response,stoppingToken);
        _store.DeleteDfsr(dfsrBatch.Select(d=>d.Id).ToArray());
    }
    private async Task SendProbesAsync<T>(HttpClient http, ProbeKind kind, string endpoint, Func<T,string> id, CancellationToken stoppingToken, int? max=null)
    {
        var batch=_store.ReadProbes<T>(kind,max ?? _cfg.BatchSize);
        if(batch.Count==0) return;
        using var response=await http.PostAsJsonAsync($"/api/monitoring/agent/{endpoint}",new ProbeBatch<T>(_cfg.AgentId,_cfg.Site,batch),stoppingToken);
        await EnsureSuccessAsync(response,stoppingToken);
        _store.DeleteProbes(kind,batch.Select(id).ToArray());
    }
    private async Task SendHeartbeatAsync(HttpClient http, CancellationToken stoppingToken)
    {
        var failing=new[]{_events,_dfsr,_syncthing,_tailscale,_parity}.Where(c=>c.Failures>0).ToList();
        var routes=_cfg.Dfsr.Enabled
            ? _cfg.Dfsr.Routes.Select(r=>new DfsrRouteInfo(r.Code,r.GroupName,r.FolderName,r.SourceComputer,r.DestinationComputer)).ToList()
            : null;
        var heartbeat=new HeartbeatPayload(_cfg.AgentId,_cfg.Site,Environment.MachineName,DateTimeOffset.UtcNow,
            _store.PendingCount(),_folderAgent.States(),_store.PendingDfsrCount(),
            failing.Count>0 ? string.Join("; ",failing.Select(c=>$"{c.Name}: {c.LastError}")) : null,
            failing.Count>0 ? failing.Min(c=>c.FailingSince) : null,
            routes,
            _store.PendingProbeCount(),
            _cfg.Syncthing.Enabled ? _cfg.Syncthing.Routes.Select(r=>new TargetInfo(r.Code,string.IsNullOrWhiteSpace(r.FolderLabel) ? r.FolderId : r.FolderLabel,r.RemoteName)).ToList() : null,
            _cfg.Tailscale.Enabled ? _cfg.Tailscale.Peers.Select(p=>new TargetInfo(p.Code,p.HostName,p.HostName)).ToList() : null);
        using var result=await http.PostAsJsonAsync("/api/monitoring/agent/heartbeat",heartbeat,stoppingToken);
        await EnsureSuccessAsync(result,stoppingToken);
        _lastHeartbeat=DateTimeOffset.UtcNow;
    }
    private static async Task EnsureSuccessAsync(HttpResponseMessage response, CancellationToken stoppingToken)
    {
        if(response.IsSuccessStatusCode) return;
        // Include the server's reason (e.g. validation errors) so the queue problem can be diagnosed.
        var body=await response.Content.ReadAsStringAsync(stoppingToken);
        throw new HttpRequestException($"HTTP {(int)response.StatusCode}: {body[..Math.Min(body.Length,300)]}",null,response.StatusCode);
    }
}
