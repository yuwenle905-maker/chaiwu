using ChaiWu.Windows.Models;
using ChaiWu.Windows.Services;
using ChaiWu.Windows.Views;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;

namespace ChaiWu.Windows.ViewModels;

public partial class MainViewModel : ObservableObject
{
    [ObservableProperty] private ObservableCollection<Transaction> _transactions = [];
    [ObservableProperty] private ObservableCollection<Transaction> _conflicts = [];
    [ObservableProperty] private bool _isSyncing;
    [ObservableProperty] private string _syncStatus = "已同步";
    [ObservableProperty] private decimal _totalBalance;
    [ObservableProperty] private decimal _totalIncome;
    [ObservableProperty] private decimal _totalExpense;
    [ObservableProperty] private TransactionType? _filterType;

    private readonly DatabaseService _db = DatabaseService.Instance;
    private readonly SyncService _sync = SyncService.Instance;

    public bool HasConflicts => Conflicts.Count > 0;

    public MainViewModel()
    {
        _sync.SyncCompleted += () => App.Current.Dispatcher.Invoke(Reload);
        _sync.ConflictsDetected += pairs => App.Current.Dispatcher.Invoke(() =>
        {
            SyncStatus = $"⚠ 检测到 {pairs.Count} 条冲突，请处理";
        });
        _sync.SyncError += err => App.Current.Dispatcher.Invoke(() =>
        {
            SyncStatus = $"同步失败: {err}";
            IsSyncing = false;
        });

        Reload();
        _sync.StartWatching();
    }

    public void Reload()
    {
        var all = _db.FetchAll();
        Transactions = new ObservableCollection<Transaction>(
            all.Where(t => !t.IsConflict && (FilterType == null || t.Type == FilterType))
               .OrderByDescending(t => t.Date));
        Conflicts = new ObservableCollection<Transaction>(all.Where(t => t.IsConflict));

        TotalIncome  = Transactions.Where(t => t.Type == TransactionType.收入).Sum(t => t.Amount);
        TotalExpense = Transactions.Where(t => t.Type == TransactionType.支出).Sum(t => t.Amount);
        TotalBalance = TotalIncome - TotalExpense;

        OnPropertyChanged(nameof(HasConflicts));
    }

    private async Task AddTransactionAsync(Transaction t)
    {
        _db.Upsert(t);
        Reload();
        await Task.Run(_sync.PerformSync);
    }

    [RelayCommand]
    private async Task AddTransaction(Transaction t)
    {
        _db.Upsert(t);
        Reload();
        await Task.Run(_sync.PerformSync);
    }

    [RelayCommand]
    private async Task DeleteTransaction(Transaction t)
    {
        _db.Delete(t.Id);
        Reload();
        await Task.Run(_sync.PerformSync);
    }

    [RelayCommand]
    private async Task ResolveConflict((Transaction keep, Transaction discard) pair)
    {
        _db.ResolveConflict(pair.keep.Id, pair.discard.Id);
        Reload();
        await Task.Run(_sync.PerformSync);
    }

    [RelayCommand]
    private void ShowAddDialog()
    {
        var win = new AddTransactionWindow { Owner = Application.Current.MainWindow };
        if (win.ShowDialog() == true && win.Result != null)
            _ = AddTransactionAsync(win.Result);
    }

    [RelayCommand]
    private void OpenConflictCenter()
    {
        var win = new ConflictCenterWindow(this) { Owner = Application.Current.MainWindow };
        win.ShowDialog();
    }

    [RelayCommand]
    private async Task ManualSync()
    {
        IsSyncing = true;
        SyncStatus = "同步中...";
        await Task.Run(_sync.PerformSync);
        IsSyncing = false;
        SyncStatus = $"已同步 · {DateTime.Now:HH:mm}";
    }

    partial void OnFilterTypeChanged(TransactionType? value) => Reload();
}
