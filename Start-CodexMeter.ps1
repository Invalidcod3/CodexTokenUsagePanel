[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 43127,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sessionsRoot = Join-Path $CodexHome 'sessions'
$archivedSessionsRoot = Join-Path $CodexHome 'archived_sessions'
$sessionIndexPath = Join-Path $CodexHome 'session_index.jsonl'
$importsRoot = Join-Path $scriptRoot 'imports'
$importedSessionsRoot = Join-Path $importsRoot 'sessions'
$bundlesRoot = Join-Path $importsRoot 'bundles'
$importedDevicesRoot = Join-Path $importsRoot 'devices'
$configPath = Join-Path $scriptRoot 'meter.config.json'
$accountLiveStatePath = Join-Path $scriptRoot 'meter.account-cache.json'
$identityPath = Join-Path $scriptRoot 'meter.identity.json'
$historyPath = Join-Path $scriptRoot 'meter.history.json'
$script:accountSnapshot = $null
$script:accountSnapshotExpiresAt = [datetimeoffset]::MinValue
$script:accountLiveSnapshotFetchedAt = ''
$script:accountLiveBaseTokens = [long]0
$script:accountLiveLocalBaselineTokens = [long]0
$script:accountLiveLifetimeTokens = [long]0
$script:accountLiveAccountKey = ''
$script:deviceIdentity = $null
$script:sessionParseCache = @{}
$script:threadNameCache = $null

if (Test-Path -LiteralPath $accountLiveStatePath) {
    try {
        $storedLiveState = Get-Content -LiteralPath $accountLiveStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:accountLiveSnapshotFetchedAt = [string]$storedLiveState.snapshotFetchedAt
        $script:accountLiveBaseTokens = [long]$storedLiveState.baseTokens
        $script:accountLiveLocalBaselineTokens = [long]$storedLiveState.localBaselineTokens
        $script:accountLiveLifetimeTokens = [long]$storedLiveState.liveLifetimeTokens
        $script:accountLiveAccountKey = [string]$storedLiveState.accountKey
    } catch {}
}

function Get-MeterConfig {
    $additionalRoots = @()
    $refreshSeconds = [double]15
    $themeAccent = '#B8FF34'
    $themeBackground = '#090B0D'
    $themePanel = '#131619'
    $themeText = '#F3F6F4'
    $themeMuted = '#8A9290'
    $themeSecondary = '#9D84EF'
    $numberUnitStyle = 'international'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $stored = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $additionalRoots = @($stored.additionalSessionRoots)
            if ($null -ne $stored.refreshIntervalSeconds) { $refreshSeconds = [double]$stored.refreshIntervalSeconds }
            if ([string]$stored.themeAccent -match '^#[0-9a-fA-F]{6}$') { $themeAccent = ([string]$stored.themeAccent).ToUpperInvariant() }
            if ([string]$stored.themeBackground -match '^#[0-9a-fA-F]{6}$') { $themeBackground = ([string]$stored.themeBackground).ToUpperInvariant() }
            if ([string]$stored.themePanel -match '^#[0-9a-fA-F]{6}$') { $themePanel = ([string]$stored.themePanel).ToUpperInvariant() }
            if ([string]$stored.themeText -match '^#[0-9a-fA-F]{6}$') { $themeText = ([string]$stored.themeText).ToUpperInvariant() }
            if ([string]$stored.themeMuted -match '^#[0-9a-fA-F]{6}$') { $themeMuted = ([string]$stored.themeMuted).ToUpperInvariant() }
            if ([string]$stored.themeSecondary -match '^#[0-9a-fA-F]{6}$') { $themeSecondary = ([string]$stored.themeSecondary).ToUpperInvariant() }
            if ([string]$stored.numberUnitStyle -in @('international', 'chinese')) { $numberUnitStyle = [string]$stored.numberUnitStyle }
        } catch {}
    }
    $refreshSeconds = [math]::Min([double]3600, [math]::Max([double]0.5, [double]$refreshSeconds))
    [pscustomobject][ordered]@{
        additionalSessionRoots = $additionalRoots
        refreshIntervalSeconds = $refreshSeconds
        themeAccent = $themeAccent
        themeBackground = $themeBackground
        themePanel = $themePanel
        themeText = $themeText
        themeMuted = $themeMuted
        themeSecondary = $themeSecondary
        numberUnitStyle = $numberUnitStyle
    }
}

function Set-MeterRefreshInterval {
    param([double]$Seconds)
    $config = Get-MeterConfig
    $seconds = [math]::Min([double]3600, [math]::Max([double]0.5, [double]$Seconds))
    $updated = [pscustomobject][ordered]@{
        additionalSessionRoots = @($config.additionalSessionRoots)
        refreshIntervalSeconds = $seconds
        themeAccent = $config.themeAccent
        themeBackground = $config.themeBackground
        themePanel = $config.themePanel
        themeText = $config.themeText
        themeMuted = $config.themeMuted
        themeSecondary = $config.themeSecondary
        numberUnitStyle = $config.numberUnitStyle
    }
    $json = $updated | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($configPath, $json, [Text.UTF8Encoding]::new($false))
    return $updated
}

function Set-MeterTheme {
    param([string]$Accent, [string]$Background, [string]$Panel, [string]$Text, [string]$Muted, [string]$Secondary)
    foreach ($color in @($Accent, $Background, $Panel, $Text, $Muted, $Secondary)) {
        if ($color -notmatch '^#[0-9a-fA-F]{6}$') { throw 'Theme colors must use #RRGGBB.' }
    }
    $config = Get-MeterConfig
    $updated = [pscustomobject][ordered]@{
        additionalSessionRoots = @($config.additionalSessionRoots)
        refreshIntervalSeconds = [double]$config.refreshIntervalSeconds
        themeAccent = $Accent.ToUpperInvariant()
        themeBackground = $Background.ToUpperInvariant()
        themePanel = $Panel.ToUpperInvariant()
        themeText = $Text.ToUpperInvariant()
        themeMuted = $Muted.ToUpperInvariant()
        themeSecondary = $Secondary.ToUpperInvariant()
        numberUnitStyle = $config.numberUnitStyle
    }
    $json = $updated | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($configPath, $json, [Text.UTF8Encoding]::new($false))
    return $updated
}

