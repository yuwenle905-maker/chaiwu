import SwiftUI

struct EntryView: View {
    @EnvironmentObject var vm: TransactionViewModel
    @Environment(\.dismiss) private var dismiss

    // 编辑模式传入已有账单；nil 表示新增
    var editing: Transaction?

    @State private var type: TransactionType
    @State private var amountText: String
    @State private var category: TransactionCategory
    @State private var note: String
    @State private var date: Date
    @State private var showError = false

    init(editing: Transaction? = nil) {
        self.editing = editing
        _type        = State(initialValue: editing?.type ?? .expense)
        _amountText  = State(initialValue: editing.map { "\($0.amount)" } ?? "")
        _category    = State(initialValue: editing?.category ?? .advertising)
        _note        = State(initialValue: editing?.note ?? "")
        _date        = State(initialValue: editing?.date ?? Date())
    }

    var amount: Decimal? { Decimal(string: amountText) }

    var availableCategories: [TransactionCategory] {
        TransactionCategory.categories(for: type)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $type) {
                        ForEach(TransactionType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: type) { _ in
                        if !availableCategories.contains(category) {
                            category = availableCategories[0]
                        }
                    }
                }

                Section("金额") {
                    HStack {
                        Text("¥")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(type == .income ? Color.green : Color.red)
                    }
                }

                Section("分类") {
                    Picker("分类", selection: $category) {
                        ForEach(availableCategories, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120)
                }

                Section("备注") {
                    TextField("请输入备注（可选）", text: $note, axis: .vertical)
                        .lineLimit(3)
                }

                Section("日期") {
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            .navigationTitle(editing == nil ? "新增账单" : "编辑账单")
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
        if var t = editing {
            t.type = type; t.amount = amt; t.category = category
            t.note = note; t.date = date
            vm.update(t)
        } else {
            vm.add(type: type, amount: amt, category: category, note: note, date: date)
        }
        dismiss()
    }
}
