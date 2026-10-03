$ErrorActionPreference = 'Stop'
$projectPath = Split-Path -Parent $PSScriptRoot
$toolsPath = Join-Path $projectPath '.local\windows-tools'
$nugetPath = Join-Path $toolsPath 'nuget.exe'
$nugetHash = '0790bb7a0c898e44b70f2b65e3070b4db8af23897e38b8653d72d268b6e8bb11'
$nugetUrl = 'https://dist.nuget.org/win-x86-commandline/v6.12.1/nuget.exe'
New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
$cached = (Test-Path -LiteralPath $nugetPath) -and ((Get-FileHash -LiteralPath $nugetPath -Algorithm SHA256).Hash -eq $nugetHash)
if (-not $cached) {
    $partialPath = $nugetPath + '.download'
    Write-Host 'Downloading NuGet 6.12.1 from the official Microsoft distribution...'
    Invoke-WebRequest -UseBasicParsing -Uri $nugetUrl -OutFile $partialPath -TimeoutSec 180
    if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash -ne $nugetHash) {
        throw 'NuGet SHA-256 mismatch; the downloaded tool was not used.'
    }
    Move-Item -LiteralPath $partialPath -Destination $nugetPath -Force
}
Write-Output $nugetPath
