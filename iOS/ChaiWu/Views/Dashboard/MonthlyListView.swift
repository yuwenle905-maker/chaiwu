import SwiftUI

struct MonthGroup: Identifiable {
    let id: String
    let transactions: [Transaction]
    var month: Date { Calendar.current.dateInterval(of: .month, for: transactions[0].date)!.start }
    var totalIncome: Decimal { transactions.filter { $0.type == .income }.reduce(0) { $0 + $1.amount } }
    var totalExpense: Decimal { transactions.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount } }
    var netBalance: Decimal { totalIncome - totalExpense }
}

struct MonthlyListView: View {
    @EnvironmentObject var vm: TransactionViewModel
    let filter: TransactionType?
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"; return f
    }()

    var groups: [MonthGroup] {
        Dictionary(grouping: vm.transactions, by: { Self.monthFmt.string(from: $0.date) })
            .map { name, entries in MonthGroup(id: name, transactions: entries.sorted { $0.date > $1.date }) }
            .filter { group in filter == nil || group.transactions.contains { $0.type == filter } }
            .sorted { $0.month > $1.month }
    }

    var body: some View {
        if groups.isEmpty {
            Text("暂无记录").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(groups) { group in MonthGroupCard(group: group) }
            }.padding(.bottom, 32)
        }
    }
}

// 月份/条数、收入、支出是独立入口，避免嵌套 NavigationLink。
struct MonthGroupCard: View {
    let group: MonthGroup
    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(destination: MonthDetailView(month: group.month, filter: nil)) {
                HStack {
                    Text(group.id).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    Text("\(group.transactions.count) 条").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().padding(.horizontal, 14)
            HStack(spacing: 0) {
                NavigationLink(destination: MonthDetailView(month: group.month, filter: .income)) {
                    MonthStat(label: "收入 ›", amount: group.totalIncome, color: .green)
                        .padding(.vertical, 14).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().frame(height: 30)
                NavigationLink(destination: MonthDetailView(month: group.month, filter: .expense)) {
                    MonthStat(label: "支出 ›", amount: group.totalExpense, color: .red)
                        .padding(.vertical, 14).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().frame(height: 30)
                MonthStat(label: "净额", amount: group.netBalance, color: group.netBalance >= 0 ? .blue : .red)
                    .padding(.vertical, 14)
            }
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
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(color)
                .minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
}

struct MonthDetailView: View {
    @EnvironmentObject var vm: TransactionViewModel
    let month: Date
    let filter: TransactionType?
    @State private var editingTransaction: Transaction?
    private var groups: [DailyTransactionGroup] {
        DailyTransactionGroup.groups(from: vm.transactions, month: month, filter: filter)
    }
    private var items: [Transaction] { groups.flatMap(\.transactions) }
    private var income: Decimal { groups.reduce(0) { $0 + $1.income } }
    private var expense: Decimal { groups.reduce(0) { $0 + $1.expense } }
    private var title: String {
        month.formatted(.dateTime.year().month()) + (filter.map { " · \($0.rawValue)明细" } ?? " · 按日明细")
    }

    var body: some View {
        List {
            Section {
                if let filter {
                    HStack {
                        Text("本月\(filter.rawValue)")
                        Spacer()
                        Text((filter == .income ? income : expense).formatted(.currency(code: "CNY")))
                            .font(.headline).foregroundStyle(filter == .income ? .green : .red)
                    }
                } else {
                    HStack(spacing: 0) {
                        MonthStat(label: "收入", amount: income, color: .green)
                        Divider().frame(height: 30)
                        MonthStat(label: "支出", amount: expense, color: .red)
                        Divider().frame(height: 30)
                        MonthStat(label: "净额", amount: income - expense, color: income >= expense ? .blue : .red)
                    }.padding(.vertical, 4)
                }
                Text("\(items.count) 条 · 按日期从早到晚排列")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if groups.isEmpty {
                Section { Text(filter.map { "本月暂无\($0.rawValue)记录" } ?? "本月暂无记录").foregroundStyle(.secondary) }
            }
            ForEach(groups) { day in
                Section {
                    ForEach(day.transactions) { transaction in
                        TransactionRow(transaction: transaction)
                            .onTapGesture { editingTransaction = transaction }
                            .swipeActions {
                                Button("删除", role: .destructive) { vm.delete(transaction) }
                            }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(day.id.formatted(.dateTime.month().day().weekday()))
                            .font(.headline).foregroundStyle(.primary)
                        if filter != .expense {
                            Text("收入 \(day.incomeCount) 条 · \(day.income.formatted(.currency(code: "CNY")))")
                                .foregroundStyle(.green)
                        }
                        if filter != .income {
                            Text("支出 \(day.expenseCount) 条 · \(day.expense.formatted(.currency(code: "CNY")))")
                                .foregroundStyle(.red)
                        }
                    }.font(.caption).textCase(nil).padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingTransaction) { EntryView(editing: $0).environmentObject(vm) }
        .alert("操作失败", isPresented: Binding(get: { vm.writeError != nil }, set: { if !$0 { vm.writeError = nil } })) {
            Button("好") { vm.writeError = nil }
        } message: { Text(vm.writeError ?? "") }
    }
}

// MARK: - 累计收入/支出 详情页
struct TotalDetailView: View {
    @ObservedObject private var categories = CategorySettings.shared
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
        }.sorted { ($0.items.first?.date ?? .distantPast) > ($1.items.first?.date ?? .distantPast) }
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
                                Text(categories.name(for: t.category)).font(.subheadline.weight(.medium))
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
        .alert("操作失败", isPresented: Binding(get: { vm.writeError != nil }, set: { if !$0 { vm.writeError = nil } })) {
            Button("好") { vm.writeError = nil }
        } message: { Text(vm.writeError ?? "") }
    }
}
