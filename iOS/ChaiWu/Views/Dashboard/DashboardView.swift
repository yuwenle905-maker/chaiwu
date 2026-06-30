import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var vm: TransactionViewModel
    @EnvironmentObject var sync: SyncEngine
    @State private var showEntry = false
    @State private var showConflict = false
    @State private var selectedFilter: TransactionType? = nil

    var filteredTransactions: [Transaction] {
        guard let f = selectedFilter else { return vm.transactions }
        return vm.transactions.filter { $0.type == f }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 冲突提示 Banner
                    if vm.conflictCount > 0 {
                        conflictBanner
                    }

                    // 汇总卡片
                    summaryCards

                    // 收支筛选
                    filterBar

                    // 流水列表
                    transactionList
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("柴务")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showEntry = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    syncStatus
                }
            }
            .sheet(isPresented: $showEntry) {
                EntryView()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $showConflict) {
                ConflictCenterView()
                    .environmentObject(vm)
            }
        }
    }

    // MARK: - 子视图

    private var conflictBanner: some View {
        Button(action: { showConflict = true }) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                Text("检测到 \(vm.conflictCount) 条数据冲突，点击处理")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(14)
            .background(Color.red.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var summaryCards: some View {
        VStack(spacing: 12) {
            // 余额大卡
            VStack(spacing: 4) {
                Text("当前余额")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(vm.totalBalance.formatted(.currency(code: "CNY")))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(vm.totalBalance >= 0 ? Color.primary : Color.red)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)

            // 收支双卡
            HStack(spacing: 12) {
                SummaryMiniCard(title: "累计收入", amount: vm.totalIncome, color: .green)
                SummaryMiniCard(title: "累计支出", amount: vm.totalExpense, color: .red)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterChip(label: "全部", selected: selectedFilter == nil) {
                selectedFilter = nil
            }
            FilterChip(label: "收入", selected: selectedFilter == .income) {
                selectedFilter = .income
            }
            FilterChip(label: "支出", selected: selectedFilter == .expense) {
                selectedFilter = .expense
            }
            Spacer()
            Text("\(filteredTransactions.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transactionList: some View {
        LazyVStack(spacing: 8, pinnedViews: []) {
            ForEach(filteredTransactions) { t in
                TransactionRow(transaction: t)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            vm.delete(t)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .padding(.bottom, 32)
    }

    private var syncStatus: some View {
        HStack(spacing: 4) {
            if sync.isSyncing {
                ProgressView().scaleEffect(0.8)
                Text("同步中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let err = sync.syncError {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .help(err)
            } else {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
            }
        }
    }
}

struct SummaryMiniCard: View {
    let title: String
    let amount: Decimal
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: title == "累计收入" ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundStyle(color)
                            .font(.system(size: 14))
                    )
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(amount.formatted(.currency(code: "CNY")))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selected ? Color.blue : Color(.systemFill))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            // 分类图标
            Circle()
                .fill(transaction.type == .income ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay(
                    Text(categoryEmoji)
                        .font(.system(size: 20))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.category.rawValue)
                    .font(.subheadline.weight(.medium))
                if !transaction.note.isEmpty {
                    Text(transaction.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(transaction.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text((transaction.type == .income ? "+" : "-") +
                 transaction.amount.formatted(.currency(code: "CNY")))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(transaction.type == .income ? .green : .red)
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var categoryEmoji: String {
        switch transaction.category {
        case .food: return "🍜"
        case .transport: return "🚇"
        case .shopping: return "🛍️"
        case .entertainment: return "🎬"
        case .health: return "💊"
        case .education: return "📚"
        case .salary: return "💰"
        case .investment: return "📈"
        case .other: return "📌"
        }
    }
}
