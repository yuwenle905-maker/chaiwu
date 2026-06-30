import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - UIDocumentPickerViewController 包装（绕过 SwiftUI 多 sheet bug）

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.data, .item]
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - DashboardView

struct DashboardView: View {
    @EnvironmentObject var vm: TransactionViewModel
    @EnvironmentObject var sync: SyncEngine
    @State private var showEntry = false
    @State private var editingTransaction: Transaction?
    @State private var showConflict = false
    @State private var showImportPicker = false
    @State private var selectedFilter: TransactionType? = nil

    var filteredTransactions: [Transaction] {
        guard let f = selectedFilter else { return vm.transactions }
        return vm.transactions.filter { $0.type == f }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if vm.conflictCount > 0 { conflictBanner }
                    if let msg = vm.importSuccess { importSuccessBanner(msg) }
                    if let err = vm.importError   { importErrorBanner(err) }

                    summaryCards
                    filterBar
                    transactionList
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("账单")
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
                    Menu {
                        Button(action: { showImportPicker = true }) {
                            Label("导入表格", systemImage: "square.and.arrow.down")
                        }
                        Button(action: { sync.performSync() }) {
                            Label("手动同步", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            // 把所有 sheet 合并成一个，避免多 sheet 互斥导致 fileImporter 回调失效
            .sheet(isPresented: $showEntry) {
                EntryView().environmentObject(vm)
            }
            .sheet(item: $editingTransaction) { t in
                EntryView(editing: t).environmentObject(vm)
            }
            .sheet(isPresented: $showConflict) {
                ConflictCenterView().environmentObject(vm)
            }
            // 用 UIDocumentPickerViewController 替代 .fileImporter，避免 SwiftUI 多 sheet bug
            .sheet(isPresented: $showImportPicker) {
                DocumentPicker { url in
                    showImportPicker = false
                    vm.importXlsx(from: url)
                }
            }
        }
    }

    // MARK: - 子视图

    private var conflictBanner: some View {
        Button(action: { showConflict = true }) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                Text("检测到 \(vm.conflictCount) 条数据冲突，点击处理")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.8))
            }
            .padding(14)
            .background(Color.red.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func importSuccessBanner(_ msg: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(msg).font(.subheadline).foregroundStyle(.green)
            Spacer()
            Button("×") { vm.importSuccess = nil }.foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func importErrorBanner(_ err: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(err).font(.subheadline).foregroundStyle(.red)
            Spacer()
            Button("×") { vm.importError = nil }.foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var summaryCards: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("当前余额").font(.subheadline).foregroundStyle(.secondary)
                Text(vm.totalBalance.formatted(.currency(code: "CNY")))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(vm.totalBalance >= 0 ? Color.primary : Color.red)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)

            HStack(spacing: 12) {
                SummaryMiniCard(title: "累计收入", amount: vm.totalIncome,  color: .green)
                SummaryMiniCard(title: "累计支出", amount: vm.totalExpense, color: .red)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterChip(label: "全部",   selected: selectedFilter == nil)      { selectedFilter = nil }
            FilterChip(label: "收入",   selected: selectedFilter == .income)  { selectedFilter = .income }
            FilterChip(label: "支出",   selected: selectedFilter == .expense) { selectedFilter = .expense }
            Spacer()
            Text("\(filteredTransactions.count) 条").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var transactionList: some View {
        LazyVStack(spacing: 8) {
            ForEach(filteredTransactions) { t in
                TransactionRow(transaction: t)
                    .onTapGesture { editingTransaction = t }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { vm.delete(t) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button { editingTransaction = t } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .padding(.bottom, 32)
    }
}

// MARK: - 组件

struct SummaryMiniCard: View {
    let title: String; let amount: Decimal; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color.opacity(0.15)).frame(width: 28, height: 28)
                    .overlay(Image(systemName: title == "累计收入" ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(color).font(.system(size: 14)))
                Text(title).font(.caption).foregroundStyle(.secondary)
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
    let label: String; let selected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(selected ? Color.blue : Color(.systemFill))
                .foregroundStyle(selected ? .white : Color.primary)
                .clipShape(Capsule())
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 1) {
                Text(Self.dateFmt.string(from: transaction.date))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.category.rawValue)
                    .font(.subheadline.weight(.medium))
                if !transaction.note.isEmpty {
                    Text(transaction.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text((transaction.type == .income ? "+" : "-") +
                 transaction.amount.formatted(.currency(code: "CNY")))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(transaction.type == .income ? Color.green : Color.red)
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
