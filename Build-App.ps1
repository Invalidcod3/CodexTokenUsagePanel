param(
    [switch]$SelfContained,
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$project = Join-Path $projectRoot 'CodexMeter.App\CodexMeter.App.csproj'
$output = Join-Path $projectRoot 'dist\CodexMeter'
$preservedRuntimeFiles = @(
    'meter.config.json',
    'meter.account-cache.json',
    'meter.identity.json',
    'meter.history.json'
)
$cliHome = Join-Path $projectRoot '.dotnet-home'
$packages = Join-Path $projectRoot '.nuget-packages'

$env:DOTNET_CLI_HOME = $cliHome
$env:NUGET_PACKAGES = $packages
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

if (Get-Process -Name 'CodexMeter' -ErrorAction SilentlyContinue) {
    throw 'Codex Meter is running. Exit it from the tray menu before rebuilding.'
}

$preservedRuntimeData = @{}
foreach ($fileName in $preservedRuntimeFiles) {
    $runtimePath = Join-Path $output $fileName
    if (Test-Path -LiteralPath $runtimePath) {
        $preservedRuntimeData[$fileName] = [IO.File]::ReadAllText($runtimePath, [Text.Encoding]::UTF8)
    }
}

$arguments = @('publish', $project, '-c', 'Release', '-o', $output)
if ($SelfContained) {
    $arguments += @('-r', $Runtime, '--self-contained', 'true')
} else {
    $arguments += @('--self-contained', 'false')
}

Write-Host 'Building Codex Meter...' -ForegroundColor Cyan
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }
foreach ($fileName in $preservedRuntimeData.Keys) {
    [IO.File]::WriteAllText((Join-Path $output $fileName), $preservedRuntimeData[$fileName], [Text.UTF8Encoding]::new($false))
}

Write-Host "`nBuild complete: $output\CodexMeter.exe" -ForegroundColor Green
Write-Host 'You can now launch CodexMeter.exe or Launch-Widget.cmd.'
