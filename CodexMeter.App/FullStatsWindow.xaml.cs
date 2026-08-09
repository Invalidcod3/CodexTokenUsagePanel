using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;

namespace CodexMeter;

public partial class FullStatsWindow : Window
{
    private readonly Uri _dashboardUri;

    public FullStatsWindow(string baseUrl, ImageSource? brandImage)
    {
        InitializeComponent();
        Icon = brandImage;
        BrandIcon.Source = brandImage;
        _dashboardUri = new Uri(baseUrl);
        Loaded += FullStatsWindow_Loaded;
        StateChanged += (_, _) => UpdateWindowState();
    }

    private async void FullStatsWindow_Loaded(object sender, RoutedEventArgs e)
    {
        Loaded -= FullStatsWindow_Loaded;
        try
        {
            await Browser.EnsureCoreWebView2Async();
            Browser.CoreWebView2.Settings.AreDevToolsEnabled = false;
            Browser.CoreWebView2.Settings.IsStatusBarEnabled = false;
            Browser.CoreWebView2.NewWindowRequested += (_, args) =>
            {
                args.Handled = true;
                Browser.CoreWebView2.Navigate(args.Uri);
            };
            Browser.Source = _dashboardUri;
        }
        catch (Exception ex)
        {
            StatusText.Text = $"无法载入统计页面：{ex.Message}";
            System.Windows.MessageBox.Show(
                $"完整统计窗口需要 Microsoft Edge WebView2 Runtime。\n\n{ex.Message}",
                "Codex Meter", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void Browser_NavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        => StatusText.Text = e.IsSuccess ? "账户总账 · 设备归因 · JSON 导出" : $"页面载入失败：{e.WebErrorStatus}";

    private void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        if (Browser.CoreWebView2 is not null) Browser.Reload();
        else Browser.Source = _dashboardUri;
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (e.ClickCount == 2) { ToggleMaximize(); return; }
        if (WindowState == WindowState.Maximized) WindowState = WindowState.Normal;
        DragMove();
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void MaximizeButton_Click(object sender, RoutedEventArgs e) => ToggleMaximize();
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void ToggleMaximize()
        => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void UpdateWindowState()
    {
        var maximized = WindowState == WindowState.Maximized;
        WindowFrame.CornerRadius = new CornerRadius(maximized ? 0 : 12);
        MaximizeButton.Content = maximized ? "❐" : "□";
        MaximizeButton.ToolTip = maximized ? "还原" : "最大化";
    }
}
