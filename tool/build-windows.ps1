[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [string]$Go = 'go',
    [string]$BuildConfig,
    [string]$ConfigUrl,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'build-common.ps1')
$settings = Get-AsterLinkBuildSettings -ProjectPath $projectPath -BuildConfig $BuildConfig -ConfigUrl $ConfigUrl -Offline:$Offline
$dartDefines = @(Get-AsterLinkDartDefines -Settings $settings)
Test-AsterLinkVersion -ProjectPath $projectPath -Flutter $Flutter
$savedPub = $env:PUB_HOSTED_URL
$savedStorage = $env:FLUTTER_STORAGE_BASE_URL
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$savedPubCache = $env:PUB_CACHE
$savedPath = $env:PATH
$savedNugetPackages = $env:NUGET_PACKAGES
$savedNugetHttpCache = $env:NUGET_HTTP_CACHE_PATH
try {
    if (-not $env:PUB_HOSTED_URL) { $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn' }
    if (-not $env:FLUTTER_STORAGE_BASE_URL) { $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn' }
    $env:TEMP = Join-Path $projectPath '.local\build-tmp'
    $env:TMP = $env:TEMP
    $env:PUB_CACHE = Join-Path $projectPath '.local\pub-cache'
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    $nugetPath = & (Join-Path $PSScriptRoot 'prepare-windows-tools.ps1')
    $env:PATH = (Split-Path -Parent $nugetPath) + [IO.Path]::PathSeparator + $env:PATH
    $env:NUGET_PACKAGES = Join-Path $projectPath '.local\nuget\packages'
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $projectPath '.local\nuget\http-cache'
    & (Join-Path $PSScriptRoot 'prepare-windows-media.ps1')
    & (Join-Path $PSScriptRoot 'build-native-windows.ps1') -Go $Go
    Push-Location -LiteralPath $projectPath
    try {
        Invoke-AsterLinkTool -Command $Flutter -Arguments @('pub', 'get') -Failure 'Flutter dependencies failed'
        Invoke-AsterLinkTool -Command $Flutter -Arguments (@('build', 'windows', '--release', '--no-pub') + $dartDefines) -Failure 'Windows build failed; check the Visual Studio C++ toolchain'
    } finally { Pop-Location }
} finally {
    $env:PUB_HOSTED_URL = $savedPub
    $env:FLUTTER_STORAGE_BASE_URL = $savedStorage
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    $env:PUB_CACHE = $savedPubCache
    $env:PATH = $savedPath
    $env:NUGET_PACKAGES = $savedNugetPackages
    $env:NUGET_HTTP_CACHE_PATH = $savedNugetHttpCache
}
