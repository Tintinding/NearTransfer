param(
    [string] $Flutter = 'flutter',
    [string] $StageRoot = (Join-Path $env:LOCALAPPDATA 'NearTransfer/builds')
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stageParent = [IO.Path]::GetFullPath($StageRoot, $repo)
if ($stageParent -match '[^\x00-\x7f]') { throw 'StageRoot must have an ASCII path.' }
$stage = Join-Path $stageParent ([Guid]::NewGuid().ToString('N'))
$name = 'NearTransfer-Windows-x64'
$destination = Join-Path $repo "release/$name.exe"

New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    # The Windows AOT toolchain can mangle a non-ASCII project path.
    $files = & git -C $repo ls-files --cached --others --exclude-standard -- windows lib l10n.yaml pubspec.yaml pubspec.lock .metadata
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
        $pubOutput = & $Flutter pub get 2>&1
        $pubStatus = $LASTEXITCODE
        $pubOutput | Write-Output
        if ($pubStatus) {
            if (($pubOutput -join [Environment]::NewLine) -notmatch 'Building with plugins requires symlink support') {
                throw 'Flutter pub get failed.'
            }
            # Flutter accepts directory junctions in its generated plugin tree.
            # They let a standard account build without changing Windows settings.
            $plugins = (Get-Content -LiteralPath '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json).plugins.windows
            foreach ($plugin in $plugins) {
                $link = Join-Path 'windows/flutter/ephemeral/.plugin_symlinks' $plugin.name
                if (-not (Test-Path -LiteralPath $link)) {
                    New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
                }
            }
            & $Flutter pub get
            if ($LASTEXITCODE) { throw 'Flutter pub get failed after linking Windows plugins.' }
        }
        & $Flutter build windows --release
        if ($LASTEXITCODE) { throw 'Flutter Windows release build failed.' }
    } finally {
        Pop-Location
    }

    $release = Join-Path $stage 'build/windows/x64/runner/Release'
    foreach ($file in @('near_transfer.exe', 'flutter_windows.dll', 'bonsoir_windows_plugin.dll',
                       'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
                       'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin')) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $file) -PathType Leaf)) {
            throw "Release is missing $file. Check the Visual Studio C++ workload and redistributable files."
        }
    }
    $package = New-Item -ItemType Directory -Path (Join-Path $stage 'package')
    $resourceLines = [Collections.Generic.List[string]]::new()
    $resourceLines.Add('#pragma code_page(65001)')
    $icon = (Join-Path $stage 'windows/runner/resources/app_icon.ico').Replace('\', '/')
    $resourceLines.Add('101 ICON "{0}"' -f $icon)
    $fileLines = [Collections.Generic.List[string]]::new()
    $fingerprints = [Collections.Generic.List[string]]::new()
    $id = 1000
    foreach ($file in (Get-ChildItem -LiteralPath $release -File -Recurse | Sort-Object FullName)) {
        $path = [IO.Path]::GetRelativePath($release, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $fingerprints.Add("$hash $path")
        $source = $file.FullName.Replace('\', '/')
        $resourceLines.Add(('{0} RCDATA "{1}"' -f $id, $source))
        $fileLines.Add(('    {{{0}, L"{1}"}},' -f $id, $path))
        $id++
    }
    $packageId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes(($fingerprints -join [char]10)))).ToLowerInvariant()
    $resourceLines | Set-Content -LiteralPath (Join-Path $package 'package.rc') -Encoding utf8
    @(
        'constexpr wchar_t kPackageId[] = L"{0}";' -f $packageId
        'constexpr PackageFile kPackageFiles[] = {'
        $fileLines
        '};'
    ) | Set-Content -LiteralPath (Join-Path $package 'package.inc') -Encoding utf8

    $cache = Get-Content -LiteralPath (Join-Path $stage 'build/windows/x64/CMakeCache.txt')
    $cmake = ($cache -cmatch '^CMAKE_COMMAND:INTERNAL=' | Select-Object -First 1) -creplace '^[^=]+=', ''
    $generator = ($cache -cmatch '^CMAKE_GENERATOR:INTERNAL=' | Select-Object -First 1) -creplace '^[^=]+=', ''
    $instance = ($cache -cmatch '^CMAKE_GENERATOR_INSTANCE:INTERNAL=' | Select-Object -First 1) -creplace '^[^=]+=', ''
    $launcherBuild = Join-Path $stage 'launcher'
    $configure = @('-S', (Join-Path $stage 'windows/portable'), '-B', $launcherBuild,
                   '-G', $generator, '-A', 'x64', "-DCMAKE_GENERATOR_INSTANCE=$instance",
                   "-DPACKAGE_RESOURCES=$($package.FullName)")
    & $cmake @configure
    if ($LASTEXITCODE) { throw 'Portable launcher configuration failed.' }
    & $cmake --build $launcherBuild --config Release
    if ($LASTEXITCODE) { throw 'Portable launcher build failed.' }

    $outputDirectory = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
    if ($outputDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Unexpected output directory: $($outputDirectory.FullName)"
    }
    if (Test-Path -LiteralPath $destination) {
        $previous = Get-Item -LiteralPath $destination
        if ($previous.PSIsContainer -or
            ($previous.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unexpected release path: $destination"
        }
    }
    Copy-Item -LiteralPath (Join-Path $launcherBuild "Release/$name.exe") -Destination $destination -Force
    Write-Output $destination
} finally {
    $resolvedStage = (Resolve-Path -LiteralPath $stage).Path
    if ((Split-Path -Parent $resolvedStage) -eq (Resolve-Path -LiteralPath $stageParent).Path -and
        (Split-Path -Leaf $resolvedStage) -match '^[a-f0-9]{32}$') {
        $links = Join-Path $resolvedStage 'windows/flutter/ephemeral/.plugin_symlinks'
        if (Test-Path -LiteralPath $links -PathType Container) {
            Get-ChildItem -LiteralPath $links -Force |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        }
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
