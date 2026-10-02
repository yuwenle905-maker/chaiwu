import Foundation
import SQLite3
import Combine

// SQLITE_TRANSIENT 在 Swift 中需要手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager {
    static var shared: DatabaseManager { LedgerStore.shared.context.database }
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private(set) var lastError = "数据库写入失败"
    private let databaseURL: URL?
    private let readOnly: Bool

    init(databaseURL: URL? = nil, readOnly: Bool = false) {
        self.databaseURL = databaseURL
        self.readOnly = readOnly
        openDatabase()
        if !readOnly { createTable() }
    }

    deinit { sqlite3_close(db) }

    private var dbPath: String {
        if let databaseURL { return databaseURL.path }
        return Self.defaultDatabaseURL.path
    }

    static var defaultDatabaseURL: URL {
        // 优先使用标准沙盒 Documents（TrollStore 和普通安装均可写）
        let sandboxDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("ChaiWu").path
        if (try? FileManager.default.createDirectory(atPath: sandboxDir,
                                                     withIntermediateDirectories: true)) != nil
            || FileManager.default.fileExists(atPath: sandboxDir) {
            return URL(fileURLWithPath: "\(sandboxDir)/chaiwu.sqlite")
        }
        // TrollStore fallback
        let trollDir = "/var/mobile/Documents/ChaiWu"
        try? FileManager.default.createDirectory(atPath: trollDir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: "\(trollDir)/chaiwu.sqlite")
    }

    private func openDatabase() {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(dbPath, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            lastError = "无法打开账本数据库"
            return
        }
        // WAL 模式提升并发写入性能
        if !readOnly {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        }
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

    // 使用 SQLite 备份 API，包含尚未 checkpoint 的 WAL 数据，不直接复制活动 sqlite 文件。
    func snapshot(to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw SyncError.writeError("当前账本未打开，已停止备份") }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SyncError.writeError("备份文件已存在，请重新尝试")
        }
        var target: OpaquePointer?
        guard sqlite3_open(destination.path, &target) == SQLITE_OK else {
            sqlite3_close(target)
            throw SyncError.writeError("无法创建备份文件，当前账本未改变")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else {
            throw SyncError.writeError("无法读取当前账本，已停止备份")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw SyncError.writeError("账本备份未完成，当前账本未改变")
        }
        guard sqlite3_exec(target, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
            throw SyncError.writeError("备份文件未完成整理，当前账本未改变")
        }
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(target, "PRAGMA integrity_check;", -1, &check, nil) == SQLITE_OK else {
            throw SyncError.writeError("无法校验账本备份")
        }
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW,
              sqlite3_column_text(check, 0).map({ String(cString: $0) }) == "ok" else {
            throw SyncError.writeError("备份校验失败，当前账本未改变")
        }
    }

    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.writeError("账本数据库无法读取")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) == "ok" else {
            throw SyncError.writeError("账本数据库校验失败")
        }
        var schema: OpaquePointer?
        defer { sqlite3_finalize(schema) }
        guard sqlite3_prepare_v2(db, "SELECT id,date,type,amount,category,note,modified_at,source_device,is_conflict,is_deleted FROM transactions LIMIT 0;", -1, &schema, nil) == SQLITE_OK else {
            throw SyncError.writeError("账本数据结构不完整")
        }
    }

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

struct LedgerBackup: Identifiable, Codable {
    let id: UUID
    let name: String
    let createdAt: Date
    let databaseFile: String
    let ledgerID: String
    let categoryNames: [String: String]
    let categoryOptions: [String: [String]]
}

private struct LedgerManifest: Codable {
    var activeID: String
    var activeName: String
    var activeDatabaseFile: String
    var backups: [LedgerBackup]
}

struct LedgerContext {
    let id: String
    let database: DatabaseManager
    var syncFilename: String { Self.syncFilename(for: id) }
    static func syncFilename(for id: String) -> String {
        id == "legacy" ? "chaiwu_data.xlsx" : "chaiwu_data_\(id).xlsx"
    }
}

final class LedgerStore: ObservableObject {
    static let shared = LedgerStore()
    @Published private(set) var revision = 0
    @Published private(set) var startupError: String?
    private let lock = NSRecursiveLock()
    private let root: URL
    private let defaults: UserDefaults
    private var manifest: LedgerManifest
    private var database: DatabaseManager

