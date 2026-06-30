import SwiftUI

struct AdvertisingDetailView: View {
    @EnvironmentObject var vm: TransactionViewModel

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"; return f
    }()

    // 按月分组，月份降序
    private var grouped: [(month: String, total: Decimal, items: [Transaction])] {
        let fmt = Self.monthFmt
        var dict: [String: [Transaction]] = [:]
        for t in vm.advertisingTransactions {
            let key = fmt.string(from: t.date)
            dict[key, default: []].append(t)
        }
        return dict.map { key, items in
            let total = items.reduce(Decimal(0)) { $0 + $1.amount }
            return (month: key, total: total, items: items.sorted { $0.date > $1.date })
        }.sorted { $0.month > $1.month }
    }

    var body: some View {
        NavigationStack {
            List {
                // 总计 banner
                Section {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("本月广告支出").font(.caption).foregroundStyle(.secondary)
                            Text(vm.thisMonthAdvertising.formatted(.currency(code: "CNY")))
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("累计广告支出").font(.caption).foregroundStyle(.secondary)
                            Text(vm.totalAdvertising.formatted(.currency(code: "CNY")))
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                    .padding(.vertical, 6)
                }

                if grouped.isEmpty {
                    Section {
                        Text("暂无广告支出记录")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }

                // 按月分组
                ForEach(grouped, id: \.month) { group in
                    Section {
                        ForEach(group.items) { t in
                            HStack(spacing: 12) {
                                Text(Self.dayFmt.string(from: t.date))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.note.isEmpty ? "广告费" : t.note)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text("-" + t.amount.formatted(.currency(code: "CNY")))
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text(group.month)
                                .font(.headline)
                            Spacer()
                            Text(group.total.formatted(.currency(code: "CNY")))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("广告支出明细")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
