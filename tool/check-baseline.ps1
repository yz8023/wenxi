param([string]$Original = (Join-Path $PSScriptRoot '..\..\AsterLink'))
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
$baseline = Get-Content -LiteralPath (Join-Path $projectPath 'docs\kotlin-baseline-sha256.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$count = 0
foreach ($entry in $baseline.PSObject.Properties) {
    $target = Join-Path $Original $entry.Name
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Missing original source: $($entry.Name)" }
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($actual -ne $entry.Value) { throw "Original source changed: $($entry.Name)" }
    $count++
}
Write-Output "Verified $count original source files: unchanged."
