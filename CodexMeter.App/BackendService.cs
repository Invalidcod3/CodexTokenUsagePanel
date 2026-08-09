using System.Diagnostics;
using System.IO;
using System.Net.Http;

namespace CodexMeter;

public sealed class BackendService : IDisposable
{
    private readonly string _baseDirectory;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(40) };
    private Process? _ownedProcess;
    public string BaseUrl { get; }

    public BackendService(string baseDirectory, int port)
    {
        _baseDirectory = baseDirectory;
        BaseUrl = $"http://127.0.0.1:{port}/";
    }

    public async Task EnsureStartedAsync(TimeSpan timeout)
    {
        if (await IsHealthyAsync()) return;
        if (await IsPortOpenAsync())
            throw new InvalidOperationException($"端口 {new Uri(BaseUrl).Port} 已被其他程序占用，请先关闭占用程序。");

        var script = Path.Combine(_baseDirectory, "Start-CodexMeter.ps1");
        if (!File.Exists(script)) throw new FileNotFoundException("应用目录缺少 Start-CodexMeter.ps1。", script);

        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        _ownedProcess = Process.Start(new ProcessStartInfo
        {
            FileName = powershell,
            Arguments = $"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{script}\" -Port {new Uri(BaseUrl).Port} -NoBrowser",
            WorkingDirectory = _baseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        });

        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (_ownedProcess?.HasExited == true)
                throw new InvalidOperationException($"统计服务启动后立即退出，代码 {_ownedProcess.ExitCode}。");
            if (await IsHealthyAsync()) return;
            await Task.Delay(250);
        }
        throw new TimeoutException("统计服务未能在规定时间内启动。");
    }

    public Task<string> GetUsageJsonAsync() => _http.GetStringAsync(BaseUrl + "api/usage");

    private async Task<bool> IsHealthyAsync()
    {
        try { return (await _http.GetStringAsync(BaseUrl + "api/health")).Contains("codex-token-meter"); }
        catch { return false; }
    }

    private async Task<bool> IsPortOpenAsync()
    {
        try
        {
            using var client = new System.Net.Sockets.TcpClient();
            await client.ConnectAsync("127.0.0.1", new Uri(BaseUrl).Port).WaitAsync(TimeSpan.FromMilliseconds(500));
            return client.Connected;
        }
        catch { return false; }
    }

    public void Dispose()
    {
        _http.Dispose();
        try { if (_ownedProcess is { HasExited: false }) _ownedProcess.Kill(true); } catch { }
        _ownedProcess?.Dispose();
    }
}
