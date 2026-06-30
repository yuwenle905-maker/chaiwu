using ChaiWu.Windows.Models;
using Microsoft.Data.Sqlite;
using System;
using System.Collections.Generic;
using System.IO;

namespace ChaiWu.Windows.Services;

public class DatabaseService
{
    public static readonly DatabaseService Instance = new();

    private readonly string _dbPath;
    private readonly string _connStr;

    private DatabaseService()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ChaiWu");
        Directory.CreateDirectory(dir);
        _dbPath = Path.Combine(dir, "chaiwu.sqlite");
        _connStr = $"Data Source={_dbPath}";
        CreateTable();
    }

    private void CreateTable()
    {
        using var conn = new SqliteConnection(_connStr);
        conn.Open();
        conn.Execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS transactions (
                id TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                type TEXT NOT NULL,
                amount TEXT NOT NULL,
                category TEXT NOT NULL,
                note TEXT DEFAULT '',
                modified_at TEXT NOT NULL,
                source_device TEXT DEFAULT '',
                is_conflict INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_date ON transactions(date DESC);
            """);
    }

    public void Upsert(Transaction t)
    {
        using var conn = new SqliteConnection(_connStr);
        conn.Open();
        conn.Execute("""
            INSERT INTO transactions (id,date,type,amount,category,note,modified_at,source_device,is_conflict)
            VALUES (@id,@date,@type,@amount,@category,@note,@modified_at,@source_device,@is_conflict)
            ON CONFLICT(id) DO UPDATE SET
                date=excluded.date, type=excluded.type, amount=excluded.amount,
                category=excluded.category, note=excluded.note,
                modified_at=excluded.modified_at, source_device=excluded.source_device,
                is_conflict=excluded.is_conflict;
            """,
            new { id = t.Id.ToString(), date = t.Date.ToString("O"), type = t.Type.ToString(),
                  amount = t.Amount.ToString(), category = t.Category.ToString(), note = t.Note,
                  modified_at = t.ModifiedAt.ToString("O"), source_device = t.SourceDevice,
                  is_conflict = t.IsConflict ? 1 : 0 });
    }

    public void BatchUpsert(IEnumerable<Transaction> transactions)
    {
        using var conn = new SqliteConnection(_connStr);
        conn.Open();
        using var tx = conn.BeginTransaction();
        foreach (var t in transactions) UpsertWithConn(conn, t);
        tx.Commit();
    }

    private static void UpsertWithConn(SqliteConnection conn, Transaction t)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO transactions (id,date,type,amount,category,note,modified_at,source_device,is_conflict)
            VALUES ($id,$date,$type,$amount,$category,$note,$ma,$sd,$ic)
            ON CONFLICT(id) DO UPDATE SET
                date=excluded.date,type=excluded.type,amount=excluded.amount,
                category=excluded.category,note=excluded.note,
                modified_at=excluded.modified_at,source_device=excluded.source_device,is_conflict=excluded.is_conflict;
            """;
        cmd.Parameters.AddWithValue("$id", t.Id.ToString());
        cmd.Parameters.AddWithValue("$date", t.Date.ToString("O"));
        cmd.Parameters.AddWithValue("$type", t.Type.ToString());
        cmd.Parameters.AddWithValue("$amount", t.Amount.ToString());
        cmd.Parameters.AddWithValue("$category", t.Category.ToString());
        cmd.Parameters.AddWithValue("$note", t.Note);
        cmd.Parameters.AddWithValue("$ma", t.ModifiedAt.ToString("O"));
        cmd.Parameters.AddWithValue("$sd", t.SourceDevice);
        cmd.Parameters.AddWithValue("$ic", t.IsConflict ? 1 : 0);
        cmd.ExecuteNonQuery();
    }

    public void Delete(Guid id)
    {
        using var conn = new SqliteConnection(_connStr);
        conn.Open();
        conn.Execute("DELETE FROM transactions WHERE id=@id", new { id = id.ToString() });
    }

    public List<Transaction> FetchAll()
    {
        using var conn = new SqliteConnection(_connStr);
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT id,date,type,amount,category,note,modified_at,source_device,is_conflict FROM transactions ORDER BY date DESC";
        using var reader = cmd.ExecuteReader();
        var results = new List<Transaction>();
        while (reader.Read())
        {
            if (!Guid.TryParse(reader.GetString(0), out var id)) continue;
            if (!DateTime.TryParse(reader.GetString(1), out var date)) continue;
            if (!Enum.TryParse<TransactionType>(reader.GetString(2), out var type)) continue;
            if (!decimal.TryParse(reader.GetString(3), out var amount)) continue;
            if (!Enum.TryParse<TransactionCategory>(reader.GetString(4), out var category)) continue;
            if (!DateTime.TryParse(reader.GetString(6), out var modifiedAt)) continue;

            results.Add(new Transaction
            {
                Id = id, Date = date, Type = type, Amount = amount, Category = category,
                Note = reader.GetString(5), ModifiedAt = modifiedAt,
                SourceDevice = reader.GetString(7), IsConflict = reader.GetInt64(8) != 0
            });
        }
        return results;
    }

    public void ResolveConflict(Guid keepId, Guid discardId)
    {
        using var conn = new SqliteConnection(_connStr);
        conn.Open();
        conn.Execute("UPDATE transactions SET is_conflict=0 WHERE id=@id", new { id = keepId.ToString() });
        conn.Execute("DELETE FROM transactions WHERE id=@id", new { id = discardId.ToString() });
    }
}

// 简单扩展避免引入 Dapper
file static class SqliteExtensions
{
    public static void Execute(this SqliteConnection conn, string sql, object? param = null)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        if (param != null)
            foreach (var prop in param.GetType().GetProperties())
                cmd.Parameters.AddWithValue("@" + prop.Name, prop.GetValue(param) ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }
}
