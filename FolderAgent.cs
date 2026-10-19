using System.Collections.Concurrent;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
namespace WindowsMonitoringAgent;
public sealed class FolderAgent : BackgroundService
{
    private readonly AgentOptions _options;
    private readonly SqliteStore _store;
    private readonly ILogger<FolderAgent> _log;
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly ConcurrentDictionary<string, DateTimeOffset> _last = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, DateTimeOffset> _lastErrors = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, DateTimeOffset> _debounce = new(StringComparer.OrdinalIgnoreCase);
    public FolderAgent(IOptions<AgentOptions> options, SqliteStore store, ILogger<FolderAgent> log)
       { _options = options.Value; _store = store; _log = log; }
    public IReadOnlyList<FolderState> States() => _options.Folders.Select(f => new FolderState(
        f.Code, f.Name, f.Path, Directory.Exists(f.Path),
        _last.TryGetValue(f.Code, out var changed) ? changed : null,
        _lastErrors.TryGetValue(f.Code, out var error) ? error : null)).ToList();
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        foreach(var folder in _options.Folders)
        {
            if (string.IsNullOrWhiteSpace(folder.Path) || !Directory.Exists(folder.Path))
            {
                _lastErrors[folder.Code] = DateTimeOffset.UtcNow;
                _log.LogError("Folder does not exist: {Folder} {Path}", folder.Code, folder.Path);
                continue;
            }
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
            watcher.Error += (_, e) => { _lastErrors[folder.Code] = DateTimeOffset.UtcNow; _log.LogError(e.GetException(), "Watcher error in {Folder}; events may have been lost. Reconciliation required", folder.Code); };
            _watchers.Add(watcher); watcher.EnableRaisingEvents=true;
            _log.LogInformation("Monitoring {Folder} at {Path}",folder.Code,folder.Path);
        }
        try { await Task.Delay(Timeout.Infinite,stoppingToken); } catch(OperationCanceledException) { }
        finally { foreach(var w in _watchers) { w.EnableRaisingEvents=false; w.Dispose(); } }
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
        catch(Exception ex) { _lastErrors[folder.Code]=DateTimeOffset.UtcNow; _log.LogError(ex,"Failed to persist file event for {Folder}",folder.Code); }
    }
}
