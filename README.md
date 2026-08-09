# Codex Token Usage Analyzer

本项目是跑着玩的，本意就是Token太多，造个轮子玩玩，传入Github成为新的赛博垃圾（不过我会用着玩）。至于你想用我也不拦你。

下面全是Codex自动写的，我没仔细核查过，该说的应该都在里面，反正就我一个人用不至于搞半天火了吧。

=================================================

一个 Windows 托盘式 Codex Token 用量显示器。它通过已登录的 Codex 只读同步 ChatGPT 账户 lifetime Token 总量，同时扫描本机 Codex 会话，统计输入、缓存输入、缓存写入、输出和推理 Token，并换算标准 OpenAI API 的文本 Token 等价开销。

它刻意把两种口径分开：

- **账户总账**：OpenAI 服务器返回的 lifetime 总量与每日总量，覆盖其他电脑和云端 Codex 使用。
- **本机明细**：当前能找到的 `sessions`、`archived_sessions` 和已导入日志，可拆分输入/输出、模型和费用。
- **未归因**：账户总账减去可归因 Codex 日志。由于官方账户接口不返回历史输入/输出和模型拆分，这部分不会被伪造拆分。面板可以按本机已知日志的模型/输入/输出结构外推一个全量 API 情景费用，但会明确标注为非账单。

## Windows 桌面应用

已经编译好的程序位于：

- `dist\CodexMeter\CodexMeter.exe`

直接双击该 EXE 或 `Launch-Widget.cmd` 即可启动，不会出现需要一直保留的 CMD/PowerShell 窗口。`Launch-Dashboard.cmd` 会直接打开独立的完整统计窗口。

应用采用单实例运行并常驻系统托盘。单击托盘图标打开紧凑小组件，双击打开完整统计；右键使用应用自绘的暗色圆角菜单，不再显示 Windows 默认菜单。最小化按钮与关闭按钮都只会隐藏到托盘，不会误关后台统计。只有托盘右键菜单中的“退出”才会结束应用及其自行启动的后台服务。托盘图标对象由应用全程持有，避免窗口关闭后图标随机消失。自动刷新间隔可在设置中按秒配置，支持小数且最低为 0.5 秒。

小组件同时显示账户总量、本机可归因量、未归因量、覆盖率、输入、输出、缓存输入、推理输出、本机与外推 API 等价费用、额度窗口与重置时间、模型排行和数据状态。圆角窗口可调整大小，内容不足时使用细滚动条。

标题栏保留“累计 / 今日”快捷切换。底部“打开完整统计”右侧的时间下拉菜单还可选择昨日、最近 7 日、最近 30 日、本月和上月。账户用量、本机任务、输入输出、缓存、模型排行、归因覆盖率和费用会同步切换；同一年内的区间只显示月/日，跨年区间才显示年份。本机时间段按每条 Token 事件的本地日期拆分，跨午夜的长任务不会再被全部计入任务开始日；若账户今日桶尚未返回，顶部会明确切换为本机实时确认值。

刷新采用逐文件增量索引：首次启动解析现有 JSONL，之后记录每个文件的已读字节偏移，只解析新增行；文件被截断、替换或同长度重写时会自动回退全量校验。刷新期间暂停倒计时，完成后才重新开始完整间隔，因此短间隔不会产生重叠任务或请求队列。顶部状态会显示下次刷新/失败重试的实时倒计时。

数值变化使用逐位滚动动画，只有改变的数字位滚入新值；刷新和切换累计、今日、昨日、7 日、30 日、本月、上月时都会触发。完整统计的动画结束后恢复为纯文本；原生小组件使用不参与布局测量的字形位移动画，真实文本始终留在原位，避免刷新瞬间数字消失或卡片缩放。中文紧凑单位（万、亿）与数字统一使用支持中文的等宽数字界面字体。

设置页提供 HLS（色相、亮度、饱和度）配色面板，可分别调整强调色、背景色、卡片色、主文字、次级文字和辅助色并实时预览；保存后完整统计、Web 小组件与原生小组件共享配色。各层背景会由所选颜色自动派生，深浅强调色会自动选择对比文字颜色，也可一键恢复默认配色。

账户 lifetime 总量以服务器快照为锚点；两个账户快照之间，本机新写入且可归因的日志 Token 会实时补记到累计显示。下一次服务器总账追上后自动重新对账，并使用单调合并避免数值倒退或重复累计；对账锚点保存在本地缓存中，应用重启或重新编译后也不会暂时回落。

页面背景与控件/卡片背景彼此独立。工具按钮、周期按钮、设置输入框和配色项只跟随卡片色，浅色页面背景不会再渗入控件；卡片和页面底色均使用纯色，不叠加装饰渐变或光斑。

完整统计折线图使用逐日 Token 事件，其中当天点会随本机日志实时变化。只有当天数据点的悬浮提示会标注“数据可能不完整”，历史点不会显示该提示；悬浮层已提升到图表卡片上层，避免被相邻元素遮挡。所有日期范围会在跨午夜后重新锚定到新的本地日期。

“打开完整统计”会在应用内打开另一个自绘桌面窗口。它没有 Windows 原生外框，使用“Token 明细”标题栏，并支持最小化、最大化/还原、边缘缩放、详细图表、任务表格、设置和 JSON 导出；关闭它不会退出托盘小组件。

## 重新编译

电脑已安装 .NET 8 SDK 或更高版本时，双击 `Build-App.cmd`，或运行：

```powershell
.\Build-App.ps1
```

输出目录为 `dist\CodexMeter`。如需把 .NET 运行时一同打包，可运行：

