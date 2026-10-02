import Foundation
import SQLite3

// SQLITE_TRANSIENT 在 Swift 中需要手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private(set) var lastError = "数据库写入失败"
    private let databaseURL: URL?

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
        openDatabase()
        createTable()
    }

    deinit { sqlite3_close(db) }

    private var dbPath: String {
        if let databaseURL { return databaseURL.path }
        // 优先使用标准沙盒 Documents（TrollStore 和普通安装均可写）
        let sandboxDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("ChaiWu").path
        if (try? FileManager.default.createDirectory(atPath: sandboxDir,
                                                     withIntermediateDirectories: true)) != nil
            || FileManager.default.fileExists(atPath: sandboxDir) {
            return "\(sandboxDir)/chaiwu.sqlite"
        }
        // TrollStore fallback
        let trollDir = "/var/mobile/Documents/ChaiWu"
        try? FileManager.default.createDirectory(atPath: trollDir, withIntermediateDirectories: true)
        return "\(trollDir)/chaiwu.sqlite"
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            assertionFailure("无法打开数据库: \(dbPath)")
        }
        // WAL 模式提升并发写入性能
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_busy_timeout(db, 5000)
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
        // 旧数据库保留所有行；已迁移的数据库跳过重复添加。
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT is_deleted FROM transactions LIMIT 0;", -1, &stmt, nil)
        let migrated = stmt != nil
        sqlite3_finalize(stmt)
        if !migrated {
            sqlite3_exec(db, "ALTER TABLE transactions ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func upsert(_ t: Transaction) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        INSERT INTO transactions (id, date, type, amount, category, note, modified_at, source_device, is_conflict, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            date=excluded.date, type=excluded.type, amount=excluded.amount,
            category=excluded.category, note=excluded.note,
            modified_at=excluded.modified_at, source_device=excluded.source_device,
            is_conflict=excluded.is_conflict, is_deleted=excluded.is_deleted
        WHERE excluded.modified_at >= transactions.modified_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return writeFailed() }
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
        sqlite3_bind_int(stmt, 10, t.isDeleted ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return writeFailed() }
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var t = fetchAll().first(where: { $0.id == id }) else { return true }
        t.isDeleted = true
        t.isConflict = false
        t.modifiedAt = max(Date(), t.modifiedAt.addingTimeInterval(0.001))
        return upsert(t)
    }

    func fetchAll() -> [Transaction] {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT id,date,type,amount,category,note,modified_at,source_device,is_conflict,is_deleted FROM transactions ORDER BY date DESC;"
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
            let isDeleted = sqlite3_column_int(stmt, 9) != 0

            results.append(Transaction(id: id, date: date, type: type, amount: amount,
                                       category: category, note: note, modifiedAt: modifiedAt,
                                       sourceDevice: sourceDevice, isConflict: isConflict, isDeleted: isDeleted))
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

    @discardableResult
    func batchUpsert(_ transactions: [Transaction]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return writeFailed() }
        for t in transactions {
            guard upsert(t) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return writeFailed()
        }
        return true
    }

    private func writeFailed() -> Bool {
        lastError = db.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库未打开"
        appLog("数据库写入失败：\(lastError)", level: .error)
        return false
    }
}
