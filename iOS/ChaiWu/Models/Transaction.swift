import Foundation
import UIKit

enum TransactionType: String, Codable, CaseIterable {
    case income = "收入"
    case expense = "支出"
}

enum TransactionCategory: String, Codable, CaseIterable {
    case food = "餐饮"
    case transport = "交通"
    case shopping = "购物"
    case entertainment = "娱乐"
    case health = "医疗"
    case education = "教育"
    case salary = "工资"
    case investment = "投资"
    case other = "其他"
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
