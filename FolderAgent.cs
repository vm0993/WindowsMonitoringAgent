using System.Collections.Concurrent;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
namespace WindowsMonitoringAgent;
public sealed class FolderAgent : BackgroundService
{
    // Mutable per-folder state; guarded by _gate because watcher callbacks, the check loop and States() run on different threads.
    private sealed class WatchState
    {
        public FileSystemWatcher? Watcher;
        public bool Accessible;
        public bool Faulted;
        public int Failures;
        public DateTimeOffset NextAttempt=DateTimeOffset.MinValue;
        public DateTimeOffset? ErrorAt;
        public DateTimeOffset? RecoveredAt;
        public bool Unrecovered => ErrorAt is { } e && (RecoveredAt is not { } r || r < e);
    }
    private readonly AgentOptions _options;
    private readonly SqliteStore _store;
    private readonly ILogger<FolderAgent> _log;
    private readonly object _gate=new();
    private readonly Dictionary<string, WatchState> _states=new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, DateTimeOffset> _last = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, DateTimeOffset> _debounce = new(StringComparer.OrdinalIgnoreCase);
    public FolderAgent(IOptions<AgentOptions> options, SqliteStore store, ILogger<FolderAgent> log)
    {
        _options = options.Value; _store = store; _log = log;
        foreach(var f in _options.Folders) _states[f.Code]=new WatchState();
    }
    public IReadOnlyList<FolderState> States()
    {
        lock(_gate)
        {
            return _options.Folders.Select(f =>
            {
                var s=_states[f.Code];
                return new FolderState(f.Code, f.Name, f.Path, s.Accessible,
                    _last.TryGetValue(f.Code, out var changed) ? changed : null,
                    s.ErrorAt, s.Watcher is not null && !s.Faulted, s.RecoveredAt);
            }).ToList();
        }
    }
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while(!stoppingToken.IsCancellationRequested)
            {
                foreach(var folder in _options.Folders)
                {
                    if(stoppingToken.IsCancellationRequested) break;
                    await EnsureWatcherAsync(folder, stoppingToken);
                }
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(5,_options.FolderCheckSeconds)),stoppingToken);
            }
        }
        catch(OperationCanceledException) { }
        finally
        {
            lock(_gate) { foreach(var s in _states.Values) DisposeWatcher(s); }
        }
    }
    private async Task EnsureWatcherAsync(FolderDefinition folder, CancellationToken stoppingToken)
    {
        var accessible=CanAccess(folder.Path);
        var now=DateTimeOffset.UtcNow;
        WatchState s;
        lock(_gate)
        {
            s=_states[folder.Code];
            if(s.Accessible && !accessible) _log.LogError("Folder no longer accessible: {Folder} {Path}", folder.Code, folder.Path);
            s.Accessible=accessible;
            if(s.Watcher is not null && (!accessible || s.Faulted))
            {
                DisposeWatcher(s);
                s.NextAttempt=DateTimeOffset.MinValue;
            }
            if(!accessible)
            {
                if(!s.Unrecovered) s.ErrorAt=now;
                return;
            }
            if(s.Watcher is not null || now<s.NextAttempt) return;
        }
        FileSystemWatcher watcher;
        try { watcher=CreateWatcher(folder); }
        catch(Exception ex)
        {
            lock(_gate)
            {
                s.Failures++;
                s.ErrorAt=now;
                s.NextAttempt=now.AddSeconds(Math.Min(600,Math.Max(5,_options.FolderCheckSeconds)*Math.Pow(2,Math.Min(6,s.Failures-1))));
            }
            _log.LogError(ex,"Could not start watcher for {Folder} at {Path}; retry after backoff",folder.Code,folder.Path);
            return;
        }
        DateTimeOffset? lostSince;
        lock(_gate)
        {
            s.Watcher=watcher; s.Faulted=false; s.Failures=0;
            lostSince=s.Unrecovered ? s.ErrorAt : null;
        }
        _log.LogInformation("Monitoring {Folder} at {Path}",folder.Code,folder.Path);
        if(lostSince is null) return;
        // The watcher is running again; rescan for files changed while events may have been lost
        // before declaring recovery. Deletions during the outage cannot be detected this way.
        var found=await Task.Run(()=>Reconcile(folder, lostSince.Value, stoppingToken), stoppingToken);
        lock(_gate) { if(s.Watcher==watcher && !s.Faulted) s.RecoveredAt=DateTimeOffset.UtcNow; }
        _log.LogWarning("Watcher for {Folder} recovered; reconciliation recorded {Count} changed files since {Since}",folder.Code,found,lostSince);
    }
    private FileSystemWatcher CreateWatcher(FolderDefinition folder)
    {
        var watcher = new FileSystemWatcher(folder.Path)
        {
            IncludeSubdirectories=true,
            NotifyFilter=NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
            InternalBufferSize=64*1024,
            EnableRaisingEvents=false
        };
        watcher.Created += (_, e) => Record(folder, e.FullPath, "created");
        watcher.Changed += (_, e) => Record(folder, e.FullPath, "modified");
        watcher.Deleted += (_, e) => Record(folder, e.FullPath, "deleted");
        watcher.Renamed += (_, e) => { Record(folder,e.OldFullPath,"renamed_from"); Record(folder,e.FullPath,"renamed_to"); };
        watcher.Error += (_, e) => { MarkFaulted(folder); _log.LogError(e.GetException(), "Watcher error in {Folder}; events may have been lost, watcher will be restarted and reconciled", folder.Code); };
        try { watcher.EnableRaisingEvents=true; }
        catch { watcher.Dispose(); throw; }
        return watcher;
    }
    private void MarkFaulted(FolderDefinition folder)
    {
        lock(_gate) { var s=_states[folder.Code]; s.Faulted=true; s.ErrorAt=DateTimeOffset.UtcNow; }
    }
    private static void DisposeWatcher(WatchState s)
    {
        if(s.Watcher is null) return;
        try { s.Watcher.EnableRaisingEvents=false; s.Watcher.Dispose(); } catch { }
        s.Watcher=null;
    }
    private static bool CanAccess(string path)
    {
        if(string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return false;
        try { using var e=Directory.EnumerateFileSystemEntries(path).GetEnumerator(); e.MoveNext(); return true; }
        catch(IOException) { return false; }
        catch(UnauthorizedAccessException) { return false; }
    }
    private int Reconcile(FolderDefinition folder, DateTimeOffset since, CancellationToken stoppingToken)
    {
        var count=0;
        var threshold=since.UtcDateTime.AddSeconds(-5);
        try
        {
            var options=new EnumerationOptions { RecurseSubdirectories=true, IgnoreInaccessible=true, AttributesToSkip=FileAttributes.System };
            foreach(var file in new DirectoryInfo(folder.Path).EnumerateFiles("*",options))
            {
                if(stoppingToken.IsCancellationRequested || count>=Math.Max(0,_options.MaxReconcileEvents)) break;
                if(file.LastWriteTimeUtc<threshold && file.CreationTimeUtc<threshold) continue;
                Record(folder,file.FullName,"reconciled");
                count++;
            }
        }
        catch(Exception ex) { _log.LogError(ex,"Reconciliation of {Folder} was incomplete",folder.Code); }
        return count;
    }
    private void Record(FolderDefinition folder,string fullPath,string action)
    {
        try
        {
            var now=DateTimeOffset.UtcNow;
            var relative=Path.GetRelativePath(folder.Path,fullPath).Replace('\\','/');
            if(relative=="." || relative.StartsWith("../",StringComparison.Ordinal) || relative=="..") return;
            var key=folder.Code+"|"+action+"|"+relative;
            if (_debounce.TryGetValue(key,out var prior) && (now-prior).TotalSeconds < Math.Max(0,_options.FileEventDebounceSeconds)) return;
            _debounce[key]=now;
            bool isDirectory=Directory.Exists(fullPath);
            long? bytes=null;
            if(!isDirectory && File.Exists(fullPath))
            {
                try { bytes=new FileInfo(fullPath).Length; } catch(IOException) { } catch(UnauthorizedAccessException) { }
            }
            _store.Append(new FolderEvent(Guid.NewGuid().ToString("N"),folder.Code,relative,action,now,isDirectory,bytes));
            _last[folder.Code]=now;
            if(_debounce.Count>100000) _debounce.Clear();
        }
        catch(Exception ex)
        {
            // A lost event is treated like a watcher failure so the folder is reconciled before it is reported healthy again.
            MarkFaulted(folder);
            _log.LogError(ex,"Failed to persist file event for {Folder}",folder.Code);
        }
    }
}
