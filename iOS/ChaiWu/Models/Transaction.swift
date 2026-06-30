import Foundation
import UIKit

enum TransactionType: String, Codable, CaseIterable {
    case income = "收入"
    case expense = "支出"
}

enum TransactionCategory: String, Codable, CaseIterable {
    // 收入分类
    case clientDeposit  = "客户定金"
    case clientBalance  = "客户尾款"
    case expressRefund  = "快递回款"
    // 支出分类
    case advertising    = "广告费"
    case baseSalary     = "底薪"
    case performance    = "绩效"
    case logistics      = "产品物流"
    case incentive      = "激励"
    case rent           = "房租"
    // 通用
    case custom         = "自定义"

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

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        type: TransactionType,
        amount: Decimal,
        category: TransactionCategory,
        note: String = "",
        modifiedAt: Date = Date(),
        sourceDevice: String = UIDevice.current.name,
        isConflict: Bool = false
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
    }
}

struct ConflictPair: Identifiable {
    let id = UUID()
    let local: Transaction
    let remote: Transaction
}