    init(root: URL = DatabaseManager.defaultDatabaseURL.deletingLastPathComponent(), defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        let initial = LedgerManifest(activeID: "legacy", activeName: "原始账本", activeDatabaseFile: "chaiwu.sqlite", backups: [])
        var loaded = initial
        var error: String?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("ledgers.json")
            if FileManager.default.fileExists(atPath: file.path) {
                loaded = try JSONDecoder().decode(LedgerManifest.self, from: Data(contentsOf: file))
                guard loaded.activeDatabaseFile == "chaiwu.sqlite" || loaded.activeDatabaseFile == "ledger_\(loaded.activeID).sqlite",
                      loaded.activeID == "legacy" || UUID(uuidString: loaded.activeID) != nil,
                      FileManager.default.fileExists(atPath: root.appendingPathComponent(loaded.activeDatabaseFile).path) else {
                    throw SyncError.parseError("当前账本索引异常或数据库缺失，请保留文件并检查备份")
                }
            }
        } catch let caught { error = "账本索引读取失败：\(caught.localizedDescription)" }
        manifest = loaded
        database = DatabaseManager(databaseURL: root.appendingPathComponent(loaded.activeDatabaseFile), readOnly: error != nil)
        startupError = error
    }

    var context: LedgerContext {
        lock.lock(); defer { lock.unlock() }
        return LedgerContext(id: manifest.activeID, database: database)
    }
    var activeName: String {
        lock.lock(); defer { lock.unlock() }
        return manifest.activeName
    }
    var backups: [LedgerBackup] {
        lock.lock(); defer { lock.unlock() }
        return manifest.backups.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist(_ value: LedgerManifest) throws {
        if let startupError { throw SyncError.writeError(startupError) }
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("ledgers.json"), options: .atomic)
    }

    @discardableResult
    func backupCurrent(at date: Date = Date()) throws -> LedgerBackup {
        lock.lock(); defer { lock.unlock() }
        if let startupError { throw SyncError.writeError(startupError) }
        try database.validate()
        let id = UUID()
        let filename = "backup_\(id.uuidString).sqlite"
        try database.snapshot(to: root.appendingPathComponent(filename))
        let backup = LedgerBackup(id: id, name: manifest.activeName, createdAt: date, databaseFile: filename, ledgerID: manifest.activeID,
                                  categoryNames: defaults.dictionary(forKey: "categoryNames") as? [String: String] ?? [:],
                                  categoryOptions: defaults.dictionary(forKey: "categoryOptions") as? [String: [String]] ?? [:])
        var next = manifest
        next.backups.append(backup)
        try persist(next)
        manifest = next
        revision += 1
        return backup
    }

    @discardableResult
    func automaticBackupIfNeeded(at date: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard defaults.bool(forKey: "automaticLedgerBackup"),
              !manifest.backups.contains(where: { $0.ledgerID == manifest.activeID && Calendar.current.isDate($0.createdAt, inSameDayAs: date) }) else { return false }
        try backupCurrent(at: date)
        return true
    }

    func startNew(name: String) throws {
        lock.lock(); defer { lock.unlock() }
        try backupCurrent()
        let id = UUID().uuidString
        let filename = "ledger_\(id).sqlite"
        let newDatabase = DatabaseManager(databaseURL: root.appendingPathComponent(filename))
        try newDatabase.validate()
        var next = manifest
        next.activeID = id
        next.activeName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新账本 \(Date().formatted(date: .numeric, time: .shortened))" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.activeDatabaseFile = filename
        try persist(next)
        database = newDatabase
        manifest = next
        revision += 1
    }

    private func backupDatabase(_ backup: LedgerBackup) throws -> DatabaseManager {
        guard manifest.backups.contains(where: { $0.id == backup.id && $0.databaseFile == backup.databaseFile }),
              backup.databaseFile == "backup_\(backup.id.uuidString).sqlite",
              FileManager.default.fileExists(atPath: root.appendingPathComponent(backup.databaseFile).path) else {
            throw SyncError.parseError("历史备份文件不存在，当前账本未改变")
        }
        let db = DatabaseManager(databaseURL: root.appendingPathComponent(backup.databaseFile), readOnly: true)
        try db.validate()
        return db
    }

    func transactions(in backup: LedgerBackup) throws -> [Transaction] {
        lock.lock(); defer { lock.unlock() }
        return try backupDatabase(backup).fetchAll()
    }

    func restore(_ backup: LedgerBackup) throws {
        lock.lock(); defer { lock.unlock() }
        let source = try backupDatabase(backup)
        try backupCurrent()
        let id = UUID().uuidString
        let filename = "ledger_\(id).sqlite"
        let file = root.appendingPathComponent(filename)
        try source.snapshot(to: file)
        let restored = DatabaseManager(databaseURL: file)
        try restored.validate()
        var next = manifest
        next.activeID = id
        next.activeName = "\(backup.name)（恢复）"
        next.activeDatabaseFile = filename
        try persist(next)
        database = restored
        manifest = next
        revision += 1
    }
}
