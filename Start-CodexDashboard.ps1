[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 43127
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$meterScript = Join-Path $scriptRoot 'Start-CodexMeter.ps1'
$baseUrl = "http://127.0.0.1:$Port/"

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

if (Test-MeterServer) {
    Write-Host "Codex Token Meter 已在运行：$baseUrl" -ForegroundColor Green
    Start-Process $baseUrl
    exit 0
}

if (Test-PortOpen) {
    throw "端口 $Port 已被其他程序占用，并且不是 Codex Token Meter。请关闭占用程序，或运行 .\Start-CodexDashboard.ps1 -Port 43128。"
}

& $meterScript -Port $Port
