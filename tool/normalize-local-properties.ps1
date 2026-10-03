$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
$propertiesPath = Join-Path $projectPath 'android\local.properties'
if (Test-Path -LiteralPath $propertiesPath) {
    # Flutter 3.41 escapes backslashes but leaves drive colons unescaped.
    # Keep the generated paths valid for both Java Properties and Android lint.
    $original = [IO.File]::ReadAllText($propertiesPath)
    $normalized = [regex]::Replace($original, '(?m)^((?:sdk\.dir|flutter\.sdk)=[A-Za-z]):', '$1\:')
    if ($normalized -ne $original) {
        [IO.File]::WriteAllText($propertiesPath, $normalized, [Text.UTF8Encoding]::new($false))
    }
}
