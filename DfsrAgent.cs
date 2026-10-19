using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace WindowsMonitoringAgent;
public sealed record DfsrResult(
    string Id, string Code, string GroupName, string FolderName,
    string SourceComputer, string DestinationComputer, string ServiceStatus,
    long? BacklogCount, string Status, string? Error,
    DateTimeOffset CheckedAtUtc);
// Envelope names must be snake_case: VerifyMonitoringAgent reads "agent_id" (camelCase "agentId" => 401).
// DfsrResult fields stay camelCase (web defaults), matching AgentController::dfsr validation.
public sealed record DfsrBatch(
    [property: JsonPropertyName("agent_id")] string AgentId,
    [property: JsonPropertyName("site")] string Site,
    [property: JsonPropertyName("results")] IReadOnlyList<DfsrResult> Results);

public sealed class DfsrAgent : BackgroundService
{
    private readonly AgentOptions _cfg;
    private readonly SqliteStore _store;
    private readonly ILogger<DfsrAgent> _log;
    public DfsrAgent(IOptions<AgentOptions> options, SqliteStore store, ILogger<DfsrAgent> log)
    { _cfg=options.Value; _store=store; _log=log; }
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        if (!_cfg.Dfsr.Enabled) { _log.LogInformation("DFSR collector disabled"); return; }
        if (!OperatingSystem.IsWindows()) { _log.LogWarning("DFSR collector requires Windows"); return; }
        while (!stop.IsCancellationRequested)
        {
            foreach(var route in _cfg.Dfsr.Routes)
            {
                if(stop.IsCancellationRequested) break;
                var now=DateTimeOffset.UtcNow;
                try
                {
                    var value=await RunAsync(route, stop);
                    _store.AppendDfsr(new DfsrResult(Guid.NewGuid().ToString("N"),route.Code,route.GroupName,route.FolderName,
                        route.SourceComputer,route.DestinationComputer,value.ServiceStatus,value.BacklogCount,
                        value.Status,value.Error,now));
                }
                catch (OperationCanceledException) when(stop.IsCancellationRequested) { break; }
                catch(Exception ex)
                {
                    _log.LogWarning(ex,"DFSR probe failed for {Route}",route.Code);
                    _store.AppendDfsr(new DfsrResult(Guid.NewGuid().ToString("N"),route.Code,route.GroupName,route.FolderName,
                        route.SourceComputer,route.DestinationComputer,"unknown",null,"unknown",ex.Message,now));
                }
            }
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(30,_cfg.Dfsr.IntervalSeconds)),stop); }
            catch(OperationCanceledException) { break; }
        }
    }
    private async Task<ProbeResult> RunAsync(DfsrRoute route,CancellationToken stop)
    {
        // Pass arguments through JSON/base64 to avoid script injection via group/folder/server names.
        var json=JsonSerializer.Serialize(route);
        var payload=Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        var script=EmbeddedScript.Replace("__ROUTE_BASE64__",payload,StringComparison.Ordinal);
        var scriptB64=Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        using var proc=new Process { StartInfo=new ProcessStartInfo("powershell.exe") {
            Arguments="-NoLogo -NoProfile -NonInteractive -EncodedCommand "+scriptB64,
            UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true
        }};
        if (!proc.Start()) throw new InvalidOperationException("Could not launch PowerShell");
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(stop);
        timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(_cfg.Dfsr.CommandTimeoutSeconds,10,300)));
        var stdout=proc.StandardOutput.ReadToEndAsync();
        var stderr=proc.StandardError.ReadToEndAsync();
        try { await proc.WaitForExitAsync(timeout.Token); }
        catch(OperationCanceledException) { if(!proc.HasExited) proc.Kill(entireProcessTree:true); throw; }
        var output=await stdout; var error=await stderr;
        if(proc.ExitCode!=0) throw new InvalidOperationException("DFSR PowerShell exit "+proc.ExitCode+": "+error[..Math.Min(error.Length,500)]);
        return JsonSerializer.Deserialize<ProbeResult>(output, new JsonSerializerOptions { PropertyNameCaseInsensitive=true })
            ?? throw new InvalidOperationException("Empty DFSR response");
    }
    private sealed record ProbeResult(string ServiceStatus,long? BacklogCount,string Status,string? Error);
    private const string EmbeddedScript = """
        $ErrorActionPreference='Stop'
        $r=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ROUTE_BASE64__')) | ConvertFrom-Json
        try {
          Import-Module DFSR -ErrorAction Stop
          $service=(Get-Service -Name DFSR -ErrorAction Stop).Status.ToString().ToLowerInvariant()
          if($service -ne 'running') {
            @{serviceStatus=$service;backlogCount=$null;status='critical';error='DFSR service not running'} | ConvertTo-Json -Compress
            exit 0
          }
          $output=@(Get-DfsrBacklog -GroupName $r.GroupName -FolderName $r.FolderName -SourceComputerName $r.SourceComputer -DestinationComputerName $r.DestinationComputer -Verbose 4>&1 -ErrorAction Stop)
          $messages=@($output | Where-Object {$_ -is [System.Management.Automation.VerboseRecord]} | ForEach-Object {$_.Message})
          $count=$null
          foreach($msg in $messages) {
            if($msg -match '(?i)Count\s*:\s*([0-9]+)') { $count=[long]$Matches[1]; break }
          }
          # If the cmdlet returned 0 items and no count, zero is the only possible backlog.
          $items=@($output | Where-Object {$_ -isnot [System.Management.Automation.VerboseRecord]})
          if($null -eq $count -and $items.Count -eq 0) {$count=0}
          $state=if($null -eq $count){'unknown'}elseif($count -eq 0){'caught_up'}else{'backlog'}
          @{serviceStatus=$service;backlogCount=$count;status=$state;error=$null} | ConvertTo-Json -Compress
        } catch {
          @{serviceStatus='unknown';backlogCount=$null;status='unknown';error=$_.Exception.Message} | ConvertTo-Json -Compress
        }
        """;
}
