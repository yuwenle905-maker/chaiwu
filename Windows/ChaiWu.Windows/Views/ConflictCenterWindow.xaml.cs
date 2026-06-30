using ChaiWu.Windows.Models;
using ChaiWu.Windows.ViewModels;
using System.Windows;
using System.Windows.Controls;

namespace ChaiWu.Windows.Views;

public partial class ConflictCenterWindow : Window
{
    private readonly MainViewModel _vm;

    public ConflictCenterWindow(MainViewModel vm)
    {
        InitializeComponent();
        _vm = vm;
        RefreshList();
    }

    private void RefreshList()
    {
        // 简单两两配对：按顺序每两条冲突记录为一对
        var conflicts = _vm.Conflicts;
        var pairs = new System.Collections.Generic.List<ConflictPair>();
        for (int i = 0; i + 1 < conflicts.Count; i += 2)
            pairs.Add(new ConflictPair(conflicts[i], conflicts[i + 1]));
        ConflictList.ItemsSource = pairs;
    }

    private void KeepLocal_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is ConflictPair pair)
        {
            _vm.ResolveConflictCommand.Execute((pair.Local, pair.Remote));
            RefreshList();
        }
    }

    private void KeepRemote_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is ConflictPair pair)
        {
            _vm.ResolveConflictCommand.Execute((pair.Remote, pair.Local));
            RefreshList();
        }
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();
}
