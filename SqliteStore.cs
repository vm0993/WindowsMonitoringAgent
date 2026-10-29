using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Options;
using System.Text.Json;
namespace WindowsMonitoringAgent;
public sealed class SqliteStore
{
    private readonly string _connectionString;
    private readonly object _gate = new();
    public SqliteStore(IOptions<AgentOptions> settings)
    {
        var dir = settings.Value.DataDirectory;
        Directory.CreateDirectory(dir);
        _connectionString = new SqliteConnectionStringBuilder { DataSource = Path.Combine(dir, "queue.sqlite"), Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false }.ToString();
        lock (_gate)
        {
            using var db = Connect();
            using var cmd = db.CreateCommand();
            cmd.CommandText = "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS pending_events (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_utc TEXT NOT NULL); CREATE INDEX IF NOT EXISTS idx_pending_date ON pending_events(created_utc); CREATE TABLE IF NOT EXISTS pending_dfsr (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_utc TEXT NOT NULL); CREATE TABLE IF NOT EXISTS pending_syncthing (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_utc TEXT NOT NULL); CREATE TABLE IF NOT EXISTS pending_tailscale (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_utc TEXT NOT NULL); CREATE TABLE IF NOT EXISTS pending_parity (id TEXT PRIMARY KEY, payload TEXT NOT NULL, created_utc TEXT NOT NULL);";
            cmd.ExecuteNonQuery();
        }
    }
    private SqliteConnection Connect() { var db = new SqliteConnection(_connectionString); db.Open(); return db; }
    public void Append(FolderEvent ev)
    {
        lock (_gate)
        {
            using var db = Connect(); using var cmd = db.CreateCommand();
            cmd.CommandText = "INSERT OR IGNORE INTO pending_events(id,payload,created_utc) VALUES ($id,$payload,$when)";
            cmd.Parameters.AddWithValue("$id", ev.Id);
            cmd.Parameters.AddWithValue("$payload", JsonSerializer.Serialize(ev));
            cmd.Parameters.AddWithValue("$when", ev.OccurredAtUtc.ToString("O"));
            cmd.ExecuteNonQuery();
        }
    }
    public List<FolderEvent> ReadBatch(int batchSize)
    {
        lock (_gate)
        {
            var rows = new List<FolderEvent>(); using var db = Connect(); using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT payload FROM pending_events ORDER BY created_utc, id LIMIT $limit";
            cmd.Parameters.AddWithValue("$limit", Math.Clamp(batchSize, 1, 1000));
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) { var e = JsonSerializer.Deserialize<FolderEvent>(reader.GetString(0)); if(e != null) rows.Add(e); }
            return rows;
        }
    }
    public void DeleteAcknowledged(IReadOnlyCollection<string> ids)
    {
        if (ids.Count == 0) return;
        lock (_gate)
        {
            using var db = Connect(); using var txn = db.BeginTransaction();
            foreach (var id in ids)
            {
                using var cmd = db.CreateCommand(); cmd.Transaction = txn;
                cmd.CommandText = "DELETE FROM pending_events WHERE id=$id";
                cmd.Parameters.AddWithValue("$id", id); cmd.ExecuteNonQuery();
            }
            txn.Commit();
        }
    }
    public void AppendDfsr(DfsrResult result)
    {
        lock (_gate)
        {
            using var db = Connect(); using var cmd = db.CreateCommand();
            cmd.CommandText = "INSERT OR IGNORE INTO pending_dfsr (id,payload,created_utc) VALUES ($id,$payload,$when)";
            cmd.Parameters.AddWithValue("$id", result.Id);
            cmd.Parameters.AddWithValue("$payload", JsonSerializer.Serialize(result));
            cmd.Parameters.AddWithValue("$when", result.CheckedAtUtc.ToString("O"));
            cmd.ExecuteNonQuery();
        }
    }
    public List<DfsrResult> ReadDfsrBatch(int max)
    {
        lock (_gate)
        {
            using var db = Connect(); using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT payload FROM pending_dfsr ORDER BY created_utc,id LIMIT $limit";
            cmd.Parameters.AddWithValue("$limit", Math.Clamp(max, 1, 1000));
            using var r = cmd.ExecuteReader();
            var rows = new List<DfsrResult>();
            while(r.Read()) { var item=JsonSerializer.Deserialize<DfsrResult>(r.GetString(0)); if(item is not null) rows.Add(item); }
            return rows;
        }
    }
    public void DeleteDfsr(IReadOnlyCollection<string> ids)
    {
        lock (_gate)
        {
            using var db = Connect(); using var tx = db.BeginTransaction();
            foreach(var id in ids)
            {
                using var cmd = db.CreateCommand(); cmd.Transaction=tx;
                cmd.CommandText="DELETE FROM pending_dfsr WHERE id=$id";
                cmd.Parameters.AddWithValue("$id", id); cmd.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }
    public long PendingDfsrCount()
    {
        lock(_gate) { using var db=Connect(); using var cmd=db.CreateCommand(); cmd.CommandText="SELECT COUNT(*) FROM pending_dfsr"; return (long)(cmd.ExecuteScalar() ?? 0L); }
    }
    public long PendingCount()
    {
        lock (_gate)
        {
            using var db = Connect(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT COUNT(*) FROM pending_events";
            return (long)(cmd.ExecuteScalar() ?? 0L);
        }
    }
    // Probe queues (Syncthing, Tailscale) share one shape; table names come from this fixed list, never from input.
    private static string ProbeTable(ProbeKind kind) => kind switch
    {
        ProbeKind.Syncthing => "pending_syncthing",
        ProbeKind.Tailscale => "pending_tailscale",
        ProbeKind.Parity => "pending_parity",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
    public void AppendProbe<T>(ProbeKind kind, string id, T payload, DateTimeOffset when)
    {
        lock (_gate)
        {
            using var db = Connect(); using var cmd = db.CreateCommand();
            cmd.CommandText = $"INSERT OR IGNORE INTO {ProbeTable(kind)} (id,payload,created_utc) VALUES ($id,$payload,$when)";
            cmd.Parameters.AddWithValue("$id", id);
            cmd.Parameters.AddWithValue("$payload", JsonSerializer.Serialize(payload));
            cmd.Parameters.AddWithValue("$when", when.ToString("O"));
            cmd.ExecuteNonQuery();
        }
    }
    public List<T> ReadProbes<T>(ProbeKind kind, int max)
    {
        lock (_gate)
        {
            using var db = Connect(); using var cmd = db.CreateCommand();
            cmd.CommandText = $"SELECT payload FROM {ProbeTable(kind)} ORDER BY created_utc,id LIMIT $limit";
            cmd.Parameters.AddWithValue("$limit", Math.Clamp(max, 1, 1000));
            using var r = cmd.ExecuteReader();
            var rows = new List<T>();
            while(r.Read()) { var item=JsonSerializer.Deserialize<T>(r.GetString(0)); if(item is not null) rows.Add(item); }
            return rows;
        }
    }
    public void DeleteProbes(ProbeKind kind, IReadOnlyCollection<string> ids)
    {
        lock (_gate)
        {
            using var db = Connect(); using var tx = db.BeginTransaction();
            foreach(var id in ids)
            {
                using var cmd = db.CreateCommand(); cmd.Transaction=tx;
                cmd.CommandText=$"DELETE FROM {ProbeTable(kind)} WHERE id=$id";
                cmd.Parameters.AddWithValue("$id", id); cmd.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }
    public long PendingProbeCount()
    {
        lock(_gate) { using var db=Connect(); using var cmd=db.CreateCommand(); cmd.CommandText="SELECT (SELECT COUNT(*) FROM pending_syncthing)+(SELECT COUNT(*) FROM pending_tailscale)+(SELECT COUNT(*) FROM pending_parity)"; return (long)(cmd.ExecuteScalar() ?? 0L); }
    }
}
public enum ProbeKind { Syncthing, Tailscale, Parity }
