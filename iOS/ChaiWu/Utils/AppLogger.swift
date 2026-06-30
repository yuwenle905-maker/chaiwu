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

    private init() {}

    func log(_ msg: String, level: Entry.Level = .info, file: String = #file, line: Int = #line) {
        let src = (file as NSString).lastPathComponent
        let entry = Entry(date: Date(), level: level, message: "(\(src):\(line)) \(msg)")
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > 500 { self.entries.removeFirst() }
        }
    }

    func clear() { entries.removeAll() }
}

// 便捷全局函数
func appLog(_ msg: String, level: AppLogger.Entry.Level = .info, file: String = #file, line: Int = #line) {
    AppLogger.shared.log(msg, level: level, file: file, line: line)
}
