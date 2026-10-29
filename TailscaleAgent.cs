using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
namespace WindowsMonitoringAgent;
// Measures the Tailscale path to each expected peer from this host: daemon state, peer presence and a live ping.
public sealed partial class TailscaleAgent : BackgroundService
{
    private readonly AgentOptions _cfg;
    private readonly SqliteStore _store;
    private readonly ILogger<TailscaleAgent> _log;
    public TailscaleAgent(IOptions<AgentOptions> options, SqliteStore store, ILogger<TailscaleAgent> log)
    { _cfg=options.Value; _store=store; _log=log; }
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        var ts=_cfg.Tailscale;
        if(!ts.Enabled) { _log.LogInformation("Tailscale collector disabled"); return; }
        while(!stop.IsCancellationRequested)
        {
            var now=DateTimeOffset.UtcNow;
            JsonElement? status=null; string? statusError=null;
            try
            {
                var output=await ProcessRunner.RunAsync(ts.ExePath,["status","--json"],30,stop);
                if(output.ExitCode!=0 && string.IsNullOrWhiteSpace(output.StdOut)) throw new InvalidOperationException("tailscale status exit "+output.ExitCode+": "+output.StdErr.Trim());
                using var doc=JsonDocument.Parse(output.StdOut);
                status=doc.RootElement.Clone();
            }
            catch(OperationCanceledException) when(stop.IsCancellationRequested) { break; }
            catch(Exception ex) { statusError=ex.Message; _log.LogWarning(ex,"tailscale status failed"); }
            foreach(var peer in ts.Peers)
            {
                if(stop.IsCancellationRequested) break;
                TailscaleResult result;
                try { result=await ProbeAsync(peer,status,statusError,now,stop); }
                catch(OperationCanceledException) when(stop.IsCancellationRequested) { break; }
                catch(Exception ex)
                {
                    _log.LogWarning(ex,"Tailscale probe failed for {Peer}",peer.Code);
                    result=new TailscaleResult(Guid.NewGuid().ToString("N"),peer.Code,null,null,peer.HostName,null,null,null,null,null,null,Trim(ex.Message),now);
                }
                _store.AppendProbe(ProbeKind.Tailscale,result.Id,result,now);
            }
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(15,ts.IntervalSeconds)),stop); }
            catch(OperationCanceledException) { break; }
        }
    }
    private async Task<TailscaleResult> ProbeAsync(TailscalePeer peer, JsonElement? status, string? statusError, DateTimeOffset now, CancellationToken stop)
    {
        var id=Guid.NewGuid().ToString("N");
        if(status is null) return new(id,peer.Code,null,null,peer.HostName,null,null,null,null,null,null,Trim("tailscale status: "+statusError),now);
        var root=status.Value;
        var backend=Str(root,"BackendState");
        var self=root.TryGetProperty("Self",out var s) ? Str(s,"HostName") : null;
        JsonElement? match=null;
        if(root.TryGetProperty("Peer",out var peers) && peers.ValueKind==JsonValueKind.Object)
            foreach(var p in peers.EnumerateObject())
                if(Matches(p.Value,peer.HostName)) { match=p.Value; break; }
        if(match is null)
            return new(id,peer.Code,self,backend,peer.HostName,null,false,null,null,null,null,"Peer not found in tailnet",now);
        var m=match.Value;
        var ip=m.TryGetProperty("TailscaleIPs",out var ips) && ips.ValueKind==JsonValueKind.Array && ips.GetArrayLength()>0 ? ips[0].GetString() : null;
        var online=m.TryGetProperty("Online",out var o) && o.ValueKind is JsonValueKind.True or JsonValueKind.False ? o.GetBoolean() : (bool?)null;
        DateTimeOffset? lastSeen=DateTimeOffset.TryParse(Str(m,"LastSeen"),CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out var ls) && ls.Year>2000 ? ls : null;
        string? path=null, relay=Str(m,"Relay"); double? latency=null; string? error=null;
        if(backend!="Running") error=$"Tailscale backend state: {backend}";
        else if(ip is not null)
        {
            // Pong text is parsed even on non-zero exit: "direct connection not established" still means the peer answered via DERP.
            var ping=await ProcessRunner.RunAsync(_cfg.Tailscale.ExePath,["ping","--c","1","--timeout",$"{Math.Clamp(_cfg.Tailscale.PingTimeoutSeconds,1,30)}s",ip],Math.Clamp(_cfg.Tailscale.PingTimeoutSeconds,1,30)+15,stop);
            var pong=PongRegex().Match(ping.StdOut);
            if(pong.Success)
            {
                var via=pong.Groups["via"].Value;
                var derp=DerpRegex().Match(via);
                path=derp.Success ? "relay" : "direct";
                if(derp.Success) relay=derp.Groups[1].Value;
                latency=double.Parse(pong.Groups["ms"].Value,CultureInfo.InvariantCulture);
            }
            else error=Trim("Ping failed: "+(ping.StdOut+" "+ping.StdErr).Trim());
        }
        return new(id,peer.Code,self,backend,Str(m,"HostName") ?? peer.HostName,ip,online,path,relay,latency,lastSeen,error,now);
    }
    private static bool Matches(JsonElement p, string host)
    {
        if(string.Equals(Str(p,"HostName"),host,StringComparison.OrdinalIgnoreCase)) return true;
        var dns=Str(p,"DNSName");
        return dns is not null && string.Equals(dns.Split('.')[0],host,StringComparison.OrdinalIgnoreCase);
    }
    [GeneratedRegex(@"pong from .* via (?<via>.+?) in (?<ms>[0-9.]+)ms")] private static partial Regex PongRegex();
    [GeneratedRegex(@"DERP\(([^)]+)\)")] private static partial Regex DerpRegex();
    private static string? Str(JsonElement e,string name) => e.ValueKind==JsonValueKind.Object && e.TryGetProperty(name,out var v) && v.ValueKind==JsonValueKind.String ? v.GetString() : null;
    private static string? Trim(string? v) => v is null ? null : v.Length>1000 ? v[..1000] : v;
}
