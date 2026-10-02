import Foundation
import SQLite3

enum TestLogLevel { case info, warn, error }
func appLog(_ message: String, level: TestLogLevel = .info) {}

@main
struct DataRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        var sqlite: OpaquePointer?
        precondition(sqlite3_open(url.path, &sqlite) == SQLITE_OK)
        precondition(sqlite3_exec(sqlite, """
            CREATE TABLE transactions (id TEXT PRIMARY KEY,date REAL NOT NULL,type TEXT NOT NULL,
              amount TEXT NOT NULL,category TEXT NOT NULL,note TEXT DEFAULT '',modified_at REAL NOT NULL,
              source_device TEXT DEFAULT '',is_conflict INTEGER DEFAULT 0);
            INSERT INTO transactions VALUES ('00000000-0000-0000-0000-000000000001',1759183200,'支出','88','房租','旧账单',1,'旧版本',0);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(sqlite)
        let db = DatabaseManager(databaseURL: url)
        precondition(db.fetchAll().count == 1 && !db.fetchAll()[0].isDeleted)
        let second = DatabaseManager(databaseURL: url)
        precondition(second.fetchAll().count == 1, "迁移必须可重复")

        let date = ISO8601DateFormatter().date(from: "2026-09-30T10:20:30Z")!
        let custom = TransactionCategory(rawValue: "设备维修")!
        var original = Transaction(date: date, type: .expense, amount: 18, category: custom,
                                   note: "测试 & <备注> \"中文\"", modifiedAt: Date(timeIntervalSince1970: 100.123))
        precondition(db.upsert(original))
        let oldSnapshot = original
        original.amount = 42
        original.date = ISO8601DateFormatter().date(from: "2026-10-02T10:20:30Z")!
        original.modifiedAt = Date(timeIntervalSince1970: 200.123)
        precondition(db.upsert(original) && db.batchUpsert([oldSnapshot]))
        precondition(db.fetchAll().first { $0.id == original.id }?.amount == 42)
        precondition(Calendar.current.component(.month, from: db.fetchAll().first { $0.id == original.id }!.date) == 10)

        precondition(db.delete(id: original.id) && db.batchUpsert([original, oldSnapshot]))
        let deleted = db.fetchAll().first { $0.id == original.id }!
        precondition(deleted.isDeleted, "旧同步快照不得恢复删除账单")
        let data = try OOXMLWriter.generateSync(transactions: [original, deleted])
        let read = try OOXMLReader.parse(data: data, requireIdentity: true)
        precondition(read.count == 2 && read[0].id == original.id && read[1].isDeleted)
        precondition(read[0].date == original.date && read[0].category == custom && read[0].amount == 42)
        precondition(read[0].note == original.note && abs(read[0].modifiedAt.timeIntervalSince(original.modifiedAt)) < 0.001)
        let repeatRead = try OOXMLReader.parse(data: data, requireIdentity: true)
        precondition(repeatRead.map(\.id) == read.map(\.id), "反复同步不得生成新 ID")
        let empty = try OOXMLReader.parse(data: OOXMLWriter.generateSync(transactions: []), requireIdentity: true)
        precondition(empty.isEmpty)
        let report = try OOXMLReader.parse(data: OOXMLWriter.generate(transactions: [original]))
        precondition(report.count == 1 && report[0].type == .expense && report[0].amount == 42 && report[0].category == custom)
        precondition(Calendar.current.component(.year, from: report[0].date) == 2026 && Calendar.current.component(.month, from: report[0].date) == 10)
        do {
            _ = try OOXMLReader.parse(data: OOXMLWriter.generate(transactions: [original]), requireIdentity: true)
            fatalError("旧六列表不能自动同步")
        } catch is SyncError {}

        let json = try JSONEncoder().encode(original)
        var legacy = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        legacy.removeValue(forKey: "isDeleted")
        let decoded = try JSONDecoder().decode(Transaction.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!decoded.isDeleted && decoded.category == custom)

        UserDefaults.standard.removeObject(forKey: "categoryNames")
        UserDefaults.standard.removeObject(forKey: "categoryOptions")
        let settings = CategorySettings.shared
        precondition(settings.save(name: "推广支出", type: .expense, editing: .advertising) == nil)
        precondition(settings.name(for: .advertising) == "推广支出")
        precondition(settings.categories(for: .expense).contains(.advertising), "改名保留广告口径")
        precondition(settings.save(name: "广告费", type: .expense, editing: nil) != nil, "不能重复添加已改名的原分类标识")
        precondition(settings.save(name: "设备维修", type: .expense, editing: nil) == nil)
        precondition(settings.categories(for: .expense).contains(custom))
        precondition(!settings.categories(for: .income).contains(custom))
        precondition(settings.save(name: "设备维修", type: .expense, editing: nil) != nil)
        settings.remove(custom, type: .expense)
        precondition(!settings.categories(for: .expense).contains(custom))
        precondition(db.fetchAll().first { $0.id == original.id }?.category == custom)
        try ledgerRegression(in: directory)
        dailyGroupingRegression()
        print("PASS: 旧库迁移、编辑删除、跨月修改、同步身份、分类管理、账本备份/新建/恢复、同步隔离、自动备份及失败保护")
    }

    static func ledgerRegression(in directory: URL) throws {
        let suite = "LedgerRegression.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(["房租": "办公场地"], forKey: "categoryNames")
        let root = directory.appendingPathComponent("ledgers", isDirectory: true)
        let store = LedgerStore(root: root, defaults: preferences)
        let oldContext = store.context
        precondition(oldContext.id == "legacy" && oldContext.syncFilename == "chaiwu_data.xlsx")
        let income = Transaction(type: .income, amount: 100, category: .clientDeposit)
        let expense = Transaction(type: .expense, amount: 20, category: .rent)
        precondition(oldContext.database.batchUpsert([income, expense]))
        let backup = try store.backupCurrent()
        precondition(backup.categoryNames["房租"] == "办公场地")
        precondition(tryCount(store, backup) == 2)

        try store.startNew(name: "十月账本")
        let newContext = store.context
        precondition(newContext.id != oldContext.id && newContext.syncFilename != oldContext.syncFilename)
        precondition(newContext.database.fetchAll().isEmpty && store.activeName == "十月账本")
        precondition(store.backups.count == 2 && tryCount(store, backup) == 2)
        let freshExpense = Transaction(type: .expense, amount: 5, category: .advertising)
        precondition(newContext.database.upsert(freshExpense))
        // 模拟切换前排队的同步仍写旧连接：不会写入新账本或改变已经完成的备份。
        let late = Transaction(type: .expense, amount: 999, category: .rent)
        precondition(oldContext.database.upsert(late))
        precondition(newContext.database.fetchAll().count == 1 && tryCount(store, backup) == 2)
        let afterRestart = LedgerStore(root: root, defaults: preferences)
        precondition(afterRestart.startupError == nil && afterRestart.context.id == newContext.id)
        precondition(afterRestart.context.database.fetchAll().first?.id == freshExpense.id)

        try store.restore(backup)
        precondition(store.context.id != oldContext.id && store.context.id != newContext.id)
        precondition(store.context.database.fetchAll().count == 2)
        precondition(store.context.database.fetchAll().reduce(Decimal(0), { $0 + ($1.type == .income ? $1.amount : -$1.amount) }) == 80)
        precondition(store.backups.count == 3)
        let preservedNewBook = store.backups.first { $0.ledgerID == newContext.id }!
        precondition(tryCount(store, preservedNewBook) == 1)
        let preservedTransactions = try store.transactions(in: preservedNewBook)
        precondition(preservedTransactions.first?.id == freshExpense.id)
        precondition(tryCount(store, backup) == 2, "恢复不修改原始备份")
        let restoredRestart = LedgerStore(root: root, defaults: preferences)
        precondition(restoredRestart.context.id == store.context.id && restoredRestart.context.database.fetchAll().count == 2)

        let day = Calendar.current.date(from: DateComponents(year: 2040, month: 2, day: 1, hour: 12))!
        let disabled = try store.automaticBackupIfNeeded(at: day)
        precondition(!disabled)
        preferences.set(true, forKey: "automaticLedgerBackup")
        let firstAuto = try store.automaticBackupIfNeeded(at: day)
        let repeatedAuto = try store.automaticBackupIfNeeded(at: day)
        let nextAuto = try store.automaticBackupIfNeeded(at: Calendar.current.date(byAdding: .day, value: 1, to: day)!)
        precondition(firstAuto && !repeatedAuto && nextAuto, "同一账本每天仅自动备份一次")

        let faultRoot = directory.appendingPathComponent("failure", isDirectory: true)
        let faultStore = LedgerStore(root: faultRoot, defaults: preferences)
        precondition(faultStore.context.database.upsert(expense))
        let beforeFailure = faultStore.context.id
        try FileManager.default.createDirectory(at: faultRoot.appendingPathComponent("ledgers.json"), withIntermediateDirectories: true)
        do {
            try faultStore.startNew(name: "不应开启")
            fatalError("无法保存备份索引时必须停止新建")
        } catch {}
        precondition(faultStore.context.id == beforeFailure && faultStore.context.database.fetchAll().count == 1)
        let badIndex = LedgerStore(root: faultRoot, defaults: preferences)
        precondition(badIndex.startupError != nil)
        do { _ = try badIndex.backupCurrent(); fatalError("索引损坏必须阻止写入") } catch {}

        let brokenBackup = store.backups.first!
        try FileManager.default.removeItem(at: root.appendingPathComponent(brokenBackup.databaseFile))
        let beforeRestore = store.context.id
        do { try store.restore(brokenBackup); fatalError("备份缺失时不得恢复") } catch {}
        precondition(store.context.id == beforeRestore && store.context.database.fetchAll().count == 2)

        let activeFile = root.appendingPathComponent("ledger_\(store.context.id).sqlite")
        try FileManager.default.removeItem(at: activeFile)
        let missingActive = LedgerStore(root: root, defaults: preferences)
        precondition(missingActive.startupError != nil)
        precondition(!FileManager.default.fileExists(atPath: activeFile.path), "活动账本缺失时不能创建空库掩盖异常")
    }

    static func tryCount(_ store: LedgerStore, _ backup: LedgerBackup) -> Int {
        do { return try store.transactions(in: backup).count }
        catch { fatalError("备份应可完整读取：\(error)") }
    }

    static func dailyGroupingRegression() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        let month = date("2026-09-15T00:00:00Z")
        let first = Transaction(date: date("2026-08-31T16:00:00Z"), type: .income, amount: 100, category: .clientDeposit)
        let sameDay = Transaction(date: date("2026-09-01T10:00:00Z"), type: .expense, amount: 20, category: .rent)
        let secondDay = Transaction(date: date("2026-09-01T16:00:00Z"), type: .expense, amount: 30, category: .rent)
        let october = Transaction(date: date("2026-09-30T16:00:00Z"), type: .expense, amount: 999, category: .rent)
        var deleted = first; deleted.id = UUID(); deleted.isDeleted = true
        var conflict = sameDay; conflict.id = UUID(); conflict.isConflict = true
        let source = [october, secondDay, sameDay, first, deleted, conflict]
        let groups = DailyTransactionGroup.groups(from: source, month: month, calendar: calendar)
        precondition(groups.count == 2 && calendar.component(.day, from: groups[0].id) == 1 && calendar.component(.day, from: groups[1].id) == 2)
        precondition(groups[0].incomeCount == 1 && groups[0].expenseCount == 1 && groups[0].income == 100 && groups[0].expense == 20)
        precondition(groups[0].transactions.map(\.id) == [first.id, sameDay.id])
        let income = DailyTransactionGroup.groups(from: source, month: month, filter: .income, calendar: calendar)
        let expense = DailyTransactionGroup.groups(from: source, month: month, filter: .expense, calendar: calendar)
        precondition(income.count == 1 && income[0].transactions.map(\.id) == [first.id])
        precondition(expense.count == 2 && expense.reduce(Decimal(0), { $0 + $1.expense }) == 50)
        var moved = first; moved.date = october.date
        let changed = DailyTransactionGroup.groups(from: [moved, sameDay, secondDay], month: month, calendar: calendar)
        precondition(changed.reduce(0, { $0 + $1.incomeCount }) == 0 && changed.count == 2)
    }
}
