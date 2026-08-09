其他设备数据的结构化归档目录

目录结构：
  imports\devices\<设备码>\sessions\         原始 Codex JSONL 会话
  imports\devices\<设备码>\session-indexes\  可选的 session_index.jsonl
  imports\devices\<设备码>\bundles\          Codex Meter JSON 导出包

推荐使用 Import-CodexUsage.ps1 导入。它会读取导出包内的 deviceCode，
并自动归档到对应设备目录；导入原始 .codex 文件夹时，也可显式指定：

  .\Import-CodexUsage.ps1 -Source "D:\Backup\.codex" -DeviceCode "DEV-1234-5678-9ABC"

旧目录 imports\sessions、imports\session-indexes 和 imports\bundles 仍会继续读取。
