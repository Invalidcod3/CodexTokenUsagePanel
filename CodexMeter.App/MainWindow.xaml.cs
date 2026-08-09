using System.ComponentModel;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace CodexMeter;

public partial class MainWindow : Window
{
    private readonly BackendService _backend;
    private JsonElement? _data;
    private bool _refreshing;
    private bool _allowClose;
    private bool _periodReady;
    private List<PeriodOption> _periods = [];
    private readonly DispatcherTimer _refreshTimer;
    private readonly DispatcherTimer _countdownTimer;
    private DateOnly _periodAnchor;
    private DateTimeOffset _nextRefreshAt = DateTimeOffset.MinValue;
    private string _statusBase = "尚未刷新";
    private bool _lastRefreshFailed;
    private bool _metricAnimationReady;
    private readonly Dictionary<TextBlock, string> _metricValues = [];
    private readonly Dictionary<TextBlock, int> _metricAnimationVersions = [];
    private SolidColorBrush _accentBrush = new(System.Windows.Media.Color.FromRgb(184, 255, 52));
    private SolidColorBrush _accentForegroundBrush = new(System.Windows.Media.Color.FromRgb(10, 13, 11));

    public MainWindow(BackendService backend, ImageSource? brandImage)
    {
        InitializeComponent();
        _backend = backend;
        BrandIcon.Source = brandImage;
        PopulatePeriods();
        _refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        _refreshTimer.Tick += (_, _) => { if (IsVisible) RefreshData(); };
        _refreshTimer.Start();
        _countdownTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        _countdownTimer.Tick += (_, _) => UpdateCountdownStatus();
        Loaded += (_, _) =>
        {
            PositionBottomRight();
            RefreshData();
        };
        StateChanged += (_, _) =>
        {
            if (WindowState != WindowState.Minimized) return;
            Hide();
            WindowState = WindowState.Normal;
        };
    }

    private void PopulatePeriods()
    {
        var selectedKey = (PeriodPicker.SelectedItem as PeriodOption)?.Key ?? "all";
        _periodReady = false;
        var today = DateOnly.FromDateTime(DateTime.Today);
        _periodAnchor = today;
        var yesterday = today.AddDays(-1);
        var monthStart = new DateOnly(today.Year, today.Month, 1);
        var previousEnd = monthStart.AddDays(-1);
        var previousStart = new DateOnly(previousEnd.Year, previousEnd.Month, 1);
        _periods =
        [
            new("all", "累计", null, null),
            NewPeriod("today", "今日", today, today),
            NewPeriod("yesterday", "昨日", yesterday, yesterday),
            NewPeriod("7days", "7 日", today.AddDays(-6), today),
            NewPeriod("30days", "30 日", today.AddDays(-29), today),
            NewPeriod("month", "本月", monthStart, today),
            NewPeriod("previous-month", "上月", previousStart, previousEnd)
        ];
        PeriodPicker.DisplayMemberPath = nameof(PeriodOption.Display);
        PeriodPicker.ItemsSource = _periods;
        PeriodPicker.SelectedItem = _periods.FirstOrDefault(item => item.Key == selectedKey) ?? _periods[0];
        _periodReady = true;
    }

    private static PeriodOption NewPeriod(string key, string name, DateOnly start, DateOnly end)
    {
        var range = FormatRange(start, end);
        return new PeriodOption(key, $"{name} · {range}", start, end);
    }

    private static string FormatRange(DateOnly start, DateOnly end)
    {
        if (start == end) return start.ToString("MM/dd", CultureInfo.InvariantCulture);
        if (start.Year == end.Year)
            return $"{start:MM/dd}–{end:MM/dd}";
        return $"{start:yyyy/MM/dd}–{end:yyyy/MM/dd}";
    }

