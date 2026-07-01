import SwiftUI

// MARK: - 月度分组数据
struct MonthGroup: Identifiable {
    let id: String
    let transactions: [Transaction]

    var totalIncome:  Decimal { transactions.filter { $0.type == .income  }.reduce(0) { $0 + $1.amount } }
    var totalExpense: Decimal { transactions.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount } }
    var netBalance:   Decimal { totalIncome - totalExpense }
}

// MARK: - 月度列表（替换原 transactionList）
struct MonthlyListView: View {
    @EnvironmentObject var vm: TransactionViewModel
    let filter: TransactionType?

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"; return f
    }()

    var groups: [MonthGroup] {
        let source = filter == nil ? vm.transactions : vm.transactions.filter { $0.type == filter }
        var dict: [String: [Transaction]] = [:]
        for t in source {
            let key = Self.monthFmt.string(from: t.date)
            dict[key, default: []].append(t)
        }
        return dict.map { key, items in
            MonthGroup(id: key, transactions: items.sorted { $0.date > $1.date })
        }.sorted { $0.id > $1.id }
    }

    var body: some View {
        if groups.isEmpty {
            Text("暂无记录").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(groups) { group in
                    NavigationLink(destination: MonthDetailView(group: group).environmentObject(vm)) {
                        MonthGroupCard(group: group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 32)
        }
    }
}

// MARK: - 月份卡片（收纳状态）
struct MonthGroupCard: View {
    let group: MonthGroup

    var body: some View {
        VStack(spacing: 0) {
            // 月份标题行
            HStack {
                Text(group.id)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(group.transactions.count) 条")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            // 收入 / 支出 / 净额
            HStack(spacing: 0) {
                MonthStat(label: "收入", amount: group.totalIncome,  color: .green)
                Divider().frame(height: 30)
                MonthStat(label: "支出", amount: group.totalExpense, color: .red)
                Divider().frame(height: 30)
                MonthStat(label: "净额",
                          amount: group.netBalance,
                          color: group.netBalance >= 0 ? .blue : .red)
            }
            .padding(.vertical, 10)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

private struct MonthStat: View {
    let label: String; let amount: Decimal; let color: Color
    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(amount.formatted(.currency(code: "CNY")))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 月度详情页
struct MonthDetailView: View {
    @EnvironmentObject var vm: TransactionViewModel
    let group: MonthGroup
    @State private var editingTransaction: Transaction?

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "d日 HH:mm"; return f
    }()

    var body: some View {
        List {
            // 月度汇总
            Section {
                HStack(spacing: 0) {
                    MonthStat(label: "收入", amount: group.totalIncome,  color: .green)
                    Divider().frame(height: 30)
                    MonthStat(label: "支出", amount: group.totalExpense, color: .red)
                    Divider().frame(height: 30)
                    MonthStat(label: "净额",
                              amount: group.netBalance,
                              color: group.netBalance >= 0 ? .blue : .red)
                }
                .padding(.vertical, 4)
            }

            // 明细列表（按日期降序）
            let incomeItems  = group.transactions.filter { $0.type == .income }
            let expenseItems = group.transactions.filter { $0.type == .expense }

            if !incomeItems.isEmpty {
                Section("收入明细") {
                    ForEach(incomeItems) { t in
                        TransactionRow(transaction: t)
                            .onTapGesture { editingTransaction = t }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { vm.delete(t) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            if !expenseItems.isEmpty {
                Section("支出明细") {
                    ForEach(expenseItems) { t in
                        TransactionRow(transaction: t)
                            .onTapGesture { editingTransaction = t }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { vm.delete(t) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editingTransaction) { t in
            EntryView(editing: t).environmentObject(vm)
        }
    }
}

// MARK: - 累计收入/支出 详情页
struct TotalDetailView: View {
    @EnvironmentObject var vm: TransactionViewModel
    let type: TransactionType
    @State private var editingTransaction: Transaction?

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"; return f
    }()

    private var items: [Transaction] {
        vm.transactions.filter { $0.type == type }.sorted { $0.date > $1.date }
    }

    private var grouped: [(month: String, items: [Transaction], total: Decimal)] {
        var dict: [String: [Transaction]] = [:]
        for t in items {
            let key = Self.monthFmt.string(from: t.date)
            dict[key, default: []].append(t)
        }
        return dict.map { key, txs in
            (month: key, items: txs.sorted { $0.date > $1.date },
             total: txs.reduce(0) { $0 + $1.amount })
        }.sorted { $0.month > $1.month }
    }

    private var title: String { type == .income ? "累计收入" : "累计支出" }
    private var total: Decimal { type == .income ? vm.totalIncome : vm.totalExpense }
    private var color: Color   { type == .income ? .green : .red }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"; return f
    }()

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.subheadline).foregroundStyle(.secondary)
                        Text(total.formatted(.currency(code: "CNY")))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                    }
                    Spacer()
                    Text("\(items.count) 条").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ForEach(grouped, id: \.month) { group in
                Section {
                    ForEach(group.items) { t in
                        HStack(spacing: 10) {
                            Text(Self.dayFmt.string(from: t.date))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.category.rawValue).font(.subheadline.weight(.medium))
                                if !t.note.isEmpty {
                                    Text(t.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(t.amount.formatted(.currency(code: "CNY")))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(color)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingTransaction = t }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { vm.delete(t) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.month)
                        Spacer()
                        Text(group.total.formatted(.currency(code: "CNY")))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(color)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editingTransaction) { t in
            EntryView(editing: t).environmentObject(vm)
        }
    }
}
