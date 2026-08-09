[CmdletBinding()]
param([string]$Source)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$importsRoot = Join-Path $scriptRoot 'imports'
$targetRoot = Join-Path $importsRoot 'sessions'
$indexRoot = Join-Path $importsRoot 'session-indexes'
$bundlesRoot = Join-Path $importsRoot 'bundles'

function Get-TextSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-PortableSessionCore {
    param($Session)
    [ordered]@{
        id = [string]$Session.id
        title = [string]$Session.title
        project = [string]$Session.project
        origin = [string]$Session.origin
        sourceLabel = [string]$Session.sourceLabel
        accountComparable = [bool]$Session.accountComparable
        startedAt = $Session.startedAt
        endedAt = $Session.endedAt
        localDate = [string]$Session.localDate
        durationSeconds = [long]$Session.durationSeconds
        efforts = @($Session.efforts)
        usage = $Session.usage
        models = @($Session.models)
    }
}

function Import-PortableJson {
    param([string]$Path)
    $bundle = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($bundle.kind -ne 'codex-token-meter-export' -or [int]$bundle.schemaVersion -ne 1) {
        throw 'This JSON file is not a supported Codex Token Meter export.'
    }
    if (-not $bundle.exportId) { throw 'The export is missing exportId.' }

    $sessionHashes = New-Object System.Collections.ArrayList
    foreach ($session in @($bundle.sessions)) {
        if (-not $session.id -or -not $session.contentHash) { throw 'A session is missing its stable ID or checksum.' }
        $core = ConvertTo-PortableSessionCore $session
        $actual = Get-TextSha256 ($core | ConvertTo-Json -Depth 14 -Compress)
        if ($actual -ne [string]$session.contentHash) { throw "Checksum mismatch for session $($session.id)." }
        [void]$sessionHashes.Add($actual)
    }
    $bundleHash = Get-TextSha256 (@($sessionHashes) -join '|')
    if ($bundle.sessionsHash -and $bundleHash -ne [string]$bundle.sessionsHash) { throw 'The export-level checksum does not match.' }

    [void](New-Item -ItemType Directory -Path $bundlesRoot -Force)
    foreach ($existingFile in @(Get-ChildItem -LiteralPath $bundlesRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $existingBundle = Get-Content -LiteralPath $existingFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existingBundle.sessionsHash -and [string]$existingBundle.sessionsHash -eq $bundleHash) {
                Write-Host "An export with the same session content was already imported: $($existingBundle.exportId)" -ForegroundColor Yellow
                return
            }
        } catch {}
    }
    $safeId = [regex]::Replace([string]$bundle.exportId, '[^a-zA-Z0-9-]', '')
    $destination = Join-Path $bundlesRoot ("bundle-$safeId.json")
    if (Test-Path -LiteralPath $destination) {
        $sourceHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($sourceHash -eq $destinationHash) {
            Write-Host "This export was already imported: $($bundle.exportId)" -ForegroundColor Yellow
            return
        }
        throw "A different file with exportId $($bundle.exportId) was already imported."
    }
    Copy-Item -LiteralPath $Path -Destination $destination
    Write-Host "Imported JSON export from $($bundle.device.name): $(@($bundle.sessions).Count) sessions." -ForegroundColor Green
    Write-Host 'Refresh the Token Meter; duplicate session IDs will be merged automatically.' -ForegroundColor Cyan
}

if (-not $Source) {
    Add-Type -AssemblyName System.Windows.Forms
    $filePicker = New-Object System.Windows.Forms.OpenFileDialog
    $filePicker.Title = 'Select a Codex Token Meter JSON export (Cancel to choose a .codex folder)'
    $filePicker.Filter = 'Codex Token Meter export (*.json)|*.json|All files (*.*)|*.*'
    if ($filePicker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Source = $filePicker.FileName
    } else {
        $folderPicker = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderPicker.Description = 'Select a .codex folder or its sessions folder'
        $folderPicker.ShowNewFolderButton = $false
        if ($folderPicker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $Source = $folderPicker.SelectedPath
    }
}

$resolvedSource = (Resolve-Path -LiteralPath $Source).Path
if (Test-Path -LiteralPath $resolvedSource -PathType Leaf) {
    if ([IO.Path]::GetExtension($resolvedSource) -ne '.json') { throw 'Only Codex Token Meter JSON exports can be imported as files.' }
    Import-PortableJson $resolvedSource
    return
}

$sessionsSource = if ((Split-Path -Leaf $resolvedSource) -eq 'sessions') { $resolvedSource } else { Join-Path $resolvedSource 'sessions' }
if (-not (Test-Path -LiteralPath $sessionsSource)) { throw "No sessions folder found under: $resolvedSource" }

[void](New-Item -ItemType Directory -Path $targetRoot -Force)
[void](New-Item -ItemType Directory -Path $indexRoot -Force)
$copied = 0
foreach ($file in @(Get-ChildItem -LiteralPath $sessionsSource -Recurse -Filter '*.jsonl' -File)) {
    $destination = Join-Path $targetRoot $file.Name
    if (-not (Test-Path -LiteralPath $destination) -or $file.Length -gt (Get-Item -LiteralPath $destination).Length) {
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $copied++
    }
}

$codexRoot = if ((Split-Path -Leaf $resolvedSource) -eq 'sessions') { Split-Path -Parent $resolvedSource } else { $resolvedSource }
$indexSource = Join-Path $codexRoot 'session_index.jsonl'
if (Test-Path -LiteralPath $indexSource) {
    $indexDestination = Join-Path $indexRoot ("session-index-" + [guid]::NewGuid().ToString('N') + '.jsonl')
    Copy-Item -LiteralPath $indexSource -Destination $indexDestination
}

Write-Host "Imported or updated $copied session log files." -ForegroundColor Green
Write-Host 'Refresh the Token Meter to include them.' -ForegroundColor Cyan
