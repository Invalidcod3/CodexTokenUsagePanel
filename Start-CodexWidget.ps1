[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 43127
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$meterScript = Join-Path $scriptRoot 'Start-CodexMeter.ps1'
$baseUrl = "http://127.0.0.1:$Port/"
$serverProcess = $null
$script:exiting = $false
$script:downloadTask = $null
$script:webClient = $null
$script:nextRefresh = [datetimeoffset]::MinValue
$script:shownAt = [datetimeoffset]::MinValue
$script:viewMode = 'all'
$script:lastData = $null

trap {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][Windows.Forms.MessageBox]::Show(
            "Codex Token Meter 启动失败：`r`n`r`n$($_.Exception.Message)",
            'Codex Token Meter',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        )
    } catch {}
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

function Test-MeterServer {
    try {
        $health = Invoke-RestMethod ($baseUrl + 'api/health') -TimeoutSec 2
        return $health.product -eq 'codex-token-meter'
    } catch { return $false }
}

function Test-PortOpen {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        return $task.Wait(500) -and $client.Connected
    } catch { return $false } finally { $client.Dispose() }
}

if (-not (Test-MeterServer)) {
    if (Test-PortOpen) { throw "端口 $Port 已被其他程序占用。请关闭占用程序，或使用 -Port 指定其他端口。" }
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$meterScript`" -Port $Port -NoBrowser"
    $serverProcess = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    for ($attempt = 0; $attempt -lt 60 -and -not (Test-MeterServer); $attempt++) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-MeterServer)) {
        if ($serverProcess.HasExited) { throw "本地 Token Meter 服务启动后立即退出，退出码 $($serverProcess.ExitCode)。" }
        throw '本地 Token Meter 服务在 15 秒内没有就绪。'
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:primitives="clr-namespace:System.Windows.Controls.Primitives;assembly=PresentationFramework"
        Title="Codex Token Meter" Width="420" Height="780" MinHeight="500"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        AllowsTransparency="True" Background="Transparent" Foreground="#F2F5F3" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="5"/>
      <Setter Property="Margin" Value="4,0,0,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Grid Width="5" Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
                <Track.DecreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Background="Transparent" BorderThickness="0" Focusable="False" Opacity="0"/></Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <primitives:Thumb Width="2">
                    <primitives:Thumb.Template>
                      <ControlTemplate TargetType="{x:Type primitives:Thumb}">
                        <Border x:Name="Grip" Background="#46504C" CornerRadius="2" Opacity="0.55"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Grip" Property="Background" Value="#77817D"/><Setter TargetName="Grip" Property="Opacity" Value="0.85"/></Trigger>
                          <Trigger Property="IsDragging" Value="True"><Setter TargetName="Grip" Property="Background" Value="#A2ABA7"/><Setter TargetName="Grip" Property="Opacity" Value="1"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </primitives:Thumb.Template>
                  </primitives:Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Background="Transparent" BorderThickness="0" Focusable="False" Opacity="0"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="{x:Type Button}">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="ButtonChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.68"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border BorderBrush="#303A36" BorderThickness="1" CornerRadius="18" Background="#0D1112" Padding="20" SnapsToDevicePixels="True">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="30" Height="30" CornerRadius="8" Background="#F1F4F2" Padding="4"><Image x:Name="BrandIcon" Width="22" Height="22" Stretch="Uniform"/></Border>
          <StackPanel Margin="10,0,0,0"><TextBlock Text="CODEX METER" FontWeight="SemiBold" FontSize="12"/><TextBlock Text="账户总账 · 本机归因" Foreground="#7E8985" FontSize="9"/></StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border CornerRadius="9" Background="#14191A" Padding="2">
            <StackPanel Orientation="Horizontal">
              <Button x:Name="AllTimeButton" Content="累计" Width="43" Height="26" Padding="0" Background="#B8FF34" Foreground="#0A0D0B" FontSize="9" FontWeight="SemiBold"/>
              <Button x:Name="TodayButton" Content="今日" Width="43" Height="26" Padding="0" Background="Transparent" Foreground="#87918D" FontSize="9"/>
            </StackPanel>
          </Border>
          <Button x:Name="HideButton" Content="×" Width="28" Height="28" Margin="8,0,0,0" Padding="0" Background="#171C1D" Foreground="#9DA6A2" FontSize="17"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="1" Margin="0,22,0,0" Padding="18" CornerRadius="12" BorderBrush="#33452E" BorderThickness="1" Background="#131A16">
        <StackPanel>
          <TextBlock x:Name="AccountScopeLabel" Text="CHATGPT ACCOUNT · LIFETIME" Foreground="#9AA49F" FontSize="9"/>
          <TextBlock x:Name="LifetimeValue" Text="正在同步…" Margin="0,11,0,4" FontFamily="Consolas" FontSize="38" FontWeight="Bold"/>
          <TextBlock x:Name="AccountState" Text="读取 OpenAI 账户总账" Foreground="#B8FF34" FontSize="9"/>
        </StackPanel>
      </Border>

      <Grid Grid.Row="2" Margin="0,8,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Padding="11" CornerRadius="9" Background="#14191A"><StackPanel><TextBlock Text="可归因" Foreground="#78827E" FontSize="8"/><TextBlock x:Name="AttributedValue" Text="—" Margin="0,7,0,0" FontFamily="Consolas" FontSize="15"/></StackPanel></Border>
        <Border Grid.Column="1" Margin="5,0" Padding="11" CornerRadius="9" Background="#1A1715"><StackPanel><TextBlock Text="未归因" Foreground="#9B8171" FontSize="8"/><TextBlock x:Name="UnattributedValue" Text="—" Margin="0,7,0,0" Foreground="#E0A27E" FontFamily="Consolas" FontSize="15"/></StackPanel></Border>
        <Border Grid.Column="2" Padding="11" CornerRadius="9" Background="#14191A"><StackPanel><TextBlock Text="覆盖率" Foreground="#78827E" FontSize="8"/><TextBlock x:Name="CoverageValue" Text="—" Margin="0,7,0,0" FontFamily="Consolas" FontSize="15"/></StackPanel></Border>
      </Grid>

      <Grid Grid.Row="3" Margin="0,22,0,9"><TextBlock Text="本机可拆分明细" FontSize="11" FontWeight="SemiBold"/><TextBlock x:Name="RequestValue" Text="—" HorizontalAlignment="Right" Foreground="#6F7975" FontSize="8"/></Grid>
      <Grid Grid.Row="4">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <Border Grid.Row="0" Grid.Column="0" Margin="0,0,4,4" Padding="13" Background="#121718" CornerRadius="9"><StackPanel><TextBlock Text="输入 TOKEN" Foreground="#77817D" FontSize="8"/><TextBlock x:Name="InputValue" Text="—" Margin="0,7,0,0" FontFamily="Consolas" FontSize="18"/></StackPanel></Border>
        <Border Grid.Row="0" Grid.Column="1" Margin="4,0,0,4" Padding="13" Background="#121718" CornerRadius="9"><StackPanel><TextBlock Text="输出 TOKEN" Foreground="#77817D" FontSize="8"/><TextBlock x:Name="OutputValue" Text="—" Margin="0,7,0,0" FontFamily="Consolas" FontSize="18"/></StackPanel></Border>
        <Border Grid.Row="1" Grid.Column="0" Margin="0,4,4,0" Padding="13" Background="#121718" CornerRadius="9"><StackPanel><TextBlock Text="缓存输入" Foreground="#77817D" FontSize="8"/><TextBlock x:Name="CachedValue" Text="—" Margin="0,7,0,0" Foreground="#B8FF34" FontFamily="Consolas" FontSize="18"/></StackPanel></Border>
        <Border Grid.Row="1" Grid.Column="1" Margin="4,4,0,0" Padding="13" Background="#121718" CornerRadius="9"><StackPanel><TextBlock Text="其中推理输出" Foreground="#77817D" FontSize="8"/><TextBlock x:Name="ReasoningValue" Text="—" Margin="0,7,0,0" FontFamily="Consolas" FontSize="18"/></StackPanel></Border>
      </Grid>

      <Border Grid.Row="5" Margin="0,12,0,0" Padding="14" Background="#101516" CornerRadius="9">
        <Grid><StackPanel><TextBlock Text="本机明细 API 等价费用" Foreground="#7D8783" FontSize="8"/><TextBlock Text="账户全量外推（非账单）" Foreground="#59625F" FontSize="8" Margin="0,7,0,0"/></StackPanel><StackPanel HorizontalAlignment="Right"><TextBlock x:Name="CostValue" Text="—" HorizontalAlignment="Right" Foreground="#B8FF34" FontFamily="Consolas" FontSize="18"/><TextBlock x:Name="ProjectedCostValue" Text="—" Margin="0,4,0,0" HorizontalAlignment="Right" Foreground="#A0A9A5" FontFamily="Consolas" FontSize="11"/></StackPanel></Grid>
      </Border>

      <ScrollViewer Grid.Row="6" Margin="0,14,0,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <TextBlock Text="账户使用特征" Foreground="#7C8682" FontSize="8"/>
          <Grid Margin="0,7,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" Padding="10" Background="#121718" CornerRadius="8"><StackPanel><TextBlock Text="单日峰值" Foreground="#6F7975" FontSize="7"/><TextBlock x:Name="PeakValue" Text="—" Margin="0,5,0,0" FontFamily="Consolas" FontSize="12"/></StackPanel></Border>
            <Border Grid.Column="1" Margin="5,0" Padding="10" Background="#121718" CornerRadius="8"><StackPanel><TextBlock Text="连续使用" Foreground="#6F7975" FontSize="7"/><TextBlock x:Name="StreakValue" Text="—" Margin="0,5,0,0" FontFamily="Consolas" FontSize="12"/></StackPanel></Border>
            <Border Grid.Column="2" Padding="10" Background="#121718" CornerRadius="8"><StackPanel><TextBlock Text="最长任务" Foreground="#6F7975" FontSize="7"/><TextBlock x:Name="LongestTurnValue" Text="—" Margin="0,5,0,0" FontFamily="Consolas" FontSize="12"/></StackPanel></Border>
          </Grid>

          <TextBlock Text="Codex 额度窗口" Margin="0,13,0,0" Foreground="#7C8682" FontSize="8"/>
          <Grid Margin="0,7,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" Margin="0,0,4,0" Padding="11" Background="#121718" CornerRadius="8"><StackPanel><Grid><TextBlock x:Name="PrimaryLimitLabel" Text="主要窗口" Foreground="#8C9691" FontSize="8"/><TextBlock x:Name="PrimaryLimitValue" Text="—" HorizontalAlignment="Right" FontFamily="Consolas" FontSize="9"/></Grid><ProgressBar x:Name="PrimaryLimitBar" Height="4" Margin="0,8,0,6" Minimum="0" Maximum="100" Value="0" Background="#252C2A" Foreground="#B8FF34" BorderThickness="0"/><TextBlock x:Name="PrimaryResetValue" Text="重置时间 —" Foreground="#626B67" FontSize="7"/></StackPanel></Border>
            <Border Grid.Column="1" Margin="4,0,0,0" Padding="11" Background="#121718" CornerRadius="8"><StackPanel><Grid><TextBlock x:Name="SecondaryLimitLabel" Text="次要窗口" Foreground="#8C9691" FontSize="8"/><TextBlock x:Name="SecondaryLimitValue" Text="—" HorizontalAlignment="Right" FontFamily="Consolas" FontSize="9"/></Grid><ProgressBar x:Name="SecondaryLimitBar" Height="4" Margin="0,8,0,6" Minimum="0" Maximum="100" Value="0" Background="#252C2A" Foreground="#8BC7FF" BorderThickness="0"/><TextBlock x:Name="SecondaryResetValue" Text="重置时间 —" Foreground="#626B67" FontSize="7"/></StackPanel></Border>
          </Grid>

          <TextBlock Text="模型排行" Margin="0,13,0,0" Foreground="#7C8682" FontSize="8"/>
          <Border Margin="0,7,0,0" Padding="11" Background="#121718" CornerRadius="8"><TextBlock x:Name="TopModelsValue" Text="—" Foreground="#A6AFAB" FontFamily="Consolas" FontSize="9" TextWrapping="Wrap" LineHeight="16"/></Border>

          <TextBlock Text="账户最近用量" Margin="0,13,0,0" Foreground="#7C8682" FontSize="8"/>
          <TextBlock x:Name="DailyValue" Text="—" Margin="0,7,0,0" Foreground="#A6AFAB" FontFamily="Consolas" FontSize="9" TextWrapping="Wrap" LineHeight="16"/>
          <TextBlock x:Name="SourceValue" Text="—" Margin="0,10,0,2" Foreground="#59625F" FontSize="7" TextWrapping="Wrap"/>
        </StackPanel>
      </ScrollViewer>

      <Grid Grid.Row="7" Margin="0,14,0,0">
        <Button x:Name="DashboardButton" Content="打开完整统计" Height="34" HorizontalAlignment="Stretch" Margin="0,0,84,0" Background="#B8FF34" Foreground="#0A0D0B" BorderThickness="0" FontWeight="SemiBold"/>
        <Button x:Name="RefreshButton" Content="刷新" Width="76" Height="34" HorizontalAlignment="Right" Background="#171D1E" Foreground="#BFC7C3" BorderThickness="0"/>
      </Grid>
      <TextBlock Grid.Row="8" x:Name="StatusValue" Text="准备同步" Margin="0,12,0,0" Foreground="#626C68" FontSize="8" TextTrimming="CharacterEllipsis"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = @('TitleBar','BrandIcon','AllTimeButton','TodayButton','HideButton','AccountScopeLabel','LifetimeValue','AccountState','AttributedValue','UnattributedValue','CoverageValue','RequestValue','InputValue','OutputValue','CachedValue','ReasoningValue','CostValue','ProjectedCostValue','PeakValue','StreakValue','LongestTurnValue','PrimaryLimitLabel','PrimaryLimitValue','PrimaryLimitBar','PrimaryResetValue','SecondaryLimitLabel','SecondaryLimitValue','SecondaryLimitBar','SecondaryResetValue','TopModelsValue','DailyValue','SourceValue','DashboardButton','RefreshButton','StatusValue')
$ui = @{}
foreach ($name in $names) { $ui[$name] = $window.FindName($name) }

function Resolve-BrandIconPath {
    try {
        $command = Get-Command codex.exe -ErrorAction Stop
        $candidate = Join-Path (Split-Path -Parent $command.Path) 'icon-chatgpt.ico'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    } catch {}
    try {
        $packageRoot = 'C:\Program Files\WindowsApps'
        $candidate = Get-ChildItem -LiteralPath $packageRoot -Directory -Filter 'OpenAI.Codex_*' -ErrorAction Stop |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'app\resources\icon-chatgpt.ico' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($candidate) { return $candidate }
    } catch {}
    return $null
}

$brandIconPath = Resolve-BrandIconPath
if ($brandIconPath) {
    try {
        $decoder = [Windows.Media.Imaging.IconBitmapDecoder]::new(
            [Uri]$brandIconPath,
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        )
        $frame = $decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
        $ui.BrandIcon.Source = $frame
    } catch {}
}

function Format-Compact([double]$value) {
    if ($value -ge 1000000000) { return ('{0:0.##}B' -f ($value / 1000000000)) }
    if ($value -ge 1000000) { return ('{0:0.##}M' -f ($value / 1000000)) }
    if ($value -ge 1000) { return ('{0:0.##}K' -f ($value / 1000)) }
    return ('{0:N0}' -f $value)
}

function Format-Duration([double]$seconds) {
    if ($seconds -le 0) { return '—' }
    $span = [timespan]::FromSeconds($seconds)
    if ($span.TotalHours -ge 1) { return ('{0}h {1:D2}m' -f [math]::Floor($span.TotalHours), $span.Minutes) }
    if ($span.TotalMinutes -ge 1) { return ('{0}m {1:D2}s' -f [math]::Floor($span.TotalMinutes), $span.Seconds) }
    return ('{0}s' -f [math]::Round($span.TotalSeconds))
}

function Format-WindowName($minutes) {
    if ($null -eq $minutes) { return '额度窗口' }
    $value = [double]$minutes
    if ($value -ge 10080) { return ('{0:0.#} 周窗口' -f ($value / 10080)) }
    if ($value -ge 1440) { return ('{0:0.#} 天窗口' -f ($value / 1440)) }
    if ($value -ge 60) { return ('{0:0.#} 小时窗口' -f ($value / 60)) }
    return ('{0:0} 分钟窗口' -f $value)
}

function Format-ResetAt($timestamp) {
    if ($null -eq $timestamp -or [long]$timestamp -le 0) { return '重置时间不可用' }
    try { return '重置 ' + [datetimeoffset]::FromUnixTimeSeconds([long]$timestamp).ToLocalTime().ToString('MM-dd HH:mm') } catch { return '重置时间不可用' }
}

function Set-LimitView($limit, $label, $value, $bar, $reset) {
    if ($null -eq $limit) {
        $label.Text = '额度窗口不可用'; $value.Text = '—'; $bar.Value = 0; $reset.Text = '等待账户数据'
        return
    }
    $percent = if ($null -ne $limit.usedPercent) { [math]::Max(0, [math]::Min(100, [double]$limit.usedPercent)) } else { 0 }
    $label.Text = Format-WindowName $limit.windowDurationMins
    $value.Text = if ($null -ne $limit.usedPercent) { '{0:0.#}%' -f [double]$limit.usedPercent } else { '—' }
    $bar.Value = $percent
    $reset.Text = Format-ResetAt $limit.resetsAt
}

function Get-Price($model) {
    $prices = @{
        'gpt-5.6-sol' = @(5.00, 0.50, 30.00, $true); 'gpt-5.6' = @(5.00, 0.50, 30.00, $true)
        'gpt-5.6-terra' = @(2.00, 0.20, 12.00, $true); 'gpt-5.6-luna' = @(0.20, 0.02, 1.20, $true)
        'gpt-5.5' = @(5.00, 0.50, 30.00, $true); 'gpt-5.4' = @(2.50, 0.25, 15.00, $true)
        'gpt-5.4-mini' = @(0.75, 0.075, 4.50, $true); 'gpt-5.4-nano' = @(0.20, 0.02, 1.25, $true)
        'gpt-5.3-codex' = @(1.75, 0.175, 14.00, $false); 'gpt-5.2-codex' = @(1.75, 0.175, 14.00, $false)
    }
    foreach ($key in @($prices.Keys | Sort-Object Length -Descending)) {
        if ($model -eq $key -or $model.StartsWith($key + '-')) { return $prices[$key] }
    }
    return @(0,0,0,$false)
}

function Estimate-Cost($models) {
    $sum = 0.0
    foreach ($row in @($models)) {
        $price = Get-Price ([string]$row.model)
        $input = [double]$row.inputTokens; $cached = [double]$row.cachedInputTokens; $write = [double]$row.cacheWriteInputTokens; $output = [double]$row.outputTokens
        $longInput = if ($price[3]) { [double]$row.longInputTokens } else { 0 }; $longCached = if ($price[3]) { [double]$row.longCachedInputTokens } else { 0 }
        $longWrite = if ($price[3]) { [double]$row.longCacheWriteInputTokens } else { 0 }; $longOutput = if ($price[3]) { [double]$row.longOutputTokens } else { 0 }
        $standard = [math]::Max(0, $input - $cached - $write); $longStandard = [math]::Max(0, $longInput - $longCached - $longWrite)
        $normalStandard = [math]::Max(0, $standard - $longStandard); $normalCached = [math]::Max(0, $cached - $longCached); $normalWrite = [math]::Max(0, $write - $longWrite); $normalOutput = [math]::Max(0, $output - $longOutput)
        $sum += ($normalStandard * $price[0] + $normalCached * $price[1] + $normalWrite * $price[0] * 1.25 + $normalOutput * $price[2] + $longStandard * $price[0] * 2 + $longCached * $price[1] * 2 + $longWrite * $price[0] * 2.5 + $longOutput * $price[2] * 1.5) / 1000000
    }
    return $sum
}

function New-ViewUsage {
    [ordered]@{
        inputTokens = [double]0; cachedInputTokens = [double]0; cacheWriteInputTokens = [double]0
        outputTokens = [double]0; reasoningOutputTokens = [double]0; totalTokens = [double]0
        longInputTokens = [double]0; longCachedInputTokens = [double]0; longCacheWriteInputTokens = [double]0
        longOutputTokens = [double]0; requests = [double]0; longRequests = [double]0
    }
}

function Add-ViewUsage($target, $source) {
    foreach ($key in @($target.Keys)) { $target[$key] += [double]($source.$key) }
}

function Get-ViewSnapshot($data) {
    $today = [datetimeoffset]::Now.ToString('yyyy-MM-dd')
    $sessions = if ($script:viewMode -eq 'today') { @($data.sessions | Where-Object { $_.localDate -eq $today }) } else { @($data.sessions) }
    $totals = New-ViewUsage
    $modelMap = @{}
    $comparableTokens = [double]0

    foreach ($session in $sessions) {
        Add-ViewUsage $totals $session.usage
        if ($session.source -ne 'manual') { $comparableTokens += [double]$session.usage.totalTokens }
        foreach ($modelUsage in @($session.models)) {
            $model = [string]$modelUsage.model
            if (-not $modelMap.ContainsKey($model)) { $modelMap[$model] = New-ViewUsage }
            Add-ViewUsage $modelMap[$model] $modelUsage
        }
    }

    $models = @($modelMap.GetEnumerator() | ForEach-Object {
        $row = [ordered]@{ model = $_.Key }
        foreach ($key in $_.Value.Keys) { $row[$key] = $_.Value[$key] }
        [pscustomobject]$row
    })

    $accountBucketAvailable = $true
    if ($script:viewMode -eq 'today') {
        $bucket = @($data.account.dailyUsageBuckets | Where-Object { $_.startDate -eq $today } | Select-Object -First 1)
        if ($bucket.Count) { $accountTokens = [double]$bucket[0].tokens }
        else { $accountTokens = $comparableTokens; $accountBucketAvailable = $false }
    } else {
        $accountTokens = [double]$data.account.summary.lifetimeTokens
    }
    $unattributed = [math]::Max(0, $accountTokens - $comparableTokens)
    $coverage = if ($accountTokens -gt 0 -and $accountBucketAvailable) { [double]$comparableTokens * 100 / $accountTokens } else { $null }

    [pscustomobject][ordered]@{
        today = $today
        sessions = $sessions
        totals = [pscustomobject]$totals
        models = $models
        accountTokens = $accountTokens
        accountBucketAvailable = $accountBucketAvailable
        comparableTokens = $comparableTokens
        unattributedTokens = $unattributed
        coveragePercent = $coverage
    }
}

function Update-View($data) {
    $script:lastData = $data
    $view = Get-ViewSnapshot $data
    $available = $data.account.available -and $null -ne $data.account.summary
    $isToday = $script:viewMode -eq 'today'
    $ui.AccountScopeLabel.Text = if ($isToday) { 'CHATGPT ACCOUNT · TODAY' } else { 'CHATGPT ACCOUNT · LIFETIME' }
    $ui.LifetimeValue.Text = if ($available) { Format-Compact $view.accountTokens } else { '账户不可用' }
    $ui.AccountState.Text = if (-not $available) { [string]$data.account.error } elseif ($isToday -and -not $view.accountBucketAvailable) { '今日账户桶尚未返回 · 显示本机已知用量' } elseif ($isToday) { '今日账户用量已同步' } else { '账户总账已同步' }
    $ui.AccountState.Foreground = if ($available) { '#B8FF34' } else { '#E0A27E' }
    $ui.AttributedValue.Text = Format-Compact $view.comparableTokens
    $ui.UnattributedValue.Text = if ($available -and $view.accountBucketAvailable) { Format-Compact $view.unattributedTokens } else { '—' }
    $ui.CoverageValue.Text = if ($null -ne $view.coveragePercent) { '{0:0.0}%' -f [double]$view.coveragePercent } else { '—' }
    $ui.RequestValue.Text = ('{0} · {1:N0} 次调用 · {2} 个任务' -f (Format-Compact $view.totals.totalTokens), [long]$view.totals.requests, @($view.sessions).Count)
    $ui.InputValue.Text = Format-Compact $view.totals.inputTokens
    $ui.OutputValue.Text = Format-Compact $view.totals.outputTokens
    $cacheRate = if ([double]$view.totals.inputTokens -gt 0) { [double]$view.totals.cachedInputTokens * 100 / [double]$view.totals.inputTokens } else { 0 }
    $reasoningRate = if ([double]$view.totals.outputTokens -gt 0) { [double]$view.totals.reasoningOutputTokens * 100 / [double]$view.totals.outputTokens } else { 0 }
    $ui.CachedValue.Text = (Format-Compact $view.totals.cachedInputTokens) + (' · {0:0.#}%' -f $cacheRate)
    $ui.ReasoningValue.Text = (Format-Compact $view.totals.reasoningOutputTokens) + (' · {0:0.#}%' -f $reasoningRate)
    $localCost = Estimate-Cost $view.models
    $comparableModels = @($view.sessions | Where-Object { $_.source -ne 'manual' } | ForEach-Object { @($_.models) })
    $comparableCost = Estimate-Cost $comparableModels
    $projectedCost = if ($available -and $view.accountBucketAvailable -and [double]$view.comparableTokens -gt 0) { $comparableCost * [double]$view.accountTokens / [double]$view.comparableTokens } else { $null }
    $ui.CostValue.Text = ('$' + ('{0:N2}' -f $localCost) + '  ·  ¥' + ('{0:N2}' -f ($localCost * 7.2)))
    $ui.ProjectedCostValue.Text = if ($null -ne $projectedCost) { '外推 $' + ('{0:N2}' -f $projectedCost) + '  ·  ¥' + ('{0:N0}' -f ($projectedCost * 7.2)) } else { '外推 —' }

    $summary = $data.account.summary
    $ui.PeakValue.Text = if ($available -and $null -ne $summary.peakDailyTokens) { Format-Compact $summary.peakDailyTokens } else { '—' }
    $ui.StreakValue.Text = if ($available) { '{0}d / {1}d' -f [long]$summary.currentStreakDays, [long]$summary.longestStreakDays } else { '—' }
    $ui.LongestTurnValue.Text = if ($available) { Format-Duration $summary.longestRunningTurnSec } else { '—' }
    Set-LimitView $data.account.rateLimits.primary $ui.PrimaryLimitLabel $ui.PrimaryLimitValue $ui.PrimaryLimitBar $ui.PrimaryResetValue
    Set-LimitView $data.account.rateLimits.secondary $ui.SecondaryLimitLabel $ui.SecondaryLimitValue $ui.SecondaryLimitBar $ui.SecondaryResetValue

    $topModels = @($view.models | Sort-Object -Property totalTokens -Descending | Select-Object -First 4 | ForEach-Object {
        ([string]$_.model) + '  ' + (Format-Compact $_.totalTokens) + '  ·  ' + ('{0:N0}' -f [long]$_.requests) + ' 次'
    })
    $ui.TopModelsValue.Text = if ($topModels.Count) { $topModels -join "`r`n" } else { '没有可用的模型明细' }

    $recent = @($data.account.dailyUsageBuckets | Select-Object -Last 7 | ForEach-Object { ([string]$_.startDate).Substring(5) + ' ' + (Format-Compact $_.tokens) })
    $ui.DailyValue.Text = if ($recent.Count) { $recent -join '   ·   ' } else { '账户每日桶不可用' }
    $sourceCount = @($view.sessions | ForEach-Object source | Sort-Object -Unique).Count
    $ui.SourceValue.Text = ('数据源 {0} 类 · 扫描 {1} 个文件 · 异常行 {2} · 模型 {3} 个' -f $sourceCount, [long]$data.filesScanned, [long]$data.malformedLines, @($view.models).Count)
    $scopeText = if ($isToday) { '今日' } else { '累计' }
    $ui.StatusValue.Text = $scopeText + ' · 更新于 ' + ([datetime]$data.generatedAt).ToLocalTime().ToString('HH:mm:ss') + ' · 账户总量不等于 API 账单'
}

function Set-ViewMode([string]$mode) {
    $script:viewMode = if ($mode -eq 'today') { 'today' } else { 'all' }
    $todayActive = $script:viewMode -eq 'today'
    $ui.TodayButton.Background = if ($todayActive) { '#B8FF34' } else { 'Transparent' }
    $ui.TodayButton.Foreground = if ($todayActive) { '#0A0D0B' } else { '#87918D' }
    $ui.TodayButton.FontWeight = if ($todayActive) { 'SemiBold' } else { 'Normal' }
    $ui.AllTimeButton.Background = if ($todayActive) { 'Transparent' } else { '#B8FF34' }
    $ui.AllTimeButton.Foreground = if ($todayActive) { '#87918D' } else { '#0A0D0B' }
    $ui.AllTimeButton.FontWeight = if ($todayActive) { 'Normal' } else { 'SemiBold' }
    if ($null -ne $script:lastData) { Update-View $script:lastData }
}

function Begin-Refresh {
    if ($null -ne $script:downloadTask) { return }
    try {
        $ui.StatusValue.Text = '正在同步账户总账与本机日志…'
        $script:webClient = New-Object Net.WebClient
        $script:webClient.Encoding = [Text.Encoding]::UTF8
        $script:downloadTask = $script:webClient.DownloadStringTaskAsync([Uri]($baseUrl + 'api/usage'))
    } catch {
        $ui.StatusValue.Text = '刷新失败：' + $_.Exception.Message
        $script:downloadTask = $null
    }
}

function Show-Flyout {
    # WPF coordinates are device-independent pixels. SystemParameters.WorkArea uses
    # the same coordinate system, unlike WinForms Screen.WorkingArea on scaled displays.
    $area = [Windows.SystemParameters]::WorkArea
    $window.Height = [math]::Min(780, [math]::Max(500, $area.Height - 28))
    $window.Left = $area.Right - $window.Width - 14
    $window.Top = $area.Bottom - $window.Height - 14
    $script:shownAt = [datetimeoffset]::Now
    $window.Show()
    $window.Activate()
    Begin-Refresh
}

function Open-Dashboard { Start-Process $baseUrl }

$notifyIcon = New-Object Windows.Forms.NotifyIcon
$trayIcon = $null
if ($brandIconPath) {
    try { $trayIcon = New-Object Drawing.Icon $brandIconPath } catch {}
}
$notifyIcon.Icon = if ($trayIcon) { $trayIcon } else { [Drawing.SystemIcons]::Application }
$notifyIcon.Text = 'Codex Token Meter'
$notifyIcon.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
$showItem = $menu.Items.Add('显示用量')
$openItem = $menu.Items.Add('打开完整统计')
$refreshItem = $menu.Items.Add('刷新')
[void]$menu.Items.Add('-')
$exitItem = $menu.Items.Add('退出')
$notifyIcon.ContextMenuStrip = $menu

$showItem.Add_Click({ Show-Flyout })
$openItem.Add_Click({ Open-Dashboard })
$refreshItem.Add_Click({ $script:nextRefresh = [datetimeoffset]::MinValue; Begin-Refresh })
$exitItem.Add_Click({ $script:exiting = $true; $window.Close() })
$notifyIcon.Add_MouseClick({ if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-Flyout } })
$notifyIcon.Add_DoubleClick({ Open-Dashboard })
$ui.HideButton.Add_Click({ $window.Hide() })
$ui.AllTimeButton.Add_Click({ Set-ViewMode 'all' })
$ui.TodayButton.Add_Click({ Set-ViewMode 'today' })
$ui.DashboardButton.Add_Click({ Open-Dashboard })
$ui.RefreshButton.Add_Click({ Begin-Refresh })
# Keep the panel visible until the user presses ×. Auto-hiding on focus loss made
# it disappear immediately when launched from a CMD window on some Windows setups.
$window.Add_Closing({ if (-not $script:exiting) { $_.Cancel = $true; $window.Hide() } })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [timespan]::FromMilliseconds(400)
$timer.Add_Tick({
    if ($null -ne $script:downloadTask -and $script:downloadTask.IsCompleted) {
        try {
            $json = $script:downloadTask.GetAwaiter().GetResult()
            Update-View ($json | ConvertFrom-Json)
            $script:nextRefresh = [datetimeoffset]::Now.AddSeconds(30)
        } catch {
            $ui.StatusValue.Text = '刷新失败：' + $_.Exception.Message
            $script:nextRefresh = [datetimeoffset]::Now.AddSeconds(10)
        } finally {
            if ($null -ne $script:webClient) { $script:webClient.Dispose() }
            $script:webClient = $null
            $script:downloadTask = $null
        }
    }
    if ($window.IsVisible -and $null -eq $script:downloadTask -and [datetimeoffset]::Now -ge $script:nextRefresh) { Begin-Refresh }
})
$timer.Start()

try {
    Show-Flyout
    $application = New-Object Windows.Application
    [void]$application.Run($window)
} finally {
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($null -ne $trayIcon) { $trayIcon.Dispose() }
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
