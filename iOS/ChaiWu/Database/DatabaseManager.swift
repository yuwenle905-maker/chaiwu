import Foundation
import SQLite3

// SQLITE_TRANSIENT 在 Swift 中需要手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTable()
    }

    // TrollStore 优势：直接写入不受沙盒限制的持久路径
    private var dbPath: String {
        let dir = "/var/mobile/Documents/ChaiWu"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/chaiwu.sqlite"
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            assertionFailure("无法打开数据库: \(dbPath)")
        }
        // WAL 模式提升并发写入性能
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS transactions (
            id TEXT PRIMARY KEY,
            date REAL NOT NULL,
            type TEXT NOT NULL,
            amount TEXT NOT NULL,
            category TEXT NOT NULL,
            note TEXT DEFAULT '',
            modified_at REAL NOT NULL,
            source_device TEXT DEFAULT '',
            is_conflict INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_date ON transactions(date DESC);
        CREATE INDEX IF NOT EXISTS idx_conflict ON transactions(is_conflict);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - CRUD

    func upsert(_ t: Transaction) {
        let sql = """
        INSERT INTO transactions (id, date, type, amount, category, note, modified_at, source_device, is_conflict)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            date=excluded.date, type=excluded.type, amount=excluded.amount,
            category=excluded.category, note=excluded.note,
            modified_at=excluded.modified_at, source_device=excluded.source_device,
            is_conflict=excluded.is_conflict;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, t.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, t.date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, t.type.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, "\(t.amount)", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, t.category.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, t.note, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 7, t.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 8, t.sourceDevice, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 9, t.isConflict ? 1 : 0)
        sqlite3_step(stmt)
    }

    func delete(id: UUID) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM transactions WHERE id = ?;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func fetchAll() -> [Transaction] {
        let sql = "SELECT id,date,type,amount,category,note,modified_at,source_device,is_conflict FROM transactions ORDER BY date DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [Transaction] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                let id = UUID(uuidString: idStr),
                let typeStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                let type = TransactionType(rawValue: typeStr),
                let amtStr = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                let amount = Decimal(string: amtStr),
                let catStr = sqlite3_column_text(stmt, 4).map({ String(cString: $0) }),
                let category = TransactionCategory(rawValue: catStr)
            else { continue }

            let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let note = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let sourceDevice = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let isConflict = sqlite3_column_int(stmt, 8) != 0

            results.append(Transaction(id: id, date: date, type: type, amount: amount,
                                       category: category, note: note, modifiedAt: modifiedAt,
                                       sourceDevice: sourceDevice, isConflict: isConflict))
        }
        return results
    }

    func fetchConflicts() -> [Transaction] {
        fetchAll().filter { $0.isConflict }
    }

    func resolveConflict(keepID: UUID, discardID: UUID) {
        var keep = fetchAll().first(where: { $0.id == keepID })
        keep?.isConflict = false
        if let t = keep { upsert(t) }
        delete(id: discardID)
    }

    func batchUpsert(_ transactions: [Transaction]) {
        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        transactions.forEach { upsert($0) }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }
}