    public async void RefreshData()
    {
        if (_refreshing) return;
        if (_periodAnchor != DateOnly.FromDateTime(DateTime.Today)) PopulatePeriods();
        _refreshing = true;
        _refreshTimer.Stop();
        _countdownTimer.Stop();
        _nextRefreshAt = DateTimeOffset.MinValue;
        StatusText.Text = "正在刷新账户与本机日志…";
        try
        {
            using var document = JsonDocument.Parse(await _backend.GetUsageJsonAsync());
            _data = document.RootElement.Clone();
            UpdateRefreshInterval(_data.Value);
            UpdateTheme(_data.Value);
            _lastRefreshFailed = false;
            Render();
        }
        catch (Exception ex)
        {
            _lastRefreshFailed = true;
            _statusBase = $"刷新失败：{ex.Message}";
            StatusText.Text = _statusBase;
            AccountState.Text = "暂时无法读取数据";
        }
        finally
        {
            _refreshing = false;
            _nextRefreshAt = DateTimeOffset.Now + _refreshTimer.Interval;
            UpdateCountdownStatus();
            _countdownTimer.Start();
            _refreshTimer.Start();
        }
    }

    private void Render()
    {
        if (_data is not JsonElement root) return;
        var period = PeriodPicker.SelectedItem as PeriodOption ?? _periods[0];
        var sessions = new List<JsonElement>();
        var usage = new UsageCounter();
        var comparableUsage = new UsageCounter();
        var models = new Dictionary<string, UsageCounter>(StringComparer.OrdinalIgnoreCase);
        var comparableModels = new Dictionary<string, UsageCounter>(StringComparer.OrdinalIgnoreCase);

        foreach (var session in GetItems(root, "sessions"))
        {
            var comparable = IsComparable(session);
            if (period.Key == "all")
            {
                sessions.Add(session);
                AddUsageContainer(session, comparable);
                continue;
            }

            var dailyRows = GetItems(session, "dailyUsage").ToList();
            if (dailyRows.Count > 0)
            {
                var matchingRows = dailyRows.Where(row => IsDailyRowInPeriod(row, period)).ToList();
                if (matchingRows.Count == 0) continue;
                sessions.Add(session);
                foreach (var row in matchingRows) AddUsageContainer(row, comparable);
            }
            else if (IsInPeriod(session, period))
            {
                sessions.Add(session);
                AddUsageContainer(session, comparable);
            }
        }

        void AddUsageContainer(JsonElement container, bool comparable)
        {
            if (TryGet(container, "usage", out var rowUsage)) usage.Add(rowUsage);
            AddModels(container, models);
            if (!comparable) return;
            if (TryGet(container, "usage", out rowUsage)) comparableUsage.Add(rowUsage);
            AddModels(container, comparableModels);
        }

        var accountAvailable = TryGet(root, "account", out var account)
            && GetBool(account, "available");
        var accountTotal = accountAvailable ? AccountTokens(account, period) : 0;
        var accountHasPeriod = accountAvailable && AccountHasPeriodData(account, period);
        var unattributed = accountAvailable && accountHasPeriod ? Math.Max(0, accountTotal - comparableUsage.TotalTokens) : 0;
        var coverage = accountAvailable && accountHasPeriod && accountTotal > 0
            ? Math.Min(100, comparableUsage.TotalTokens * 100d / accountTotal)
            : (double?)null;

        var localPeriodFallback = period.Key != "all" && !accountHasPeriod;
        AccountScopeLabel.Text = period.Key == "all"
            ? "CHATGPT ACCOUNT · LIFETIME"
            : localPeriodFallback ? $"LOCAL CONFIRMED · {ScopeRange(period)}" : $"CHATGPT ACCOUNT · {ScopeRange(period)}";
        SetRollingMetric(AccountTotal, accountAvailable && accountHasPeriod
            ? FormatCompact(accountTotal, 2)
            : localPeriodFallback ? FormatCompact(comparableUsage.TotalTokens, 2) : "不可用");
        AccountState.Text = accountAvailable
            ? period.Key == "all"
                ? "账户总账已同步 · 输入输出拆分来自设备日志"
                : accountHasPeriod ? "账户日用量已同步 · 当前所选时间段" : "账户日桶尚未返回 · 当前显示本机实时明细"
            : localPeriodFallback ? "账户接口暂不可用 · 当前显示本机实时明细" : GetAccountError(root);
        SetRollingMetric(Attributed, FormatCompact(comparableUsage.TotalTokens, 1));
        SetRollingMetric(Unattributed, accountAvailable && accountHasPeriod ? FormatCompact(unattributed, 1) : "—");
        SetRollingMetric(Coverage, coverage is null ? "—" : $"{coverage:0.0}%");

        SetRollingMetric(InputTokens, FormatCompact(usage.InputTokens, 1));
        SetRollingMetric(OutputTokens, FormatCompact(usage.OutputTokens, 1));
        SetRollingMetric(CachedTokens, FormatCompact(usage.CachedInputTokens, 1));
        SetRollingMetric(ReasoningTokens, FormatCompact(usage.ReasoningOutputTokens, 1));
        LocalMeta.Text = $"{sessions.Count} 个任务 · {usage.Requests:N0} 次请求";

        var localCost = Cost(models);
        var comparableCost = Cost(comparableModels);
        var projectedCost = accountAvailable && accountHasPeriod && comparableUsage.TotalTokens > 0
            ? comparableCost * accountTotal / comparableUsage.TotalTokens
            : (double?)null;
        SetRollingMetric(LocalCost, $"${localCost:N2}");
        SetRollingMetric(ProjectedCost, projectedCost is null ? "外推 —" : $"外推 ${projectedCost:N2}");

        RenderModels(models, usage.TotalTokens);
        RenderLimits(root);
        SetQuickButtons(period.Key);
        var generated = GetString(root, "generatedAt");
        _statusBase = DateTimeOffset.TryParse(generated, out var generatedAt)
            ? $"更新于 {generatedAt.ToLocalTime():MM-dd HH:mm:ss} · {period.Display}"
            : $"已更新 · {period.Display}";
        StatusText.Text = _statusBase;
        _metricAnimationReady = true;
        UpdateCountdownStatus();
    }

