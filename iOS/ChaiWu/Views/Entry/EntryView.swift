import SwiftUI

struct EntryView: View {
    @EnvironmentObject var vm: TransactionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var type: TransactionType = .expense
    @State private var amountText = ""
    @State private var category: TransactionCategory = .food
    @State private var note = ""
    @State private var date = Date()
    @State private var showError = false

    var amount: Decimal? { Decimal(string: amountText) }

    var body: some View {
        NavigationStack {
            Form {
                // 收/支切换
                Section {
                    Picker("类型", selection: $type) {
                        ForEach(TransactionType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("金额") {
                    HStack {
                        Text("¥")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(type == .income ? .green : .red)
                    }
                }

                Section("分类") {
                    Picker("分类", selection: $category) {
                        ForEach(TransactionCategory.allCases, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                }

                Section("备注") {
                    TextField("可选", text: $note, axis: .vertical)
                        .lineLimit(3)
                }

                Section("日期") {
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            .navigationTitle("新增记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .font(.headline)
                        .disabled(amount == nil || amountText.isEmpty)
                }
            }
            .alert("请输入有效金额", isPresented: $showError) {
                Button("好") {}
            }
        }
    }

    private func save() {
        guard let amt = amount, amt > 0 else { showError = true; return }
        vm.add(type: type, amount: amt, category: category, note: note)
        dismiss()
    }
}
