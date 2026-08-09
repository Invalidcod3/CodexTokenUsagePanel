using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Forms = System.Windows.Forms;

namespace CodexMeter;

public partial class App : System.Windows.Application
{
    private const string MutexName = "Local\\CodexTokenMeter.App.Singleton";
    private const string ShowEventName = "Local\\CodexTokenMeter.App.Show";
    private const string DashboardEventName = "Local\\CodexTokenMeter.App.Dashboard";
    private Mutex? _mutex;
    private EventWaitHandle? _showEvent;
    private EventWaitHandle? _dashboardEvent;
    private CancellationTokenSource? _eventCancellation;
    private Forms.NotifyIcon? _tray;
    private Icon? _trayIcon;
    private BackendService? _backend;
    private MainWindow? _mainWindow;
    private FullStatsWindow? _statsWindow;
    private TrayMenuWindow? _trayMenu;
    private ImageSource? _brandImage;
    private bool _exiting;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var dashboardRequested = e.Args.Any(a => a.Equals("--dashboard", StringComparison.OrdinalIgnoreCase));
        _mutex = new Mutex(true, MutexName, out var firstInstance);
        if (!firstInstance)
        {
            SignalExisting(dashboardRequested ? DashboardEventName : ShowEventName);
            Shutdown();
            return;
        }

        try
        {
            _backend = new BackendService(AppContext.BaseDirectory, 43127);
            await _backend.EnsureStartedAsync(TimeSpan.FromSeconds(25));
            LoadBrandAssets();
            _mainWindow = new MainWindow(_backend, _brandImage);
            MainWindow = _mainWindow;
            CreateTray();
            _trayMenu = new TrayMenuWindow(
                ShowMain,
                OpenDashboard,
                () => _mainWindow?.RefreshData(),
                ExitApplication,
                _brandImage);
            StartEventListeners();
            if (dashboardRequested) OpenDashboard(); else ShowMain();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show($"Codex Meter 启动失败：\n\n{ex.Message}", "Codex Meter", MessageBoxButton.OK, MessageBoxImage.Error);
            ExitApplication();
        }
    }

    private static void SignalExisting(string name)
    {
        try { EventWaitHandle.OpenExisting(name).Set(); } catch { }
    }

    private void StartEventListeners()
    {
        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        _dashboardEvent = new EventWaitHandle(false, EventResetMode.AutoReset, DashboardEventName);
        _eventCancellation = new CancellationTokenSource();
        Listen(_showEvent, ShowMain, _eventCancellation.Token);
        Listen(_dashboardEvent, OpenDashboard, _eventCancellation.Token);
    }

    private void Listen(EventWaitHandle handle, Action action, CancellationToken token) => Task.Run(() =>
    {
        while (!token.IsCancellationRequested)
        {
            if (handle.WaitOne(500)) Dispatcher.Invoke(action);
        }
    }, token);

    private void CreateTray()
    {
        _tray = new Forms.NotifyIcon
        {
            Text = "Codex Token Meter",
            Icon = _trayIcon ?? SystemIcons.Application,
            Visible = true
        };
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) Dispatcher.Invoke(ShowMain);
            if (args.Button == Forms.MouseButtons.Right) Dispatcher.Invoke(() => _trayMenu?.ShowAtCursor());
        };
        _tray.DoubleClick += (_, _) => Dispatcher.Invoke(OpenDashboard);
    }

    private void LoadBrandAssets()
    {
        var iconPath = BrandIconResolver.FindOfficialIcon();
        if (iconPath is null) return;
        try
        {
            _trayIcon = new Icon(iconPath);
            using var icon = new Icon(iconPath, 64, 64);
            _brandImage = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(
                icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(64, 64));
            _brandImage.Freeze();
        }
        catch { }
    }

    public void ShowMain()
    {
        if (_mainWindow is null) return;
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.PositionBottomRight();
        _mainWindow.Activate();
        _mainWindow.RefreshData();
    }

    public void OpenDashboard()
    {
        if (_backend is null) return;
        if (_statsWindow is null)
        {
            _statsWindow = new FullStatsWindow(_backend.BaseUrl, _brandImage);
            _statsWindow.Closed += (_, _) => _statsWindow = null;
        }
        _statsWindow.Show();
        if (_statsWindow.WindowState == WindowState.Minimized) _statsWindow.WindowState = WindowState.Normal;
        _statsWindow.Activate();
    }

    public void ExitApplication()
    {
        if (_exiting) return;
        _exiting = true;
        _eventCancellation?.Cancel();
        _showEvent?.Dispose();
        _dashboardEvent?.Dispose();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        _trayIcon?.Dispose();
        _trayMenu?.Close();
        _statsWindow?.Close();
        _mainWindow?.ForceClose();
        _backend?.Dispose();
        try { _mutex?.ReleaseMutex(); } catch { }
        _mutex?.Dispose();
        Shutdown();
    }
}

internal static class BrandIconResolver
{
    public static string? FindOfficialIcon()
    {
        try
        {
            var where = Process.Start(new ProcessStartInfo("where.exe", "codex.exe")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                CreateNoWindow = true
            });
            var codex = where?.StandardOutput.ReadLine();
            where?.WaitForExit(1000);
            if (!string.IsNullOrWhiteSpace(codex))
            {
                var path = Path.Combine(Path.GetDirectoryName(codex)!, "icon-chatgpt.ico");
                if (File.Exists(path)) return path;
            }
        }
        catch { }

        try
        {
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps");
            return Directory.EnumerateDirectories(root, "OpenAI.Codex_*")
                .OrderByDescending(x => x)
                .Select(x => Path.Combine(x, "app", "resources", "icon-chatgpt.ico"))
                .FirstOrDefault(File.Exists);
        }
        catch { return null; }
    }
}