    private void UpdateCountdownStatus()
    {
        if (_refreshing || _nextRefreshAt == DateTimeOffset.MinValue) return;
        var remaining = Math.Max(0, (_nextRefreshAt - DateTimeOffset.Now).TotalSeconds);
        var countdown = remaining < 10
            ? remaining.ToString("0.0", CultureInfo.InvariantCulture)
            : Math.Ceiling(remaining).ToString("0", CultureInfo.InvariantCulture);
        StatusText.Text = _lastRefreshFailed
            ? $"{_statusBase} · {countdown} 秒后重试"
            : $"{_statusBase} · {countdown} 秒后刷新";
    }

    private void UpdateRefreshInterval(JsonElement root)
    {
        if (!TryGet(root, "settings", out var settings)) return;
        var seconds = GetDouble(settings, "refreshIntervalSeconds");
        if (seconds <= 0) return;
        _refreshTimer.Interval = TimeSpan.FromSeconds(Math.Clamp(seconds, 0.5, 3600));
    }

    private void UpdateTheme(JsonElement root)
    {
        if (!TryGet(root, "settings", out var settings)) return;
        System.Windows.Media.Color ParseColor(string name, string fallback)
        {
            var value = GetString(settings, name);
            var source = string.IsNullOrWhiteSpace(value) ? fallback : value;
            return System.Windows.Media.ColorConverter.ConvertFromString(source) is System.Windows.Media.Color parsed
                ? parsed
                : (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(fallback)!;
        }

        System.Windows.Media.Color accent, background, panel, text, muted, secondary;
        try
        {
            accent = ParseColor("themeAccent", "#B8FF34");
            background = ParseColor("themeBackground", "#090B0D");
            panel = ParseColor("themePanel", "#131619");
            text = ParseColor("themeText", "#F3F6F4");
            muted = ParseColor("themeMuted", "#8A9290");
            secondary = ParseColor("themeSecondary", "#9D84EF");
        }
        catch { return; }

        _accentBrush = new SolidColorBrush(accent);
        var textBrush = new SolidColorBrush(text);
        var mutedBrush = new SolidColorBrush(muted);
        var panelBrush = new SolidColorBrush(panel);
        var secondaryBrush = new SolidColorBrush(secondary);
        var luminance = (0.2126 * accent.R + 0.7152 * accent.G + 0.0722 * accent.B) / 255d;
        _accentForegroundBrush = new SolidColorBrush(luminance > .52
            ? System.Windows.Media.Color.FromRgb(10, 13, 11)
            : System.Windows.Media.Color.FromRgb(245, 248, 246));
        Foreground = textBrush;
        RootSurface.Background = new SolidColorBrush(background);
        RootSurface.BorderBrush = new SolidColorBrush(MixColor(background, accent, .24));
        AccountCard.Background = panelBrush;
        AccountCard.BorderBrush = new SolidColorBrush(MixColor(panel, accent, .30));
        AccountScopeLabel.Foreground = mutedBrush;
        LocalMeta.Foreground = mutedBrush;
        StatusText.Foreground = mutedBrush;
        TopModels.Foreground = textBrush;
        ProjectedCost.Foreground = mutedBrush;
        PeriodPicker.Background = panelBrush;
        PeriodPicker.Foreground = textBrush;
        PeriodPicker.BorderBrush = new SolidColorBrush(MixColor(panel, text, .18));
        AccountState.Foreground = _accentBrush;
        CachedTokens.Foreground = _accentBrush;
        LocalCost.Foreground = _accentBrush;
        PrimaryLimitBar.Foreground = _accentBrush;
        SecondaryLimitBar.Foreground = secondaryBrush;
        DashboardOpenButton.Background = _accentBrush;
        DashboardOpenButton.Foreground = _accentForegroundBrush;
    }

    private static System.Windows.Media.Color MixColor(System.Windows.Media.Color first, System.Windows.Media.Color second, double amount)
    {
        byte Mix(byte a, byte b) => (byte)Math.Round(a + (b - a) * amount);
        return System.Windows.Media.Color.FromRgb(Mix(first.R, second.R), Mix(first.G, second.G), Mix(first.B, second.B));
    }

    private void SetRollingMetric(TextBlock target, string value)
    {
        var version = _metricAnimationVersions.GetValueOrDefault(target) + 1;
        _metricAnimationVersions[target] = version;
        _metricValues.TryGetValue(target, out var previous);
        _metricValues[target] = value;
        target.TextEffects?.Clear();
        if (!_metricAnimationReady || previous is null || previous == value || !Regex.IsMatch(previous, "\\d") || !Regex.IsMatch(value, "\\d"))
        {
            target.Text = value;
            return;
        }

        var oldDigits = previous.Where(char.IsDigit).ToArray();
        var newDigitCount = value.Count(char.IsDigit);
        var digitIndex = 0;
        var oldNumber = ParseDisplayNumber(previous);
        var newNumber = ParseDisplayNumber(value);
        var rollsUp = oldNumber is null || newNumber is null || newNumber >= oldNumber;
        target.Text = value;
        target.TextEffects = new TextEffectCollection();

        for (var characterIndex = 0; characterIndex < value.Length; characterIndex++)
        {
            var character = value[characterIndex];
            if (!char.IsDigit(character)) continue;

            var digitsFromRight = newDigitCount - digitIndex - 1;
            var oldIndex = oldDigits.Length - digitsFromRight - 1;
            var oldDigit = oldIndex >= 0 ? oldDigits[oldIndex] : '\0';
            digitIndex++;
            if (oldDigit == '\0' || oldDigit == character) continue;

            var transform = new TranslateTransform();
            target.TextEffects.Add(new TextEffect
            {
                PositionStart = characterIndex,
                PositionCount = 1,
                Transform = transform
            });
            var animation = new DoubleAnimation
            {
                From = rollsUp ? target.FontSize * 0.42 : target.FontSize * -0.42,
                To = 0,
                Duration = TimeSpan.FromMilliseconds(480),
                BeginTime = TimeSpan.FromMilliseconds(Math.Min(150, digitsFromRight * 22)),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                FillBehavior = FillBehavior.Stop
            };
            transform.BeginAnimation(TranslateTransform.YProperty, animation);
        }
        _ = FinalizeRollingMetricAsync(target, value, version);
    }

    private async Task FinalizeRollingMetricAsync(TextBlock target, string value, int version)
    {
        await Task.Delay(760);
        if (!_metricAnimationVersions.TryGetValue(target, out var currentVersion) || currentVersion != version) return;
        if (!_metricValues.TryGetValue(target, out var currentValue) || currentValue != value) return;
        target.TextEffects?.Clear();
        target.Text = value;
    }

    private static double? ParseDisplayNumber(string value)
    {
        var cleaned = Regex.Replace(value, "[^0-9.\\-]", string.Empty);
        if (!double.TryParse(cleaned, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)) return null;
        var suffix = Regex.Match(value, "([KMB])\\b", RegexOptions.IgnoreCase).Groups[1].Value.ToUpperInvariant();
        return number * (suffix switch { "K" => 1e3, "M" => 1e6, "B" => 1e9, _ => 1 });
    }

    private static string ScopeRange(PeriodOption period)
    {
        if (period.Start is null || period.End is null) return "LIFETIME";
        var start = period.Start.Value;
        var end = period.End.Value;
        if (start == end) return start.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        return start.Year == end.Year
            ? $"{start:MM-dd} — {end:MM-dd}"
            : $"{start:yyyy-MM-dd} — {end:yyyy-MM-dd}";
    }

    private static long AccountTokens(JsonElement account, PeriodOption period)
    {
        if (period.Key == "all")
        {
            var live = GetLong(account, "liveLifetimeTokens");
            if (live > 0) return live;
            if (TryGet(account, "summary", out var summary)) return GetLong(summary, "lifetimeTokens");
        }

        long total = 0;
        foreach (var bucket in GetItems(account, "dailyUsageBuckets"))
        {
            if (!DateOnly.TryParse(GetString(bucket, "startDate"), out var date)) continue;
            if (period.Start is not null && date < period.Start.Value) continue;
            if (period.End is not null && date > period.End.Value) continue;
            total += GetLong(bucket, "tokens");
        }
        return total;
    }

    private static bool AccountHasPeriodData(JsonElement account, PeriodOption period)
    {
        if (period.Key == "all") return true;
        return GetItems(account, "dailyUsageBuckets").Any(bucket =>
            DateOnly.TryParse(GetString(bucket, "startDate"), out var date)
            && period.Start is not null && period.End is not null
            && date >= period.Start.Value && date <= period.End.Value);
    }

    private static bool IsDailyRowInPeriod(JsonElement row, PeriodOption period)
    {
        if (period.Start is null || period.End is null) return true;
        return DateOnly.TryParse(GetString(row, "date"), out var date)
            && date >= period.Start.Value && date <= period.End.Value;
    }

    private static bool IsInPeriod(JsonElement session, PeriodOption period)
    {
        if (period.Start is null || period.End is null) return true;
        DateOnly date;
        var localDate = GetString(session, "localDate");
        if (!DateOnly.TryParse(localDate, out date))
        {
            if (!DateTimeOffset.TryParse(GetString(session, "startedAt"), out var started)) return false;
            date = DateOnly.FromDateTime(started.ToLocalTime().DateTime);
        }
        return date >= period.Start.Value && date <= period.End.Value;
    }

    private static bool IsComparable(JsonElement session)
    {
        if (TryGet(session, "accountComparable", out var comparable)
            && comparable.ValueKind is JsonValueKind.True or JsonValueKind.False)
            return comparable.GetBoolean();
        return !GetString(session, "source").Equals("manual", StringComparison.OrdinalIgnoreCase);
    }

    private static void AddModels(JsonElement session, Dictionary<string, UsageCounter> target)
    {
        foreach (var row in GetItems(session, "models"))
        {
            var model = GetString(row, "model");
            if (string.IsNullOrWhiteSpace(model)) continue;
            if (!target.TryGetValue(model, out var counter)) target[model] = counter = new UsageCounter();
            counter.Add(row);
        }
    }

    private void RenderModels(Dictionary<string, UsageCounter> models, long totalTokens)
    {
        var rows = models.OrderByDescending(pair => pair.Value.TotalTokens).Take(5).ToList();
        TopModels.Text = rows.Count == 0
            ? "此时间段暂无模型数据"
            : string.Join("\n", rows.Select((pair, index) =>
                $"{index + 1}. {pair.Key}  {FormatCompact(pair.Value.TotalTokens, 1)}  {(totalTokens > 0 ? pair.Value.TotalTokens * 100d / totalTokens : 0):0.0}%"));
    }

    private void RenderLimits(JsonElement root)
    {
        JsonElement primary = default;
        JsonElement secondary = default;
        var hasPrimary = false;
        var hasSecondary = false;
        if (TryGet(root, "account", out var account)
            && TryGet(account, "rateLimits", out var limits))
        {
            hasPrimary = TryGet(limits, "primary", out primary) && primary.ValueKind == JsonValueKind.Object;
            hasSecondary = TryGet(limits, "secondary", out secondary) && secondary.ValueKind == JsonValueKind.Object;
        }
        if (!hasPrimary && TryGet(root, "rateLimit", out var fallback) && fallback.ValueKind == JsonValueKind.Object)
        {
            primary = fallback;
            hasPrimary = true;
        }
        RenderLimit(hasPrimary ? primary : null, PrimaryLimitLabel, PrimaryLimitValue, PrimaryLimitBar, PrimaryReset, "主要窗口");
        RenderLimit(hasSecondary ? secondary : null, SecondaryLimitLabel, SecondaryLimitValue, SecondaryLimitBar, SecondaryReset, "次要窗口");
    }

    private static void RenderLimit(JsonElement? limit, TextBlock label, TextBlock value, System.Windows.Controls.ProgressBar bar, TextBlock reset, string fallbackLabel)
    {
        if (limit is null)
        {
            label.Text = fallbackLabel;
            value.Text = "—";
            bar.Value = 0;
            reset.Text = "暂无额度数据";
            return;
        }
        var item = limit.Value;
        var used = GetDouble(item, "usedPercent", "used_percent");
        var minutes = GetDouble(item, "windowDurationMins", "windowMinutes", "window_minutes");
        label.Text = minutes > 0 ? FormatWindow(minutes) : fallbackLabel;
        value.Text = $"{used:0.0}%";
        bar.Value = Math.Clamp(used, 0, 100);
        reset.Text = $"重置 {FormatReset(item)}";
    }

    private static string FormatWindow(double minutes)
    {
        if (minutes % 1440 == 0) return $"{minutes / 1440:0} 天窗口";
        if (minutes % 60 == 0) return $"{minutes / 60:0} 小时窗口";
        return $"{minutes:0} 分钟窗口";
    }

    private static string FormatReset(JsonElement limit)
    {
        if (!TryGetAny(limit, out var reset, "resetsAt", "resets_at")) return "—";
        DateTimeOffset when;
        if (reset.ValueKind == JsonValueKind.Number && reset.TryGetInt64(out var epoch))
        {
            when = epoch > 10_000_000_000 ? DateTimeOffset.FromUnixTimeMilliseconds(epoch) : DateTimeOffset.FromUnixTimeSeconds(epoch);
        }
        else if (!DateTimeOffset.TryParse(reset.ToString(), out when)) return "—";
        return when.ToLocalTime().ToString("MM-dd HH:mm", CultureInfo.InvariantCulture);
    }

    private static string GetAccountError(JsonElement root)
    {
        if (TryGet(root, "account", out var account))
        {
            var error = GetString(account, "error");
            if (!string.IsNullOrWhiteSpace(error)) return $"账户总账不可用 · {error}";
        }
        return "账户总账暂不可用 · 本机明细仍可统计";
    }

    private void SetQuickButtons(string key)
    {
        var transparent = System.Windows.Media.Brushes.Transparent;
        var muted = new SolidColorBrush(System.Windows.Media.Color.FromRgb(135, 145, 141));
        AllButton.Background = key == "all" ? _accentBrush : transparent;
        AllButton.Foreground = key == "all" ? _accentForegroundBrush : muted;
        TodayButton.Background = key == "today" ? _accentBrush : transparent;
        TodayButton.Foreground = key == "today" ? _accentForegroundBrush : muted;
    }

    private static double Cost(Dictionary<string, UsageCounter> models)
        => models.Sum(pair => Cost(pair.Value, PriceFor(pair.Key)));

    private static double Cost(UsageCounter usage, Price price)
    {
        var longInput = price.LongContext ? usage.LongInputTokens : 0;
        var longCached = price.LongContext ? usage.LongCachedInputTokens : 0;
        var longWrite = price.LongContext ? usage.LongCacheWriteInputTokens : 0;
        var longOutput = price.LongContext ? usage.LongOutputTokens : 0;
        var standard = Math.Max(0, usage.InputTokens - usage.CachedInputTokens - usage.CacheWriteInputTokens);
        var longStandard = Math.Max(0, longInput - longCached - longWrite);
        var normalStandard = Math.Max(0, standard - longStandard);
        var normalCached = Math.Max(0, usage.CachedInputTokens - longCached);
        var normalWrite = Math.Max(0, usage.CacheWriteInputTokens - longWrite);
        var normalOutput = Math.Max(0, usage.OutputTokens - longOutput);
        return (normalStandard * price.Input + normalCached * price.Cached + normalWrite * price.Input * 1.25
            + normalOutput * price.Output + longStandard * price.Input * 2 + longCached * price.Cached * 2
            + longWrite * price.Input * 2.5 + longOutput * price.Output * 1.5) / 1_000_000d;
    }

    private static Price PriceFor(string model)
    {
        var prices = new Dictionary<string, Price>(StringComparer.OrdinalIgnoreCase)
        {
            ["gpt-5.6-sol"] = new(5, .5, 30, true), ["gpt-5.6"] = new(5, .5, 30, true),
            ["gpt-5.6-terra"] = new(2, .2, 12, true), ["gpt-5.6-luna"] = new(.2, .02, 1.2, true),
            ["gpt-5.5"] = new(5, .5, 30, true), ["gpt-5.4"] = new(2.5, .25, 15, true),
            ["gpt-5.4-mini"] = new(.75, .075, 4.5, true), ["gpt-5.4-nano"] = new(.2, .02, 1.25, true),
            ["gpt-5.3-codex"] = new(1.75, .175, 14, false), ["gpt-5.2-codex"] = new(1.75, .175, 14, false)
        };
        if (prices.TryGetValue(model, out var exact)) return exact;
        var key = prices.Keys.OrderByDescending(k => k.Length).FirstOrDefault(k => model.StartsWith(k + "-", StringComparison.OrdinalIgnoreCase));
        return key is null ? new Price(0, 0, 0, false) : prices[key];
    }

    private static string FormatCompact(long value, int digits)
    {
        var absolute = Math.Abs((double)value);
        if (absolute < 1_000) return value.ToString("N0", CultureInfo.GetCultureInfo("zh-CN"));
        var format = "F" + digits;
        if (absolute < 1_000_000) return (value / 1_000d).ToString(format, CultureInfo.InvariantCulture) + "K";
        if (absolute < 1_000_000_000) return (value / 1_000_000d).ToString(format, CultureInfo.InvariantCulture) + "M";
        return (value / 1_000_000_000d).ToString(format, CultureInfo.InvariantCulture) + "B";
    }

    private static IEnumerable<JsonElement> GetItems(JsonElement parent, string name)
    {
        if (!TryGet(parent, name, out var value) || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) yield break;
        if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in value.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.Array)
                    foreach (var nested in item.EnumerateArray()) yield return nested;
                else yield return item;
            }
        }
        else yield return value;
    }

    private static bool TryGet(JsonElement parent, string name, out JsonElement value)
    {
        if (parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out value)) return true;
        value = default;
        return false;
    }

    private static bool TryGetAny(JsonElement parent, out JsonElement value, params string[] names)
    {
        foreach (var name in names) if (TryGet(parent, name, out value)) return true;
        value = default;
        return false;
    }

    private static string GetString(JsonElement parent, string name)
        => TryGet(parent, name, out var value) && value.ValueKind != JsonValueKind.Null ? value.ToString() : string.Empty;

    private static bool GetBool(JsonElement parent, string name)
        => TryGet(parent, name, out var value) && value.ValueKind == JsonValueKind.True;

    private static long GetLong(JsonElement parent, string name)
    {
        if (!TryGet(parent, name, out var value)) return 0;
        if (value.TryGetInt64(out var result)) return result;
        return long.TryParse(value.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out result) ? result : 0;
    }

    private static double GetDouble(JsonElement parent, params string[] names)
    {
        if (!TryGetAny(parent, out var value, names)) return 0;
        if (value.TryGetDouble(out var result)) return result;
        return double.TryParse(value.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out result) ? result : 0;
    }

    public void PositionBottomRight()
    {
        var work = SystemParameters.WorkArea;
        Left = Math.Max(work.Left, work.Right - ActualWidth - 18);
        Top = Math.Max(work.Top, work.Bottom - ActualHeight - 18);
    }

    public void ForceClose()
    {
        _refreshTimer.Stop();
        _countdownTimer.Stop();
        _allowClose = true;
        Close();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed) DragMove();
    }

    private void AllButton_Click(object sender, RoutedEventArgs e) => SelectPeriod("all");
    private void TodayButton_Click(object sender, RoutedEventArgs e) => SelectPeriod("today");
    private void MinimizeButton_Click(object sender, RoutedEventArgs e) => Hide();
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Hide();
    private void DashboardButton_Click(object sender, RoutedEventArgs e) => ((App)System.Windows.Application.Current).OpenDashboard();
    private void RefreshButton_Click(object sender, RoutedEventArgs e) => RefreshData();

    private void SelectPeriod(string key)
    {
        var target = _periods.First(item => item.Key == key);
        if (!Equals(PeriodPicker.SelectedItem, target)) PeriodPicker.SelectedItem = target;
    }

    private void PeriodPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_periodReady) Render();
    }

    public sealed record PeriodOption(string Key, string Display, DateOnly? Start, DateOnly? End)
    {
        public override string ToString() => Display;
    }
    private sealed record Price(double Input, double Cached, double Output, bool LongContext);

    private sealed class UsageCounter
    {
        public long InputTokens { get; private set; }
        public long CachedInputTokens { get; private set; }
        public long CacheWriteInputTokens { get; private set; }
        public long OutputTokens { get; private set; }
        public long ReasoningOutputTokens { get; private set; }
        public long TotalTokens { get; private set; }
        public long LongInputTokens { get; private set; }
        public long LongCachedInputTokens { get; private set; }
        public long LongCacheWriteInputTokens { get; private set; }
        public long LongOutputTokens { get; private set; }
        public long Requests { get; private set; }

        public void Add(JsonElement value)
        {
            InputTokens += GetLong(value, "inputTokens");
            CachedInputTokens += GetLong(value, "cachedInputTokens");
            CacheWriteInputTokens += GetLong(value, "cacheWriteInputTokens");
            OutputTokens += GetLong(value, "outputTokens");
            ReasoningOutputTokens += GetLong(value, "reasoningOutputTokens");
            TotalTokens += GetLong(value, "totalTokens");
            LongInputTokens += GetLong(value, "longInputTokens");
            LongCachedInputTokens += GetLong(value, "longCachedInputTokens");
            LongCacheWriteInputTokens += GetLong(value, "longCacheWriteInputTokens");
            LongOutputTokens += GetLong(value, "longOutputTokens");
            Requests += GetLong(value, "requests");
        }
    }
}
