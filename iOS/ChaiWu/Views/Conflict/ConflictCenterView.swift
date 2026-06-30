import SwiftUI

struct ConflictCenterView: View {
    @EnvironmentObject var vm: TransactionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.conflicts.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.green)
                        Text("没有数据冲突")
                            .font(.title2.weight(.semibold))
                        Text("所有数据已同步一致")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(conflictPairs, id: \.0.id) { local, remote in
                            Section {
                                ConflictPairRow(local: local, remote: remote) { choice in
                                    switch choice {
                                    case .keepLocal:
                                        vm.resolveConflict(keep: local, discard: remote)
                                    case .keepRemote:
                                        vm.resolveConflict(keep: remote, discard: local)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("冲突处理中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // 将冲突列表两两配对（本地 vs 云端）
    private var conflictPairs: [(Transaction, Transaction)] {
        let sorted = vm.conflicts.sorted { $0.modifiedAt > $1.modifiedAt }
        var pairs: [(Transaction, Transaction)] = []
        var used = Set<UUID>()
        for t in sorted {
            guard !used.contains(t.id) else { continue }
            // 找同金额同日期的配对（同一原始 UUID 冲突产生的两份）
            if let match = sorted.first(where: { !used.contains($0.id) && $0.id != t.id && $0.date == t.date && $0.amount == t.amount }) {
                pairs.append((t, match))
                used.insert(t.id)
                used.insert(match.id)
            }
        }
        return pairs
    }
}

enum ConflictChoice { case keepLocal, keepRemote }

struct ConflictPairRow: View {
    let local: Transaction
    let remote: Transaction
    let onResolve: (ConflictChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(local.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                conflictCard(t: local, label: "本地版本", color: .blue)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                conflictCard(t: remote, label: "云端版本", color: .orange)
            }

            HStack(spacing: 12) {
                Button {
                    onResolve(.keepLocal)
                } label: {
                    Label("保留本地", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.blue)

                Button {
                    onResolve(.keepRemote)
                } label: {
                    Label("保留云端", systemImage: "icloud")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func conflictCard(t: Transaction, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            Text(t.amount.formatted(.currency(code: "CNY")))
                .font(.subheadline.weight(.bold))
            Text(t.type.rawValue + " · " + t.category.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !t.note.isEmpty {
                Text(t.note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Text("来自: \(t.sourceDevice)")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
