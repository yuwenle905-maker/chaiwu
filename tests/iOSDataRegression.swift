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
        print("PASS: 旧库迁移、金额与跨月修改、删除保护、同步身份与日期、中文分类、旧 JSON、分类管理")
    }
}
