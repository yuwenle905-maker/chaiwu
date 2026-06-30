using System;

namespace ChaiWu.Windows.Models;

public enum TransactionType { 收入, 支出 }

public enum TransactionCategory { 餐饮, 交通, 购物, 娱乐, 医疗, 教育, 工资, 投资, 其他 }

public class Transaction
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTime Date { get; set; } = DateTime.Now;
    public TransactionType Type { get; set; }
    public decimal Amount { get; set; }
    public TransactionCategory Category { get; set; }
    public string Note { get; set; } = string.Empty;
    public DateTime ModifiedAt { get; set; } = DateTime.UtcNow;
    public string SourceDevice { get; set; } = Environment.MachineName;
    public bool IsConflict { get; set; }

    public decimal SignedAmount => Type == TransactionType.收入 ? Amount : -Amount;
}

public record ConflictPair(Transaction Local, Transaction Remote);
