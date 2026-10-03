param([string]$SevenZip = '7za')
$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
$runtimePath = Join-Path $projectPath '.local\player-test'
$libraryPath = Join-Path $runtimePath 'libmpv'
$archiveName = 'mpv-dev-x86_64-20241021-git-0f78584.7z'
$archivePath = Join-Path $runtimePath $archiveName
# Same pinned release as vendor_plugins/media_kit_libs_windows_video.
$archiveHash = 'e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007'
$upstreamMd5 = '6ecf18e85b093c3f7edb16f3ee6603f3'
$downloadUrl = 'https://gh-proxy.com/https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/' + $archiveName
Get-Command $SevenZip -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $libraryPath -Force | Out-Null
$cached = (Test-Path -LiteralPath $archivePath) -and ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -eq $archiveHash)
if (-not $cached) {
    $partialPath = $archivePath + '.download'
    Write-Host 'Downloading the pinned libmpv test runtime through gh-proxy.com...'
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $partialPath
    if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash -ne $archiveHash) {
        throw 'libmpv archive SHA-256 mismatch; the download was not extracted.'
    }
    Move-Item -LiteralPath $partialPath -Destination $archivePath -Force
}
if ((Get-FileHash -LiteralPath $archivePath -Algorithm MD5).Hash -ne $upstreamMd5) {
    throw 'libmpv archive does not match the plugin release checksum.'
}
# Extract this filename only, without paths. No runtime is copied into source or APK assets.
& $SevenZip e $archivePath ('-o' + $libraryPath) 'libmpv-2.dll' -r -y | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'libmpv extraction failed.' }
$dllPath = Join-Path $libraryPath 'libmpv-2.dll'
if (-not (Test-Path -LiteralPath $dllPath)) { throw 'libmpv-2.dll was not found.' }
$env:ASTERLINK_MPV_LIBRARY = $dllPath
Write-Host ('Prepared: ' + $dllPath)
Write-Host 'Run flutter test test/native_playback_test.dart to check real playback without a GUI or audio output.'
