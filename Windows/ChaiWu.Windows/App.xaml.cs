using System.Windows;

namespace ChaiWu.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, ex) =>
        {
            MessageBox.Show($"启动错误：{ex.Exception.Message}\n\n{ex.Exception.StackTrace}",
                            "柴务 - 错误", MessageBoxButton.OK, MessageBoxImage.Error);
            ex.Handled = true;
        };
    }
}
