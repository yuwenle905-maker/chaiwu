import SwiftUI

struct LogViewerView: View {
    @ObservedObject private var logger = AppLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var filtered: [AppLogger.Entry] {
        guard !filter.isEmpty else { return logger.entries.reversed() }
        return logger.entries.reversed().filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if logger.entries.isEmpty {
                    Spacer()
                    Text("暂无日志").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    TextField("搜索...", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal).padding(.top, 8)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(filtered) { entry in
                                    Text(entry.formatted)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(color(for: entry.level))
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 12)
                                        .id(entry.id)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onAppear {
                            if let first = filtered.first { proxy.scrollTo(first.id) }
                        }
                    }
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive, action: { logger.clear() }) {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: logger.entries.map(\.formatted).joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func color(for level: AppLogger.Entry.Level) -> Color {
        switch level {
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}
