using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace CodexMeter;

public partial class TrayMenuWindow : Window
{
    private readonly Action _showWidget;
    private readonly Action _showDetails;
    private readonly Action _refresh;
    private readonly Action _exit;

    public TrayMenuWindow(Action showWidget, Action showDetails, Action refresh, Action exit, ImageSource? brandImage)
    {
        InitializeComponent();
        _showWidget = showWidget;
        _showDetails = showDetails;
        _refresh = refresh;
        _exit = exit;
        BrandIcon.Source = brandImage;
        Deactivated += (_, _) => Hide();
    }

    public void ShowAtCursor()
    {
        Show();
        WindowState = WindowState.Normal;
        UpdateLayout();

        var cursor = Forms.Cursor.Position;
        var screen = Forms.Screen.FromPoint(cursor);
        var source = PresentationSource.FromVisual(this);
        var transform = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var cursorDip = transform.Transform(new System.Windows.Point(cursor.X, cursor.Y));
        var workTopLeft = transform.Transform(new System.Windows.Point(screen.WorkingArea.Left, screen.WorkingArea.Top));
        var workBottomRight = transform.Transform(new System.Windows.Point(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
        Left = Math.Clamp(cursorDip.X - ActualWidth + 12, workTopLeft.X + 6, workBottomRight.X - ActualWidth - 6);
        Top = Math.Clamp(cursorDip.Y - ActualHeight + 8, workTopLeft.Y + 6, workBottomRight.Y - ActualHeight - 6);
        Activate();
        Focus();
    }

    private void Run(Action action)
    {
        Hide();
        action();
    }

    private void ShowWidget_Click(object sender, RoutedEventArgs e) => Run(_showWidget);
    private void ShowDetails_Click(object sender, RoutedEventArgs e) => Run(_showDetails);
    private void Refresh_Click(object sender, RoutedEventArgs e) => Run(_refresh);
    private void Exit_Click(object sender, RoutedEventArgs e) => Run(_exit);
    private void Window_KeyDown(object sender, System.Windows.Input.KeyEventArgs e) { if (e.Key == Key.Escape) Hide(); }
}
