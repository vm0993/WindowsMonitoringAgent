using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
namespace WindowsMonitoringAgent;
// Reads sync state from the local Syncthing REST API. It never changes Syncthing configuration.
public sealed class SyncthingAgent : BackgroundService
{
    private readonly AgentOptions _cfg;
    private readonly SqliteStore _store;
    private readonly IHttpClientFactory _factory;
    private readonly ILogger<SyncthingAgent> _log;
    public SyncthingAgent(IOptions<AgentOptions> options, SqliteStore store, IHttpClientFactory factory, ILogger<SyncthingAgent> log)
    { _cfg=options.Value; _store=store; _factory=factory; _log=log; }
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        var st=_cfg.Syncthing;
        if(!st.Enabled) { _log.LogInformation("Syncthing collector disabled"); return; }
        var key=Environment.GetEnvironmentVariable(st.ApiKeyEnvironmentVariable);
        if(string.IsNullOrWhiteSpace(key)) { _log.LogCritical("Missing Syncthing API key in environment variable {Env}",st.ApiKeyEnvironmentVariable); return; }
        if(!Uri.TryCreate(st.BaseUrl,UriKind.Absolute,out var baseUri)) { _log.LogCritical("Invalid Syncthing BaseUrl"); return; }
        while(!stop.IsCancellationRequested)
        {
            var now=DateTimeOffset.UtcNow;
            using var http=_factory.CreateClient("syncthing");
            http.BaseAddress=baseUri;
            http.DefaultRequestHeaders.Add("X-API-Key",key);
            JsonElement? connections=null;
            string? connectionError=null;
            try { connections=(await GetAsync(http,"/rest/system/connections",stop)).GetProperty("connections"); }
            catch(OperationCanceledException) when(stop.IsCancellationRequested) { break; }
            catch(Exception ex) { connectionError=ex.Message; _log.LogWarning(ex,"Syncthing API not reachable"); }
            foreach(var route in st.Routes)
            {
                if(stop.IsCancellationRequested) break;
                SyncthingResult result;
                try { result=await ProbeAsync(http,route,connections,connectionError,now,stop); }
                catch(OperationCanceledException) when(stop.IsCancellationRequested) { break; }
                catch(Exception ex)
                {
                    _log.LogWarning(ex,"Syncthing probe failed for {Route}",route.Code);
                    result=Empty(route,now,ex.Message);
                }
                _store.AppendProbe(ProbeKind.Syncthing,result.Id,result,now);
            }
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(10,st.IntervalSeconds)),stop); }
            catch(OperationCanceledException) { break; }
        }
    }
    private SyncthingResult Empty(SyncthingRoute route, DateTimeOffset now, string error) =>
        new(Guid.NewGuid().ToString("N"),route.Code,route.FolderId,NullIfEmpty(route.FolderLabel),Environment.MachineName,route.RemoteDeviceId,NullIfEmpty(route.RemoteName),
            null,null,null,null,null,null,null,null,null,null,null,Trim(error),now,null,NullIfEmpty(route.ExpectedFolderType));
    private async Task<SyncthingResult> ProbeAsync(HttpClient http, SyncthingRoute route, JsonElement? connections, string? connectionError, DateTimeOffset now, CancellationToken stop)
    {
        if(connections is null) return Empty(route,now,"Syncthing API: "+connectionError);
        bool connected=false; string? type=null, address=null;
        foreach(var c in connections.Value.EnumerateObject())
        {
            if(!string.Equals(c.Name,route.RemoteDeviceId,StringComparison.OrdinalIgnoreCase)) continue;
            connected=Bool(c.Value,"connected") ?? false;
            type=Str(c.Value,"type");
            address=Str(c.Value,"address");
        }
        var folder=Uri.EscapeDataString(route.FolderId);
        var status=await GetAsync(http,$"/rest/db/status?folder={folder}",stop);
        var completion=await GetAsync(http,$"/rest/db/completion?folder={folder}&device={Uri.EscapeDataString(route.RemoteDeviceId)}",stop);
        var errors=(Long(status,"errors") ?? 0)+(Long(status,"pullErrors") ?? 0);
        string? error=null;
        string? folderType=null;
        try { folderType=Str(await GetAsync(http,$"/rest/config/folders/{folder}",stop),"type"); }
        catch(OperationCanceledException) when(stop.IsCancellationRequested) { throw; }
        catch(Exception ex) { _log.LogDebug(ex,"Syncthing folder config unavailable for {Folder}",route.FolderId); }
        var expected=NullIfEmpty(route.ExpectedFolderType);
        if(expected is not null && folderType is not null && !string.Equals(expected,folderType,StringComparison.OrdinalIgnoreCase))
            error=$"Folder type is {folderType}, expected {expected}";
        var localChanged=folderType=="receiveonly" ? Long(status,"receiveOnlyTotalItems") : null;
        if(localChanged>0) error??=$"{localChanged} item(s) changed locally on a receive-only folder";
        if(errors>0 && error is null)
        {
            var list=await GetAsync(http,$"/rest/folder/errors?folder={folder}",stop);
            if(list.TryGetProperty("errors",out var e) && e.ValueKind==JsonValueKind.Array && e.GetArrayLength()>0)
                error=$"{Str(e[0],"path")}: {Str(e[0],"error")}";
        }
        var needItems=Long(status,"needTotalItems") ?? (Long(status,"needFiles") ?? 0)+(Long(status,"needDirectories") ?? 0)+(Long(status,"needDeletes") ?? 0);
        var remoteState=Str(completion,"remoteState");
        if(remoteState is "notSharing" or "paused") error??=$"Remote folder state: {remoteState}";
        var overTailscale=connected ? IsTailscaleAddress(address) : (bool?)null;
        if(connected && _cfg.Syncthing.RequireTailscale && overTailscale==false) error??=$"Connection does not use Tailscale: {address}";
        return new SyncthingResult(Guid.NewGuid().ToString("N"),route.Code,route.FolderId,NullIfEmpty(route.FolderLabel),Environment.MachineName,
            route.RemoteDeviceId,NullIfEmpty(route.RemoteName),connected,type,address,overTailscale,Str(status,"state"),errors,
            needItems,Long(status,"needBytes"),Double(completion,"completion"),Long(completion,"needItems"),Long(completion,"needBytes"),
            Trim(error),now,folderType,expected,localChanged);
    }
    private static async Task<JsonElement> GetAsync(HttpClient http, string path, CancellationToken stop)
    {
        using var response=await http.GetAsync(path,stop);
        var body=await response.Content.ReadAsStringAsync(stop);
        if(!response.IsSuccessStatusCode) throw new HttpRequestException($"Syncthing {path.Split('?')[0]} HTTP {(int)response.StatusCode}: {body[..Math.Min(body.Length,200)]}");
        using var doc=JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
        return doc.RootElement.Clone();
    }
    // Tailscale addresses: IPv4 100.64.0.0/10 (CGNAT) and IPv6 fd7a:115c:a1e0::/48.
    public static bool? IsTailscaleAddress(string? address)
    {
        if(string.IsNullOrWhiteSpace(address)) return null;
        var host=address;
        var scheme=host.IndexOf("://",StringComparison.Ordinal);
        if(scheme>=0) host=host[(scheme+3)..];
        if(host.StartsWith('[')) host=host[1..host.IndexOf(']')];
        else if(host.Count(ch=>ch==':')==1) host=host[..host.IndexOf(':')];
        if(!IPAddress.TryParse(host,out var ip)) return host.EndsWith(".ts.net",StringComparison.OrdinalIgnoreCase);
        var b=ip.GetAddressBytes();
        return b.Length==4
            ? b[0]==100 && b[1]>=64 && b[1]<=127
            : b[0]==0xfd && b[1]==0x7a && b[2]==0x11 && b[3]==0x5c && b[4]==0xa1 && b[5]==0xe0;
    }
    private static string? Str(JsonElement e,string name) => e.ValueKind==JsonValueKind.Object && e.TryGetProperty(name,out var v) && v.ValueKind==JsonValueKind.String ? v.GetString() : null;
    private static bool? Bool(JsonElement e,string name) => e.ValueKind==JsonValueKind.Object && e.TryGetProperty(name,out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : null;
    private static long? Long(JsonElement e,string name) => e.ValueKind==JsonValueKind.Object && e.TryGetProperty(name,out var v) && v.ValueKind==JsonValueKind.Number && v.TryGetInt64(out var n) ? n : null;
    private static double? Double(JsonElement e,string name) => e.ValueKind==JsonValueKind.Object && e.TryGetProperty(name,out var v) && v.ValueKind==JsonValueKind.Number ? v.GetDouble() : null;
    private static string? NullIfEmpty(string v) => string.IsNullOrWhiteSpace(v) ? null : v;
    private static string? Trim(string? v) => v is null ? null : v.Length>1000 ? v[..1000] : v;
}
