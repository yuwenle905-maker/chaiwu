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

    private let db = DatabaseManager.shared
    private let sync = SyncEngine.shared
    private var cancellables = Set<AnyCancellable>()

    var totalBalance: Decimal {
        transactions.reduce(0) { $0 + ($1.type == .income ? $1.amount : -$1.amount) }
    }
    var totalIncome: Decimal  { transactions.filter { $0.type == .income  }.reduce(0) { $0 + $1.amount } }
    var totalExpense: Decimal { transactions.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount } }
    var conflictCount: Int { conflicts.count }

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
        transactions = all.filter { !$0.isConflict }
        conflicts    = all.filter {  $0.isConflict }
    }

    func add(type: TransactionType, amount: Decimal, category: TransactionCategory, note: String) {
        let t = Transaction(type: type, amount: amount, category: category, note: note)
        db.upsert(t)
        reload()                  // 立即刷新 UI
        sync.performSync()        // 异步同步到 xlsx
    }

    func delete(_ transaction: Transaction) {
        db.delete(id: transaction.id)
        reload()
        sync.performSync()
    }

    func resolveConflict(keep: Transaction, discard: Transaction) {
        db.resolveConflict(keepID: keep.id, discardID: discard.id)
        reload()
        sync.performSync()
    }

    // MARK: - 导入 xlsx

    func importXlsx(from url: URL) {
        importError = nil
        importSuccess = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // 安全访问沙盒外文件（Files App 选取）
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                let data = try Data(contentsOf: url)
                let imported = try OOXMLReader.parse(data: data)
                self.db.batchUpsert(imported)

                DispatchQueue.main.async {
                    self.reload()
                    self.importSuccess = "成功导入 \(imported.count) 条记录"
                }
            } catch {
                DispatchQueue.main.async {
                    self.importError = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
