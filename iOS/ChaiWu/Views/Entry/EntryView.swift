import SwiftUI

struct EntryView: View {
    @EnvironmentObject var vm: TransactionViewModel
    @Environment(\.dismiss) private var dismiss

    // 编辑模式传入已有账单；nil 表示新增
    var editing: Transaction?
    private let ledgerID: String

    @State private var type: TransactionType
    @State private var amountText: String
    @State private var category: TransactionCategory
    @State private var note: String
    @State private var date: Date
    @State private var showError = false
    @State private var showDelete = false
    @ObservedObject private var categories = CategorySettings.shared

    init(editing: Transaction? = nil) {
        self.editing = editing
        self.ledgerID = LedgerStore.shared.context.id
        _type        = State(initialValue: editing?.type ?? .expense)
        _amountText  = State(initialValue: editing.map { "\($0.amount)" } ?? "")
        _category    = State(initialValue: editing?.category ?? CategorySettings.shared.categories(for: .expense).first ?? .custom)
        _note        = State(initialValue: editing?.note ?? "")
        _date        = State(initialValue: editing?.date ?? Date())
    }

    var amount: Decimal? { Decimal(string: amountText) }

    var availableCategories: [TransactionCategory] {
        var result = categories.categories(for: type)
        if !result.contains(category) { result.append(category) }
        return result
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
                        if !categories.categories(for: type).contains(category) {
                            category = categories.categories(for: type).first ?? .custom
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
                            Text(categories.name(for: c)).tag(c)
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
                    Text("补录可选择以前的日期，账单按此日期归入对应月份。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let t = editing {
                    Section {
                        Button("删除这条账单", role: .destructive) { showDelete = true }
                            .confirmationDialog("删除这条账单？", isPresented: $showDelete, titleVisibility: .visible) {
                                Button("删除", role: .destructive) {
                                    if vm.delete(t, ledgerID: ledgerID) { dismiss() }
                                }
                            }
                    }
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
            .alert("保存失败", isPresented: Binding(get: { vm.writeError != nil }, set: { if !$0 { vm.writeError = nil } })) {
                Button("好") { vm.writeError = nil }
            } message: { Text(vm.writeError ?? "") }
        }
    }

    private func save() {
        guard let amt = amount, amt > 0 else { showError = true; return }
        if var t = editing {
            t.type = type; t.amount = amt; t.category = category
            t.note = note; t.date = date
            guard vm.update(t, ledgerID: ledgerID) else { return }
        } else {
            guard vm.add(type: type, amount: amt, category: category, note: note, date: date, ledgerID: ledgerID) else { return }
        }
        dismiss()
    }
}

// 分类设置只改变选项和显示名称，不重写历史账单或广告统计标识。
final class CategorySettings: ObservableObject {
    static let shared = CategorySettings()
    private let defaults = UserDefaults.standard
    @Published private var names: [String: String]
    @Published private var options: [String: [String]]

    private init() {
        names = defaults.dictionary(forKey: "categoryNames") as? [String: String] ?? [:]
        options = defaults.dictionary(forKey: "categoryOptions") as? [String: [String]] ?? [:]
    }

    func categories(for type: TransactionType) -> [TransactionCategory] {
        let values = options[type.rawValue] ?? TransactionCategory.categories(for: type).map(\.rawValue)
        return values.compactMap { TransactionCategory(rawValue: $0) }
    }

    func name(for category: TransactionCategory) -> String { names[category.rawValue] ?? category.rawValue }

