import Foundation
import Combine

final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var conflictCount = 0
    @Published var syncError: String?

    private var fileWatcher: DispatchSourceFileSystemObject?
    private let syncQueue = DispatchQueue(label: "com.chaiwu.sync", qos: .utility)
    private var lastExportedData: Data?

    func startWatching() {
        guard fileWatcher == nil else { return }
        let directory = XlsxManager.shared.xlsxURL.deletingLastPathComponent().path
        let fd = open(directory, O_EVTONLY)
        guard fd != -1 else { return }

        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: syncQueue
        )
        fileWatcher?.setEventHandler { [weak self] in
            guard let self else { return }
            let data = try? Data(contentsOf: XlsxManager.shared.xlsxURL)
            guard data != self.lastExportedData else { return }
            self.performSync()
        }
        fileWatcher?.setCancelHandler { close(fd) }
        fileWatcher?.resume()
        performSync()
    }

    func performSync() {
        syncQueue.async { [weak self] in
            guard let self else { return }
            let context = LedgerStore.shared.context
            let syncURL = XlsxManager.shared.url(for: context.syncFilename)
            DispatchQueue.main.async {
                guard LedgerStore.shared.context.id == context.id else { return }
                self.isSyncing = true; self.syncError = nil
            }

            do {
                if let error = LedgerStore.shared.startupError { throw SyncError.parseError(error) }
                let remote = try XlsxManager.shared.importFromXlsx(at: syncURL)
                let local  = context.database.fetchAll()
                let (merged, conflicts) = self.merge(local: local, remote: remote)

                guard context.database.batchUpsert(merged) else {
                    throw SyncError.parseError(context.database.lastError)
                }
                // 再读一次，纳入同步期间保存的编辑及删除。
                try XlsxManager.shared.exportToXlsx(context.database.fetchAll(), to: syncURL)
                self.lastExportedData = try Data(contentsOf: syncURL)

                DispatchQueue.main.async {
                    guard LedgerStore.shared.context.id == context.id else { return }
                    self.isSyncing = false
                    self.lastSyncDate = Date()
                    self.conflictCount = conflicts.count
                }
            } catch {
                DispatchQueue.main.async {
                    guard LedgerStore.shared.context.id == context.id else { return }
                    self.isSyncing = false
                    self.syncError = error.localizedDescription
                }
            }
        }
    }

    // 仅在用户确认后，以本机数据库重建缺少 ID 的旧同步文件；原文件由写入器备份。
    func rebuildSyncFile() {
        syncQueue.async { [weak self] in
            guard let self else { return }
            let context = LedgerStore.shared.context
            let syncURL = XlsxManager.shared.url(for: context.syncFilename)
            DispatchQueue.main.async {
                guard LedgerStore.shared.context.id == context.id else { return }
                self.isSyncing = true; self.syncError = nil
            }
            do {
                if let error = LedgerStore.shared.startupError { throw SyncError.parseError(error) }
                try XlsxManager.shared.exportToXlsx(context.database.fetchAll(), to: syncURL)
                self.lastExportedData = try Data(contentsOf: syncURL)
                DispatchQueue.main.async {
                    guard LedgerStore.shared.context.id == context.id else { return }
                    self.isSyncing = false; self.lastSyncDate = Date()
                }
            } catch {
                DispatchQueue.main.async {
                    guard LedgerStore.shared.context.id == context.id else { return }
                    self.isSyncing = false; self.syncError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Last-Write-Wins 合并 + 冲突检测

    private func merge(local: [Transaction], remote: [Transaction]) -> ([Transaction], [ConflictPair]) {
        var byID: [UUID: Transaction] = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var conflicts: [ConflictPair] = []

        for remoteT in remote {
            if let localT = byID[remoteT.id] {
                if localT.modifiedAt == remoteT.modifiedAt { continue } // 相同，无需处理

                if remoteT.modifiedAt > localT.modifiedAt {
                    // 远端更新：直接覆盖
                    byID[remoteT.id] = remoteT
                } else {
                    // 本地比远端新：本地直接胜出，不产生冲突
                    // （remote 是上次导出的旧快照，不能覆盖用户刚做的编辑）
                }
            } else {
                byID[remoteT.id] = remoteT
            }
        }
        return (Array(byID.values), conflicts)
    }

}
