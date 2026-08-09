[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64',
    [string]$Version,
    [switch]$FrameworkDependent
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$projectPath = Join-Path $projectRoot 'CodexMeter.App\CodexMeter.App.csproj'
$releaseRoot = Join-Path $projectRoot 'dist\release'
$cliHome = Join-Path $projectRoot '.dotnet-home'
$packages = Join-Path $projectRoot '.nuget-packages'

function Assert-ProjectChildPath {
    param([string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $prefix = $projectRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the project: $resolved"
    }
    return $resolved
}

if (-not (Test-Path -LiteralPath $projectPath)) {
    throw "Project file not found: $projectPath"
}

[xml]$projectXml = Get-Content -LiteralPath $projectPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = [string]$projectXml.Project.PropertyGroup.Version
}
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
    throw 'Version may only contain letters, numbers, dots, underscores, and hyphens.'
}

$packageName = "CodexMeter-$Version-$Runtime"
if ($FrameworkDependent) { $packageName += '-framework-dependent' }
$workRoot = Assert-ProjectChildPath (Join-Path $releaseRoot ('.work-' + [guid]::NewGuid().ToString('N')))
$packageDirectory = Assert-ProjectChildPath (Join-Path $workRoot $packageName)
$zipPath = Assert-ProjectChildPath (Join-Path $releaseRoot ($packageName + '.zip'))
$hashPath = Assert-ProjectChildPath ($zipPath + '.sha256')

$env:DOTNET_CLI_HOME = $cliHome
$env:NUGET_PACKAGES = $packages
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

$requiredFiles = @(
    'CodexMeter.exe',
    'Start-CodexMeter.ps1',
    'Import-CodexUsage.ps1',
    'index.html',
    'app.js',
    'styles.css',
    'meter.config.json',
    'imports\manual-usage.json',
    'imports\devices\README.txt'
)
$privateRuntimeFiles = @(
    'meter.account-cache.json',
    'meter.scan-cache.json',
    'meter.identity.json',
    'meter.history.json'
)

try {
    [void](New-Item -ItemType Directory -Path $packageDirectory -Force)

    $publishArguments = @(
        'publish', $projectPath,
        '-c', 'Release',
        '-r', $Runtime,
        '-o', $packageDirectory,
        '--self-contained', $(if ($FrameworkDependent) { 'false' } else { 'true' }),
        '-p:DebugType=None',
        '-p:DebugSymbols=false'
    )

    Write-Host "Building distribution: $packageName" -ForegroundColor Cyan
    & dotnet @publishArguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    # Always ship neutral defaults, never a user's runtime preferences or imported data.
    Copy-Item -LiteralPath (Join-Path $projectRoot 'meter.config.json') -Destination (Join-Path $packageDirectory 'meter.config.json') -Force
    $importsDirectory = Join-Path $packageDirectory 'imports'
    [void](New-Item -ItemType Directory -Path $importsDirectory -Force)
    Copy-Item -LiteralPath (Join-Path $projectRoot 'imports\manual-usage.json') -Destination (Join-Path $importsDirectory 'manual-usage.json') -Force

    foreach ($privateName in $privateRuntimeFiles) {
        $privatePath = Join-Path $packageDirectory $privateName
        if (Test-Path -LiteralPath $privatePath) { Remove-Item -LiteralPath $privatePath -Force }
    }

    $runtimeRequirement = if ($FrameworkDependent) {
        '- .NET 8 Desktop Runtime.'
    } else {
        '- The .NET runtime is included in this package.'
    }
    $distributionReadme = @"
Codex Meter $Version ($Runtime)

QUICK START
1. Extract the complete folder. Do not copy CodexMeter.exe by itself.
2. Make sure Codex is installed and signed in on this computer.
3. Run CodexMeter.exe. The app remains available in the system tray.

REQUIREMENTS
- 64-bit Windows 10/11 matching the architecture in the package name.
- Microsoft Edge WebView2 Runtime (normally included with Windows 11).
- A working and signed-in Codex installation.
$runtimeRequirement

PRIVACY
- This package excludes the builder's account cache, Codex logs, and imported data.
- Token logs are read only on the computer running the app.
- meter.config.json stores theme and refresh preferences. imports is for optional manual data.
"@
    [IO.File]::WriteAllText((Join-Path $packageDirectory 'README.txt'), $distributionReadme, [Text.UTF8Encoding]::new($true))

    foreach ($relativePath in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageDirectory $relativePath))) {
            throw "Distribution is missing required file: $relativePath"
        }
    }
    $packagedPrivateFiles = @(Get-ChildItem -LiteralPath $packageDirectory -Recurse -File | Where-Object { $_.Name -in $privateRuntimeFiles })
    if ($packagedPrivateFiles.Count -gt 0) {
        throw "Distribution unexpectedly contains private runtime data: $($packagedPrivateFiles.Name -join ', ')"
    }

    [void](New-Item -ItemType Directory -Path $releaseRoot -Force)
    foreach ($oldArtifact in @($zipPath, $hashPath)) {
        if (Test-Path -LiteralPath $oldArtifact) { Remove-Item -LiteralPath $oldArtifact -Force }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $packageDirectory,
        $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )

    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entryNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('/', '\') })
        foreach ($relativePath in $requiredFiles) {
            $expected = "$packageName\$relativePath"
            if ($entryNames -notcontains $expected) { throw "ZIP validation failed: $relativePath" }
        }
        $privateEntries = @($entryNames | Where-Object { [IO.Path]::GetFileName($_) -in $privateRuntimeFiles })
        if ($privateEntries.Count -gt 0) {
            throw "ZIP validation failed: private runtime data is present: $($privateEntries -join ', ')"
        }
    } finally {
        $zip.Dispose()
    }

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($hashPath, "$hash  $([IO.Path]::GetFileName($zipPath))`r`n", [Text.UTF8Encoding]::new($false))

    $sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
    Write-Host ''
    Write-Host 'Distribution ready' -ForegroundColor Green
    Write-Host "ZIP:    $zipPath"
    Write-Host "SHA256: $hashPath"
    Write-Host "Size:   $sizeMb MB"
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        $verifiedWorkRoot = Assert-ProjectChildPath $workRoot
        Remove-Item -LiteralPath $verifiedWorkRoot -Recurse -Force
    }
}