    func save(name: String, type: TransactionType, editing: TransactionCategory?) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "分类名称不能为空" }
        let list = categories(for: type)
        guard !list.contains(where: { $0 != editing && (self.name(for: $0) == value || $0.rawValue == value) }) else { return "同类型已有这个分类" }
        if let editing {
            names[editing.rawValue] = value
        } else {
            // 内部标识稳定，即使以后改名，账单仍可识别原分类。
            let key = value
            names[key] = value
            options[type.rawValue] = list.map(\.rawValue) + [key]
        }
        persist()
        return nil
    }

    func remove(_ category: TransactionCategory, type: TransactionType) {
        options[type.rawValue] = categories(for: type).filter { $0 != category }.map(\.rawValue)
        persist()
    }

    private func persist() {
        defaults.set(names, forKey: "categoryNames")
        defaults.set(options, forKey: "categoryOptions")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var vm: TransactionViewModel
    @ObservedObject private var ledgers = LedgerStore.shared
    @AppStorage("automaticLedgerBackup") private var automaticBackup = false
    @ObservedObject private var sync = SyncEngine.shared
    @AppStorage("biometricLockEnabled") private var biometricLockEnabled = false
    @ObservedObject private var categories = CategorySettings.shared
    @State private var selectedType: TransactionType = .expense
    @State private var editing: TransactionCategory?
    @State private var name = ""
    @State private var showEditor = false
    @State private var error: String?
    @State private var showRebuild = false
    @State private var showNewLedger = false
    @State private var newLedgerName = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("当前账本", value: ledgers.activeName)
                Button("一键备份当前账本") { vm.backupLedger() }
                    .disabled(vm.isImporting || sync.isSyncing || ledgers.startupError != nil)
                Button("备份并新建账本") { newLedgerName = ""; showNewLedger = true }
                    .disabled(vm.isImporting || sync.isSyncing || ledgers.startupError != nil)
                NavigationLink("历史备份（\(ledgers.backups.count)份）") {
                    LedgerHistoryView().environmentObject(vm)
                }
                Toggle("每天首次打开自动备份", isOn: $automaticBackup)
                    .onChange(of: automaticBackup) { enabled in if enabled { vm.automaticBackupIfNeeded() } }
            } header: { Text("账本与备份") } footer: {
                Text("新建前自动完整备份，成功后开启零记录的新账本，保留分类设置。历史备份保存在本机，不自动清理，可查看或恢复。每日自动备份需打开 App 才会执行。")
            }
            if let success = vm.importSuccess {
                Section { Text(success).foregroundStyle(.green) }
            }
            if let failure = vm.writeError {
                Section { Text(failure).foregroundStyle(.red) }
            }
            Section("隐私") { Toggle("面容 / 指纹解锁", isOn: $biometricLockEnabled) }
            Section {
                if let message = sync.syncError { Text(message).foregroundStyle(.red) }
                Button("手动同步") { sync.performSync() }.disabled(sync.isSyncing)
                Button("备份并重建旧同步文件") { showRebuild = true }.disabled(sync.isSyncing)
            } header: { Text("同步") } footer: {
                Text("旧版六列同步表没有账单 ID，不能可靠合并。重建前请确认需要保留的账单均在本机；原同步文件会保留备份。两端同步须使用支持删除标记的版本。")
            }
            Section {
                Picker("类型", selection: $selectedType) {
                    ForEach(TransactionType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                ForEach(categories.categories(for: selectedType), id: \.self) { category in
                    Button {
                        editing = category; name = categories.name(for: category); showEditor = true
                    } label: {
                        HStack {
                            Text(categories.name(for: category)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("移除", role: .destructive) { categories.remove(category, type: selectedType) }
                    }
                }
                Button("添加分类") { editing = nil; name = ""; showEditor = true }
            } header: { Text("收支分类") } footer: {
                Text("点分类可改名，左滑可从预设选项中移除。改名保留分类身份和统计口径；移除不会删除历史账单，历史分类仍可在原账单中使用。分类设置保存在本机。")
            }
        }
        .navigationTitle("设置")
        .alert("备份并新建账本", isPresented: $showNewLedger) {
            TextField("新账本名称（可留空）", text: $newLedgerName)
            Button("备份并新建") { vm.startNewLedger(name: newLedgerName) }
            Button("取消", role: .cancel) {}
        } message: { Text("先完整备份当前账本，备份成功后才切换。新账本记录、收入、支出、余额均为零，旧账本可在历史备份中查看或恢复。") }
        .confirmationDialog("以本机账单重建同步文件？", isPresented: $showRebuild, titleVisibility: .visible) {
            Button("备份并重建") { sync.rebuildSyncFile() }
            Button("取消", role: .cancel) {}
        } message: { Text("原文件先备份，再写入本机账单。云端独有的记录请先人工核对或导入。") }
        .alert(editing == nil ? "添加分类" : "修改分类名称", isPresented: $showEditor) {
            TextField("分类名称", text: $name)
            Button("保存") { error = categories.save(name: name, type: selectedType, editing: editing) }
            Button("取消", role: .cancel) {}
        }
        .alert("无法保存分类", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct LedgerHistoryView: View {
    @EnvironmentObject private var vm: TransactionViewModel
    @ObservedObject private var ledgers = LedgerStore.shared

    var body: some View {
        List {
            if ledgers.backups.isEmpty { Text("暂无历史备份").foregroundStyle(.secondary) }
            ForEach(ledgers.backups) { backup in
                NavigationLink {
                    LedgerBackupDetailView(backup: backup).environmentObject(vm)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(backup.name)
                        Text(backup.createdAt.formatted(date: .numeric, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("历史备份")
    }
}

struct LedgerBackupDetailView: View {
    @EnvironmentObject private var vm: TransactionViewModel
    @ObservedObject private var sync = SyncEngine.shared
    let backup: LedgerBackup
    @State private var transactions: [Transaction] = []
    @State private var loadError: String?
    @State private var showRestore = false
    @State private var loaded = false

    private var income: Decimal { transactions.filter { $0.type == .income }.reduce(0) { $0 + $1.amount } }
    private var expense: Decimal { transactions.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount } }

    var body: some View {
        List {
            Section("备份信息") {
                Text(backup.createdAt.formatted(date: .numeric, time: .standard))
                LabeledContent("收入", value: income.formatted(.currency(code: "CNY")))
                LabeledContent("支出", value: expense.formatted(.currency(code: "CNY")))
                LabeledContent("余额", value: (income - expense).formatted(.currency(code: "CNY")))
                Text("\(transactions.count) 条账单 · 历史备份只读")
            }
            if let loadError { Section { Text(loadError).foregroundStyle(.red) } }
            if let error = vm.writeError { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("恢复为当前账本") { showRestore = true }
                    .disabled(!loaded || sync.isSyncing || vm.isImporting)
            } footer: {
                Text("恢复前会自动备份当前账本。恢复账单数据，继续沿用当前分类设置；原历史备份保留。")
            }
            Section("历史明细") {
                ForEach(transactions) { transaction in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(backup.categoryNames[transaction.category.rawValue] ?? transaction.category.rawValue)
                            Spacer()
                            Text((transaction.type == .income ? "+" : "-") + transaction.amount.formatted(.currency(code: "CNY")))
                                .foregroundStyle(transaction.type == .income ? .green : .red)
                        }
                        Text(transaction.date.formatted(date: .numeric, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if !transaction.note.isEmpty { Text(transaction.note).font(.caption) }
                    }
                }
            }
        }
        .navigationTitle(backup.name)
        .onAppear {
            do {
                transactions = try LedgerStore.shared.transactions(in: backup).filter { !$0.isDeleted && !$0.isConflict }
                loaded = true
            } catch { loadError = error.localizedDescription }
        }
        .confirmationDialog("恢复这个历史账本？", isPresented: $showRestore, titleVisibility: .visible) {
            Button("先备份当前账本并恢复") { vm.restoreLedger(backup) }
            Button("取消", role: .cancel) {}
        } message: { Text("当前账本先完整备份，再切换到恢复的历史数据。两个账本均不会被删除。") }
    }
}
