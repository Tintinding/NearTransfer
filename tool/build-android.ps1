param(
    [string] $Flutter = 'flutter',
    [string] $Output = 'release/NearTransfer-Android.apk',
    [string] $StageRoot = (Join-Path $env:LOCALAPPDATA 'NearTransfer/builds')
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$destination = [IO.Path]::GetFullPath($Output, $repo)
$stageParent = [IO.Path]::GetFullPath($StageRoot, $repo)
if ($stageParent -match '[^\x00-\x7f]') { throw 'StageRoot must have an ASCII path.' }
$stage = Join-Path $stageParent ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    # AGP refuses non-ASCII project paths on Windows. Copy only Flutter inputs;
    # credentials stay in the parent process environment and outside the repo.
    $files = & git -C $repo ls-files --cached --others --exclude-standard -- android lib l10n.yaml pubspec.yaml pubspec.lock .metadata
    if ($LASTEXITCODE) { throw 'Unable to list Flutter sources.' }
    foreach ($relative in ($files | Sort-Object -Unique)) {
        $source = Join-Path $repo $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $target = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target
    }
    Push-Location -LiteralPath $stage
    try {
        & $Flutter build apk --release
        if ($LASTEXITCODE) { throw 'Flutter release build failed.' }
    } finally {
        Pop-Location
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $stage 'build/app/outputs/flutter-apk/app-release.apk') -Destination $destination
    Write-Output $destination
} finally {
    # The only recursive deletion is the specific temporary directory we created.
    $resolvedStage = (Resolve-Path -LiteralPath $stage).Path
    if ((Split-Path -Parent $resolvedStage) -eq (Resolve-Path -LiteralPath $stageParent).Path -and
        (Split-Path -Leaf $resolvedStage) -match '^[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
