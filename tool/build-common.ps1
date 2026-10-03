function Restore-AsterLinkEnvironment {
    param([hashtable]$SavedEnvironment)
    foreach ($name in $SavedEnvironment.Keys) {
        if ($null -eq $SavedEnvironment[$name]) {
            # Remove absent variables explicitly: newer PowerShell/.NET versions
            # preserve empty strings, which override Gradle property defaults.
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $SavedEnvironment[$name], 'Process')
        }
    }
}

function Invoke-AsterLinkTool {
    param([string]$Command, [string[]]$Arguments, [string]$Failure = 'Build command failed')
    Get-Command $Command -ErrorAction Stop | Out-Null
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell wraps native stderr in ErrorRecord objects, even
        # for successful commands. Preserve the message and check the exit code.
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $commandExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($commandExit -ne 0) { throw "$Failure (exit code $commandExit)." }
}

function Get-AsterLinkBuildSettings {
    param([string]$ProjectPath, [string]$BuildConfig, [string]$ConfigUrl, [switch]$Offline)
    if (-not $BuildConfig) {
        $BuildConfig = Join-Path $ProjectPath '.local/build-config.json'
        if (-not (Test-Path -LiteralPath $BuildConfig -PathType Leaf)) {
            $BuildConfig = Join-Path $ProjectPath 'config/build.community.json'
        }
    }
    $settings = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $BuildConfig).ProviderPath) | ConvertFrom-Json
    $expected = @('controlEnabled', 'controlUrl', 'githubRepository', 'applicationId', 'metricsAppKey', 'metricsChannel')
    $names = @($settings.PSObject.Properties.Name)
    if (@(Compare-Object ($expected | Sort-Object) ($names | Sort-Object)).Count -ne 0) {
        throw 'Build config must have exactly the fields in config/build.community.json.'
    }
    foreach ($name in @('controlEnabled')) {
        if ($settings.$name -isnot [bool]) { throw "Build config field $name must be a JSON boolean." }
    }
    foreach ($name in @('controlUrl', 'githubRepository', 'applicationId', 'metricsAppKey', 'metricsChannel')) {
        if ($settings.$name -isnot [string]) { throw "Build config field $name must be a string." }
        $settings.$name = $settings.$name.Trim()
    }
    if ($ConfigUrl) { $settings.controlUrl = $ConfigUrl; $settings.controlEnabled = $true }
    if ($Offline) { $settings.controlEnabled = $false; $settings.githubRepository = '' }
    if ($settings.controlEnabled) {
        $uri = $null
        if (-not [Uri]::TryCreate($settings.controlUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.Port -lt 1 -or
            $uri.UserInfo -or $uri.Fragment -or $settings.controlUrl.Length -gt 2048 -or
            $settings.controlUrl -match '[\s\x00-\x1f\x7f\\]') {
            throw 'controlUrl must be an absolute HTTPS URL without credentials or a fragment.'
        }
    }
    if ($settings.githubRepository -and $settings.githubRepository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$') {
        throw 'githubRepository must be empty or owner/repository.'
    }
    if ($settings.applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
        throw 'applicationId must be a valid Android application ID.'
    }
    if ($settings.metricsAppKey -and $settings.metricsAppKey -notmatch '^[0-9a-fA-F]{24}$') {
        throw 'metricsAppKey must be empty (use the built-in value) or a 24-character key.'
    }
    if ($settings.metricsChannel -notmatch '^[A-Za-z0-9_.-]{1,64}$') {
        throw 'metricsChannel must use 1-64 letters, digits, dots, underscores or hyphens.'
    }
    return $settings
}

function Get-AsterLinkDartDefines {
    param($Settings)
    @(
        "--dart-define=ASTERLINK_CONTROL_ENABLED=$($Settings.controlEnabled.ToString().ToLowerInvariant())"
        "--dart-define=ASTERLINK_CONTROL_URL=$($Settings.controlUrl)"
        "--dart-define=ASTERLINK_GITHUB_REPO=$($Settings.githubRepository)"
    )
}

function Test-AsterLinkVersion {
    param([string]$ProjectPath, [string]$Flutter)
    $flutterPath = (Get-Command $Flutter -ErrorAction Stop).Source
    $dartPath = Join-Path (Split-Path -Parent $flutterPath) 'dart.bat'
    if (-not (Test-Path -LiteralPath $dartPath -PathType Leaf)) { $dartPath = 'dart' }
    Invoke-AsterLinkTool -Command $dartPath -Arguments @((Join-Path $ProjectPath 'tool/sync_version.dart'), '--check') -Failure 'Application version check failed'
}

function Get-AsterLinkOfficialBuildSettings {
    param([string]$ProjectPath)
    $configPath = Join-Path $ProjectPath '.local/build-config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'Official builds require .local/build-config.json. Public templates are not used as a fallback.'
    }
    $settings = Get-AsterLinkBuildSettings -ProjectPath $ProjectPath -BuildConfig $configPath
    if ($settings.applicationId -ne 'com.asterlink.app') {
        throw 'The local official build config must retain applicationId com.asterlink.app.'
    }
    return $settings
}
