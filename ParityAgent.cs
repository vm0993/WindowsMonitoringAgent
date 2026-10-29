using System.Buffers.Binary;
using System.IO.Enumeration;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
namespace WindowsMonitoringAgent;
// Builds a manifest (path, size, last write time) of every configured folder so the server can compare a replica
// with its source. Bucket hashes are order-independent sums, so both servers get the same value for the same file set
// regardless of enumeration order. Only a small, deterministic sample of files is read, and only to compute SHA-256.
public sealed class ParityAgent : BackgroundService
{
    private sealed class Bucket
    {
        public long Files, Directories, Bytes;
        public ulong Hi, Lo;
        public DateTimeOffset? LatestChange;
        public void Add(ReadOnlySpan<byte> line)
        {
            Span<byte> h=stackalloc byte[32];
            SHA256.HashData(line,h);
            unchecked { Hi+=BinaryPrimitives.ReadUInt64BigEndian(h); Lo+=BinaryPrimitives.ReadUInt64BigEndian(h[8..]); }
        }
        public void Merge(Bucket b)
        {
            Files+=b.Files; Directories+=b.Directories; Bytes+=b.Bytes;
            unchecked { Hi+=b.Hi; Lo+=b.Lo; }
            if(b.LatestChange>LatestChange || LatestChange is null) LatestChange=b.LatestChange;
        }
        public string Hash => $"{Hi:x16}{Lo:x16}";
    }
    private sealed record Candidate(byte[] Rank, string Relative, string FullPath, long Size, long MTime);
    private readonly AgentOptions _cfg;
    private readonly SqliteStore _store;
    private readonly ILogger<ParityAgent> _log;
    public ParityAgent(IOptions<AgentOptions> options, SqliteStore store, ILogger<ParityAgent> log)
    { _cfg=options.Value; _store=store; _log=log; }
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        var p=_cfg.Parity;
        if(!p.Enabled) { _log.LogInformation("Parity collector disabled"); return; }
        while(!stop.IsCancellationRequested)
        {
            foreach(var folder in _cfg.Folders)
            {
                if(stop.IsCancellationRequested) break;
                ParityResult result;
                try { result=await Task.Run(()=>Scan(folder,stop),stop); }
                catch(OperationCanceledException) when(stop.IsCancellationRequested) { break; }
                catch(Exception ex)
                {
                    _log.LogWarning(ex,"Parity scan failed for {Folder}",folder.Code);
                    var now=DateTimeOffset.UtcNow;
                    result=Failed(folder,now,now,ex.Message);
                }
                _store.AppendProbe(ProbeKind.Parity,result.Id,result,result.CheckedAtUtc);
                _log.LogInformation("Parity scan {Folder}: {Files} files, {Bytes} bytes, {Buckets} buckets in {Ms} ms",
                    folder.Code,result.Files,result.TotalBytes,result.Buckets.Count,result.DurationMs);
            }
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Max(300,p.IntervalSeconds)),stop); }
            catch(OperationCanceledException) { break; }
        }
    }
    private static ParityResult Failed(FolderDefinition folder, DateTimeOffset started, DateTimeOffset now, string error) =>
        new(Guid.NewGuid().ToString("N"),folder.Code,folder.Path,null,null,null,null,0,null,[],[],null,0,
            error.Length>1000 ? error[..1000] : error,started,now,(long)(now-started).TotalMilliseconds);
    public ParityResult Scan(FolderDefinition folder, CancellationToken stop)
    {
        var p=_cfg.Parity;
        var started=DateTimeOffset.UtcNow;
        if(string.IsNullOrWhiteSpace(folder.Path) || !Directory.Exists(folder.Path))
            return Failed(folder,started,DateTimeOffset.UtcNow,"Folder not found or not accessible");
        var depth=Math.Clamp(p.BucketDepth,0,8);
        var buckets=new Dictionary<string,Bucket>(StringComparer.Ordinal);
        var total=new Bucket();
        // The salt rotates daily so successive days sample different files; both servers use the same UTC date.
        var salt=started.UtcDateTime.ToString("yyyy-MM-dd");
        var sampleSize=Math.Clamp(p.ContentSampleFiles,0,500);
        var sample=new List<Candidate>(sampleSize+1);
        long unreadable=0;
        var exclude=p.EffectiveExclude;
        var options=new EnumerationOptions
        {
            RecurseSubdirectories=false, IgnoreInaccessible=false, ReturnSpecialDirectories=false,
            // DFSR never replicates temporary files; reparse points may point outside the replicated tree.
            AttributesToSkip=FileAttributes.ReparsePoint | FileAttributes.Temporary
        };
        var pending=new Stack<(DirectoryInfo Dir,string Relative)>();
        pending.Push((new DirectoryInfo(folder.Path),""));
        while(pending.Count>0)
        {
            stop.ThrowIfCancellationRequested();
            var (dir,dirRelative)=pending.Pop();
            IEnumerable<FileSystemInfo> entries;
            try { entries=dir.EnumerateFileSystemInfos("*",options).ToList(); }
            catch(Exception ex) when(ex is UnauthorizedAccessException or IOException or System.Security.SecurityException)
            {
                unreadable++;
                if(dirRelative=="") throw;
                continue;
            }
            foreach(var entry in entries)
            {
                if(Excluded(entry.Name,exclude)) continue;
                var relative=dirRelative=="" ? entry.Name : dirRelative+"/"+entry.Name;
                var changed=new DateTimeOffset(entry.LastWriteTimeUtc,TimeSpan.Zero);
                if(entry is DirectoryInfo sub)
                {
                    pending.Push((sub,relative));
                    var b=BucketFor(buckets,relative,depth,true);
                    b.Directories++; total.Directories++;
                    // Directory names are compared, directory timestamps are not: they change locally on every replica.
                    var line=Line("D",relative,null,null);
                    b.Add(line); total.Add(line);
                    Touch(b,changed); Touch(total,changed);
                }
                else if(entry is FileInfo file)
                {
                    long size, mtime;
                    try { size=file.Length; mtime=new DateTimeOffset(file.LastWriteTimeUtc,TimeSpan.Zero).ToUnixTimeSeconds(); }
                    catch(Exception ex) when(ex is IOException or UnauthorizedAccessException) { unreadable++; continue; }
                    var b=BucketFor(buckets,relative,depth,false);
                    b.Files++; b.Bytes+=size; total.Files++; total.Bytes+=size;
                    var line=Line("F",relative,size,mtime);
                    b.Add(line); total.Add(line);
                    Touch(b,changed); Touch(total,changed);
                    if(sampleSize>0 && size<=p.ContentSampleMaxFileBytes)
                        Consider(sample,sampleSize,new Candidate(SHA256.HashData(Encoding.UTF8.GetBytes(salt+"\0"+relative)),relative,file.FullName,size,mtime));
                }
            }
        }
        // Too many buckets: merge them into shallower directories. Sums stay valid because the hash is additive.
        while(buckets.Count>Math.Max(1,p.MaxBuckets) && depth>0)
        {
            depth--;
            var merged=new Dictionary<string,Bucket>(StringComparer.Ordinal);
            foreach(var (key,b) in buckets)
            {
                var k=Truncate(key,depth);
                if(!merged.TryGetValue(k,out var m)) merged[k]=m=new Bucket();
                m.Merge(b);
            }
            buckets=merged;
        }
        var samples=sample.Select(c=>new ParitySample(c.Relative,c.Size,c.MTime,HashContent(c.FullPath,c.Size,c.MTime,stop))).ToList();
        var done=DateTimeOffset.UtcNow;
        return new ParityResult(Guid.NewGuid().ToString("N"),folder.Code,folder.Path,total.Files,total.Directories,total.Bytes,total.Hash,depth,
            total.LatestChange,
            buckets.OrderBy(b=>b.Key,StringComparer.Ordinal).Select(b=>new ParityBucket(b.Key,b.Value.Files,b.Value.Directories,b.Value.Bytes,b.Value.Hash,b.Value.LatestChange)).ToList(),
            samples,salt,unreadable,unreadable>0 ? $"{unreadable} item(s) could not be read" : null,started,done,(long)(done-started).TotalMilliseconds);
    }
    private static bool Excluded(string name, IReadOnlyList<string> patterns)
    {
        foreach(var pattern in patterns)
            if(FileSystemName.MatchesSimpleExpression(pattern,name,ignoreCase:true)) return true;
        return false;
    }
    // Bucket = first <depth> directory levels. Files use their parent directory, directories their own path.
    private static Bucket BucketFor(Dictionary<string,Bucket> buckets, string relative, int depth, bool isDirectory)
    {
        var parent=isDirectory ? relative : (relative.LastIndexOf('/') is var i && i>=0 ? relative[..i] : "");
        var key=Truncate(parent,depth);
        if(!buckets.TryGetValue(key,out var b)) buckets[key]=b=new Bucket();
        return b;
    }
    private static string Truncate(string path, int depth)
    {
        if(depth<=0 || path=="") return "";
        var at=-1;
        for(var n=0;n<depth;n++)
        {
            at=path.IndexOf('/',at+1);
            if(at<0) return path;
        }
        return path[..at];
    }
    private static void Touch(Bucket b, DateTimeOffset changed)
    {
        if(b.LatestChange is null || changed>b.LatestChange) b.LatestChange=changed;
    }
    private static byte[] Line(string kind, string relative, long? size, long? mtime) =>
        Encoding.UTF8.GetBytes(size is null ? $"{kind}\0{relative}" : $"{kind}\0{relative}\0{size}\0{mtime}");
    private static void Consider(List<Candidate> sample, int size, Candidate c)
    {
        var at=sample.BinarySearch(c,RankComparer.Instance);
        if(at<0) at=~at;
        if(at>=size) return;
        sample.Insert(at,c);
        if(sample.Count>size) sample.RemoveAt(sample.Count-1);
    }
    private sealed class RankComparer : IComparer<Candidate>
    {
        public static readonly RankComparer Instance=new();
        public int Compare(Candidate? x, Candidate? y) => x!.Rank.AsSpan().SequenceCompareTo(y!.Rank);
    }
    // A file that changed while it was being read gives a hash of mixed content; report it as unknown instead.
    private string? HashContent(string path, long size, long mtime, CancellationToken stop)
    {
        try
        {
            using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete,1<<16,FileOptions.SequentialScan);
            var hash=Convert.ToHexStringLower(SHA256.HashData(stream));
            stop.ThrowIfCancellationRequested();
            var after=new FileInfo(path);
            return after.Length==size && new DateTimeOffset(after.LastWriteTimeUtc,TimeSpan.Zero).ToUnixTimeSeconds()==mtime ? hash : null;
        }
        catch(Exception ex) when(ex is IOException or UnauthorizedAccessException)
        {
            _log.LogDebug(ex,"Content hash skipped for {Path}",path);
            return null;
        }
    }
}
