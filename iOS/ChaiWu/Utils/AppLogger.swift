import Foundation

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String

        enum Level: String { case info = "ℹ️"; case warn = "⚠️"; case error = "❌" }

        var formatted: String {
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
            return "[\(df.string(from: date))] \(level.rawValue) \(message)"
        }
    }

    private let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("chaiwu_log.txt")
    }()

    private init() {
        loadFromDisk()
    }

    func log(_ msg: String, level: Entry.Level = .info, file: String = #file, line: Int = #line) {
        let src = (file as NSString).lastPathComponent
        let entry = Entry(date: Date(), level: level, message: "(\(src):\(line)) \(msg)")
        appendToDisk(entry)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > 500 { self.entries.removeFirst() }
        }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    // MARK: - 磁盘持久化

    private func appendToDisk(_ entry: Entry) {
        let line = entry.formatted + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
        trimDiskLog()
    }

    private func loadFromDisk() {
        guard let text = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let recent = lines.suffix(500)
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
        entries = recent.map { line in
            // 格式: [HH:mm:ss.SSS] emoji (file:line) msg
            let level: Entry.Level
            if line.contains("⚠️") { level = .warn }
            else if line.contains("❌") { level = .error }
            else { level = .info }
            return Entry(date: Date(), level: level, message: line)
        }
    }

    private func trimDiskLog() {
        guard let text = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count > 600 {
            let trimmed = lines.suffix(500).joined(separator: "\n") + "\n"
            try? trimmed.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }
}

func appLog(_ msg: String, level: AppLogger.Entry.Level = .info, file: String = #file, line: Int = #line) {
    AppLogger.shared.log(msg, level: level, file: file, line: line)
}
