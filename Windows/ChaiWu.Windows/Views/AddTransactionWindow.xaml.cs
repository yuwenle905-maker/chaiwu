using ChaiWu.Windows.Models;
using System;
using System.Windows;

namespace ChaiWu.Windows.Views;

public partial class AddTransactionWindow : Window
{
    public Transaction? Result { get; private set; }

    public AddTransactionWindow()
    {
        InitializeComponent();
        DpDate.SelectedDate = DateTime.Today;
        foreach (var c in Enum.GetNames<TransactionCategory>())
            CbCategory.Items.Add(c);
        CbCategory.SelectedIndex = 0;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (!decimal.TryParse(TbAmount.Text, out var amount) || amount <= 0)
        {
            MessageBox.Show("请输入有效金额", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        Result = new Transaction
        {
            Type = RbIncome.IsChecked == true ? TransactionType.收入 : TransactionType.支出,
            Amount = amount,
            Category = Enum.Parse<TransactionCategory>(CbCategory.SelectedItem?.ToString() ?? "其他"),
            Note = TbNote.Text,
            Date = DpDate.SelectedDate ?? DateTime.Today,
            ModifiedAt = DateTime.UtcNow
        };
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
