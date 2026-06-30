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

    func startWatching() {
        let xlsxPath = XlsxManager.shared.xlsxURL.path
        let fd = open(xlsxPath, O_EVTONLY)
        guard fd != -1 else { return }

        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: syncQueue
        )
        fileWatcher?.setEventHandler { [weak self] in
            self?.performSync()
        }
        fileWatcher?.setCancelHandler { close(fd) }
        fileWatcher?.resume()
    }

    func performSync() {
        syncQueue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.isSyncing = true; self.syncError = nil }

            do {
                let remote = try XlsxManager.shared.importFromXlsx()
                let local  = DatabaseManager.shared.fetchAll()
                let (merged, conflicts) = self.merge(local: local, remote: remote)

                DatabaseManager.shared.batchUpsert(merged)
                try XlsxManager.shared.exportToXlsx(merged)

                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.lastSyncDate = Date()
                    self.conflictCount = conflicts.count
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSyncing = false
                    self.syncError = error.localizedDescription
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
                    // 本地更新：检查是否有实质性差异
                    if hasSubstantiveDiff(localT, remoteT) {
                        // 生成冲突对：本地标记 conflict=true，保留两份（用不同 UUID）
                        var conflictCopy = remoteT
                        conflictCopy.id = UUID()
                        conflictCopy.isConflict = true
                        var localMarked = localT
                        localMarked.isConflict = true
                        byID[localT.id] = localMarked
                        byID[conflictCopy.id] = conflictCopy
                        conflicts.append(ConflictPair(local: localMarked, remote: conflictCopy))
                    }
                }
            } else {
                byID[remoteT.id] = remoteT
            }
        }
        return (Array(byID.values), conflicts)
    }

    private func hasSubstantiveDiff(_ a: Transaction, _ b: Transaction) -> Bool {
        a.amount != b.amount || a.type != b.type || a.category != b.category || a.note != b.note
    }
}
