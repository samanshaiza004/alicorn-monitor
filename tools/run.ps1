param(
    [string]$Odin = $env:ALICORN_ODIN,
    [switch]$Smoke,
    [switch]$Diagnostics,
    [int]$CaptureAfter = 2,
    [string]$CaptureDir = 'out\diagnostics',
    [switch]$InputDebug
)

$ErrorActionPreference = 'Stop'
if (-not $Odin) { $Odin = 'odin' }
if ([IO.Path]::IsPathRooted($Odin)) {
    if (-not (Test-Path -LiteralPath $Odin -PathType Leaf)) { throw "Odin executable not found: $Odin" }
} else {
    $command = Get-Command $Odin -ErrorAction SilentlyContinue
    if (-not $command) { throw "Odin executable not found on PATH: $Odin" }
    $Odin = $command.Source
}

New-Item -ItemType Directory -Force -Path 'out' | Out-Null
$outputPath = Join-Path (Get-Location) 'out\alicorn-monitor.exe'
if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
    try {
        $probe = [IO.File]::Open($outputPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $probe.Dispose()
    } catch {
        throw "The monitor executable is in use: $outputPath. Close the running Alicorn Monitor window and retry."
    }
}
& $Odin build . -out:out\alicorn-monitor.exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$odinRoot = Split-Path -Parent $Odin
$sdlDll = Join-Path $odinRoot 'vendor\sdl3\SDL3.dll'
if (-not (Test-Path -LiteralPath $sdlDll -PathType Leaf)) {
    throw "SDL3.dll was not found at $sdlDll. Use an Odin distribution containing vendor/sdl3."
}
if ((Get-Item -LiteralPath $sdlDll).Length -lt 100000) {
    throw "SDL3.dll appears to be a Git LFS pointer: $sdlDll"
}
Copy-Item -LiteralPath $sdlDll -Destination 'out\SDL3.dll' -Force

$args = @()
if ($Smoke) { $args += '--smoke' }
if ($Diagnostics) {
    $args += '--diagnostics'
    $args += "--capture-after=$CaptureAfter"
    $args += "--capture-dir=$CaptureDir"
}
if ($InputDebug) { $args += '--input-debug' }
& .\out\alicorn-monitor.exe @args
exit $LASTEXITCODE
