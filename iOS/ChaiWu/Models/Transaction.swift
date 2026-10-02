import Foundation
import UIKit

enum TransactionType: String, Codable, CaseIterable {
    case income = "收入"
    case expense = "支出"
}

struct TransactionCategory: RawRepresentable, Codable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let category = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "分类不能为空")
        }
        self = category
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    // 收入分类
    static let clientDeposit = Self(rawValue: "客户定金")!
    static let clientBalance = Self(rawValue: "客户尾款")!
    static let expressRefund = Self(rawValue: "快递回款")!
    // 支出分类
    static let advertising = Self(rawValue: "广告费")!
    static let baseSalary = Self(rawValue: "底薪")!
    static let performance = Self(rawValue: "绩效")!
    static let logistics = Self(rawValue: "产品物流")!
    static let incentive = Self(rawValue: "激励")!
    static let rent = Self(rawValue: "房租")!
    // 通用
    static let custom = Self(rawValue: "自定义")!

    static func categories(for type: TransactionType) -> [TransactionCategory] {
        switch type {
        case .income:  return [.clientDeposit, .clientBalance, .expressRefund, .custom]
        case .expense: return [.advertising, .baseSalary, .performance, .logistics, .incentive, .rent, .custom]
        }
    }
}

struct Transaction: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var type: TransactionType
    var amount: Decimal
    var category: TransactionCategory
    var note: String
    var modifiedAt: Date
    var sourceDevice: String
    var isConflict: Bool
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        type: TransactionType,
        amount: Decimal,
        category: TransactionCategory,
        note: String = "",
        modifiedAt: Date = Date(),
        sourceDevice: String = UIDevice.current.name,
        isConflict: Bool = false,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.date = date
        self.type = type
        self.amount = amount
        self.category = category
        self.note = note
        self.modifiedAt = modifiedAt
        self.sourceDevice = sourceDevice
        self.isConflict = isConflict
        self.isDeleted = isDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, type, amount, category, note, modifiedAt, sourceDevice, isConflict, isDeleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        type = try c.decode(TransactionType.self, forKey: .type)
        amount = try c.decode(Decimal.self, forKey: .amount)
        category = try c.decode(TransactionCategory.self, forKey: .category)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        sourceDevice = try c.decodeIfPresent(String.self, forKey: .sourceDevice) ?? ""
        isConflict = try c.decodeIfPresent(Bool.self, forKey: .isConflict) ?? false
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }
}

struct ConflictPair: Identifiable {
    let id = UUID()
    let local: Transaction
    let remote: Transaction
}

struct DailyTransactionGroup: Identifiable {
    let id: Date
    let transactions: [Transaction]
    var incomeCount: Int { transactions.filter { $0.type == .income }.count }
    var expenseCount: Int { transactions.filter { $0.type == .expense }.count }
    var income: Decimal { transactions.filter { $0.type == .income }.reduce(0) { $0 + $1.amount } }
    var expense: Decimal { transactions.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount } }

    static func groups(from transactions: [Transaction], month: Date, filter: TransactionType? = nil,
                       calendar: Calendar = .current) -> [DailyTransactionGroup] {
        let items = transactions.filter {
            !$0.isDeleted && !$0.isConflict && calendar.isDate($0.date, equalTo: month, toGranularity: .month)
                && (filter == nil || $0.type == filter)
        }
        return Dictionary(grouping: items, by: { calendar.startOfDay(for: $0.date) }).map { day, entries in
            Self(id: day, transactions: entries.sorted {
                $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
            })
        }.sorted { $0.id < $1.id }
    }
}
