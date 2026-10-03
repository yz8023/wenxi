[CmdletBinding()]
param(
    [string]$AarPath = (Join-Path $PSScriptRoot '..\android\app\libs\gopeed-1.8.1.aar'),
    [Parameter(Mandatory = $true)][string]$NdkHome,
    [string]$WorkDirectory = (Join-Path $PSScriptRoot '.tools')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$AarPath = [IO.Path]::GetFullPath($AarPath)
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
$llvmRoot = Join-Path $NdkHome 'toolchains\llvm\prebuilt\windows-x86_64'
$strip = Join-Path $llvmRoot 'bin\llvm-strip.exe'
$readelf = Join-Path $llvmRoot 'bin\llvm-readelf.exe'
$notice = Join-Path $llvmRoot 'NOTICE'
foreach ($required in @($AarPath, $strip, $readelf, $notice)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing input: $required" }
}
$triples = @{
    'arm64-v8a' = 'aarch64-linux-android'
    'armeabi-v7a' = 'arm-linux-androideabi'
    'x86' = 'i686-linux-android'
    'x86_64' = 'x86_64-linux-android'
}
# libc++_shared.so is an NDK runtime, not an Android system library.
$systemLibraries = @('libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so', 'libz.so')
$stage = Join-Path $WorkDirectory ('aar-runtime-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $stagedAar = Join-Path $stage 'gopeed.aar'
    $source = [IO.Compression.ZipFile]::OpenRead($AarPath)
    $archive = [IO.Compression.ZipFile]::Open($stagedAar, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $abis = @($source.Entries | Where-Object { $_.FullName -match '^jni/[^/]+/libgojni\.so$' } |
            ForEach-Object { $_.FullName.Split('/')[1] })
        if ($abis.Count -eq 0) { throw 'AAR contains no Gopeed native libraries.' }
        # Recreate entries instead of Update: .NET can preserve gomobile ZIP64 data
        # descriptors with incompatible local headers, rejected by Java ZipInputStream.
        foreach ($entry in $source.Entries) {
            if ($entry.FullName -match '^jni/[^/]+/libc\+\+_shared\.so$' -or
                $entry.FullName -eq 'META-INF/licenses/libc++_shared-NOTICE.txt') { continue }
            $copy = $archive.CreateEntry($entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
            $inputStream = $entry.Open()
            $outputStream = $copy.Open()
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
        foreach ($abi in $abis) {
            if (-not $triples.ContainsKey($abi)) { throw "Unsupported ABI: $abi" }
            $abiDirectory = Join-Path $stage $abi
            New-Item -ItemType Directory -Path $abiDirectory | Out-Null
            $runtime = Join-Path $abiDirectory 'libc++_shared.so'
            Copy-Item -LiteralPath (Join-Path $llvmRoot "sysroot\usr\lib\$($triples[$abi])\libc++_shared.so") -Destination $runtime
            # Strip the copy; never modify the installed SDK/NDK.
            & $strip '--strip-unneeded' $runtime
            if ($LASTEXITCODE -ne 0) { throw "Stripping $abi C++ runtime failed." }
            $entryName = "jni/$abi/libc++_shared.so"
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $runtime, $entryName, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
        $noticeEntry = 'META-INF/licenses/libc++_shared-NOTICE.txt'
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $notice, $noticeEntry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    } finally { $archive.Dispose(); $source.Dispose() }

    $archive = [IO.Compression.ZipFile]::OpenRead($stagedAar)
    try {
        foreach ($entry in @($archive.Entries | Where-Object { $_.FullName -match '^jni/[^/]+/[^/]+\.so$' })) {
            $parts = $entry.FullName.Split('/')
            $nativeFile = Join-Path (Join-Path $stage $parts[1]) $parts[2]
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $nativeFile, $true)
            $dynamic = & $readelf '-d' $nativeFile
            if ($LASTEXITCODE -ne 0) { throw "ELF inspection failed: $($entry.FullName)" }
            foreach ($line in $dynamic) {
                if ($line -match '\(NEEDED\).*Shared library: \[([^\]]+)\]') {
                    $dependency = $Matches[1]
                    if ($dependency -notin $systemLibraries -and $null -eq $archive.GetEntry("jni/$($parts[1])/$dependency")) {
                        throw "Missing dependency for $($entry.FullName): $dependency"
                    }
                }
            }
        }
    } finally { $archive.Dispose() }

    $licenseDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\licenses'))
    New-Item -ItemType Directory -Path $licenseDirectory -Force | Out-Null
    Copy-Item -LiteralPath $notice -Destination (Join-Path $licenseDirectory 'android-ndk-NOTICE.txt') -Force
    Move-Item -LiteralPath $stagedAar -Destination $AarPath -Force
    Write-Output "Bundled stripped C++ runtimes and verified native dependencies for: $($abis -join ', ')"
} finally {
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    $allowedPrefix = $WorkDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStage.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a staging directory outside the build work directory.'
    }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
