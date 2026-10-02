import Foundation
import Combine
import LocalAuthentication

@MainActor
final class TransactionViewModel: ObservableObject {
    @Published var transactions: [Transaction] = []
    @Published var conflicts: [Transaction] = []
    @Published var isUnlocked = false
    @Published var authError: String?
    @Published var importError: String?
    @Published var importSuccess: String?
    @Published var writeError: String?

    private let db = DatabaseManager.shared
    private let sync = SyncEngine.shared
    private var cancellables = Set<AnyCancellable>()

    var totalBalance: Decimal {
        transactions.reduce(0) { $0 + ($1.type == .income ? $1.amount : -$1.amount) }
    }
    var totalIncome: Decimal  { transactions.filter { $0.type == .income  }.reduce(0) { $0 + $1.amount } }
    var totalExpense: Decimal { transactions.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount } }
    var conflictCount: Int { conflicts.count }

    var advertisingTransactions: [Transaction] {
        transactions.filter {
            $0.type == .expense &&
            ($0.category == .advertising || $0.note.contains("广告"))
        }.sorted { $0.date > $1.date }
    }
    var totalAdvertising: Decimal {
        advertisingTransactions.reduce(0) { $0 + $1.amount }
    }
    var thisMonthAdvertising: Decimal {
        let cal = Calendar.current
        let now = Date()
        return advertisingTransactions
            .filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    init() {
        sync.$conflictCount
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func authenticate() {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: "验证身份以访问账单") { [weak self] success, err in
                DispatchQueue.main.async {
                    if success {
                        self?.isUnlocked = true
                        self?.reload()
                        SyncEngine.shared.startWatching()
                    } else {
                        self?.authError = err?.localizedDescription ?? "认证失败"
                    }
                }
            }
        } else {
            isUnlocked = true
            reload()
            SyncEngine.shared.startWatching()
        }
    }

    func reload() {
        let all = db.fetchAll()
        transactions = all.filter { !$0.isConflict && !$0.isDeleted }
        conflicts    = all.filter {  $0.isConflict && !$0.isDeleted }
    }

    @discardableResult
    func add(type: TransactionType, amount: Decimal, category: TransactionCategory,
             note: String, date: Date = Date()) -> Bool {
        let t = Transaction(date: date, type: type, amount: amount, category: category, note: note)
        guard db.upsert(t) else { writeError = db.lastError; return false }
        reload()
        sync.performSync()
        return true
    }

    @discardableResult
    func update(_ transaction: Transaction) -> Bool {
        var t = transaction
        let current = db.fetchAll().first { $0.id == t.id }
        guard current?.isDeleted != true else { writeError = "这条账单已删除，请返回列表刷新"; return false }
        t.modifiedAt = max(Date(), (current?.modifiedAt ?? t.modifiedAt).addingTimeInterval(0.001))
        t.isConflict = false
        guard db.upsert(t) else { writeError = db.lastError; return false }
        reload()
        sync.performSync()
        return true
    }

    @discardableResult
    func delete(_ transaction: Transaction) -> Bool {
        guard db.delete(id: transaction.id) else { writeError = db.lastError; return false }
        reload()
        sync.performSync()
        return true
    }

    func resolveConflict(keep: Transaction, discard: Transaction) {
        db.resolveConflict(keepID: keep.id, discardID: discard.id)
        reload()
        sync.performSync()
    }

    // MARK: - 导入表格（xlsx / xls / csv）

    func importXlsx(from url: URL) {
        importError = nil
        importSuccess = nil
        appLog("导入开始: \(url.lastPathComponent) ext=\(url.pathExtension)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                appLog("读取文件数据...")
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw NSError(domain: "Import", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(url.path)"])
                }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                appLog("文件大小: \(fileSize) bytes")

                let data = try Data(contentsOf: url)
                appLog("Data 读取成功, count=\(data.count)")

                let ext = url.pathExtension.lowercased()
                appLog("扩展名: \(ext), 开始解析...")

                let imported = try XlsxManager.shared.importAny(from: url, data: data)
                appLog("解析完成, 共 \(imported.count) 条", level: .info)

                guard self.db.batchUpsert(imported) else {
                    throw NSError(domain: "Database", code: 1, userInfo: [NSLocalizedDescriptionKey: self.db.lastError])
                }
                appLog("数据库写入完成")

                DispatchQueue.main.async {
                    self.reload()
                    self.importSuccess = "成功导入 \(imported.count) 条记录"
                    appLog("导入成功完成")
                }
            } catch {
                appLog("导入异常: \(error)", level: .error)
                appLog("详细: \((error as NSError).userInfo)", level: .error)
                DispatchQueue.main.async {
                    self.importError = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