function Set-MeterUnitStyle {
    param([string]$Style)
    if ($Style -notin @('international', 'chinese')) { throw 'Unsupported number unit style.' }
    $config = Get-MeterConfig
    $updated = [pscustomobject][ordered]@{
        additionalSessionRoots = @($config.additionalSessionRoots)
        refreshIntervalSeconds = [double]$config.refreshIntervalSeconds
        themeAccent = $config.themeAccent
        themeBackground = $config.themeBackground
        themePanel = $config.themePanel
        themeText = $config.themeText
        themeMuted = $config.themeMuted
        themeSecondary = $config.themeSecondary
        numberUnitStyle = $Style
    }
    [IO.File]::WriteAllText($configPath, ($updated | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    return $updated
}

function Resolve-CodexExecutable {
    $candidates = @(
        (Join-Path $CodexHome '.sandbox-bin\codex.exe'),
        (Join-Path $CodexHome 'plugins\.plugin-appserver\codex.exe')
    )
    try {
        $command = Get-Command codex.exe -ErrorAction Stop
        if ($command.Path) { $candidates += $command.Path }
    } catch {}

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

function Invoke-CodexAccountSnapshot {
    $codexExe = Resolve-CodexExecutable
    if (-not $codexExe) { throw 'Could not locate codex.exe for account usage sync.' }

    $process = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $codexExe
        $startInfo.Arguments = 'app-server --stdio'
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Could not start Codex app-server.' }

        $initialize = [ordered]@{
            id = 1
            method = 'initialize'
            params = [ordered]@{
                clientInfo = [ordered]@{ name = 'codex-token-meter'; title = 'Codex Token Meter'; version = '0.2.0' }
                capabilities = [ordered]@{ experimentalApi = $true }
            }
        } | ConvertTo-Json -Compress -Depth 8
        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.Flush()

        $usageResponse = $null
        $rateResponse = $null
        $requestsSent = $false
        $deadline = [datetimeoffset]::Now.AddSeconds(15)

        while ([datetimeoffset]::Now -lt $deadline -and -not $process.HasExited) {
            $remainingMs = [math]::Max(1, [int]($deadline - [datetimeoffset]::Now).TotalMilliseconds)
            $readTask = $process.StandardOutput.ReadLineAsync()
            if (-not $readTask.Wait($remainingMs)) { throw 'Timed out while reading Codex account usage.' }
            $line = $readTask.Result
            if ($null -eq $line) { break }
            try { $message = $line | ConvertFrom-Json } catch { continue }

            if ($message.id -eq 1 -and -not $requestsSent) {
                if ($message.error) { throw [string]$message.error.message }
                foreach ($request in @(
                    [ordered]@{ id = 2; method = 'account/usage/read'; params = $null },
                    [ordered]@{ id = 3; method = 'account/rateLimits/read'; params = $null }
                )) {
                    $process.StandardInput.WriteLine(($request | ConvertTo-Json -Compress -Depth 5))
                }
                $process.StandardInput.Flush()
                $requestsSent = $true
                continue
            }
            if ($message.id -eq 2) { $usageResponse = $message }
            if ($message.id -eq 3) { $rateResponse = $message }
            if ($null -ne $usageResponse -and $null -ne $rateResponse) { break }
        }

        if ($null -eq $usageResponse) { throw 'Codex account usage did not return a response.' }
        if ($usageResponse.error) { throw [string]$usageResponse.error.message }

        [pscustomobject][ordered]@{
            available = $true
            fetchedAt = [datetimeoffset]::Now.ToString('o')
            source = 'codex-app-server'
            summary = $usageResponse.result.summary
            dailyUsageBuckets = @($usageResponse.result.dailyUsageBuckets)
            rateLimits = if ($null -ne $rateResponse -and -not $rateResponse.error) { $rateResponse.result.rateLimits } else { $null }
            identityRaw = $null
            error = $null
        }
    } finally {
        if ($null -ne $process) {
            try { $process.StandardInput.Close() } catch {}
            try {
                if (-not $process.WaitForExit(1000)) { $process.Kill() }
            } catch {}
            try { $process.Dispose() } catch {}
        }
    }
}

function Get-CodexAccountSnapshot {
    if ($null -ne $script:accountSnapshot -and [datetimeoffset]::Now -lt $script:accountSnapshotExpiresAt) {
        return $script:accountSnapshot
    }
    try {
        $script:accountSnapshot = Invoke-CodexAccountSnapshot
        $accountRefreshSeconds = [math]::Max([double]30, [double](Get-MeterConfig).refreshIntervalSeconds)
        $script:accountSnapshotExpiresAt = [datetimeoffset]::Now.AddSeconds($accountRefreshSeconds)
    } catch {
        $script:accountSnapshot = [pscustomobject][ordered]@{
            available = $false
            fetchedAt = [datetimeoffset]::Now.ToString('o')
            source = 'codex-app-server'
            summary = $null
            dailyUsageBuckets = @()
            rateLimits = $null
            identityRaw = $null
            error = $_.Exception.Message
        }
        $script:accountSnapshotExpiresAt = [datetimeoffset]::Now.AddSeconds(30)
    }
    return $script:accountSnapshot
}

function Get-DeviceIdentity {
    if ($null -ne $script:deviceIdentity) { return $script:deviceIdentity }
    if (Test-Path -LiteralPath $identityPath) {
        try {
            $stored = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$stored.deviceId -match '^[0-9a-fA-F-]{36}$') { $script:deviceIdentity = $stored }
        } catch {}
    }
    if ($null -eq $script:deviceIdentity) {
        $deviceId = [guid]::NewGuid().ToString('D')
        $deviceHash = Get-TextSha256 ("device|$deviceId")
        $script:deviceIdentity = [pscustomobject][ordered]@{
            deviceId = $deviceId
            deviceCode = ('DEV-' + $deviceHash.Substring(0, 4) + '-' + $deviceHash.Substring(4, 4) + '-' + $deviceHash.Substring(8, 4)).ToUpperInvariant()
            name = [string]$env:COMPUTERNAME
            platform = 'windows'
            createdAt = [datetimeoffset]::Now.ToString('o')
        }
        [IO.File]::WriteAllText($identityPath, ($script:deviceIdentity | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    return $script:deviceIdentity
}

function Get-AccountIdentity {
    param($Account)
    $raw = $Account.identityRaw
    $type = if ($raw -and $raw.type) { [string]$raw.type } else { 'unknown' }
    $plan = if ($raw -and $raw.planType) { [string]$raw.planType } elseif ($raw -and $raw.plan) { [string]$raw.plan } else { '' }
    $email = if ($raw -and $raw.email) { ([string]$raw.email).Trim().ToLowerInvariant() } else { '' }
    $rawId = if ($raw -and $raw.id) { [string]$raw.id } elseif ($raw -and $raw.accountId) { [string]$raw.accountId } else { $email }
    if (-not $rawId) {
        # Read only the stable account id metadata from auth.json; credentials are never retained
        # in memory, cached, returned by the API, or included in an export.
        $authPath = Join-Path $CodexHome 'auth.json'
        if (Test-Path -LiteralPath $authPath) {
            try {
                $authMetadata = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($authMetadata.tokens -and $authMetadata.tokens.account_id) { $rawId = [string]$authMetadata.tokens.account_id }
                if ($type -eq 'unknown' -and $authMetadata.auth_mode) { $type = [string]$authMetadata.auth_mode }
            } catch {}
        }
    }
    $keySource = if ($rawId) { "$type|$rawId" } else { "$type|unidentified" }
    $hash = Get-TextSha256 ("account|$keySource")
    $maskedEmail = ''
    if ($email -match '^(.)([^@]*)@(.+)$') {
        $maskedEmail = $matches[1] + ('*' * [math]::Min(6, [math]::Max(3, $matches[2].Length))) + '@' + $matches[3]
    }
    [pscustomobject][ordered]@{
        accountKey = 'acct-' + $hash.Substring(0, 24)
        type = $type
        plan = $plan
        emailMasked = $maskedEmail
        emailHash = if ($email) { Get-TextSha256 ("email|$email") } else { '' }
    }
}

function Get-LiveAccountLifetime {
    param($Account, [long]$ComparableTokens, [string]$AccountKey)
    if (-not $Account.available -or $null -eq $Account.summary -or $null -eq $Account.summary.lifetimeTokens) {
        return [long]0
    }

    $serverTokens = [long]$Account.summary.lifetimeTokens
    if ($script:accountLiveAccountKey -ne $AccountKey) {
        $script:accountLiveAccountKey = $AccountKey
        $script:accountLiveSnapshotFetchedAt = ''
        $script:accountLiveBaseTokens = $serverTokens
        $script:accountLiveLocalBaselineTokens = $ComparableTokens
        $script:accountLiveLifetimeTokens = $serverTokens
    }
    $previousLiveTokens = $script:accountLiveLifetimeTokens
    $snapshotFetchedAt = [string]$Account.fetchedAt
    $snapshotChanged = $snapshotFetchedAt -ne $script:accountLiveSnapshotFetchedAt
    if ($snapshotChanged) {
        # A newly fetched account total becomes the next reconciliation anchor. Keep the
        # already displayed live total monotonic when the account endpoint is slightly behind.
        $script:accountLiveSnapshotFetchedAt = $snapshotFetchedAt
        $script:accountLiveBaseTokens = [long][math]::Max($serverTokens, $script:accountLiveLifetimeTokens)
        $script:accountLiveLocalBaselineTokens = $ComparableTokens
    }

    $localDelta = [long][math]::Max(0, $ComparableTokens - $script:accountLiveLocalBaselineTokens)
    $candidate = [long]($script:accountLiveBaseTokens + $localDelta)
    $script:accountLiveLifetimeTokens = [long][math]::Max($serverTokens, [math]::Max($candidate, $script:accountLiveLifetimeTokens))
    if ($snapshotChanged -or $script:accountLiveLifetimeTokens -ne $previousLiveTokens) {
        try {
            $state = [pscustomobject][ordered]@{
                accountKey = $script:accountLiveAccountKey
                snapshotFetchedAt = $script:accountLiveSnapshotFetchedAt
                baseTokens = $script:accountLiveBaseTokens
                localBaselineTokens = $script:accountLiveLocalBaselineTokens
                liveLifetimeTokens = $script:accountLiveLifetimeTokens
                savedAt = [datetimeoffset]::Now.ToString('o')
            }
            [IO.File]::WriteAllText($accountLiveStatePath, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        } catch {}
    }
    return $script:accountLiveLifetimeTokens
}

function New-UsageCounter {
    [ordered]@{
        inputTokens = [long]0
        cachedInputTokens = [long]0
        cacheWriteInputTokens = [long]0
        outputTokens = [long]0
        reasoningOutputTokens = [long]0
        totalTokens = [long]0
        longInputTokens = [long]0
        longCachedInputTokens = [long]0
        longCacheWriteInputTokens = [long]0
        longOutputTokens = [long]0
        requests = [long]0
        longRequests = [long]0
    }
}

function Add-Usage {
    param($Target, $Usage, [bool]$IsLongContext)

    $inputTokens = [long]$Usage.input_tokens
    $cachedTokens = [long]$Usage.cached_input_tokens
    $cacheWriteTokens = [long]$Usage.cache_write_input_tokens
    $outputTokens = [long]$Usage.output_tokens
    $reasoningTokens = [long]$Usage.reasoning_output_tokens

    $Target.inputTokens += $inputTokens
    $Target.cachedInputTokens += $cachedTokens
    $Target.cacheWriteInputTokens += $cacheWriteTokens
    $Target.outputTokens += $outputTokens
    $Target.reasoningOutputTokens += $reasoningTokens
    $Target.totalTokens += ($inputTokens + $outputTokens)
    $Target.requests += 1

    if ($IsLongContext) {
        $Target.longInputTokens += $inputTokens
        $Target.longCachedInputTokens += $cachedTokens
        $Target.longCacheWriteInputTokens += $cacheWriteTokens
        $Target.longOutputTokens += $outputTokens
        $Target.longRequests += 1
    }
}

function Add-Counter {
    param($Target, $Source)
    foreach ($key in @($Target.Keys)) {
        if ($null -ne $Source.$key) { $Target[$key] += [long]$Source.$key }
    }
}

function Get-TextSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Merge-MaxUsageCounter {
    param($Existing, $Current)
    $merged = New-UsageCounter
    foreach ($key in @($merged.Keys)) {
        $oldValue = if ($null -ne $Existing -and $null -ne $Existing.$key) { [long]$Existing.$key } else { [long]0 }
        $newValue = if ($null -ne $Current -and $null -ne $Current.$key) { [long]$Current.$key } else { [long]0 }
        $merged[$key] = [long][math]::Max($oldValue, $newValue)
    }
    return [pscustomobject]$merged
}

function Update-HistoryCache {
    param($Sessions, $Account, $AccountIdentity, $DeviceIdentity)

    $currentDaily = @{}
    foreach ($session in @($Sessions)) {
        $dailyRows = @($session.dailyUsage)
        if ($dailyRows.Count -eq 0 -and $session.localDate) {
            $dailyRows = @([pscustomobject][ordered]@{ date = [string]$session.localDate; usage = $session.usage })
        }
        foreach ($row in $dailyRows) {
            $date = [string]$row.date
            if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or $null -eq $row.usage) { continue }
            if (-not $currentDaily.ContainsKey($date)) { $currentDaily[$date] = New-UsageCounter }
            Add-Counter $currentDaily[$date] $row.usage
        }
    }

    $existingAccounts = @()
    if (Test-Path -LiteralPath $historyPath) {
        try {
            $stored = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$stored.schemaVersion -eq 1) { $existingAccounts = @($stored.accounts) }
        } catch {}
    }

    $accountKey = [string]$AccountIdentity.accountKey
    $existingAccount = @($existingAccounts | Where-Object { [string]$_.account.accountKey -eq $accountKey } | Select-Object -First 1)
    $dayMap = @{}
    if ($existingAccount.Count) {
        foreach ($day in @($existingAccount[0].days)) {
            if ([string]$day.date -match '^\d{4}-\d{2}-\d{2}$') { $dayMap[[string]$day.date] = $day }
        }
    }

    $now = [datetimeoffset]::Now
    $todayKey = $now.ToLocalTime().ToString('yyyy-MM-dd')
    foreach ($date in @($currentDaily.Keys)) {
        $existing = $dayMap[$date]
        $dayMap[$date] = [pscustomobject][ordered]@{
            date = $date
            accountTokens = if ($null -ne $existing) { [long]$existing.accountTokens } else { [long]0 }
            localUsage = Merge-MaxUsageCounter $(if ($null -ne $existing) { $existing.localUsage } else { $null }) ([pscustomobject]$currentDaily[$date])
            complete = $date -lt $todayKey
            updatedAt = $now.ToString('o')
        }
    }

    foreach ($bucket in @($Account.dailyUsageBuckets)) {
        $date = [string]$bucket.startDate
        if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        $existing = $dayMap[$date]
        $dayMap[$date] = [pscustomobject][ordered]@{
            date = $date
            accountTokens = [long][math]::Max($(if ($null -ne $existing) { [long]$existing.accountTokens } else { [long]0 }), [long]$bucket.tokens)
            localUsage = if ($null -ne $existing) { $existing.localUsage } else { [pscustomobject](New-UsageCounter) }
            complete = $date -lt $todayKey
            updatedAt = $now.ToString('o')
        }
    }

    $deviceMap = @{}
    if ($existingAccount.Count) {
        foreach ($device in @($existingAccount[0].devices)) {
            if ($device.deviceId) { $deviceMap[[string]$device.deviceId] = $device }
        }
    }
    $deviceMap[[string]$DeviceIdentity.deviceId] = [pscustomobject][ordered]@{
        deviceId = $DeviceIdentity.deviceId
        deviceCode = $DeviceIdentity.deviceCode
        name = $DeviceIdentity.name
        platform = $DeviceIdentity.platform
        lastSeenAt = $now.ToString('o')
    }

    $days = @($dayMap.Keys | Sort-Object | ForEach-Object { $dayMap[$_] })
    $accountRecord = [pscustomobject][ordered]@{
        account = $AccountIdentity
        devices = @($deviceMap.Values | Sort-Object deviceCode)
        firstDate = if ($days.Count) { [string]$days[0].date } else { '' }
        lastDate = if ($days.Count) { [string]$days[-1].date } else { '' }
        days = $days
        updatedAt = $now.ToString('o')
    }
    $accounts = @($existingAccounts | Where-Object { [string]$_.account.accountKey -ne $accountKey }) + @($accountRecord)
    $store = [pscustomobject][ordered]@{
        kind = 'codex-token-meter-history-cache'
        schemaVersion = 1
        updatedAt = $now.ToString('o')
        accounts = $accounts
    }
    [IO.File]::WriteAllText($historyPath, ($store | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    return [pscustomobject][ordered]@{
        account = $AccountIdentity
        device = $DeviceIdentity
        firstDate = $accountRecord.firstDate
        lastDate = $accountRecord.lastDate
        days = $days
        updatedAt = $accountRecord.updatedAt
    }
}

function ConvertTo-PortableSessionCore {
    param($Session)
    $comparable = if ($null -ne $Session.accountComparable) { [bool]$Session.accountComparable } else { $Session.source -ne 'manual' }
    $core = [ordered]@{
        id = [string]$Session.id
        title = [string]$Session.title
        project = [string]$Session.project
        origin = [string]$Session.origin
        sourceLabel = [string]$Session.sourceLabel
        accountComparable = $comparable
        startedAt = $Session.startedAt
        endedAt = $Session.endedAt
        localDate = [string]$Session.localDate
        durationSeconds = [long]$Session.durationSeconds
        efforts = @($Session.efforts)
        usage = $Session.usage
        models = @($Session.models)
    }
    if ($null -ne $Session.dailyUsage) { $core.dailyUsage = @($Session.dailyUsage) }
    return $core
}

function Convert-ModelsToArray {
    param($ModelMap)
    @($ModelMap.GetEnumerator() | ForEach-Object {
        $row = [ordered]@{ model = $_.Key }
        foreach ($key in $_.Value.Keys) { $row[$key] = $_.Value[$key] }
        [pscustomobject]$row
    } | Sort-Object -Property @{ Expression = { $_.totalTokens }; Descending = $true })
}

function Get-ThreadNames {
    $indexFiles = @()
    if (Test-Path -LiteralPath $sessionIndexPath) { $indexFiles += Get-Item -LiteralPath $sessionIndexPath }
    $importedIndexes = Join-Path $importsRoot 'session-indexes'
    if (Test-Path -LiteralPath $importedIndexes) { $indexFiles += Get-ChildItem -LiteralPath $importedIndexes -Filter '*.jsonl' -File }
    if (Test-Path -LiteralPath $importedDevicesRoot) {
        $indexFiles += Get-ChildItem -LiteralPath $importedDevicesRoot -Recurse -Filter '*.jsonl' -File |
            Where-Object { $_.Directory.Name -eq 'session-indexes' }
    }

    $signature = @($indexFiles | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
    if ($null -ne $script:threadNameCache -and $script:threadNameCache.signature -eq $signature) {
        return $script:threadNameCache.names
    }

    $names = @{}
    foreach ($indexFile in $indexFiles) {
        Get-Content -LiteralPath $indexFile.FullName -Encoding UTF8 | ForEach-Object {
            try {
                $item = $_ | ConvertFrom-Json
                if ($item.id -and $item.thread_name) { $names[[string]$item.id] = [string]$item.thread_name }
            } catch {}
        }
    }
    $script:threadNameCache = [pscustomobject]@{ signature = $signature; names = $names }
    return $names
}

function Get-SessionCandidates {
    $roots = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $sessionsRoot) {
        [void]$roots.Add([pscustomobject]@{ path = $sessionsRoot; source = 'local'; label = 'This computer' })
    }
    if (Test-Path -LiteralPath $archivedSessionsRoot) {
        [void]$roots.Add([pscustomobject]@{ path = $archivedSessionsRoot; source = 'local-archive'; label = 'This computer (archived)' })
    }
    if (Test-Path -LiteralPath $importedSessionsRoot) {
        [void]$roots.Add([pscustomobject]@{ path = $importedSessionsRoot; source = 'imported'; label = 'Imported devices' })
    }
    if (Test-Path -LiteralPath $importedDevicesRoot) {
        foreach ($deviceDirectory in @(Get-ChildItem -LiteralPath $importedDevicesRoot -Directory -ErrorAction SilentlyContinue)) {
            $deviceSessions = Join-Path $deviceDirectory.FullName 'sessions'
            if (Test-Path -LiteralPath $deviceSessions) {
                $deviceCode = [string]$deviceDirectory.Name
                [void]$roots.Add([pscustomobject]@{
                    path = $deviceSessions
                    source = 'device:' + $deviceCode
                    label = 'Other device · ' + $deviceCode
                })
            }
        }
    }
    $config = Get-MeterConfig
    foreach ($extraRoot in @($config.additionalSessionRoots)) {
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$extraRoot)
        if (Test-Path -LiteralPath $expanded) {
            $leaf = Split-Path -Leaf (Split-Path -Parent $expanded)
            [void]$roots.Add([pscustomobject]@{ path = $expanded; source = 'additional'; label = if ($leaf) { $leaf } else { 'Additional source' } })
        }
    }

    $bySession = @{}
    foreach ($root in $roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root.path -Recurse -Filter '*.jsonl' -File)) {
            $key = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($key -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { $key = $Matches[1] }
            if (-not $bySession.ContainsKey($key) -or $file.Length -gt $bySession[$key].file.Length) {
                $bySession[$key] = [pscustomobject]@{ file = $file; source = $root.source; label = $root.label }
            }
        }
    }
    return @($bySession.Values)
}

function New-SessionParseState {
    param($Candidate)
    $file = $Candidate.file
    $sessionId = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    if ($sessionId -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { $sessionId = $Matches[1] }
    [ordered]@{
        path = $file.FullName
        offset = [long]0
        observedLength = [long]0
        creationUtcTicks = [long]$file.CreationTimeUtc.Ticks
        lastWriteUtcTicks = [long]0
        boundaryHash = ''
        pendingText = ''
        source = $Candidate.source
        sourceLabel = $Candidate.label
        sessionId = $sessionId
        currentModel = 'unknown'
        efforts = @{}
        cwd = ''
        origin = ''
        firstUserMessage = ''
        startedAt = $null
        endedAt = $null
        usage = New-UsageCounter
        models = @{}
        dailyUsage = @{}
        dailyModels = @{}
        badLines = [long]0
        lastReadBytes = [long]0
        cacheHit = $false
        latestRateLimit = $null
        latestRateLimitAt = [datetimeoffset]::MinValue
    }
}

function Get-FileBoundaryHash {
    param([string]$Path, [long]$EndOffset)
    if ($EndOffset -le 0) { return '' }
    $stream = $null
    $sha = $null
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
        $end = [math]::Min([long]$EndOffset, [long]$stream.Length)
        $headLength = [int][math]::Min([long]128, $end)
        $tailLength = [int][math]::Min([long]128, $end)
        $sample = [byte[]]::new($headLength + $tailLength)
        if ($headLength -gt 0) { [void]$stream.Read($sample, 0, $headLength) }
        if ($tailLength -gt 0) {
            [void]$stream.Seek($end - $tailLength, [IO.SeekOrigin]::Begin)
            [void]$stream.Read($sample, $headLength, $tailLength)
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($sample))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Add-SessionLogLine {
    param($State, [string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $entry = $Line.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $State.badLines++; return }

    $entryAt = $null
    try {
        $entryAt = [datetimeoffset]::Parse([string]$entry.timestamp)
        if ($null -eq $State.startedAt -or $entryAt -lt $State.startedAt) { $State.startedAt = $entryAt }
        if ($null -eq $State.endedAt -or $entryAt -gt $State.endedAt) { $State.endedAt = $entryAt }
    } catch {}

    if ($entry.type -eq 'session_meta') {
        if ($entry.payload.id) { $State.sessionId = [string]$entry.payload.id }
        elseif ($entry.payload.session_id) { $State.sessionId = [string]$entry.payload.session_id }
        if ($entry.payload.cwd) { $State.cwd = [string]$entry.payload.cwd }
        if ($entry.payload.originator) { $State.origin = [string]$entry.payload.originator }
        return
    }

    if ($entry.type -eq 'turn_context') {
        if ($entry.payload.model) { $State.currentModel = [string]$entry.payload.model }
        if ($entry.payload.effort) { $State.efforts[[string]$entry.payload.effort] = $true }
        if ($entry.payload.cwd) { $State.cwd = [string]$entry.payload.cwd }
        return
    }

    if ($entry.payload.type -eq 'thread_settings_applied' -and $entry.payload.thread_settings.model) {
        $State.currentModel = [string]$entry.payload.thread_settings.model
        return
    }

    if ($entry.payload.type -eq 'user_message' -and -not $State.firstUserMessage -and $entry.payload.message) {
        $State.firstUserMessage = ([string]$entry.payload.message -replace '\s+', ' ').Trim()
        return
    }

    if ($entry.payload.type -ne 'token_count' -or $null -eq $entry.payload.info.last_token_usage) { return }
    $usage = $entry.payload.info.last_token_usage
    if (([long]$usage.input_tokens + [long]$usage.output_tokens) -le 0) { return }
    $isLong = ([long]$usage.input_tokens -gt 272000)
    if (-not $State.models.ContainsKey($State.currentModel)) { $State.models[$State.currentModel] = New-UsageCounter }
    Add-Usage $State.usage $usage $isLong
    Add-Usage $State.models[$State.currentModel] $usage $isLong

    if ($null -ne $entryAt) {
        $usageDate = $entryAt.ToLocalTime().ToString('yyyy-MM-dd')
        if (-not $State.dailyUsage.ContainsKey($usageDate)) {
            $State.dailyUsage[$usageDate] = New-UsageCounter
            $State.dailyModels[$usageDate] = @{}
        }
        if (-not $State.dailyModels[$usageDate].ContainsKey($State.currentModel)) {
            $State.dailyModels[$usageDate][$State.currentModel] = New-UsageCounter
        }
        Add-Usage $State.dailyUsage[$usageDate] $usage $isLong
        Add-Usage $State.dailyModels[$usageDate][$State.currentModel] $usage $isLong
    }

    if ($entry.payload.rate_limits -and $null -ne $entryAt -and $entryAt -ge $State.latestRateLimitAt) {
        $State.latestRateLimitAt = $entryAt
        $State.latestRateLimit = $entry.payload.rate_limits
    }
}

function Update-SessionParseState {
    param($Candidate)
    $file = Get-Item -LiteralPath $Candidate.file.FullName
    $path = $file.FullName
    $state = $script:sessionParseCache[$path]
    $creationChanged = $null -ne $state -and [long]$file.CreationTimeUtc.Ticks -ne [long]$state.creationUtcTicks
    $boundaryChanged = $false
    if ($null -ne $state -and [long]$state.offset -gt 0 -and [long]$file.Length -ge [long]$state.offset -and [long]$file.LastWriteTimeUtc.Ticks -ne [long]$state.lastWriteUtcTicks) {
        $boundaryChanged = (Get-FileBoundaryHash $path ([long]$state.offset)) -ne [string]$state.boundaryHash
    }
    if ($null -eq $state -or [long]$file.Length -lt [long]$state.offset -or $creationChanged -or $boundaryChanged) {
        $state = New-SessionParseState $Candidate
        $script:sessionParseCache[$path] = $state
    }
    $state.lastReadBytes = [long]0
    $state.cacheHit = $true
    $state.source = $Candidate.source
    $state.sourceLabel = $Candidate.label

    if ([long]$file.Length -gt [long]$state.offset) {
        $stream = $null
        $reader = $null
        try {
            $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
            [void]$stream.Seek([long]$state.offset, [IO.SeekOrigin]::Begin)
            $remaining = [long]$stream.Length - [long]$stream.Position
            if ($remaining -gt [int]::MaxValue) { throw "Session log append is too large to scan incrementally: $path" }
            $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::UTF8, $true)
            $bytes = $reader.ReadBytes([int]$remaining)
            $state.lastReadBytes = [long]$bytes.Length
            $state.cacheHit = $false
            $state.offset += [long]$bytes.Length
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            $combined = [string]$state.pendingText + $text
            $parts = @([regex]::Split($combined, "\r?\n"))
            if ($combined -notmatch "\r?\n$") {
                $state.pendingText = if ($parts.Count) { [string]$parts[-1] } else { $combined }
                if ($parts.Count -gt 1) { $parts = @($parts[0..($parts.Count - 2)]) } else { $parts = @() }
            } else {
                $state.pendingText = ''
            }
            foreach ($line in $parts) { Add-SessionLogLine $state ([string]$line) }
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    $fresh = Get-Item -LiteralPath $path
    $state.observedLength = [long]$fresh.Length
    $state.creationUtcTicks = [long]$fresh.CreationTimeUtc.Ticks
    $state.lastWriteUtcTicks = [long]$fresh.LastWriteTimeUtc.Ticks
    $state.boundaryHash = Get-FileBoundaryHash $path ([long]$state.offset)
    return $state
}

function Convert-SessionParseState {
    param($State, $ThreadNames)
    if ($State.usage.requests -eq 0 -and -not $ThreadNames.ContainsKey($State.sessionId)) { return $null }
    $title = if ($ThreadNames.ContainsKey($State.sessionId)) {
        $ThreadNames[$State.sessionId]
    } elseif ($State.firstUserMessage) {
        if ($State.firstUserMessage.Length -gt 64) { $State.firstUserMessage.Substring(0, 64) + '...' } else { $State.firstUserMessage }
    } else { 'Untitled task' }
    $project = if ($State.cwd) { Split-Path -Leaf $State.cwd } else { 'Unknown project' }
    $durationSeconds = if ($null -ne $State.startedAt -and $null -ne $State.endedAt) { [math]::Max(0, [int]($State.endedAt - $State.startedAt).TotalSeconds) } else { 0 }
    $dailyRows = @($State.dailyUsage.Keys | Sort-Object | ForEach-Object {
        [pscustomobject][ordered]@{
            date = $_
            usage = [pscustomobject]$State.dailyUsage[$_]
            models = @(Convert-ModelsToArray $State.dailyModels[$_])
        }
    })
    [pscustomobject][ordered]@{
        id = $State.sessionId
        title = [string]$title
        project = $project
        cwd = $State.cwd
        origin = $State.origin
        source = $State.source
        sourceLabel = $State.sourceLabel
        accountComparable = $true
        startedAt = if ($null -ne $State.startedAt) { $State.startedAt.ToString('o') } else { $null }
        endedAt = if ($null -ne $State.endedAt) { $State.endedAt.ToString('o') } else { $null }
        localDate = if ($null -ne $State.startedAt) { $State.startedAt.ToLocalTime().ToString('yyyy-MM-dd') } else { '' }
        durationSeconds = $durationSeconds
        efforts = @($State.efforts.Keys | Sort-Object)
        usage = [pscustomobject]$State.usage
        models = @(Convert-ModelsToArray $State.models)
        dailyUsage = $dailyRows
    }
}

function Get-CodexUsage {
    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        throw "Codex sessions directory not found: $sessionsRoot"
    }

    $scanClock = [Diagnostics.Stopwatch]::StartNew()
    $threadNames = Get-ThreadNames
    $total = New-UsageCounter
    $allModels = @{}
    $sessions = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $badLines = 0
    $latestRateLimit = $null
    $latestRateLimitAt = [datetimeoffset]::MinValue
    $files = @(Get-SessionCandidates)
    $incrementalBytesRead = [long]0
    $cachedFiles = 0

    foreach ($candidate in $files) {
        $state = Update-SessionParseState $candidate
        $incrementalBytesRead += [long]$state.lastReadBytes
        if ($state.cacheHit) { $cachedFiles++ }
        $badLines += [long]$state.badLines
        if ($null -ne $state.latestRateLimit -and $state.latestRateLimitAt -ge $latestRateLimitAt) {
            $latestRateLimitAt = $state.latestRateLimitAt
            $latestRateLimit = $state.latestRateLimit
        }
        $session = Convert-SessionParseState $state $threadNames
        if ($null -ne $session) { [void]$sessions.Add($session) }
    }

    $activePaths = @{}
    foreach ($candidate in $files) { $activePaths[$candidate.file.FullName] = $true }
    foreach ($cachedPath in @($script:sessionParseCache.Keys)) {
        if (-not $activePaths.ContainsKey($cachedPath)) { $script:sessionParseCache.Remove($cachedPath) }
    }

    foreach ($manualFile in @(Get-ChildItem -LiteralPath $importsRoot -Filter 'manual-usage*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $manualData = Get-Content -LiteralPath $manualFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $manualEntries = if ($manualData.entries) { @($manualData.entries) } else { @($manualData) }
            foreach ($entry in $manualEntries) {
                if ($null -eq $entry -or -not $entry.model) { continue }
                $counter = New-UsageCounter
                $counter.inputTokens = [long]$entry.inputTokens
                $counter.cachedInputTokens = [long]$entry.cachedInputTokens
                $counter.cacheWriteInputTokens = [long]$entry.cacheWriteInputTokens
                $counter.outputTokens = [long]$entry.outputTokens
                $counter.reasoningOutputTokens = [long]$entry.reasoningOutputTokens
                $counter.totalTokens = $counter.inputTokens + $counter.outputTokens
                $counter.longInputTokens = [long]$entry.longInputTokens
                $counter.longCachedInputTokens = [long]$entry.longCachedInputTokens
                $counter.longCacheWriteInputTokens = [long]$entry.longCacheWriteInputTokens
                $counter.longOutputTokens = [long]$entry.longOutputTokens
                $counter.requests = if ($entry.requests) { [long]$entry.requests } else { [long]1 }
                $counter.longRequests = [long]$entry.longRequests
                if ($counter.totalTokens -le 0) { continue }
                $model = [string]$entry.model
                $entryAt = if ($entry.date) { [datetimeoffset]::Parse([string]$entry.date) } else { [datetimeoffset]::Now }
                $modelRow = [ordered]@{ model = $model }
                foreach ($key in $counter.Keys) { $modelRow[$key] = $counter[$key] }
                [void]$sessions.Add([pscustomobject][ordered]@{
                    id = if ($entry.id) { [string]$entry.id } else { 'manual-' + (Get-TextSha256 ("$($manualFile.Name)|$model|$entryAt|$($entry.title)" )).Substring(0, 24) }
                    title = if ($entry.title) { [string]$entry.title } else { 'Manual usage import' }
                    project = if ($entry.project) { [string]$entry.project } else { 'External usage' }
                    cwd = ''
                    origin = 'Manual import'
                    source = 'manual'
                    sourceLabel = if ($entry.source) { [string]$entry.source } else { 'Manual import' }
                    accountComparable = $false
                    startedAt = $entryAt.ToString('o')
                    endedAt = $entryAt.ToString('o')
                    localDate = $entryAt.ToLocalTime().ToString('yyyy-MM-dd')
                    durationSeconds = 0
                    efforts = @()
                    usage = [pscustomobject]$counter
                    models = @([pscustomobject]$modelRow)
                    dailyUsage = @([pscustomobject][ordered]@{
                        date = $entryAt.ToLocalTime().ToString('yyyy-MM-dd')
                        usage = [pscustomobject]$counter
                        models = @([pscustomobject]$modelRow)
                    })
                })
            }
        } catch {
            $badLines++
            [void]$warnings.Add("Manual import $($manualFile.Name): $($_.Exception.Message)")
        }
    }

    $bundleFiles = @()
    if (Test-Path -LiteralPath $bundlesRoot) {
        $bundleFiles += Get-ChildItem -LiteralPath $bundlesRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $importedDevicesRoot) {
        $bundleFiles += Get-ChildItem -LiteralPath $importedDevicesRoot -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq 'bundles' }
    }
    foreach ($bundleFile in @($bundleFiles)) {
        try {
            $bundle = Get-Content -LiteralPath $bundleFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($bundle.kind -ne 'codex-token-meter-export' -or [int]$bundle.schemaVersion -ne 1) { throw 'Unsupported export format.' }
            foreach ($portableSession in @($bundle.sessions)) {
                if (-not $portableSession.id -or $null -eq $portableSession.usage) { continue }
                $core = ConvertTo-PortableSessionCore $portableSession
                $canonical = $core | ConvertTo-Json -Depth 14 -Compress
                if ($portableSession.contentHash -and (Get-TextSha256 $canonical) -ne [string]$portableSession.contentHash) {
                    [void]$warnings.Add("Bundle $($bundleFile.Name): checksum mismatch for $($portableSession.id)")
                    continue
                }
                $label = if ($bundle.device.name) { [string]$bundle.device.name } else { 'Imported device' }
                $portableDailyUsage = if ($null -ne $core.dailyUsage) {
                    @($core.dailyUsage)
                } elseif ($core.localDate) {
                    @([pscustomobject][ordered]@{ date = [string]$core.localDate; usage = $core.usage; models = @($core.models) })
                } else { @() }
                [void]$sessions.Add([pscustomobject][ordered]@{
                    id = [string]$core.id
                    title = [string]$core.title
                    project = [string]$core.project
                    cwd = ''
                    origin = if ($core.origin) { [string]$core.origin } else { 'Portable JSON export' }
                    source = 'portable'
                    sourceLabel = "$label · $($core.sourceLabel)"
                    accountComparable = [bool]$core.accountComparable
                    startedAt = $core.startedAt
                    endedAt = $core.endedAt
                    localDate = [string]$core.localDate
                    durationSeconds = [long]$core.durationSeconds
                    efforts = @($core.efforts)
                    usage = $core.usage
                    models = @($core.models)
                    dailyUsage = $portableDailyUsage
                    contentHash = [string]$portableSession.contentHash
                })
            }
        } catch {
            $badLines++
            [void]$warnings.Add("Portable bundle $($bundleFile.Name): $($_.Exception.Message)")
        }
    }

    $sessionById = @{}
    foreach ($session in @($sessions)) {
        $id = [string]$session.id
        if (-not $id) { continue }
        if (-not $sessionById.ContainsKey($id)) { $sessionById[$id] = $session; continue }
        $current = $sessionById[$id]
        $replace = [double]$session.usage.totalTokens -gt [double]$current.usage.totalTokens
        if ([double]$session.usage.totalTokens -eq [double]$current.usage.totalTokens) {
            if ([long]$session.usage.requests -gt [long]$current.usage.requests) { $replace = $true }
            elseif ([long]$session.usage.requests -eq [long]$current.usage.requests) {
                $sessionLocal = $session.source -ne 'portable'
                $currentLocal = $current.source -ne 'portable'
                if ($sessionLocal -and -not $currentLocal) { $replace = $true }
                elseif ($sessionLocal -eq $currentLocal -and [string]$session.endedAt -gt [string]$current.endedAt) { $replace = $true }
                elseif ($sessionLocal -eq $currentLocal -and [string]$session.endedAt -eq [string]$current.endedAt -and $session.contentHash) {
                    if (-not $current.contentHash -or [string]::CompareOrdinal([string]$session.contentHash, [string]$current.contentHash) -lt 0) { $replace = $true }
                }
            }
        }
        if ($replace) { $sessionById[$id] = $session }
    }
    $sessions = @($sessionById.Values)
    $total = New-UsageCounter
    $allModels = @{}
    foreach ($session in $sessions) {
        Add-Counter $total $session.usage
        foreach ($modelUsage in @($session.models)) {
            $model = [string]$modelUsage.model
            if (-not $model) { continue }
            if (-not $allModels.ContainsKey($model)) { $allModels[$model] = New-UsageCounter }
            Add-Counter $allModels[$model] $modelUsage
        }
    }

    $localScanMilliseconds = [math]::Round($scanClock.Elapsed.TotalMilliseconds, 1)

    $comparableTokens = [long]0
    foreach ($session in @($sessions)) {
        $isComparable = if ($null -ne $session.accountComparable) { [bool]$session.accountComparable } else { $session.source -ne 'manual' }
        if ($isComparable) { $comparableTokens += [long]$session.usage.totalTokens }
    }

    $account = Get-CodexAccountSnapshot
    $deviceIdentity = Get-DeviceIdentity
    $accountIdentity = Get-AccountIdentity $account
    $account | Add-Member -NotePropertyName identity -NotePropertyValue $accountIdentity -Force
    $serverLifetimeTokens = if ($account.available -and $null -ne $account.summary.lifetimeTokens) { [long]$account.summary.lifetimeTokens } else { [long]0 }
    $lifetimeTokens = Get-LiveAccountLifetime $account $comparableTokens $accountIdentity.accountKey
    if ($account.available) {
        $account | Add-Member -NotePropertyName serverLifetimeTokens -NotePropertyValue $serverLifetimeTokens -Force
        $account | Add-Member -NotePropertyName liveLifetimeTokens -NotePropertyValue $lifetimeTokens -Force
        $account | Add-Member -NotePropertyName liveLocalDeltaTokens -NotePropertyValue ([long][math]::Max(0, $lifetimeTokens - $serverLifetimeTokens)) -Force
    }
    $rateLimitView = $null
    if ($null -ne $latestRateLimit -and $latestRateLimit.primary) {
        $rateLimitView = [pscustomobject][ordered]@{
            usedPercent = $latestRateLimit.primary.used_percent
            windowMinutes = $latestRateLimit.primary.window_minutes
            resetsAt = $latestRateLimit.primary.resets_at
            limitId = $latestRateLimit.limit_id
            hasCredits = if ($latestRateLimit.credits) { $latestRateLimit.credits.has_credits } else { $null }
            balance = if ($latestRateLimit.credits) { $latestRateLimit.credits.balance } else { $null }
        }
    }
    elseif ($account.available -and $account.rateLimits -and $account.rateLimits.primary) {
        $rateLimitView = [pscustomobject][ordered]@{
            usedPercent = $account.rateLimits.primary.usedPercent
            windowMinutes = $account.rateLimits.primary.windowDurationMins
            resetsAt = $account.rateLimits.primary.resetsAt
            limitId = $null
            hasCredits = $null
            balance = $null
        }
    }

    $unattributedTokens = if ($lifetimeTokens -gt 0) { [math]::Max(0, $lifetimeTokens - $comparableTokens) } else { [long]0 }
    $coveragePercent = if ($lifetimeTokens -gt 0) { [math]::Min([double]100.0, [double]$comparableTokens * 100.0 / [double]$lifetimeTokens) } else { $null }
    $history = Update-HistoryCache $sessions $account $accountIdentity $deviceIdentity

    [pscustomobject][ordered]@{
        generatedAt = [datetimeoffset]::Now.ToString('o')
        sessionsRoot = $sessionsRoot
        importsRoot = $importsRoot
        filesScanned = $files.Count
        scan = [pscustomobject][ordered]@{
            mode = 'incremental'
            cachedFiles = $cachedFiles
            changedFiles = $files.Count - $cachedFiles
            bytesRead = $incrementalBytesRead
            localMilliseconds = $localScanMilliseconds
        }
        malformedLines = $badLines
        warnings = @($warnings)
        settings = (Get-MeterConfig)
        totals = [pscustomobject]$total
        models = @(Convert-ModelsToArray $allModels)
        sessions = @($sessions | Sort-Object -Property @{ Expression = { $_.startedAt }; Descending = $true })
        rateLimit = $rateLimitView
        account = $account
        identity = [pscustomobject][ordered]@{ account = $accountIdentity; device = $deviceIdentity }
        history = $history
        coverage = [pscustomobject][ordered]@{
            accountLifetimeTokens = $lifetimeTokens
            locallyAttributableTokens = $comparableTokens
            unattributedTokens = $unattributedTokens
            percent = $coveragePercent
        }
    }
}

function New-PortableJsonExport {
    param($Usage)
    $portableSessions = New-Object System.Collections.ArrayList
    foreach ($session in @($Usage.sessions)) {
        $core = ConvertTo-PortableSessionCore $session
        $canonical = $core | ConvertTo-Json -Depth 14 -Compress
        $portable = [ordered]@{}
        foreach ($key in $core.Keys) { $portable[$key] = $core[$key] }
        $portable['contentHash'] = Get-TextSha256 $canonical
        [void]$portableSessions.Add([pscustomobject]$portable)
    }
    $exportedAt = [datetimeoffset]::Now
    $hashList = @($portableSessions | ForEach-Object { $_.contentHash }) -join '|'
    [pscustomobject][ordered]@{
        kind = 'codex-token-meter-export'
        schemaVersion = 1
        exportId = [guid]::NewGuid().ToString('D')
        exportedAt = $exportedAt.ToString('o')
        suggestedFileName = 'codex-meter-' + ([string]$Usage.identity.device.deviceCode).ToLowerInvariant() + '-' + $exportedAt.ToString('yyyyMMdd-HHmmss') + '.json'
        identity = $Usage.identity
        device = $Usage.identity.device
        account = $Usage.identity.account
        accountSnapshot = [pscustomobject][ordered]@{
            fetchedAt = $Usage.account.fetchedAt
            summary = $Usage.account.summary
            dailyUsageBuckets = @($Usage.account.dailyUsageBuckets)
        }
        sessionCount = $portableSessions.Count
        sessionsHash = Get-TextSha256 $hashList
        sessions = @($portableSessions)
    }
}

function New-HistorySummaryExport {
    param($Usage)
    $exportedAt = [datetimeoffset]::Now
    $days = @($Usage.history.days | Sort-Object date | ForEach-Object {
        [pscustomobject][ordered]@{
            date = [string]$_.date
            accountTokens = [long]$_.accountTokens
            localUsage = $_.localUsage
            complete = [bool]$_.complete
        }
    })
    $localTotal = New-UsageCounter
    $accountDailyTotal = [long]0
    foreach ($day in $days) {
        Add-Counter $localTotal $day.localUsage
        $accountDailyTotal += [long]$day.accountTokens
    }
    $canonical = [pscustomobject][ordered]@{
        accountKey = [string]$Usage.identity.account.accountKey
        deviceId = [string]$Usage.identity.device.deviceId
        days = $days
    } | ConvertTo-Json -Depth 10 -Compress
    [pscustomobject][ordered]@{
        kind = 'codex-token-meter-history-summary'
        schemaVersion = 1
        exportId = [guid]::NewGuid().ToString('D')
        exportedAt = $exportedAt.ToString('o')
        suggestedFileName = 'codex-meter-history-' + ([string]$Usage.identity.account.accountKey).Substring(0, 13) + '-' + ([string]$Usage.identity.device.deviceCode).ToLowerInvariant() + '-' + $exportedAt.ToString('yyyyMMdd-HHmmss') + '.json'
        identity = $Usage.identity
        range = [pscustomobject][ordered]@{
            firstDate = [string]$Usage.history.firstDate
            lastDate = [string]$Usage.history.lastDate
            dayCount = $days.Count
        }
        totals = [pscustomobject][ordered]@{
            accountDailyTokens = $accountDailyTotal
            accountLifetimeTokens = [long]$Usage.coverage.accountLifetimeTokens
            localUsage = [pscustomobject]$localTotal
        }
        days = $days
        historyHash = Get-TextSha256 $canonical
        privacy = [pscustomobject][ordered]@{
            containsTaskDetails = $false
            containsPrompts = $false
            containsFilePaths = $false
            containsOAuthCredentials = $false
        }
    }
}

function Write-HttpResponse {
    param($Stream, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes)
    $statusText = if ($StatusCode -eq 200) { 'OK' } elseif ($StatusCode -eq 404) { 'Not Found' } else { 'Internal Server Error' }
    $header = "HTTP/1.1 $StatusCode $statusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}

function Get-OnlineUsdCnyRate {
    $response = Invoke-RestMethod -Uri 'https://api.frankfurter.dev/v2/rate/USD/CNY' -Method Get -TimeoutSec 12
    $rate = [double]$response.rate
    if ($rate -le 0 -or [double]::IsNaN($rate) -or [double]::IsInfinity($rate)) {
        throw 'The exchange-rate provider returned an invalid USD/CNY rate.'
    }
    [pscustomobject][ordered]@{
        base = 'USD'
        quote = 'CNY'
        rate = $rate
        date = [string]$response.date
        source = 'Frankfurter'
        sourceUrl = 'https://frankfurter.dev/'
        fetchedAt = [datetimeoffset]::Now.ToString('o')
    }
}

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'
    '.js' = 'application/javascript; charset=utf-8'
    '.svg' = 'image/svg+xml'
}

$baseUrl = "http://127.0.0.1:$Port/"
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)

try {
    $listener.Start()
} catch {
    throw "Could not start $baseUrl. Try another port: .\Start-CodexMeter.ps1 -Port 43128`n$($_.Exception.Message)"
}

Write-Host ''
Write-Host '  Codex Token Meter is running' -ForegroundColor Cyan
Write-Host "  $baseUrl" -ForegroundColor White
Write-Host '  Press Ctrl+C to stop' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoBrowser) {
    try { Start-Process $baseUrl } catch { Write-Warning "Open $baseUrl in your browser." }
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        try {
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            while ($reader.ReadLine()) {}
            $requestTarget = ($requestLine -split ' ')[1]
            $requestUri = [Uri]("http://127.0.0.1" + $requestTarget)
            $path = $requestUri.AbsolutePath
            if ($path -eq '/api/health') {
                $health = '{"product":"codex-token-meter","version":"0.2.0"}'
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($health))
                continue
            }
            if ($path -eq '/api/usage') {
                $json = Get-CodexUsage | ConvertTo-Json -Depth 12 -Compress
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/settings') {
                $json = Get-MeterConfig | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/settings/refresh') {
                $match = [regex]::Match($requestUri.Query, '(?:^|[?&])seconds=([^&]+)')
                if (-not $match.Success) { throw 'Missing refresh interval.' }
                $value = [Uri]::UnescapeDataString($match.Groups[1].Value)
                $seconds = [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
                $json = Set-MeterRefreshInterval $seconds | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/settings/theme') {
                $themeValues = @{}
                foreach ($name in @('accent', 'background', 'panel', 'text', 'muted', 'secondary')) {
                    $match = [regex]::Match($requestUri.Query, "(?:^|[?&])$name=([^&]+)")
                    if (-not $match.Success) { throw "Missing theme color: $name" }
                    $themeValues[$name] = [Uri]::UnescapeDataString($match.Groups[1].Value)
                }
                $json = Set-MeterTheme $themeValues.accent $themeValues.background $themeValues.panel $themeValues.text $themeValues.muted $themeValues.secondary | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/settings/units') {
                $match = [regex]::Match($requestUri.Query, '(?:^|[?&])style=([^&]+)')
                if (-not $match.Success) { throw 'Missing number unit style.' }
                $style = [Uri]::UnescapeDataString($match.Groups[1].Value)
                $json = Set-MeterUnitStyle $style | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/export') {
                $usage = Get-CodexUsage
                $json = New-PortableJsonExport $usage | ConvertTo-Json -Depth 16
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/export/history') {
                $usage = Get-CodexUsage
                $json = New-HistorySummaryExport $usage | ConvertTo-Json -Depth 14
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/exchange-rate') {
                $json = Get-OnlineUsdCnyRate | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
                continue
            }
            if ($path -eq '/api/open-imports') {
                if (-not (Test-Path -LiteralPath $importsRoot)) { [void](New-Item -ItemType Directory -Path $importsRoot -Force) }
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $importsRoot + '"')
                Write-HttpResponse $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
                continue
            }

            $relative = switch ($path) {
                '/' { 'index.html' }
                '/index.html' { 'index.html' }
                '/styles.css' { 'styles.css' }
                '/app.js' { 'app.js' }
                default { $null }
            }
            if ($null -eq $relative) {
                Write-HttpResponse $stream 404 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Not found'))
                continue
            }

            $filePath = Join-Path $scriptRoot $relative
            $extension = [IO.Path]::GetExtension($filePath)
            Write-HttpResponse $stream 200 $mimeTypes[$extension] ([IO.File]::ReadAllBytes($filePath))
        } catch {
            $message = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
            try { Write-HttpResponse $stream 500 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($message)) } catch {}
        } finally {
            try { $stream.Dispose() } catch {}
            try { $client.Close() } catch {}
        }
    }
} finally {
    $listener.Stop()
}
