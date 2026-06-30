using ChaiWu.Windows.Models;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace ChaiWu.Windows.Services;

public class SyncService
{
    public static readonly SyncService Instance = new();

    private FileSystemWatcher? _watcher;

    public event Action? SyncCompleted;
    public event Action<List<ConflictPair>>? ConflictsDetected;
    public event Action<string>? SyncError;

    public void StartWatching()
    {
        var path = XlsxService.Instance.XlsxPath;
        var dir = Path.GetDirectoryName(path);
        if (dir == null || !Directory.Exists(dir)) return;

        _watcher = new FileSystemWatcher(dir)
        {
            Filter = Path.GetFileName(path),
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName,
            EnableRaisingEvents = true
        };
        _watcher.Changed += (_, _) => Task.Run(PerformSync);
        _watcher.Created += (_, _) => Task.Run(PerformSync);
    }

    public void PerformSync()
    {
        try
        {
            var remote = XlsxService.Instance.Import();
            var local  = DatabaseService.Instance.FetchAll();
            var (merged, conflicts) = Merge(local, remote);

            DatabaseService.Instance.BatchUpsert(merged);
            XlsxService.Instance.Export(merged);

            if (conflicts.Count > 0)
                ConflictsDetected?.Invoke(conflicts);

            SyncCompleted?.Invoke();
        }
        catch (Exception ex)
        {
            SyncError?.Invoke(ex.Message);
        }
    }

    private (List<Transaction>, List<ConflictPair>) Merge(List<Transaction> local, List<Transaction> remote)
    {
        var byId = local.ToDictionary(t => t.Id);
        var conflicts = new List<ConflictPair>();

        foreach (var remoteT in remote)
        {
            if (byId.TryGetValue(remoteT.Id, out var localT))
            {
                if (localT.ModifiedAt == remoteT.ModifiedAt) continue;

                if (remoteT.ModifiedAt > localT.ModifiedAt)
                {
                    byId[remoteT.Id] = remoteT;
                }
                else if (HasSubstantiveDiff(localT, remoteT))
                {
                    var conflictCopy = remoteT with { Id = Guid.NewGuid(), IsConflict = true };
                    var localMarked = localT with { IsConflict = true };
                    byId[localT.Id] = localMarked;
                    byId[conflictCopy.Id] = conflictCopy;
                    conflicts.Add(new ConflictPair(localMarked, conflictCopy));
                }
            }
            else
            {
                byId[remoteT.Id] = remoteT;
            }
        }
        return ([.. byId.Values], conflicts);
    }

    private static bool HasSubstantiveDiff(Transaction a, Transaction b) =>
        a.Amount != b.Amount || a.Type != b.Type || a.Category != b.Category || a.Note != b.Note;
}