```powershell
.\Build-App.ps1 -SelfContained -Runtime win-x64
```

完整统计窗口使用 Microsoft Edge WebView2；Windows 11 通常已内置该运行时。

## 源码兼容启动

在此目录打开 PowerShell：

```powershell
.\Start-CodexMeter.ps1
```

浏览器会自动打开 `http://127.0.0.1:43127/`。按 `Ctrl+C` 停止服务。

两个 CMD 启动器会优先调用编译后的 EXE。只有 `dist\CodexMeter\CodexMeter.exe` 不存在时，才退回旧 PowerShell 入口。

如果 PowerShell 阻止本次脚本执行，可用：

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-CodexMeter.ps1
```

可选参数：

```powershell
.\Start-CodexMeter.ps1 -Port 43128 -NoBrowser
.\Start-CodexMeter.ps1 -CodexHome "D:\custom\.codex"
```

## 为什么 ChatGPT 的 5 亿 Token 以前没有被统计

旧版本只扫描当前电脑的 `~/.codex/sessions`，因此只能看到这台电脑仍保留的 JSONL 日志。ChatGPT/Codex 页面显示的是账户端总账，可能包含：

- 其他电脑或 Codex 客户端；
- 云端任务；
- 已清理、未同步或不在本机的历史会话；
- 账户端仍在统计周期内、但本机已经没有逐次调用明细的使用。

新版使用 Codex 官方 app-server 的 `account/usage/read` 读取 `lifetimeTokens` 和 `dailyUsageBuckets`，因此会自动显示账户端的约 5 亿总量。该接口只提供总量，不提供历史输入/输出与模型维度，所以本机日志仍是详细费用计算的必要数据源。

## 统计与费用口径

- 总 Token = `input_tokens + output_tokens`；`reasoning_output_tokens` 已包含在输出中，不重复累加。
- 非缓存输入 = 输入 - 缓存读取 - 缓存写入。
- 缓存写入按非缓存输入单价的 1.25 倍计算。
- 对支持 1.05M 上下文的模型，单次输入超过 272K 时默认按输入 2 倍、输出 1.5 倍计算；可在设置中关闭。
- 费用仅估算标准 API 文本 Token，不含 Web Search、图像生成等工具调用费、区域处理加价、Batch/Flex 折扣、税费或 Codex 订阅费用。
- 账户总量通过本机已有的 Codex 登录只读获取，不读取或保存 OAuth Token；会话明细不上传。
- 费用设置与人民币汇率只保存在浏览器 `localStorage`。
- 费用设置可从 Frankfurter 在线获取最新工作日的 USD/CNY 参考汇率，也可关闭人民币换算并仅保留美元费用；在线汇率不代表银行实时成交价。
- ChatGPT/Codex 订阅用量与 OpenAI API 组织用量是两套账。手工导入 API 用量只会进入本机明细，不会改写 ChatGPT lifetime 总量。

## 合并其他电脑或来源

本机 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 中的 Codex 用量已经自动计算，不需要额外配置。其他电脑只要使用同一个 ChatGPT/Codex 账户，其总量会自动进入账户总账；若还需要那台电脑的输入/输出和费用拆分，再导入其日志。

推荐的多设备同步方式：在详细页面右上角点击“导出”按钮，下载 `codex-meter-设备名-时间.json`。把 JSON 复制到另一台设备，然后运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Import-CodexUsage.ps1
```

选择该 JSON 后，导入器会校验会话 SHA-256、按 `exportId` 和内容指纹防止重复导入，并按稳定会话 ID 合并；相同会话优先保留 Token 更多的完整版本。再次导出的 JSON 会包含当前设备已经合并的会话，因此多台设备可以反复交换数据而不重复计数。

JSON 数据包格式版本为 `schemaVersion: 1`，包含规范化会话、输入/输出/缓存/模型明细、来源口径、账户快照、逐会话 `contentHash` 和全包 `sessionsHash`。不包含 Codex OAuth 凭据。

也可以继续直接导入另一台电脑复制过来的 `.codex` 或 `sessions` 文件夹；在 JSON 文件选择窗口点击取消，然后选择目录即可。

在弹出的窗口中选择复制过来的 `.codex` 文件夹或其中的 `sessions` 文件夹。日志会复制到 `imports/sessions`；相同会话 ID 只保留更完整的文件，因此不会重复计数。

也可以在 [meter.config.json](./meter.config.json) 的 `additionalSessionRoots` 中直接配置其他日志目录，例如：

```json
{
  "additionalSessionRoots": ["D:\\CodexBackup\\.codex\\sessions"]
}
```

对于 OpenAI API、其他客户端或无法取得原始日志的用量，可以编辑 [imports/manual-usage.json](./imports/manual-usage.json)：

```json
{
  "entries": [
    {
      "id": "api-2026-08",
      "date": "2026-08-04T12:00:00+08:00",
      "title": "API 八月汇总",
      "source": "OpenAI API",
      "model": "gpt-5.6-sol",
      "inputTokens": 1000000,
      "cachedInputTokens": 600000,
      "cacheWriteInputTokens": 0,
      "outputTokens": 50000,
      "reasoningOutputTokens": 20000,
      "requests": 20
    }
  ]
}
```

手工记录的 `reasoningOutputTokens` 只是输出 Token 的子集，不会重复计费。

内置单价核对日期：2026-08-04。价格会变化，请以 [OpenAI 模型价格页](https://developers.openai.com/api/docs/models/compare) 为准，或在右上角设置中手动修改。
